#!/usr/bin/env bash
# carbon-room.test.sh - runs carbon-room.sh --selftest and the real call (100 MB must be ok here).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../.local/bin/carbon-room.sh
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

if out=$("$script" --selftest 2>&1); then pass "selftest ($(printf '%s\n' "$out" | tail -n1))"; else
  bad "selftest"; printf '%s\n' "$out" | tail -n 20
fi

# real call: state/ledger go to a throwaway dir so the test does not pollute the live audit trail
d=$(mktemp -d "${TMPDIR:-/tmp}/carbon-room-test.XXXXXX")
trap 'rm -rf "$d"' EXIT
out=$(CARBON_ROOM_HOST=carbon CARBON_ROOM_CALLER=carbon-room.test CARBON_ROOM_STATE="$d/s.json" \
  CARBON_ROOM_LEDGER="$d/l.jsonl" "$script" 100 2>&1); rc=$?
if [ $rc -eq 0 ] && [[ $out == room\ ok:* ]]; then pass "real call 100 MB: $out"; else bad "real call 100 MB rc=$rc: $out"; fi
[ -s "$d/s.json" ] && pass "real call wrote state" || bad "real call wrote no state"
[ -s "$d/l.jsonl" ] && pass "real call wrote ledger" || bad "real call wrote no ledger"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
