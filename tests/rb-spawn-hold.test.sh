#!/usr/bin/env bash
# rb-spawn-hold.test.sh - CSH: rb-spawn-hold.sh decisions (a-e,g-i), rb-run-coder.sh gates (f: 76 hold, 74 empty, 77 pair-lint), units (j), HAND-YIELD flag (AC7),
# watcher-premise binding (w-a..w-f: stub ssh logging argv, stub wm-decide; no real ssh, no real host path).
# Every fixture, state file and "remote" hand dir lives under a mktemp -d root this test created; no ssh, no real host path.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hold=${RB_SPAWN_HOLD_UNDER_TEST:-$here/../.local/bin/rb-spawn-hold.sh}   # the mutation proof points this at a throwaway copy
wplib=$here/../.local/lib/watcher-premise.sh
runc=${RB_RUN_CODER_UNDER_TEST:-$here/../.local/bin/rb-run-coder.sh}   # the G10 mutation proof points this at a throwaway copy
prescript=$here/fixtures/rb-spawn-hold.pre-shu.sh   # rb-spawn-hold.sh as of PR #52 (340d299): the byte-for-byte baseline for (u6)
udir=$here/../.config/systemd/user
fail=0
npass=0
pass() { npass=$((npass+1)); echo "PASS: $1"; }
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
[ "$(field unknown_since)" = 2026-10-23T09:25:00Z ] && pass "(e2) unknown_since = the last good read (shu2), not the first failing call" || bad "(e2) unknown_since $(field unknown_since)"
prevu='{"active":true,"run_id":1039,"refusal":"max-units","refused_at":"2026-10-23T09:20:00Z","read_at":"2026-10-23T09:25:00Z","source":"stale-ssh","unknown_since":"2026-10-23T09:25:00Z","hand_slots":2,"parts":[],"exempt":null}'
run e2b $R/missing.jsonl "$prevu"; [ "$(field unknown_since)" = 2026-10-23T09:25:00Z ] && pass "(e2b) unknown_since carried across failed reads" || bad "(e2b) unknown_since $(field unknown_since)"
# (e3) read failure, prior HOLD read 31 min ago -> stickiness expired
prev3='{"active":true,"run_id":1039,"refusal":"max-units","refused_at":"2026-10-23T08:50:00Z","read_at":"2026-10-23T08:59:00Z","source":"ssh","hand_slots":2,"parts":[],"exempt":null}'
run e3 $R/missing.jsonl "$prev3" --probe-only; expect "(e3) read failure, prior HOLD 31 min old (timer)" 0 "OK unknown: "
# shu2: the same 31 min old good read, a spawn gate: blind since that read (08:59), 1860 s >= BLIND_S
run e3b $R/missing.jsonl "$prev3"; expect "(e3b) read failure, prior HOLD 31 min old, spawn gate" 76 "HOLD unknown-blind unknown_since=2026-10-23T08:59:00Z age_s=1860 "

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
# rcr: rb-run-coder.sh now ends in the ROOM gate. Every invocation below gets an always-ok room fake, journalctl/systemctl stubs (no real user journal or units),
# and the room state/ledger under $R, so the real carbon-room.sh never runs and never writes fleet-dash state from this test.
printf '#!/usr/bin/env bash\necho "room ok: avail=8077 need=$1 reserve=3072 left=$((8077-3072-$1))"\nexit 0\n' > "$R/room-ok.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/.local/bin/journalctl"; cp "$H/.local/bin/journalctl" "$H/.local/bin/systemctl"
chmod +x "$R/room-ok.sh" "$H/.local/bin/journalctl" "$H/.local/bin/systemctl"
export RB_ROOM_BIN="$R/room-ok.sh" CARBON_ROOM_STATE="$R/room-state.json" CARBON_ROOM_LEDGER="$R/room-ledger.jsonl"
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
# (f6) pair-lint gate (exit 77): wm-decide record with --target AND --pr is refused BEFORE the hold gate (HOLD state still active in $extra); report + seat-event carry the line text
rm -f "$R/claude.ran"; { printf 'ctx %0200d\n' 0; printf 'wm-decide record --agent rb --kind verdict --target redbaron --pr wm-build#347 --what x\n'; } > "$R/pair.md"
HOME=$H RB_SPAWN_HOLD_BIN=$hold RB_SPAWN_HOLD_EXTRA="$extra" bash "$runc" f6 "$R/pair.md" >/dev/null 2>&1; rc=$?
rep=$(cat "$H/.cache/rb-seat/coders/f6.report.md" 2>/dev/null)
if [ $rc = 77 ] && [[ $rep == "REFUSED pair-lint $R/pair.md: line 2: --target with --pr"*"| text: wm-decide record --agent rb"* ]] && [ ! -e "$R/claude.ran" ] && grep -q 'RB-CODER f6 REFUSED pair-lint: wm-decide record --agent rb' "$R/events.log"; then
  pass "(f6) --target with --pr -> rc=77 before the hold gate, report '$rep', seat-event, claude not run"; else bad "(f6) rc=$rc report='$rep' ran=$(ls $R/claude.ran 2>&1)"; fi
grep -q 'rb-cargo-freeze\|RB_CODER_NO_CARGO' "$runc" && bad "(f5) interim freeze-file gate still present" || pass "(f5) interim rb-cargo-freeze gate removed"

