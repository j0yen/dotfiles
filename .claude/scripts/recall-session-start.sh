#!/usr/bin/env bash
# recall-session-start.sh — emit relevant memories at SessionStart.
#
# Loads user-scoped memories (preferences, feedback), project-scoped
# memories for the current working directory's basename, and self-scoped
# memories (how I, Claude, work in this environment). The output goes
# into the model's context at the start of each session.
#
# v0.6.1 weather: when session_id is available (read from stdin JSON's
# .session_id, or $CLAUDE_SESSION_ID), the surfaced memory IDs are
# appended to $RECALL_WEATHER_DIR/<sid>/recalled.json so the Stop hook
# can implicit-accept them (PRD-recall-outcome-feedback AC2).
#
# v0.10.0 surfaced-tracking (PRD-recall-surfaced-tracking AC4): also
# writes $RECALL_WEATHER_DIR/<sid>/surfaced.json with the same ids.
# For SessionStart, surfaced == recalled (same event). The Stop hook
# calls `recall feedback --surfaced` on surfaced.json ids BEFORE the
# accept step, so the two counters remain distinct.
#
# Silent if recall is not installed or the store is empty.

set -uo pipefail

RECALL_BIN="${RECALL_BIN:-$HOME/.local/bin/recall}"
[ -x "$RECALL_BIN" ] || exit 0

JQ="${JQ:-$(command -v jq || echo /usr/bin/jq)}"
sid=""
if [ -x "$JQ" ] && [ ! -t 0 ]; then
    raw="$(cat - 2>/dev/null || true)"
    if [ -n "$raw" ]; then
        sid="$("$JQ" -r '.session_id // empty' <<<"$raw" 2>/dev/null || true)"
    fi
fi
sid="${sid:-${CLAUDE_SESSION_ID:-}}"

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
project="$(basename "$cwd")"
limit="${RECALL_SESSION_LIMIT:-8}"

# weather: accumulate every id emitted so the Stop hook can auto-accept.
surfaced_ids=""

# Extract the markdown body from `recall show <id>` (everything after the
# closing `---` of the frontmatter), and squash to one line.
body_of() {
  "$RECALL_BIN" show "$1" 2>/dev/null \
    | awk 'BEGIN{f=0} /^---$/ {if (f==0) {f=1; next} else if (f==1) {f=2; next}} f==2 {print}' \
    | tr '\n' ' ' \
    | sed 's/  */ /g; s/^ //; s/ $//'
}

emit_section() {
  local subject="$1" header="$2"
  local out ids id text
  out="$("$RECALL_BIN" list --subject "$subject" --limit "$limit" 2>/dev/null)"
  case "$out" in
    "(no memories)"*|"") return 0 ;;
  esac
  ids="$(printf '%s\n' "$out" | awk '{print $1}')"
  [ -z "$ids" ] && return 0
  surfaced_ids="${surfaced_ids}${ids}"$'\n'
  printf '\n%s\n' "$header"
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    text="$(body_of "$id")"
    [ -n "$text" ] && printf -- '- %s\n' "$text"
  done <<EOF
$ids
EOF
}

total="$("$RECALL_BIN" list --limit 1 2>/dev/null | head -n1)"
case "$total" in
  "(no memories)"*|"") exit 0 ;;
esac

printf 'recall: relevant memories for this session\n'
emit_section "user"             "user:"
emit_section "project:$project" "project:$project:"
emit_section "self"             "self:"

# weather: write the surfaced IDs so the Stop hook can implicit-accept.
# Also writes surfaced.json (AC4 — PRD-recall-surfaced-tracking): for
# SessionStart, surfaced == recalled (same event); the Stop hook uses both
# files to record distinct counters.
if [ -n "$sid" ] && [ -x "$JQ" ] && [ -n "${surfaced_ids// /}" ]; then
    weather_dir="${RECALL_WEATHER_DIR:-$HOME/.cache/recall-weather}/$sid"
    if mkdir -p "$weather_dir" 2>/dev/null; then
        # De-dup, drop blanks, JSON-array-ify.
        ids_json="$(printf '%s' "$surfaced_ids" \
            | awk 'NF && !seen[$0]++' \
            | "$JQ" -R . \
            | "$JQ" -s . 2>/dev/null)"
        # recalled.json — Stop hook auto-accept step.
        printf '%s\n' "$ids_json" > "$weather_dir/recalled.json.tmp" 2>/dev/null \
            && mv "$weather_dir/recalled.json.tmp" "$weather_dir/recalled.json" 2>/dev/null || true
        # surfaced.json — Stop hook surfaced-increment step (AC4).
        printf '%s\n' "$ids_json" > "$weather_dir/surfaced.json.tmp" 2>/dev/null \
            && mv "$weather_dir/surfaced.json.tmp" "$weather_dir/surfaced.json" 2>/dev/null || true
    fi
fi
