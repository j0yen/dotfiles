#!/usr/bin/env bash
# PRD dotfiles-config-edit-reload-check AC1: an Edit to config.toml prints both
# keys' classes at once; once the journal gains a tick with a newer
# config_loaded_at and a config-reloaded max_runs row, the notice reads
# `max_runs loaded 3→4` and `state_dir NOT loaded (restart-required)`.
# (Delays are scaled: the fake journal gains its tick after 2 s, not 20 s.)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/crchk_test_helpers.sh"
crchk_setup
out=$(edit_payload | run_hook); rc=$?
assert_eq "$rc" "0" "hook exits 0"
assert_contains "$out" "max_runs 3→4 reloadable; daemon tick in ≤ 180 s" "stdout classes max_runs reloadable"
assert_contains "$out" "state_dir restart-required" "stdout classes state_dir restart-required"
( sleep 2; append_tick 1 0 ) &
f=$(wait_notice 60); assert_eq "$?" "0" "notice appears within 60 s"
body=$(cat "$f" 2>/dev/null)
assert_contains "$body" "max_runs loaded 3→4" "notice: max_runs loaded 3→4"
assert_contains "$body" "state_dir NOT loaded (restart-required)" "notice: state_dir NOT loaded"
wait
exit $fail
