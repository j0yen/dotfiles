#!/usr/bin/env bash
# rb-coder-fable-gate.test.sh - fvg: rb-run-coder.sh refuses (exit 78) a spawn unless every cited *.spec.md is covered, by sha256 of its bytes,
# by the newest decisions row = kind verdict + model fable + final verdict AGREE|AGREE-WITH-EDITS|CONFIRM + the spec's stem; a prompt citing no spec
# needs a valid `Hatch:` row. Every case asserts the exit code AND the report reason, that the claude stub marker is absent on a refusal (the gate
# precedes the spawn), and that the fixture DB bytes are unchanged (read-only). HOME, the fixture DB, the stubs and the lock helper live under a
# mktemp -d root this test created; the real decisions DB is never opened.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runc=${RB_RUN_CODER_UNDER_TEST:-$here/../.local/bin/rb-run-coder.sh}   # a mutation proof points this at a throwaway copy
fail=0; npass=0
pass() { npass=$((npass+1)); echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
R=$(mktemp -d "${TMPDIR:-/tmp}/rb-fable-gate-test.XXXXXX") || exit 2
LOCKPID=""
trap '[ -z "$LOCKPID" ] || kill "$LOCKPID" 2>/dev/null; case "$R" in */rb-fable-gate-test.*) rm -rf "$R";; esac' EXIT

H=$R/home; CD=$H/.cache/rb-seat/coders
mkdir -p "$H/.config/environment.d" "$H/.local/bin" "$CD"
: > "$H/.config/environment.d/90-claude-oauth.conf"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/events.log"\n' "$R" > "$H/.local/bin/seat-event.sh"
printf '#!/usr/bin/env bash\necho ran >> "%s/claude.ran"\nexit 0\n' "$R" > "$H/.local/bin/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/.cache/rb-seat/spec-lint.sh"      # spec-lint (73) is not under test here
printf '#!/usr/bin/env bash\necho "OK stub"\nexit 0\n' > "$R/hold.stub"
chmod +x "$H/.local/bin/seat-event.sh" "$H/.local/bin/claude" "$R/hold.stub"

SP=$CD/zed.spec.md
printf '# zed\n## Premises\n- a.sh:1 -> x\n## Change\n1. y\n' > "$SP"
HEX=$(sha256sum "$SP" | cut -d' ' -f1)

# mkdb <path> <rows-json> [wal]: fixture decisions table in the real wm-decide shape; row keys id, kind, model, what, evidence, regrade
mkdb() {
  python3 -I - "$1" "$2" "${3:-}" <<'PY'
import json, sqlite3, sys
path, rows, wal = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3] == "wal"
db = sqlite3.connect(path)
if wal:
    db.execute("PRAGMA journal_mode=WAL")
db.execute("""CREATE TABLE decisions (id TEXT PRIMARY KEY, ts TEXT NOT NULL, agent TEXT NOT NULL, via TEXT NOT NULL, model TEXT, kind TEXT NOT NULL, target TEXT,
  what TEXT NOT NULL, why TEXT NOT NULL, evidence TEXT NOT NULL, reverse TEXT NOT NULL, rule_ids TEXT, first_verdict TEXT, regrade TEXT,
  regrade_attempts INTEGER NOT NULL DEFAULT 0, correction TEXT, tags TEXT, outcome TEXT, expect_by TEXT, graded_at TEXT, grader TEXT, gates TEXT, session TEXT)""")
for r in rows:
    db.execute("INSERT INTO decisions (id, ts, agent, via, model, kind, what, why, evidence, reverse, regrade) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
               (r["id"], "ts-" + r["id"], "rb", "t", r.get("model"), r.get("kind", "verdict"), r.get("what", "AGREE-WITH-EDITS zed spec"), "w",
                r.get("evidence", ""), "r", r.get("regrade")))
db.commit(); db.close()
PY
}
# row <id> <kind> <model> <what> <evidence> [regrade-json-or-empty] -> one JSON object
row() { python3 -I -c 'import json,sys; a=sys.argv[1:]; d=dict(id=a[0],kind=a[1],model=a[2] or None,what=a[3],evidence=a[4]); d.update(regrade=a[5]) if len(a)>5 and a[5] else None; print(json.dumps(d))' "$@"; }
M=claude-fable-5-1
EV="sha256:$HEX (zed.spec.md folded); reply ~/x sha256 00; spawn: Agent task t1"

