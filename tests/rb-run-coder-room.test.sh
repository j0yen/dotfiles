#!/usr/bin/env bash
# rb-run-coder-room.test.sh - rcr: the ROOM gate (exit 78) in rb-run-coder.sh, cases a-k plus RedBaron cases l-p; the memcap gate (exit 71), cases mc1-mc2.
# Every case runs under a fresh HOME=$(mktemp -d) with stub claude/seat-event/journalctl/systemctl and fake room binaries; the real claude,
# carbon-room.sh, user journal and fleet-dash state are never touched (CARBON_ROOM_STATE/LEDGER point into the case HOME).
set -u
unset CARBON_ROOM_HOST CARBON_ROOM_RESERVE_MB CARBON_ROOM_HOSTNAME   # an ambient CARBON_ROOM_HOST would hide the host guard the RedBaron cases exercise
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
# fable-verdict gate (fvg): the prompt cites no spec, so it carries a Hatch line backed by a NO-SPEC-SPAWN row in a fixture decisions DB
BASE=$R/base-prompt.md
{ head -c 400 /dev/zero | tr '\0' 'x'; printf '\nkill only pids you started, by pid\nLIVE CLONES (never commit, checkout, reset or edit in place; clone them into a mktemp -d instead):\n'; } > "$BASE"
HATCH_ID=d-$(date +%Y%m%d-%H%M%S)-rb-room
python3 -I - "$R/hatch.db" "$HATCH_ID" "$(sha256sum "$BASE" | cut -d' ' -f1)" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("""CREATE TABLE decisions (id TEXT PRIMARY KEY, ts TEXT NOT NULL, agent TEXT NOT NULL, via TEXT NOT NULL, model TEXT, kind TEXT NOT NULL, target TEXT,
  what TEXT NOT NULL, why TEXT NOT NULL, evidence TEXT NOT NULL, reverse TEXT NOT NULL, rule_ids TEXT, first_verdict TEXT, regrade TEXT,
  regrade_attempts INTEGER NOT NULL DEFAULT 0, correction TEXT, tags TEXT, outcome TEXT, expect_by TEXT, graded_at TEXT, grader TEXT, gates TEXT, session TEXT)""")
db.execute("INSERT INTO decisions (id, ts, agent, via, model, kind, what, why, evidence, reverse) VALUES (?,?,?,?,?,?,?,?,?,?)",
           (sys.argv[2], "ts-" + sys.argv[2], "rb", "t", None, "other", "NO-SPEC-SPAWN room gate fixture", "w", "sha256:" + sys.argv[3], "r"))
