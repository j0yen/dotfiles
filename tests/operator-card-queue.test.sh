#!/usr/bin/env bash
# queue: the card prints `queue: N (building B, ready R[, blocked X][, parked P])` from fleet-dash status.json `.queue`
# (the carbon wm-build journal has had no tick rows since build ops moved to RedBaron); stale (ts > 180 s) or absent -> `queue: ?`.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
ocard_setup
fd="$OPERATOR_FLEET_STATUS"
regen() { rm -f "$OPERATOR_CACHE_DIR/status.json"; }
now=$(date +%s)

regen
assert_eq "$("$CARD" --section queue)" "queue: 12 (building 2, ready 5, blocked 3, parked 2)" "fresh fleet queue -> numbers"
assert_eq "$(jq -r '.sources.queue' "$OPERATOR_CACHE_DIR/status.json")" "ok" "sources.queue ok when fresh"
assert_contains "$("$CARD")" "queue: 12 (building 2, ready 5" "full card carries the line"

printf '{"ts":%s,"queue":{"queue_total":7,"queue_ready":4,"building":1}}\n' "$now" >"$fd"; regen
assert_eq "$("$CARD" --section queue)" "queue: 7 (building 1, ready 4)" "blocked/parked absent -> omitted"

printf '{"ts":%s,"queue":{"queue_total":7,"queue_ready":4,"building":1,"blocked":0}}\n' "$now" >"$fd"; regen
assert_eq "$("$CARD" --section queue)" "queue: 7 (building 1, ready 4, blocked 0)" "blocked 0 is printed"

printf '{"ts":%s,"queue":{"queue_total":12,"queue_ready":5,"building":2}}\n' "$((now-600))" >"$fd"; regen
assert_eq "$("$CARD" --section queue)" "queue: ?" "stale ts (600 s) -> queue: ?"
assert_eq "$(jq -r '.sources.queue' "$OPERATOR_CACHE_DIR/status.json")" "stale" "sources.queue stale"

printf '{"ts":%s}\n' "$now" >"$fd"; regen
assert_eq "$("$CARD" --section queue)" "queue: ?" "no .queue field -> queue: ?"
assert_eq "$(jq -r '.sources.queue' "$OPERATOR_CACHE_DIR/status.json")" "missing" "sources.queue missing (field)"

export OPERATOR_FLEET_STATUS="$work/absent.json"; regen
assert_eq "$("$CARD" --section queue)" "queue: ?" "no fleet status.json -> queue: ?"
assert_eq "$(jq -r '.sources.queue' "$OPERATOR_CACHE_DIR/status.json")" "missing" "sources.queue missing (file)"
exit $fail
