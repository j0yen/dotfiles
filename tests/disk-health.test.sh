#!/usr/bin/env bash
# disk-health.test.sh - disk-health.sh --selftest (fake smartctl/nvme/lsblk/df/journalctl/sudo on a sandbox PATH: healthy,
# FAILED + kernel I/O + 100 % inodes, needs-sudo, no tools) plus the unit pair's shape. No sudo, no real smartctl is run.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../.local/bin/disk-health.sh
unit=$here/../.config/systemd/user
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

bash -n "$script" && pass "bash -n" || bad "bash -n"
[ -x "$script" ] && pass "script is executable" || bad "script is not executable"

if out=$("$script" --selftest 2>&1); then pass "selftest ($(printf '%s\n' "$out" | tail -n1))"; else
  bad "selftest"; printf '%s\n' "$out" | tail -n 25
fi

# usage error is 64, never a collect
"$script" --bogus >/dev/null 2>&1; [ $? -eq 64 ] && pass "unknown flag -> 64" || bad "unknown flag -> 64"

# --summary on a missing file never fails and never collects
out=$(DISK_HEALTH_OUT=/nonexistent/dh.json "$script" --summary 2>&1); rc=$?
if [ $rc -eq 0 ] && [[ $out == "disk-health: no data"* ]]; then pass "--summary with no file"; else bad "--summary with no file rc=$rc: $out"; fi

# units: the timer is 3 min after boot, every 15 min, persistent; the service runs this script
t=$unit/disk-health.timer s=$unit/disk-health.service
grep -qx 'OnBootSec=3min' "$t" && grep -qx 'OnUnitActiveSec=15min' "$t" && grep -qx 'Persistent=true' "$t" && grep -qx 'WantedBy=timers.target' "$t" \
  && pass "timer: OnBootSec=3min OnUnitActiveSec=15min Persistent=true" || bad "timer fields"
grep -qx 'Type=oneshot' "$s" && grep -q 'ExecStart=.*\.local/bin/disk-health\.sh"$' "$s" && pass "service: oneshot running disk-health.sh" || bad "service fields"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