# --- (j) timer/service pass systemd-analyze verify ---
if command -v systemd-analyze >/dev/null 2>&1; then
  vo=$(systemd-analyze --user verify "$udir/rb-spawn-hold.service" "$udir/rb-spawn-hold.timer" 2>&1); vrc=$?
  # the service's ExecStart binary does not exist in a clean checkout's $HOME; any other message is a failure
  vo=$(printf '%s\n' "$vo" | grep 'rb-spawn-hold' | grep -v 'Command .*rb-spawn-hold.sh.* is not executable\|Failed to load\|No such file' || true)   # only OUR units' messages count (system units' warnings are not ours)
  [ $vrc = 0 ] || [ -z "$vo" ] && pass "(j) systemd-analyze verify rb-spawn-hold.{service,timer}" || bad "(j) verify: $vo"
else
  bad "(j) systemd-analyze missing"
fi
grep -q '^OnUnitActiveSec=2min' "$udir/rb-spawn-hold.timer" && grep -q -- '--probe-only' "$udir/rb-spawn-hold.service" && pass "(j) timer every 2 min, service --probe-only" || bad "(j) unit content"

# --- AC7: HAND-YIELD flag, CARGO_SLOT_HAND_DIR at a mktemp dir, local fake ssh (shift host, run the command) ---
fakessh=$R/fakessh; printf '#!/usr/bin/env bash\nshift\nexec bash -c "$*"\n' > "$fakessh"; chmod +x "$fakessh"
HD=$R/hand; mkdir -p "$HD"
# premise reads the slot table through fakessh -> a stub wm-build (under a throwaway HOME's .cargo/bin) with one live hand row (HOLDS); lib state + wm-decide are stubs
mkdir -p "$R/ac7bin" "$R/ac7home/.cargo/bin"; printf '#!/usr/bin/env bash\nprintf "id\\trun\\tproducer\\tpid\\talive\\ttaken\\tage\\n1\\thand-1\\tcargo-slot\\t1\\tyes\\tx\\t1s\\n"\n' > "$R/ac7home/.cargo/bin/wm-build"; chmod +x "$R/ac7home/.cargo/bin/wm-build"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/ac7bin/wm-decide"; chmod +x "$R/ac7bin/wm-decide"
export WP_LIB=$wplib WP_STATE=$R/wp-ac7 WP_DECIDE_BIN=$R/ac7bin/wm-decide RB_SPAWN_HOLD_EXPIRES=$(date -d '+1 day' -Is) WP_OWNER=rb
flag() { HOME=$R/ac7home RB_SPAWN_HOLD_SSH=$fakessh CARGO_SLOT_HAND_DIR=$HD "$hold" --journal-file "$1" --state-file "$R/flag.state.json" --now "$NOW" --probe-only 2>/dev/null; }
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

# --- watcher-premise binding (w-a..w-f): stub ssh logs argv per kind, stub wm-decide logs argv; HOME is a mktemp dir ---
WT=$R/wp; mkdir -p "$WT"
printf '#!/usr/bin/env bash\ncmd="$*"\ncase "$cmd" in\n *"cargo-jobs list"*) echo "PREMISE $cmd" >> "$STUB_LOG"; cat "$STUB_LIST"; exit "${STUB_LIST_RC:-0}" ;;\n *hy-probe*) echo "PROBE $cmd" >> "$STUB_LOG"; echo "${STUB_FLAG:-absent}" ;;\n *hy-arm*) echo "WRITE-ARM $cmd" >> "$STUB_LOG"; echo armed ;;\n *hy-clear*) echo "WRITE-CLEAR $cmd" >> "$STUB_LOG"; echo cleared ;;\n *) echo "OTHER $cmd" >> "$STUB_LOG"; exit 3 ;;\nesac\n' > "$WT/ssh.stub"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$STUB_DECIDE_LOG"\n' > "$WT/decide.stub"; chmod +x "$WT/ssh.stub" "$WT/decide.stub"
printf 'id\trun\tproducer\tpid\talive\ttaken\tage\n11799\thand-2419612\tcargo-slot\t2419612\tyes\t2026-10-23T09:29:00+00:00\t60s\n' > "$WT/list.hand"
FUT=$(date -d '+1 day' -Is); PAST=$(date -d '-1 day' -Is)
# wsc <case> <journal> <flag-state> <expires> [lib] [disarm]; sets wout wrc werr
wsc() {
  local d=$WT/$1; mkdir -p "$d/home/.cache/rb-seat" "$d/wp"
  [ "${6:-}" != disarm ] || : > "$d/home/.cache/rb-seat/spawn-hold.disarm"
  wout=$(env -i PATH="$PATH" HOME="$d/home" TMPDIR="$d" RB_SPAWN_HOLD_SSH="$WT/ssh.stub" WP_LIB="${5:-$wplib}" WP_STATE="$d/wp" WP_DECIDE_BIN="$WT/decide.stub" \
    RB_SPAWN_HOLD_EXPIRES="$4" WP_OWNER=rb STUB_LOG="$d/ssh.log" STUB_LIST="$WT/list.hand" STUB_FLAG="$3" STUB_DECIDE_LOG="$d/decide.log" CARGO_SLOT_HAND_DIR="$d/hand" \
    bash "$hold" --journal-file "$2" --state-file "$d/state.json" --now "$NOW" 2>"$d/err"); wrc=$?
  werr=$(cat "$d/err")
}
wc_() { local n; n=$(grep -c "$2" "$WT/$1" 2>/dev/null); echo "${n:-0}"; }   # wc_ <case>/<file> <pattern>
wsc wa "$R/a.jsonl" absent "$FUT"
[ "$(wc_ wa/ssh.log '^WRITE-ARM')" = 1 ] && [ "$(wc_ wa/decide.log .)" = 1 ] && [ "$wrc" = 76 ] && [[ $wout == HOLD* ]] \
  && pass "(w-a) premise holds + future EXPIRES + arm -> stub ssh write x1, decide stub x1, rc=76" || bad "(w-a) write=$(wc_ wa/ssh.log '^WRITE-ARM') decide=$(wc_ wa/decide.log .) rc=$wrc"
