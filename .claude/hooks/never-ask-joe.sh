#!/usr/bin/env bash
# never-ask-joe.sh: Stop + PreToolUse(AskUserQuestion) hook (approvals #80, Joe 10-29 10:47 PM "NEVER ASK ME AGAIN. RECORD IT. CODE IT. BUILD IT.").
# Fleet seats act on their recommendation and report; they never end a turn on a question for Joe.
# No-op unless WM_SEAT is non-empty (a plain session is never touched).
#   Stop: stop_hook_active=true -> exit 0 (no loop). Else the LAST assistant entry of the transcript, its text blocks only, is
#         matched PER LINE against the ask shapes; a line that also states the not-done form is exempt. Any ask line -> block.
#   PreToolUse AskUserQuestion: deny.
# Fails OPEN (exit 0, never 2) on a parse error or a missing transcript, and logs parse-error / transcript-missing.
# Every block/deny appends "<iso8601> | <seat> | stop|askuser | <matched phrase>" to $NAJ_STATE_DIR/fires.log
# (default ~/.local/state/never-ask-joe). Message text beyond the matched phrase is never logged.
set -euo pipefail

[ -n "${WM_SEAT:-}" ] || exit 0

STATE_DIR="${NAJ_STATE_DIR:-$HOME/.local/state/never-ask-joe}"
REASON='NEVER ASK JOE (approvals #80): do the recommended action now, log approve.sh (aide) or a DECISION row (seat), report what was done.'
ASK_RE='reply "?(yes|go)|say "?go|\bwant me to\b|\bshould I\b|\bshall I\b|(one|a) decision for you|your (call|word|approval|ok)\b|needs? (joe'"'"'?s|your) (word|approval|ok)|\bdo you want\b|\bwould you like\b|\blet me know\b|please (confirm|approve|advise)|waiting (on|for) (joe|you)\b|which (one|option)\b|ok to (proceed|apply)|(proceed|confirm|approve)\?|until you say( otherwise)?|stays as-is until|\b(can|could|will|would|happy to)\b.{0,40}\bif you (want|like|prefer)\b|\bif you (want|like|prefer)[,.]?[[:space:]]*$|\byour choice\b[[:space:]]*[:?]|\b(hold(ing)?|wait(ing)?|pending|parked|left as[- ]is|unchanged)\b.{0,40}\b(until|pending|for) (you|your|joe)\b|\bawaiting (your|joe)\b|\bon your (go|signal|nod|say-so)\b|\bunless you (say|object)\b'
EXEMPT_RE='not done|reported as not done|refused'

log_fire() { # kind phrase
  { mkdir -p "$STATE_DIR" && printf '%s | %s | %s | %s\n' "$(date -Is)" "$WM_SEAT" "$1" "$2" >>"$STATE_DIR/fires.log"; } 2>/dev/null || true
}

input="$(cat)"
if ! jq -e . >/dev/null 2>&1 <<<"$input"; then log_fire stop parse-error; exit 0; fi

tool="$(jq -r '.tool_name // empty' <<<"$input")"
if [ "$tool" = "AskUserQuestion" ]; then
  log_fire askuser AskUserQuestion
  jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi
[ -z "$tool" ] || exit 0   # some other tool: not ours

[ "$(jq -r '.stop_hook_active // false' <<<"$input")" != "true" ] || exit 0

tp="$(jq -r '.transcript_path // empty' <<<"$input")"
if [ -z "$tp" ] || [ ! -r "$tp" ]; then log_fire stop transcript-missing; exit 0; fi

if ! text="$(jq -rs '
    [ .[] | select(type=="object" and .type=="assistant") ] | last // empty
    | .message.content
    | if type=="string" then . else ([ .[]? | select(.type=="text") | .text ] | join("\n")) end
  ' "$tp" 2>/dev/null)"; then
  log_fire stop parse-error; exit 0
fi
[ -n "$text" ] || exit 0

while IFS= read -r line; do
  phrase="$(grep -oiE -m1 "$ASK_RE" <<<"$line" | head -n1 || true)"
  [ -n "$phrase" ] || continue
  if grep -qiE "$EXEMPT_RE" <<<"$line"; then continue; fi
  log_fire stop "$phrase"
  jq -nc --arg r "$REASON" '{decision:"block",reason:$r}'
  exit 0
done <<<"$text"
exit 0
