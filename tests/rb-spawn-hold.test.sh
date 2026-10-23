#!/usr/bin/env bash
# rb-spawn-hold.test.sh - CSH: rb-spawn-hold.sh decisions (a-e,g-i), rb-run-coder.sh gate (f), units (j), HAND-YIELD flag (AC7).
# Every fixture, state file and "remote" hand dir lives under a mktemp -d root this test created; no ssh, no real host path.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hold=$here/../.local/bin/rb-spawn-hold.sh
runc=$here/../.local/bin/rb-run-coder.sh
udir=$here/../.config/systemd/user
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

R=$(mktemp -d "${TMPDIR:-/tmp}/rb-spawn-hold-test.XXXXXX") || exit 2
trap 'case "$R" in */rb-spawn-hold-test.*) rm -rf "$R";; esac' EXIT
NOW=2026-10-23T09:30:00Z

# --- fixture builders: rows in the real `wm-build journal` shape (checked against 2026-10-23T08:55:54Z..09:22Z) ---
ago() { date -u -d "$NOW - $1 seconds" +%Y-%m-%dT%H:%M:%S.000000000+00:00; }   # ago <secs>
refuse() { printf '{"op":"release-mem","row":{"class":"land","decision":"refuse","refusal":"%s","run_id":%s,"parts":["1044:inner:12","hand-1:hand:5","hand-2:hand:5"],"slug":"s"},"table":"runs","ts":"%s"}\n' "$3" "$2" "$(ago "$1")"; }
grant()  { printf '{"op":"release-mem","row":{"class":"land","decision":"grant","run_id":%s,"parts":[]},"table":"runs","ts":"%s"}\n' "$2" "$(ago "$1")"; }
adopted() { printf '{"op":"driver-adopted","row":{"kind":"systemd-unit","run_id":%s,"slug":"s","unit":"u"},"table":"daemon","ts":"%s"}\n' "$2" "$(ago "$1")"; }
dropped() { printf '{"op":"release-mem-dropped","row":{"reason":"run-ended","run_id":%s},"table":"runs","ts":"%s"}\n' "$2" "$(ago "$1")"; }
queued()  { printf '{"op":"release-mem-queued","row":{"run_id":%s,"position":1,"sum":17.0,"cap":12.5,"budget":26.0,"event":"q"},"table":"runs","ts":"%s"}\n' "$2" "$(ago "$1")"; }
taken()   { printf '{"op":"cargo-jobs-taken","row":{"id":%s,"run_id":"hand-%s","via":"hand","producer":"cargo-slot","box_id":0},"table":"builder","ts":"%s"}\n' "$2" "$2" "$(ago "$1")"; }
released() { printf '{"op":"cargo-jobs-released","row":{"id":%s},"table":"builder","ts":"%s"}\n' "$2" "$(ago "$1")"; }
noise()   { printf '{"op":"tick","row":{},"table":"daemon","ts":"%s"}\n' "$(ago "$1")"; }

n=0
# run <case> <journal-file> [prev-state-json] [extra args...]; sets out, rc, st (state file)
run() {
  local case_=$1 jf=$2 prev=${3:-}; shift 3 || shift $#
  n=$((n+1)); st=$R/state.$n.json
  [ -z "$prev" ] || printf '%s\n' "$prev" > "$st"
  out=$("$hold" --journal-file "$jf" --state-file "$st" --now "$NOW" --no-flag "$@" 2>/dev/null); rc=$?
}
field() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(json.dumps(v) if not isinstance(v,str) else v)' "$st" "$1"; }
expect() { # expect <label> <rc> <out-prefix>
  if [ "$rc" = "$2" ] && [[ $out == "$3"* ]]; then pass "$1 -> rc=$rc: $out"; else bad "$1 expected rc=$2 '$3...' got rc=$rc: $out"; fi
}

# (a) refuse 5 min old -> HOLD
{ noise 400; refuse 300 1039 max-units; } > $R/a.jsonl
run a $R/a.jsonl ""; expect "(a) refuse 5 min old" 76 "HOLD run=1039 refusal=max-units age_s=300 hand_slots=2 source=file"
[ "$(field active)" = true ] && [ "$(field run_id)" = 1039 ] && [ "$(field hand_slots)" = 2 ] && pass "(a) state file active/run_id/hand_slots" || bad "(a) state file: $(cat "$st")"
[ "$(field refused_at)" = 2026-10-23T09:25:00Z ] && pass "(a) refused_at" || bad "(a) refused_at $(field refused_at)"
# --probe-only: same HOLD line, exit 0 (the timer never fails)
run a2 $R/a.jsonl "" --probe-only; expect "(a2) --probe-only" 0 "HOLD run=1039"

