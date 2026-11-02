#!/usr/bin/env bash
# rb-fable-gate-confirm-refused.test.sh - fvg v0.2.3 (Fable 33fa edit 1): CONFIRM is the regrade vocabulary, not a spec-review verdict, so
# rb-fable-gate.py must refuse a kind=verdict model=fable row whose first word is CONFIRM even when it carries the spec's sha256 + stem.
# The CONFIRM fixture row is byte-identical to the AGREE-WITH-EDITS pass row except the first word. The gate is invoked directly with the
# fixture DB as argv[3] and RB_DECISIONS_DB set to the same fixture; every path lives under a mktemp -d root this test created.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gate=${RB_FABLE_GATE_UNDER_TEST:-$here/../.local/lib/rb-fable-gate.py}   # a mutation proof points this at a throwaway copy
fail=0; npass=0
pass() { npass=$((npass+1)); echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
R=$(mktemp -d "${TMPDIR:-/tmp}/rb-fable-gate-confirm-test.XXXXXX") || exit 2
trap 'case "$R" in */rb-fable-gate-confirm-test.*) rm -rf "$R";; esac' EXIT

SP=$R/zed.spec.md
printf '# zed\n## Premises\n- a.sh:1 -> x\n## Change\n1. y\n' > "$SP"
HEX=$(sha256sum "$SP" | cut -d' ' -f1)
EV="sha256:$HEX (zed.spec.md folded); reply ~/x sha256 00; spawn: Agent task t1"
M=claude-fable-5-1
ID=d-20261023-100000-rb-aaaa

# mkdb <path> <what>: one kind=verdict model=fable row in the real wm-decide decisions shape
mkdb() {
  python3 -I - "$1" "$2" "$ID" "$M" "$EV" <<'PY'
import sqlite3, sys
path, what, rid, model, ev = sys.argv[1:6]
db = sqlite3.connect(path)
db.execute("""CREATE TABLE decisions (id TEXT PRIMARY KEY, ts TEXT NOT NULL, agent TEXT NOT NULL, via TEXT NOT NULL, model TEXT, kind TEXT NOT NULL, target TEXT,
  what TEXT NOT NULL, why TEXT NOT NULL, evidence TEXT NOT NULL, reverse TEXT NOT NULL, rule_ids TEXT, first_verdict TEXT, regrade TEXT,
  regrade_attempts INTEGER NOT NULL DEFAULT 0, correction TEXT, tags TEXT, outcome TEXT, expect_by TEXT, graded_at TEXT, grader TEXT, gates TEXT, session TEXT)""")
db.execute("INSERT INTO decisions (id, ts, agent, via, model, kind, what, why, evidence, reverse, regrade) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
           (rid, "ts-" + rid, "rb", "t", model, "verdict", what, "w", ev, "r", None))
db.commit(); db.close()
PY
}
# run <label> <expect-rc> <expect-out-glob> <what>
run() {
  local label=$1 erc=$2 eout=$3 what=$4 db="$R/$RANDOM.db"; mkdb "$db" "$what"
  local before out rc after; before=$(sha256sum "$db" | cut -d' ' -f1)
  out=$(RB_DECISIONS_DB=$db python3 -I "$gate" spec "$SP" "$db" 2>&1); rc=$?
  after=$(sha256sum "$db" | cut -d' ' -f1)
  if [ "$erc" = 0 ]; then [ $rc = 0 ] || { bad "$label: rc=$rc want 0 out='$out'"; return; }
  else [ $rc != 0 ] || { bad "$label: rc=0 want non-zero out='$out'"; return; }; fi
  [[ $out == $eout ]] || { bad "$label: out='$out' want '$eout'"; return; }
  [ "$before" = "$after" ] || { bad "$label: fixture DB bytes changed"; return; }
  pass "$label -> rc=$rc out='$out'"
}

run "(k1) AGREE-WITH-EDITS + sha + stem passes"  0 "OK $ID"             'AGREE-WITH-EDITS zed spec'
run "(k2) AGREE + sha + stem passes"             0 "OK $ID"             'AGREE zed spec'
run "(k3) CONFIRM + sha + stem is refused, naming the word" 1 "verdict-CONFIRM $ID" 'CONFIRM zed spec'
echo "tests: $npass passed"
[ $fail = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
