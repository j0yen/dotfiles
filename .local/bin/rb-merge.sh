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
# BEFORE the gate and any gh call, the verdict row must carry via=verifier (ctl c246: d-20261029-143838-r7-d24b was recorded agent=r7 with no --via and passed). Else exit 3 VIA-NOT-VERIFIER.
# `via` is caller-supplied at record time (wm-decide sets via = via or agent), so this stops honest-caller mistakes, not a forged --via; real provenance belongs in wm-decide (frozen, out of scope). No bypass env var.
# After the merge the merge commit's message is re-read; a hit prints ATTRIBUTION-LANDED <oid> on stderr and exits 3 (the merge already happened; this makes it loud, it does not revert).
# ADV PRE-CHECK (INTERIM; the real gate is a future G8 in wm_decide, because a hand `gh pr merge` after a merge-gate pass bypasses this script): after the PR is read and BEFORE merge-gate, a PR in
# j0yen/mcphost or j0yen/synthorg (any PR, brief or not), or any PR whose gated row G cites a brief (what/why/evidence), needs an adversarial-pass row for (G, the verdict's COMMIT): the NEWEST
# one decides. Refusals exit 4 (exit 3 stays attribution-only) with ONE stderr line `ADV-<REASON> <G> <owner/name>#<pr>` and gh is never asked to merge: ADV-MISSING, ADV-STALE (other COMMIT),
# ADV-NOT-PASS (newest is FAIL/UNVERIFIED), ADV-NOLOG (the log= file is not a non-empty regular file here), ADV-UNCHECKED (row read failed), ADV-COMMIT-SHORT (V's COMMIT is not a full 40-hex), ADV-STALE-HEAD (the ADV row's COMMIT, or the gate's oid, is not the PR's live headRefOid), ADV-WAIVER-BAD.
# RB_MERGE_ADV_WAIVE=<d-id> skips it only for a controller-authored (agent=controller, via=seat-tick) kind=other row naming this PR with a future until= AND its own `regrade` column = fable-regrader CONFIRM with regrade.ts strictly later than the row's ts (stderr ADV-WAIVED <d-id>; a refusal adds an `ADV-REASON <why>` line).
# A triggered pass reads the PR's headRefOid ONCE (after the ledger read), needs it byte-equal to the ADV row's 40-hex COMMIT, prints `ADV-OK <A-id> <A-ts> <that oid> <owner/name>#<pr>` on stderr before the gate, and the gate's oid must equal it too (the merge pins --match-head-commit to that one value; the oid is pinned at check time, a push after the merge call cannot be seen); an ADV row counts only with ledger via=verifier. Grammar: .local/lib/adv-grammar.sh (the one copy).
# The ledger is read from the sqlite file wm-decide writes ($WM_DECIDE_STATE or ~/.local/state/swarm-decide), mode=ro, no time window, by .local/lib/rb-merge-adv-check.py.
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
#   pre-gate-error    anything else (DB or gate root unreadable, row missing, no canonical merge-verdict prefix for this repo#pr (.local/lib/merge-verdict-grammar.sh), python failure): fail closed, any error in this block exits 6
# The only route around suite-unknown is a hand `gh pr merge` logged as a DECISION row, never a flag here. gh contract (shared with vtg2): `gh pr merge` is never called on a refusal; read-only gh calls are allowed.
# Exit codes: 3 attribution/oid, 6 pre-gate A, 64 usage, else the gate's (2) or gh's own.
set -euo pipefail
usage() { echo "usage: rb-merge.sh <verdict-id> <pr-number> <owner/name> [--handoff <aide d-id>]" >&2; exit 64; }
handoff=""
if [ $# -eq 5 ] && [ "$4" = "--handoff" ]; then handoff="$5"; set -- "$1" "$2" "$3"; fi
[ $# -eq 3 ] || usage
v="$1"; pr="$2"; repo="$3"
case "$pr" in ''|*[!0-9]*) echo "rb-merge.sh: pr must be a number, got '$pr'" >&2; usage ;; esac
case "$repo" in */*) ;; *) echo "rb-merge.sh: repo must be owner/name, got '$repo'" >&2; usage ;; esac
# Every call logs to ~/.cache/rb-seat/merge-logs/ (ctl 10-22 11:28 PM: a merge-done row cites this log).
RB_MERGE_LOG_DIR="${RB_MERGE_LOG_DIR:-$HOME/.cache/rb-seat/merge-logs}"; mkdir -p "$RB_MERGE_LOG_DIR"
LOG="$RB_MERGE_LOG_DIR/rb-merge-${repo//\//_}-$pr-$(date +%Y%m%dT%H%M%S).log"; echo "rb-merge.sh v=$v pr=$pr repo=$repo at $(date -Is)" >"$LOG"
exec > >(tee -a "$LOG"); TEE_OUT=$!
exec 2> >(tee -a "$LOG" >&2); TEE_ERR=$!
# a process substitution is not waited for by the shell: without this, the script can exit while a tee still holds the last lines, and a caller that
# redirects stdout/stderr to a file reads it before they land (a loaded host loses ADV-*/refusal lines nondeterministically). Close our ends, then wait.
trap 'exec >&- 2>&-; wait "$TEE_OUT" "$TEE_ERR" 2>/dev/null' EXIT
WM_DECIDE="${WM_DECIDE_BIN:-wm-decide}"
GH="${RB_MERGE_GH:-gh}"

