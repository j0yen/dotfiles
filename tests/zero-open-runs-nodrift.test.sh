#!/usr/bin/env bash
# zero-open-runs-nodrift.test.sh (A53, Joe #113): approve.sh and seat-ask.sh refuse a what/why that gates work on 0 open runs or an idle host;
# the patterns are one pair of files (.config/wm-guards/*.ere) pinned here to the same literals swarm-decide wm_decide/checks.py carries.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=$((fail+1)); }
PIN_ERE='\b(0|zero) open runs|\b(0|zero|no) runs? (are )?open|\b(at|until|wait(ing)? for) (0|zero) (open )?runs|when (the host is )?idle|quiet host|\bno open runs|when (the )?(fleet|host|rb|redbaron|ryzen7|r7) is idle|once idle|after the queue drains|wait(s|ing)? (for|until) no( open)? runs'
PIN_EXEMPT='never (wait for|gate on) [^.;:()]{1,40}|[^.;:()]{0,40} is not a gate'
[ "$(head -n1 "$here/.config/wm-guards/zero-open-runs.ere")" = "$PIN_ERE" ] && ok "refusal ERE pinned" || bad "refusal ERE drifted from the swarm-decide constant"
[ "$(head -n1 "$here/.config/wm-guards/zero-open-runs-exempt.ere")" = "$PIN_EXEMPT" ] && ok "exempt ERE pinned" || bad "exempt ERE drifted"
SD="${SWARM_DECIDE_DIR:-}"
if [ -n "$SD" ] && [ -r "$SD/wm_decide/checks.py" ]; then
  py=$(python3 -I - "$SD/wm_decide/checks.py" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
for n in ("ZERO_OPEN_RUNS_ERE", "ZERO_EXEMPT_ERE"):
    print(re.search(n + r' = r"(.*)"', s).group(1))
PY
)
  [ "$(printf '%s\n' "$py" | sed -n 1p)" = "$PIN_ERE" ] && [ "$(printf '%s\n' "$py" | sed -n 2p)" = "$PIN_EXEMPT" ] && ok "swarm-decide checks.py carries the same strings" || bad "swarm-decide checks.py differs"
fi
. "$here/.local/lib/zero-open-runs-guard.sh"
export WM_GUARDS_DIR="$here/.config/wm-guards"
for t in "wait for 0 open runs" "apply at 0 runs" "do it when idle" "on a quiet host only" "once no runs open" "until zero runs" "no open runs" "when the fleet is idle" "when ryzen7 is idle" "restart once idle" "after the queue drains" "waits for no open runs"; do
  zero_open_runs_refuse "$t" 2>/dev/null && bad "lib passed: $t" || ok "lib refuses: $t"
done
for t in "drain ONE slot" "runs open: 2" "never wait for 0 open runs (Joe #113): apply to new runs now" "0 open runs is not a gate"; do
  zero_open_runs_refuse "$t" 2>/dev/null && ok "lib passes: $t" || bad "lib refused: $t"
done
# approve.sh: the re line is checked
export APPROVALS_FILE="$T/approvals.log" SEAT_EVENT_DRY=1 EVENTS_DIR="$T/ev" SEAT_EVENT_BIN="$T/none" ZERO_GUARD_LIB="$here/.local/lib/zero-open-runs-guard.sh"
unset TMUX TMUX_PANE
out=$("$here/.local/bin/approve.sh" "go" "re: apply the cap change when idle" 2>&1); rc=$?
[ "$rc" = 66 ] && [ ! -s "$APPROVALS_FILE" ] && ok "approve.sh refuses a when-idle re line (rc 66, nothing written)" || bad "approve.sh rc=$rc: $out"
out=$("$here/.local/bin/approve.sh" "go" "re: apply the cap change to new runs now" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'new runs now' "$APPROVALS_FILE" && ok "approve.sh accepts a clean re line" || bad "approve.sh clean rc=$rc: $out"
# seat-ask.sh: dry run, fake seats table
printf '# t\ntst\trb\tsid-x\t20\t100\t^x\t-\n' >"$T/seats.tsv"
sa() { SEAT_ASK_TEST=1 SEAT_ASK_DRY=1 EVENTS_DIR="$T/ev" SEATS_TABLE="$T/seats.tsv" SEATS_TABLE_REAL="$T/none" SEAT_ASK_TICK_BIN="$T/fake-tick" SEAT_STAMP_NOW="9:07 PM" SEAT_TICK_SELFTEST=1 EVENT_SOURCE=t "$here/.local/bin/seat-ask.sh" tst "$1" 2>&1; }
out=$(sa "raise max_runs once the host is idle... wait for 0 open runs"); rc=$?
[ "$rc" = 66 ] && [[ "$out" == *"Joe #113"* ]] && ok "seat-ask.sh refuses a 0-open-runs ask (rc 66)" || bad "seat-ask.sh rc=$rc: $out"
out=$(sa "raise max_runs for new runs now"); rc=$?
[ "$rc" = 0 ] && [[ "$out" == systemd-run* ]] && ok "seat-ask.sh passes a clean ask" || bad "seat-ask.sh clean rc=$rc: $out"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fail"; fi
exit "$fail"
