# tests/rb_merge_fixture.sh -- sourced by tests/rb_merge_pregate.test.sh and tests/rb_merge_wrapper.test.sh: a fixture decisions DB, a fixture
# aide-verifier state dir and REAL wm-verify-run logs, all under a mktemp root the caller created (never a real host path).
# Needs: RBF_ROOT (the caller's mktemp -d), python3, git, jq-free. The live swarm-decide tree is only imported (read-only) for attach_block/parse_attachments.
rbf_gate_root() { printf '%s' "${AIDE_VERIFIER_GATE_ROOT:-$HOME/.local/share/swarm-decide/live/current}"; }
rbf_init() {   # sets AIDE_VERIFIER_DIR, RB_DECISIONS_DB, AIDE_VERIFIER_GATE_ROOT, WM_VERIFY_DIR; makes a one-commit git repo in $RBF_ROOT/pr
  export AIDE_VERIFIER_DIR="$RBF_ROOT/state" RB_DECISIONS_DB="$RBF_ROOT/decisions.sqlite" WM_VERIFY_DIR="$RBF_ROOT/verify"
  export AIDE_VERIFIER_GATE_ROOT; AIDE_VERIFIER_GATE_ROOT="$(rbf_gate_root)"
  mkdir -p "$AIDE_VERIFIER_DIR" "$WM_VERIFY_DIR" "$RBF_ROOT/pr"
  ( cd "$RBF_ROOT/pr" && git init -q . && echo one > f.txt && git add f.txt \
    && git -c user.name=t -c user.email=t@t commit -qm one ) >/dev/null
  RBF_HEAD="$(git -C "$RBF_ROOT/pr" rev-parse HEAD)"
  python3 -I -B -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("CREATE TABLE decisions (id TEXT PRIMARY KEY, what TEXT, evidence TEXT)"); d.commit()' "$RB_DECISIONS_DB"
}
rbf_launch() {   # rbf_launch <name> <suite text>: what aide-verifier.sh launch writes -- suite.txt byte-exact + meta suite_sha256
  mkdir -p "$AIDE_VERIFIER_DIR/$1"
  printf '%s' "$2" > "$AIDE_VERIFIER_DIR/$1/suite.txt"
  printf 'name=%s\nsuite_sha256=%s\n' "$1" "$(sha256sum "$AIDE_VERIFIER_DIR/$1/suite.txt" | cut -d' ' -f1)" > "$AIDE_VERIFIER_DIR/$1/meta"
}
rbf_log() {   # rbf_log <cmd> -> the log path of a REAL `wm-verify-run '<cmd>'` in the fixture repo (rc of the command is ignored)
  local wvr; wvr="$(command -v wm-verify-run || echo "$HOME/.local/bin/wm-verify-run")"
  ( cd "$RBF_ROOT/pr" && "$wvr" "$1" 2>/dev/null ) | sed -n 's/.* log=\([^ ]*\) exit=.*/\1/p'
}
rbf_row() {   # rbf_row <id> <commit> <name> <log>...  : insert a MERGE-OK row whose evidence holds real attach blocks of the logs
  local id="$1" commit="$2" name="$3"; shift 3
  python3 -I -B - "$AIDE_VERIFIER_GATE_ROOT" "$RB_DECISIONS_DB" "$id" "$commit" "$name" "${RBF_REPO:-j0yen/dotfiles}" "${RBF_PR:-7}" "$@" <<'PY'
import sqlite3, sys
sys.dont_write_bytecode = True
root, db, vid, commit, name, repo, prn, *logs = sys.argv[1:]
sys.path.insert(0, root)
from wm_decide import mergegate as mg
ev = "\n".join(mg.attach_block(p) for p in logs)
what = "MERGE-OK %s#%s COMMIT=%s agent=verifier:rb-verifier-%s recorded_by=unit:rb-verifier-%s" % (repo, prn, commit, name, name)
d = sqlite3.connect(db)
d.execute("INSERT OR REPLACE INTO decisions (id, what, evidence) VALUES (?,?,?)", (vid, what, ev))
d.commit()
PY
}
rbf_log_at() {   # rbf_log_at <head> <cmd> -> path of a log in wm-verify-run's format whose HEAD is <head> (for a stub gate whose oid is not the fixture repo's HEAD)
  local p="$RBF_ROOT/verify/at-$1-$$-$RANDOM.log"; mkdir -p "$RBF_ROOT/verify"
  { echo fixture-output; echo "WM-VERIFY HEAD=$1"; echo "WM-VERIFY CMD=${2//$'\n'/ }"; echo "WM-VERIFY DIRTY=0"; echo "WM-VERIFY EXIT=0"; } > "$p"
  printf '%s' "$p"
}
rbf_pg() {   # rbf_pg <verdict id> <owner/name> <pr> <commit>: what pre-gate A needs for a stubbed merge -- a launcher record, a clean suite log at <commit>, a MERGE-OK row in RB_DECISIONS_DB
  rbf_launch fxs 'echo fixture-suite'
  RBF_REPO="$2" RBF_PR="$3" rbf_row "$1" "$4" fxs "$(rbf_log_at "$4" 'echo fixture-suite')"
}
rbf_ledger() {   # rbf_ledger <verdict id> <owner/name> <pr> <commit> [adv]: what the ADV pre-check reads from $WM_DECIDE_STATE/decisions.sqlite -- gated row G + verdict V (+ an ADV-PASS row when "adv")
  mkdir -p "$WM_DECIDE_STATE"; : > "$RBF_ROOT/adv-pass.log"; echo "adversarial verifier output" > "$RBF_ROOT/adv-pass.log"
  python3 -I -B - "$WM_DECIDE_STATE/decisions.sqlite" "$(dirname "${BASH_SOURCE[0]}")/fixtures/rb-merge-adv/decisions.ddl.sql" "$RBF_ROOT/adv-pass.log" "$@" <<'PY'
import sqlite3, sys
db, ddl, advlog, vid, repo, prn, commit, *adv = sys.argv[1:]
d = sqlite3.connect(db)
if not d.execute("select 1 from sqlite_master where name='decisions'").fetchone():
    d.executescript(open(ddl).read())
def put(rid, ts, kind, what, gates=None):
    d.execute("INSERT OR REPLACE INTO decisions (id, ts, agent, via, kind, target, what, why, evidence, reverse, gates) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
              (rid, ts, "r7", "verifier", kind, "{}", what, "fixture", "fixture", "fixture", gates))
g = "g-" + vid
put(g, "2026-11-02T10:00:00-08:00", "other", "GATED %s#%s fixture" % (repo, prn))
put(vid, "2026-11-02T10:01:00-08:00", "verdict", "CONFIRM fixture COMMIT=%s" % commit, g)
if adv:
    put("a-" + vid, "2026-11-02T10:02:00-08:00", "verdict",
        "ADV-PASS %s#%s COMMIT=%s agent=verifier:v-adv scope=adversarial log=%s: ok" % (repo, prn, commit, advlog), g)
d.commit()
PY
}