n=0
# case <label> <expect-rc> <expect-reason-glob|-> <db> <prompt-file> [run-coder flags...]
case_() {
  local label=$1 erc=$2 ereason=$3 db=$4 pf=$5; shift 5; n=$((n+1))
  rm -f "$R/claude.ran" "$CD/c$n.report.md"; : > "$R/events.log"
  local before=""; [ ! -f "$db" ] || before=$(sha256sum "$db" | cut -d' ' -f1)
  HOME=$H RB_DECISIONS_DB=$db RB_SPAWN_HOLD_BIN=$R/hold.stub RB_FABLE_GATE_TIMEOUT=${GATE_TO:-0.3} bash "$runc" "c$n" "$pf" "$@" >/dev/null 2>&1; local rc=$?
  local rep; rep=$(cat "$CD/c$n.report.md" 2>/dev/null)
  local after=""; [ ! -f "$db" ] || after=$(sha256sum "$db" | cut -d' ' -f1)
  local ok=1 why=""
  [ "$rc" = "$erc" ] || { ok=0; why="rc=$rc want $erc"; }
  if [ "$erc" = 78 ]; then
    [[ $rep == "REFUSED fable-verdict "*": $ereason"* ]] || { ok=0; why="$why report='$rep' want reason '$ereason'"; }
    [ ! -e "$R/claude.ran" ] || { ok=0; why="$why claude ran after a refusal"; }
    grep -q "RB-CODER c$n REFUSED fable-verdict" "$R/events.log" || { ok=0; why="$why no REFUSED seat-event"; }
  elif [ "$erc" = 0 ]; then
    [ -e "$R/claude.ran" ] || { ok=0; why="$why claude marker absent on a pass"; }
    [[ $rep != *REFUSED* ]] || { ok=0; why="$why report='$rep'"; }
  else
    [ ! -e "$R/claude.ran" ] || { ok=0; why="$why claude ran after a refusal"; }
  fi
  [ "$before" = "$after" ] || { ok=0; why="$why fixture DB bytes changed"; }
  if [ $ok = 1 ]; then pass "$label -> rc=$rc${rep:+ report='$rep'}"; else bad "$label:$why"; fi
}
prompt_spec() { printf 'ctx %0200d\nSpec: %s\n' 0 "$1" > "$R/p.$n.md"; echo "$R/p.$n.md"; }   # n is the NEXT case number's predecessor: unique per call

ID1=d-20261023-100000-rb-aaaa; ID2=d-20261023-110000-rb-bbbb; ID3=d-20261023-120000-rb-cccc
P=$(prompt_spec "$SP")

# --- passes ---
mkdb $R/a.db "[$(row $ID1 verdict $M 'AGREE-WITH-EDITS zed spec' "$EV")]"
case_ "(a1) fable verdict AGREE-WITH-EDITS + sha + stem" 0 - $R/a.db "$P"
mkdb $R/a2.db "[$(row $ID1 verdict fable 'AGREE zed' "$EV")]"
case_ "(a2) model string 'fable'" 0 - $R/a2.db "$P"
mkdb $R/a3.db "[$(row $ID1 verdict Claude-FABLE-5-1 'CONFIRM zed' "$EV")]"
case_ "(a3) model string mixed case, CONFIRM" 0 - $R/a3.db "$P"
PT=$(prompt_spec '~/.cache/rb-seat/coders/zed.spec.md')
case_ "(a4) spec cited as ~/.cache/rb-seat/coders/zed.spec.md under the fixture HOME" 0 - $R/a.db "$PT"
mkdb $R/aw.db "[$(row $ID1 verdict $M 'AGREE-WITH-EDITS zed spec' "$EV")]" wal
case_ "(a5) WAL-mode fixture DB (the live DB's mode) passes" 0 - $R/aw.db "$P"
case_ "(a6) --no-cargo path passes too" 0 - $R/a.db "$P" --no-cargo

# --- sha binding ---
cp "$SP" "$R/zed.spec.md.orig"; printf 'x' >> "$SP"; HEX2=$(sha256sum "$SP" | cut -d' ' -f1)
case_ "(b1) spec edited by one byte after recording -> sha-mismatch naming the stem row" 78 "sha-mismatch $ID1" $R/a.db "$P"
mkdb $R/b2.db "[$(row $ID1 verdict $M 'AGREE-WITH-EDITS unrelated' "sha256:$HEX other")]"
case_ "(b2) no row names the stem either -> bare sha-mismatch" 78 "sha-mismatch" $R/b2.db "$P"
[[ "$(cat "$CD/c$n.report.md")" != *"sha-mismatch d-"* ]] && pass "(b2) bare: no id appended" || bad "(b2) id appended: $(cat "$CD/c$n.report.md")"
mkdb $R/b3.db "[$(row $ID1 verdict $M 'AGREE-WITH-EDITS zed spec' "$EV"),$(row $ID2 verdict $M 'AGREE zed re-record' "sha256:$HEX2 zed")]"
case_ "(b3) re-recorded row with the new sha -> passes" 0 - $R/b3.db "$P"
mv "$R/zed.spec.md.orig" "$SP"   # back to the recorded bytes

