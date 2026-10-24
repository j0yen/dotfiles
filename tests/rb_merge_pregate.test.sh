#!/usr/bin/env bash
# tests/rb_merge_pregate.test.sh -- .local/bin/rb-merge.sh pre-gate A (hand PR vtg1; ctl fef9): exit 6 + a named reason, never a `gh pr merge`, unless
# exactly one attached log is the clean PR-head run of the suite the LAUNCHER wrote (suite.txt), CMD byte-equal after wm-verify-run's flatten.
# Fixtures are REAL wm-verify-run logs + real attach_block rows in a mktemp DB; gh and wm-decide are stubs on RB_MERGE_GH/WM_DECIDE_BIN; HOME is a mktemp dir.
# Plain bash, from the repo root:  bash tests/rb_merge_pregate.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrap="$here/.local/bin/rb-merge.sh"
RBF_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rbpg.XXXXXX")"; export RBF_ROOT
trap 'rm -rf "$RBF_ROOT"' EXIT
. "$here/tests/rb_merge_fixture.sh"
export AIDE_VERIFIER_GATE_ROOT; AIDE_VERIFIER_GATE_ROOT="$(rbf_gate_root)"   # resolved BEFORE HOME moves; the live tree is only imported
[ -f "$AIDE_VERIFIER_GATE_ROOT/wm_decide/mergegate.py" ] || { echo "NOT OK - pregate: no swarm-decide gate tree at $AIDE_VERIFIER_GATE_ROOT (set AIDE_VERIFIER_GATE_ROOT)"; exit 1; }
export HOME="$RBF_ROOT/home"; mkdir -p "$HOME"
fail=0
ok()  { echo "ok - pregate: $1"; }
bad() { echo "NOT OK - pregate: $1"; fail=1; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', want '$2'"; fi; }

wvr_real="$(command -v wm-verify-run || true)"; [ -n "$wvr_real" ] || wvr_real="/home/jsy/.local/bin/wm-verify-run"
[ -x "$wvr_real" ] || { echo "NOT OK - pregate: no wm-verify-run to build real fixtures with"; exit 1; }
export PATH="$(dirname "$wvr_real"):$PATH"

rbf_init
cat > "$RBF_ROOT/wm-decide" <<'S'
#!/usr/bin/env bash
printf 'wmd %s\n' "$*" >> "$STUB_LOG/calls"
case "$1" in
  merge-gate) echo "PASS verdict=$2 pr=$5#$4 oid=${STUB_OID}"; exit 0 ;;
  merge-done) exit 0 ;;
esac
S
cat > "$RBF_ROOT/gh" <<'S'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG/calls"
case "$1 $2" in
  "pr view") case "$*" in *mergeCommit*) echo "b1b2c3d4e5f60123456789abcdef0123456789ab" ;; *) echo '{"title":"T","body":"b"}' ;; esac; exit 0 ;;
  "api repos/"*"/pulls/"*"/commits") q=""; prev=""; for a in "$@"; do { [ "$prev" = "-q" ] || [ "$prev" = "--jq" ]; } && q="$a"; prev="$a"; done
    printf '%s' '[{"sha":"aaaaaaaaaaaa0000","commit":{"message":"clean"}}]' | jq -r "$q"; exit $? ;;
  "api repos/"*) echo "clean"; exit 0 ;;
esac
exit 0
S
chmod +x "$RBF_ROOT/wm-decide" "$RBF_ROOT/gh"
export STUB_LOG="$RBF_ROOT" STUB_OID="$RBF_HEAD" WM_DECIDE_BIN="$RBF_ROOT/wm-decide" RB_MERGE_GH="$RBF_ROOT/gh"
SUITE='echo suite-ran-ok'
SUITE_ML=$'echo line-one\necho line-two'
rbf_launch n1 "$SUITE"
rbf_launch nml "$SUITE_ML"

# run <verdict-id>: wrapper rc in $rc, stderr in $err (a file), calls in $RBF_ROOT/calls
run() { : > "$RBF_ROOT/calls"; bash "$wrap" "$1" 7 j0yen/dotfiles >/dev/null 2>"$RBF_ROOT/err"; rc=$?; }
merges() { grep -c 'pr merge' "$RBF_ROOT/calls" || true; }
done_n() { grep -c 'merge-done' "$RBF_ROOT/calls" || true; }
# refused <verdict-id> <reason> <label>: rc 6, the reason + verdict on stderr, no gh pr merge, no merge-done
refused() {
  run "$1"
  check "$rc:$(merges):$(done_n)" "6:0:0" "$3: exit 6, no gh pr merge, no merge-done"
  grep -qE "^rb-merge\.sh: $2 $1: " "$RBF_ROOT/err" && ok "$3: stderr names the reason $2 and the verdict" || bad "$3: stderr lacks '$2 $1': $(cat "$RBF_ROOT/err")"
}

