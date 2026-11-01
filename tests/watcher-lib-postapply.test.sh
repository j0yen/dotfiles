#!/usr/bin/env bash
# tests/watcher-lib-postapply.test.sh -- the adopted watcher lib + spec parse, and the fleet-sync post-apply step passes its own selftest.
# Run from the repo root:  bash tests/watcher-lib-postapply.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
fail=0
chk() { if [ "$2" = 0 ]; then echo "ok - watcher-lib-postapply: $1"; else echo "FAIL - watcher-lib-postapply: $1"; fail=1; fi; }

bash -n "$root/.local/lib/watcher-premise.sh"; chk "lib parses (bash -n)" $?
[ -f "$root/.local/lib/watcher-premise.spec" ]; chk "spec present next to the lib" $?
bash -c 'source "$1" && declare -F wp_arm wp_gate wp_emit_write wp_selftest >/dev/null' _ "$root/.local/lib/watcher-premise.sh" </dev/null; chk "lib sources and defines its public functions" $?
bash "$root/.local/bin/watcher-lib-postapply.sh" --selftest | tail -1 | grep -q '^SELFTEST PASS'; chk "post-apply --selftest passes" $?
exit $fail
