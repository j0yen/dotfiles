#!/usr/bin/env bash
# PRD dotfiles-operator-status-card AC5: two files in notices/ print in name
# order on the first run and nothing on the second; an empty dir prints
# nothing and exits 0; a notice older than 24 h is deleted unread.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export OPERATOR_CACHE_DIR="$work"
n="$work/notices"; mkdir -p "$n"
echo "second notice" >"$n/20261011-b.txt"
echo "first notice" >"$n/20261011-a.txt"
out1="$(printf '{"prompt":"hi"}' | "$NOTICES")"; assert_eq "$?" "0" "first run exits 0"
assert_eq "$out1" "$(printf 'first notice\nsecond notice')" "first run prints both in name order"
assert_eq "$(ls "$n" | wc -l)" "0" "notices deleted after printing"
out2="$(printf '{"prompt":"hi"}' | "$NOTICES")"; assert_eq "$?" "0" "second run exits 0"
assert_eq "$out2" "" "second run prints nothing"
"$NOTICES" >"$work/o" 2>"$work/e"; rc=$?
assert_eq "$rc/$(wc -c <"$work/o")/$(wc -c <"$work/e")" "0/0/0" "empty dir: exit 0, no stdout, no stderr"
echo "stale" >"$n/old.txt"; touch -d '25 hours ago' "$n/old.txt"
echo "fresh" >"$n/new.txt"
assert_eq "$("$NOTICES")" "fresh" "a >24 h notice is dropped unread"
assert_eq "$(ls "$n" | wc -l)" "0" "directory drained"
rm -rf "$n"; "$NOTICES" >"$work/o"; assert_eq "$?/$(wc -c <"$work/o")" "0/0" "missing dir: exit 0, silent"
exit $fail
