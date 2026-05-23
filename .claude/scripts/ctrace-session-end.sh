#!/usr/bin/env bash
# Stop hook: if we own the active ctrace session, stop it and render summary.
# Never blocks shutdown — always exits 0.

set -u

ctrace=/home/jsy/.local/bin/ctrace
cache=/home/jsy/.cache/ctrace
marker="$cache/claude-owns.json"
summarize=/home/jsy/.claude/scripts/summarize-ctrace-session.sh
err="$cache/claude-stop.err"

[ -f "$marker" ] || exit 0

log=$(jq -r '.log // empty' "$marker" 2>/dev/null || true)

"$ctrace" stop >/dev/null 2>"$err" || true

rm -f "$marker"

if [ -n "$log" ] && [ -f "$log" ] && [ -x "$summarize" ]; then
    "$summarize" "$log" >/dev/null 2>>"$err" || true
fi

exit 0
