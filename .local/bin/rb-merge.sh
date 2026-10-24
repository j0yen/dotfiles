#!/usr/bin/env bash
# rb-merge.sh <verdict-id> <pr> <owner/name> -- the ONLY way a seat merges a PR:
#   wm-decide merge-gate V --pr N --repo O/R  &&  gh pr merge N --repo O/R --squash --match-head-commit <FULL head OID the gate printed> --subject <PR title> --body <PR body, attribution lines stripped>  &&  wm-decide merge-done
# The gate's stderr (one line per failed rule, G0..G7) reaches the terminal and its stdout is CAPTURED, never piped: a refused gate
# (rc 2) stops the script before gh runs (the 10-22 mcphost-deploy #73 class: `record | tail && gh pr merge` ran the merge after a refused record).
# WM_DECIDE_GATE_OK=<verdict-id> is set for the gh call only; the seat gh shim (~/.local/seat-bin/gh) refuses `pr merge` without it and without a gate-pass event.
# Daemon lands (wm-build/... branches) do not come through here. No --auto, no --admin, no extra gh flags: the gate checks the head at the time of the call.
# NO ATTRIBUTION TRAILERS IN A LANDED COMMIT (Joe 10-22): GitHub synthesizes `Co-authored-by:` from the squashed commits even with squash_merge_commit_message=PR_BODY
# (j0yen/dotfiles 383fef3), so the subject and body are passed explicitly, read ONCE from the PR before the gate with every co-authored-by / generated-with line removed.
# All three checks (pre-merge commits, post-merge message, body strip) match a LINE that STARTS with `co-authored-by:` or `generated with` (case-insensitive, leading blanks ok); prose that mentions the phrase passes.
# BEFORE the merge, once the gate passes, every commit on the PR branch is read (pulls/N/commits): a trailer in any branch commit exits 3 ATTRIBUTION-BRANCH <sha...> with NO merge
# (the branch owner re-commits clean); an unreadable list fails closed (ATTRIBUTION-UNCHECKED). RB_MERGE_ALLOW_BRANCH_TRAILERS=1 bypasses it (Joe-authorized legacy branches only) with a stderr note.
# After the merge the merge commit's message is re-read; a hit prints ATTRIBUTION-LANDED <oid> on stderr and exits 3 (the merge already happened; this makes it loud, it does not revert).
# PRE-GATE A (hand PR vtg1; ctl fef9 d-20261023-214417-controller-fef9, Fable a798): before merge-gate and before any `gh pr merge`, the verdict row is read READ-ONLY (sqlite mode=ro; RB_DECISIONS_DB overrides
# $WM_DECIDE_STATE|~/.local/state/swarm-decide/decisions.sqlite, tests only) and admitted only if exactly ONE attached log is the clean PR-head run of the suite the LAUNCHER rendered (a log replay is not).
# aide-verifier.sh launch writes <state dir>/suite.txt (+ suite_sha256 in meta); the state dir is $AIDE_VERIFIER_DIR|~/.local/state/aide-verifier/<name>, <name> from `agent=verifier:<agent>-verifier-<name>` in the row.
# The ATTACH blocks are parsed with the live tree's wm_decide.mergegate.parse_attachments (root = AIDE_VERIFIER_GATE_ROOT, tests only, else dirname(dirname(realpath(command -v wm-decide))); never a
# reimplementation): the row's STORED tail is the trailer source of truth, the attached file on disk is never read. The gating log is the block whose CMD equals suite.txt flattened by wm-verify-run's rule
# (newline -> one space; ONE function, tests/rb_merge_pregate.test.sh pins it against a real wm-verify-run trailer). Exit 6 + `rb-merge.sh: <reason> <verdict>: <detail>` on stderr, NO `gh pr merge`, reasons:
#   suite-unknown     no `agent=verifier:<agent>-verifier-<name>` in the row, no meta, no suite.txt, or suite.txt sha256 != meta suite_sha256 (a verdict from before vtg1: re-verify it from a new launch)
#   suite-mismatch    no attached block has CMD == the flattened suite (a cat/echo/bash -c/script replay with a wm-verify-run trailer lands here)
#   suite-ambiguous   two or more blocks carry the suite CMD
#   head-mismatch     the row has no single 40-hex COMMIT=, the gating log HEAD != COMMIT, or the gate's oid (checked after merge-gate) != COMMIT
#   suite-dirty       the gating log DIRTY != 0          suite-red   the gating log EXIT != 0
#   replay-log        another attached block's CMD is only cat/echo/printf/tee/true/:/head/tail/sed -n joined by ; && || |, or wrapped in bash -c / sh -c (secondary denylist; an extra `gh pr checks` block passes)
#   trailer-missing   an attached block lacks one of the HEAD/CMD/DIRTY/EXIT trailer lines in the stored tail
#   pre-gate-error    anything else (DB or gate root unreadable, row missing, not a MERGE-OK for this repo#pr, python failure): fail closed, any error in this block exits 6
# The only route around suite-unknown is a hand `gh pr merge` logged as a DECISION row, never a flag here. gh contract (shared with vtg2): `gh pr merge` is never called on a refusal; read-only gh calls are allowed.
# Exit codes: 3 attribution/oid, 6 pre-gate A, 64 usage, else the gate's (2) or gh's own.
set -euo pipefail
usage() { echo "usage: rb-merge.sh <verdict-id> <pr-number> <owner/name>" >&2; exit 64; }
[ $# -eq 3 ] || usage
v="$1"; pr="$2"; repo="$3"
case "$pr" in ''|*[!0-9]*) echo "rb-merge.sh: pr must be a number, got '$pr'" >&2; usage ;; esac
case "$repo" in */*) ;; *) echo "rb-merge.sh: repo must be owner/name, got '$repo'" >&2; usage ;; esac
WM_DECIDE="${WM_DECIDE_BIN:-wm-decide}"
GH="${RB_MERGE_GH:-gh}"

# ---- pre-gate A (see the header): fail closed, ONE exit code (6); the ERR trap covers only this block (PG_ACTIVE) ----
PG_DB="${RB_DECISIONS_DB:-${WM_DECIDE_STATE:-$HOME/.local/state/swarm-decide}/decisions.sqlite}"
PG_STATE="${AIDE_VERIFIER_DIR:-$HOME/.local/state/aide-verifier}"
PG_ACTIVE=0
pg_refuse() { PG_ACTIVE=0; echo "rb-merge.sh: $1 $v: $2" >&2; exit 6; }
trap 'rc=$?; if [ "$PG_ACTIVE" = 1 ]; then echo "rb-merge.sh: pre-gate-error $v: unexpected failure (rc $rc, line $LINENO)" >&2; exit 6; fi' ERR
PG_PY="$(cat <<'PY'
import hashlib, importlib, os, re, shlex, sqlite3, sys, urllib.parse
sys.dont_write_bytecode = True
root, db_path, vid, repo, pr, state_root = sys.argv[1:7]
sys.path.insert(0, root)
mg = importlib.import_module("wm_decide.mergegate")   # the live parse_attachments, never a copy
TRAILER = ("HEAD", "CMD", "DIRTY", "EXIT")
SIMPLE = {"cat", "echo", "printf", "tee", "true", ":", "head", "tail"}
def done(line):
    print(line)
    sys.exit(0)
def refuse(reason, detail):
    done("REFUSE %s %s" % (reason, " ".join(str(detail).split())[:300]))
def flatten(cmd):
    """THE flatten rule: wm-verify-run writes `WM-VERIFY CMD=${cmd//$'\n'/ }` -- newline -> one space, nothing else."""
    return cmd.replace("\n", " ")
def replay(cmd):
    """Secondary denylist: a CMD that only prints existing text (or wraps itself in bash -c / sh -c)."""
    if re.match(r"(?:\S*/)?(?:bash|sh)\s+-[A-Za-z]*c(?:\s|$)", cmd.strip()):
        return True
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        return False
    segs, cur = [], []
    for t in toks:
        if t in (";", "&&", "||", "|", "&"):
            segs.append(cur); cur = []
        else:
            cur.append(t)
    segs.append(cur)
    segs = [sg for sg in segs if sg]
    if not segs:
        return False
    for sg in segs:
        while sg and re.match(r"[A-Za-z_][A-Za-z0-9_]*=", sg[0]):
            sg = sg[1:]
        if not sg:
            return False
        w = os.path.basename(sg[0])
        if w in SIMPLE:
            continue
        if w == "sed" and any(re.fullmatch(r"-[A-Za-z]*n[A-Za-z]*", t) for t in sg[1:]):
            continue
        return False
    return True
db = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(db_path), uri=True)
row = db.execute("SELECT what, evidence FROM decisions WHERE id = ?", (vid,)).fetchone()
if row is None:
    refuse("pre-gate-error", "no decisions row %s in %s" % (vid, db_path))
what, evidence = row[0] or "", row[1] or ""
if not re.search(r"(?:^|\s)MERGE-OK %s#%s(?:\s|$)" % (re.escape(repo), re.escape(pr)), what):
    refuse("pre-gate-error", "the row's what holds no `MERGE-OK %s#%s`" % (repo, pr))
commits = re.findall(r"(?:^|\s)COMMIT=(\S*)", what)
if len(commits) != 1 or not re.fullmatch(r"[0-9a-fA-F]{40}", commits[0]):
    refuse("head-mismatch", "the row's what must hold exactly one COMMIT=<40 hex> (found %d)" % len(commits))
commit = commits[0].lower()
names = re.findall(r"(?:^|\s)agent=verifier:(?:aide|rb|r7)-verifier-([a-z0-9][a-z0-9-]{0,30})(?=\s|$)", what)
if len(names) != 1:
    refuse("suite-unknown", "the row's what names no single agent=verifier:<agent>-verifier-<name> (no launcher record to read the suite from)")
sdir = os.path.join(state_root, names[0])
try:
    meta = open(os.path.join(sdir, "meta"), encoding="utf-8").read().splitlines()
    raw = open(os.path.join(sdir, "suite.txt"), "rb").read()