wsc wb "$R/a.jsonl" absent "$PAST"
[ "$(wc_ wb/ssh.log '^WRITE')" = 0 ] && [[ $werr == *"HAND-YIELD arm SKIPPED (disarmed:"* ]] && [[ $wout == HOLD* ]] && [ "$wrc" = 76 ] \
  && pass "(w-b) EXPIRES in the past -> no ssh write, stderr SKIPPED, stdout HOLD, rc=76" || bad "(w-b) write=$(wc_ wb/ssh.log '^WRITE') rc=$wrc err=$werr"
wsc wc "$R/a.jsonl" absent "$FUT" "" disarm
[ "$(wc_ wc/ssh.log '^WRITE')" = 0 ] && [[ $werr == *"SKIPPED (disarmed: GONE"* ]] \
  && pass "(w-c) disarm file present (premise GONE) -> no ssh write" || bad "(w-c) write=$(wc_ wc/ssh.log '^WRITE') err=$werr"
wsc wd "$R/a.jsonl" absent "$FUT" /nonexistent
[ "$(wc_ wd/ssh.log '^WRITE')" = 0 ] && [[ $wout == HOLD* ]] && [ "$wrc" = 76 ] \
  && pass "(w-d) WP_LIB=/nonexistent -> no arm ssh write, HOLD/rc=76 unchanged" || bad "(w-d) write=$(wc_ wd/ssh.log '^WRITE') rc=$wrc"
wsc we "$R/d.jsonl" ours:9999999999 "$PAST"
[ "$(wc_ we/ssh.log '^WRITE-CLEAR')" = 1 ] && [ "$(wc_ we/decide.log .)" = 1 ] && [[ $wout == OK* ]] && [ "$wrc" = 0 ] \
  && pass "(w-e) EXPIRES past + flag present + OK -> ssh rm fires, decide stub x1" || bad "(w-e) clear=$(wc_ we/ssh.log '^WRITE-CLEAR') decide=$(wc_ we/decide.log .) rc=$wrc"
wsc wf "$R/a.jsonl" absent "$FUT"; wsc wf "$R/a.jsonl" ours:9999999999 "$FUT"
[ "$(wc_ wf/ssh.log '^WRITE')" = 1 ] && [ "$(wc_ wf/decide.log .)" -le 1 ] \
  && pass "(w-f) HOLD twice, flag present the 2nd time -> one write total, decide <= 1" || bad "(w-f) write=$(wc_ wf/ssh.log '^WRITE') decide=$(wc_ wf/decide.log .)"
# --- shj: per-table parallel journal read (fake ssh via RB_SPAWN_HOLD_SSH; no real ssh) ---
# the fake records the remote command and answers with 4 framed tables; SHJ_RC_<t> fails one table; SHJ_SLEEP sleeps past the timeout
SH=$R/shj; mkdir -p "$SH/home"
cat > "$SH/ssh.fake" <<'EOF2'
#!/usr/bin/env bash
shift; printf '%s\n' "$*" > "$SHJ_CMDLOG"
[ -z "${SHJ_SLEEP:-}" ] || sleep "$SHJ_SLEEP"
for t in runs land daemon builder; do
  v=SHJ_RC_$t; printf '### table=%s rc=%s wall_s=%s\n' "$t" "${!v:-0}" "${SHJ_WALL:-2}"
  [ "$t" != runs ] || cat "$SHJ_ROWS"
done
[ -n "${SHJ_EXIT0:-}" ] || for t in runs land daemon builder; do v=SHJ_RC_$t; [ "${!v:-0}" = 0 ] || exit 1; done   # SHJ_EXIT0: exit 0 despite a bad frame (the parser's own check)
EOF2
chmod +x "$SH/ssh.fake"
{ refuse 300 1039 max-units; } > "$SH/rows.jsonl"
shj() { # shj <state-file> [env assignments...]; sets sout src sext
  local stf=$1; shift
  sout=$(env HOME="$SH/home" XDG_CONFIG_HOME="$SH/home/.config" TMPDIR="$SH" RB_SPAWN_HOLD_SSH="$SH/ssh.fake" SHJ_CMDLOG="$SH/cmd.log" SHJ_ROWS="$SH/rows.jsonl" "$@" \
    bash "$hold" --state-file "$stf" --now "$NOW" --no-flag 2>/dev/null); src=$?
}
shj "$SH/s1.json"
cmd=$(cat "$SH/cmd.log")
ok=0; for t in runs land daemon builder; do [[ $cmd == *"--table \"\$t\""* || $cmd == *"rd $t "* ]] || ok=1; done
[[ $cmd == *"wait"* && $cmd == *'"op":"driver-adopted"'* && $cmd == *"grep -F"* && $cmd == *"mktemp -d"* && $cmd == *"rm -rf"* && $cmd == *"&"* ]] || ok=1
[ $ok = 0 ] && pass "(shj1) remote command names runs/land/daemon/builder, parallel '&' + wait, driver-adopted grep -F filter, mktemp -d + rm -rf trap" || bad "(shj1) remote cmd: $cmd"
[ "$src" = 76 ] && [[ $sout == "HOLD run=1039 refusal=max-units age_s=300 hand_slots=2 source=ssh walls=runs:2,land:2,daemon:2,builder:2" ]] \
  && pass "(shj2) framed tables parsed (### skipped), output line gains walls=: $sout" || bad "(shj2) rc=$src out=$sout"
