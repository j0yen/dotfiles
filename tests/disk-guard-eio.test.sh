#!/usr/bin/env bash
# disk-guard-eio.test.sh - redbaron-disk-guard-v3.sh exits 3 + prints `EIO dev=<dev> n=<n>` on kernel I/O error lines (0 when clean);
# disk-health.sh counts the sdc1 `EXT4-fs warning ... error -5` shape and re-rings an open RED every 60 min. Literal fixture lines, no journal reads.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard=$here/../.local/bin/redbaron-disk-guard-v3.sh
dh=$here/../.local/bin/disk-health.sh
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
d=$(mktemp -d "${TMPDIR:-/tmp}/disk-guard-eio.XXXXXX") || exit 1
trap 'rm -rf "$d"' EXIT

run_guard() { DISK_GUARD_EIO_FILE=$1 DISK_GUARD_EIO_ONLY=1 DISK_GUARD_EIO_STATE=$d/state "$guard"; }

W='Oct 29 03:12:44 redbaron kernel: EXT4-fs warning (device sdc1): ext4_dx_find_entry:1705: inode #2: lblock 0: comm ls: error -5 reading directory block'
printf '%s\n' 'Oct 29 03:00:01 redbaron kernel: blk_update_request: I/O error, dev sda, sector 4096 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 0' \
  'Oct 29 03:00:01 redbaron kernel: Buffer I/O error on dev sda1, logical block 512, async page read' >"$d/sda"
printf '%s\n' 'Oct 29 03:00:02 redbaron systemd[1]: Started Session 4 of User jsy.' >"$d/clean"
printf '%s\n' "$W" >"$d/sdc"

out=$(run_guard "$d/sda"); rc=$?
[ $rc -eq 3 ] && pass "sda EIO -> rc 3" || bad "sda EIO rc=$rc"
echo "$out" | grep -qx 'EIO dev=sda n=1' && echo "$out" | grep -qx 'EIO dev=sda1 n=1' && pass "sda EIO lines printed per dev" || bad "sda output: $out"
out=$(run_guard "$d/clean"); rc=$?
{ [ $rc -eq 0 ] && [ -z "$out" ]; } && pass "clean -> rc 0, silent" || bad "clean rc=$rc out=$out"
out=$(run_guard "$d/sdc"); rc=$?
{ [ $rc -eq 3 ] && [ "$out" = "EIO dev=sdc1 n=1" ]; } && pass "sdc1 EXT4-fs warning error -5 -> EIO dev=sdc1 n=1" || bad "sdc1 rc=$rc out=$out"

# disk-health KERNEL_RE counts that exact line
[ "$("$dh" --grep-kernel <"$d/sdc" | wc -l)" -eq 1 ] && pass "disk-health regex matches the sdc1 warning shape" || bad "disk-health regex misses sdc1 warning"
[ "$("$dh" --grep-kernel <"$d/clean" | wc -l)" -eq 0 ] && pass "disk-health regex ignores a clean line" || bad "disk-health regex matched a clean line"

# re-ring: RED older than 60 min rings again, younger does not, recovered clears the state
echo '{"devices":[],"kernel_io_errors_since_boot":285,"max_bytes_level":"ok"}' >"$d/red.json"
echo '{"devices":[],"kernel_io_errors_since_boot":0,"max_bytes_level":"ok"}' >"$d/ok.json"
ring() { DISK_HEALTH_RING_STATE=$d/ring.json DISK_HEALTH_NOW=$1 "$dh" --ring-eval "$2"; }
[ "$(ring 10000 "$d/red.json")" = "RING disk-health RED kernel-io" ] && pass "new RED rings" || bad "new RED did not ring"
[ "$(ring 11000 "$d/red.json")" = quiet ] && pass "RED 1000 s old does not re-ring" || bad "RED re-rang early"
[ "$(ring 13601 "$d/red.json")" = "RING disk-health RED kernel-io" ] && pass "RED older than 60 min re-rings" || bad "RED did not re-ring after 60 min"
[ "$(ring 13700 "$d/ok.json")" = quiet ] && [ ! -e "$d/ring.json" ] && pass "recovery clears ring state" || bad "recovery left ring state"

exit $fail