# (b) refuse then a later grant for the same run -> OK
{ refuse 600 1039 budget; grant 300 1039; } > $R/b.jsonl
run b $R/b.jsonl ""; expect "(b) refuse then grant" 0 "OK "
[ "$(field active)" = false ] && pass "(b) state inactive" || bad "(b) state $(cat "$st")"

# (c) refuse 31 min old -> OK
refuse 1860 1039 budget > $R/c.jsonl
run c $R/c.jsonl ""; expect "(c) refuse 31 min old" 0 "OK "
# boundary: 29 min old still HOLD
refuse 1740 1039 budget > $R/c2.jsonl
run c2 $R/c2.jsonl ""; expect "(c2) refuse 29 min old" 76 "HOLD run=1039 refusal=budget age_s=1740"

# (d) no rows -> OK
: > $R/d.jsonl
run d $R/d.jsonl ""; expect "(d) no rows" 0 "OK "

# (e1) read failure, no prior hold -> OK unknown
run e1 $R/missing.jsonl ""; expect "(e1) read failure, no prior state" 0 "OK unknown: "
[ "$(field source)" = unknown ] && pass "(e1) source=unknown" || bad "(e1) source $(field source)"
# (e2) read failure, prior HOLD read 5 min ago -> HOLD stale-ssh, read_at not advanced
prev='{"active":true,"run_id":1039,"refusal":"max-units","refused_at":"2026-10-23T09:20:00Z","read_at":"2026-10-23T09:25:00Z","source":"ssh","hand_slots":2,"parts":["hand-1:hand:5"],"exempt":null}'
run e2 $R/missing.jsonl "$prev"; expect "(e2) read failure, prior HOLD 5 min old" 76 "HOLD run=1039 refusal=max-units age_s=600 hand_slots=2 source=stale-ssh"
[ "$(field source)" = stale-ssh ] && [ "$(field read_at)" = 2026-10-23T09:25:00Z ] && pass "(e2) source=stale-ssh, read_at kept" || bad "(e2) state $(cat "$st")"
[ "$(field unknown_since)" = 2026-10-23T09:30:00Z ] && pass "(e2) unknown_since set on the first failed read" || bad "(e2) unknown_since $(field unknown_since)"
prevu='{"active":true,"run_id":1039,"refusal":"max-units","refused_at":"2026-10-23T09:20:00Z","read_at":"2026-10-23T09:25:00Z","source":"stale-ssh","unknown_since":"2026-10-23T09:26:00Z","hand_slots":2,"parts":[],"exempt":null}'
run e2b $R/missing.jsonl "$prevu"; [ "$(field unknown_since)" = 2026-10-23T09:26:00Z ] && pass "(e2b) unknown_since carried across failed reads" || bad "(e2b) unknown_since $(field unknown_since)"
# (e3) read failure, prior HOLD read 31 min ago -> stickiness expired
prev3='{"active":true,"run_id":1039,"refusal":"max-units","refused_at":"2026-10-23T08:50:00Z","read_at":"2026-10-23T08:59:00Z","source":"ssh","hand_slots":2,"parts":[],"exempt":null}'
run e3 $R/missing.jsonl "$prev3"; expect "(e3) read failure, prior HOLD 31 min old" 0 "OK unknown: "

# (g) queued product run, no refusal, a hand part held -> HOLD (leading)
{ taken 900 501; queued 120 1042; } > $R/g.jsonl
run g $R/g.jsonl ""; expect "(g) queued + hand part held" 76 "HOLD run=1042 refusal=queued age_s=120 hand_slots=1"
# (g2) the hand part released -> OK; queued then dropped -> OK
{ taken 900 501; queued 120 1042; released 60 501; } > $R/g2.jsonl
run g2 $R/g2.jsonl ""; expect "(g2) hand part released" 0 "OK "
{ taken 900 501; queued 120 1042; dropped 60 1042; } > $R/g3.jsonl
run g3 $R/g3.jsonl ""; expect "(g3) queued then dropped" 0 "OK "
# (g4) queued, no hand part held -> OK (nothing to starve)
queued 120 1042 > $R/g4.jsonl
run g4 $R/g4.jsonl ""; expect "(g4) queued, no hand slot held" 0 "OK "