# DISCOVERY CHAIN GUARD (r7 9:26 PM, ctl 382b, approval 51): r7 merged synthorg #449 from its own seat; r7 verifies and gates, the AIDE runs this script.
# A PR in a CHAIN_REPOS repo merges only with WM_SEAT=aide or ctl, or with --handoff <d-id> naming a wm-decide row (read-only `list --json`) whose agent is aide and whose text names this repo and pr=N / #N.
CHAIN_REPOS=(j0yen/synthorg)   # the ONE place the discovery chain repos are listed (no other dotfiles script keeps this set: hand-pr-land-driver HPLD_REPOS is the wider hand-PR set)
chain_guard() {
  local r in_chain=0
  # normalise ONCE (gh accepts URL / .git / mixed-case spellings of the same repo): lowercase, strip scheme+host prefix, trailing .git and /; anything that is then not plain owner/name is REFUSED outright
  NREPO="$(printf '%s' "$repo" | tr 'A-Z' 'a-z' | sed -e 's#^https\?://github\.com/##' -e 's#^github\.com/##' -e 's#^git@github\.com:##' -e 's#/*$##' -e 's#\.git$##' -e 's#/*$##')"
  if ! printf '%s' "$NREPO" | grep -Eq '^[a-z0-9._-]+/[a-z0-9._-]+$'; then
    echo "rb-merge: REFUSED repo '$repo' is not plain owner/name after normalisation" >&2; exit 3
  fi
  for r in "${CHAIN_REPOS[@]}"; do [ "$r" = "$NREPO" ] && in_chain=1; done
  [ "$in_chain" = 1 ] || return 0
  case "${WM_SEAT:-}" in aide|ctl|ops) return 0 ;; esac
  if [ -n "$handoff" ]; then
    local rows
    if rows="$("$WM_DECIDE" list --since 30d --json 2>/dev/null)" && printf '%s' "$rows" | python3 -I -c '
import json, re, sys
hid, pr, repo = sys.argv[1:4]
for row in json.load(sys.stdin):
    if row.get("id") != hid:
        continue
    if row.get("agent") != "aide":
        break
    text = " ".join(str(v) for v in row.values()).lower()
    # ONE adjacent token names both: <repo>#N or <repo> pr=N (left boundary before the repo, no digit after N)
    if re.search(r"(?<![a-z0-9._-])%s(?:#|\s+pr=)%s(?!\d)" % (re.escape(repo), re.escape(pr)), text):
        sys.exit(0)
    break