# ---- admitted ----
L_OK="$(rbf_log "$SUITE")"
rbf_row v-ok "$RBF_HEAD" n1 "$L_OK"
db_before="$(sha256sum "$RB_DECISIONS_DB" | cut -d' ' -f1)"
run v-ok
check "$rc:$(merges):$(done_n)" "0:1:1" "the suite log at the PR head, clean, EXIT 0, byte-equal CMD: admitted, merged once"
check "$(sha256sum "$RB_DECISIONS_DB" | cut -d' ' -f1)" "$db_before" "the pre-gate never writes the decisions DB"
L_ML="$(rbf_log "$SUITE_ML")"
rbf_row v-ml "$RBF_HEAD" nml "$L_ML"
run v-ml
check "$rc:$(merges)" "0:1" "a MULTI-LINE suite: a REAL wm-verify-run trailer (newline -> one space) matches the flattened suite.txt (no-drift)"
grep -q 'WM-VERIFY CMD=echo line-one echo line-two$' "$L_ML" && ok "no-drift: the real wm-verify-run flattened the newline to one space (the rule rb-merge.sh pins)" || bad "wm-verify-run's flatten rule changed: $(tail -4 "$L_ML")"
L_EX="$(rbf_log 'git log --oneline')"
rbf_row v-extra "$RBF_HEAD" n1 "$L_OK" "$L_EX"
run v-extra; check "$rc:$(merges)" "0:1" "an extra non-replay block (git log) next to the suite log passes the denylist"

# ---- suite-unknown ----
rbf_row v-nolaunch "$RBF_HEAD" ghost "$L_OK"
refused v-nolaunch suite-unknown "no launcher dir for the verdict's name"
mkdir -p "$AIDE_VERIFIER_DIR/nosuite"; printf 'name=nosuite\n' > "$AIDE_VERIFIER_DIR/nosuite/meta"
rbf_row v-nosuite "$RBF_HEAD" nosuite "$L_OK"
refused v-nosuite suite-unknown "meta without suite.txt (a pre-vtg1 launch)"
rbf_launch tamper "$SUITE"; printf '%s' "echo evil" > "$AIDE_VERIFIER_DIR/tamper/suite.txt"
rbf_row v-tamper "$RBF_HEAD" tamper "$L_OK"
refused v-tamper suite-unknown "suite.txt edited after launch (sha256 != meta suite_sha256)"
python3 -I -B -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("INSERT INTO decisions VALUES (?,?,?)",("v-noagent","MERGE-OK j0yen/dotfiles#7 COMMIT="+sys.argv[2],"")); d.commit()' "$RB_DECISIONS_DB" "$RBF_HEAD"
refused v-noagent suite-unknown "a row naming no agent=verifier:<agent>-verifier-<name>"

# ---- suite-mismatch ----
L_CAT="$(rbf_log "cat $L_OK")"
rbf_row v-cat "$RBF_HEAD" n1 "$L_CAT"
refused v-cat suite-mismatch "a cat of the earlier suite log (the fef9 replay)"
L_SUP="$(rbf_log "$SUITE ; true")"
rbf_row v-super "$RBF_HEAD" n1 "$L_SUP"
refused v-super suite-mismatch "ONE EXTRA CHARACTER class: CMD = suite + ' ; true' (the old substring rule admitted it; byte-equality does not)"
L_PRE="$(rbf_log "true ; $SUITE")"
rbf_row v-pre "$RBF_HEAD" n1 "$L_PRE"
refused v-pre suite-mismatch "CMD = 'true ; ' + suite"
L_SUB="$(rbf_log "echo suite-ran")"
rbf_row v-sub "$RBF_HEAD" n1 "$L_SUB"
refused v-sub suite-mismatch "CMD is a strict prefix of the suite"
L_SH="$(rbf_log "bash -c '$SUITE'")"
rbf_row v-bashc "$RBF_HEAD" n1 "$L_SH"
refused v-bashc suite-mismatch "bash -c '<suite>' wrapper"
rbf_row v-onlyextra "$RBF_HEAD" n1 "$L_EX"
refused v-onlyextra suite-mismatch "only a non-suite block is attached"

# ---- suite-ambiguous ----
L_OK2="$(rbf_log "$SUITE")"
rbf_row v-amb "$RBF_HEAD" n1 "$L_OK" "$L_OK2"
refused v-amb suite-ambiguous "two suite-CMD blocks"

# ---- head-mismatch ----
( cd "$RBF_ROOT/pr" && echo two >> f.txt && git -c user.name=t -c user.email=t@t commit -qam two ) >/dev/null
HEAD2="$(git -C "$RBF_ROOT/pr" rev-parse HEAD)"
rbf_row v-oldhead "$HEAD2" n1 "$L_OK"
STUB_OID="$HEAD2" refused v-oldhead head-mismatch "the suite log HEAD is the older commit, the verdict COMMIT the new one"
rbf_row v-gateoid "$RBF_HEAD" n1 "$L_OK"
STUB_OID="$HEAD2" refused v-gateoid head-mismatch "the gate's oid != the verdict COMMIT (checked after merge-gate)"
python3 -I -B -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("UPDATE decisions SET what=replace(what,\"COMMIT=\"||?,\"COMMIT=abc123\") WHERE id=\"v-ok\"",(sys.argv[2],)); d.execute("INSERT INTO decisions SELECT \"v-shortc\",what,evidence FROM decisions WHERE id=\"v-ok\"") ; d.execute("UPDATE decisions SET what=replace(what,\"COMMIT=abc123\",\"COMMIT=\"||?) WHERE id=\"v-ok\"",(sys.argv[2],)); d.commit()' "$RB_DECISIONS_DB" "$RBF_HEAD"
refused v-shortc head-mismatch "a COMMIT= that is not 40 hex"

