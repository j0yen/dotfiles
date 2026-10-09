#!/usr/bin/env bash
# agorabus-overlap.sh — UserPromptSubmit: tell the session what its peers do.
# Prints `PEER OVERLAP:` lines when another live session's intent shares our
# skill, PRD topic or a working-path prefix, or holds a claim on a path we are
# in. Advisory only. Fails open: no agorabus, no jq, no daemon → exit 0,
# silent, inside the 200 ms budget.

set -uo pipefail

deadline_ms=$(( ${EPOCHREALTIME/./} / 1000 + 100 ))
AB=$(command -v agorabus) || exit 0
JQ=$(command -v jq) || exit 0

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
sid="${CLAUDE_AGORABUS_SID:-}"
if [ -z "$sid" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    sid_helper="$here/../scripts/agorabus-sid.sh"
    [ -r "$sid_helper" ] || sid_helper="$HOME/.claude/scripts/agorabus-sid.sh"
    [ -r "$sid_helper" ] || exit 0
    # shellcheck disable=SC1090
    source "$sid_helper"
    sid=$(agorabus_derive_sid "$(agorabus_derive_root_pid "$PPID")" "$(basename "$project_dir")")
fi
[ -n "$sid" ] || exit 0

selftest=0; [ "${1:-}" = --self-test ] && selftest=1
INPUT=""; [ "$selftest" = 1 ] || INPUT=$(cat) || true
state_dir="${AGORABUS_INTENT_STATE_DIR:-$HOME/.cache/agorabus}"
tmp=$(mktemp -d 2>/dev/null) || exit 0
trap 'rm -rf "$tmp"' EXIT

# about <outfile> <args…> — run agorabus in the background, polled against the
# shared deadline (`timeout(1)` alone costs ~100 ms). Output stays `[]` on a
# miss.
about() {
    local out="$1" t left pid; shift
    echo '[]' >"$out"
    t=$(( ${EPOCHREALTIME/./} / 1000 ))
    [ "$t" -lt "$deadline_ms" ] || return 0
    "$AB" "$@" >"$out" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        t=$(( ${EPOCHREALTIME/./} / 1000 ))
        if [ "$t" -ge "$deadline_ms" ]; then kill "$pid" 2>/dev/null; echo '[]' >"$out"; return 0; fi
        read -r -t 0.005 -u "$hold_fd" _ 2>/dev/null
    done
    [ -s "$out" ] || echo '[]' >"$out"
    return 0
}
mkfifo "$tmp/hold" && exec {hold_fd}<>"$tmp/hold" || exit 0

about "$tmp/intents" intent list
about "$tmp/claims" claim list
cwd=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$project_dir"

# Overlap rule (see PRD). Prints one line per flagged peer, at most five.
OVERLAP_JQ='
  def under($a; $b): $a == $b or ($a | startswith($b + "/"));
  def related($a; $b): $a != $home and $b != $home and (under($a; $b) or under($b; $a));
  ($intents | map(select(.session_id == $sid)) | .[0] // {}) as $me
  | ([$cwd] + ($me.working_paths // [])) as $mine
  | [ $intents[] | select(.session_id != $sid) | . as $p
      | (($p.skill // "") as $s | $s != "" and $s != "claude" and $s == ($me.skill // "")) as $by_skill
      | (($p.prd // "") as $d | $d != "" and $d == ($me.prd // "")) as $by_prd
      | ([ ($p.working_paths // [])[] as $q | $mine[] | select(related(.; $q)) | $q ] | .[0]) as $by_path
      | select($by_skill or $by_prd or $by_path != null)
      | "PEER OVERLAP: \($p.session_id) is in \($p.skill // "claude") (\($p.prd // ""))"
        + (if $by_path != null and ($by_skill or $by_prd | not) then " [cwd: \($by_path)]" else "" end) ]
  | . + [ $claims[] | . as $c | ($c.session_id // $c.holder // "") as $h
          | select($h != "" and $h != $sid and ($c.path // "") != "" and $c.path != $home)
          | select([ $mine[] | select(under(.; $c.path)) ] | length > 0)
          | "PEER OVERLAP: \($h) holds \($c.path)" + (if ($c.reason // "") != "" then " (\($c.reason))" else "" end) ]
  | .[:5][]'

"$JQ" -rn --arg sid "$sid" --arg cwd "$cwd" --arg home "$HOME" \
    --slurpfile i "$tmp/intents" --slurpfile c "$tmp/claims" '$i[0] as $intents | $c[0] as $claims | '"$OVERLAP_JQ" 2>/dev/null

# Activity block: other sessions' agent.activity events from the last 2 h in
# our own subscriber log, printed only when the set differs from last time.
log="$state_dir/sessions/$sid.ndjson"
last="$state_dir/overlap-$sid.last"
ACTIVITY_JQ='
  def epoch: if type == "number" then . else (try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch 0) end;
  select(type == "object" and .topic == "agent.activity" and (.session_id // "") != $sid)
  | (.ts | epoch) as $t | select($t >= $now - 7200)
  | (.data | if type == "string" then (fromjson? // {}) else . end) as $d
  | [$t, "\($t | strflocaltime("%-I:%M %p")) \(.session_id) \($d.status // "") \($d.summary // "")"]'
if [ -s "$log" ]; then
    "$JQ" -c --argjson now "$(date +%s)" --arg sid "$sid" "$ACTIVITY_JQ" "$log" 2>/dev/null \
        | "$JQ" -rs 'sort_by(.[0]) | .[-5:] | .[][1]' >"$tmp/activity" 2>/dev/null
    if [ -s "$tmp/activity" ]; then
        hash=$(cksum <"$tmp/activity")
        if [ "$selftest" = 1 ] || [ "$hash" != "$(cat "$last" 2>/dev/null)" ]; then
            printf 'PEER ACTIVITY (2h):\n'; cat "$tmp/activity"
            [ "$selftest" = 1 ] || { mkdir -p "$state_dir" && printf '%s\n' "$hash" >"$last"; } 2>/dev/null
        fi
    fi
fi
exit 0
