#!/usr/bin/env bash
# PRD dotfiles-operator-status-card AC6: settings.json wires the card once in
# SessionStart after the banner hooks (decisions-banner.sh when present, else
# the last pre-existing banner, grand-loop-banner-start.sh) and the notices
# hook once, last, in UserPromptSubmit; every pre-existing command (captured in
# tests/fixtures/ocard-settings-before.json) is unchanged and in order.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
S="$ROOT/.claude/settings.json"
B="$ROOT/tests/fixtures/ocard-settings-before.json"
jq -e . "$S" >/dev/null || { echo "NOT OK - settings.json parses"; exit 1; }

ss='[.hooks.SessionStart[].hooks[].command]'
ups='[.hooks.UserPromptSubmit[].hooks[].command]'
assert_eq "$(jq -r "$ss | map(select(test(\"operator-status-card[.]sh\"))) | length" "$S")" "1" "card appears once in SessionStart"
assert_eq "$(jq -r '[.hooks[][].hooks[].command | select(test("operator-status-card[.]sh"))] | length' "$S")" "1" "card appears once overall"
pos() { jq -r "$ss | map(test(\"$1\")) | index(true) // -1" "$S"; }
card=$(pos 'operator-status-card[.]sh')
[ "$card" -gt "$(pos 'grand-loop-banner-start[.]sh')" ] && echo "ok - card is after grand-loop-banner-start.sh" || { echo "NOT OK - card before grand-loop banner"; fail=1; }
db=$(pos 'decisions-banner[.]sh')
if [ "$db" -ge 0 ]; then
  [ "$card" -gt "$db" ] && echo "ok - card is after decisions-banner.sh" || { echo "NOT OK - card before decisions-banner.sh"; fail=1; }
fi
assert_eq "$(jq -c "$ss | map(select(test(\"operator-status-card[.]sh\") | not))" "$S")" "$(jq -c .SessionStart "$B")" "pre-existing SessionStart commands unchanged, in order"

assert_eq "$(jq -r "$ups | map(select(test(\"operator-notices[.]sh\"))) | length" "$S")" "1" "notices hook once in UserPromptSubmit"
assert_eq "$(jq -r '[.hooks[][].hooks[].command | select(test("operator-notices[.]sh"))] | length' "$S")" "1" "notices hook once overall"
assert_eq "$(jq -r "$ups | last | test(\"operator-notices[.]sh\")" "$S")" "true" "notices hook is last in UserPromptSubmit"
assert_eq "$(jq -c "$ups | map(select(test(\"operator-notices[.]sh\") | not))" "$S")" "$(jq -c .UserPromptSubmit "$B")" "pre-existing UserPromptSubmit commands unchanged, in order"
for f in .claude/scripts/operator-status-gen.sh .claude/scripts/operator-status-card.sh .claude/hooks/operator-notices.sh; do
  [ -x "$ROOT/$f" ] && echo "ok - $f is executable" || { echo "NOT OK - $f not executable"; fail=1; }
done
exit $fail
