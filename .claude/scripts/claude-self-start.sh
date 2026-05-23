#!/usr/bin/env bash
# claude-self-start.sh — SessionStart hook: emit CLAUDE_SELF.md into context.
#
# Loaded after CLAUDE.md (project-scoped) and before any skill execution.
# Treated as a system prompt augmentation. Silent if the file is missing.

set -uo pipefail

SELF="${HOME}/.claude/CLAUDE_SELF.md"
[ -r "$SELF" ] || exit 0

# Lint the file before emitting; if it fails, emit a warning marker but
# still ship the content so a malformed file isn't silently invisible.
LINT="${HOME}/.local/bin/claude-self"
if [ -x "$LINT" ] && ! "$LINT" lint --quiet 2>/dev/null; then
    printf '\n=== CLAUDE_SELF.md (LINT FAILED — see `claude-self lint`) ===\n'
else
    printf '\n=== CLAUDE_SELF.md ===\n'
fi

cat "$SELF"
printf '\n=== /CLAUDE_SELF.md ===\n'
