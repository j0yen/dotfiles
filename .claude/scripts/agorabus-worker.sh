#!/usr/bin/env bash
# agorabus-worker.sh — RPC handler for one Claude session.
#
# DRAFT (PRD-chord-async-delegate iter-2): extends the live worker with
# async delegation methods. Live install path:
#   install -m755 ~/wintermute/autobuilder/proposals/agorabus-worker.draft.sh \
#                 ~/wintermute/dotfiles/.claude/scripts/agorabus-worker.sh
# Held out of live infra until jsy smoke-tests in one session.
#
# Subscribes to rpc.req.<sid> and dispatches per AGORABUS_RPC.md v0.2:
#   ping             → {pong_unix, session_id}        (default method)
#   self.describe    → {session_id, cwd, claude_version, started_unix, methods}
#   methods.list     → {methods: [...]}                (default method)
#   delegate.run     → back-compat wrapper: start+poll until done (or ttl)
#   delegate.start   → spawn detached runner; returns {ticket_id, started_unix}
#   delegate.poll    → read ticket state; returns {status, started_unix, ...}
#   delegate.result  → return ticket state + stdout
#   delegate.cancel  → SIGTERM the runner pid; mark ticket cancelled
#   delegate.cleanup → remove ticket files; prune done tickets older than 24h
# Unknown methods reply {ok:false, error:"unknown_method"}.
#
# Started by SessionStart hook (one per claude session); killed at SessionEnd.
# Idempotent: refuses to start if a worker for this sid is already running.

set -u

agorabus=/home/jsy/.local/bin/agorabus
runner=/home/jsy/.claude/scripts/agorabus-delegate-runner.sh
tickets_dir=/home/jsy/.cache/agorabus/tickets
sid="${1:-}"
worker_cwd="${2:-$HOME}"
if [ -z "$sid" ]; then
    echo "usage: agorabus-worker.sh <sid> [cwd]" >&2
    exit 2
fi

started_unix=$(date +%s)
claude_version=$(claude --version 2>/dev/null | head -1 || true)
METHODS='["ping","self.describe","methods.list","delegate.run","delegate.start","delegate.poll","delegate.result","delegate.cancel","delegate.cleanup"]'

[ -x "$agorabus" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Recursion guard: a delegated claude must not start its own worker.
if [ "${AGORABUS_DELEGATE_DEPTH:-0}" -gt 0 ]; then
    exit 0
fi

# Idempotency: bail if another worker for this sid is already alive.
self_pid=$$
if pgrep -f "agorabus-worker\.sh $sid( |\$)" | grep -v "^${self_pid}\$" >/dev/null 2>&1; then
    exit 0
fi

log_dir=/home/jsy/.cache/agorabus/workers
mkdir -p "$log_dir" "$tickets_dir" 2>/dev/null || true
log="$log_dir/${sid}.log"

worker_conn_sid="${sid}-worker"

log_event() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" >>"$log"
}

reply() {
    local from="$1" id="$2" payload="$3"
    "$agorabus" publish --session-id "$sid" "rpc.reply.${from}" "$payload" \
        >/dev/null 2>&1 || log_event "publish-failed id=$id from=$from"
}

# === Ticket helpers (PRD §What this builds) ===

# Read a ticket's JSON state; emit '{}' on missing/unreadable.
ticket_state() {
    local t="$1"
    local f="$tickets_dir/${t}.json"
    if [ -r "$f" ]; then
        cat "$f"
    else
        printf '%s' '{}'
    fi
}