# (h) refuse then running (driver-adopted) -> OK
{ refuse 600 1039 budget; adopted 120 1039; } > $R/h.jsonl
run h $R/h.jsonl ""; expect "(h) refuse then running" 0 "OK "
# (h2) another run's grant does not clear it
{ refuse 600 1039 budget; grant 120 1044; } > $R/h2.jsonl
run h2 $R/h2.jsonl ""; expect "(h2) other run's grant" 76 "HOLD run=1039"
# (h3) refuse then the run closed (update runs outcome) -> OK
{ refuse 600 1039 budget; printf '{"op":"update","row":{"id":1039,"outcome":"code"},"table":"runs","ts":"%s"}\n' "$(ago 100)"; } > $R/h3.jsonl
run h3 $R/h3.jsonl ""; expect "(h3) refuse then closed" 0 "OK "

# (i) refuse then dropped run-ended 20 min old -> HOLD
{ refuse 1500 1039 max-units; dropped 1200 1039; } > $R/i.jsonl
run i $R/i.jsonl ""; expect "(i) refuse then dropped run-ended" 76 "HOLD run=1039 refusal=max-units age_s=1500"

# --- (f) rb-run-coder.sh: any prompt + HOLD -> 76 + report; --no-cargo + HOLD -> passes, exemption logged ---
H=$R/home; mkdir -p "$H/.config/environment.d" "$H/.local/bin" "$H/.cache/rb-seat/coders"
: > "$H/.config/environment.d/90-claude-oauth.conf"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/events.log"\n' "$R" > "$H/.local/bin/seat-event.sh"
printf '#!/usr/bin/env bash\necho ran >> "%s/claude.ran"\nexit 0\n' "$R" > "$H/.local/bin/claude"
chmod +x "$H/.local/bin/seat-event.sh" "$H/.local/bin/claude"
head -c 400 /dev/zero | tr '\0' 'x' > "$R/prompt.md"        # >= 200 bytes, no cargo/redbaron words: the gate must still fire
cat "$R/a.jsonl" > /dev/null
extra="--journal-file $R/a.jsonl --state-file $R/f.state.json --now $NOW"
HOME=$H RB_SPAWN_HOLD_BIN=$hold RB_SPAWN_HOLD_EXTRA="$extra" bash "$runc" f1 "$R/prompt.md" >/dev/null 2>&1; rc=$?
rep=$(cat "$H/.cache/rb-seat/coders/f1.report.md" 2>/dev/null)
if [ $rc = 76 ] && [[ $rep == "REFUSED spawn-hold: HOLD run=1039"* ]] && [ ! -e "$R/claude.ran" ] && grep -q 'RB-CODER f1 REFUSED spawn-hold' "$R/events.log"; then
  pass "(f1) prompt without cargo words + HOLD -> rc=76, report '$rep', seat-event, claude not run"; else bad "(f1) rc=$rc report='$rep' ran=$(ls $R/claude.ran 2>&1)"; fi
HOME=$H RB_SPAWN_HOLD_BIN=$hold RB_SPAWN_HOLD_EXTRA="$extra" bash "$runc" f2 "$R/prompt.md" --no-cargo >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ -e "$R/claude.ran" ] && grep -q 'RB-CODER f2 EXEMPT spawn-hold --no-cargo (HOLD run=1039' "$R/events.log"; then
  pass "(f2) --no-cargo + HOLD -> rc=0, claude ran, exemption in seat-event"; else bad "(f2) rc=$rc ran=$(ls $R/claude.ran 2>&1) events=$(tail -n 2 $R/events.log)"; fi
[ "$(python3 -I -c 'import json;print(json.load(open("'$R'/f.state.json"))["exempt"])')" = f2 ] && pass "(f2) exempt=f2 in spawn-hold.json" || bad "(f2) exempt field: $(cat $R/f.state.json)"
# (f3) OK -> spawn proceeds; empty-prompt gate (74) keeps its behaviour
rm -f "$R/claude.ran"; extra_ok="--journal-file $R/d.jsonl --state-file $R/f3.state.json --now $NOW"
HOME=$H RB_SPAWN_HOLD_BIN=$hold RB_SPAWN_HOLD_EXTRA="$extra_ok" bash "$runc" f3 "$R/prompt.md" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ -e "$R/claude.ran" ] && pass "(f3) OK -> spawn proceeds rc=0" || bad "(f3) rc=$rc"
: > "$R/empty.md"; HOME=$H RB_SPAWN_HOLD_BIN=$hold RB_SPAWN_HOLD_EXTRA="$extra" bash "$runc" f4 "$R/empty.md" >/dev/null 2>&1; rc=$?
[ $rc = 74 ] && pass "(f4) empty prompt still exits 74 before the hold gate" || bad "(f4) rc=$rc"
grep -q 'rb-cargo-freeze\|RB_CODER_NO_CARGO' "$runc" && bad "(f5) interim freeze-file gate still present" || pass "(f5) interim rb-cargo-freeze gate removed"

