#!/usr/bin/env bash
# PRD dotfiles-operator-status-card AC3: no agorabus on PATH and no synthorg
# state dir -> generator exits 0, siblings null with sources.siblings
# "missing", and the card prints "chain: not on this host (orch)".
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
ocard_setup
rm -f "$work/bin/agorabus"; rm -rf "$work/syn"
# PATH without any agorabus: the fixture bin (systemctl, wm-build) plus system dirs only
# (plus wherever sqlite3 lives: the runs/config sources need it and are not what this test removes)
sqld=$(dirname "$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)")
export PATH="$work/bin:$sqld:/usr/bin:/bin"
command -v agorabus >/dev/null 2>&1 && { echo "SKIP - a real agorabus lives in /usr/bin"; exit 0; }
t="$work/t.json"
"$GEN" --out "$t"; assert_eq "$?" "0" "generator exits 0"
assert_eq "$(jq -c '.siblings' "$t")" "null" "siblings null"
assert_eq "$(jq -r '.sources.siblings' "$t")" "missing" "sources.siblings = missing"
assert_eq "$(jq -r '.sources.chain' "$t")" "missing" "sources.chain = missing"
assert_eq "$(jq -r '.sources.runs' "$t")" "ok" "other sources unaffected"
rm -f "$OPERATOR_CACHE_DIR/status.json"
out="$("$CARD")"; assert_eq "$?" "0" "card exits 0"
assert_contains "$out" "chain: not on this host (orch)" "card prints the named-host chain line"
exit $fail
