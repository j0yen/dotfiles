#!/usr/bin/env bash
# tests/explorefirst_ac1_full_cycle.test.sh — PRD-mcphost-explore-first-light
# AC1: given a fake mcphost binary and fake synthorg entrypoints that record
# their invocations, when the runner completes a full cycle, then the
# invocation log shows instance start -> health wait -> explore with 24
# sessions and the pinned composition -> mine -> export, in that order, and
# the pack directory exists with catalog, manifest, and the novelty result
# line.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup

out="$("$RUNNER")"
rc=$?
assert_eq "$rc" "0" "runner exits 0 on a clean full cycle"

# -- ordering: mcphost migrate -> serve, before any synthorg call ------------
mig_line="$(grep -n '^migrate' "$mcphost_calls" | head -1 | cut -d: -f1)"
serve_line="$(grep -n '^serve' "$mcphost_calls" | head -1 | cut -d: -f1)"
explore_line="$(grep -n '^explore ' "$synthorg_calls" | head -1 | cut -d: -f1)"
obs_line="$(grep -n '^obs ' "$synthorg_calls" | head -1 | cut -d: -f1)"
usecases_line="$(grep -n '^usecases ' "$synthorg_calls" | head -1 | cut -d: -f1)"
export_line="$(grep -n '^export-evidence ' "$synthorg_calls" | head -1 | cut -d: -f1)"

assert_eq "$([ -n "$mig_line" ] && [ -n "$serve_line" ] && [ "$mig_line" -lt "$serve_line" ] && echo yes)" "yes" "migrate runs before serve"
assert_eq "$([ -n "$explore_line" ] && [ -n "$obs_line" ] && [ "$explore_line" -lt "$obs_line" ] && echo yes)" "yes" "explore runs before the budget assert (obs)"
assert_eq "$([ -n "$obs_line" ] && [ -n "$usecases_line" ] && [ "$obs_line" -lt "$usecases_line" ] && echo yes)" "yes" "budget assert runs before mining"
assert_eq "$([ -n "$usecases_line" ] && [ -n "$export_line" ] && [ "$usecases_line" -lt "$export_line" ] && echo yes)" "yes" "mining runs before export"

# -- pinned parameters --------------------------------------------------------
explore_call="$(grep '^explore ' "$synthorg_calls" | head -1)"
assert_contains "$explore_call" "--sessions 24" "explore invoked with 24 pinned sessions"
assert_contains "$explore_call" "--composition $syn_dir/corpora/mcphost/panel-composition.yaml" "explore invoked with the pinned panel composition, not consumer-tasks.yaml"
assert_contains "$explore_call" "--host http://127.0.0.1:" "explore invoked against the local ephemeral instance's URL"

# -- pack contents -------------------------------------------------------------
pack_dir="$(tail -1 "$prd_dir/vibeloop/exploration-ledger.md" | grep -oE 'pack=[^ ]+' | cut -d= -f2)"
assert_file_exists "$pack_dir" "pack directory recorded on the ledger line exists"
assert_file_exists "$pack_dir/catalog.json" "pack carries catalog.json"
assert_file_exists "$pack_dir/manifest.json" "pack carries manifest.json"
assert_file_exists "$pack_dir/novelty-result.txt" "pack carries the novelty result line"
assert_contains "$(cat "$pack_dir/novelty-result.txt")" "candidates=4 novel=3 gate_met=yes" "novelty result line reads candidates/novel/gate_met"

exit "$fail"