# --- kind / model ---
mkdb $R/c1.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV"),$(row $ID2 design claude-opus-5-5 'AGREE zed design' "$EV")]"
case_ "(c1) newest row for the sha is kind=design model=opus -> no-fable-verdict-row" 78 "no-fable-verdict-row $ID2" $R/c1.db "$P"
mkdb $R/c2.db "[$(row $ID2 design $M 'AGREE zed design' "$EV")]"
case_ "(c2) kind=design model=fable -> no-fable-verdict-row" 78 "no-fable-verdict-row $ID2" $R/c2.db "$P"
mkdb $R/c3.db "[$(row $ID2 verdict claude-opus-5-5 'AGREE zed' "$EV")]"
case_ "(c3) kind=verdict model=opus -> no-fable-verdict-row" 78 "no-fable-verdict-row $ID2" $R/c3.db "$P"
mkdb $R/c4.db "[$(row $ID2 verdict '' 'AGREE zed' "$EV")]"
case_ "(c4) kind=verdict model NULL -> no-fable-verdict-row" 78 "no-fable-verdict-row $ID2" $R/c4.db "$P"

# --- verdict word / regrade ---
mkdb $R/d1.db "[$(row $ID1 verdict $M 'DISAGREE zed' "$EV")]"
case_ "(d1) fable verdict DISAGREE -> verdict-DISAGREE" 78 "verdict-DISAGREE $ID1" $R/d1.db "$P"
mkdb $R/d2.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV" '{"by":"fable-regrader","verdict":"CORRECT","result":"DISAGREE"}')]"
case_ "(d2) what=AGREE, regrade verdict CORRECT (the regrader's real word) -> verdict-CORRECT" 78 "verdict-CORRECT $ID1" $R/d2.db "$P"
mkdb $R/d3.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV" '{"verdict":"DISAGREE"}')]"
case_ "(d3) what=AGREE, regrade verdict DISAGREE -> verdict-DISAGREE" 78 "verdict-DISAGREE $ID1" $R/d3.db "$P"
mkdb $R/d4.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV" '{"by":"fable-regrader","result":"RESOLVED"}')]"
case_ "(d4) regrade JSON without a verdict key falls back to what (AGREE passes)" 0 - $R/d4.db "$P"
mkdb $R/d5.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV" '{"verdict":"CONFIRM"}')]"
case_ "(d5) regrade verdict CONFIRM passes" 0 - $R/d5.db "$P"
mkdb $R/d6.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV" '{"verdict":"ESCALATE"}')]"
case_ "(d6) regrade verdict ESCALATE -> verdict-ESCALATE" 78 "verdict-ESCALATE $ID1" $R/d6.db "$P"
mkdb $R/d7.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV" '{not json')]"
case_ "(d7) unparseable regrade fails closed" 78 "verdict-REGRADE-UNREADABLE $ID1" $R/d7.db "$P"
mkdb $R/e1.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV"),$(row $ID2 verdict $M 'DISAGREE zed' "$EV")]"
case_ "(e1) older AGREE + newer DISAGREE on the same sha -> newest governs, 78" 78 "verdict-DISAGREE $ID2" $R/e1.db "$P"
mkdb $R/e2.db "[$(row $ID1 verdict $M 'DISAGREE zed' "$EV"),$(row $ID2 verdict $M 'AGREE zed' "$EV")]"
case_ "(e2) older DISAGREE + newer AGREE -> newest governs, passes" 0 - $R/e2.db "$P"

# --- stem ---
mkdb $R/f1.db "[$(row $ID1 verdict $M 'AGREE-WITH-EDITS other spec' "sha256:$HEX (other.spec.md); spawn t")]"
case_ "(f1) governing row names a different stem -> stem-mismatch" 78 "stem-mismatch $ID1" $R/f1.db "$P"
mkdb $R/f2.db "[$(row $ID1 verdict $M 'AGREE-WITH-EDITS unzedded' "sha256:$HEX")]"
case_ "(f2) stem only as a substring of another word -> stem-mismatch" 78 "stem-mismatch $ID1" $R/f2.db "$P"

