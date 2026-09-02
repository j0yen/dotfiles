#!/usr/bin/env bash
# procstat-cargo.sh — PreToolUse/PostToolUse hook on Bash matcher.
#
# Goal: every `cargo build|test|install|run|check` invocation gets a
# resource receipt recorded, without me having to remember to wrap with
# procstat.
#
# v1 design: PreToolUse records start timestamp + command. PostToolUse
# records end timestamp + exit + duration, and (if any cargo/rustc PIDs
# are still alive — long parallel builds) snaps their RSS via
# `procstat snap`. Receipts append to:
#   ~/.cache/procstat/cargo/<YYYY-MM-DD>.jsonl
#
# Peak-RSS tracking across the cargo subtree is not yet here — that
# requires a sidecar sampler. v1 captures duration + final-moment RSS
# of survivors, which already surfaces "this took 90s and is still
# linking 4 rustc workers" patterns.
#
# Wired in settings.json:
#   PreToolUse  matcher=Bash → procstat-cargo.sh start
#   PostToolUse matcher=Bash → procstat-cargo.sh end ok
#   PostToolUseFailure matcher=Bash → procstat-cargo.sh end error
#
# Best-effort; silent on every failure.

set -uo pipefail
exec 2>/dev/null

mode="${1:-}"
outcome="${2:-ok}"
[ -z "$mode" ] && exit 0

JQ=$(command -v jq || echo /usr/bin/jq)
PROCSTAT="${PROCSTAT:-$HOME/.local/bin/procstat}"
[ -x "$JQ" ] || exit 0

input="$(cat)"
cmd="$("$JQ" -r '.tool_input.command // empty' <<<"$input")"
[ -z "$cmd" ] && exit 0

# Only fire for cargo invocations. Match the bare-word cargo at the
# start of the command (after optional whitespace / cd-prefixes).
# Patterns to match:
#   cargo build|test|install|run|check (anywhere as a "main" command)
shopt -s extglob 2>/dev/null
case " $cmd " in
    *" cargo build"*|*" cargo test"*|*" cargo install"*|\
    *" cargo run"*|*" cargo check"*|*" cargo clippy"*|*" cargo bench"*|\
    "cargo build"*|"cargo test"*|"cargo install"*|\
    "cargo run"*|"cargo check"*|"cargo clippy"*|"cargo bench"*) ;;
    *) exit 0 ;;
esac

session_id="$("$JQ" -r '.session_id // "unknown"' <<<"$input")"
stash_dir="/tmp/procstat-cargo-$(id -u)"
mkdir -p "$stash_dir"
# Stash key — collision risk if same session fires two cargo invocations
# concurrently. Acceptable; we'd drop the second.
key="$(printf '%s' "$session_id $cmd" | sha256sum | cut -c1-16)"
stash_file="$stash_dir/$key.start"

today=$(date -u +%Y-%m-%d)
log_dir="$HOME/.cache/procstat/cargo"
mkdir -p "$log_dir"
log_file="$log_dir/$today.jsonl"

case "$mode" in
  start)
    now_ns=$(date +%s%N)
    printf '%s\n' "$now_ns" > "$stash_file"
    ;;
  end)
    [ -f "$stash_file" ] || exit 0
    start_ns=$(cat "$stash_file")
    rm -f "$stash_file"
    end_ns=$(date +%s%N)
    dur_ms=$(( (end_ns - start_ns) / 1000000 ))

    # Snap any cargo/rustc PIDs still alive (long-tail linker / parallel jobs)
    pids=$(pgrep -f '^(cargo|rustc)( |$)' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    rss_json="null"
    if [ -n "$pids" ] && [ -x "$PROCSTAT" ]; then
        # procstat snap takes pids as positional
        rss_json=$("$PROCSTAT" snap $pids 2>/dev/null || echo "null")
    fi

    # Truncate cmd to keep the log line readable
    cmd_short=$(printf '%s' "$cmd" | head -c 200)

    "$JQ" -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg sid "$session_id" \
        --arg cmd "$cmd_short" \
        --arg outcome "$outcome" \
        --argjson dur "$dur_ms" \
        --argjson rss "$rss_json" \
        '{ts:$ts, session:$sid, cmd:$cmd, outcome:$outcome, dur_ms:$dur, rss_snap:$rss}' \
        >> "$log_file" 2>/dev/null || true
    ;;
esac

exit 0