except OSError as e:
    refuse("suite-unknown", "%s: %s" % (sdir, e.strerror or e))
want = [ln[len("suite_sha256="):] for ln in meta if ln.startswith("suite_sha256=")]
if len(want) != 1 or want[0] != hashlib.sha256(raw).hexdigest():
    refuse("suite-unknown", "%s/suite.txt sha256 does not equal meta suite_sha256 (or meta has none)" % sdir)
flat = flatten(raw.decode("utf-8"))
atts = mg.parse_attachments(evidence)
for a in atts:
    miss = [k for k in TRAILER if k not in a["trailer"]]
    if miss:
        refuse("trailer-missing", "attached log %s lacks %s in the stored tail" % (a["file"], "/".join(miss)))
gating = [a for a in atts if a["trailer"]["CMD"] == flat]
if not gating:
    refuse("suite-mismatch", "none of %d attached log(s) has CMD == the launcher's suite (suite.txt, flattened)" % len(atts))
if len(gating) > 1:
    refuse("suite-ambiguous", "%d attached logs carry the suite CMD: %s" % (len(gating), ", ".join(a["file"] for a in gating)))
g = gating[0]["trailer"]
if g["HEAD"].lower() != commit:
    refuse("head-mismatch", "the suite log HEAD %s != the verdict COMMIT %s" % (g["HEAD"][:12], commit[:12]))
if g["DIRTY"] != "0":
    refuse("suite-dirty", "the suite log was run on a dirty tree (DIRTY=%s)" % g["DIRTY"])
if g["EXIT"] != "0":
    refuse("suite-red", "the suite log EXIT=%s" % g["EXIT"])
for a in atts:
    if a is not gating[0] and replay(a["trailer"]["CMD"]):
        refuse("replay-log", "attached log %s ran only a replay: CMD=%s" % (a["file"], a["trailer"]["CMD"][:100]))
done("OK " + commit)
PY
)"
if [ -n "${AIDE_VERIFIER_GATE_ROOT:-}" ]; then pg_root="$AIDE_VERIFIER_GATE_ROOT"
else
  pg_w="$(command -v "$WM_DECIDE")" || pg_refuse pre-gate-error "$WM_DECIDE is not on PATH (no gate root to import parse_attachments from)"
  pg_root="$(dirname "$(dirname "$(readlink -f "$pg_w")")")"
fi
PG_ACTIVE=1
pg_out="$(python3 -I -B -c "$PG_PY" "$pg_root" "$PG_DB" "$v" "$repo" "$pr" "$PG_STATE" 2>&1)" \
  || pg_refuse pre-gate-error "helper failed: $(printf '%s\n' "$pg_out" | tail -n1 | cut -c1-200)"
