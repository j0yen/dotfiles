#!/usr/bin/env bash
# wchg-scope-check.sh — PreToolUse/PostToolUse hook on Edit|Write|MultiEdit.
#
# Goal: every file mutation gets watched by wchg, and the post-tool
# delta is reported. Catches a class of scope escapes that git status
# would miss (e.g., a script side-effects an unexpected file).
#
# v1 design:
#   PreToolUse  → `wchg watch $(dirname file_path)` (idempotent — wchg
#                  treats existing watches as a no-op).
#   PostToolUse → `wchg since <path>` to capture the delta. If any
#                  files outside the targeted file_path were touched,
#                  emit a one-line warning to stdout (visible to Claude
#                  in the tool result).
#
# Best-effort; silent on every failure path. Skips Edit/Write inside
# the recall data dir (~/.claude/recall/) and the hook scripts dir
# itself to avoid recursive noise.
#
# Wired in settings.json:
#   PreToolUse  matcher=Edit|Write|MultiEdit → wchg-scope-check.sh pre
#   PostToolUse matcher=Edit|Write|MultiEdit → wchg-scope-check.sh post

set -uo pipefail
exec 2>/dev/null

mode="${1:-}"
[ -z "$mode" ] && exit 0

JQ=$(command -v jq || echo /usr/bin/jq)
WCHG="${WCHG:-$HOME/.local/bin/wchg}"
[ -x "$JQ" ] || exit 0
[ -x "$WCHG" ] || exit 0

input="$(cat)"

# Extract file_path. Edit/Write use .tool_input.file_path; MultiEdit
# uses .tool_input.file_path too (single path applied across edits).
fp="$("$JQ" -r '.tool_input.file_path // empty' <<<"$input")"
[ -z "$fp" ] && exit 0

# Skip noisy paths
case "$fp" in
    "$HOME/.claude/recall/"*) exit 0 ;;
    "$HOME/.cache/"*) exit 0 ;;
    "/tmp/"*) exit 0 ;;
esac

# Parent dir for watching; the scope of interest is that dir's contents.
parent_dir=$(dirname "$fp")
[ -d "$parent_dir" ] || exit 0

case "$mode" in
  pre)
    # Idempotent watch registration.
    "$WCHG" watch "$parent_dir" >/dev/null 2>&1 || true
    ;;
  post)
    # `wchg since` emits JSON: {"files":[{"name":...,"exists":...,"new":...}], "clock":...}
    delta=$("$WCHG" since "$parent_dir" 2>/dev/null || true)
    [ -z "$delta" ] && exit 0

    # Filter to files OTHER than the expected one. The "name" field is
    # the basename relative to the watch root; compare against
    # fp's basename (parent_dir IS the watch root in our setup).
    fp_basename=$(basename "$fp")
    others=$("$JQ" -r --arg target "$fp_basename" \
        '.files // [] | map(select(.name != $target)) | .[] | "\(.name) (\(if .new then "new" else "modified" end))"' \
        <<<"$delta" 2>/dev/null || true)
    if [ -n "$others" ]; then
        others_short=$(printf '%s\n' "$others" | head -5)
        printf '\n[wchg scope-check] %s changed; sibling files in %s also touched this turn:\n%s\n' \
            "$fp" "$parent_dir" "$others_short"
    fi
    ;;
esac

exit 0
