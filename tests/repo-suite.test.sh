#!/usr/bin/env bash
# repo-suite.test.sh - repo-suite.sh (the hermetic runner) and repo-suite-poll.sh (the carbon/repo-suite status poller) --selftest,
# plus the repo-suite.service/.timer shape (carbon only, ROOM-checked, 40 min start cap, idle priority, 10 min after the last poll).
# Mechanisms 4+5 of decisions/2026-10-24-dotfiles-vibecode-kit-decisions-graded-wwhtbt.md. The runner's bwrap half skips itself when this
# test runs INSIDE the repo-suite sandbox (REPO_SUITE_RUNNING=1: no nested user namespaces); a direct run exercises it.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run=$here/../.local/bin/repo-suite.sh
poll=$here/../.local/bin/repo-suite-poll.sh
unit=$here/../.config/systemd/user
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

for f in "$run" "$poll"; do
  bash -n "$f" && pass "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")"
  [ -x "$f" ] && pass "$(basename "$f") is executable" || bad "$(basename "$f") is not executable"
done

if out=$("$run" --selftest 2>&1); then pass "repo-suite.sh --selftest ($(printf '%s\n' "$out" | tail -n1))"; else bad "repo-suite.sh --selftest"; printf '%s\n' "$out" | tail -n 25; fi
if out=$("$poll" --selftest 2>&1); then pass "repo-suite-poll.sh --selftest ($(printf '%s\n' "$out" | tail -n1))"; else bad "repo-suite-poll.sh --selftest"; printf '%s\n' "$out" | tail -n 30; fi

"$poll" --bogus >/dev/null 2>&1; [ $? -eq 64 ] && pass "poll: unknown flag -> 64" || bad "poll: unknown flag -> 64"
"$run" >/dev/null 2>&1; [ $? -eq 64 ] && pass "runner: no args -> 64" || bad "runner: no args -> 64"

# the runner keeps the measured budget and the v84 SKIP list the 10-24 falsifier ran with
grep -q 'PERTEST=${PERTEST:-300}' "$run" && grep -q 'WALLCAP=${WALLCAP:-1200}' "$run" && pass "runner budget: PERTEST 300 s, WALLCAP 1200 s" || bad "runner budget"
for t in aide-inbox seat-time-stamp aide-verifier-gate-nodrift vibeloop-ctl-claim; do
  sed -n '/^SKIPN=/,/^FLAKY=/p' "$run" | grep -qw -- "$t" && pass "runner SKIP list has $t" || bad "runner SKIP list lacks $t"
done
for c in systemctl systemd-run gh ssh wm-build wm-decide synthorg agorabus tmux; do
  grep -q "^STUBS=.*\b$c\b" "$run" && pass "runner stubs $c (exit 99)" || bad "runner does not stub $c"
done

# units: carbon only, ROOM first, capped start, idle priority, 10 min after the previous poll finished
s=$unit/repo-suite.service t=$unit/repo-suite.timer
grep -q '^ExecCondition=.*hostname -s.* = carbon' "$s" && pass "service: ExecCondition hostname = carbon" || bad "service: hostname condition"
grep -q '^ExecCondition=.*carbon-room\.sh 1536' "$s" && pass "service: ExecCondition ROOM (carbon-room.sh 1536 = 1.5 G + the 3 G reserve)" || bad "service: ROOM condition"
grep -qx 'TimeoutStartSec=40min' "$s" && grep -qx 'IOSchedulingClass=idle' "$s" && grep -qx 'Type=oneshot' "$s" && grep -q '^Nice=' "$s" && pass "service: oneshot, TimeoutStartSec=40min, Nice, IOSchedulingClass=idle" || bad "service fields"
grep -q 'ExecStart=.*\.local/bin/repo-suite-poll\.sh"$' "$s" && pass "service: runs repo-suite-poll.sh" || bad "service ExecStart"
grep -qx 'OnUnitInactiveSec=10min' "$t" && grep -qx 'OnBootSec=5min' "$t" && grep -qx 'WantedBy=timers.target' "$t" && pass "timer: OnBootSec=5min OnUnitInactiveSec=10min" || bad "timer fields"
grep -rn 'repo-suite\.timer' "$here/../install.sh" >/dev/null 2>&1 && bad "install.sh must not enable repo-suite.timer (carbon only, enabled by hand)" || pass "install.sh does not enable the repo-suite timer"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
