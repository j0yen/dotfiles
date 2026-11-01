#!/usr/bin/env bash
# approve.sh — append one Joe approval to ~/.claude/state/approvals.log. Written ONLY by the aide session.
#   approve.sh "<verbatim Joe quote>" "<re: what it approves>"
#   approve.sh --last N        print the last N approval lines (non-comment) prefixed age=<N>m
#   approve.sh --selftest
# Line format: #<id> | <YYYY-MM-DD h:MM AM/PM TZ> | <session> | Joe: "<verbatim>" | re: <what>
#   id = highest existing id + 1 (1 if none), strictly increasing, no dedupe (identical text appends a new id).
# Guard: refuses (exit 3) inside tmux session rb, r7 or ctl. Append-only: never edits existing lines. File mode 600.
# After a successful append it rings the controller: EVENT_SOURCE=approve seat-event.sh ctl "APPROVAL #<id> <re truncated 120>" (skipped if the bin is not executable;
#   a failure never fails the approval). Test overrides: APPROVALS_FILE, SEAT_EVENT_BIN (fake bell), SEAT_EVENT_DRY=1 / EVENTS_DIR (passed through to seat-event.sh).
set -uo pipefail
LOG="${APPROVALS_FILE:-$HOME/.claude/state/approvals.log}"
HEADER='# Joe approvals. Written ONLY by the aide session (approve.sh), append-only. One line per word: #<id> | <YYYY-MM-DD h:MM AM/PM TZ> | <aide session> | Joe: "<verbatim>" | re: <what it approves>'
DATA_RE='^#[0-9]+ \| '

age_lines() { # stdin = log lines; prints "age=<N>m <line>" for data lines
  local line ts e now; now=$(date +%s)
  while IFS= read -r line; do
    [[ "$line" =~ $DATA_RE ]] || continue
    ts="${line#* | }"; ts="${ts%% | *}"
    if e=$(date -d "$ts" +%s 2>/dev/null); then printf 'age=%sm %s\n' "$(( (now - e) / 60 ))" "$line"
    else printf 'age=?m %s\n' "$line"; fi
  done
}

tmux_session() {
  if [ -n "${TMUX_PANE:-}" ]; then tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null
  else tmux display-message -p '#S' 2>/dev/null; fi
}

if [ "${1:-}" = "--last" ]; then
  n="${2:-}"; case "$n" in ''|*[!0-9]*) echo "usage: approve.sh --last N" >&2; exit 2 ;; esac
  [ -r "$LOG" ] || { echo "none"; exit 0; }
  grep -E "$DATA_RE" "$LOG" | tail -n "$n" | age_lines
  exit 0
fi

