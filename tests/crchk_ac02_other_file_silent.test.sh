#!/usr/bin/env bash
# PRD dotfiles-config-edit-reload-check AC2: an Edit to any other file exits 0,
# prints nothing, takes < 50 ms (best of 3, load-tolerant; see crchk_time_best_of) and leaves no waiter process.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/crchk_test_helpers.sh"
crchk_setup
payload=$(edit_payload "$work/other.toml")
crchk_time_best_of 3 "$payload"
assert_eq "$CRCHK_RC" "0" "exit 0"
assert_eq "$CRCHK_OUT" "" "no stdout"
crchk_assert_fast "answers within ${CRCHK_MS_BUDGET} ms"
sleep 0.3
assert_eq "$(pgrep -fc "config-reload-check.sh --wait $work")" "0" "no waiter process"
assert_eq "$(ls "$OPERATOR_CACHE_DIR")" "" "no state written"
exit $fail