# --- fail closed ---
case_ "(g1) RB_DECISIONS_DB missing file -> db-unreadable" 78 "db-unreadable" $R/missing.db "$P"
printf 'not a database, not a database, not a database' > $R/g2.db
case_ "(g2) not a sqlite file -> db-unreadable" 78 "db-unreadable" $R/g2.db "$P"
python3 -I -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("create table decisions (id text, kind text)"); d.commit()' $R/g3.db
case_ "(g3) schema without the needed columns -> db-unreadable" 78 "db-unreadable" $R/g3.db "$P"
mkdb $R/lock.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV")]"
python3 -I -c '
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1], isolation_level=None); c.execute("BEGIN EXCLUSIVE"); open(sys.argv[2], "w").write("held")
time.sleep(60)' $R/lock.db $R/lock.ready &
LOCKPID=$!
for _ in $(seq 1 50); do [ -e $R/lock.ready ] && break; sleep 0.1; done
[ -e $R/lock.ready ] || bad "(g4) lock helper never took the lock"
case_ "(g4) fixture DB under an exclusive write lock (helper pid $LOCKPID) -> db-locked" 78 "db-locked" $R/lock.db "$P"
kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null; LOCKPID=""
case_ "(g5) lock released -> the same DB passes" 0 - $R/lock.db "$P"

# --- no spec / hatch / spec-missing ---
NOW_ID=d-$(date +%Y%m%d-%H%M%S)-rb-dddd
OLD_ID=d-$(date -d '25 hours ago' +%Y%m%d-%H%M%S)-rb-eeee
printf 'ctx %0200d\nrun a thing with no spec\n' 0 > "$R/ns.md"
mkdb $R/h0.db "[$(row $ID1 verdict $M 'AGREE zed' "$EV")]"
case_ "(h1) prompt citing no spec -> no-spec" 78 "no-spec" $R/h0.db "$R/ns.md"
mkhatch() { # mkhatch <id> <file> -> prompt file with the Hatch line; echoes the sha of the prompt WITHOUT the line
  { cat "$R/ns.md"; printf 'Hatch: %s\n' "$1"; } > "$2"; sha256sum "$R/ns.md" | cut -d' ' -f1; }
HP=$R/hp.md; HS=$(mkhatch $NOW_ID $HP)
mkdb $R/h2.db "[$(row $NOW_ID decision '' 'NO-SPEC-SPAWN one-off probe' "sha256:$HS")]"
case_ "(h2) valid Hatch row -> passes" 0 - $R/h2.db "$HP"
grep -q "RB-CODER c$n HATCH no-spec $NOW_ID" "$R/events.log" && pass "(h2) seat-event RB-CODER HATCH no-spec $NOW_ID fired" || bad "(h2) HATCH seat-event missing: $(cat $R/events.log)"
HO=$R/ho.md; HSO=$(mkhatch $OLD_ID $HO)
mkdb $R/h3.db "[$(row $OLD_ID decision '' 'NO-SPEC-SPAWN one-off probe' "sha256:$HSO")]"
case_ "(h3) hatch row 25 h old -> no-spec (hatch-expired)" 78 "no-spec (hatch-expired)" $R/h3.db "$HO"
mkdb $R/h4.db "[$(row $NOW_ID decision '' 'NO-SPEC-SPAWN one-off probe' "sha256:$(printf 0%.0s $(seq 64))")]"
case_ "(h4) hatch row with the wrong prompt sha -> no-spec (hatch-prompt-sha-mismatch)" 78 "no-spec (hatch-prompt-sha-mismatch)" $R/h4.db "$HP"
mkdb $R/h5.db "[$(row $NOW_ID verdict $M 'NO-SPEC-SPAWN one-off probe' "sha256:$HS")]"
case_ "(h5) hatch row with kind=verdict -> no-spec (hatch-not-no-spec-decision)" 78 "no-spec (hatch-not-no-spec-decision)" $R/h5.db "$HP"
mkdb $R/h6.db "[$(row $NOW_ID decision '' 'APPROVED one-off probe' "sha256:$HS")]"
case_ "(h6) hatch row whose what is not NO-SPEC-SPAWN -> no-spec (hatch-not-no-spec-decision)" 78 "no-spec (hatch-not-no-spec-decision)" $R/h6.db "$HP"
case_ "(h7) Hatch names a row that does not exist -> no-spec (hatch-no-row)" 78 "no-spec (hatch-no-row)" $R/h0.db "$HP"
PM=$(prompt_spec "$CD/nope.spec.md")
case_ "(h8) nonexistent spec path -> spec-missing" 78 "spec-missing $CD/nope.spec.md" $R/a.db "$PM"
{ cat "$PM"; printf 'Hatch: %s\n' "$NOW_ID"; } > "$R/hm.md"
case_ "(h9) a Hatch line does not rescue a nonexistent spec" 78 "spec-missing $CD/nope.spec.md" $R/h2.db "$R/hm.md"

# --- the other gates keep their exits and precede this one ---
: > "$R/empty.md"
case_ "(i1) empty prompt still exits 74" 74 - $R/h0.db "$R/empty.md"
echo "tests: $npass passed"
[ $fail = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
