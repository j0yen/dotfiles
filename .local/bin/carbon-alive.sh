#!/usr/bin/env bash
# carbon-alive.sh — off-host witness for carbon (A1446, five-whys 2026-11-09 mechanism 3).
# Runs as a SYSTEM timer with User=jsy on RedBaron and ryzen7, never on carbon (.config/systemd/system-units/): on 11-09
# user@1000 was SIGKILLed twice and every recoverer and observer sat inside the killed cgroup, so the fleet was down ~2 h
# with no alarm; under the system manager a SIGKILL of the witness host's own user manager cannot stop the witness either.
# Needs only HOME (state/config dirs below): no XDG_RUNTIME_DIR, user bus or local systemctl.
#
# One ssh per run (ssh binary: $CARBON_ALIVE_SSH) prints key=value readings: host_up, user_manager, gateway, bus,
# dash_age_s, executor_age_s (age of the ctl heartbeat file), um_inv / um_nrestarts / um_enter_mono (InvocationID,
# NRestarts, ActiveEnterTimestampMonotonic of user@1000.service from the system manager) and boot_id
# (/proc/sys/kernel/random/boot_id). Derived reading `executor`: fresh | stale (executor_age_s >
# ${CARBON_ALIVE_EXEC_MAX_S:-1800}) | unknown (absent, non-numeric, or host unreachable); it is written to state.json,
# probes.jsonl and every alert whatever the state. One state per run, first match wins:
#   witness-offline > host-unreachable > user-manager-down > host-rebooted > user-manager-restarted > gateway-down > bus-down
#   > dash-stale (dash_age_s > 300 or unreadable) > executor-stale > ok
# witness-offline is UNKNOWN, never a carbon DOWN: when the ssh probe fails, one TCP connect (bounded to 5 s) tests
# whether this witness reaches ${CARBON_ALIVE_REF:-discord.com:443} (host:port). REF reachable = the old behavior, state
# host-unreachable. REF unreachable = state witness-offline: this host lost its own network, so nothing is known about
# carbon. It neither increments nor resets the carbon outage `consecutive` count, sends no host-unreachable alert and no
# recovery, and is recorded in state.json and probes.jsonl like every run. state.json keeps its own count of consecutive
# witness-offline runs (witness_offline_runs); when it reaches 10 one alert with state witness-offline is queued (it waits
# in the outbox until delivery works), once per streak (witness_offline_alerted) until recovered. The first run after
# that streak that reads carbon ok queues one recovery for it (`recovers: witness-offline`). An unparseable REF counts as
# reachable (the old behavior, so a typo cannot hide a real outage).
# host-rebooted / user-manager-restarted are EVENTS read against the baseline in state.json (boot_id, um_inv,
# um_nrestarts, um_enter_mono of the last run with the host up and user_manager=active; only such a run moves it):
# boot_id differs -> host-rebooted; else um_inv differs or um_nrestarts rose -> user-manager-restarted. They exist
# because a SIGKILLed user manager is back (Restart=on-abnormal, or the probe's own ssh login) before the next probe,
# so is-active alone reads active. An event alerts on the first run that sees it (no two-run debounce, no 10-min gap)
# and does not hold the state open: the next run with nothing wrong is ok and sends the recovery. The first run with no
# baseline records one and compares nothing.
# executor-stale applies only while ${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/expect-executor exists, and then
# executor stale OR unknown (heartbeat missing or unreadable) gives it: the director closes the ctl seat on purpose at
# times, so without that file the executor stays a reading (state ok, no page). A successful ssh alone is never "ok".
#
# State dir ${XDG_STATE_HOME:-$HOME/.local/state}/carbon-alive/: state.json (state, executor, since, outage_since,
# consecutive, states_seen, alerted, last_alert, last_alert_state, last_ok, readings, baseline, witness_offline_runs,
# witness_offline_since, witness_offline_alerted), probes.jsonl (capped
# 5000 lines), outbox.jsonl (alerts not yet delivered, capped 200: the oldest overflow moves to outbox.dead.jsonl),
# outbox.dead.jsonl (entries a deliverer rejected permanently, unparseable entries and cap overflow; capped 1000 lines).
# Each move to outbox.dead.jsonl logs one stderr line (kind, state, at; never the URL); a trim of outbox.dead.jsonl logs
# one stderr line with the count dropped.
# Outage = from the first non-ok run after an ok to the next ok; `consecutive` counts NON-OK runs in it whatever the
# non-ok state, so an outage flapping gateway-down/bus-down/... still alerts. Alerts: first alert when consecutive
# reaches 2 (an event: at once); while the outage lasts, re-alert when >= 30 min since the last alert OR the state
# differs from the last alerted state, never twice within 10 min (events excepted); one recovery alert on the first ok
# after an outage that alerted (none for an outage that never alerted). Each carries host-of-origin, state, executor,
# outage_since, states seen in the outage, readings, `previous` (the baseline an event was read against) and its `at`
# time (UTC ISO at the start of `text`).
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
# after ${CARBON_ALIVE_SEND_BUDGET_S:-40} s of the run have elapsed; the rest waits for the next run. Each send gets
# min(30, 50 - elapsed) s, then TERM, then KILL 5 s later (timeout -k 5), and none starts when that limit is under 5 s,
# so one run ends by ~55 s (TimeoutStartSec=60) even with a deliverer that ignores TERM; ssh gets 30 s + 5 s the same
# way, and the REF check 5 s + 1 s (it runs only after a failed ssh, inside the same SECONDS clock the send window reads). ssh and the deliverer run without the lock fd, so a straggler child cannot hold the lock into the next run.
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
systemctl show user@1000.service -p InvocationID -p NRestarts -p ActiveEnterTimestampMonotonic 2>/dev/null |
while IFS="=" read -r k v; do
  case "$k" in
    InvocationID) echo "um_inv=$v" ;;
    NRestarts) echo "um_nrestarts=$v" ;;
    ActiveEnterTimestampMonotonic) echo "um_enter_mono=$v" ;;
  esac