pg_line="$(printf '%s\n' "$pg_out" | tail -n1)"
case "$pg_line" in
  "OK "*) pg_commit="${pg_line#OK }" ;;
  "REFUSE "*) pg_r="${pg_line#REFUSE }"; pg_refuse "${pg_r%% *}" "${pg_r#* }" ;;
  *) pg_refuse pre-gate-error "unexpected helper output: $(printf '%s' "$pg_line" | cut -c1-200)" ;;
esac
PG_ACTIVE=0

pr_meta="$("$GH" pr view "$pr" --repo "$repo" --json title,body)"   # read ONCE, before the gate; set -e: an unreadable PR stops here
gate_out="$("$WM_DECIDE" merge-gate "$v" --pr "$pr" --repo "$repo")"   # set -e: rc 2 ends the script here; stdout is held, stderr streams
oid="$(printf '%s\n' "$gate_out" | sed -n 's/^PASS .* oid=\([0-9a-f]\{40\}\)$/\1/p')"
[ -n "$oid" ] || { echo "rb-merge.sh: the gate returned 0 but printed no full 40-hex oid; refusing to merge" >&2; exit 3; }
[ "$oid" = "$pg_commit" ] || pg_refuse head-mismatch "the gate's oid $oid != the verdict's COMMIT $pg_commit (pre-gate A); no merge"
printf '%s\n' "$gate_out"
if [ "${RB_MERGE_ALLOW_BRANCH_TRAILERS:-}" = 1 ]; then
  echo "rb-merge.sh: RB_MERGE_ALLOW_BRANCH_TRAILERS=1 -- the PRE-merge branch-commit attribution check is SKIPPED" >&2
else
  commits_out="$("$GH" api "repos/$repo/pulls/$pr/commits" --paginate -q '.[] | .sha[0:12] + " " + (.commit.message | test("(?im)^[ \\t]*(co-authored-by:|generated with)") | tostring)')" \
    || { echo "rb-merge.sh: the PR's branch commits could not be read; refusing to merge (ATTRIBUTION-UNCHECKED)" >&2; exit 3; }
  [ -n "$commits_out" ] || { echo "rb-merge.sh: the PR's branch commit list is empty; refusing to merge (ATTRIBUTION-UNCHECKED)" >&2; exit 3; }
  bad_shas="$(printf '%s\n' "$commits_out" | sed -n 's/^\([0-9a-f]\{12\}\) true$/\1/p' | paste -sd' ' -)"
  [ -z "$bad_shas" ] || { echo "ATTRIBUTION-BRANCH $bad_shas" >&2; exit 3; }
fi
ATTR_RE='^[[:space:]]*(co-authored-by:|generated with)'   # LINE-ANCHORED: a trailer line, never a sentence that merely mentions the phrase (PR 19's own message was refused by the unanchored form)
subject="$(printf '%s' "$pr_meta" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["title"].replace("\n"," ").strip())')"
[ -n "$subject" ] || { echo "rb-merge.sh: PR title is empty; refusing to merge" >&2; exit 3; }
body="$(printf '%s' "$pr_meta" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["body"] or "")' | grep -viE "$ATTR_RE" || true)"
WM_DECIDE_GATE_OK="$v" "$GH" pr merge "$pr" --repo "$repo" --squash --match-head-commit "$oid" --subject "$subject" --body "$body" && "$WM_DECIDE" merge-done "$v" --pr "$pr" --repo "$repo" --oid "$oid" || exit $?   # a failed merge (or merge-done) ends here with its own rc: set -e does not trip inside an && list

mc="$("$GH" pr view "$pr" --repo "$repo" --json mergeCommit -q .mergeCommit.oid || true)"
[ -n "$mc" ] || { echo "rb-merge.sh: merged, but the merge commit oid could not be read; attribution NOT verified (ATTRIBUTION-UNCHECKED)" >&2; exit 3; }
msg="$("$GH" api "repos/$repo/commits/$mc" -q .commit.message || true)"
[ -n "$msg" ] || { echo "rb-merge.sh: merged $mc, but its message could not be read; attribution NOT verified (ATTRIBUTION-UNCHECKED $mc)" >&2; exit 3; }
hits="$(printf '%s\n' "$msg" | grep -ciE "$ATTR_RE" || true)"
[ "$hits" = 0 ] || { echo "ATTRIBUTION-LANDED $mc" >&2; exit 3; }