# Reap stale tickets at boot: any ticket marked 'running' whose pid is dead
# transitions to status:"failed" with error:"worker_restart".
reap_stale_tickets() {
    [ -d "$tickets_dir" ] || return 0
    local f st pid t
    for f in "$tickets_dir"/*.json; do
        [ -r "$f" ] || continue
        st=$(jq -r '.status // empty' "$f" 2>/dev/null || true)
        [ "$st" = "running" ] || continue
        pid=$(jq -r '.pid // empty' "$f" 2>/dev/null || true)
        [ -n "$pid" ] || continue
        if ! kill -0 "$pid" 2>/dev/null; then
            t=$(jq -r '.ticket // empty' "$f" 2>/dev/null || true)
            jq -c '. + {status:"failed", error:"worker_restart",
                       finished_unix:'"$(date +%s)"'}' "$f" \
                >"${f}.tmp.$$" 2>/dev/null \
                && mv "${f}.tmp.$$" "$f"
            log_event "reaped-ticket $t pid=$pid was-running-but-dead"
        fi
    done
}

# Auto-prune tickets in terminal states older than 24h. Called from cleanup.
prune_old_tickets() {
    [ -d "$tickets_dir" ] || return 0
    # 86400s = 24h. mtime-based pruning of {ticket}.json and matching .stdout.
    find "$tickets_dir" -maxdepth 1 -type f -name '*.json' -mmin +1440 \
        -print 2>/dev/null \
    | while IFS= read -r jf; do
        st=$(jq -r '.status // empty' "$jf" 2>/dev/null || true)
        case "$st" in
            done|failed|timeout|cancelled)
                base=${jf%.json}
                rm -f "$jf" "${base}.stdout" 2>/dev/null || true
                ;;
        esac
    done
}

# Spawn a detached runner for a fresh ticket. Returns the ticket id on stdout.
# Args: from_sid prompt cwd ttl_secs
spawn_delegate_runner() {
    local from="$1" prompt="$2" cwd="$3" ttl="$4"
    local ticket
    # Ticket id: ulid-ish (date+nanos+rand). Sortable, collision-resistant.
    ticket="d$(date +%s%N | tail -c 13)$(awk 'BEGIN{srand(); printf "%04x", int(rand()*65536)}')"
    local prompt_file="$tickets_dir/${ticket}.prompt"
    # Write the prompt to a file so the detached runner can read it without
    # ARG_MAX pressure. Runner deletes it after read.
    printf '%s' "$prompt" >"$prompt_file" || return 1
    # Detach via setsid so the runner survives a worker restart.
    if [ -x "$runner" ]; then
        setsid "$runner" "$ticket" "$cwd" "$prompt_file" "$ttl" "$agorabus" "$from" "$sid" \
            >/dev/null 2>&1 < /dev/null &
        disown 2>/dev/null || true
    else
        # Runner not installed: write a failed-state file inline.
        rm -f "$prompt_file" 2>/dev/null || true
        jq -nc --arg t "$ticket" --arg err "runner_missing" \
               --arg p "$runner" \
            '{ticket:$t, status:"failed", error:$err, detail:$p}' \
            >"$tickets_dir/${ticket}.json"
        printf '%s' "$ticket"
        return 1
    fi
    printf '%s' "$ticket"
}

log_event "worker-start sid=$sid"
reap_stale_tickets

"$agorabus" subscribe "rpc.req.${sid}" --session-id "$worker_conn_sid" 2>/dev/null \
| while IFS= read -r line; do
    [ -z "$line" ] && continue

    method=$(printf '%s' "$line" | jq -r '.data.method // empty' 2>/dev/null || true)
    id=$(printf '%s' "$line" | jq -r '.data.id // empty' 2>/dev/null || true)
    from=$(printf '%s' "$line" | jq -r '.data.from // empty' 2>/dev/null || true)

    if [ -z "$id" ] || [ -z "$from" ]; then
        log_event "skip-malformed: $line"
        continue
    fi

    # Default convention methods (read-only / pure): handle inline.
    case "$method" in
    ping)
        log_event "recv id=$id from=$from method=ping"
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                       --argjson now "$(date +%s)" \
            '{id:$id, from:$s, to:$f, ok:true,
              result:{pong_unix:$now, session_id:$s}}')
        reply "$from" "$id" "$body"
        continue
        ;;
    self.describe)
        log_event "recv id=$id from=$from method=self.describe"
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                       --arg cwd "$worker_cwd" --arg ver "$claude_version" \
                       --argjson started "$started_unix" \
                       --argjson methods "$METHODS" \
            '{id:$id, from:$s, to:$f, ok:true,
              result:{session_id:$s, cwd:$cwd, claude_version:$ver,
                      started_unix:$started, methods:$methods}}')
        reply "$from" "$id" "$body"
        continue
        ;;
    methods.list)
        log_event "recv id=$id from=$from method=methods.list"
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                       --argjson methods "$METHODS" \
            '{id:$id, from:$s, to:$f, ok:true, result:{methods:$methods}}')
        reply "$from" "$id" "$body"
        continue
        ;;
    delegate.start)
        prompt=$(printf '%s' "$line" | jq -r '.data.params.prompt // empty')
        cwd_req=$(printf '%s' "$line" | jq -r '.data.params.cwd // empty')
        ttl_secs=$(printf '%s' "$line" | jq -r '.data.params.ttl_secs // .data.params.timeout_secs // 300')
        cwd="${cwd_req:-$HOME}"

        if [ -z "$prompt" ]; then
            body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                '{id:$id, from:$s, to:$f, ok:false, error:"missing_prompt"}')
            reply "$from" "$id" "$body"
            continue
        fi
        if [ ! -d "$cwd" ]; then
            body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" --arg c "$cwd" \
                '{id:$id, from:$s, to:$f, ok:false, error:"bad_cwd", detail:$c}')
            reply "$from" "$id" "$body"
            continue
        fi

        log_event "start-begin id=$id from=$from cwd=$cwd ttl=${ttl_secs}s"
        ticket=$(spawn_delegate_runner "$from" "$prompt" "$cwd" "$ttl_secs")
        rc=$?
        if [ $rc -ne 0 ] || [ -z "$ticket" ]; then
            log_event "start-fail id=$id rc=$rc"
            body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                '{id:$id, from:$s, to:$f, ok:false, error:"spawn_failed"}')
            reply "$from" "$id" "$body"
            continue
        fi
        log_event "start-ok   id=$id ticket=$ticket"
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                      --arg t "$ticket" --argjson now "$(date +%s)" \
            '{id:$id, from:$s, to:$f, ok:true,
              result:{ticket_id:$t, started_unix:$now}}')
        reply "$from" "$id" "$body"
        continue
        ;;
    delegate.poll)
        ticket=$(printf '%s' "$line" | jq -r '.data.params.ticket_id // .data.params.ticket // empty')
        if [ -z "$ticket" ]; then
            body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                '{id:$id, from:$s, to:$f, ok:false, error:"missing_ticket"}')
            reply "$from" "$id" "$body"
            continue
        fi
        state_json=$(ticket_state "$ticket")
        if [ "$state_json" = "{}" ]; then
            body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" --arg t "$ticket" \
                '{id:$id, from:$s, to:$f, ok:false, error:"unknown_ticket", detail:$t}')
            reply "$from" "$id" "$body"
            continue
        fi
        # Strip large fields from poll response — caller fetches via .result.
        body=$(printf '%s' "$state_json" \
            | jq -c --arg id "$id" --arg s "$sid" --arg f "$from" \
                '{id:$id, from:$s, to:$f, ok:true,
                  result:{ticket_id:.ticket, status:.status,
                          started_unix:.started_unix,
                          finished_unix:(.finished_unix // null),
                          exit_code:(.exit_code // null),
                          duration_ms:(.duration_ms // null),
                          bytes_written:(.bytes_written // 0)}}')
        reply "$from" "$id" "$body"
        continue
        ;;
    delegate.result)
        ticket=$(printf '%s' "$line" | jq -r '.data.params.ticket_id // .data.params.ticket // empty')
        if [ -z "$ticket" ]; then
            body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                '{id:$id, from:$s, to:$f, ok:false, error:"missing_ticket"}')
            reply "$from" "$id" "$body"
            continue
        fi
        state_json=$(ticket_state "$ticket")
        if [ "$state_json" = "{}" ]; then
            body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" --arg t "$ticket" \
                '{id:$id, from:$s, to:$f, ok:false, error:"unknown_ticket", detail:$t}')
            reply "$from" "$id" "$body"
            continue
        fi
        stdout_file="$tickets_dir/${ticket}.stdout"
        stdout=""
        if [ -r "$stdout_file" ]; then
            stdout=$(cat "$stdout_file")
        fi
        body=$(printf '%s' "$state_json" \
            | jq -c --arg id "$id" --arg s "$sid" --arg f "$from" \
                   --arg out "$stdout" \
                '{id:$id, from:$s, to:$f, ok:true,
                  result:{ticket_id:.ticket, status:.status,
                          stdout:$out, exit_code:(.exit_code // null),
                          duration_ms:(.duration_ms // null),
                          started_unix:.started_unix,
                          finished_unix:(.finished_unix // null)}}')
        reply "$from" "$id" "$body"
        continue
        ;;
    delegate.cancel)
        ticket=$(printf '%s' "$line" | jq -r '.data.params.ticket_id // .data.params.ticket // empty')
        if [ -z "$ticket" ]; then
            body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                '{id:$id, from:$s, to:$f, ok:false, error:"missing_ticket"}')
            reply "$from" "$id" "$body"
            continue
        fi
        state_json=$(ticket_state "$ticket")
        if [ "$state_json" = "{}" ]; then
            body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" --arg t "$ticket" \
                '{id:$id, from:$s, to:$f, ok:false, error:"unknown_ticket", detail:$t}')
            reply "$from" "$id" "$body"
            continue
        fi
        runner_pid=$(printf '%s' "$state_json" | jq -r '.pid // empty')
        if [ -n "$runner_pid" ] && kill -0 "$runner_pid" 2>/dev/null; then
            # SIGTERM the entire setsid group (negative pid).
            kill -TERM -- "-$runner_pid" 2>/dev/null \
                || kill -TERM "$runner_pid" 2>/dev/null || true
        fi
        # Mark as cancelled; publish result event so subscribers unblock.
        f="$tickets_dir/${ticket}.json"
        jq -c '. + {status:"cancelled", finished_unix:'"$(date +%s)"'}' "$f" \
            >"${f}.tmp.$$" 2>/dev/null \
            && mv "${f}.tmp.$$" "$f"
        new_state=$(ticket_state "$ticket")
        "$agorabus" publish --session-id "$sid" "delegate.result.${ticket}" "$new_state" \
            >/dev/null 2>&1 || true
        log_event "cancel-ok id=$id ticket=$ticket pid=$runner_pid"
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" --arg t "$ticket" \
            '{id:$id, from:$s, to:$f, ok:true,
              result:{ticket_id:$t, status:"cancelled"}}')
        reply "$from" "$id" "$body"
        continue
        ;;
    delegate.cleanup)
        ticket=$(printf '%s' "$line" | jq -r '.data.params.ticket_id // .data.params.ticket // empty')
        prune_old_tickets
        if [ -n "$ticket" ]; then
            rm -f "$tickets_dir/${ticket}.json" "$tickets_dir/${ticket}.stdout" \
                  "$tickets_dir/${ticket}.prompt" 2>/dev/null || true
            log_event "cleanup-ok id=$id ticket=$ticket"
        else
            log_event "cleanup-prune-only id=$id"
        fi
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" --arg t "$ticket" \
            '{id:$id, from:$s, to:$f, ok:true,
              result:{ticket_id:$t, cleaned:true}}')
        reply "$from" "$id" "$body"
        continue
        ;;
    esac

    if [ "$method" != "delegate.run" ]; then
        log_event "unknown-method id=$id from=$from method=$method"
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" --arg m "$method" \
            '{id:$id, from:$s, to:$f, ok:false, error:"unknown_method", detail:("got: "+$m)}')
        reply "$from" "$id" "$body"
        continue
    fi

    # === delegate.run (back-compat) ===
    # PRD §What this builds: keep delegate.run as the obvious composition of
    # start+poll-until-done. Same envelope as today; same head-of-line cost
    # from the *caller's* perspective (they're blocking on a single reply).
    # The worker itself is NOT blocked — the runner is detached, and the
    # loop below polls the ticket state file without holding the dispatch
    # loop. (Concurrent ping in another iteration will still serialize
    # behind the busy-wait; AC7 is the head-of-line test for the new
    # start/poll path, not delegate.run.)
    prompt=$(printf '%s' "$line" | jq -r '.data.params.prompt // empty')
    cwd_req=$(printf '%s' "$line" | jq -r '.data.params.cwd // empty')
    timeout_secs=$(printf '%s' "$line" | jq -r '.data.params.timeout_secs // 300')
    cwd="${cwd_req:-$HOME}"

    if [ -z "$prompt" ]; then
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
            '{id:$id, from:$s, to:$f, ok:false, error:"missing_prompt"}')
        reply "$from" "$id" "$body"
        continue
    fi
    if [ ! -d "$cwd" ]; then
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" --arg c "$cwd" \
            '{id:$id, from:$s, to:$f, ok:false, error:"bad_cwd", detail:$c}')
        reply "$from" "$id" "$body"
        continue
    fi

    log_event "run-begin id=$id from=$from cwd=$cwd timeout=${timeout_secs}s"
    start_ms=$(date +%s%3N)
    ticket=$(spawn_delegate_runner "$from" "$prompt" "$cwd" "$timeout_secs")
    if [ -z "$ticket" ]; then
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
            '{id:$id, from:$s, to:$f, ok:false, error:"spawn_failed"}')
        reply "$from" "$id" "$body"
        continue
    fi
    # Poll until terminal state or hard cap (= timeout_secs + 30s grace).
    hard_cap=$((timeout_secs + 30))
    elapsed=0
    final_status=""
    while [ "$elapsed" -lt "$hard_cap" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
        st=$(ticket_state "$ticket" | jq -r '.status // empty' 2>/dev/null || true)
        case "$st" in
            done|failed|timeout|cancelled) final_status="$st"; break ;;
        esac
    done
    end_ms=$(date +%s%3N)
    dur_ms=$((end_ms - start_ms))

    state_json=$(ticket_state "$ticket")
    stdout_file="$tickets_dir/${ticket}.stdout"
    out=""
    [ -r "$stdout_file" ] && out=$(cat "$stdout_file")
    rc=$(printf '%s' "$state_json" | jq -r '.exit_code // -1')

    log_event "run-end   id=$id ticket=$ticket status=${final_status:-stuck} rc=$rc dur=${dur_ms}ms bytes=${#out}"

    if [ "$final_status" = "done" ] && [ "$rc" = "0" ]; then
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                      --arg out "$out" --argjson dur "$dur_ms" --arg cwd "$cwd" \
            '{id:$id, from:$s, to:$f, ok:true,
              result:{stdout:$out, exit_code:0, duration_ms:$dur, cwd:$cwd}}')
    elif [ "$final_status" = "timeout" ] || [ -z "$final_status" ]; then
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                      --arg out "$out" --argjson dur "$dur_ms" \
            '{id:$id, from:$s, to:$f, ok:false, error:"timeout",
              detail:$out, duration_ms:$dur}')
    elif [ "$final_status" = "cancelled" ]; then
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                      --arg out "$out" --argjson dur "$dur_ms" \
            '{id:$id, from:$s, to:$f, ok:false, error:"cancelled",
              detail:$out, duration_ms:$dur}')
    else
        body=$(jq -nc --arg id "$id" --arg s "$sid" --arg f "$from" \
                      --arg out "$out" --argjson dur "$dur_ms" --argjson code "$rc" \
            '{id:$id, from:$s, to:$f, ok:false, error:"nonzero_exit",
              detail:$out, exit_code:$code, duration_ms:$dur}')
    fi
    reply "$from" "$id" "$body"
done

log_event "worker-exit sid=$sid"