sys.exit(1)' "$handoff" "$pr" "$NREPO"; then return 0; fi
  fi
  echo "rb-merge: REFUSED discovery chain PR $repo#$pr needs WM_SEAT=aide or --handoff <aide d-id> (approval 51)" >&2
  exit 3
}
chain_guard

# ---- pre-gate A (see the header): fail closed, ONE exit code (6); the ERR trap covers only this block (PG_ACTIVE) ----
PG_DB="${RB_DECISIONS_DB:-${WM_DECIDE_STATE:-$HOME/.local/state/swarm-decide}/decisions.sqlite}"
PG_STATE="${AIDE_VERIFIER_DIR:-$HOME/.local/state/aide-verifier}"
PG_ACTIVE=0
pg_refuse() { PG_ACTIVE=0; echo "rb-merge.sh: $1 $v: $2" >&2; exit 6; }
trap 'rc=$?; if [ "$PG_ACTIVE" = 1 ]; then echo "rb-merge.sh: pre-gate-error $v: unexpected failure (rc $rc, line $LINENO)" >&2; exit 6; fi' ERR
PG_PY="$(cat <<'PY'
import hashlib, importlib, os, re, shlex, sqlite3, sys, urllib.parse
sys.dont_write_bytecode = True
root, db_path, vid, repo, pr, state_root, libdir = sys.argv[1:8]
sys.path.insert(0, root)
sys.path.insert(0, libdir)
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
mvg = importlib.import_module("merge_verdict_grammar")   # the ONE merge-verdict grammar (.local/lib/merge-verdict-grammar.sh exports its patterns)
why, got = mvg.parse_ex(what)
if why == "prefix":
    refuse("pre-gate-error", "the row's what holds no canonical `<MERGE-OK word> %s#%s COMMIT=<40 hex> agent=verifier:...` prefix: %s" % (repo, pr, got))
if why == "commit":
    refuse("head-mismatch", got)
if why == "agent":
    refuse("suite-unknown", got + " (no launcher record to read the suite from)")
g_owner, g_name, g_pr, commit, agent_tok = got
if "%s/%s" % (g_owner, g_name) != repo or g_pr != pr:
    refuse("pre-gate-error", "the row names %s/%s#%s, not %s#%s" % (g_owner, g_name, g_pr, repo, pr))
names = [agent_tok.split("-verifier-", 1)[1]]
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
mvg_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib"
[ -r "$mvg_lib/merge-verdict-grammar.sh" ] && [ -r "$mvg_lib/merge_verdict_grammar.py" ] || pg_refuse pre-gate-error "the merge-verdict grammar lib is missing under $mvg_lib"
. "$mvg_lib/merge-verdict-grammar.sh"   # exports the MVG_* patterns the pre-gate helper reads
PG_ACTIVE=1
pg_out="$(python3 -I -B -c "$PG_PY" "$pg_root" "$PG_DB" "$v" "$NREPO" "$pr" "$PG_STATE" "$mvg_lib" 2>&1)" \
  || pg_refuse pre-gate-error "helper failed: $(printf '%s\n' "$pg_out" | tail -n1 | cut -c1-200)"
pg_line="$(printf '%s\n' "$pg_out" | tail -n1)"
case "$pg_line" in
  "OK "*) pg_commit="${pg_line#OK }" ;;
  "REFUSE "*) pg_r="${pg_line#REFUSE }"; pg_refuse "${pg_r%% *}" "${pg_r#* }" ;;
  *) pg_refuse pre-gate-error "unexpected helper output: $(printf '%s' "$pg_line" | cut -c1-200)" ;;
