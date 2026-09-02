#!/usr/bin/env bash
# agorabus-session-start.sh — SessionStart hook for cross-session pub/sub.
#
# Idempotently:
#   - Starts the agorabus daemon if not already running.
#   - Spawns a long-lived `subscribe` so this session appears in `peers`
#     and receives published events.
#   - Appends incoming events to ~/.cache/agorabus/sessions/<sid>.ndjson
#     so the model can tail its own inbox.
#   - Verifies peer-record attachment with retry + re-spawn on failure.
#   - Logs structured handshake records to ~/.cache/agorabus/handshake/<sid>.log
#
# Emits a brief banner listing other peers on the bus (if any). Never
# blocks Claude startup; always exits 0.
#
# ── Why the wait windows are what they are ──────────────────────────────
# 2026-05-25 journal §Notable (verbatim excerpt):
#   "PID 917's two subscribers (1888 subscriber, 2091 worker) are alive
#    and the daemon binary IS post-fix, so the cause is a daemon-not-ready
#    race at boot, not the pre-fix collision bug. The agorabus_orphan_subscriber
#    playbook detected the state but had to escalate because no programmatic
#    re-attach exists. ... extending the hook's socket-wait to ~0.5s × N or
#    adding a peer-record-explicit re-announce after the subscribe handshake."
#
# The original hook polled [ -S "$sock" ] for at most 0.1s × 5 = 0.5s.
# Under kernel-build-equivalent load (load 10.42 observed that morning), the
# daemon can take >0.5s to bind its UDS. The subscriber would spawn anyway,
# its first announce often hit no listener, and it silently orphaned.
#
# Fix: extended socket-wait to 0.3s × 10 = 3s, plus post-spawn peer-record
# polling (10 × 0.3s = 3s) with one re-spawn attempt on first failure,
# then 5 × 0.3s more. Total max wait per phase: ~4.5s — never blocking Claude
# startup because all failure paths exit 0.
# ────────────────────────────────────────────────────────────────────────

set -u

agorabus=/home/jsy/.local/bin/agorabus
cache=/home/jsy/.cache/agorabus
sessions="$cache/sessions"
sock="$cache/sock"
daemon_log="$cache/daemon.log"
handshake_dir="$cache/handshake"

[ -x "$agorabus" ] || exit 0
mkdir -p "$sessions" "$handshake_dir" 2>/dev/null || exit 0

# Log rotation: prune handshake logs older than 14 days.
find "$handshake_dir" -maxdepth 1 -name '*.log' -mtime +14 -delete 2>/dev/null || true

# ── Helpers ──────────────────────────────────────────────────────────────

_now_ms() {
    # milliseconds since epoch (GNU date %3N)
    date +%s%3N 2>/dev/null || echo 0
}

_log_handshake() {
    local hlog="$1" ts sid phase attempt_n result elapsed_ms
    ts="$2"; sid="$3"; phase="$4"; attempt_n="$5"; result="$6"; elapsed_ms="$7"
    printf '{"ts":"%s","sid":"%s","phase":"%s","attempt_n":%s,"result":"%s","elapsed_ms":%s}\n' \
        "$ts" "$sid" "$phase" "$attempt_n" "$result" "$elapsed_ms" \
        >> "$hlog" 2>/dev/null || true
}

# Poll until `agorabus peers` lists a peer matching $1, up to $2 times at 0.3s.
# Returns 0 if found, 1 if exhausted.
_poll_peer() {
    local peer_id="$1" max_attempts="$2" i
    for i in $(seq 1 "$max_attempts"); do
        if "$agorabus" peers 2>/dev/null \
               | jq -e --arg p "$peer_id" 'any(.[]; .session_id == $p)' \
               >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.3
    done
    return 1
}

# ── Derive session-id ────────────────────────────────────────────────────

# Find Claude's PID. Hook may be invoked directly (PPID=claude) or via
# a wrapper shell (PPID=sh, grandparent=claude). Walk up one if needed.
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

# Derive session-id from the kernel agentns when available (wintermute kernel).
# The kernel writes a stable 32-char hex id into /proc/self/agent_session once
# unshare(CLONE_NEWAGENT) has been called (via agentns-claude). Falls back to
# the PID-based synthesis on stock kernels or when the id reads all zeros.
sid_kernel=$(cat /proc/self/agent_session 2>/dev/null || true)
if [[ -n "$sid_kernel" ]] && [[ "$sid_kernel" != "00000000000000000000000000000000" ]]; then
    # Use first 16 hex chars (64 bits) as a compact stable prefix.
    sid="claude-${sid_kernel:0:16}-${project}"
else
    # Fallback: PID-based synthesis (stock kernels / pre-agentns-claude sessions).
    sid="claude-${root}-${project}"
fi

hlog="$handshake_dir/${sid}.log"

# ── Phase: daemon_up ─────────────────────────────────────────────────────

phase_start=$(_now_ms)

if ! pgrep -f 'agorabus daemon' >/dev/null 2>&1; then
    nohup "$agorabus" daemon >"$daemon_log" 2>&1 &
    disown
    socket_ok=0
    for _ in $(seq 1 10); do
        if [ -S "$sock" ]; then
            socket_ok=1
            break
        fi
        sleep 0.3
    done
    elapsed=$(( $(_now_ms) - phase_start ))
    if [ "$socket_ok" -eq 1 ]; then
        _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
            "$sid" "daemon_up" 1 "ok" "$elapsed"
    else
        _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
            "$sid" "daemon_up" 1 "fail" "$elapsed"
        # Fail-open: daemon never came up, nothing else to do.
        exit 0
    fi