# --- (j) timer/service pass systemd-analyze verify ---
if command -v systemd-analyze >/dev/null 2>&1; then
  vo=$(systemd-analyze --user verify "$udir/rb-spawn-hold.service" "$udir/rb-spawn-hold.timer" 2>&1); vrc=$?
  # the service's ExecStart binary does not exist in a clean checkout's $HOME; any other message is a failure
  vo=$(printf '%s\n' "$vo" | grep -v 'Command .*rb-spawn-hold.sh.* is not executable\|Failed to load\|No such file' || true)
  [ $vrc = 0 ] || [ -z "$vo" ] && pass "(j) systemd-analyze verify rb-spawn-hold.{service,timer}" || bad "(j) verify: $vo"
else
  bad "(j) systemd-analyze missing"
fi
grep -q '^OnUnitActiveSec=2min' "$udir/rb-spawn-hold.timer" && grep -q -- '--probe-only' "$udir/rb-spawn-hold.service" && pass "(j) timer every 2 min, service --probe-only" || bad "(j) unit content"

# --- AC7: HAND-YIELD flag, CARGO_SLOT_HAND_DIR at a mktemp dir, local fake ssh (shift host, run the command) ---
fakessh=$R/fakessh; printf '#!/usr/bin/env bash\nshift\nexec bash -c "$*"\n' > "$fakessh"; chmod +x "$fakessh"
HD=$R/hand; mkdir -p "$HD"
flag() { RB_SPAWN_HOLD_SSH=$fakessh CARGO_SLOT_HAND_DIR=$HD "$hold" --journal-file "$1" --state-file "$R/flag.state.json" --now "$NOW" --probe-only 2>/dev/null; }
now_e=$(date -u -d "$NOW" +%s)
flag "$R/a.jsonl" >/dev/null
read -r e1 r1 < "$HD/HAND-YIELD" 2>/dev/null
if [ "${e1:-0}" = $((now_e + 1800)) ] && [[ ${r1:-} == spawn-hold* ]]; then pass "(AC7a) HOLD arms HAND-YIELD: $(cat $HD/HAND-YIELD)"; else bad "(AC7a) flag: $(cat $HD/HAND-YIELD 2>&1)"; fi
grep -q '^[0-9]* spawn-hold run=1039$' "$HD/HAND-YIELD" && pass "(AC7a) flag format '<epoch> spawn-hold run=<id>'" || bad "(AC7a) format"
flag "$R/d.jsonl" >/dev/null
[ ! -e "$HD/HAND-YIELD" ] && pass "(AC7b) OK clears our flag" || bad "(AC7b) flag survived: $(cat $HD/HAND-YIELD)"
echo "9999999999 hand-yield-by-rb 1039 land starved" > "$HD/HAND-YIELD"; before=$(cat "$HD/HAND-YIELD")
flag "$R/a.jsonl" >/dev/null; [ "$(cat "$HD/HAND-YIELD")" = "$before" ] && pass "(AC7c) foreign flag survives HOLD" || bad "(AC7c) foreign flag changed: $(cat $HD/HAND-YIELD)"
flag "$R/d.jsonl" >/dev/null; [ "$(cat "$HD/HAND-YIELD")" = "$before" ] && pass "(AC7c) foreign flag survives OK" || bad "(AC7c) foreign flag removed"
# --no-flag never touches the dir
rm -f "$HD/HAND-YIELD"; RB_SPAWN_HOLD_SSH=$fakessh CARGO_SLOT_HAND_DIR=$HD "$hold" --journal-file "$R/a.jsonl" --state-file "$R/flag2.state.json" --now "$NOW" --probe-only --no-flag >/dev/null 2>&1
[ ! -e "$HD/HAND-YIELD" ] && pass "(AC7d) --no-flag writes nothing" || bad "(AC7d) --no-flag wrote a flag"
# a stale-ssh read failure keeps the (our) flag armed, an unknown one never removes a foreign flag
echo "9999999999 hand-yield-by-rb keep" > "$HD/HAND-YIELD"
RB_SPAWN_HOLD_SSH=$fakessh CARGO_SLOT_HAND_DIR=$HD "$hold" --journal-file "$R/missing.jsonl" --state-file "$R/flag3.state.json" --now "$NOW" --probe-only >/dev/null 2>&1
[ "$(cat "$HD/HAND-YIELD")" = "9999999999 hand-yield-by-rb keep" ] && pass "(AC7e) read failure leaves a foreign flag alone" || bad "(AC7e)"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
