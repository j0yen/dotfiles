#!/usr/bin/env bash
# carbon-alive.sh — off-host witness for carbon (A1446, five-whys 2026-11-09 mechanism 3).
# Runs as a systemd --user timer on RedBaron and ryzen7, never on carbon: on 11-09 user@1000 was SIGKILLed twice and every
# recoverer and observer sat inside the killed cgroup, so the fleet was down ~2 h with no alarm.
#
# One ssh per run (ssh binary: $CARBON_ALIVE_SSH) prints key=value readings: host_up, user_manager, gateway, bus,
# dash_age_s, executor_age_s (age of the ctl heartbeat file). Derived reading `executor`: fresh | stale (executor_age_s >
# ${CARBON_ALIVE_EXEC_MAX_S:-1800}) | unknown (absent, non-numeric, or host unreachable); it is written to state.json,
# probes.jsonl and every alert whatever the state. One state per run, first match wins:
#   host-unreachable > user-manager-down > gateway-down > bus-down > dash-stale (dash_age_s > 300 or unreadable)
#   > executor-stale > ok
# executor-stale applies only while ${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/expect-executor exists: the director
# closes the ctl seat on purpose at times, so without that file a stale executor stays a reading (state ok, no page).
# A successful ssh alone is never "ok".
#
# State dir ${XDG_STATE_HOME:-$HOME/.local/state}/carbon-alive/: state.json (state, executor, since, outage_since,
# consecutive, states_seen, alerted, last_alert, last_alert_state, last_ok), probes.jsonl (capped 5000 lines),
# outbox.jsonl (alerts not yet delivered, capped 200: the oldest overflow moves to outbox.dead.jsonl), outbox.dead.jsonl
# (entries a deliverer rejected permanently, unparseable entries and cap overflow; capped 1000 lines). Each move to
# outbox.dead.jsonl logs one stderr line (kind, state, at; never the URL).
# Outage = from the first non-ok run after an ok to the next ok; `consecutive` counts NON-OK runs in it whatever the
# non-ok state, so an outage flapping gateway-down/bus-down/... still alerts. Alerts: first alert when consecutive
# reaches 2; while the outage lasts, re-alert when >= 30 min since the last alert OR the state differs from the last
# alerted state, never twice within 10 min; one recovery alert on the first ok after an outage that alerted (none for
# an outage that never alerted). Each carries host-of-origin, state, executor, outage_since, states seen in the outage,
# readings, and its `at` time (UTC ISO at the start of `text`).
#
# DELIVERY CONTRACT, two host-local files under ${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/ (never in the repo):
#   deliver      ONE command path. The command is run with the alert kind (alert|recovery) as $1 and the alert as one
#                JSON line on stdin ({kind,host,state,executor,since,outage_since,states,at,text,readings}, plus
#                replay_at = this run's time when the entry was queued by an earlier run); exit 0 = delivered,
#                exit 3 = rejected permanently (moved to outbox.dead.jsonl), any other exit = retry next run.
#   webhook.url  Discord webhook URL (regular file, mode 0600, owned by the running user, <= 4096 bytes, https://).
#                When `deliver` is absent and webhook.url exists, the deliverer defaults to carbon-alive-discord.sh next
#                to this script (path override: CARBON_ALIVE_WEBHOOK_FILE). Same contract as the cloud watchdog's
#                Discord delivery on orch/hub; the URL never appears on an argv, in output or in a log.
# Either channel must not route through carbon (not the carbon Hermes gateway, agorabus or fleet-dash). A missing or
# failing deliverer keeps the alert in outbox.jsonl; each run replays the outbox oldest-first before anything newer,
# stops at the first retryable failure, and rewrites outbox.jsonl atomically (temp + mv) after every delivered or
# dead-lettered entry, so a run cut short (TimeoutStartSec) re-sends only what was not delivered. No new send starts
# after ${CARBON_ALIVE_SEND_BUDGET_S:-40} s of the run have elapsed; the rest waits for the next run. ssh and the
# deliverer run without the lock fd, so a straggler child cannot hold the lock into the next run.
# Exit 0 after recording; nonzero only on this script's own bug. CARBON_ALIVE_NOW injects the clock (tests).
set -u

sd="${XDG_STATE_HOME:-$HOME/.local/state}/carbon-alive"
cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive"
cfg="$cfgdir/deliver"
webhook="${CARBON_ALIVE_WEBHOOK_FILE:-$cfgdir/webhook.url}"
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh_bin="${CARBON_ALIVE_SSH:-ssh}"
now="${CARBON_ALIVE_NOW:-$(date +%s)}"
host="${CARBON_ALIVE_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"
budget="${CARBON_ALIVE_SEND_BUDGET_S:-40}"
mkdir -p "$sd" || exit 1
exec 9>"$sd/lock"; flock -n 9 || exit 0