# (shj3) the ssh timeout is a named variable; a read that outlives it reads rc=124
shj "$SH/s3.json" SHJ_SLEEP=5 RB_SPAWN_HOLD_TIMEOUT_S=1
[ "$src" = 0 ] && [[ $sout == "OK unknown: ssh redbaron journal failed: "*"rc=124 source=unknown" ]] && pass "(shj3) 1-s timeout vs sleeping ssh -> $sout" || bad "(shj3) rc=$src out=$sout"
# (shj4) one table read fails: the whole read is a failure, and the stale-ssh fallback runs (the survivors are NOT parsed as a picture)
prev4='{"active":true,"run_id":1039,"refusal":"max-units","refused_at":"2026-10-23T09:20:00Z","read_at":"2026-10-23T09:25:00Z","source":"ssh","hand_slots":2,"parts":["hand-1:hand:5"],"exempt":null}'
printf '%s\n' "$prev4" > "$SH/s4.json"
: > "$SH/rows.empty"; cp "$SH/rows.jsonl" "$SH/rows.keep"; cp "$SH/rows.empty" "$SH/rows.jsonl"   # surviving tables look all-clear: only the failure rule can keep the HOLD
shj "$SH/s4.json" SHJ_RC_daemon=3
[ "$src" = 76 ] && [[ $sout == "HOLD run=1039 refusal=max-units age_s=600 hand_slots=2 source=stale-ssh" ]] && pass "(shj4) daemon table rc=3 (remote exits 1) -> stale-ssh HOLD kept: $sout" || bad "(shj4) rc=$src out=$sout"
printf '%s\n' "$prev4" > "$SH/s4b.json"; shj "$SH/s4b.json" SHJ_RC_daemon=3 SHJ_EXIT0=1
[ "$src" = 76 ] && [[ $sout == "HOLD run=1039 refusal=max-units age_s=600 hand_slots=2 source=stale-ssh" ]] && pass "(shj4b) daemon frame rc=3 though ssh exit 0 -> parser still counts the read failed: $sout" || bad "(shj4b) rc=$src out=$sout"
rm -f "$SH/s5.json"; shj "$SH/s5.json" SHJ_RC_land=3 SHJ_EXIT0=1
[ "$src" = 0 ] && [[ $sout == "OK unknown: ssh journal table read failed: land rc=3"* ]] && [ "$(python3 -I -c 'import json;print(json.load(open("'$SH'/s5.json"))["source"])')" = unknown ] \
  && pass "(shj5) a failed table with no prior HOLD -> OK unknown (not a clean OK): $sout" || bad "(shj5) rc=$src out=$sout"
cp "$SH/rows.keep" "$SH/rows.jsonl"
# (shj6) the REAL remote script, run under dash by a local fake ssh, with a stub wm-build (one row per table; the daemon table has a
# non-matching row, so grep -F exits 1 on an empty match elsewhere must still count as success); HOME is a throwaway
mkdir -p "$SH/rhome/.cargo/bin"
cat > "$SH/rhome/.cargo/bin/wm-build" <<'EOF2'
#!/usr/bin/env bash
t=""; while [ $# -gt 0 ]; do [ "$1" != --table ] || t=$2; shift; done
[ "$t" != "${SHJ_FAIL_TABLE:-}" ] || { echo "boom $t" >&2; exit 5; }
case "$t" in
  runs)   printf '{"op":"release-mem","row":{"class":"land","decision":"refuse","refusal":"budget","run_id":7,"parts":["hand-1:hand:5"]},"table":"runs","ts":"%s"}\n' "$SHJ_TS" ;;
  land)   printf '{"op":"land-cargo-granted","row":{"run_id":8},"table":"land","ts":"%s"}\n' "$SHJ_TS" ;;
  daemon) printf '{"op":"tick","row":{},"table":"daemon","ts":"%s"}\n{"op":"admission-mem","row":{},"table":"daemon","ts":"%s"}\n' "$SHJ_TS" "$SHJ_TS" ;;
  builder) printf '{"op":"cargo-jobs-taken","row":{"id":1,"run_id":"hand-1","via":"hand"},"table":"builder","ts":"%s"}\n' "$SHJ_TS" ;;
esac
EOF2
chmod +x "$SH/rhome/.cargo/bin/wm-build"
printf '#!/usr/bin/env bash\nshift\nexec dash -c "$*"\n' > "$SH/ssh.dash"; chmod +x "$SH/ssh.dash"
if command -v dash >/dev/null 2>&1; then
  ts=$(date -u -d "$NOW - 120 seconds" +%Y-%m-%dT%H:%M:%S.000000000+00:00)
  mkdir -p "$SH/rtmp"
  sout=$(env HOME="$SH/rhome" XDG_CONFIG_HOME="$SH/rhome/.config" TMPDIR="$SH/rtmp" SHJ_TS="$ts" RB_SPAWN_HOLD_SSH="$SH/ssh.dash" bash "$hold" --state-file "$SH/s6.json" --now "$NOW" --no-flag 2>/dev/null); src=$?
  [ "$src" = 76 ] && [[ $sout == "HOLD run=7 refusal=budget age_s=120 hand_slots=1 source=ssh walls=runs:"* ]] && [ -z "$(ls -A "$SH/rtmp" | grep -v '^rb-spawn-hold\.')" ] \
    && pass "(shj6) real remote script under dash: 4 tables read, HOLD decided, empty daemon-filter match (grep rc 1) ok, remote mktemp -d removed: $sout" || bad "(shj6) rc=$src out=$sout rtmp=$(ls "$SH/rtmp")"
  rm -f "$SH/s7.json"; sout=$(env HOME="$SH/rhome" XDG_CONFIG_HOME="$SH/rhome/.config" TMPDIR="$SH/rtmp" SHJ_TS="$ts" SHJ_FAIL_TABLE=land RB_SPAWN_HOLD_SSH="$SH/ssh.dash" bash "$hold" --state-file "$SH/s7.json" --now "$NOW" --no-flag 2>/dev/null); src=$?
  [ "$src" = 0 ] && [[ $sout == "OK unknown: ssh redbaron journal failed:"*"rc=1 source=unknown" ]] && pass "(shj7) real remote script, land read rc=5 -> remote exits non-zero -> OK unknown: $sout" || bad "(shj7) rc=$src out=$sout"
