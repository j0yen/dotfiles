#!/usr/bin/env bash
# aide-lanes step 3b (i): handoff-gen.sh under WM_SEAT=aide WM_AIDE_LANE=<lane> writes handoff-generated-<host>-<lane>.md, never the per-host file,
# and leaves MEMORY.md byte-identical; main/unset keep today's file name and the index line (added once).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/hgen_test_helpers.sh"
hgen_setup
m="$HANDOFF_MEMORY_DIR/MEMORY.md"; host="$(hostname -s 2>/dev/null || echo unknown)"
printf '%s\n' '- [first](a.md) — one' '- [last](c.md) — end' >"$m"; cp "$m" "$work/before.md"
env WM_SEAT=aide WM_AIDE_LANE=build "$HGEN"
[ -s "$HANDOFF_MEMORY_DIR/handoff-generated-$host-build.md" ]; assert_eq "$?" "0" "lane build: handoff-generated-$host-build.md written"
[ ! -e "$HANDOFF_MEMORY_DIR/handoff-generated-$host.md" ]; assert_eq "$?" "0" "lane build: per-host handoff-generated-$host.md absent (main's file never clobbered)"
assert_eq "$(cmp "$m" "$work/before.md" && echo same)" "same" "lane build: MEMORY.md byte-identical (no index block)"
rm -f "$HANDOFF_MEMORY_DIR"/handoff-generated-*
env WM_SEAT=aide WM_AIDE_LANE=main "$HGEN"
[ -s "$HANDOFF_MEMORY_DIR/handoff-generated-$host.md" ] && [ ! -e "$HANDOFF_MEMORY_DIR/handoff-generated-$host-main.md" ]; assert_eq "$?" "0" "lane main: today's per-host file name"
assert_eq "$(grep -c 'handoff-generated-' "$m")" "1" "lane main: index line added once"
rm -f "$HANDOFF_MEMORY_DIR"/handoff-generated-*; cp "$work/before.md" "$m"
env -u WM_AIDE_LANE -u WM_SEAT "$HGEN"; env -u WM_AIDE_LANE -u WM_SEAT "$HGEN"
[ -s "$HANDOFF_MEMORY_DIR/handoff-generated-$host.md" ]; assert_eq "$?" "0" "unset lane: today's per-host file"
assert_eq "$(grep -c 'handoff-generated-' "$m")" "1" "unset lane: index line present exactly once after two runs"
rm -f "$HANDOFF_MEMORY_DIR"/handoff-generated-*
env -u WM_SEAT WM_AIDE_LANE=build "$HGEN"
[ -s "$HANDOFF_MEMORY_DIR/handoff-generated-$host.md" ] && [ ! -e "$HANDOFF_MEMORY_DIR/handoff-generated-$host-build.md" ]; assert_eq "$?" "0" "WM_AIDE_LANE without WM_SEAT=aide: lane ignored"
exit $fail
