#!/usr/bin/env bash
# aide-inbox.sh must record .session_id from stdin JSON even when $1 names the event (settings.json invokes it that way).
# Throwaway HOME + EVENTS_DIR only; never the live ~/.cache/fleet-dash.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
H="$here/.claude/hooks/aide-inbox.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
d="$tmp/fd"; mkdir -p "$d"
run() { # $1 event arg, $2 json
  printf '%s' "$2" | env HOME="$tmp" WM_SEAT=aide EVENTS_DIR="$d" bash "$H" "$1" 2>/dev/null
}
for ev in SessionStart UserPromptSubmit; do
  sid="test-sid-$ev-12345678"
  j="{\"session_id\":\"$sid\",\"hook_event_name\":\"$ev\"}"
  run "$ev" "$j" >/dev/null; run "$ev" "$j" >/dev/null
  n="$(awk -v s="$sid" '$1==s' "$d/aide-sids" 2>/dev/null | wc -l)"
  [ "$n" = 1 ] && ok "\$1=$ev: sid recorded exactly once" || bad "\$1=$ev: sid count $n (want 1)"
done
[ "$(wc -l <"$d/aide-sids")" = 2 ] && ok "two distinct sids, two lines" || bad "aide-sids line count"
# cursor logic unchanged: unread line printed once, cursor advances to EOF
printf 'hello one\n' >"$d/aide-events.log"
out="$(run UserPromptSubmit '{"session_id":"test-sid-cursor-12345678"}')"
printf '%s' "$out" | grep -q 'hello one' && ok "new inbox line printed" || bad "inbox line not printed"
[ "$(cat "$d/aide-events.cursor")" = "$(stat -c %s "$d/aide-events.log")" ] && ok "cursor at EOF" || bad "cursor not at EOF"
out="$(run UserPromptSubmit '{"session_id":"test-sid-cursor-12345678"}')"
printf '%s' "$out" | grep -q 'hello one' && bad "line re-printed" || ok "no re-print on second read"
# non-aide seat records nothing
d2="$tmp/fd2"; mkdir -p "$d2"
printf '%s' '{"session_id":"test-sid-nonaide-1234"}' | env -u WM_SEAT HOME="$tmp" EVENTS_DIR="$d2" bash "$H" SessionStart >/dev/null 2>&1
[ ! -s "$d2/aide-sids" ] && ok "non-aide records no sid" || bad "non-aide recorded a sid"
exit $fail