else
  bad "(shj6) dash missing"
fi
if [ -z "${RB_SPAWN_HOLD_UNDER_TEST:-}" ]; then
  so=$(bash "$hold" --selftest 2>&1); src=$?
  [ $src = 0 ] && [ "$so" = "SELFTEST PASS rb-spawn-hold.sh" ] && pass "(w-g) --selftest -> $so" || bad "(w-g) --selftest rc=$src: $so"
fi
grep -q '^ExecStartPre=%h/.local/bin/rb-spawn-hold.sh --selftest' "$udir/rb-spawn-hold.service" && grep -q '^Environment=RB_SPAWN_HOLD_EXPIRES=2026-10-26T06:00:00-07:00 WP_OWNER=rb' "$udir/rb-spawn-hold.service" \
  && pass "(w-h) service: ExecStartPre --selftest + EXPIRES/WP_OWNER env" || bad "(w-h) service lines"

# --- shu (ctl a43d): the gate fails CLOSED. u1-u11 rb-spawn-hold.sh unknown-blind, u12-u15 rb-run-coder.sh rc handling, u16-u17 engine crash ---
# every case: hermetic mktemp state, --journal-file at a missing file (a read failure), --now = NOW, no ssh
MISSING=$R/missing.jsonl
isoago() { date -u -d "$NOW - $1 seconds" +%Y-%m-%dT%H:%M:%SZ; }   # isoago <secs>
useed() { printf '{"active":false,"run_id":null,"refusal":null,"refused_at":null,"read_at":"%s","source":"unknown","hand_slots":0,"parts":[],"exempt":null,"unknown_since":"%s"}' "$(isoago "$1")" "$(isoago "$1")"; }   # useed <unknown_since age>
oneline() { [[ $out != *$'\n'* ]]; }
BLINDFIX="source=unknown fix: ssh redbaron journal read or --no-cargo"
# (u1) fresh unknown (300 s) non-exempt -> OK unknown, rc 0
run u1 $MISSING "$(useed 300)"; expect "(u1) unknown 300 s, non-exempt" 0 "OK unknown: "
# (u2) aged unknown (660 s) non-exempt -> HOLD unknown-blind, rc 76; the state keeps source=unknown + the seeded unknown_since; no flag, no ssh
run u2 $MISSING "$(useed 660)"; expect "(u2) unknown 660 s, non-exempt" 76 "HOLD unknown-blind unknown_since=$(isoago 660) age_s=660 $BLINDFIX"
oneline && [ "$out" = "HOLD unknown-blind unknown_since=$(isoago 660) age_s=660 $BLINDFIX" ] && pass "(u2) the HOLD line is exact (G8) and the only stdout line" || bad "(u2) line: $out"
[ "$(field source)" = unknown ] && [ "$(field unknown_since)" = "$(isoago 660)" ] && pass "(u2) state after HOLD: source=unknown, unknown_since == the seeded value" || bad "(u2) state $(cat "$st")"
U2H=$R/u2hand; mkdir -p "$U2H"; : > "$R/u2.sshlog"; printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 3\n' "$R/u2.sshlog" > "$R/u2.ssh"; chmod +x "$R/u2.ssh"
printf '%s\n' "$(useed 660)" > "$R/u2b.state.json"
u2o=$(RB_SPAWN_HOLD_SSH=$R/u2.ssh CARGO_SLOT_HAND_DIR=$U2H "$hold" --journal-file $MISSING --state-file "$R/u2b.state.json" --now "$NOW" 2>/dev/null); u2rc=$?   # NO --no-flag: the flag path is live
[ $u2rc = 76 ] && [[ $u2o == "HOLD unknown-blind "* ]] && [ ! -e "$U2H/HAND-YIELD" ] && [ ! -s "$R/u2.sshlog" ] && pass "(u2) flag logic live (no --no-flag): rc=76, HAND-YIELD absent, no ssh call (act=none: source stays unknown)" || bad "(u2) rc=$u2rc flag=$(ls $U2H) ssh=$(cat $R/u2.sshlog)"
# (u3) boundary exactly 600 s -> HOLD, rc 76; 599 s -> OK
run u3 $MISSING "$(useed 600)"; expect "(u3) boundary 600 s" 76 "HOLD unknown-blind unknown_since=$(isoago 600) age_s=600 "
run u3b $MISSING "$(useed 599)"; expect "(u3b) 599 s" 0 "OK unknown: "
# (u4) aged unknown + --probe-only (the timer) -> rc 0; (u5) --probe-only --exempt X (the --no-cargo path) -> rc 0; (u5b) --exempt alone never refuses (G1)
run u4 $MISSING "$(useed 660)" --probe-only; expect "(u4) aged unknown, --probe-only" 0 "OK unknown: "
run u5 $MISSING "$(useed 660)" --probe-only --exempt X; expect "(u5) aged unknown, --probe-only --exempt X" 0 "OK unknown: "
run u5b $MISSING "$(useed 660)" --exempt X; expect "(u5b) aged unknown, --exempt X alone" 0 "OK unknown: "
# (u6) stale-ssh branch (a prior good read) is byte-for-byte what PR #52 did: stdout, rc and the state file, probe and not
prev6='{"active":true,"run_id":1039,"refusal":"max-units","refused_at":"2026-10-23T09:20:00Z","read_at":"2026-10-23T09:25:00Z","source":"ssh","hand_slots":2,"parts":["hand-1:hand:5"],"exempt":null,"unknown_since":null}'
prev6u='{"active":true,"run_id":1039,"refusal":"max-units","refused_at":"2026-10-23T09:00:00Z","read_at":"2026-10-23T09:25:00Z","source":"stale-ssh","hand_slots":2,"parts":[],"exempt":null,"unknown_since":"2026-10-23T09:00:00Z"}'
same6=1
# shu2 changed ONE thing here: the carried unknown_since of a prior GOOD read is that read's read_at (09:25), not now; everything else is byte-identical
strip_us() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("unknown_since",None); print(json.dumps(d,sort_keys=True))' "$1"; }
for pv in "$prev6" "$prev6u"; do for ex in "" "--probe-only"; do
  printf '%s\n' "$pv" > "$R/u6.new.json"; printf '%s\n' "$pv" > "$R/u6.old.json"
  on=$("$hold" --journal-file $MISSING --state-file "$R/u6.new.json" --now "$NOW" --no-flag $ex 2>&1); orc=$?
  oo=$("$prescript" --journal-file $MISSING --state-file "$R/u6.old.json" --now "$NOW" --no-flag $ex 2>&1); orrc=$?
  [ "$on" = "$oo" ] && [ "$orc" = "$orrc" ] && [ "$(strip_us "$R/u6.new.json")" = "$(strip_us "$R/u6.old.json")" ] || { same6=0; echo "u6 diff ex='$ex': new=[$on] rc=$orc old=[$oo] rc=$orrc"; }
