#!/usr/bin/env bash
# recall-session-start.sh — emit relevant memories at SessionStart.
#
# Loads user-scoped memories (preferences, feedback), project-scoped
# memories for the current working directory's basename, and self-scoped
# memories (how I, Claude, work in this environment). The output goes
# into the model's context at the start of each session.
#
# Silent if recall is not installed or the store is empty.

set -uo pipefail

RECALL_BIN="${RECALL_BIN:-$HOME/.local/bin/recall}"
[ -x "$RECALL_BIN" ] || exit 0

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
project="$(basename "$cwd")"
limit="${RECALL_SESSION_LIMIT:-8}"

# Extract the markdown body from `recall show <id>` (everything after the
# closing `---` of the frontmatter), and squash to one line.
body_of() {
  "$RECALL_BIN" show "$1" 2>/dev/null \
    | awk 'BEGIN{f=0} /^---$/ {if (f==0) {f=1; next} else if (f==1) {f=2; next}} f==2 {print}' \
    | tr '\n' ' ' \
    | sed 's/  */ /g; s/^ //; s/ $//'
}

emit_section() {
  local subject="$1" header="$2"
  local out ids id text
  out="$("$RECALL_BIN" list --subject "$subject" --limit "$limit" 2>/dev/null)"
  case "$out" in
    "(no memories)"*|"") return 0 ;;
  esac
  ids="$(printf '%s\n' "$out" | awk '{print $1}')"
  [ -z "$ids" ] && return 0
  printf '\n%s\n' "$header"
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    text="$(body_of "$id")"
    [ -n "$text" ] && printf -- '- %s\n' "$text"
  done <<EOF
$ids
EOF
}

total="$("$RECALL_BIN" list --limit 1 2>/dev/null | head -n1)"
case "$total" in
  "(no memories)"*|"") exit 0 ;;
esac

printf 'recall: relevant memories for this session\n'
emit_section "user"             "user:"
emit_section "project:$project" "project:$project:"
emit_section "self"             "self:"
