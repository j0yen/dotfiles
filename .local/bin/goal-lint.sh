#!/usr/bin/env bash
# goal-lint.sh — every `/goal NAME:` line in goal.md must carry the five stop-hook judging properties:
#   P1 judge only the final assistant message · P2 a STATUS block with read times · P3 an "unmeasured" pass
#   P4 a "WAIT until <...>" form · P5 "never require" + "forbid" (no action the turn cannot take).
# Source: memory feedback_goal_stop_hook_judge_final_message_20261021 (SWARM-CONTROL goal looped ~40 turns on
# 2026-10-21; rb CLEARWATER goal refused 4 final messages on 2026-10-22: conditions only met by events outside the turn).
# A goal whose block (up to the next "/goal ", "## " heading or EOF) has a "- Dormant"/"- Parked" line reports dormant|parked, never MISSING.
# Usage: goal-lint.sh [goal.md] | --help | --selftest.  Exit 0 all ok, 1 a goal misses a property, 2 file unreadable.
set -uo pipefail

usage() {
  cat <<'USG'
Usage: goal-lint.sh [goal.md path]   (default: $HOME/Notes/wiki/goal.md)
       goal-lint.sh --selftest | --help
Checks each line starting with "/goal " for five properties (case-insensitive regex):
  P1 final-message-only: judge[s]? ONLY the final | final assistant message
  P2 status block with read times: (STATUS < | STATUS block) AND (read time | read at | timestamp)
  P3 unmeasured pass: unmeasured
  P4 WAIT form: WAIT until <
  P5 no forbidden action: never require AND forbid
A block line matching ^\s*-\s*\**(Dormant|Parked)\b (case-insensitive) marks the goal dormant/parked: reported as such, never MISSING.
Output: "goal-lint: <NAME> <ok|dormant|parked|MISSING P1,P3,...>". Exit 0 all ok, 1 any missing, 2 missing/unreadable file.
USG
}

has() { printf '%s\n' "$1" | grep -Eiq -- "$2"; }

# marker_of LINES... : print dormant|parked if the block lines carry the marker
marker_of() {
  local l m
  for l in "$@"; do
    m="$(printf '%s\n' "$l" | grep -Eio -- '^[[:space:]]*-[[:space:]]*\**(dormant|parked)\b' | grep -Eio 'dormant|parked' | head -n1)"
    [ -n "$m" ] && { printf '%s\n' "${m,,}"; return 0; }
  done
  return 1
}

lint() {
  local f="$1" line name miss rc=0 lines=() i j n mark block
  [ -r "$f" ] && [ -f "$f" ] || { echo "goal-lint: cannot read $f" >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done < "$f"
  n=${#lines[@]}
  for ((i=0; i<n; i++)); do
    line="${lines[i]}"
    case "$line" in "/goal "*) ;; *) continue ;; esac
    name="${line#/goal }"; name="${name%%[ :]*}"
    block=()
    for ((j=i+1; j<n; j++)); do
      case "${lines[j]}" in "/goal "*|"## "*) break ;; esac
      block+=("${lines[j]}")
    done
    if [ ${#block[@]} -gt 0 ] && mark="$(marker_of "${block[@]}")"; then
      echo "goal-lint: $name $mark"; continue
    fi
    miss=""
    has "$line" 'judges? ONLY the final|final assistant message' || miss="$miss,P1"
    { has "$line" 'STATUS <|STATUS block' && has "$line" 'read time|read at|timestamp'; } || miss="$miss,P2"
    has "$line" 'unmeasured' || miss="$miss,P3"
    has "$line" 'WAIT until <' || miss="$miss,P4"
    { has "$line" 'never require' && has "$line" 'forbid'; } || miss="$miss,P5"
    if [ -z "$miss" ]; then echo "goal-lint: $name ok"; else echo "goal-lint: $name MISSING ${miss#,}"; rc=1; fi
  done
  return $rc
}

selftest() {
  local d pass=0 total=0 out rc
  d="$(mktemp -d)" || return 1
  trap 'rm -rf "$d"' RETURN
  local good='/goal GOOD: judge ONLY the final assistant message; STATUS block with read times; unmeasured pass; WAIT until <event>; never require X, forbid Y'
  chk() { total=$((total+1)); [ "$1" = "$2" ] && pass=$((pass+1)); }
  printf '%s\n' "$good" > "$d/a.md"
  out="$(lint "$d/a.md")"; rc=$?; chk "$rc" 0; chk "$out" "goal-lint: GOOD ok"
  printf '%s\n' "${good//unmeasured/pending}" > "$d/b.md"
  out="$(lint "$d/b.md")"; rc=$?; chk "$rc" 1; chk "$out" "goal-lint: GOOD MISSING P3"
  printf '%s\n' '/goal D: nothing' '- **Dormant** headless' > "$d/c.md"
  out="$(lint "$d/c.md")"; rc=$?; chk "$rc" 0; chk "$out" "goal-lint: D dormant"
  printf '%s\n' '/goal P: nothing' '- parked until later' '/goal Q: nothing' > "$d/d.md"
  out="$(lint "$d/d.md")"; rc=$?; chk "$rc" 1; chk "$out" "$(printf 'goal-lint: P parked\ngoal-lint: Q MISSING P1,P2,P3,P4,P5')"
  lint "$d/nonexistent.md" 2>/dev/null; rc=$?; chk "$rc" 2
  if [ "$pass" = "$total" ]; then echo "SELFTEST PASS $pass/0"; return 0; fi
  echo "SELFTEST FAIL"; return 1
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --selftest) selftest; exit $? ;;
esac
lint "${1:-$HOME/Notes/wiki/goal.md}"
