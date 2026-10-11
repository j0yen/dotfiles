#!/usr/bin/env bash
# PRD dotfiles-sibling-overlap-digest AC2: B's commit 45 min after A's is
# outside the 30-minute window -> overlaps: 0 and no notice.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/sodig_test_helpers.sh"
sodig_setup

fx_commit 100 "park: x y" x y;   park=$LAST
fx_commit 55 "unpark: x y" x y;  unpark=$LAST
fx_activity session-A "park $park"
fx_activity session-B "unpark $unpark"

run_digest --since 3h
assert_eq "$rc" "0" "exit 0"
assert_eq "$(tail -1 <<<"$digest")" "overlaps: 0" "overlaps: 0"
assert_eq "$(grep -c '^OVERLAP:' <<<"$digest")" "0" "no OVERLAP line"
assert_eq "$(notice_count)" "0" "no notice written"
exit $fail
