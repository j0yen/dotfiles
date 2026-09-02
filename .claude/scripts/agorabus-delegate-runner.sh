#!/usr/bin/env bash
# agorabus-delegate-runner.sh — execute one delegated `claude --print`
# detached from the parent agorabus-worker.sh. Writes ticket state under
# ~/.cache/agorabus/tickets/<ticket>.{json,stdout} and publishes
# delegate.progress.<ticket> + delegate.result.<ticket> events.
#
# Invoked as:
#   setsid agorabus-delegate-runner.sh \
#       <ticket> <cwd> <prompt-file> <ttl_secs> <agorabus_bin> <from_sid> <sid> &
#
# Prompt is passed via file (not argv) so it can be arbitrarily large
# without hitting ARG_MAX. The runner deletes the prompt file once read.
#
# Survives parent worker restart (setsid). The worker on next boot scans
# ~/.cache/agorabus/tickets/ and reaps any 'running' tickets whose pid is
# no longer alive.

set -u

ticket="${1:-}"
cwd="${2:-}"
prompt_file="${3:-}"
ttl_secs="${4:-300}"
agorabus="${5:-/home/jsy/.local/bin/agorabus}"
from_sid="${6:-}"
sid="${7:-}"

if [ -z "$ticket" ] || [ -z "$cwd" ] || [ -z "$prompt_file" ] || [ -z "$sid" ]; then
    echo "usage: agorabus-delegate-runner.sh <ticket> <cwd> <prompt-file> <ttl_secs> <agorabus_bin> <from_sid> <sid>" >&2
    exit 2
fi

[ -x "$agorabus" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

tickets_dir=/home/jsy/.cache/agorabus/tickets
mkdir -p "$tickets_dir" 2>/dev/null || true

state_file="$tickets_dir/${ticket}.json"
stdout_file="$tickets_dir/${ticket}.stdout"

# Atomic state writer: writes to .tmp then renames.
write_state() {
    local payload="$1"
    local tmp="${state_file}.tmp.$$"
    printf '%s\n' "$payload" >"$tmp" 2>/dev/null || return 1
    mv "$tmp" "$state_file" 2>/dev/null || return 1
}

publish_progress() {
    local status="$1"
    local body
    body=$(jq -nc --arg t "$ticket" --arg st "$status" \
                  --argjson now "$(date +%s)" \
                  --argjson pid "$$" \
                  --arg f "$from_sid" --arg s "$sid" \
        '{ticket:$t, status:$st, pid:$pid, ts_unix:$now, from:$f, sid:$s}')
    "$agorabus" publish --session-id "$sid" "delegate.progress.${ticket}" "$body" \
        >/dev/null 2>&1 || true
}

publish_result() {
    local payload="$1"
    "$agorabus" publish --session-id "$sid" "delegate.result.${ticket}" "$payload" \
        >/dev/null 2>&1 || true
}

# Read the prompt (caller writes it as a file so we can support huge prompts).
if [ ! -r "$prompt_file" ]; then
    body=$(jq -nc --arg t "$ticket" --arg err "missing_prompt_file" \
                  --arg pf "$prompt_file" \
        '{ticket:$t, status:"failed", error:$err, detail:$pf}')
    write_state "$body"
    publish_result "$body"
    exit 2
fi
prompt=$(cat "$prompt_file")
rm -f "$prompt_file" 2>/dev/null || true

if [ ! -d "$cwd" ]; then
    body=$(jq -nc --arg t "$ticket" --arg err "bad_cwd" --arg c "$cwd" \
        '{ticket:$t, status:"failed", error:$err, detail:$c}')
    write_state "$body"
    publish_result "$body"
    exit 2
fi

started_unix=$(date +%s)
start_ms=$(date +%s%3N)

# Initial state: running.
init_state=$(jq -nc --arg t "$ticket" --argjson started "$started_unix" \
                    --argjson pid "$$" --arg cwd "$cwd" \
                    --argjson ttl "$ttl_secs" --arg from "$from_sid" --arg s "$sid" \
    '{ticket:$t, status:"running", started_unix:$started,
      pid:$pid, cwd:$cwd, ttl_secs:$ttl, from:$from, sid:$s,
      bytes_written:0}')
write_state "$init_state"
publish_progress "running"

# Periodic-progress background tick: emits progress.<ticket> every 30s
# until parent exits. Killed in trap.
(
    while sleep 30; do
        publish_progress "running" 2>/dev/null || exit 0
    done
) &
progress_pid=$!

cleanup_progress() {
    kill "$progress_pid" 2>/dev/null || true
}
trap cleanup_progress EXIT

# Run the delegated claude. timeout-cmd handles ttl; we capture stdout
# to a file (NOT stdout var) so large outputs don't pressure shell memory.
tmpout="${stdout_file}.tmp.$$"
(
    cd "$cwd" && \
    AGORABUS_DELEGATE_DEPTH=$((${AGORABUS_DELEGATE_DEPTH:-0} + 1)) \
    timeout --kill-after=10s "${ttl_secs}s" claude --print \
        --dangerously-skip-permissions --no-session-persistence \
        --output-format text -- "$prompt" >"$tmpout" 2>&1
)
rc=$?
mv "$tmpout" "$stdout_file" 2>/dev/null || true
end_ms=$(date +%s%3N)
finished_unix=$(date +%s)
dur_ms=$((end_ms - start_ms))
bytes=$(wc -c <"$stdout_file" 2>/dev/null | tr -d ' ' || echo 0)

if [ "$rc" -eq 0 ]; then
    status="done"
elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    status="timeout"
else
    status="failed"
fi

final_state=$(jq -nc --arg t "$ticket" --arg st "$status" \
                     --argjson started "$started_unix" \
                     --argjson finished "$finished_unix" \
                     --argjson dur "$dur_ms" \
                     --argjson rc "$rc" \
                     --argjson bytes "$bytes" \
                     --arg cwd "$cwd" --arg from "$from_sid" --arg s "$sid" \
    '{ticket:$t, status:$st, started_unix:$started, finished_unix:$finished,
      duration_ms:$dur, exit_code:$rc, bytes_written:$bytes,
      cwd:$cwd, from:$from, sid:$s}')
write_state "$final_state"

# Result event carries the same payload as state (no stdout — caller fetches
# via delegate.result RPC which reads the file).
publish_result "$final_state"
publish_progress "$status"

cleanup_progress
exit 0