db.commit(); db.close()
PY
printf '#!/usr/bin/env bash\necho "memcap ok: unit=rb-coder-t.service high=12884901888 max=15032385536"\n' > "$R/ok-memcap"
printf '#!/usr/bin/env bash\necho "memcap NO: not in a .service unit (cgroup=/user.slice/tmux.scope)"\nexit 3\n' > "$R/no-memcap"
chmod +x "$R"/*-fake "$R/ok-hold" "$R"/*-memcap
# fable-verdict gate (80) is not under test here: every case prompt carries a valid Hatch row in a fixture DB (sha = prompt minus the Hatch line)
export RB_DECISIONS_DB=$R/decisions.fixture.sqlite
HID=d-$(date +%Y%m%d-%H%M%S)-rb-0001; PSHA=$({ { head -c 400 /dev/zero | tr '\0' 'x'; printf '\nkill only pids you started, by pid\nLIVE CLONES (never commit, checkout, reset or edit in place; clone them into a mktemp -d instead):\n'; }; printf '\n'; } | sha256sum | cut -d' ' -f1)
python3 -I -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("create table decisions (id text, ts text, kind text, model text, what text, evidence text, regrade text)"); d.execute("insert into decisions values (?,?,?,?,?,?,?)", (sys.argv[2], "t", "decision", None, "NO-SPEC-SPAWN room test", "sha256:" + sys.argv[3], None)); d.commit()' "$RB_DECISIONS_DB" "$HID" "$PSHA"

# case <name> <room-bin> <journal-text> <systemctl-text> [env assignments...]; sets H (home), D, rc
case_() {
  local name=$1 room=$2 jtxt=$3 stxt=$4; shift 4
  H=$R/$name; D=$H/.cache/rb-seat/coders
  mkdir -p "$H/.config/environment.d" "$H/.local/bin" "$D"
  : > "$H/.config/environment.d/90-claude-oauth.conf"
  { cat "$BASE"; printf 'Hatch: %s\n' "$HATCH_ID"; } > "$H/prompt.md"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/events"\n' "$H" > "$H/.local/bin/seat-event.sh"
  printf '#!/usr/bin/env bash\ntouch "%s/claude.ran"\nexit 0\n' "$H" > "$H/.local/bin/claude"
  printf '#!/usr/bin/env bash\ncat "%s/journal.txt"\nexit 0\n' "$H" > "$H/.local/bin/journalctl"
  printf '#!/usr/bin/env bash\ncat "%s/systemctl.txt"\nexit 0\n' "$H" > "$H/.local/bin/systemctl"
  chmod +x "$H/.local/bin/"*
  printf '%s' "$jtxt" > "$H/journal.txt"; printf '%s' "$stxt" > "$H/systemctl.txt"
  env HOME="$H" RB_ROOM_HOSTNAME=carbon RB_DECISIONS_DB="$R/hatch.db" RB_SPAWN_HOLD_BIN="$R/ok-hold" RB_MEMCAP_BIN="$R/ok-memcap" RB_ROOM_BIN="$room" CARBON_ROOM_STATE="$H/room-state.json" CARBON_ROOM_LEDGER="$H/room-ledger.jsonl" "$@" \
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
HOME=$H RB_ROOM_HOSTNAME=carbon RB_DECISIONS_DB="$R/hatch.db" RB_SPAWN_HOLD_BIN="$R/ok-hold" RB_MEMCAP_BIN="$R/ok-memcap" RB_ROOM_BIN="$R/ok-fake" RB_ROOM_PEAK_MB=900 CARBON_ROOM_STATE="$H/s.json" CARBON_ROOM_LEDGER="$H/l.jsonl" bash "$runc" t "$H/prompt.md" >/dev/null 2>&1; rc=$?
room=$(cat "$D/t.room" 2>/dev/null)
[ $rc = 0 ] && [[ $room == *active=\?* ]] && pass "(k) systemctl failure -> '$room'" || bad "(k) rc=$rc room='$room'"
# (mc1) memcap NO (room ok) -> 71, report REFUSED memcap rc=3:, event, no claude (memcap gate, Fable CORRECT fcdf/05b3)
case_ mc1 "$R/ok-fake" "" "" RB_ROOM_PEAK_MB=900 RB_MEMCAP_BIN="$R/no-memcap"
rep=$(cat "$D/t.report.md" 2>/dev/null)
if [ $rc = 71 ] && [[ $rep == "REFUSED memcap rc=3: memcap NO:"* ]] && [ ! -e "$H/claude.ran" ] && grep -q 'RB-CODER t REFUSED memcap rc=3' "$H/events"; then
  pass "(mc1) memcap NO -> rc=71, report '$rep', claude not run"; else bad "(mc1) rc=$rc rep='$rep' ran=$(ls "$H/claude.ran" 2>&1)"; fi
# (mc2) missing memcap binary -> 71 (fail closed); (a) above already proves ok-memcap writes t.memcap
case_ mc2 "$R/ok-fake" "" "" RB_ROOM_PEAK_MB=900 RB_MEMCAP_BIN="$R/does-not-exist"
[ $rc = 71 ] && [ ! -e "$H/claude.ran" ] && [ -e "$R/a/.cache/rb-seat/coders/t.memcap" ] && pass "(mc2) missing RB_MEMCAP_BIN -> rc=71; (a) wrote t.memcap" || bad "(mc2) rc=$rc"

# --- RedBaron cases (l-p): host != carbon -> the real carbon-room.sh is forced (CARBON_ROOM_HOST) against a fake meminfo, plus the MemGate sigma.
realroom="$here/../.local/bin/carbon-room.sh"
printf '#!/usr/bin/env bash\nprintf "id\\trun\\tproducer\\tpid\\talive\\ttaken\\tage\\n"\nprintf "1\\thand-11\\tcargo-slot\\t11\\tyes\\tt\\t5s\\n2\\tinner-12\\tcargo-slot\\t12\\tyes\\tt\\t5s\\n3\\thand-13\\tcargo-slot\\t13\\tno\\tt\\t5s\\n"\n' > "$R/wmb-two"
printf '#!/usr/bin/env bash\nexit 1\n' > "$R/wmb-fail"
printf '#!/usr/bin/env bash\necho garbage\n' > "$R/wmb-junk"
chmod +x "$R"/wmb-*
printf '[cargo_jobs]\nmem_budget_gb = 26\nmem_headroom_gb = 4\n[cargo_jobs.mem_caps_gb]\nland = 12.5\ninner = 12.0\ngate = 13\nhand = 9\n[cargo_jobs.mem_caps_gb.wm-build]\nhand = 5\n' > "$R/wmb.toml"
meminfo() { printf 'MemTotal: 31000000 kB\nMemAvailable: %d kB\n' $(( $1 * 1024 )) > "$R/mi-$1"; echo "$R/mi-$1"; }
rbcase() { local name=$1; shift; case_ "$name" "$realroom" "" "" RB_ROOM_HOSTNAME=redbaron RB_ROOM_CONFIG="$R/wmb.toml" RB_ROOM_PEAK_MB=900 "$@"; }
# (l) RB, MemAvailable 20000 ok, sigma = hand 9 + inner 12 (dead hand skipped) = 21 G -> free 5.5 G >= 900
rbcase l CARBON_ROOM_MEMINFO="$(meminfo 20000)" RB_ROOM_WMB_BIN="$R/wmb-two"
room=$(cat "$D/t.room" 2>/dev/null)
if [ $rc = 0 ] && [ -e "$H/claude.ran" ] && [[ $room == "room ok: avail=20000 need=900 reserve=4096 "* && $room == *"memgate free_mb=5120 sum_mb=21504 budget_mb=26624"* ]]; then pass "(l) RB room+memgate ok -> .room='$room'"; else bad "(l) rc=$rc room='$room'"; fi
# (m) RB, MemAvailable 3000 < 900 + 4096 reserve -> 78 room NO
rbcase m CARBON_ROOM_MEMINFO="$(meminfo 3000)" RB_ROOM_WMB_BIN="$R/wmb-two"
rep=$(cat "$D/t.report.md" 2>/dev/null)
[ $rc = 78 ] && [[ $rep == "REFUSED room rc=3: room NO:"* ]] && [ ! -e "$H/claude.ran" ] && pass "(m) RB MemAvailable short -> 78, '$rep'" || bad "(m) rc=$rc rep='$rep'"
# (n) RB, sigma 18432 of 26624, need 9000 -> 78 memgate NO
rbcase n CARBON_ROOM_MEMINFO="$(meminfo 20000)" RB_ROOM_PEAK_MB=9000 RB_ROOM_MEMGATE_SUM_MB=18432 RB_ROOM_BUDGET_MB=26624 RB_ROOM_HEADROOM_MB=1024
rep=$(cat "$D/t.report.md" 2>/dev/null)
[ $rc = 78 ] && [[ $rep == "REFUSED room rc=3: memgate NO:"* ]] && [ ! -e "$H/claude.ran" ] && pass "(n) RB sigma full -> 78, '$rep'" || bad "(n) rc=$rc rep='$rep'"
# (o) RB, sigma unreadable (command fails / garbage output) -> 78 memgate NO
for w in wmb-fail wmb-junk; do
  rbcase o CARBON_ROOM_MEMINFO="$(meminfo 20000)" RB_ROOM_WMB_BIN="$R/$w"
  rep=$(cat "$D/t.report.md" 2>/dev/null)
  [ $rc = 78 ] && [[ $rep == "REFUSED room rc=3: memgate NO: sigma unreadable"* ]] && [ ! -e "$H/claude.ran" ] && pass "(o) RB $w -> 78, '$rep'" || bad "(o) $w rc=$rc rep='$rep'"
done
# (p) carbon host unchanged: no memgate text, room bin gets no forced reserve, even with an unreadable sigma
case_ p "$R/ok-fake" "" "" RB_ROOM_PEAK_MB=900 RB_ROOM_WMB_BIN="$R/wmb-fail"
room=$(cat "$D/t.room" 2>/dev/null)
[ $rc = 0 ] && [[ $room != *memgate* && $room == "room ok: "* ]] && pass "(p) carbon unchanged -> .room='$room'" || bad "(p) rc=$rc room='$room'"
# (q) RB, numeric run names classed from state.db (ctl k1036): 1084 via=inner -> 12.0, 1090 via=hand prefix=wm-build -> 5 = 17 G
printf '#!/usr/bin/env bash\nprintf "id\\trun\\tproducer\\tpid\\talive\\ttaken\\tage\\n"\nprintf "7\\t1084\\trowless\\t71\\tyes\\tt\\t5s\\n8\\t1090\\trowless\\t81\\tyes\\tt\\t5s\\n"\n' > "$R/wmb-num"; chmod +x "$R/wmb-num"
python3 -I -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("create table builder_cargo_jobs (id integer primary key, run_id text, via text, prefix text)"); d.executemany("insert into builder_cargo_jobs values (?,?,?,?)", [(7,"1084","inner",""),(8,"1090","hand","wm-build")]); d.commit()' "$R/state.db"
rbcase q CARBON_ROOM_MEMINFO="$(meminfo 20000)" RB_ROOM_WMB_BIN="$R/wmb-num" RB_ROOM_STATE_DB="$R/state.db"
room=$(cat "$D/t.room" 2>/dev/null)
[ $rc = 0 ] && [[ $room == *"memgate free_mb=9216 sum_mb=17408 budget_mb=26624"* ]] && pass "(q) db classes -> .room='$room'" || bad "(q) rc=$rc room='$room'"
# (q2) same slots, no state.db -> numeric names fall back to the largest cap (13+13 = 26 G) -> 78 memgate NO
rbcase q2 CARBON_ROOM_MEMINFO="$(meminfo 20000)" RB_ROOM_WMB_BIN="$R/wmb-num" RB_ROOM_STATE_DB="$R/no-such.db"
rep=$(cat "$D/t.report.md" 2>/dev/null)
[ $rc = 78 ] && [[ $rep == "REFUSED room rc=3: memgate NO: free_mb=0 < need_mb=900"* ]] && pass "(q2) no db -> largest cap, '$rep'" || bad "(q2) rc=$rc rep='$rep'"

# --- watchman reap (ctl k1039): a process named watchman listed in a fake cgroup.procs; only the unit's own cgroup is reaped
mkdir -p "$R/wm" "$R/cg/u/rb-coder-t.service" "$R/cg/u/rb-coder-other.service"; cp "$(command -v sleep)" "$R/wm/watchman"
"$R/wm/watchman" 30 & wpid=$!
echo "$wpid" > "$R/cg/u/rb-coder-other.service/cgroup.procs"; echo "$wpid" > "$R/cg/u/rb-coder-t.service/cgroup.procs"
# (w1) cgroup of another unit -> watchman left alone
case_ w1 "$R/ok-fake" "" "" RB_ROOM_PEAK_MB=900 RB_CODER_CGROUP=/u/rb-coder-other.service RB_CODER_CGROUP_FS="$R/cg"
[ $rc = 0 ] && kill -0 "$wpid" 2>/dev/null && pass "(w1) other unit's cgroup -> watchman $wpid untouched" || bad "(w1) rc=$rc alive=$(kill -0 "$wpid" 2>&1 && echo yes)"
# (w2) this unit's cgroup -> watchman TERMed on exit (wait status 143), coder rc unchanged
case_ w2 "$R/ok-fake" "" "" RB_ROOM_PEAK_MB=900 RB_CODER_CGROUP=/u/rb-coder-t.service RB_CODER_CGROUP_FS="$R/cg"
wait "$wpid"; ws=$?
[ $rc = 0 ] && [ $ws = 143 ] && pass "(w2) own cgroup -> watchman reaped (wait=$ws), rc=0" || bad "(w2) rc=$rc wait=$ws"

echo "pass=$npass fail=$fail"
[ $fail = 0 ] && echo "ALL PASS ($npass checks)"
exit $fail
