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

# 6 h kernel window (producer-side filter): journal fixture via the DISK_HEALTH_JOURNAL_FILE seam, journalctl -o short-unix lines; sandbox PATH has python3 only
sb=$(mktemp -d "${TMPDIR:-/tmp}/dh-test.XXXXXX"); mkdir -p "$sb/bin"; ln -s "$(readlink -f "$(command -v python3)")" "$sb/bin/python3"
now=$(date +%s); : >"$sb/fstab"
win() { # win <name> <journal-file>  -> prints the json path
  env -i HOME="$sb" PATH="$sb/bin" DISK_HEALTH_OUT="$sb/$1.json" DISK_HEALTH_HOST=fx DISK_HEALTH_EXTRA_PATH= DISK_HEALTH_JOURNAL_FILE="$2" \
    DISK_HEALTH_FSTAB="$sb/fstab" DISK_HEALTH_BYUUID_DIR="$sb" "$BASH" "$script" >/dev/null 2>&1
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["kernel_io_errors_since_boot"], d["kernel_io_errors_6h"], d["kernel_io_errors_24h"], d["kernel_window_unfiltered"])' "$sb/$1.json"
}
printf '%s.000000 fx kernel: blk_update_request: I/O error, dev sdb, sector 1\n%s.000000 fx kernel: usb 1-9: new device\n' "$((now - 40 * 3600))" "$((now - 60))" >"$sb/old.j"
printf '%s.000000 fx kernel: blk_update_request: I/O error, dev sdb, sector 1\n%s.000000 fx kernel: blk_update_request: I/O error, dev sdc, sector 2\n' "$((now - 40 * 3600))" "$((now - 600))" >"$sb/new.j"
got=$(win old "$sb/old.j"); [ "$got" = "1 0 0 False" ] && pass "journal error 40 h old: since_boot 1, 6h 0, 24h 0 (window filter)" || bad "old-error fixture: got '$got'"
got=$(win new "$sb/new.j"); [ "$got" = "2 1 1 False" ] && pass "journal error 10 min old: since_boot 2, 6h 1, 24h 1" || bad "new-error fixture: got '$got'"
rm -rf "$sb"

# units: the timer is 3 min after boot, every 15 min, persistent; the service runs this script
t=$unit/disk-health.timer s=$unit/disk-health.service
grep -qx 'OnBootSec=3min' "$t" && grep -qx 'OnUnitActiveSec=15min' "$t" && grep -qx 'Persistent=true' "$t" && grep -qx 'WantedBy=timers.target' "$t" \
  && pass "timer: OnBootSec=3min OnUnitActiveSec=15min Persistent=true" || bad "timer fields"
grep -qx 'Type=oneshot' "$s" && grep -q 'ExecStart=.*\.local/bin/disk-health\.sh"$' "$s" && pass "service: oneshot running disk-health.sh" || bad "service fields"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