esac
PG_ACTIVE=0
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/wmd-row-lib.sh"
wmd_fetch "$WM_DECIDE" || { echo "rb-merge.sh: cannot read the verdict row $v; refusing to merge (VIA-UNCHECKED)" >&2; exit 3; }
row="$(wmd_pick "$v")" || { echo "rb-merge.sh: verdict row $v could not be selected; refusing to merge (VIA-UNCHECKED)" >&2; exit 3; }
via="$(wmd_field "$row" via)"
[ "$via" = verifier ] || { echo "VIA-NOT-VERIFIER verdict=$v via=$via" >&2; exit 3; }
# a row that carries structured repo / pr fields must agree with the target byte-for-byte (tightening; the ledger rows seen so far carry neither)
row_repo="$(wmd_field "$row" repo)"; row_pr="$(wmd_field "$row" pr)"
{ [ -z "$row_repo" ] || [ "$row_repo" = "$repo" ]; } && { [ -z "$row_pr" ] || [ "$row_pr" = "$pr" ]; } || pg_refuse pre-gate-error "the row's structured repo/pr ($row_repo#$row_pr) differ from the target $repo#$pr"

pr_meta="$("$GH" pr view "$pr" --repo "$repo" --json title,body)"   # read ONCE, before the gate; set -e: an unreadable PR stops here
adv_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib"
adv_refuse() { echo "$1 ${2:--} $repo#$pr" >&2; [ -z "${3:-}" ] || echo "ADV-REASON $3" >&2; exit "${ADV_EXIT:-4}"; }   # ADV_EXIT=4 from adv-grammar.sh (not sourced yet when the lib itself is missing)
[ -r "$adv_lib/adv-grammar.sh" ] && [ -r "$adv_lib/rb-merge-adv-check.py" ] || adv_refuse ADV-UNCHECKED -
. "$adv_lib/adv-grammar.sh"
adv_env=(); for adv_v in $(compgen -A variable ADV_); do adv_env+=("$adv_v=${!adv_v}"); done   # every ADV_* variable of the lib reaches the helper: no second list to drift
adv_out="$(env "${adv_env[@]}" python3 -I "$adv_lib/rb-merge-adv-check.py" "${WM_DECIDE_STATE:-$HOME/.local/state/swarm-decide}/decisions.sqlite" "$v" "$NREPO" "$pr" ${RB_MERGE_ADV_WAIVE:+"$RB_MERGE_ADV_WAIVE"} 2>/dev/null)" \
  || adv_out="REFUSE ADV-UNCHECKED -"
case "$adv_out" in
  NOTRIGGER) ;;
  "OK "*) read -r _ adv_g adv_aid adv_ats adv_h <<<"$adv_out"
    adv_head="$("$GH" pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid 2>/dev/null)" || adv_head=""   # the ONE head read, after the ledger read; reused for the compare, the marker and the merge pin
    [[ "$adv_head" =~ ^[0-9a-f]{40}$ ]] || adv_refuse ADV-UNCHECKED "$adv_g"
    [ "$adv_h" = "$adv_head" ] || adv_refuse ADV-STALE-HEAD "$adv_g"   # the ADV row vouches for another tip than the PR head now
    echo "ADV-OK $adv_aid $adv_ats $adv_head $repo#$pr" >&2 ;;   # the merge log can be re-checked against the ledger row
  "WAIVED "*) echo "ADV-WAIVED ${adv_out#WAIVED }" >&2 ;;   # merge-done has no note flag, so the waiver id reaches the terminal/journal only
  "REFUSE "*) read -r _ adv_tok adv_g adv_why <<<"$adv_out"; adv_refuse "$adv_tok" "$adv_g" "${adv_why:-}" ;;
  *) adv_refuse ADV-UNCHECKED - ;;
esac
gate_out="$("$WM_DECIDE" merge-gate "$v" --pr "$pr" --repo "$repo")"   # set -e: rc 2 ends the script here; stdout is held, stderr streams
oid="$(printf '%s\n' "$gate_out" | sed -n 's/^PASS .* oid=\([0-9a-f]\{40\}\)\( .*\)\{0,1\}$/\1/p')"
[ -n "$oid" ] || { echo "rb-merge.sh: the gate returned 0 but printed no full 40-hex oid; refusing to merge" >&2; exit 3; }
[ -z "${adv_head:-}" ] || [ "$oid" = "$adv_head" ] || adv_refuse ADV-STALE-HEAD "${adv_g:--}"   # the gate passed another oid than the ADV-checked head: one value for the check and the merge
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
