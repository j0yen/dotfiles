#!/usr/bin/env bash
# carbon-alive.sh — off-host witness for carbon (A1446, five-whys 2026-11-09 mechanism 3).
# Runs as a systemd --user timer on RedBaron and ryzen7, never on carbon: on 11-09 user@1000 was SIGKILLed twice and every
# recoverer and observer sat inside the killed cgroup, so the fleet was down ~2 h with no alarm.
#
# One ssh per run (ssh binary: $CARBON_ALIVE_SSH) prints key=value readings: host_up, user_manager, gateway, bus,
# dash_age_s, executor_age_s. One state per run, first match wins:
#   host-unreachable > user-manager-down > gateway-down > bus-down > dash-stale (dash_age_s > 300 or unreadable) > ok
# A successful ssh alone is never "ok".
#
# State dir ${XDG_STATE_HOME:-$HOME/.local/state}/carbon-alive/: state.json (state, since, outage_since, consecutive,
# states_seen, alerted, last_alert, last_alert_state, last_ok), probes.jsonl (capped 5000 lines), outbox.jsonl (alerts
# not yet delivered).
# Outage = from the first non-ok run after an ok to the next ok; `consecutive` counts NON-OK runs in it whatever the
# non-ok state, so an outage flapping gateway-down/bus-down/... still alerts. Alerts: first alert when consecutive
# reaches 2; while the outage lasts, re-alert when >= 30 min since the last alert OR the state differs from the last
# alerted state, never twice within 10 min; one recovery alert on the first ok after an outage that alerted (none for
# an outage that never alerted). Each carries host-of-origin, state, outage_since, states seen in the outage, readings.
#
# DELIVERY CONTRACT, two host-local files under ${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/ (never in the repo):
#   deliver      ONE command path. The command is run with the alert kind (alert|recovery) as $1 and the alert as one
#                JSON line on stdin ({kind,host,state,since,outage_since,states,at,text,readings}); exit 0 = delivered.
#   webhook.url  Discord webhook URL (regular file, mode 0600, owned by the running user, <= 4096 bytes, https://).
#                When `deliver` is absent and webhook.url exists, the deliverer defaults to carbon-alive-discord.sh next
#                to this script (path override: CARBON_ALIVE_WEBHOOK_FILE). Same contract as the cloud watchdog's
#                Discord delivery on orch/hub; the URL never appears on an argv, in output or in a log.
# Either channel must not route through carbon (not the carbon Hermes gateway, agorabus or fleet-dash). A missing or
# failing deliverer keeps the alert in outbox.jsonl; the next run replays the outbox oldest-first before anything newer.
# Exit 0 after recording; nonzero only on this script's own bug. CARBON_ALIVE_NOW injects the clock (tests).
set -u

sd="${XDG_STATE_HOME:-$HOME/.local/state}/carbon-alive"
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/deliver"
webhook="${CARBON_ALIVE_WEBHOOK_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/webhook.url}"
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh_bin="${CARBON_ALIVE_SSH:-ssh}"
now="${CARBON_ALIVE_NOW:-$(date +%s)}"
host="${CARBON_ALIVE_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"
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

out="$(timeout 30 "$ssh_bin" -n -o BatchMode=yes -o ConnectTimeout=8 carbon "$remote" 2>/dev/null)"; rc=$?
export CA_RC="$rc" CA_OUT="$out" CA_NOW="$now" CA_HOST="$host" CA_SD="$sd"

python3 -I - <<'PY' || exit 1
import json, os
sd, now, host, rc = os.environ["CA_SD"], int(os.environ["CA_NOW"]), os.environ["CA_HOST"], int(os.environ["CA_RC"])
r = {}
for ln in os.environ["CA_OUT"].splitlines():
    if "=" in ln:
        k, v = ln.split("=", 1); r[k.strip()] = v.strip()
def num(k):
    try: return int(r[k])
    except (KeyError, ValueError): return None
if rc != 0 or r.get("host_up") != "1": state = "host-unreachable"
elif r.get("user_manager") != "active": state = "user-manager-down"
elif r.get("gateway") != "active": state = "gateway-down"
elif r.get("bus") != "up": state = "bus-down"
elif num("dash_age_s") is None or num("dash_age_s") > 300: state = "dash-stale"
else: state = "ok"
readings = dict(r) if rc == 0 else {"host_up": "0", "ssh_rc": str(rc)}
sp = os.path.join(sd, "state.json")
try: st = json.load(open(sp))
except Exception: st = {}
if st.get("state") != state: st["since"] = now
st["state"] = state
alerts = []
def mk(kind):
    osince = st.get("outage_since")
    seen = list(st.get("states_seen", []))
    text = (f"carbon-alive[{host}] {kind}: state={state} outage_since={osince} states={','.join(seen)} "
            + " ".join(f"{k}={v}" for k, v in readings.items()))
    return {"kind": kind, "host": host, "state": state, "since": st["since"], "outage_since": osince,
            "states": seen, "at": now, "text": text, "readings": readings}
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
    f.write(json.dumps({"at": now, "host": host, "state": state, "readings": readings}) + "\n")
lines = open(pj).read().splitlines()
if len(lines) > 5000: open(pj, "w").write("\n".join(lines[-5000:]) + "\n")
with open(os.path.join(sd, "outbox.jsonl"), "a") as f:
    for a in alerts: f.write(json.dumps(a) + "\n")
PY

deliver() { # alert-json -> 0 delivered
  local cmd=""
  if [ -e "$cfg" ]; then cmd="$(head -n1 "$cfg" 2>/dev/null)" || return 1
  elif [ -e "$webhook" ]; then cmd="$self_dir/carbon-alive-discord.sh"; fi
  [ -n "$cmd" ] && [ -x "$cmd" ] || return 1
  local kind; kind="$(printf '%s' "$1" | python3 -I -c 'import sys,json;print(json.loads(sys.stdin.read())["kind"])')" || return 1
  printf '%s\n' "$1" | timeout 30 "$cmd" "$kind" >/dev/null 2>&1
}

ob="$sd/outbox.jsonl"
if [ -s "$ob" ]; then
  rest="$sd/outbox.rest"; : > "$rest"; failed=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    if [ "$failed" = 0 ] && deliver "$line"; then continue; fi
    failed=1; printf '%s\n' "$line" >> "$rest"
  done < "$ob"
  mv "$rest" "$ob"
fi
exit 0
