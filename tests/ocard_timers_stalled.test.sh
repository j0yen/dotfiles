#!/usr/bin/env bash
# timers: the card prints `timers: ok` / `timers: STALLED n (host unit reason, ...)` from fleet-dash status.json `timers_stalled`, and `timers: ?` when the file or the field is absent (older collector).
# Five-whys 2026-10-24: a wiped OnBootSec left seat-tick@* and the regrader unarmed; the controller sweep reads this line.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
ocard_setup
fd="$work/fleet-status.json"; export TZ=America/Los_Angeles
export OPERATOR_FLEET_STATUS="$fd"
echo '{"timers_stalled":[]}' >"$fd"
assert_contains "$("$CARD")" "timers: ok" "empty timers_stalled -> timers: ok"
assert_eq "$("$CARD" --section timers)" "timers: ok" "--section timers works"
echo '{"timers_stalled":[{"host":"redbaron","unit":"claude-vibeloop.timer","reason":"no_next"},{"host":"redbaron","unit":"claude-vibeloop.timer","reason":"stale_last"},{"host":"carbon","unit":"seat-tick@rb.timer","reason":"no_next"}]}' >"$fd"
assert_eq "$("$CARD" --section timers)" "timers: STALLED 3 (redbaron claude-vibeloop.timer no_next, redbaron claude-vibeloop.timer stale_last, carbon seat-tick@rb.timer no_next)" "stalled entries listed as host unit reason"
assert_contains "$("$CARD")" "timers: STALLED 3" "full card carries the line"
echo '{"decisions":null}' >"$fd"
assert_eq "$("$CARD" --section timers)" "timers: ?" "field absent -> timers: ?"
export OPERATOR_FLEET_STATUS="$work/absent.json"
assert_eq "$("$CARD" --section timers)" "timers: ?" "no status.json -> timers: ?"
exit $fail