remote='
echo host_up=1
echo "user_manager=$(systemctl is-active user@1000.service 2>/dev/null | head -n1)"
echo "gateway=$(XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active hermes-gateway.service 2>/dev/null | head -n1)"
sock=/home/jsy/.cache/agorabus/sock
if command -v ss >/dev/null 2>&1; then
  if test -S "$sock" && ss -xlpn 2>/dev/null | grep -qF "$sock"; then echo bus=up; else echo bus=down; fi
else
  if test -S "$sock"; then echo bus=up; else echo bus=down; fi
fi
n=$(date +%s)
t=$(python3 -I -c "import json;print(int(json.load(open(\"/home/jsy/.cache/fleet-dash/status.json\"))[\"ts\"]))" 2>/dev/null)
if [ -n "$t" ]; then echo "dash_age_s=$((n-t))"; else echo dash_age_s=na; fi
if m=$(stat -c %Y /home/jsy/.cache/aide/heartbeat 2>/dev/null); then echo "executor_age_s=$((n-m))"; else echo executor_age_s=na; fi
'

out="$(timeout 30 "$ssh_bin" -n -o BatchMode=yes -o ConnectTimeout=8 carbon "$remote" 2>/dev/null 9>&-)"; rc=$?
expect=0; [ -e "$cfgdir/expect-executor" ] && expect=1
export CA_RC="$rc" CA_OUT="$out" CA_NOW="$now" CA_HOST="$host" CA_SD="$sd" CA_EXPECT="$expect" \
  CA_EXEC_MAX="${CARBON_ALIVE_EXEC_MAX_S:-1800}"

python3 -I - <<'PY' || exit 1
import json, os, sys, time
sd, now, host, rc = os.environ["CA_SD"], int(os.environ["CA_NOW"]), os.environ["CA_HOST"], int(os.environ["CA_RC"])
OBMAX, DEADMAX = 200, 1000
try: exec_max = int(os.environ["CA_EXEC_MAX"])
except ValueError: exec_max = 1800
r = {}
for ln in os.environ["CA_OUT"].splitlines():
    if "=" in ln:
        k, v = ln.split("=", 1); r[k.strip()] = v.strip()
def num(k):
    try: return int(r[k])
    except (KeyError, ValueError): return None
ea = num("executor_age_s") if rc == 0 else None
executor = "unknown" if ea is None else ("stale" if ea > exec_max else "fresh")
if rc != 0 or r.get("host_up") != "1": state = "host-unreachable"
elif r.get("user_manager") != "active": state = "user-manager-down"
elif r.get("gateway") != "active": state = "gateway-down"
elif r.get("bus") != "up": state = "bus-down"
elif num("dash_age_s") is None or num("dash_age_s") > 300: state = "dash-stale"
elif executor == "stale" and os.environ["CA_EXPECT"] == "1": state = "executor-stale"
else: state = "ok"
readings = dict(r) if rc == 0 else {"host_up": "0", "ssh_rc": str(rc)}
sp = os.path.join(sd, "state.json")
try: st = json.load(open(sp))
except Exception: st = {}
if st.get("state") != state: st["since"] = now
st["state"] = state; st["executor"] = executor
alerts = []
def mk(kind):
    osince = st.get("outage_since")
    seen = list(st.get("states_seen", []))
    text = (f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now))} carbon-alive[{host}] {kind}: state={state} "
            f"executor={executor} outage_since={osince} states={','.join(seen)} "
            + " ".join(f"{k}={v}" for k, v in readings.items()))
    return {"kind": kind, "host": host, "state": state, "executor": executor, "since": st["since"],
            "outage_since": osince, "states": seen, "at": now, "text": text, "readings": readings}
if state != "ok":
    if not st.get("outage_since"):
        st.update(outage_since=now, consecutive=0, states_seen=[], alerted=False, last_alert_state="")
    st["consecutive"] = int(st.get("consecutive", 0)) + 1
    if state not in st["states_seen"]: st["states_seen"].append(state)
    if st["consecutive"] >= 2:
        gap = now - int(st.get("last_alert", 0))
        if (not st.get("alerted")
                or (gap >= 600 and (gap >= 1800 or state != st.get("last_alert_state")))):
            alerts.append(mk("alert")); st.update(alerted=True, last_alert=now, last_alert_state=state)
