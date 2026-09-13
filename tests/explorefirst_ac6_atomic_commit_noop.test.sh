#!/usr/bin/env bash
# tests/explorefirst_ac6_atomic_commit_noop.test.sh — PRD-mcphost-explore-first-light
# AC6: given a completed run, when the export commits, then the commit
# contains only the pack path and the dream-log note, and a second
# identical export attempt is a no-op.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup

"$RUNNER" >/dev/null
rc1=$?
assert_eq "$rc1" "0" "first run completes"

commit_files="$(cd "$prd_dir" && git show --name-only --pretty=format: HEAD | sed '/^$/d')"
# Every changed path must fall under the pack dir, the week marker, or the
# dream-log note — never anything else (the half-committed-archive trap /
# `git add -A` this PRD's technical considerations rule out).
outside="$(printf '%s\n' "$commit_files" | grep -vE '^evidence/mcp-host/exploration/|^notes/dream-log\.md$' || true)"
assert_eq "$outside" "" "commit touches only the pack path, its week marker, and the dream-log note"
assert_contains "$commit_files" "evidence/mcp-host/exploration/" "commit includes the pack path"
assert_contains "$commit_files" "notes/dream-log.md" "commit includes the dream-log note"

commit_count_before="$(cd "$prd_dir" && git rev-list --count HEAD)"

# Re-attempt the same export: same pinned "now" (same ts_dir/pack path),
# week marker removed so the AC2 skip-gate doesn't short-circuit before the
# commit step this test cares about.
rm -f "$prd_dir/evidence/mcp-host/exploration/.weeks/2026-W37"
"$RUNNER" >/dev/null
rc2=$?
assert_eq "$rc2" "0" "second identical export attempt still exits 0"

commit_count_after="$(cd "$prd_dir" && git rev-list --count HEAD)"
assert_eq "$commit_count_after" "$commit_count_before" "no new commit landed for an identical re-export"
assert_contains "$(cat "$log_file")" "nothing staged (AC6 no-op" "runner logs the no-op explicitly"

exit "$fail"
