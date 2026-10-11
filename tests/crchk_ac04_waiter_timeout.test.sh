#!/usr/bin/env bash
# PRD dotfiles-config-edit-reload-check AC4: with a journal that never gains a
# tick, the waiter times out and the notice reads `no tick within <n> s —
# daemon stalled?`. (Timeout shortened to 3 s via CRCHK_TIMEOUT.)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/crchk_test_helpers.sh"
crchk_setup
export CRCHK_TIMEOUT=3
edit_payload | run_hook >/dev/null
f=$(wait_notice 15); assert_eq "$?" "0" "notice appears after the timeout"
assert_contains "$(cat "$f" 2>/dev/null)" "no tick within 3 s — daemon stalled?" "stalled message with n"
exit $fail