done; done
[ $same6 = 1 ] && pass "(u6) stale-ssh branch output, rc and state (but unknown_since) identical to the pre-change script (4 fixtures: fresh/aged unknown_since x probe/non-probe): $on" || bad "(u6) stale-ssh differs from the pre-change script"
printf '%s\n' "$prev6" > "$R/u6.new.json"; "$hold" --journal-file $MISSING --state-file "$R/u6.new.json" --now "$NOW" --no-flag >/dev/null 2>&1
[ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["unknown_since"])' "$R/u6.new.json")" = "$(isoago 300)" ] && pass "(u6) prior good read at 09:25 -> unknown_since = that read_at (shu2)" || bad "(u6) unknown_since after a good prev"
# (u7) first failure, no prior state -> unknown_since = now, OK unknown, rc 0
run u7 $MISSING ""; expect "(u7) first failure, no state" 0 "OK unknown: "
[ "$(field unknown_since)" = "$NOW" ] && pass "(u7) unknown_since = now" || bad "(u7) unknown_since $(field unknown_since)"
# (u8) heal: aged unknown + a good read -> no carried unknown_since; the next failure restarts the clock at now
run u8 $R/d.jsonl "$(useed 660)"; expect "(u8) good read heals" 0 "OK "
u8st=$(cat "$st"); [ "$(field source)" = file ] && [ "$(field unknown_since)" = null ] && pass "(u8) healed state: non-unknown source, unknown_since null" || bad "(u8) state $u8st"
run u8b $MISSING "$u8st"; expect "(u8) failure after heal" 0 "OK unknown: "
[ "$(field unknown_since)" = "$NOW" ] && pass "(u8) unknown_since = now after the heal" || bad "(u8) unknown_since $(field unknown_since)"
# (u9) stale-ssh whose good-read time is past the window -> the blind clock dates from that last good read (shu2; was the carried unknown_since)
prev9=$(printf '{"active":true,"run_id":1039,"refusal":"max-units","refused_at":"%s","read_at":"%s","source":"stale-ssh","hand_slots":2,"parts":[],"exempt":null,"unknown_since":"%s"}' "$(isoago 2400)" "$(isoago 2000)" "$(isoago 900)")
run u9 $MISSING "$prev9"; expect "(u9) stale-ssh expired, read_at 2000 s old, unknown_since 900 s old" 76 "HOLD unknown-blind unknown_since=$(isoago 2000) age_s=2000 "
# (G2) an unparseable unknown_since restarts the clock, never a traceback
run g2a $MISSING '{"source":"unknown","unknown_since":"not-a-time","read_at":"x","active":false}'; expect "(G2) unparseable unknown_since" 0 "OK unknown: "
[ "$(field unknown_since)" = "$NOW" ] && pass "(G2) unknown_since reset to now" || bad "(G2) unknown_since $(field unknown_since)"
# (u10) corrupt state, non-exempt non-probe -> HOLD state-unreadable, rc 76, the corrupt file is left alone; (u11) --probe-only -> rc 0 and the file parses afterwards
run u10 $MISSING '{not json'; expect "(u10) corrupt state, non-exempt" 76 "HOLD unknown-blind state-unreadable fix: ssh redbaron journal read or --no-cargo"
oneline && [ "$(cat "$st")" = '{not json' ] && pass "(u10) one stdout line; the corrupt file is not rewritten (that would restart the clock)" || bad "(u10) st=$(cat "$st") out=$out"
run u11 $MISSING '{not json' --probe-only; expect "(u11) corrupt state, --probe-only" 0 "OK unknown: "
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["source"]=="unknown" and d["unknown_since"]' "$st" && pass "(u11) the state file parses afterwards (source=unknown, unknown_since set)" || bad "(u11) state: $(cat "$st")"
run u10b $MISSING '{not json' --exempt X; expect "(u10b) corrupt state, --exempt alone" 0 "OK unknown: "
run u10c $MISSING '[1,2]'; expect "(u10c) state is a JSON array (not an object)" 76 "HOLD unknown-blind state-unreadable"

