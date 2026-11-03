#!/usr/bin/env bash
# tests/aide-inbox-dead-alarm.test.sh: aide-inbox-dead-alarm.sh over throwaway inbox logs (no real inbox touched). Run: bash tests/aide-inbox-dead-alarm.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
w="$here/.local/bin/aide-inbox-dead-alarm.sh"
fail=0; total=0
chk() { total=$((total + 1)); if [ "$2" = 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
T=$(mktemp -d "${TMPDIR:-/tmp}/aide-inbox-dead-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
D="$T/ev"; mkdir -p "$D"; L="$D/aide-events.log"; C="$D/aide-events.cursor"
NOW=$(date -d '2026-11-03T08:00:00-08:00' +%s)
run() { EVENTS_DIR="$D" AIDE_INBOX_DEAD_NOW="$NOW" bash "$w" "$@" 2>&1; }

bash -n "$w"; chk "bash -n" $?
out=$(run); rc=$?; [ $rc = 0 ] && [ -z "$out" ]; chk "no log: healthy, silent, exit 0" $?
: >"$L"; out=$(run); rc=$?; [ $rc = 0 ] && [ -z "$out" ]; chk "empty log: healthy" $?
printf '2026-11-03T07:20:00-08:00 | rb | old line\n' >"$L"
out=$(run); rc=$?; [ $rc = 1 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && printf '%s' "$out" | grep -q '^ALARM: aide inbox dead: 1 unread line(s), oldest waiting 40 min (window 30 min)'; chk "unread 40 min old, no cursor: exit 1 + one ALARM line ($out)" $?
stat -c %s "$L" >"$C"; out=$(run); rc=$?; [ $rc = 0 ] && [ -z "$out" ]; chk "cursor at EOF: healthy" $?
printf '2026-11-03T07:45:00-08:00 | rb | fresh line\n' >>"$L"
out=$(run); rc=$?; [ $rc = 0 ] && [ -z "$out" ]; chk "unread 15 min old (inside window): healthy" $?
printf '2026-11-03T07:20:00-08:00 | rb | old line\n' >"$L"; printf '2026-11-03T07:25:00-08:00 | ctl | second\n' >>"$L"; echo 0 >"$C"
out=$(run); rc=$?; [ $rc = 1 ] && printf '%s' "$out" | grep -q '2 unread line(s), oldest waiting 40 min'; chk "two unread: count and oldest age reported" $?
echo 99999 >"$C"; out=$(run); rc=$?; [ $rc = 1 ]; chk "cursor beyond EOF (rotated): treated as 0, alarms" $?
echo garbage >"$C"; out=$(run); rc=$?; [ $rc = 1 ]; chk "malformed cursor: treated as 0, alarms" $?
before=$(cat "$C"); run >/dev/null; [ "$(cat "$C")" = "$before" ]; chk "read-only: cursor untouched" $?
out=$(EVENTS_DIR="$D" AIDE_INBOX_DEAD_NOW="$NOW" AIDE_INBOX_DEAD_WINDOW_S=7200 bash "$w" 2>&1); rc=$?; [ $rc = 0 ] && [ -z "$out" ]; chk "window override 7200 s: 40 min is healthy" $?
out=$(bash "$w" extra 2>&1); rc=$?; [ $rc = 2 ]; chk "usage: extra arg exits 2" $?
[ "$fail" = 0 ] && echo "ALL PASS ($total)" || echo "FAILED"
exit $fail