else:
    if st.get("alerted"): alerts.append(mk("recovery"))
    st.update(last_ok=now, outage_since=None, consecutive=0, states_seen=[], alerted=False, last_alert_state="")
tmp = sp + ".tmp"; json.dump(st, open(tmp, "w")); os.replace(tmp, sp)
pj = os.path.join(sd, "probes.jsonl")
with open(pj, "a") as f:
    f.write(json.dumps({"at": now, "host": host, "state": state, "executor": executor, "readings": readings}) + "\n")
lines = open(pj).read().splitlines()
if len(lines) > 5000: open(pj, "w").write("\n".join(lines[-5000:]) + "\n")
def keep_last(path, ls, n):
    tmp = path + ".tmp"
    with open(tmp, "w") as f: f.write("".join(l + "\n" for l in ls[-n:]))
    os.replace(tmp, path)
def desc(l):
    try: a = json.loads(l); return f"kind={a.get('kind')} state={a.get('state')} at={a.get('at')}"
    except Exception: return "unparseable"
obp, dp = os.path.join(sd, "outbox.jsonl"), os.path.join(sd, "outbox.dead.jsonl")
with open(obp, "a") as f:
    for a in alerts: f.write(json.dumps(a) + "\n")
q = [l for l in open(obp).read().splitlines() if l.strip()]
if len(q) > OBMAX:
    over = q[:-OBMAX]
    with open(dp, "a") as f:
        for l in over: f.write(l + "\n")
    for l in over:
        print(f"carbon-alive: outbox over {OBMAX} entries, moved oldest {desc(l)} to outbox.dead.jsonl", file=sys.stderr)
    keep_last(obp, q, OBMAX)
if os.path.exists(dp):
    dl = open(dp).read().splitlines()
    if len(dl) > DEADMAX: keep_last(dp, dl, DEADMAX)
PY

desc() { # alert-json -> "kind=.. state=.. at=.." for a log line (never the URL: alerts do not carry it)
  printf '%s' "$1" | python3 -I -c 'import sys,json
try: a=json.loads(sys.stdin.read()); print("kind=%s state=%s at=%s" % (a.get("kind"), a.get("state"), a.get("at")))
except Exception: print("unparseable")' 2>/dev/null
}

deliver() { # alert-json -> 0 delivered, 3 permanent rejection or unparseable entry, else retry
  local cmd="" prep kind r
  if [ -e "$cfg" ]; then cmd="$(head -n1 "$cfg" 2>/dev/null)" || return 1
  elif [ -e "$webhook" ]; then cmd="$self_dir/carbon-alive-discord.sh"; fi
  [ -n "$cmd" ] && [ -x "$cmd" ] || return 1
  # kind + the alert with replay_at added when an earlier run queued it (entries queued this run carry at == now)
  prep="$(printf '%s' "$1" | CA_NOW="$now" python3 -I -c 'import sys,json,os
try:
    a = json.loads(sys.stdin.read()); k = a["kind"]
except Exception: sys.exit(3)
if k not in ("alert", "recovery"): sys.exit(3)
now = int(os.environ["CA_NOW"])
if a.get("at") != now: a["replay_at"] = now
print(k + "\t" + json.dumps(a))' 2>/dev/null)"; r=$?
  [ "$r" = 3 ] && return 3; [ "$r" = 0 ] || return 1
  kind="${prep%%$'\t'*}"
  printf '%s\n' "${prep#*$'\t'}" | timeout 30 "$cmd" "$kind" >/dev/null 2>&1 9>&-
}

ob="$sd/outbox.jsonl"; dead="$sd/outbox.dead.jsonl"
if [ -s "$ob" ]; then
  mapfile -t q < <(grep -v '^[[:space:]]*$' "$ob")
  i=0
  while [ "$i" -lt "${#q[@]}" ]; do
    if [ "$SECONDS" -ge "$budget" ]; then
      echo "carbon-alive: send budget ${budget}s spent, $(( ${#q[@]} - i )) outbox entries left for the next run" >&2; break
    fi
    deliver "${q[$i]}"; r=$?
    if [ "$r" = 3 ]; then
      printf '%s\n' "${q[$i]}" >> "$dead"
      echo "carbon-alive: deliverer rejected $(desc "${q[$i]}") permanently, moved to outbox.dead.jsonl" >&2
    elif [ "$r" != 0 ]; then
      break
    fi
    i=$((i+1))
    if [ "$i" -lt "${#q[@]}" ]; then printf '%s\n' "${q[@]:$i}" > "$ob.tmp"; else : > "$ob.tmp"; fi
    mv "$ob.tmp" "$ob"
  done
fi
exit 0
