#!/usr/bin/env bash
# rb-fable-gate-stale.test.sh - ctl 4bed: rb-fable-gate.py refuses `db-stale <age>s` when the decisions DB file is older than
# RB_FABLE_GATE_MAX_AGE_S (default 1800), passes a fresh one, and rb-run-coder.sh defaults to carbon's ledger copy decisions-carbon.sqlite.
# Fixture DB under a mktemp -d root; the real decisions DB is never opened.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gate=$here/../.local/lib/rb-fable-gate.py; runc=$here/../.local/bin/rb-run-coder.sh
fail=0; npass=0
pass() { npass=$((npass+1)); echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
R=$(mktemp -d "${TMPDIR:-/tmp}/rb-fable-gate-stale.XXXXXX") || exit 2
trap 'case "$R" in */rb-fable-gate-stale.*) rm -rf "$R";; esac' EXIT

P=$R/p.prompt; printf 'do the thing\n' > "$P"; HEX=$(sha256sum "$P" | cut -d' ' -f1)
RID="d-$(date +%Y%m%d-%H%M%S)-rb-0abc"; printf 'Hatch: %s\n' "$RID" >> "$P"
DB=$R/decisions-carbon.sqlite
python3 -I - "$DB" "$RID" "$HEX" <<'PY'
import sqlite3, sys
path, rid, hexd = sys.argv[1:]
db = sqlite3.connect(path)
db.execute("CREATE TABLE decisions (id TEXT PRIMARY KEY, ts TEXT, kind TEXT, model TEXT, what TEXT, evidence TEXT, regrade TEXT)")
db.execute("INSERT INTO decisions VALUES (?,?,?,?,?,?,?)", (rid, "t", "other", "m", "NO-SPEC-SPAWN x", "sha256:" + hexd, None))
db.commit()
PY

out=$(python3 -I "$gate" hatch "$P" "$DB"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$RID" ] && pass "fresh DB passes ($out)" || bad "fresh DB: rc=$rc out=$out"

touch -d '-31 minutes' "$DB"
out=$(python3 -I "$gate" hatch "$P" "$DB"); rc=$?
[ "$rc" = 1 ] && [[ "$out" =~ ^db-stale\ 18[0-9][0-9]s$ ]] && pass "31-min-old DB refuses ($out)" || bad "stale DB: rc=$rc out=$out"

out=$(python3 -I "$gate" spec "$P" "$DB"); rc=$?
[ "$rc" = 1 ] && [[ "$out" == db-stale* ]] && pass "spec mode refuses a stale DB too ($out)" || bad "stale spec: rc=$rc out=$out"

out=$(RB_FABLE_GATE_MAX_AGE_S=7200 python3 -I "$gate" hatch "$P" "$DB"); rc=$?
[ "$rc" = 0 ] && pass "RB_FABLE_GATE_MAX_AGE_S=7200 accepts the same file" || bad "max-age override: rc=$rc out=$out"

out=$(python3 -I "$gate" hatch "$P" "$R/absent.sqlite"); rc=$?
[ "$rc" = 1 ] && [ "$out" = db-unreadable ] && pass "missing DB stays db-unreadable" || bad "missing DB: rc=$rc out=$out"

grep -q 'fg_db="${RB_DECISIONS_DB:-$HOME/.local/state/swarm-decide/decisions-carbon.sqlite}"' "$runc" && pass "rb-run-coder.sh defaults to decisions-carbon.sqlite" || bad "runner default path"

echo "passed $npass"; exit $fail
