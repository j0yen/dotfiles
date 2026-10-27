#!/usr/bin/env bash
# tests/token-ledger-aide-lanes.test.sh — aide-lanes step 5: per-lane tokens in token-ledger.
# aide-sids lines: bare sid (= main), `<sid> main since=T`, `<sid> build since=T`, and a build sid whose rows straddle T (only the post-T rows are
# charged to the lane; earlier rows keep the role they would have had without the sids line). Hermetic: temp state/jsonl/aide-sids/seats, fixed NOW.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ledgerday_test_helpers.sh"
ledgerday_setup   # NOW=2026-09-12T10:15:00Z, today = 2026-09-12
export SEATS_TABLE="$work/seats.tsv"; printf '# seat\trole\tsid\ttick_min\n' >"$SEATS_TABLE"
export TOKEN_LEDGER_AIDE_SIDS="$work/aide-sids"
T0="$(date -u -d 2026-09-12T08:00:00Z +%s)"; T1="$(date -u -d 2026-09-12T09:00:00Z +%s)"
printf 'sid-mainbare\nsid-mainsince main since=%s\nsid-builda build since=%s\nsid-straddle build since=%s\n' "$T0" "$T0" "$T1" >"$TOKEN_LEDGER_AIDE_SIDS"
rec() { # file id ts in
  mkdir -p "$(dirname "$jsonl/$1")"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"m","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$3" "$2" "$4" >>"$jsonl/$1"
}
usr() { mkdir -p "$(dirname "$jsonl/$1")"; printf '{"type":"user","uuid":"u-%s","timestamp":"%s","message":{"content":"hello"}}\n' "$1" "$2" >>"$jsonl/$1"; }
D=-home-jsy
usr $D/sid-mainbare.jsonl 2026-09-12T07:00:00Z;   rec $D/sid-mainbare.jsonl m1 2026-09-12T09:00:00Z 20000000
usr $D/sid-mainsince.jsonl 2026-09-12T07:00:00Z;  rec $D/sid-mainsince.jsonl m2 2026-09-12T09:00:00Z 10000000
usr $D/sid-builda.jsonl 2026-09-12T07:00:00Z;     rec $D/sid-builda.jsonl m3 2026-09-12T09:00:00Z 30000000
usr $D/sid-straddle.jsonl 2026-09-12T07:00:00Z;   rec $D/sid-straddle.jsonl m4 2026-09-12T08:30:00Z 40000000; rec $D/sid-straddle.jsonl m5 2026-09-12T09:30:00.250Z 20000000
# main 30M, build 30M + 20M (post-T1 rows only) = 50M, straddle pre-T1 40M stays interactive (excluded) -> denominator 80M
run() { env AIDE_LANE_ALARM_PCT="$1" "$TL" >/dev/null 2>&1; }
run 50
pr="$(ledger_field 2026-09-12 12)"
assert_eq "$pr" "interactive=40000000;seat:aide=30000000;seat:aide:build=50000000" "per_role: main 30M, build 50M (post-since rows only), pre-since straddle rows stay interactive"
line1="$(head -n1 "$state/today-summary.txt")"
assert_contains "$line1" " · aide main=37% build=62%" "TOKENS line carries one entry per lane seen today"
assert_contains "$line1" "build_share 100% (coder+inner+seats 80M of 80M; interactive 40M excluded)" "build_share counts lane tokens as building (80M of 80M), unchanged by the lane split"
bs="$state/build-share.json"
assert_eq "$(jq -r '.build_share' "$bs")" "100.0" "build-share.json build_share is the same with or without the lane split"
assert_eq "$(jq -c '.aide_lanes' "$bs")" '{"main":{"tokens":30000000,"pct":37},"build":{"tokens":50000000,"pct":62}}' "build-share.json aide_lanes keys main + build"
assert_eq "$(jq -r '.build_roles_re' "$bs")" '^(coder|inner|seat:(ctl|rb|r7|aide(:[A-Za-z0-9._-]+)?))$' "BUILD_ROLES_RE admits aide lanes"
assert_contains "$(cat "$state/today-summary.txt")" "ALARM aide_lane build 62% > 50% — one lane is eating the day" "default X=50: build lane 62% alarms"
assert_not_contains "$(cat "$state/today-summary.txt")" "aide_lane main" "default X=50: main 37% does not alarm"
run 10
assert_contains "$(cat "$state/today-summary.txt")" "ALARM aide_lane main 37% > 10%" "AIDE_LANE_ALARM_PCT=10: alarm for main"
assert_contains "$(cat "$state/today-summary.txt")" "ALARM aide_lane build 62% > 10%" "AIDE_LANE_ALARM_PCT=10: alarm for build"
run 90
assert_not_contains "$(cat "$state/today-summary.txt")" "aide_lane" "AIDE_LANE_ALARM_PCT=90: no lane alarm"
# no lane column at all (bare main sids only): no suffix, no alarm, empty aide_lanes
rm -rf "$state"/* "$jsonl"/*; printf 'sid-mainbare\n' >"$TOKEN_LEDGER_AIDE_SIDS"
usr $D/sid-mainbare.jsonl 2026-09-12T07:00:00Z; rec $D/sid-mainbare.jsonl m1 2026-09-12T09:00:00Z 20000000
run 50
assert_eq "$(ledger_field 2026-09-12 12)" "seat:aide=20000000" "bare sid keeps today's role seat:aide"
assert_contains "$(head -n1 "$state/today-summary.txt")" " · aide main=100%" "main-only day: a single main entry"
assert_eq "$(jq -c '.aide_lanes' "$state/build-share.json")" '{"main":{"tokens":20000000,"pct":100}}' "main-only aide_lanes"
exit $fail
