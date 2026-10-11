#!/usr/bin/env bash
# PRD dotfiles-handoff-generated AC5: settings.json wires handoff-gen.sh once,
# in SessionEnd after agorabus-session-end.sh; every pre-existing SessionEnd
# entry (tests/fixtures/hgen-sessionend-before.json) is unchanged and in order.
# R5: operator-status-gen.sh refreshes a > 20 min old handoff, not a fresh one.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/hgen_test_helpers.sh"
S="$ROOT/.claude/settings.json"
B="$ROOT/tests/fixtures/hgen-sessionend-before.json"
jq -e . "$S" >/dev/null || { echo "NOT OK - settings.json parses"; exit 1; }
se='[.hooks.SessionEnd[].hooks[].command]'
assert_eq "$(jq -r "$se | map(select(test(\"handoff-gen[.]sh\"))) | length" "$S")" "1" "handoff-gen.sh once in SessionEnd"
assert_eq "$(jq -r '[.hooks[][].hooks[].command | select(test("handoff-gen[.]sh"))] | length' "$S")" "1" "handoff-gen.sh once overall"
pos() { jq -r "$se | map(test(\"$1\")) | index(true) // -1" "$S"; }
[ "$(pos 'handoff-gen[.]sh')" -gt "$(pos 'agorabus-session-end[.]sh')" ] && [ "$(pos 'agorabus-session-end[.]sh')" -ge 0 ] \
  && echo "ok - after agorabus-session-end.sh" || { echo "NOT OK - not after agorabus-session-end.sh"; fail=1; }
assert_eq "$(jq -c ".hooks.SessionEnd | map(.hooks |= map(select(.command | test(\"handoff-gen[.]sh\") | not)))" "$S")" "$(cat "$B")" "pre-existing SessionEnd entries unchanged, in order"
[ -x "$HGEN" ] && echo "ok - handoff-gen.sh executable" || { echo "NOT OK - not executable"; fail=1; }
# install.sh walks the repo and links every file: the script gets linked
assert_contains "$("$ROOT/install.sh" --dry-run 2>&1)" ".claude/scripts/handoff-gen.sh" "install.sh links the script (dry run)"

# R5: status regeneration refreshes the handoff only when it is > 20 min old
hgen_setup
H="$HANDOFF_MEMORY_DIR/handoff-generated.md"
"$GEN" --out "$work/cache/status.json"; sleep 1.5
[ -s "$H" ] && echo "ok - missing handoff is generated after a status regen" || { echo "NOT OK - handoff not generated"; fail=1; }
touch -d '30 minutes ago' "$H"; before=$(stat -c %Y "$H")
"$GEN" --out "$work/cache/status.json"; sleep 1.5
assert_eq "$([ "$(stat -c %Y "$H")" -gt "$before" ] && echo yes)" "yes" "30 min old handoff is refreshed"
touch -d '5 minutes ago' "$H"; before=$(stat -c %Y "$H")
"$GEN" --out "$work/cache/status.json"; sleep 1.5
assert_eq "$(stat -c %Y "$H")" "$before" "5 min old handoff is left alone"
exit $fail
