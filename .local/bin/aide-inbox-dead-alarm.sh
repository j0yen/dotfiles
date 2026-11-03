#!/usr/bin/env bash
# aide-inbox-dead-alarm.sh: one pass, no loop. Exit 0 when the aide inbox is healthy, exit 1 + ONE `ALARM:` line when the inbox is dead:
# unread lines have waited past the window with no consumer read (aide-inbox.sh advances the cursor on every aide prompt/SessionStart, so a stale cursor = nobody is reading).
#   inbox  = $EVENTS_DIR/aide-events.log   (EVENTS_DIR default FLEET_DASH_DIR or ~/.cache/fleet-dash), lines `<iso8601> | <source> | <text>`, written by seat-event.sh aide
#   cursor = $EVENTS_DIR/aide-events.cursor (byte offset; missing or malformed = 0; beyond EOF = rotated, treated as 0, same as aide-inbox.sh)
#   DEAD   = at least one unread line AND the oldest unread line is older than the window. No log, an empty log, or a cursor at EOF = healthy.
# WINDOW: 30 min (1800 s). The row notes (A647) named no window, so the brief default applies; override with AIDE_INBOX_DEAD_WINDOW_S.
# PREMISE: the aide inbox has a consumer that reads it at least every 30 min while the aide runs; an unread line older than that means the aide is down or its inbox hook is not firing
# Env: EVENTS_DIR AIDE_INBOX_DEAD_WINDOW_S AIDE_INBOX_DEAD_NOW (epoch seconds, test only)
# Read-only: it never writes the log or the cursor. Exit: 0 healthy, 1 dead, 2 usage. --selftest runs tests/aide-inbox-dead-alarm.test.sh.
set -u
export LC_ALL=C
SELF=$(readlink -f "${BASH_SOURCE[0]}")
HERE=$(dirname "$SELF")
if [ "${1:-}" = "--selftest" ]; then
  T="$HERE/../../tests/aide-inbox-dead-alarm.test.sh"
  [ -r "$T" ] || { echo "aide-inbox-dead-alarm --selftest: $T not found" >&2; exit 2; }
  exec bash "$T"
fi
[ "$#" -eq 0 ] || { echo "usage: aide-inbox-dead-alarm.sh [--selftest]" >&2; exit 2; }

DIR="${EVENTS_DIR:-${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}}"
LOG="$DIR/aide-events.log"; CUR="$DIR/aide-events.cursor"
WINDOW="${AIDE_INBOX_DEAD_WINDOW_S:-1800}"; [[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW=1800
NOW="${AIDE_INBOX_DEAD_NOW:-$(date +%s)}"

[ -s "$LOG" ] || exit 0
size=$(stat -c %s "$LOG" 2>/dev/null) || exit 0
off=0; [ -r "$CUR" ] && off=$(head -n1 "$CUR" 2>/dev/null)
[[ "$off" =~ ^[0-9]+$ ]] || off=0
[ "$off" -le "$size" ] || off=0
[ "$off" -lt "$size" ] || exit 0

# oldest unread line with a parseable leading timestamp
n=0; oldest=""
while IFS= read -r line; do
  ts="${line%% |*}"
  if s=$(date -d "$ts" +%s 2>/dev/null); then oldest="$s"; break; fi
  n=$((n + 1)); [ "$n" -lt 50 ] || break
done < <(tail -c +"$((off + 1))" "$LOG")
[ -n "$oldest" ] || exit 0

age=$((NOW - oldest))
[ "$age" -gt "$WINDOW" ] || exit 0
unread=$(tail -c +"$((off + 1))" "$LOG" | grep -c .)
echo "ALARM: aide inbox dead: $unread unread line(s), oldest waiting $((age / 60)) min (window $((WINDOW / 60)) min), cursor $off of $size in $LOG; the aide is down or its inbox hook is not reading"
exit 1
