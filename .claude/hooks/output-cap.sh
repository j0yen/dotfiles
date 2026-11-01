#!/usr/bin/env bash
# output-cap.sh — PreToolUse hook (Bash): make "tool output > 2 KB goes to a
# file, read a tail" a mechanism. For an expensive-model call (opus/fable)
# the command is REWRITTEN (never refused) so its combined stdout+stderr goes
# to a file; the model then receives the whole output if it is <= 2048
# bytes, else the first 15 lines + a marker (bytes, lines, file path) + the
# last 15 lines, each line cut to 400 chars. The exit code is preserved.
#
# Mechanism: hookSpecificOutput.updatedInput (PreToolUse; verified as a
# documented field in the installed claude-code binary, 2.1.x: "updatedInput
# - Modified tool input (PreToolUse only)"). permissionDecision "allow" is
# required alongside it; NOTE it also skips the permission prompt for this
# call (moot under bypass permissions; deny rules still apply).
#
# Scope (enable file ~/.claude/state/output-cap.enabled, first word):
#   aide = only the interactive aide (no WM_SEAT, no TMUX, host carbon);
#   all  = every session. Missing / any other word -> off.
# Model detection is per-CALL via .tool_use_id in the transcript, exactly as
# probe-gate.sh section 1 (subagent calls share the parent's transcript).
#
# Fails OPEN: any error, missing jq, unknown model, odd input -> exit 0 with
# no output (the command runs untouched). The wrapped script is checked with
# `bash -n` before it is emitted, so a rewrite can never introduce a syntax
# error.
#
# Known limits (documented, not hidden):
#   - the command runs in a SUBSHELL: `cd`, `export`, `set -e`, `exec`,
#     `exit` inside it do not leak out. cwd persistence between calls is NOT
#     claimed — a command that only `cd`s to change the next call's cwd
#     loses that effect when wrapped. Chain `cd x && ...` in one call.
#   - stdout and stderr are merged in the file (order preserved).
#   - not wrapped: run_in_background, trailing `&`, any stdout redirection or
#     `>`/`>(`, existing `__oc=`, a trailing backslash, a command that fails
#     `bash -n`, before or after wrapping.
#
# --stanza   print the settings.json PreToolUse matcher group (not installed)
# --selftest run tests/output-cap.test.sh next to this hook's repo

set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
STANZA='{"matcher":"Bash","hooks":[{"type":"command","command":"/home/jsy/.claude/hooks/output-cap.sh","timeout":10}]}'
case "${1:-}" in
    --stanza) printf '%s\n' "$STANZA"; exit 0 ;;
    --selftest) exec bash "$(dirname "$SELF")/../../tests/output-cap.test.sh" ;;
esac

HOME_DIR="${HOME}"
ENABLE_FILE="${HOME_DIR}/.claude/state/output-cap.enabled"
LEDGER_DIR="${HOME_DIR}/.cache/token-ledger"
LEDGER_FILE="${LEDGER_DIR}/output-cap.jsonl"
FALLBACK_DIR="${HOME_DIR}/.cache/output-cap"

# --- a. enable file / scope -------------------------------------------------
[ -r "$ENABLE_FILE" ] || exit 0
SCOPE=""
read -r SCOPE _ < "$ENABLE_FILE" 2>/dev/null || true
case "$SCOPE" in aide | all) ;; *) exit 0 ;; esac

JQ=$(command -v jq) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
BG=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.run_in_background // false' 2>/dev/null) || exit 0
SESSION_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null) || exit 0
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null) || exit 0
TOOL_USE_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_use_id // empty' 2>/dev/null) || exit 0

# --- b. aide scope: same predicate as probe-gate.sh section 1b --------------
if [ "$SCOPE" = aide ]; then
    if [ -n "${WM_SEAT:-}" ] || [ -n "${TMUX:-}" ] \
        || [ "${PROBE_GATE_HOSTNAME:-$(hostname 2>/dev/null)}" != carbon ]; then
        exit 0
    fi
fi

# --- d. cheap skips first (reordered before the transcript scan) ------------
[ "$BG" = true ] && exit 0
case "$CMD" in *'__oc='*) exit 0 ;; esac          # idempotent
TRIM="${CMD%"${CMD##*[![:space:]]}"}"
while [ -n "$TRIM" ] && { [ "${TRIM: -1}" = ";" ] || [[ "${TRIM: -1}" == [[:space:]] ]]; }; do
    TRIM="${TRIM%?}"
done
[ -n "$TRIM" ] || exit 0
case "$TRIM" in
    *'&&') ;;                                      # (syntax error anyway; bash -n decides)
    *'&') exit 0 ;;                                # trailing & = background
