#!/usr/bin/env bash
# worker-route-hygiene.test.sh (R3-5): the worker-route test scripts and the mutation runner refuse to scratch under /tmp; fixtures never touch it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0
ok(){ echo "PASS $1"; }; bad(){ echo "FAIL $1"; fails=$((fails+1)); }
for s in worker-route.test.sh worker-route-probes.test.sh worker-route-review3.test.sh; do
  before="$(ls -d /tmp/wr.* 2>/dev/null | wc -l)"
  out="$(env -u WR_TEST_TMP TMPDIR=/tmp timeout 20 bash "$HERE/$s" 2>&1)"; rc=$?
  after="$(ls -d /tmp/wr.* 2>/dev/null | wc -l)"
  if [ "$rc" = 64 ] && [ "$before" = "$after" ] && echo "$out" | grep -q "outside /tmp"; then ok "$s refuses a /tmp scratch (exit 64, nothing created under /tmp)"; else bad "$s refuses a /tmp scratch: rc=$rc"; fi
done
out="$(env -u WR_MUT_BASE python3 -I "$HERE/seatret-probes/mutate.py" 2>&1)"; rc=$?
if [ "$rc" = 64 ] && echo "$out" | grep -q "outside /tmp"; then ok "mutate.py has no default scratch under /tmp (exit 64 without WR_MUT_BASE)"; else bad "mutate.py without WR_MUT_BASE: rc=$rc"; fi
if grep -qE 'or "/tmp|mktemp -d\)|mkdtemp\(prefix' "$HERE"/worker-route.test.sh "$HERE"/worker-route-probes.test.sh "$HERE"/worker-route-review3.test.sh "$HERE"/seatret-probes/*.py "$HERE"/seatret-probes/review3/*.py 2>/dev/null; then bad "a test file still names /tmp or an unrooted mktemp"; else ok "no test file names /tmp or an unrooted mktemp"; fi
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
