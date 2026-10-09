#!/usr/bin/env bash
# PRD agorabus-overlap-warning-hook AC8: the existing .claude/hooks/tests/
# suite passes unchanged against this build. The suite resolves hooks through
# $HOME/.claude, so it runs under a throwaway HOME whose .claude points at
# this worktree's .claude (the suite files themselves are not touched).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-overlap-warning-hook_test_helpers.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
ln -s "$ROOT/.claude" "$work/.claude"
ran=0
for t in "$ROOT"/.claude/hooks/tests/*.sh; do
  [ -e "$t" ] || continue
  ran=$((ran + 1))
  out=$(HOME="$work" bash "$t" 2>&1); rc=$?
  echo "$out" | tail -n 1
  assert_eq "$rc" "0" "$(basename "$t") exits 0"
  case "$out" in *FAIL*) echo "NOT OK - $(basename "$t") reported FAIL"; fail=1 ;; esac
done
[ "$ran" -ge 1 ] && echo "ok - ran $ran suite file(s)" || { echo "NOT OK - no suite files found"; fail=1; }
exit $fail
