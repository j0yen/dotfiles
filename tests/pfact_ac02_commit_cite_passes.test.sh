#!/usr/bin/env bash
# PRD dotfiles-park-requires-fresh-fact AC2: the same park command citing
# commit=<the requeue commit> -> exit 0, no stdout; the pass is audited.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/pfact_test_helpers.sh"
pfact_setup

echo "- Status: queued" >>"$PRD_DIR/build-queue/PRD-x.md"
git -C "$PRD_DIR" add -A
fx_commit 47 "requeue: x (final-gate hotfix 0.73.2, runs 503/506 were harness blocks)"
req=$(git -C "$PRD_DIR" log -1 --format=%h)

run_hook "$(bash_payload "git mv build-queue/PRD-x.md parked/ # because: commit=$req")"
assert_eq "$rc" "0" "citing the requeue commit passes"
assert_eq "$out" "" "no stdout"
assert_contains "$(cat "$PARK_AUDIT_FILE" 2>/dev/null)" "\"newest_commit\":\"$req\"" "pass appended to the audit file"
exit $fail