done
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
'

out="$(timeout -k 5 30 "$ssh_bin" -n -o BatchMode=yes -o ConnectTimeout=8 carbon "$remote" 2>/dev/null 9>&-)"; rc=$?
expect=0; [ -e "$cfgdir/expect-executor" ] && expect=1
ref="${CARBON_ALIVE_REF:-discord.com:443}"; ref_ok=1
if [ "$rc" != 0 ]; then # ssh failed: is it carbon, or this witness without a network? exit 1/124/137 = REF unreachable
  timeout -k 1 5 python3 -I -c 'import socket, sys
try:
    h, p = sys.argv[1].rsplit(":", 1)
    socket.create_connection((h, int(p)), timeout=4).close()
except Exception as e: sys.exit(1 if isinstance(e, OSError) else 2)' "$ref" >/dev/null 2>&1 9>&-
  case $? in 1|124|137) ref_ok=0 ;; esac
fi
export CA_RC="$rc" CA_REF_OK="$ref_ok" CA_OUT="$out" CA_NOW="$now" CA_HOST="$host" CA_SD="$sd" CA_EXPECT="$expect" \
  CA_EXEC_MAX="${CARBON_ALIVE_EXEC_MAX_S:-1800}"

python3 -I - <<'PY' || exit 1
import json, os, sys, time
sd, now, host, rc = os.environ["CA_SD"], int(os.environ["CA_NOW"]), os.environ["CA_HOST"], int(os.environ["CA_RC"])
OBMAX, DEADMAX, WO_ALERT_AFTER = 200, 1000, 10
witness_off = rc != 0 and os.environ["CA_REF_OK"] == "0"
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
sp = os.path.join(sd, "state.json")
try: st = json.load(open(sp))
except Exception: st = {}
if not isinstance(st, dict): st = {}
EVENTS = ("host-rebooted", "user-manager-restarted")
BASE = ("boot_id", "um_inv", "um_nrestarts", "um_enter_mono")
base = st.get("baseline") if isinstance(st.get("baseline"), dict) else {}
up = rc == 0 and r.get("host_up") == "1"
um_up = up and r.get("user_manager") == "active"
def moved(k): return bool(base.get(k)) and bool(r.get(k)) and base[k] != r[k]
def rose(k):
    try: return int(r[k]) > int(base[k])
    except (KeyError, ValueError, TypeError): return False
event = None
if um_up:
    if moved("boot_id"): event = "host-rebooted"
    elif moved("um_inv") or rose("um_nrestarts"): event = "user-manager-restarted"
if witness_off: state = "witness-offline"
elif not up: state = "host-unreachable"
elif not um_up: state = "user-manager-down"
elif event: state = event
elif r.get("gateway") != "active": state = "gateway-down"
elif r.get("bus") != "up": state = "bus-down"
elif num("dash_age_s") is None or num("dash_age_s") > 300: state = "dash-stale"
elif executor in ("stale", "unknown") and os.environ["CA_EXPECT"] == "1": state = "executor-stale"
else: state = "ok"
readings = dict(r) if rc == 0 else {"host_up": "0", "ssh_rc": str(rc)}
if witness_off: readings["ref"] = "unreachable"
previous = {k: base.get(k) for k in BASE} if event else None
# the baseline moves only on a run with the host up and the user manager active, so a down run in between still
# leaves the restart visible to the next active run
if um_up: st["baseline"] = {k: (r.get(k) or base.get(k)) for k in BASE}
if st.get("state") != state: st["since"] = now
st["state"] = state; st["executor"] = executor; st["readings"] = readings
alerts = []
def mk(kind, osince=None, seen=None, recovers=None):
    if seen is None: osince, seen = st.get("outage_since"), list(st.get("states_seen", []))
    text = (f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now))} carbon-alive[{host}] {kind}: state={state} "
            f"executor={executor} outage_since={osince} states={','.join(seen)} "
            + " ".join(f"{k}={v}" for k, v in readings.items())
            + ("" if not previous else " previous: " + " ".join(f"{k}={v}" for k, v in previous.items())))
    a = {"kind": kind, "host": host, "state": state, "executor": executor, "since": st["since"],
         "outage_since": osince, "states": seen, "at": now, "text": text, "readings": readings}
    if previous: a["previous"] = previous
    if recovers: a["recovers"] = recovers
    return a
