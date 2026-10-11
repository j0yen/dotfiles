#!/usr/bin/env bash
# PRD dotfiles-sibling-overlap-digest AC4: a second run over unchanged sources
# leaves the digest byte-identical below the header and writes no new notice.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/sodig_test_helpers.sh"
sodig_setup

fx_commit 37 "park: x" x;   park=$LAST
fx_commit 35 "unpark: x" x; unpark=$LAST
fx_activity session-A "park $park"
fx_activity session-B "unpark $unpark"

run_digest --since 2h
assert_eq "$(grep -c '^OVERLAP:' <<<"$digest")" "1" "first run has an OVERLAP line"
assert_eq "$(notice_count)" "1" "first run wrote one notice"
first=$(grep -v '^# ' "$OUT")
sleep 1
run_digest --since 2h
assert_eq "$(grep -v '^# ' "$OUT")" "$first" "body byte-identical on re-run"
assert_eq "$(notice_count)" "1" "no new notice on re-run"
exit $fail
