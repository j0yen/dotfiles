#!/usr/bin/env bash
# PRD dotfiles-park-requires-fresh-fact AC7: PARK_FRESH_FACT=off lets a park
# without because: through with exactly one bypass line.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/pfact_test_helpers.sh"
pfact_setup

export PARK_FRESH_FACT=off
run_hook "$(bash_payload "git mv build-queue/PRD-x.md parked/")"
assert_eq "$rc" "0" "bypass: exit 0"
assert_contains "$out" "bypassed" "bypass line printed"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "exactly one line"
exit $fail
