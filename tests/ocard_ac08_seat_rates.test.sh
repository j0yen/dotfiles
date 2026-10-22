#!/usr/bin/env bash
# seat-rates: the card prints each seat's n20 corrected share and every seat-* alarm from fleet-dash's status.json; no file -> "seats: ?".
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
ocard_setup
fd="$work/fleet-status.json"
cat >"$fd" <<'JSON'
{"decisions":{"per_agent":{
  "rb":{"n20":20,"corrected20":8,"share":0.4,"upgrade_flag":true},
  "rb/verifier":{"n20":13,"corrected20":6,"share":0.462},
  "r7":{"n20":20,"corrected20":2,"share":0.1,"upgrade_flag":false,"held_until":"2026-10-26"},
  "controller":{"n20":1,"corrected20":0,"share":0.0,"upgrade_flag":false},
  "coder:x":{"n20":3,"corrected20":1,"share":0.333}}},
 "alarms":[{"text":"seat-upgrade rb 0.4"},{"text":"seat-upgrade-held r7 until 2026-10-26"},{"text":"chain-red x"}]}
JSON
export OPERATOR_FLEET_STATUS="$fd"
out="$("$CARD")"; assert_eq "$?" "0" "card exits 0"
assert_contains "$out" "seats (n20 corrected/n share): rb 20 8 0.4 · r7 20 2 0.1 · controller 1 0 0" "per-seat n20 corrected share"
assert_contains "$out" "  seat-upgrade rb 0.4" "seat-upgrade alarm printed"
assert_contains "$out" "  seat-upgrade-held r7 until 2026-10-26" "seat-upgrade-held alarm printed"
case "$out" in *chain-red*) echo "NOT OK - a non-seat alarm leaked into the seats block"; fail=1 ;; *) echo "ok - only seat-* alarms printed" ;; esac
case "$out" in *"coder:x"*|*"rb/verifier"*) echo "NOT OK - a non-seat bucket was printed"; fail=1 ;; *) echo "ok - only the named seats" ;; esac
assert_eq "$("$CARD" --section seats | head -1 | cut -c1-6)" "seats " "--section seats works"
export OPERATOR_FLEET_STATUS="$work/absent.json"
assert_contains "$("$CARD")" "seats: ?" "no fleet-dash status.json -> seats: ?"
echo '{"decisions":null}' >"$work/null.json"; export OPERATOR_FLEET_STATUS="$work/null.json"
assert_contains "$("$CARD")" "seats: ?" "decisions null -> seats: ?"
exit $fail
