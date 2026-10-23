#!/usr/bin/env bash
# tests/aide-verifier.test.sh: runs aide-verifier.sh --selftest under a throwaway HOME (fakes only: no unit, no wm-decide row,
# no seat bell, no claude), then greps the script for the anchored attribution regex and the merge-gate call. Run: bash tests/aide-verifier.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../.local/bin/aide-verifier.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
th=$(mktemp -d "${TMPDIR:-/tmp}/aide-verifier-test.XXXXXX"); trap 'rm -rf "$th"' EXIT
bash -n "$script" && pass "bash -n" || bad "bash -n"
out=$(HOME="$th" bash "$script" --selftest 2>&1); rc=$?
last=$(printf '%s\n' "$out" | tail -n1)
if [ $rc = 0 ] && [[ $last =~ ^selftest:\ ([0-9]+)/([0-9]+)\ passed$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[2]}" -ge 14 ] \
   && ! printf '%s\n' "$out" | grep -q '^FAIL'; then pass "selftest ($last)"; else bad "selftest rc=$rc"; printf '%s\n' "$out" | grep -v '^PASS' | tail -n 20; fi
grep -qF '^[[:space:]]*(co-authored-by:|generated with)' "$script" && pass "script carries the anchored attribution regex" || bad "anchored attribution regex missing"
grep -q 'merge-gate' "$script" && pass "script calls merge-gate" || bad "merge-gate missing"
grep -qF -- '--agent {{AGENT}} --via verifier --model sonnet --kind verdict --gates' "$script" && pass "prompt template records the verdict row shape" || bad "verdict row shape missing"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
