#!/usr/bin/env bash
# tests/aide-verifier-guard-skip-nodrift.test.sh: NON-hermetic no-drift guard for the load-guard skip regex. swarm-decide owns the regex (gen/merge-gate.json key
# load_guard_skip_re); aide-verifier.sh --guard-skip-re prints the one in use. When the live key is present: it must equal what --guard-skip-re prints, and the printed
# regex must round-trip through `grep -E` (the #443 golden line = 1 match, `set SYNTHORG_LOAD_GUARD=1 to run it` = 0 matches). Key absent: print SKIP-NOKEY, exit 0.
# Read-only. Run with PATH intact: bash tests/aide-verifier-guard-skip-nodrift.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../.local/bin/aide-verifier.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
GOLD='SKIPPED [1] tests/test_golden.py:163: SYNTHORG_LOAD_GUARD=1: 1-minute load average 15.17 exceeds core count 8'
EXCL='SKIPPED [1] tests/test_golden.py:163: set SYNTHORG_LOAD_GUARD=1 to run it'
wmd=$(command -v wm-decide) || { echo "SKIP-NOKEY (wm-decide is not on PATH; the live root cannot be resolved)"; exit 0; }
root=$(dirname "$(dirname "$(readlink -f "$wmd")")")
live=""
[ -f "$root/gen/merge-gate.json" ] && live=$(jq -r '.load_guard_skip_re // empty' "$root/gen/merge-gate.json" 2>/dev/null)
if [ -z "$live" ]; then echo "SKIP-NOKEY (live $root/gen/merge-gate.json has no load_guard_skip_re)"; exit 0; fi
used=$(bash "$script" --guard-skip-re); rc=$?
[ "$rc" = 0 ] && pass "--guard-skip-re exits 0 on the live key" || bad "--guard-skip-re rc=$rc (grep -E rejects the live key?)"
[ "$used" = "$live" ] && pass "--guard-skip-re equals the live load_guard_skip_re" || bad "drift: live key [$live] vs printed [$used]"
g=$(printf '%s\n' "$GOLD" | grep -cE "$used"); x=$(printf '%s\n' "$EXCL" | grep -cE "$used")
[ "$g" = 1 ] && pass "round-trip: the #443 golden line matches (1)" || bad "round-trip: golden line matched $g times"
[ "$x" = 0 ] && pass "round-trip: 'set SYNTHORG_LOAD_GUARD=1 to run it' does not match (0)" || bad "round-trip: exclusion line matched $x times"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
