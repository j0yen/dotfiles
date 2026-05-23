#!/usr/bin/env bash
# SessionStart hook: start a ctrace session rooted at the Claude process tree
# unless another ctrace is already running. Silent on success. Never blocks
# Claude startup — always exits 0.

set -u

ctrace=/home/jsy/.local/bin/ctrace
cache=/home/jsy/.cache/ctrace
sessions="$cache/sessions"
marker="$cache/claude-owns.json"
err="$cache/claude-start.err"

mkdir -p "$sessions" 2>/dev/null || exit 0

# Find Claude's PID. The hook may be invoked directly by claude (PPID=claude)
# or wrapped in a shell (PPID=sh, grandparent=claude). Walk up one if needed.
root="$PPID"
if [ -r "/proc/$PPID/comm" ]; then
    parent_comm=$(cat "/proc/$PPID/comm" 2>/dev/null || true)
    if [ "$parent_comm" != "claude" ]; then
        grand=$(awk '{print $4}' "/proc/$PPID/stat" 2>/dev/null || true)
        if [ -n "$grand" ] && [ "$grand" != "1" ]; then
            root="$grand"
        fi
    fi
fi

# Reap stale marker: tracer exited but marker file remains.
if [ -f "$marker" ]; then
    if ! "$ctrace" status 2>/dev/null | jq -e '.running == true' >/dev/null 2>&1; then
        rm -f "$marker"
    fi
fi

# Honor any running tracer (foreign or already-owned). Do not fight.
if "$ctrace" status 2>/dev/null | jq -e '.running == true' >/dev/null 2>&1; then
    exit 0
fi

iso=$(date +%Y%m%dT%H%M%S)
log="$sessions/claude-$iso.ndjson"

if "$ctrace" start --root "$root" --log "$log" >/dev/null 2>"$err"; then
    printf '{"claude_pid":%s,"started_at":"%s","log":"%s"}\n' \
        "$root" "$iso" "$log" > "$marker"
fi

exit 0