# --- (u12-u15) rb-run-coder.sh: any rc but 0/76 refuses (G10); first line matching ^(HOLD|OK|REFUSED), else the first non-empty line (H3) ---
runc_case() { # runc_case <name> <hold_bin> [--no-cargo]; sets crc rep
  rm -f "$R/claude.ran" "$H/.cache/rb-seat/coders/$1.report.md"
  HOME=$H RB_SPAWN_HOLD_BIN=$2 RB_SPAWN_HOLD_EXTRA="" bash "$runc" "$1" "$R/prompt.md" ${3:-} >/dev/null 2>&1; crc=$?
  rep=$(cat "$H/.cache/rb-seat/coders/$1.report.md" 2>/dev/null)
}
runc_case u12 "$R/nohold/missing"
[ $crc = 76 ] && [[ $rep == "REFUSED spawn-hold rc=127: "* ]] && [ ! -e "$R/claude.ran" ] && grep -q 'RB-CODER u12 REFUSED spawn-hold rc=127' "$R/events.log" && pass "(u12) missing hold_bin -> rc=76, report '$rep', seat-event rc=127, claude not run" || bad "(u12) rc=$crc rep='$rep'"
mkdir -p "$R/nohold"; printf '#!/bin/sh\necho "OK x"\nexit 0\n' > "$R/nohold/noexec"; chmod 644 "$R/nohold/noexec"
runc_case u13 "$R/nohold/noexec"
[ $crc = 76 ] && [[ $rep == "REFUSED spawn-hold rc=126: "* ]] && [ ! -e "$R/claude.ran" ] && grep -q 'RB-CODER u13 REFUSED spawn-hold rc=126' "$R/events.log" && pass "(u13) non-executable hold_bin -> rc=76, report '$rep', seat-event rc=126" || bad "(u13) rc=$crc rep='$rep'"
printf '#!/bin/sh\necho "weird crash line"\nexit 3\n' > "$R/nohold/exit3"; chmod +x "$R/nohold/exit3"
runc_case u14 "$R/nohold/exit3"
[ $crc = 76 ] && [ "$rep" = "REFUSED spawn-hold rc=3: weird crash line" ] && [ ! -e "$R/claude.ran" ] && grep -q 'RB-CODER u14 REFUSED spawn-hold rc=3' "$R/events.log" && pass "(u14) hold_bin exits 3 -> rc=76, report '$rep' (first non-empty line)" || bad "(u14) rc=$crc rep='$rep'"
printf '#!/bin/sh\necho "noise first"\necho "OK x source=y"\nexit 3\n' > "$R/nohold/exit3b"; chmod +x "$R/nohold/exit3b"
runc_case u14b "$R/nohold/exit3b"
[ $crc = 76 ] && [ "$rep" = "REFUSED spawn-hold rc=3: OK x source=y" ] && pass "(u14b) H3: the first ^(HOLD|OK|REFUSED) line is quoted, not the first line: '$rep'" || bad "(u14b) rc=$crc rep='$rep'"
rm -f "$R/claude.ran"; HOME=$H RB_SPAWN_HOLD_BIN=$hold RB_SPAWN_HOLD_EXTRA="$extra_ok" bash "$runc" u14c "$R/prompt.md" >/dev/null 2>&1; crc=$?
[ $crc = 0 ] && [ -e "$R/claude.ran" ] && pass "(u14c) rc 0 still proceeds" || bad "(u14c) rc=$crc"
# (u15) --no-cargo with a missing hold_bin: unchanged (never refuses): rc 0, no REFUSED anywhere, the exemption event, and the next gate/spawn marker (claude) reached
runc_case u15 "$R/nohold/missing" --no-cargo
if [ $crc = 0 ] && [ -e "$R/claude.ran" ] && [[ $rep != *REFUSED* ]] && ! grep -q 'RB-CODER u15 REFUSED' "$R/events.log" && grep -q 'RB-CODER u15 EXEMPT spawn-hold --no-cargo' "$R/events.log"; then
  pass "(u15) --no-cargo + missing hold_bin -> no REFUSED, rc=0, exemption logged, claude reached"; else bad "(u15) rc=$crc rep='$rep' ran=$(ls $R/claude.ran 2>&1)"; fi

# --- (u16/u17) engine crash: --state-file in a chmod 500 dir -> os.replace/open fails inside the engine (G11, H2, H6, H4) ---
if [ "$(id -u)" = 0 ]; then echo "SKIP: (u16/u17) running as root (chmod 500 does not stop a write)"; else
  RO=$R/ro; mkdir -p "$RO"; chmod 500 "$RO"
  u16o=$("$hold" --journal-file $MISSING --state-file "$RO/state.json" --now "$NOW" --no-flag 2>"$R/u16.err"); u16rc=$?
  [ $u16rc = 76 ] && [ "$u16o" = "HOLD unknown-blind engine-failed fix: ssh redbaron journal read or --no-cargo" ] && [[ $u16o != *$'\n'* ]] && [ ! -s "$R/u16.err" ] \
    && pass "(u16) engine crash, non-exempt -> rc=76, the HOLD line is the ONLY output (stderr empty): $u16o" || bad "(u16) rc=$u16rc out=[$u16o] err=[$(head -c 200 "$R/u16.err")]"
  u17o=$("$hold" --journal-file $MISSING --state-file "$RO/state.json" --now "$NOW" --no-flag --probe-only 2>/dev/null); u17rc=$?
  [ $u17rc = 0 ] && [ "$u17o" = "OK unknown: decision engine failed source=unknown" ] && pass "(u17) engine crash under --probe-only -> rc=0: $u17o" || bad "(u17) rc=$u17rc out=[$u17o]"
  u17b=$("$hold" --journal-file $MISSING --state-file "$RO/state.json" --now "$NOW" --no-flag --exempt X 2>/dev/null); u17brc=$?
  [ $u17brc = 0 ] && [[ $u17b == "OK unknown: decision engine failed"* ]] && pass "(u17b) H4: engine crash with --exempt alone stays OK unknown, rc=0 (exempt = the caller accepts blindness)" || bad "(u17b) rc=$u17brc out=[$u17b]"
  chmod 700 "$RO"
