#!/usr/bin/env bash
# PRD dotfiles-config-edit-reload-check AC2: an Edit to any other file exits 0,
# prints nothing, takes < 50 ms and leaves no waiter process.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/crchk_test_helpers.sh"
crchk_setup
payload=$(edit_payload "$work/other.toml")
start=$(date +%s%N)
out=$(printf '%s' "$payload" | run_hook); rc=$?
ms=$(( ($(date +%s%N) - start) / 1000000 ))
assert_eq "$rc" "0" "exit 0"
assert_eq "$out" "" "no stdout"
[ "$ms" -lt 50 ] && echo "ok - ${ms} ms < 50" || { echo "NOT OK - ${ms} ms"; fail=1; }
sleep 0.3
assert_eq "$(pgrep -fc "config-reload-check.sh --wait $work")" "0" "no waiter process"
assert_eq "$(ls "$OPERATOR_CACHE_DIR")" "" "no state written"
exit $fail
