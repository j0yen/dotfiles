#!/usr/bin/env bash
# rb-run-coder-room.test.sh - rcr: the ROOM gate (exit 78) in rb-run-coder.sh, cases a-j.
# Every case runs under a fresh HOME=$(mktemp -d) with stub claude/seat-event/journalctl/systemctl and fake room binaries; the real claude,
# carbon-room.sh, user journal and fleet-dash state are never touched (CARBON_ROOM_STATE/LEDGER point into the case HOME).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runc=${RB_RUN_CODER_UNDER_TEST:-$here/../.local/bin/rb-run-coder.sh}   # the mutation proofs point this at a throwaway copy
fail=0; npass=0
pass() { npass=$((npass+1)); echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
R=$(mktemp -d "${TMPDIR:-/tmp}/rb-run-coder-room-test.XXXXXX") || exit 2
trap 'case "$R" in */rb-run-coder-room-test.*) rm -rf "$R";; esac' EXIT

# room fakes (shared)
printf '#!/usr/bin/env bash\necho "$1" >> "$HOME/room.argv"\necho "room ok: avail=8077 need=$1 reserve=3072 left=$((8077-3072-$1))"\nexit 0\n' > "$R/ok-fake"
printf '#!/usr/bin/env bash\necho "$1" >> "$HOME/room.argv"\necho "room NO: avail=1000 need=$1 reserve=3072 short=9" >&2\nexit 3\n' > "$R/no-fake"
printf '#!/usr/bin/env bash\nexit 64\n' > "$R/usage-fake"
printf '#!/usr/bin/env bash\necho hello\nexit 0\n' > "$R/junk-fake"
printf '#!/usr/bin/env bash\necho "room n/a: not carbon"\nexit 0\n' > "$R/na-fake"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/ok-hold"
chmod +x "$R"/*-fake "$R/ok-hold"

# case <name> <room-bin> <journal-text> <systemctl-text> [env assignments...]; sets H (home), D, rc
case_() {
  local name=$1 room=$2 jtxt=$3 stxt=$4; shift 4
  H=$R/$name; D=$H/.cache/rb-seat/coders
  mkdir -p "$H/.config/environment.d" "$H/.local/bin" "$D"
  : > "$H/.config/environment.d/90-claude-oauth.conf"
  head -c 400 /dev/zero | tr '\0' 'x' > "$H/prompt.md"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/events"\n' "$H" > "$H/.local/bin/seat-event.sh"
  printf '#!/usr/bin/env bash\ntouch "%s/claude.ran"\nexit 0\n' "$H" > "$H/.local/bin/claude"
  printf '#!/usr/bin/env bash\ncat "%s/journal.txt"\nexit 0\n' "$H" > "$H/.local/bin/journalctl"
  printf '#!/usr/bin/env bash\ncat "%s/systemctl.txt"\nexit 0\n' "$H" > "$H/.local/bin/systemctl"
  chmod +x "$H/.local/bin/"*
  printf '%s' "$jtxt" > "$H/journal.txt"; printf '%s' "$stxt" > "$H/systemctl.txt"
  env HOME="$H" RB_SPAWN_HOLD_BIN="$R/ok-hold" RB_ROOM_BIN="$room" CARBON_ROOM_STATE="$H/room-state.json" CARBON_ROOM_LEDGER="$H/room-ledger.jsonl" "$@" \
    bash "$runc" t "$H/prompt.md" >/dev/null 2>&1; rc=$?
}
jline() { printf 'rb-launch-x%s.service: Consumed 3min 38.580s CPU time over 12min 26.464s wall clock time, %s memory peak, 3.1M memory swap peak.\n' "$1" "$2"; }
five() { { jline 1 812.4M; jline 2 1.2G; jline 3 300.0M; jline 4 95.0M; jline 5 400.0M; }; }

# (a) ok-fake + env peak, no other units -> spawn proceeds, .room has left= and peak_src=env, ROOM event
case_ a "$R/ok-fake" "" "" RB_ROOM_PEAK_MB=900
room=$(cat "$D/t.room" 2>/dev/null)
if [ $rc = 0 ] && [ -e "$H/claude.ran" ] && [[ $room == *left=* && $room == *peak_src=env* && $room == *active=0* ]] && grep -q 'RB-CODER t ROOM room ok:' "$H/events"; then
  pass "(a) ok -> rc=0, claude ran, .room='$room', ROOM event"; else bad "(a) rc=$rc room='$room' ran=$(ls "$H/claude.ran" 2>&1)"; fi
# (b) no-fake -> 78, report REFUSED room rc=3:, no claude
case_ b "$R/no-fake" "" "" RB_ROOM_PEAK_MB=900
rep=$(cat "$D/t.report.md" 2>/dev/null)
if [ $rc = 78 ] && [[ $rep == "REFUSED room rc=3:"* ]] && [ ! -e "$H/claude.ran" ] && grep -q 'RB-CODER t REFUSED room rc=3' "$H/events"; then
  pass "(b) room NO -> rc=78, report '$rep', claude not run"; else bad "(b) rc=$rc rep='$rep' ran=$(ls "$H/claude.ran" 2>&1)"; fi
# (c) missing room binary -> 78 (fail closed)
case_ c "$R/does-not-exist" "" "" RB_ROOM_PEAK_MB=900
[ $rc = 78 ] && [ ! -e "$H/claude.ran" ] && pass "(c) missing RB_ROOM_BIN -> rc=78, claude not run" || bad "(c) rc=$rc"
# (d) journal: 5 lines incl 812.4M and 1.2G (swap field ignored) -> need 1229, journal(n=5)
case_ d "$R/ok-fake" "$(five)" ""
argv=$(cat "$H/room.argv" 2>/dev/null); room=$(cat "$D/t.room" 2>/dev/null)
if [ $rc = 0 ] && [ "$argv" = 1229 ] && [[ $room == *'peak_src=journal(n=5)'* ]]; then pass "(d) 5 journal lines -> room.argv=$argv, .room='$room'"; else bad "(d) rc=$rc argv='$argv' room='$room'"; fi
# (e) empty journal -> 1500 default
case_ e "$R/ok-fake" "" ""
argv=$(cat "$H/room.argv" 2>/dev/null); room=$(cat "$D/t.room" 2>/dev/null)
if [ $rc = 0 ] && [ "$argv" = 1500 ] && [[ $room == *peak_src=default* ]]; then pass "(e) empty journal -> room.argv=$argv, .room='$room'"; else bad "(e) rc=$rc argv='$argv' room='$room'"; fi
# (f) systemctl lists self + 2 other active units, env peak 900 -> 2700, active=2
case_ f "$R/ok-fake" "" "rb-launch-t.service loaded active running rb t
rb-launch-u1.service loaded active running rb u1
rb-launch-u2.service loaded active running rb u2
" RB_ROOM_PEAK_MB=900
argv=$(cat "$H/room.argv" 2>/dev/null); room=$(cat "$D/t.room" 2>/dev/null)
if [ $rc = 0 ] && [ "$argv" = 2700 ] && [[ $room == *active=2* ]]; then pass "(f) 2 other active units -> room.argv=$argv, .room='$room'"; else bad "(f) rc=$rc argv='$argv' room='$room'"; fi
# (g) usage-fake (rc 64) -> 78
case_ g "$R/usage-fake" "" "" RB_ROOM_PEAK_MB=900
[ $rc = 78 ] && [ ! -e "$H/claude.ran" ] && pass "(g) rc=64 -> rc=78" || bad "(g) rc=$rc"
# (h) junk-fake (rc 0, other text) -> 78
case_ h "$R/junk-fake" "" "" RB_ROOM_PEAK_MB=900
rep=$(cat "$D/t.report.md" 2>/dev/null)
[ $rc = 78 ] && [[ $rep == "REFUSED room rc=0: hello"* ]] && pass "(h) rc=0 + junk text -> rc=78, report '$rep'" || bad "(h) rc=$rc rep='$rep'"
# (i) na-fake -> allowed, .room records the no-op
case_ i "$R/na-fake" "" "" RB_ROOM_PEAK_MB=900
room=$(cat "$D/t.room" 2>/dev/null)
[ $rc = 0 ] && [ -e "$H/claude.ran" ] && [[ $room == "room n/a: not carbon "* ]] && pass "(i) n/a -> rc=0, .room='$room'" || bad "(i) rc=$rc room='$room'"
# (j) 2 journal lines max 900M -> floored at 1500
case_ j "$R/ok-fake" "$(jline 1 900.0M; jline 2 100.0M)" ""
argv=$(cat "$H/room.argv" 2>/dev/null); room=$(cat "$D/t.room" 2>/dev/null)
if [ $rc = 0 ] && [ "$argv" = 1500 ] && [[ $room == *'peak_src=journal(n=2)+floor'* ]]; then pass "(j) 2 lines max 900M -> room.argv=$argv, .room='$room'"; else bad "(j) rc=$rc argv='$argv' room='$room'"; fi
# (k) systemctl failure -> active=? and n_active=0
case_ k "$R/ok-fake" "" "" RB_ROOM_PEAK_MB=900
printf '#!/usr/bin/env bash\nexit 1\n' > "$H/.local/bin/systemctl"
HOME=$H RB_SPAWN_HOLD_BIN="$R/ok-hold" RB_ROOM_BIN="$R/ok-fake" RB_ROOM_PEAK_MB=900 CARBON_ROOM_STATE="$H/s.json" CARBON_ROOM_LEDGER="$H/l.jsonl" bash "$runc" t "$H/prompt.md" >/dev/null 2>&1; rc=$?
room=$(cat "$D/t.room" 2>/dev/null)
[ $rc = 0 ] && [[ $room == *active=\?* ]] && pass "(k) systemctl failure -> '$room'" || bad "(k) rc=$rc room='$room'"

echo "pass=$npass fail=$fail"
[ $fail = 0 ] && echo "ALL PASS ($npass checks)"
exit $fail
