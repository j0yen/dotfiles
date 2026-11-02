#!/usr/bin/env bash
# no-drift: aide-launch.sh and seat-event.sh take the lane rule from .local/lib/aide-lane.sh only (one source).
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"; fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
. "$R/.local/lib/aide-lane.sh"
[ "$AIDE_LANE_RE" = '^[a-z][a-z0-9-]{0,15}$' ] && ok "AIDE_LANE_RE is the pinned rule" || bad "regex changed: $AIDE_LANE_RE"
for g in main build a a-b0 abcdefghijklmno; do aide_lane_valid "$g" && ok "valid '$g'" || bad "rejected '$g'"; done
for b in '' Build 1x -x a_b a/b .. abcdefghijklmnopq 'a b'; do aide_lane_valid "$b" && bad "accepted '$b'" || ok "rejects '$b'"; done
for f in .local/bin/aide-launch.sh .local/bin/seat-event.sh; do
  grep -q 'aide-lane.sh' "$R/$f" && grep -q 'aide_lane_valid' "$R/$f" && ok "$f sources the lib and calls aide_lane_valid" || bad "$f not wired to the lib"
  grep -nE '\[A-Za-z0-9_-\]\{1,32\}|\[a-z\]\[a-z0-9-\]' "$R/$f" | grep -v '^.*#' >/dev/null && bad "$f carries its own lane regex" || ok "$f has no private lane regex"
done
exit $fail
