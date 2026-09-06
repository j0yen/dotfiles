#!/usr/bin/env bash
# tests/loop_ac2_flock.test.sh — PRD-grand-loop-scaffold AC2: a second tick
# started while state.lock is held exits 0 within 2s, prints
# "skip: tick running", and writes no ledger line.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup
mkdir -p "$loop_dir"

# Hold the lock ourselves, exactly as the tick script would (fd 9, flock -n).
exec 9>"$loop_dir/state.lock"
flock -n 9 || { echo "NOT OK - test setup: could not acquire the lock itself"; exit 1; }

start=$(date +%s%N)
out="$(run_tick)"
rc=$?
end=$(date +%s%N)
elapsed_ms=$(( (end - start) / 1000000 ))

assert_eq "$rc" "0" "second tick exits 0"
assert_contains "$out" "skip: tick running" "second tick prints skip: tick running"
[ "$elapsed_ms" -lt 2000 ] && echo "ok - second tick returned within 2s (${elapsed_ms}ms)" || { echo "NOT OK - second tick took ${elapsed_ms}ms (>2s)"; fail=1; }
[ -f "$ledger" ] && { echo "NOT OK - ledger.md was created despite the held lock"; fail=1; } || echo "ok - no ledger line written"

exec 9>&-  # release our own hold
exit $fail
