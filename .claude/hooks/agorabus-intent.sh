#!/usr/bin/env bash
# agorabus-intent.sh — keep the agorabus session intent in step with skills.
# Wired three ways in .claude/settings.json:
#   PreToolUse (matcher Skill)  — the model called a skill via the Skill tool
#   UserPromptSubmit            — the user typed `/<skill> …`
#   Stop (arg `stop`)           — turn ended; reset intent to `skill=claude`
# Detection is dream-marker.sh's, generalised from `dream` to any skill.
# Fails open: no agorabus, no jq, or no daemon → exit 0, silent, fast.

set -uo pipefail

deadline_ms=0 # set at the first agorabus call: all calls share one 60 ms budget
AB=$(command -v agorabus) || exit 0
JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

# sid: same derivation as agorabus-session-start.sh (shared helper).
# CLAUDE_AGORABUS_SID pins it for tests.
sid="${CLAUDE_AGORABUS_SID:-}"
if [ -z "$sid" ]; then
    sid_helper="$here/../scripts/agorabus-sid.sh"
    [ -r "$sid_helper" ] || sid_helper="$HOME/.claude/scripts/agorabus-sid.sh"
    [ -r "$sid_helper" ] || exit 0
    # shellcheck disable=SC1090
    source "$sid_helper"
    sid=$(agorabus_derive_sid "$(agorabus_derive_root_pid "$PPID")" "$(basename "$project_dir")")
fi
[ -n "$sid" ] || exit 0

state_dir="${AGORABUS_INTENT_STATE_DIR:-$HOME/.cache/agorabus}"
state="$state_dir/intent-$sid.state"
# One shared deadline for every agorabus call (hook budget is 200 ms): a dead
# daemon costs the budget once, and later calls are skipped once it is spent.
# JSON is built by hand (json_str) — a second jq fork costs ~30 ms here.
json_str() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v"; }
# `timeout(1)` itself costs ~100 ms on this host, so the call runs in the
# background and is polled (read -t on an idle fifo = fork-free sleep).
hold_fd=
ab() {
    local t=${EPOCHREALTIME/./} left pid
    t=$(( t / 1000 ))
    [ "$deadline_ms" -gt 0 ] || deadline_ms=$(( t + 60 ))
    "$AB" "$@" >/dev/null 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        t=${EPOCHREALTIME/./}; t=$(( t / 1000 ))
        left=$(( deadline_ms - t ))
        if [ "$left" -le 0 ]; then kill "$pid" 2>/dev/null; return 0; fi
        if [ -z "$hold_fd" ]; then
            local fifo="$state_dir/.wait-$$"
            mkdir -p "$state_dir" 2>/dev/null
            mkfifo "$fifo" 2>/dev/null && exec {hold_fd}<>"$fifo" && rm -f "$fifo"
            [ -n "$hold_fd" ] || { kill "$pid" 2>/dev/null; return 0; }
        fi
        read -r -t 0.005 -u "$hold_fd" _ 2>/dev/null
    done
    return 0
}

# One jq fork for every field (forks dominate the 200 ms budget); first line
# of args/prompt only; fields joined by \001 so empty ones survive `read`.
IFS=$'\001' read -r SKILL ARGS cwd PROMPT < <(printf '%s' "$INPUT" | "$JQ" -r \
    '[(.tool_input.skill // ""), ((.tool_input.args // "") | split("\n")[0]),
      (.cwd // ""), ((.prompt // "") | split("\n")[0])] | join("\u0001")' 2>/dev/null) || true
[ -n "$cwd" ] || cwd="$project_dir"

start_skill() { # $1=skill name  $2=args text
    local name="$1" args="$2" topic paths p n=1
    topic=${args:0:48}
    topic=${topic,,}
    topic=${topic//[^a-z0-9]/-}
    while [[ $topic == *--* ]]; do topic=${topic//--/-}; done
    topic=${topic#-}; topic=${topic%-}
    paths="$cwd"
    for p in $args; do
        case "$p" in /*) [ "$n" -lt 8 ] && { paths="$paths,$p"; n=$((n + 1)); } ;; esac
    done
    mkdir -p "$state_dir" 2>/dev/null && printf '%s\n' "$name" >"$state"
    ab intent set --session-id "$sid" --skill "/$name" --prd "$topic" --paths "$paths"
    local summary="/$name $topic"
    ab publish --session-id "$sid" agent.activity \
        "{\"agent\":\"claude\",\"status\":\"started\",\"summary\":$(json_str "${summary% }"),\"paths\":[$(json_str "$cwd")]}"
}


stop_turn() {
    [ -s "$state" ] || return 0 # no skill this turn → record nothing
    local name
    name=$(head -n1 "$state")
    rm -f "$state"
    ab intent set --session-id "$sid" --skill claude --prd ""
    ab publish --session-id "$sid" agent.activity \
        "{\"agent\":\"claude\",\"status\":\"finished\",\"summary\":$(json_str "/$name"),\"paths\":[$(json_str "$cwd")]}"
}

if [ "${1:-}" = stop ]; then
    stop_turn
elif [ -n "$SKILL" ]; then
    start_skill "$SKILL" "$ARGS"
elif [ -n "$PROMPT" ]; then
    # typed form: optional leading whitespace, `/<name>` as a whole word
    re='^[[:space:]]*/([A-Za-z0-9][A-Za-z0-9:_-]*)([[:space:]]+(.*))?$'
    if [[ "$PROMPT" =~ $re ]]; then
        start_skill "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    fi
fi
exit 0