# ---- suite-dirty / suite-red ----
( cd "$RBF_ROOT/pr" && echo dirty >> f.txt )
L_DIRTY="$(rbf_log "$SUITE")"
( cd "$RBF_ROOT/pr" && git checkout -q -- f.txt )
rbf_row v-dirty "$HEAD2" n1 "$L_DIRTY"
STUB_OID="$HEAD2" refused v-dirty suite-dirty "the suite ran on a dirty tree (DIRTY=1)"
rbf_launch nred 'echo red ; exit 3'
L_RED="$(rbf_log 'echo red ; exit 3')"
rbf_row v-red "$HEAD2" nred "$L_RED"
STUB_OID="$HEAD2" refused v-red suite-red "the suite exited non-zero (EXIT=3)"

# ---- replay-log (secondary denylist on EXTRA blocks) ----
L_OK_H2="$(rbf_log "$SUITE")"
i=0
for rc_cmd in "cat $L_OK" "echo PASS 100 passed" "printf '%s\n' green" "cat $L_OK | tee /dev/null" "true" "tail -n 3 $L_OK" "sed -n 1,5p $L_OK" "bash -c 'echo hi'" "sh -c 'cat $L_OK'"; do
  i=$((i+1)); L_X="$(rbf_log "$rc_cmd")"
  rbf_row "v-rep$i" "$HEAD2" n1 "$L_OK_H2" "$L_X"
  STUB_OID="$HEAD2" refused "v-rep$i" replay-log "an extra block that only replays: $rc_cmd"
done
# the wiki case: a denylisted-looking word inside a real command is NOT a replay
L_GREP="$(rbf_log "git log --oneline -n 1")"
rbf_row v-norep "$HEAD2" n1 "$L_OK_H2" "$L_GREP"
STUB_OID="$HEAD2" run v-norep; check "$rc:$(merges)" "0:1" "an extra real command (git log) is not a replay"

# ---- trailer-missing ----
python3 -I -B -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); w,e=d.execute("SELECT what,evidence FROM decisions WHERE id=\"v-ok\"").fetchone(); e="\n".join(l for l in e.split("\n") if not l.startswith("| WM-VERIFY DIRTY=")); d.execute("INSERT INTO decisions VALUES (\"v-notr\",?,?)",(w,e)); d.commit()' "$RB_DECISIONS_DB"
refused v-notr trailer-missing "a block whose stored tail lacks the DIRTY trailer line"

# ---- pre-gate-error: fail closed ----
refused v-does-not-exist pre-gate-error "no such decisions row"
python3 -I -B -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("INSERT INTO decisions SELECT \"v-otherpr\",replace(what,\"#7\",\"#8\"),evidence FROM decisions WHERE id=\"v-ok\""); d.commit()' "$RB_DECISIONS_DB"
refused v-otherpr pre-gate-error "a MERGE-OK row for a different PR number"
RB_DECISIONS_DB="$RBF_ROOT/missing.sqlite" refused v-ok pre-gate-error "an unreadable decisions DB"
AIDE_VERIFIER_GATE_ROOT="$RBF_ROOT/no-such-root" refused v-ok pre-gate-error "an unusable gate root"
check "$([ -e "$RBF_ROOT/missing.sqlite" ] && echo created || echo absent)" "absent" "a missing DB is not created by the read-only open"

# ---- unchanged exits ----
bash "$wrap" v-ok seven j0yen/dotfiles >/dev/null 2>&1; check "$?" "64" "usage error stays 64 (before the pre-gate)"

# ---- structure ----
pg="$(grep -n 'pg_commit="\${pg_line' "$wrap" | head -1 | cut -d: -f1)"; gm="$(grep -n '^\s*"\$GH" pr merge\|"\$GH" pr merge' "$wrap" | head -1 | cut -d: -f1)"
{ [ -n "$pg" ] && [ -n "$gm" ] && [ "$pg" -lt "$gm" ]; } && ok "the pre-gate sits before the first gh pr merge in the wrapper (line $pg < $gm)" || bad "pre-gate not before gh pr merge ($pg, $gm)"
grep -q 'mode=ro' "$wrap" && ok "the decisions DB is opened mode=ro" || bad "no mode=ro in the pre-gate"
grep -q 'mg.parse_attachments' "$wrap" && ok "the live parse_attachments is used (no reimplementation)" || bad "parse_attachments not used"
grep -q 'gating = \[a for a in atts if a\["trailer"\]\["CMD"\] == flat\]' "$wrap" && ok "the suite match is byte-equality on the flattened suite" || bad "suite match is not ==, see the wrapper"

[ "$fail" = 0 ] && echo "ALL OK - pregate" || echo "FAILED - pregate"
exit "$fail"
