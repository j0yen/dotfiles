#!/usr/bin/env bash
# tests/aide-inbox-dead-alarm.test.sh: aide-inbox-dead-alarm.sh --selftest (fake log + cursor in a throwaway dir) plus the script carries PREMISE and a 30 min default window. Run: bash tests/aide-inbox-dead-alarm.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
w="$here/.local/bin/aide-inbox-dead-alarm.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
bash -n "$w" && pass "bash -n aide-inbox-dead-alarm.sh" || bad "bash -n aide-inbox-dead-alarm.sh"
out=$(bash "$w" --selftest 2>&1); rc=$?; last=$(printf '%s\n' "$out" | tail -n1)
if [ $rc = 0 ] && [[ $last =~ ^selftest:\ ([0-9]+)/([0-9]+)\ passed$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[2]}" -ge 10 ] && ! printf '%s\n' "$out" | grep -q '^FAIL'; then pass "selftest ($last)"
else bad "selftest rc=$rc"; printf '%s\n' "$out" | grep -v '^PASS' | tail -n 20; fi
grep -q '^# PREMISE: ' "$w" && pass "script carries PREMISE" || bad "PREMISE missing"
grep -q 'AIDE_INBOX_DEAD_WINDOW_MIN:-30' "$w" && pass "default window 30 min" || bad "default window"
bash "$w" --bogus >/dev/null 2>&1; [ $? = 64 ] && pass "bad arg exits 64" || bad "bad arg exit"
exit $fail
