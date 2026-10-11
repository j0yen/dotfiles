#!/usr/bin/env bash
# PRD dotfiles-sibling-overlap-digest AC1: the 10-08 11:00/11:47/11:49/11:54 pm
# commits (park by session A, unpark by session B, 2 min apart, two slugs)
# yield one OVERLAP line per slug naming A, B, park, unpark, "2 min", and
# `overlaps: 2`.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/sodig_test_helpers.sh"
sodig_setup

fx_commit 84 "chore: claim z (run=500)" z                       # 11:00 pm
fx_commit 37 "park: x y (blocked on 517)" x y;   park=$LAST      # 11:47 pm
fx_commit 35 "unpark: x y (517 landed)" x y;     unpark=$LAST    # 11:49 pm
fx_commit 30 "archive: z" z                                     # 11:54 pm
fx_activity session-A "park $park"
fx_activity session-B "unpark $unpark"

run_digest --since 2h
assert_eq "$rc" "0" "exit 0"
assert_eq "$(grep -c '^OVERLAP:' <<<"$digest")" "2" "one OVERLAP line per parked slug"
for s in x y; do
  line=$(grep "^OVERLAP: $s " <<<"$digest")
  for needle in session-A session-B park unpark "2 min"; do
    assert_contains "$line" "$needle" "slug $s line names $needle"
  done
done
assert_eq "$(tail -1 <<<"$digest")" "overlaps: 2" "last line is overlaps: 2"
exit $fail
