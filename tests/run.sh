#!/usr/bin/env bash
# tests/run.sh - run tests/*.test.sh (or the files given as args) and print one summary line: `GLOB main n=<all> fail=<rc not 0/77> skip=<rc 77>`.
# Exit codes of a test: 0 = pass, 77 = SKIP (capability probe failed; the test printed `SKIP <test>: <reason>`), anything else = fail.
# A skip is never a pass: pass = n - fail - skip. Exit 0 only when fail=0. A TEST_RUN_TIMEOUT_S (default 600) cuts a hung test (rc 124 = fail).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "$#" -gt 0 ]; then files=("$@"); else files=("$here"/*.test.sh); fi
n=0; fail=0; skip=0
for t in "${files[@]}"; do
  [ -f "$t" ] || continue
  n=$((n+1))
  timeout "${TEST_RUN_TIMEOUT_S:-600}" bash "$t"; rc=$?
  case "$rc" in
    0) ;;
    77) skip=$((skip+1)); echo "SKIPPED $(basename "$t")";;
    *) fail=$((fail+1)); echo "FAILED $(basename "$t") rc=$rc";;
  esac
done
echo "GLOB main n=$n fail=$fail skip=$skip"
[ "$fail" = 0 ]
