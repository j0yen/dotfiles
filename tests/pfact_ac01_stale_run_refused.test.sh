#!/usr/bin/env bash
# PRD dotfiles-park-requires-fresh-fact AC1: a requeue commit at T, then a
# park at T+47 min citing run=515 whose runs.ended is T-2 h -> exit 2 and
# stdout names the requeue commit with its subject.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/pfact_test_helpers.sh"
pfact_setup

echo "- Status: queued" >>"$PRD_DIR/build-queue/PRD-x.md"
git -C "$PRD_DIR" add -A
fx_commit 47 "requeue: x (final-gate hotfix 0.73.2, runs 503/506 were harness blocks)"
req=$(git -C "$PRD_DIR" log -1 --format=%h)
sqlite3 "$WM_STATE_DB" "insert into runs(id,slug,started,ended,outcome) values (515,'x','$(iso_ago 227)','$(iso_ago 167)','blocked')"

run_hook "$(bash_payload "git mv build-queue/PRD-x.md parked/ # because: run=515")"
assert_eq "$rc" "2" "stale run citation is refused"
assert_contains "$out" "$req" "stdout names the requeue commit hash"
assert_contains "$out" "requeue: x (final-gate hotfix 0.73.2" "stdout carries the commit subject"
exit $fail
