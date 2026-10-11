#!/usr/bin/env bash
# PRD dotfiles-config-edit-reload-check AC6: a Bash `sed -i` on the config path
# is treated as an edit (same immediate output as AC1); a Bash command that
# only reads the file is not.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/crchk_test_helpers.sh"
crchk_setup
want=$(edit_payload | run_hook)
pkill -f "config-reload-check.sh --wait $work"; rm -rf "$OPERATOR_CACHE_DIR"/*
bash_payload() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
# the path as typed: ~/.config/wm-build/config.toml (tilde form), with HOME pointing at the fixture
export HOME="$work/home"; mkdir -p "$HOME/.config/wm-build"; unset WM_BUILD_CONFIG
got=$(bash_payload "sed -i 's/max_runs = 3/max_runs = 4/' ~/.config/wm-build/config.toml" | run_hook); rc=$?
assert_eq "$rc" "0" "exit 0"
assert_eq "$got" "$want" "same immediate output as an Edit"
assert_contains "$got" "max_runs 3→4 reloadable" "max_runs classed reloadable"
pkill -f "config-reload-check.sh --wait $work"
got=$(bash_payload 'cat ~/.config/wm-build/config.toml | head' | run_hook)
assert_eq "$got" "" "a read-only Bash command is ignored"
got=$(bash_payload "sed -i 's/a/b/' /tmp/other.toml" | run_hook)
assert_eq "$got" "" "sed -i on another file is ignored"
exit $fail
