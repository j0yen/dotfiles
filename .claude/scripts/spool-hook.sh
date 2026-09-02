#!/usr/bin/env bash
# spool-hook.sh — log Skill tool invocations to ~/.claude/spool/.
#
# Wired into PreToolUse / PostToolUse / PostToolUseFailure with matcher "Skill".
# Reads the hook input JSON on stdin; argv1 = start|end ; argv2 (end only) = ok|error
#
# Failure is silent — never block a Claude turn on telemetry.

set -uo pipefail
exec 2>/dev/null  # silence everything; this is best-effort instrumentation

mode="${1:-}"
[[ -z "$mode" ]] && exit 0

SPOOL_BIN=/home/jsy/.local/bin/spool
JQ=$(command -v jq || echo /usr/bin/jq)

[[ -x "$SPOOL_BIN" ]] || exit 0
[[ -x "$JQ" ]] || exit 0

input="$(cat)"
skill="$("$JQ" -r '.tool_input.skill // empty' <<<"$input")"
[[ -z "$skill" ]] && exit 0

session_id="$("$JQ" -r '.session_id // "unknown"' <<<"$input")"
stash_dir="/tmp/spool-stash-$(id -u)/$session_id"
mkdir -p "$stash_dir"
# Sanitize skill name for filename use (slashes, colons).
safe_skill="${skill//[^A-Za-z0-9._-]/_}"
id_file="$stash_dir/$safe_skill.id"

case "$mode" in
  start)
    args="$("$JQ" -r '.tool_input.args // empty' <<<"$input")"
    if [[ -n "$args" ]]; then
      id=$("$SPOOL_BIN" log start "$skill" --args "$args")
    else
      id=$("$SPOOL_BIN" log start "$skill")
    fi
    [[ -n "${id:-}" ]] && printf '%s\n' "$id" > "$id_file"
    ;;
  end)
    outcome="${2:-ok}"
    if [[ -f "$id_file" ]]; then
      id=$(cat "$id_file")
      rm -f "$id_file"
      [[ -n "$id" ]] && "$SPOOL_BIN" log end "$id" --outcome "$outcome"
    fi
    ;;
esac

exit 0
