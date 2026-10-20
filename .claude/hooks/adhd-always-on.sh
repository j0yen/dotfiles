#!/usr/bin/env bash
# adhd-always-on.sh — SessionStart hook: the i-have-adhd always-on injection, owned by dotfiles.
# Replaces the plugin's own always-on hook, which we no longer let fire: the lean/compact one-liner used to be a
# local patch INSIDE ~/.claude/plugins/cache/i-have-adhd/*/hooks/always-on.{mjs,sh} and a plugin update erased it
# (token-cut C3, 10-20 2026; moved here by the Fable review the same day). The plugin cache is pristine again.
#
# Opt-in flag: $CLAUDE_CONFIG_DIR/.adhd-always-on (default ~/.claude). The plugin's own flag name
# (.i-have-adhd-always) is the legacy name: if found it is renamed to the new one, which makes the plugin's hook a
# no-op and this hook the single injector. Rename is a mv (reversible), never a delete.
#
# Output: LEAN (CLAUDE_LEAN_START=1 or SEAT_LEAN=1) or source=compact -> one line; otherwise the full ruleset from
# the newest cached plugin SKILL.md (frontmatter stripped). Never blocks session start: any failure exits 0.
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
flag="$claude_dir/.adhd-always-on"
legacy="$claude_dir/.i-have-adhd-always"
if [ ! -f "$flag" ] && [ -f "$legacy" ]; then mv -f "$legacy" "$flag" 2>/dev/null || cp "$legacy" "$flag" 2>/dev/null; fi
[ -f "$flag" ] || exit 0

src=""
[ -t 0 ] || src=$(sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ "${CLAUDE_LEAN_START:-}" = 1 ] || [ "${SEAT_LEAN:-}" = 1 ] || [ "$src" = compact ]; then
  printf 'ADHD MODE ACTIVE (always-on); ruleset = i-have-adhd skill.\n'; exit 0
fi

skill=$(ls -d "$claude_dir"/plugins/cache/i-have-adhd/i-have-adhd/*/skills/i-have-adhd/SKILL.md 2>/dev/null | sort -V | tail -1)
[ -n "$skill" ] && [ -f "$skill" ] || exit 0
body=$(awk 'NR==1 && /^---[[:space:]]*$/ {fm=1; next} fm && /^---[[:space:]]*$/ {fm=0; next} !fm {print}' "$skill") || exit 0
printf 'ADHD MODE ACTIVE (always-on). The ruleset below applies to every response. "stop adhd mode" turns it off for this session; delete %s to turn always-on off for good.\n\n%s\n' \
  "$flag" "$body"
