#!/usr/bin/env bash
# probe-gate.sh — PreToolUse hook (Bash): deny read-only "probe" commands
# (ssh/scp/rsync/journalctl/systemctl/sqlite3/gh/hcloud/cargo/rustc/du/df/
# find/fuser/lsof/ps/pgrep/curl/wget/jq/grep/rg/egrep/awk/sed-read/head/
# tail/cat/less/wc/stat/ls/tree/git/python) when the SESSION's own model is
# fable or opus, per CLAUDE.md "Model routing — cheapest capable model
# always": Fable/Opus does planning/synthesis only and must delegate any
# probe to a haiku scout/runner/triage subagent. Sonnet/haiku sessions (or
# an undetectable model) are never gated — this only turns the expensive
# tier's own hands off probing.
#
# Model detection is per-CALL, not per-session: a subagent's Bash call
# arrives with the SAME session_id/transcript_path as its parent (the
# subagent does not get its own transcript file), so "last assistant model
# in the transcript" picks up the PARENT's model and mis-gates the
# subagent (2026-09-20 incident: a haiku runner got denied as if it were
# fable). The fix is to key off the hook JSON's own `.tool_use_id`: find
# the transcript line whose assistant message content array contains a
# tool_use block with that id — main-session line or, failing that, a
# sidechain line (subagent turns are logged with "isSidechain":true and
# carry their OWN "model") — and read THAT line's model. tool_use_id not
# found (or absent) -> unknown model -> allow, same as any other unknown.
#
# Allow-list (checked first, overrides the deny words) covers writes into
# the session's own scratch spaces: ~/.claude/projects/*/memory/,
# ~/.claude/scratch/, the session scratchpad under /tmp/claude-1000/, and
# the PRD workspace ~/Documents/PRDs — plus bare date/echo/printf/mkdir -p.
# touch/rm of a ~/.claude/.allow-* flag is allowed UNCONDITIONALLY, under
# every model, so the escape hatch itself can never be trapped by a
# model-detection bug.
#
# One-shot override: touch ~/.claude/.allow-fable-bash (consumed on use).
# Fails OPEN on any parse error or missing jq — a bug here must never
# silently block a live buildloop's Bash calls.

set -uo pipefail

HOME_DIR="${HOME}"
OVERRIDE_FLAG="${HOME_DIR}/.claude/.allow-fable-bash"
LEDGER_DIR="${HOME_DIR}/.cache/token-ledger"
LEDGER_FILE="${LEDGER_DIR}/probe-gate.jsonl"

JQ=$(command -v jq) || exit 0

INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null) || exit 0
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null) || exit 0
TOOL_USE_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_use_id // empty' 2>/dev/null) || exit 0

# --- 0. Unconditional escape hatch -----------------------------------------
# touch/rm of any ~/.claude/.allow-* flag must never itself be gate-able,
# under any model, correctly-detected or not.
ALLOW_FLAG_RE='(^|[[:space:]])(touch|rm)([[:space:]]+-[^[:space:]]+)*[[:space:]]+.*\.claude/\.allow-[A-Za-z0-9_-]+'
if printf '%s' "$CMD" | grep -qE "$ALLOW_FLAG_RE"; then
    exit 0
fi

# --- 1. Detect the model of the assistant turn that emitted THIS call -----
MODEL=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ] && [ -n "$TOOL_USE_ID" ]; then
    MODEL=$(tail -n 2000 "$TRANSCRIPT_PATH" 2>/dev/null \
        | "$JQ" -R -c 'fromjson? // empty' \
        | "$JQ" -s -r --arg id "$TOOL_USE_ID" '
            [.[] | select(.type=="assistant")
                 | select([.message.content[]?.id?] | index($id))]
            | last
            | .message.model? // empty
          ' 2>/dev/null)
fi

MODEL_LC=$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')

# Only fable/opus are gated; sonnet/haiku/unknown (including "not found in
# the transcript window") always allow.
if ! printf '%s' "$MODEL_LC" | grep -qE '(^|-)(opus|fable)($|-)'; then
    exit 0
fi

# --- 2. One-shot override -------------------------------------------------
if [ -f "$OVERRIDE_FLAG" ]; then
    rm -f "$OVERRIDE_FLAG" 2>/dev/null
    echo "probe-gate: one-shot override consumed" >&2
    exit 0
fi

# --- 3. Allow-list (checked first) ----------------------------------------
# Matches ~/.claude/projects/*/memory/, ~/.claude/scratch/, the session
# scratchpad under /tmp/claude-1000/, and ~/Documents/PRDs — in either
# tilde, $HOME, or literal-home-dir form.
ALLOWED_PATH_RE='(~|\$HOME|'"${HOME_DIR//\//\\/}"')/\.claude/projects/[^ "'"'"']+/memory(/|$|["'"'"'[:space:]])'
ALLOWED_PATH_RE="${ALLOWED_PATH_RE}|(~|\\\$HOME|${HOME_DIR//\//\\/})/\\.claude/scratch(/|\$|[\"'[:space:]])"
ALLOWED_PATH_RE="${ALLOWED_PATH_RE}|/tmp/claude-1000/[^ \"']*/scratchpad(/|\$|[\"'[:space:]])"
ALLOWED_PATH_RE="${ALLOWED_PATH_RE}|(~|\\\$HOME|${HOME_DIR//\//\\/})/Documents/PRDs(/|\$|[\"'[:space:]])"

is_allowed() {
    local c="$1" fw="$2"

    case "$fw" in
        date|echo|printf) return 0 ;;
        mkdir) printf '%s' "$c" | grep -qE '(^|[[:space:]])-p([[:space:]]|$)' && return 0 ;;
    esac

    if printf '%s' "$c" | grep -qE "$ALLOWED_PATH_RE"; then
        # A write shape targeting an allowed path: append heredoc/redirect,
        # sed -i, touch/rm of an allow-* flag, or git add/commit/push.
        if printf '%s' "$c" | grep -qE '>>' \
            || printf '%s' "$c" | grep -qE '(^|[[:space:]])sed[[:space:]]+-i' \
            || printf '%s' "$c" | grep -qE '(^|[[:space:]])(touch|rm)([[:space:]]|$)' \
            || printf '%s' "$c" | grep -qE '(^|[[:space:]])git[[:space:]].*(add|commit|push)([[:space:]]|$)'; then
            return 0
        fi
    fi
    return 1
}