fi

# --- shu2: the blind clock starts at the LAST GOOD journal read (Fable 10-23 AGREE-WITH-EDITS folded, spec v0.2) ---
# gprev <source> <read_at age> <unknown_since age|null> <active true|false> [nosource]: a prior state whose last good read is <age> s ago
gprev() {
  local us=null; [ "$3" = null ] || us="\"$(isoago "$3")\""
  if [ "${5:-}" = nosource ]; then
    printf '{"active":%s,"run_id":null,"refusal":null,"refused_at":null,"read_at":"%s","hand_slots":0,"parts":[],"exempt":null}' "$4" "$(isoago "$2")"
  else
    printf '{"active":%s,"run_id":1039,"refusal":"max-units","refused_at":"%s","read_at":"%s","source":"%s","hand_slots":2,"parts":[],"exempt":null,"unknown_since":%s}' "$4" "$(isoago "$2")" "$(isoago "$2")" "$1" "$us"
  fi
}
# (s2a) good OK read 601 s ago, no calls since, a failing spawn call -> HOLD unknown-blind rc 76; unknown_since == the FIXTURE read_at (not out.read_at = now)
run s2a $MISSING "$(gprev ssh 601 null false)"; expect "(s2a) last good read 601 s ago + failing call" 76 "HOLD unknown-blind unknown_since=$(isoago 601) age_s=601 "
[ "$(field unknown_since)" = "$(isoago 601)" ] && [ "$(field read_at)" = "$NOW" ] && pass "(s2a) written unknown_since == the fixture read_at ($(isoago 601)), read_at is now" || bad "(s2a) state $(cat "$st")"
# (s2b) 599 s -> OK unknown, rc 0
run s2b $MISSING "$(gprev ssh 599 null false)"; expect "(s2b) last good read 599 s ago + failing call" 0 "OK unknown: "
[ "$(field unknown_since)" = "$(isoago 599)" ] && pass "(s2b) unknown_since == the fixture read_at" || bad "(s2b) unknown_since $(field unknown_since)"
# (s2c) the same 601 s state never refuses --probe-only (the timer) or --exempt X --probe-only (--no-cargo) or --exempt alone
run s2c1 $MISSING "$(gprev ssh 601 null false)" --probe-only; expect "(s2c) 601 s, --probe-only" 0 "OK unknown: "
run s2c2 $MISSING "$(gprev ssh 601 null false)" --exempt X; expect "(s2c) 601 s, --exempt X" 0 "OK unknown: "
run s2c3 $MISSING "$(gprev ssh 601 null false)" --probe-only --exempt X; expect "(s2c) 601 s, --probe-only --exempt X" 0 "OK unknown: "
# (s2d) a good read after the 601 s-old OK -> OK, unknown_since null (a good read resets the clock)
run s2d $R/d.jsonl "$(gprev ssh 601 null false)"; expect "(s2d) good read after a 601 s-old OK" 0 "OK "
[ "$(field unknown_since)" = null ] && pass "(s2d) unknown_since null after the good read" || bad "(s2d) unknown_since $(field unknown_since)"
# (s2e) stale-ssh HOLD prev, unknown_since recent (now-10), read_at now-1801 (past CEIL) -> only the read_at anchor can trip it
run s2e $MISSING "$(gprev stale-ssh 1801 10 true)"; expect "(s2e) stale-ssh prev, read_at 1801 s, unknown_since 10 s" 76 "HOLD unknown-blind unknown_since=$(isoago 1801) age_s=1801 "
[ "$(field unknown_since)" = "$(isoago 1801)" ] && pass "(s2e) written unknown_since == now-1801 (the read_at anchor, not the recent carried value)" || bad "(s2e) unknown_since $(field unknown_since)"
# (s2f) engine code (comments stripped) has exactly one `BLIND_S = 600` and no other 600 token
codeonly=$(sed -n "/<<'PY'\$/,/^PY\$/p" "$hold" | sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#.*$//')   # the python decision engine only (the bash flag-expiry 600 is unrelated)
[ "$(printf '%s\n' "$codeonly" | grep -c '^BLIND_S = 600$')" = 1 ] && [ "$(printf '%s\n' "$codeonly" | grep -cw 600)" = 1 ] && printf '%s\n' "$codeonly" | grep -q 'age_s >= BLIND_S' \
  && pass "(s2f) exactly one BLIND_S = 600 and no other 600 token in the code; the blind threshold reads BLIND_S" || bad "(s2f) 600 tokens: $(printf '%s\n' "$codeonly" | grep -nw 600 | head -5)"
# (s2g) a pre-shu state file with NO source key and read_at 601 s ago -> HOLD rc 76
run s2g $MISSING "$(gprev x 601 null false nosource)"; expect "(s2g) no-source prev, read_at 601 s" 76 "HOLD unknown-blind unknown_since=$(isoago 601) age_s=601 "
# the unknown branch keeps the earlier of the two: a prev unknown whose read_at is later than unknown_since still dates from unknown_since
run s2h $MISSING "$(printf '{"active":false,"read_at":"%s","source":"unknown","unknown_since":"%s"}' "$(isoago 50)" "$(isoago 700)")"; expect "(s2h) unknown prev: the earlier unknown_since wins" 76 "HOLD unknown-blind unknown_since=$(isoago 700) age_s=700 "

[ $fail -eq 0 ] && echo "ALL PASS ($npass checks)" || echo "FAILED"
exit $fail