wo_since = st.get("witness_offline_since")
if witness_off:
    # UNKNOWN about carbon: the carbon outage fields (consecutive, outage_since, states_seen, alerted) stay as they were
    st["witness_offline_runs"] = int(st.get("witness_offline_runs", 0)) + 1
    if st["witness_offline_runs"] == 1 and not st.get("witness_offline_alerted"): st["witness_offline_since"] = wo_since = now
    if st["witness_offline_runs"] >= WO_ALERT_AFTER and not st.get("witness_offline_alerted"):
        alerts.append(mk("alert", wo_since, ["witness-offline"])); st["witness_offline_alerted"] = True
elif state != "ok":
    st["witness_offline_runs"] = 0
    if not st.get("outage_since"):
        st.update(outage_since=now, consecutive=0, states_seen=[], alerted=False, last_alert_state="")
    st["consecutive"] = int(st.get("consecutive", 0)) + 1
    if state not in st["states_seen"]: st["states_seen"].append(state)
    if state in EVENTS:
        alerts.append(mk("alert")); st.update(alerted=True, last_alert=now, last_alert_state=state)
    elif st["consecutive"] >= 2:
        gap = now - int(st.get("last_alert", 0))
        if (not st.get("alerted")
                or (gap >= 600 and (gap >= 1800 or state != st.get("last_alert_state")))):
            alerts.append(mk("alert")); st.update(alerted=True, last_alert=now, last_alert_state=state)
else:
    if st.get("alerted"): alerts.append(mk("recovery"))
    if st.get("witness_offline_alerted"):
        alerts.append(mk("recovery", wo_since, ["witness-offline"], "witness-offline"))
    st.update(witness_offline_runs=0, witness_offline_alerted=False, witness_offline_since=None)
    st.update(last_ok=now, outage_since=None, consecutive=0, states_seen=[], alerted=False, last_alert_state="")
tmp = sp + ".tmp"; json.dump(st, open(tmp, "w")); os.replace(tmp, sp)
pj = os.path.join(sd, "probes.jsonl")
with open(pj, "a") as f:
    p = {"at": now, "host": host, "state": state, "executor": executor, "readings": readings}
    if previous: p["previous"] = previous
    f.write(json.dumps(p) + "\n")
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
    if len(dl) > DEADMAX:
        keep_last(dp, dl, DEADMAX)
        print(f"carbon-alive: outbox.dead.jsonl over {DEADMAX} lines, dropped the oldest {len(dl) - DEADMAX}", file=sys.stderr)
PY

desc() { # alert-json -> "kind=.. state=.. at=.." for a log line (never the URL: alerts do not carry it)
  printf '%s' "$1" | python3 -I -c 'import sys,json
try: a=json.loads(sys.stdin.read()); print("kind=%s state=%s at=%s" % (a.get("kind"), a.get("state"), a.get("at")))
except Exception: print("unparseable")' 2>/dev/null
}

deliver() { # alert-json limit-s -> 0 delivered, 3 permanent rejection or unparseable entry, else retry
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
  printf '%s\n' "${prep#*$'\t'}" | timeout -k 5 "$2" "$cmd" "$kind" >/dev/null 2>&1 9>&-
}

ob="$sd/outbox.jsonl"; dead="$sd/outbox.dead.jsonl"
if [ -s "$ob" ]; then
  mapfile -t q < <(grep -v '^[[:space:]]*$' "$ob")
  i=0
  while [ "$i" -lt "${#q[@]}" ]; do
    if [ "$SECONDS" -ge "$budget" ]; then
      echo "carbon-alive: send budget ${budget}s spent, $(( ${#q[@]} - i )) outbox entries left for the next run" >&2; break
    fi
    lim=$(( 50 - SECONDS )); [ "$lim" -gt 30 ] && lim=30
    if [ "$lim" -lt 5 ]; then
      echo "carbon-alive: ${lim}s left of the 50s send window, $(( ${#q[@]} - i )) outbox entries left for the next run" >&2; break
    fi
    deliver "${q[$i]}" "$lim"; r=$?
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