# --- 4. Deny-list -----------------------------------------------------------
DENY_RE='^(ssh|scp|rsync|journalctl|systemctl|sqlite3|gh|hcloud|cargo|rustc|du|df|find|fuser|lsof|ps|pgrep|curl|wget|jq|grep|rg|egrep|awk|sed|head|tail|cat|less|wc|stat|ls|tree|git|python3|python)$'

# Strip env assignments, leading "(" and "cd ... &&" chains, per spec.
strip_prefix() {
    local c="$1"
    c="${c#"${c%%[![:space:]]*}"}"
    while [[ "$c" =~ ^\(+[[:space:]]* ]]; do
        c="${c#"${BASH_REMATCH[0]}"}"
    done
    while [[ "$c" =~ ^[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|\'[^\']*\'|[^[:space:]]*)[[:space:]]+ ]]; do
        c="${c#"${BASH_REMATCH[0]}"}"
    done
    local cd_re='^cd[[:space:]]+[^&]+&&[[:space:]]*'
    while [[ "$c" =~ $cd_re ]]; do
        c="${c#"${BASH_REMATCH[0]}"}"
    done
    printf '%s' "$c"
}

first_word_of() {
    local c="$1" w=""
    if [[ "$c" =~ ^([^[:space:]]+) ]]; then
        w="${BASH_REMATCH[1]}"
    fi
    w="${w%;}"
    w="${w#\"}"; w="${w%\"}"
    w="${w#\'}"; w="${w%\'}"
    printf '%s' "$w"
}

# is_probe_word WORD CMD -> 0 if WORD is a probe (honors the sed -i exception)
is_probe_word() {
    local w="$1" c="$2"
    if [ "$w" = "sed" ]; then
        printf '%s' "$c" | grep -qE '(^|[[:space:]])-i' && return 1
        return 0
    fi
    printf '%s' "$w" | grep -qE "$DENY_RE"
}

STRIPPED=$(strip_prefix "$CMD")
FIRST_WORD=$(first_word_of "$STRIPPED")

PROBE=1
if is_allowed "$CMD" "$FIRST_WORD"; then
    PROBE=0
elif is_probe_word "$FIRST_WORD" "$STRIPPED"; then
    PROBE=1
elif [ "$FIRST_WORD" = "sudo" ]; then
    REM="${STRIPPED#sudo}"
    REM="${REM# }"
    while [[ "$REM" =~ ^-[^[:space:]]*[[:space:]]+ ]]; do
        REM="${REM#"${BASH_REMATCH[0]}"}"
    done
    SUDO_TARGET=$(first_word_of "$REM")
    if is_probe_word "$SUDO_TARGET" "$REM"; then
        PROBE=1
    else
        PROBE=0
    fi
elif printf '%s' "$CMD" | grep -qE '(^|[;&|]|&&|\|\|)[[:space:]]*ssh([[:space:]]|$)'; then
    PROBE=1
elif printf '%s' "$CMD" | grep -qE '\|[[:space:]]*(head|tail|grep)\b'; then
    PROBE=1
else
    PROBE=0
fi

if [ "$PROBE" -eq 0 ]; then
    exit 0
fi

# --- 5. Deny ---------------------------------------------------------------
mkdir -p "$LEDGER_DIR" 2>/dev/null
CMD_HEAD=$(printf '%s' "$CMD" | cut -c1-80)
"$JQ" -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sid "$SESSION_ID" \
    --arg fw "$FIRST_WORD" \
    --arg ch "$CMD_HEAD" \
    '{ts:$ts, session_id:$sid, first_word:$fw, cmd_head:$ch}' >> "$LEDGER_FILE" 2>/dev/null

{
    echo "probe-gate: Fable/Opus runs no probes."
    echo "Delegate: Agent(subagent_type=runner|scout|triage, model=haiku)"
    echo "with every remote command written as ssh orch \"…\"."
    echo "One-shot override: touch ~/.claude/.allow-fable-bash"
} >&2
exit 2
