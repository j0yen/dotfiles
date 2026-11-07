#!/usr/bin/env bash
# Recovery plan d-20261107-072411-hermes-666e step 2: isolated alive-idle and dead-executor falsifier, provider outage, replay, known-bad control.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; S="$here/.local/bin/ctl-silence-recover.sh"; W="$here/.local/bin/aide-wake.sh"
fail=0; ok(){ echo "PASS $1"; }; bad(){ echo "FAIL $1"; fail=1; }
t="$(mktemp -d)"; sess="silrec$$"; unset TMUX TMUX_PANE; trap 'tmux -L "$sess" kill-server 2>/dev/null; rm -rf "$t"' EXIT
printf '#!/bin/sh\nexec tmux -L %s "$@"\n' "$sess" > "$t/tmuxw"; chmod +x "$t/tmuxw"; export SR_TMUX_BIN="$t/tmuxw"
mkdir -p "$t/ev" "$t/aw" "$t/home"; echo "work" > "$t/ev/aide-events.log"; echo x > "$t/tr.jsonl"
export SR_DIR="$t/sr" SR_EVENTS_DIR="$t/ev" AIDE_WAKE_DIR="$t/aw" SR_TRANSCRIPT="$t/tr.jsonl" SR_NOTIFY_BIN="$t/notify" SR_NOW=1000000 SR_SID=11111111-2222-3333-4444-555555555555
printf '#!/bin/sh\nexit 1\n' > "$t/pg-none"; printf '#!/bin/sh\nexit 0\n' > "$t/pg-live"; chmod +x "$t/pg-none" "$t/pg-live"; export SR_PGREP_BIN="$t/pg-none"
printf '#!/bin/sh\necho "$@" >> %s/notify.log\n' "$t" > "$t/notify"; chmod +x "$t/notify"
touch -d @990000 "$t/tr.jsonl"   # 10000 s quiet
# alive-idle: a real tmux pane whose current command is node (a fake "claude") reading a file the poke lands in
export SR_ALIVE_RE=sleep
"$t/tmuxw" new-session -d -s "$sess" -x 80 -y 24 "sleep 600" && sleep 0.5
pane="$("$t/tmuxw" list-panes -t "$sess" -F '#{pane_id}' | head -1)"; export SR_PANE="$pane"
"$t/tmuxw" display-message -p -t "$pane" '#{pane_current_command}' | grep -q sleep && ok "fixture pane runs a live process" || bad "fixture pane runs a live process"
export SR_HOLD_BIN="$t/hold-ok"; printf '#!/bin/sh\nexit 0\n' > "$t/hold-ok"; chmod +x "$t/hold-ok"
out="$("$S")"; sleep 0.5
[ "$out" = poked ] && "$t/tmuxw" capture-pane -p -t "$pane" | grep -q 'silence-recover' && ok "alive idle pane poked, text landed in the pane" || bad "alive idle pane poked ($out)"
out="$("$S")"; [ "$out" = open:poked ] && ok "replay with open incident does not re-poke" || bad "replay ($out)"
[ "$("$t/tmuxw" capture-pane -p -t "$pane" | grep -c silence-recover)" = 1 ] && ok "exactly one poke" || bad "exactly one poke"
echo 5 > "$t/ev/aide-events.cursor"; out="$("$S")"; [ "$out" = consumed ] && [ ! -e "$t/sr/incident.json" ] && ok "cursor advance closes incident as consumed" || bad "consumed ($out)"
# fresh transcript write = not silent
touch -d @999990 "$t/tr.jsonl"; rm -f "$t/ev/aide-events.cursor"; out="$("$S")"; [ "$out" = idle-ok ] && ok "recent transcript write = no action" || bad "recent write ($out)"
touch -d @990000 "$t/tr.jsonl"
# dead executor: pane gone
"$t/tmuxw" kill-server; sleep 0.3
export SR_LAUNCH_CMD="echo relaunch >> $t/launch.log"
out="$("$S")"; [ "$out" = relaunched ] && grep -q relaunch "$t/launch.log" && ok "dead pane + gate allows -> launcher invoked" || bad "dead relaunch ($out)"
rm -f "$t/sr/incident.json"
printf '#!/bin/sh\necho "hold-gate: HOLD blocks ctl-recover" >&2\nexit 1\n' > "$t/hold-no"; chmod +x "$t/hold-no"; export SR_HOLD_BIN="$t/hold-no"; rm -f "$t/launch.log"
out="$("$S")"; [ "$out" = blocked-by-hold ] && [ ! -e "$t/launch.log" ] && grep -q 'blocked-by-hold' "$t/notify.log" && [ -s "$t/sr/incident.json" ] && ok "hold refusal: no launch, persistent incident, notified (no bypass)" || bad "hold refusal ($out)"
out2="$("$S")"; [ "$out2" = open:blocked-by-hold ] && ok "refused incident stays open on replay" || bad "refused replay ($out2)"
export SR_HOLD_BIN="$t/hold-ok"; out2="$("$S")"; [ "$out2" = relaunched ] && grep -q relaunch "$t/launch.log" && ok "hold lifts -> blocked incident retried and relaunched" || bad "retry after lift ($out2)"
export SR_HOLD_BIN="$t/hold-no"; rm -f "$t/launch.log" "$t/sr/incident.json"; "$S" >/dev/null
[ "$(cat "$t/ev/aide-events.log")" = work ] && ok "queue untouched" || bad "queue untouched"
# guards: a live ctl elsewhere and a bad sid are never relaunched over
rm -f "$t/sr/incident.json"; export SR_HOLD_BIN="$t/hold-ok" SR_PGREP_BIN="$t/pg-live"; rm -f "$t/launch.log"
out="$("$S")"; [ "$out" = live-elsewhere ] && [ ! -e "$t/launch.log" ] && ok "live ctl process elsewhere: no relaunch" || bad "live-elsewhere ($out)"
rm -f "$t/sr/incident.json"; export SR_PGREP_BIN="$t/pg-none"; out="$(SR_SID=bogus "$S")"; [ "$out" = bad-sid ] && [ ! -e "$t/launch.log" ] && ok "bad sid: no relaunch, escalated" || bad "bad-sid ($out)"
rm -f "$t/sr/incident.json"
# provider outage: gate allows, launcher fails
rm -f "$t/sr/incident.json"; export SR_HOLD_BIN="$t/hold-ok" SR_LAUNCH_CMD="exit 7"; : > "$t/notify.log"
out="$("$S")"; [ "$out" = launch-failed ] && grep -q 'launch-failed' "$t/notify.log" && ok "provider outage: detection+queue preserved, deterministic escalation" || bad "provider outage ($out)"
# escalation repeats only after SR_ESC_MIN
: > "$t/notify.log"; out="$("$S")"; [ ! -s "$t/notify.log" ] && ok "no early re-escalation" || bad "early escalation"
SR_NOW=1001000 "$S" >/dev/null; grep -q 'launch-failed unconsumed' "$t/notify.log" && ok "escalates again after SR_ESC_MIN" || bad "re-escalation"
# known-bad control: existing timer-only check on a dead pane acts on nothing
rm -f "$t/sr/incident.json"; echo 990000 > "$t/aw/heartbeat"; echo 999000 > "$t/aw/wake-armed"; echo "$pane" > "$t/aw/pane"
EVENTS_DIR="$t/ev" AIDE_TMUX_BIN="$t/tmuxw" OWED_NOW_BIN="$t/none" "$W" check; jq -e '.idle==true and .poked=="no"' "$t/aw/aide-idle.json" >/dev/null && ok "control: aide-wake alone leaves a dead executor unrecovered (poked=no, no launch)" || bad "control"
exit $fail