esac
[ "${TRIM: -1}" = "\\" ] && exit 0                 # trailing line continuation
# Any remaining `>` after removing harmless fd dups / stderr-to-null = a
# stdout redirect (or a false positive such as `awk '$1>3'`: false skips are
# fine, false wraps are not). `<(`-free: `>(` is caught by the `>` too.
STRIPPED=${CMD//2>&1/}
STRIPPED=${STRIPPED//>&2/}
STRIPPED=${STRIPPED//>&1/}
STRIPPED=${STRIPPED//2>\/dev\/null/}
case "$STRIPPED" in *'>'*) exit 0 ;; esac
printf '%s\n' "$CMD" | bash -n 2>/dev/null || exit 0

# --- c. model of THIS call (probe-gate.sh section 1) ------------------------
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
printf '%s' "$MODEL_LC" | grep -qE '(^|-)(opus|fable)($|-)' || exit 0

# tool_use_id lands in a file name and a quoted string: refuse odd characters.
case "$TOOL_USE_ID" in '' | *[!A-Za-z0-9_-]*) exit 0 ;; esac

# --- scratch dir: the session scratchpad if derivable, else the fallback ----
OC_DIR="$FALLBACK_DIR"
if [ -n "$SESSION_ID" ] && [[ "$SESSION_ID" != *[!A-Za-z0-9-]* ]]; then
    for d in "${TMPDIR:-$HOME_DIR/.cache/tmp}/claude-$(id -u)"/*/"$SESSION_ID"/scratchpad; do
        if [ -d "$d" ] && [ -w "$d" ]; then OC_DIR="$d"; break; fi
    done
fi
case "$OC_DIR" in *"'"*) OC_DIR="$FALLBACK_DIR" ;; esac   # single quote would break the quoting below
case "$LEDGER_FILE$OC_DIR" in *"'"*) exit 0 ;; esac
mkdir -p "$OC_DIR" "$LEDGER_DIR" 2>/dev/null || exit 0
find "$OC_DIR" -maxdepth 1 -name 'oc-*.out' -mmin +2880 -delete 2>/dev/null || true

OC_FILE="${OC_DIR}/oc-${TOOL_USE_ID}.out"

# --- wrap -------------------------------------------------------------------
# Subshell (not { }) so exit / set -e / exec inside cannot skip the emit; the
# trailing `( exit "$__rc" )` sets $? without ending the harness shell. A
# short file (< 30 newlines, e.g. one 60 KB line) is cut once instead of
# head+tail printing the same lines twice.
IFS= read -r -d '' TAIL_PART <<'WRAP' || true
) >"$__oc" 2>&1; __rc=$?
__n=$(stat -c %s "$__oc" 2>/dev/null); __n=${__n:-0}
__l=$(wc -l <"$__oc" 2>/dev/null); __l=${__l:-0}
if [ "$__n" -le 2048 ]; then __cap=false; cat "$__oc"
else __cap=true
  if [ "$__l" -lt 30 ]; then cut -c1-400 "$__oc"; else head -n 15 "$__oc" | cut -c1-400; fi
  printf '\n… [output-cap: %s bytes, %s lines; full output: %s]\n' "$__n" "$__l" "$__oc"
  if [ "$__l" -ge 30 ]; then tail -n 15 "$__oc" | cut -c1-400; fi
fi
WRAP
LEDGER_TAIL="command -v jq >/dev/null 2>&1 && jq -nc --arg ts \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" --arg id '${TOOL_USE_ID}' --argjson rc \"\$__rc\" --argjson b \"\$__n\" --argjson l \"\$__l\" --argjson cap \"\$__cap\" '{ts:\$ts,phase:\"done\",tool_use_id:\$id,rc:\$rc,bytes:\$b,lines:\$l,capped:\$cap}' >>'${LEDGER_FILE}' 2>/dev/null; true"

WRAPPED=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "__oc='${OC_FILE}'; mkdir -p \"\$(dirname \"\$__oc\")\"" \
    "(" \
    "$CMD" \
    "$TAIL_PART" \
    "$LEDGER_TAIL" \
    '( exit "$__rc" )')

printf '%s\n' "$WRAPPED" | bash -n 2>/dev/null || exit 0

OUT=$("$JQ" -nc --arg cmd "$WRAPPED" --argjson ti "$(printf '%s' "$INPUT" | "$JQ" -c '.tool_input')" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:($ti + {command:$cmd})}}' 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0

"$JQ" -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sid "$SESSION_ID" \
    --arg id "$TOOL_USE_ID" \
    --arg scope "$SCOPE" \
    --arg model "$MODEL_LC" \
    --arg ch "$(printf '%s' "$CMD" | cut -c1-80)" \
    '{ts:$ts, phase:"wrap", session_id:$sid, tool_use_id:$id, scope:$scope, model:$model, cmd_head:$ch}' \
    >> "$LEDGER_FILE" 2>/dev/null || true

printf '%s\n' "$OUT"
exit 0
