#!/usr/bin/env bash
# Test (A1572 stage3 AC1): aide-inbox.sh serves bld and rls from ~/.cache/<seat>; ctl/ops keep the fleet-dash inbox.
set -u
H="$(dirname "$0")/../.claude/hooks/aide-inbox.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; fail=0
mkdir -p "$HOME/.cache/bld" "$HOME/.cache/rls" "$HOME/.cache/fleet-dash"
printf 't | x | bld line\n' > "$HOME/.cache/bld/aide-events.log"
printf 't | x | rls line\n' > "$HOME/.cache/rls/aide-events.log"
printf 't | x | ctl line\n' > "$HOME/.cache/fleet-dash/aide-events.log"
run() { env -u TMUX -u EVENTS_DIR -u FLEET_DASH_DIR -u WM_AIDE_LANE WM_SEAT="$1" bash "$H" UserPromptSubmit </dev/null 2>&1; }
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
o=$(run bld); grep -q 'bld line' <<<"$o" && ! grep -qE 'rls line|ctl line' <<<"$o"; chk "bld reads only its own inbox" $?
[ "$(cat "$HOME/.cache/bld/aide-events.cursor" 2>/dev/null)" = "$(stat -c %s "$HOME/.cache/bld/aide-events.log")" ]; chk "bld cursor advanced in its own dir" $?
o=$(run rls); grep -q 'rls line' <<<"$o" && ! grep -qE 'bld line|ctl line' <<<"$o"; chk "rls reads only its own inbox" $?
[ ! -e "$HOME/.cache/fleet-dash/aide-events.cursor" ]; chk "ctl cursor untouched by bld/rls" $?
o=$(run bld); [ -z "$o" ]; chk "bld second run silent" $?
o=$(run ctl); grep -q 'ctl line' <<<"$o" && ! grep -qE 'bld line|rls line' <<<"$o"; chk "ctl reads fleet-dash inbox" $?
printf 't | x | ops line\n' >> "$HOME/.cache/fleet-dash/aide-events.log"
o=$(run ops); grep -q 'ops line' <<<"$o" && ! grep -q 'ctl line' <<<"$o"; chk "ops shares ctl state" $?
o=$(run rb); [ -z "$o" ]; chk "rb silent" $?
# sid recorded under the seat's own dir
printf '{"session_id":"sid-bldx-0001"}' | env -u TMUX -u EVENTS_DIR WM_SEAT=bld bash "$H" SessionStart >/dev/null 2>&1
grep -q '^sid-bldx-0001 ' "$HOME/.cache/bld/aide-sids" 2>/dev/null; chk "bld sid recorded in its own dir" $?
[ "$fail" = 0 ] && echo "TEST PASS" || { echo "TEST FAIL"; exit 1; }
