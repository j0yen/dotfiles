#!/usr/bin/env bash
# tests/explorefirst_ac10_dry_run.test.sh — PRD-mcphost-explore-first-light
# AC10 (P2): given --dry-run, when the runner completes, then the instance
# was started and health-checked, zero sessions ran, teardown is verified,
# and no pack is written.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup

out="$("$RUNNER" --dry-run)"
rc=$?

assert_eq "$rc" "0" "--dry-run exits 0"
assert_contains "$(grep '^serve' "$mcphost_calls")" "serve" "instance was started"
assert_contains "$(cat "$log_file")" "instance healthy" "instance was health-checked"
assert_eq "$(wc -l < "$synthorg_calls")" "0" "zero sessions ran — synthorg never invoked"
assert_contains "$out" "dry-run ok" "dry-run reports its own outcome"

sleep 0.3
assert_eq "$(pgrep -f "$bin/mcphost serve" | wc -l)" "0" "teardown verified — no leaked instance process"
leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'mcphost-explore-data.*' -newer "$log_file" 2>/dev/null | wc -l)"
assert_eq "$leftover" "0" "teardown verified — no leftover ephemeral data dir"
assert_eq "$(find "$prd_dir/evidence/mcp-host/exploration" -mindepth 1 -maxdepth 1 -type d -not -name '.weeks' 2>/dev/null | wc -l)" "0" "no pack written on --dry-run"

exit "$fail"
