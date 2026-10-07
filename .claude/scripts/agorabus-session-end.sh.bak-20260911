#!/usr/bin/env bash
# agorabus-session-end.sh — SessionEnd hook that drops this session's
# long-lived agorabus subscriber so the peer record clears.
#
# Mirrors the sid derivation in agorabus-session-start.sh. Silent; always
# exits 0.

set -u

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

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
project=$(basename "$cwd")
sid="claude-${root}-${project}"

pkill -f "agorabus subscribe --session-id $sid" 2>/dev/null || true
# Worker's subscribe connection (suffix -worker) and the worker script.
pkill -f "agorabus subscribe rpc\\.req\\.${sid} " 2>/dev/null || true
pkill -f "agorabus-worker\\.sh $sid" 2>/dev/null || true
exit 0
