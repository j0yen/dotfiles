#!/usr/bin/env bash
# PRD dotfiles-config-edit-reload-check R5/R7: settings.json wires the hook once
# on PostToolUse for Edit|Write|MultiEdit|Bash, and `--last` reprints the
# newest notice even after operator-notices.sh has drained it.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/crchk_test_helpers.sh"
S="$ROOT/.claude/settings.json"
jq -e . "$S" >/dev/null || { echo "NOT OK - settings.json parses"; exit 1; }
assert_eq "$(jq -r '[.hooks.PostToolUse[] | select(.hooks[].command | test("config-reload-check[.]sh")) | .matcher] | join(",")' "$S")" "Edit|Write|MultiEdit|Bash" "wired once with the R5 matcher"
crchk_setup
export CRCHK_TIMEOUT=2
edit_payload | run_hook >/dev/null
f=$(wait_notice 15); assert_eq "$?" "0" "notice appears"
rm -f "$f"
assert_contains "$(run_hook --last)" "no tick within 2 s" "--last reprints the drained notice"
exit $fail
