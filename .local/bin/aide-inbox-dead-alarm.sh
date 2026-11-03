#!/usr/bin/env bash
# aide-inbox-dead-alarm.sh: ring when the aide inbox has unread lines and no consumer has read them within the window (A647, open-asks 1297).
# The inbox is $EVENTS_DIR/aide-events.log, read by .claude/hooks/aide-inbox.sh, which advances $EVENTS_DIR/aide-events.cursor (byte offset). Dead =
# at least one whole unread line whose own timestamp (leading ISO field, else the log mtime) is older than the window.
#   exit 0  healthy: nothing unread, or the oldest unread line is still inside the window (prints nothing)
#   exit 1  dead: prints ONE alarm line "aide-inbox-dead: N unread byte(s), oldest M min old (window W min)"
#   exit 64 usage
# Window: 30 min default (no window was named in the row notes). Read-only: it never touches the log or cursor.
# PREMISE: an aide inbox line is read by a hook on the aide's next prompt or session start, so an unread line older than the window means no consumer is alive
# Env: EVENTS_DIR (default ~/.cache/fleet-dash) AIDE_INBOX_DEAD_WINDOW_MIN AIDE_INBOX_DEAD_NOW (epoch, tests)
# --selftest: fakes in a throwaway dir.
set -u
EV="${EVENTS_DIR:-${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}}"
num() { [[ "${1:-}" =~ ^[0-9]{1,12}$ ]] && printf '%s' "$1" || printf 0; }
now() { printf '%s' "${AIDE_INBOX_DEAD_NOW:-$(date +%s)}"; }

check() {
  local log="$EV/aide-events.log" cur="$EV/aide-events.cursor" win size off unread first ts t age
  win="$(num "${AIDE_INBOX_DEAD_WINDOW_MIN:-30}")"; [ "$win" -gt 0 ] || win=30
  [ -f "$log" ] || return 0
  size="$(stat -c %s "$log" 2>/dev/null || echo 0)"; off="$(num "$(head -c 20 "$cur" 2>/dev/null)")"
  [ "$off" -gt "$size" ] && off=0            # log rotated/truncated since the last read
  [ "$size" -gt "$off" ] || return 0
  unread="$(tail -c +$((off + 1)) "$log" 2>/dev/null; printf x)"; unread="${unread%x}"   # x keeps the trailing newline $() would strip
  case "$unread" in *$'\n'*) ;; *) return 0 ;; esac   # a writer mid-append leaves a partial tail: no whole line yet
  first="$(printf '%s\n' "$unread" | head -n1)"
  ts="${first%% *}"; t="$(date -d "$ts" +%s 2>/dev/null)" || t=""
  [[ "$t" =~ ^[0-9]+$ ]] || t="$(stat -c %Y "$log" 2>/dev/null || echo 0)"
  age=$(( ( $(now) - t ) / 60 )); [ "$age" -ge 0 ] || age=0
  [ "$age" -gt "$win" ] || return 0
  echo "aide-inbox-dead: $((size - off)) unread byte(s), oldest $age min old (window $win min)"
  return 1
}

selftest() {
  local T pass=0 total=0 out rc L C now=1000000000
  T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN; L="$T/aide-events.log"; C="$T/aide-events.cursor"
  chk() { total=$((total + 1)); if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "PASS $1"; else echo "FAIL $1"; fi; }
  run() { out="$(EVENTS_DIR="$T" AIDE_INBOX_DEAD_NOW="$now" AIDE_INBOX_DEAD_WINDOW_MIN="${1:-}" bash "$SELF" 2>&1)"; rc=$?; }
  local old new; old="$(date -u -d "@$((now - 3600))" +%Y-%m-%dT%H:%M:%S+00:00)"; new="$(date -u -d "@$((now - 300))" +%Y-%m-%dT%H:%M:%S+00:00)"
  run; [ $rc = 0 ] && [ -z "$out" ]; chk "no log: healthy" $?
  : >"$L"; run; [ $rc = 0 ] && [ -z "$out" ]; chk "empty log: healthy" $?
  printf '%s | rb | old line\n' "$old" >"$L"; run
  [ $rc = 1 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && [[ $out == "aide-inbox-dead: "*"oldest 60 min old (window 30 min)" ]]; chk "old unread line: rc 1 + one alarm line ($out)" $?
  wc -c <"$L" >"$C"; run; [ $rc = 0 ] && [ -z "$out" ]; chk "cursor at EOF: healthy" $?
  printf '%s | rb | fresh line\n' "$new" >>"$L"; run; [ $rc = 0 ] && [ -z "$out" ]; chk "fresh unread line inside window: healthy" $?
  run 3; [ $rc = 1 ]; chk "window 3 min: the 5 min old line rings" $?
  printf '%s | rb | old line\n' "$old" >"$L"; printf '99999999' >"$C"; run; [ $rc = 1 ]; chk "cursor beyond EOF (rotated log): reads from 0, rings" $?
  rm -f "$C"; printf '%s | rb | partial no newline' "$old" >"$L"; run; [ $rc = 0 ] && [ -z "$out" ]; chk "partial tail only: healthy" $?
  printf 'no timestamp line\n' >"$L"; touch -d "@$((now - 7200))" "$L"; run; [ $rc = 1 ]; chk "untimestamped line falls back to log mtime" $?
  printf '%s | rb | old line\n' "$old" >"$L"; local sz; sz="$(stat -c '%s %Y' "$L")"; run >/dev/null; [ "$(stat -c '%s %Y' "$L")" = "$sz" ] && [ ! -e "$C" ]; chk "read-only: log unchanged, no cursor created" $?
  echo "selftest: $pass/$total passed"; [ "$pass" = "$total" ]
}

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
case "${1:-}" in
  "") check; exit $? ;;
  --selftest) selftest; exit $? ;;
  *) echo 'usage: aide-inbox-dead-alarm.sh [--selftest]' >&2; exit 64 ;;
esac
