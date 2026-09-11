#!/usr/bin/env bash
# agorabus-sid.sh — shared session-id derivation for agorabus hooks.
#
# 2026-09-11 root-cause fix: agorabus-session-start.sh derived sid from the
# kernel agentns id (/proc/self/agent_session) when available, but
# agorabus-session-end.sh derived only the PID fallback. On agentns kernels
# (RedBaron) the two sids never matched, so session-end's `pkill -f
# "agorabus-worker.sh $sid"` never found its target and the worker orphaned.
# 100 orphaned workers accumulated over 9 days. Both hooks now source this
# file and call the same functions, so they can never drift again.
#
# Usage (from a hook script):
#   source "$HOME/.claude/scripts/agorabus-sid.sh"
#   root=$(agorabus_derive_root_pid "$PPID")
#   sid=$(agorabus_derive_sid "$root" "$project")
#
# Pure functions — no side effects, safe to source repeatedly.

# Walk from a hook's $PPID to find Claude's actual pid. The hook may be
# invoked directly (PPID=claude) or via a wrapper shell (PPID=sh,
# grandparent=claude); walk up one level in that case.
agorabus_derive_root_pid() {
    local ppid="$1" root parent_comm grand
    root="$ppid"
    if [ -r "/proc/$ppid/comm" ]; then
        parent_comm=$(cat "/proc/$ppid/comm" 2>/dev/null || true)
        if [ "$parent_comm" != "claude" ]; then
            grand=$(awk '{print $4}' "/proc/$ppid/stat" 2>/dev/null || true)
            if [ -n "$grand" ] && [ "$grand" != "1" ]; then
                root="$grand"
            fi
        fi
    fi
    printf '%s' "$root"
}

# Derive the session id used as the agorabus session/pubsub key.
#
# Args: root_pid project [sid_kernel_override]
#   root_pid  — this hook's derived Claude root pid (agorabus_derive_root_pid).
#   project   — basename of the working directory.
#   sid_kernel_override — TEST ONLY. When passed (even ""), skips reading
#                          /proc/self/agent_session and uses this value
#                          instead, so tests can simulate the agentns path
#                          without a real agentns kernel. Production call
#                          sites must pass exactly 2 args.
#
# On agentns kernels, the kernel writes a stable 32-char hex id into
# /proc/self/agent_session once unshare(CLONE_NEWAGENT) has been called
# (via agentns-claude). We use the first 16 hex chars (64 bits) as a
# compact stable prefix. Falls back to the PID-based synthesis on stock
# kernels, non-agentns sessions, or when the id reads all zeros.
agorabus_derive_sid() {
    local root_pid="$1" project="$2" sid_kernel
    if [ -n "${3+x}" ]; then
        sid_kernel="$3"
    else
        sid_kernel=$(cat /proc/self/agent_session 2>/dev/null || true)
    fi
    if [[ -n "$sid_kernel" ]] && [[ "$sid_kernel" != "00000000000000000000000000000000" ]]; then
        printf '%s' "claude-${sid_kernel:0:16}-${project}"
    else
        printf '%s' "claude-${root_pid}-${project}"
    fi
}
