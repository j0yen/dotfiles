#!/usr/bin/env bash
# tests/explorefirst_ac8_manifest_cost_fields.test.sh — PRD-mcphost-explore-first-light
# AC8 (P1): given a completed run, when the pack manifest is read, then it
# carries sessions completed and the cost figure the telemetry exposed.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup

"$RUNNER" >/dev/null
pack_dir="$(tail -1 "$prd_dir/vibeloop/exploration-ledger.md" | grep -oE 'pack=[^ ]+' | cut -d= -f2)"

manifest="$pack_dir/manifest.json"
assert_file_exists "$manifest" "manifest.json exists in the pack"

sessions="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sessions_completed"))' "$manifest")"
cost="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("est_cost_usd"))' "$manifest")"

assert_eq "$sessions" "24" "manifest carries the sessions-completed figure the telemetry exposed"
assert_eq "$cost" "1.2345" "manifest carries the cost figure the telemetry exposed"

exit "$fail"
