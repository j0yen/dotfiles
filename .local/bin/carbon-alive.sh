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
# State dir ${XDG_STATE_HOME:-$HOME/.local/state}/carbon-alive/: state.json (state, since, consecutive, last_ok,
# last_alert), probes.jsonl (capped 5000 lines), outbox.jsonl (alerts not yet delivered).
# Alerts: a non-ok state held for 2 consecutive runs; re-alert every 30 min while down (dedupe on state+since);
# one recovery alert on the first ok after an alerted outage. Each carries host-of-origin, state, since, readings.
#
# DELIVERY CONTRACT: ${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/deliver is a host-local file holding ONE command
# path (secrets stay in that file's target, never in the repo). The command is run with the alert kind as $1 and the
# alert as one JSON line on stdin ({kind,host,state,since,at,text,readings}); exit 0 = delivered. No existing
# off-carbon deliverer was found in the repo (alert-deliver.sh is not shipped here; followup-deliver.sh goes through
# `hermes send`, which is not proven off-carbon), so there is no default: the file must point at a channel that does
# not route through carbon (not the carbon Hermes gateway, agorabus or fleet-dash). A missing or failing deliverer
# keeps the alert in outbox.jsonl; the next run replays the outbox oldest-first before anything newer.
# Exit 0 after recording; nonzero only on this script's own bug. CARBON_ALIVE_NOW injects the clock (tests).
set -u

sd="${XDG_STATE_HOME:-$HOME/.local/state}/carbon-alive"
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/carbon-alive/deliver"
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
if st.get("state") == state:
    st["consecutive"] = int(st.get("consecutive", 0)) + 1
else:
    st.update(state=state, since=now, consecutive=1)
if state == "ok": st["last_ok"] = now
alerts = []
def mk(kind):
    since = st["since"]
    text = f"carbon-alive[{host}] {kind}: state={state} since={since} " + " ".join(f"{k}={v}" for k, v in readings.items())
    return {"kind": kind, "host": host, "state": state, "since": since, "at": now, "text": text, "readings": readings}
if state != "ok":
    if st["consecutive"] >= 2:
        key = f"{state}@{st['since']}"
        if st.get("alert_key") != key or now - int(st.get("last_alert", 0)) >= 1800:
            alerts.append(mk("alert")); st.update(alert_key=key, last_alert=now, outage_alerted=True)
elif st.get("outage_alerted"):
    alerts.append(mk("recovery")); st.update(outage_alerted=False, alert_key="", last_alert=now)
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
  local cmd; cmd="$(head -n1 "$cfg" 2>/dev/null)" || return 1
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
