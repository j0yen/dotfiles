#!/usr/bin/env bash
# agorabus-session-end.sh — SessionEnd hook that drops this session's
# long-lived agorabus subscriber so the peer record clears.
#
# Derives sid via the SAME agorabus-sid.sh helper agorabus-session-start.sh
# uses (2026-09-11 fix). Previously this script derived only the PID
# fallback sid, so on agentns kernels (RedBaron) it never matched
# session-start's agentns-derived sid and the pkill below silently missed
# its target — 100 orphaned workers accumulated over 9 days. Silent;
# always exits 0.

set -u

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
project=$(basename "$cwd")

sid_helper="$HOME/.claude/scripts/agorabus-sid.sh"
if [ -r "$sid_helper" ]; then
    # shellcheck disable=SC1090
    source "$sid_helper"
    root=$(agorabus_derive_root_pid "$PPID")
    sid=$(agorabus_derive_sid "$root" "$project")
else
    # Fallback: helper not yet propagated to this host. Inline copy of the
    # ORIGINAL (pre-fix) logic — PID fallback only. This preserves old
    # behavior when the helper is missing rather than guessing at the
    # agentns derivation without the shared source of truth.
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
    sid="claude-${root}-${project}"
fi

# Test hook only: dump the derived sid and exit before the pkills, so the
# sid-matching fix can be verified against agorabus-session-start.sh's
# AGORABUS_SID_DEBUG output without touching live processes. Never set in
# normal hook invocation.
if [ -n "${AGORABUS_SID_DEBUG:-}" ]; then
    printf '%s\n' "$sid"
    exit 0
fi

pkill -f "agorabus subscribe --session-id $sid" 2>/dev/null || true
# Worker's subscribe connection (suffix -worker) and the worker script.
pkill -f "agorabus subscribe rpc\\.req\\.${sid} " 2>/dev/null || true
pkill -f "agorabus-worker\\.sh $sid" 2>/dev/null || true
exit 0