else
    elapsed=$(( $(_now_ms) - phase_start ))
    _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
        "$sid" "daemon_up" 0 "already_attached:ok" "$elapsed"
fi

# ── Phase: sub_attach ────────────────────────────────────────────────────

phase_start=$(_now_ms)
log="$sessions/${sid}.ndjson"

if pgrep -f "agorabus subscribe --session-id $sid" >/dev/null 2>&1; then
    elapsed=$(( $(_now_ms) - phase_start ))
    _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
        "$sid" "sub_attach" 0 "already_attached:ok" "$elapsed"
else
    setsid bash -c "exec '$agorabus' subscribe --session-id '$sid' '' >>'$log' 2>&1" </dev/null &
    disown
    # Brief moment for the subscriber's announce to land.
    sleep 0.2

    if _poll_peer "$sid" 10; then
        elapsed=$(( $(_now_ms) - phase_start ))
        _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
            "$sid" "sub_attach" 1 "ok" "$elapsed"
    else
        # First attempt failed — re-spawn once, then give it 5 more polls.
        _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
            "$sid" "sub_attach" 1 "fail" "$(( $(_now_ms) - phase_start ))"
        # Kill the failed subscriber if still alive.
        pkill -f "agorabus subscribe --session-id $sid" 2>/dev/null || true
        sleep 0.1
        setsid bash -c "exec '$agorabus' subscribe --session-id '$sid' '' >>'$log' 2>&1" </dev/null &
        disown
        sleep 0.2
        if _poll_peer "$sid" 5; then
            elapsed=$(( $(_now_ms) - phase_start ))
            _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
                "$sid" "sub_attach" 2 "ok" "$elapsed"
        else
            elapsed=$(( $(_now_ms) - phase_start ))
            _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
                "$sid" "sub_attach" 2 "fail" "$elapsed"
            # Fail-open: log the failure and continue to worker phase.
        fi
    fi
fi

# ── Phase: worker_attach ─────────────────────────────────────────────────

# Advertise a minimal default identity and working path. Task-level detail is
# published separately as agent.activity metadata, never inferred from prompts.
"$agorabus" intent set --session-id "$sid" --skill "claude" --paths "$cwd" \
    >/dev/null 2>&1 || true

# Spawn the RPC worker so this session auto-replies to ping / self.describe /
# methods.list / delegate.run on rpc.req.<sid>. Worker is idempotent.
worker="$HOME/.claude/scripts/agorabus-worker.sh"
if [ ! -x "$worker" ]; then
    exit 0
fi

phase_start=$(_now_ms)
worker_sid="${sid}-worker"

if pgrep -f "agorabus-worker.sh $sid\$" >/dev/null 2>&1; then
    elapsed=$(( $(_now_ms) - phase_start ))
    _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
        "$sid" "worker_attach" 0 "already_attached:ok" "$elapsed"
else
    workers="$cache/workers"
    mkdir -p "$workers" 2>/dev/null || true
    spawn_log="$workers/${sid}.spawn.log"
    setsid bash -c "exec '$worker' '$sid' '$cwd' >>'$spawn_log' 2>&1" </dev/null &
    disown
    sleep 0.2

    if _poll_peer "$worker_sid" 10; then
        elapsed=$(( $(_now_ms) - phase_start ))
        _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
            "$sid" "worker_attach" 1 "ok" "$elapsed"
    else
        # First attempt failed — re-spawn once.
        _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
            "$sid" "worker_attach" 1 "fail" "$(( $(_now_ms) - phase_start ))"
        pkill -f "agorabus-worker.sh $sid\$" 2>/dev/null || true
        sleep 0.1
        setsid bash -c "exec '$worker' '$sid' '$cwd' >>'$spawn_log' 2>&1" </dev/null &
        disown
        sleep 0.2
        if _poll_peer "$worker_sid" 5; then
            elapsed=$(( $(_now_ms) - phase_start ))
            _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
                "$sid" "worker_attach" 2 "ok" "$elapsed"
        else
            elapsed=$(( $(_now_ms) - phase_start ))
            _log_handshake "$hlog" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
                "$sid" "worker_attach" 2 "fail" "$elapsed"
            # Fail-open: log and continue.
        fi
    fi
fi

# ── Peer banner (other sessions only) ────────────────────────────────────

peers=$("$agorabus" peers 2>/dev/null)
case "$peers" in
    ""|"[]") exit 0 ;;
esac

other_count=$(printf '%s' "$peers" \
    | jq --arg sid "$sid" '[.[] | select(.session_id != $sid)] | length' 2>/dev/null)
if [ "${other_count:-0}" -gt 0 ]; then
    printf '\n=== agorabus: %s peer(s) on bus ===\n' "$other_count"
    printf '%s\n' "$peers" \
        | jq -r --arg sid "$sid" \
            '.[] | select(.session_id != $sid) | "- \(.session_id) pid=\(.pid) cwd=\(.cwd) intent=\(.intent)"' \
            2>/dev/null
    printf 'this session: %s\n' "$sid"
    printf '=== /agorabus ===\n'
fi

exit 0
