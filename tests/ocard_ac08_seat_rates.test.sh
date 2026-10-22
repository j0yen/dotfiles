#!/usr/bin/env bash
# seat-rates: the card prints each seat's corrected/n share, the current-model run, at threshold / hold state, and every seat-* and verifier-rate alarm from fleet-dash's status.json; no file -> "seats: ?".
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
ocard_setup
fd="$work/fleet-status.json"
cat >"$fd" <<'JSON'
{"decisions":{"per_agent":{
  "rb":{"n20":20,"corrected20":8,"n20_all":20,"corrected_all":8,"share":0.4,"upgrade_flag":true,"held_until":"2026-10-26","n_current":20,"current_model":"claude-opus-5-5","current_since":"2026-10-21T19:02:00-07:00","status":"measured"},
  "rb/verifier":{"n20":13,"corrected20":6,"share":0.462},
  "r7":{"n20":20,"corrected20":5,"share":0.25,"upgrade_flag":null,"n_current":2,"current_model":"claude-opus-5-5","current_since":"2026-10-22T12:04:00-07:00","status":"unmeasured"},
  "controller":{"n20":20,"corrected20":9,"share":0.45,"upgrade_flag":true,"hold_expired":true,"n_current":20,"current_model":"claude-fable-5-1","current_since":"2026-10-22T11:53:00-07:00","status":"measured"},
  "coder:x":{"n20":3,"corrected20":1,"share":0.333}}},
 "alarms":[{"text":"seat-upgrade-held rb until 2026-10-26"},{"text":"seat-hold-expired controller 0.45 hold expired, flag up, awaiting Joe"},{"text":"verifier-rate rb/verifier 6/13 0.462"},{"text":"chain-red x"}]}
JSON
export OPERATOR_FLEET_STATUS="$fd" TZ=America/Los_Angeles
out="$("$CARD")"; assert_eq "$?" "0" "card exits 0"
assert_contains "$out" "  rb 8/20 0.4 (20 on claude-opus-5-5 since 7:02 pm) · held until 2026-10-26" "held seat, current-model run"
assert_contains "$out" "  r7 5/20 0.25 at threshold (2 on claude-opus-5-5 since 12:04 pm, unmeasured until 20)" "at threshold + unmeasured current-model note"
assert_contains "$out" "  controller 9/20 0.45 (20 on claude-fable-5-1 since 11:53 am) · hold expired, flag up, awaiting Joe" "expired hold with the flag up"
assert_contains "$out" "  seat-upgrade-held rb until 2026-10-26" "seat-upgrade-held alarm printed"
assert_contains "$out" "  seat-hold-expired controller 0.45" "seat-hold-expired alarm printed"
assert_contains "$out" "  verifier-rate rb/verifier 6/13 0.462" "verifier-rate alarm printed"
case "$out" in *chain-red*) echo "NOT OK - a non-seat alarm leaked into the seats block"; fail=1 ;; *) echo "ok - only seat alarms printed" ;; esac
case "$out" in *"coder:x"*|*"  rb/verifier"*) echo "NOT OK - a non-seat bucket was printed"; fail=1 ;; *) echo "ok - only the named seats" ;; esac
assert_eq "$("$CARD" --section seats | head -1 | cut -c1-6)" "seats " "--section seats works"
export OPERATOR_FLEET_STATUS="$work/absent.json"
assert_contains "$("$CARD")" "seats: ?" "no fleet-dash status.json -> seats: ?"
echo '{"decisions":null}' >"$work/null.json"; export OPERATOR_FLEET_STATUS="$work/null.json"
assert_contains "$("$CARD")" "seats: ?" "decisions null -> seats: ?"
exit $fail