selftest() {
  local d fail=0 out rc f line id1 id2 id3 ids; d=$(mktemp -d "$HOME/.cache/tmp/approve-selftest.XXXXXX") || { echo "FAIL setup"; return 1; }
  f="$d/approvals.log"; mkdir -p "$d/bin"
  ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
  export APPROVALS_FILE="$f"; unset TMUX TMUX_PANE
  printf '#!/bin/bash\necho "src=${EVENT_SOURCE:-} $*" >>"%s/bell"\n' "$d" >"$d/fake-bell"; chmod +x "$d/fake-bell"
  export SEAT_EVENT_BIN="$d/fake-bell" SEAT_EVENT_DRY=1 EVENTS_DIR="$d/ev"   # never a real tick, never the real events log
  out=$("$0" 'go ahead with the aide split' 're: test approval' 2>&1); rc=$?
  [ $rc -eq 0 ] && ok "append exit 0" || bad "append exit $rc: $out"
  [ "$(stat -c %a "$f")" = 600 ] && ok "mode 600 on create" || bad "mode $(stat -c %a "$f")"
  head -n1 "$f" | grep -q '^# Joe approvals' && ok "header comment present" || bad "header missing"
  line=$(grep -E "$DATA_RE" "$f" | tail -n1)
  re='^#1 \| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{1,2}:[0-9]{2} [AP]M [A-Z]{2,5} \| aide \| Joe: "go ahead with the aide split" \| re: test approval$'
  [[ "$line" =~ $re ]] && ok "line format regex (id #1): $line" || bad "format: $line"
  cp "$f" "$d/snap1"
  chmod 644 "$f"; "$0" 'go ahead with the aide split' 're: test approval' >/dev/null 2>&1   # IDENTICAL text: must append, not dedupe
  [ "$(stat -c %a "$f")" = 600 ] && ok "mode restored to 600 on append" || bad "mode not restored"
  [ "$(grep -cE "$DATA_RE" "$f")" = 2 ] && ok "identical text appended a new line (no dedupe)" || bad "dedupe or lost line"
  CLAUDE_SESSION_NAME=jsy-zz "$0" "third" "re: y" >/dev/null 2>&1
  grep -q '^#3 | .* | jsy-zz | Joe: "third"' "$f" && ok "CLAUDE_SESSION_NAME used, id #3" || bad "session name / id 3"
  ids=$(grep -oE '^#[0-9]+' "$f" | tr -d '#' | tr '\n' ' ')
  [ "$ids" = "1 2 3 " ] && ok "ids strictly increase: $ids" || bad "ids: $ids"
  cmp -s <(head -c "$(stat -c %s "$d/snap1")" "$f") "$d/snap1" && ok "existing bytes untouched (append-only)" || bad "existing bytes changed"
  out=$("$0" "" "re: x" 2>&1); rc=$?; [ $rc -ne 0 ] && ok "empty quote refused (exit $rc)" || bad "empty quote accepted"
  out=$("$0" "q" "" 2>&1); rc=$?; [ $rc -ne 0 ] && ok "empty re refused (exit $rc)" || bad "empty re accepted"
  [ "$(grep -cE "$DATA_RE" "$f")" = 3 ] && ok "refusals wrote nothing" || bad "refusal wrote a line"
  for name in ctl rb r7 other; do
    printf '#!/bin/sh\n[ "$1" = display-message ] && echo %s\n' "$name" > "$d/bin/tmux"; chmod +x "$d/bin/tmux"
    out=$(PATH="$d/bin:$PATH" TMUX=fake "$0" "from $name" "re: z" 2>&1); rc=$?
    if [ "$name" = other ]; then [ $rc -eq 0 ] && ok "tmux session '$name' allowed" || bad "tmux other refused: $out"
    else [ $rc -eq 3 ] && ok "tmux session '$name' refused (exit 3)" || bad "tmux $name exit $rc"; fi
  done
  grep -q 'from ctl' "$f" && bad "ctl line leaked" || ok "no ctl line written"
  out=$("$0" --last 2); echo "$out" | head -n2 | grep -Eq '^age=[0-9]+m #[0-9]+ \| [0-9]{4}-' && [ "$(echo "$out" | wc -l)" = 2 ] && ok "--last 2: $(echo "$out" | head -n1 | cut -c1-50)" || bad "--last: $out"
  [ "$(sed -n 1p "$d/bell")" = 'src=approve ctl APPROVAL #1 test approval' ] && ok "bell after append: '$(sed -n 1p "$d/bell")'" || bad "bell line 1: $(sed -n 1p "$d/bell")"
  [ "$(wc -l <"$d/bell")" = "$(grep -cE "$DATA_RE" "$f")" ] && ok "one bell per appended line, none for refusals ($(wc -l <"$d/bell"))" || bad "bell count $(wc -l <"$d/bell") vs lines $(grep -cE "$DATA_RE" "$f")"
  "$0" 'long' "re: $(printf 'x%.0s' $(seq 1 200))" >/dev/null 2>&1
  [ "$(tail -n1 "$d/bell" | sed -E 's/^src=approve ctl APPROVAL #[0-9]+ //' | tr -d '\n' | wc -c)" = 120 ] && ok "re text truncated to 120 chars in the bell" || bad "truncation: $(tail -n1 "$d/bell" | wc -c)"
  SEAT_EVENT_BIN="$d/nonexistent" "$0" 'no bin' 're: no bell bin' >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && grep -q 'no bin' "$f" && ok "missing bell bin: approval still appended, exit 0" || bad "missing bin: rc $rc"
  printf '#!/bin/bash\nexit 9\n' >"$d/bad-bell"; chmod +x "$d/bad-bell"
  SEAT_EVENT_BIN="$d/bad-bell" "$0" 'bad bin' 're: bell fails' >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && grep -q 'bad bin' "$f" && ok "failing bell: approval still appended, exit 0" || bad "failing bin: rc $rc"
  rm -rf "$d"; return $fail
}
[ "${1:-}" = "--selftest" ] && { selftest; rc=$?; [ $rc -eq 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"; exit $rc; }

quote="${1:-}"; re="${2:-}"
quote=$(printf '%s' "$quote" | tr '\r\n' '  '); re=$(printf '%s' "$re" | tr '\r\n' '  ')
re="${re#re: }"
if [ -z "${quote//[[:space:]]/}" ] || [ -z "${re//[[:space:]]/}" ]; then
  echo 'usage: approve.sh "<verbatim Joe quote>" "<re: what it approves>" (both non-empty)' >&2; exit 2
fi
if [ -n "${TMUX:-}" ]; then
  case "$(tmux_session)" in rb|r7|ctl) echo "approve.sh: refused: only the aide writes approvals (tmux seat $(tmux_session))" >&2; exit 3 ;; esac
fi
mkdir -p "$(dirname "$LOG")"
if [ ! -e "$LOG" ]; then ( umask 077; printf '%s\n' "$HEADER" > "$LOG" ); fi
chmod 600 "$LOG"
# id allocation + append under one lock so concurrent writers never share an id
line=$( ( flock 9
  last=$(grep -oE '^#[0-9]+' "$LOG" | tr -d '#' | sort -n | tail -n1); id=$(( ${last:-0} + 1 ))
  l=$(printf '#%s | %s | %s | Joe: "%s" | re: %s' "$id" "$(date '+%F %-I:%M %p %Z')" "${CLAUDE_SESSION_NAME:-aide}" "$quote" "$re")
  printf '%s\n' "$l" >> "$LOG"; printf '%s' "$l" ) 9>>"$LOG" )
chmod 600 "$LOG"
echo "approve.sh: appended: $line"
EV="${SEAT_EVENT_BIN:-$HOME/.local/bin/seat-event.sh}"
if [ -x "$EV" ]; then   # ring the controller; never fails the approval
  id="${line#\#}"; id="${id%% *}"
  EVENT_SOURCE=approve "$EV" ctl "APPROVAL #$id ${re:0:120}" >/dev/null 2>&1 || true
fi
