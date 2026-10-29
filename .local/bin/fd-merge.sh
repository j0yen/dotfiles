#!/usr/bin/env bash
# fd-merge.sh <verdict-row-id> <branch> -- the ONLY way a seat lands a fleet-dash branch on the remote main (fleet-dash has no PR and no merge gate). Runs on carbon.
# Refuses (exit 3, one line `FD-MERGE REFUSED: <reason>`, no git write, no wm-decide write) unless ALL hold:
#   1. the verdict row: kind=verdict, via=verifier, first token of `what` = CONFIRM, exactly one COMMIT=<40 hex> token in `what`
#   2. the gated row (the verdict's `gates` id): kind=other, `what` starts `GATED fleet-dash `, same COMMIT
#   3. the two rows' `session` values are non-empty and differ
#   4. `git fetch` of the remote works, remote/<branch> == COMMIT exactly, and remote/main == local HEAD (a remote main that moved ahead refuses, so local main is never advanced without the remote)
#   5. the repo is on main, the worktree is clean, and HEAD is an ancestor of COMMIT (fast-forward)
# Then, stopping on the first failure (exit 4, naming the step): (a) merge --ff-only COMMIT, (b) land HEAD on the remote main (no force flag), (c) record `MERGED fleet-dash <branch> COMMIT=<sha> verdict=<id>`.
# If (c) fails after (b), the full MERGED line goes to stderr so it can be recorded by hand. Success prints `FD-MERGED <branch> <sha> verdict=<id>`.
# `via` is caller-supplied at record time (wm-decide sets via = via or agent), so this check stops honest-caller mistakes like d24b (recorded agent=r7, no --via); real provenance belongs in wm-decide (frozen, out of scope).
# Env (tests): WM_DECIDE_BIN, FD_MERGE_REPO (default $HOME/wintermute/fleet-dash), FD_MERGE_REMOTE (default orch).
set -uo pipefail
usage() { echo "usage: fd-merge.sh <verdict-row-id> <branch>" >&2; exit 64; }
[ $# -eq 2 ] || usage
v="$1"; branch="$2"
case "$branch" in ''|-*|*[!A-Za-z0-9._/-]*) echo "fd-merge.sh: branch must be a plain ref name, got '$branch'" >&2; usage ;; esac
WM_DECIDE="${WM_DECIDE_BIN:-wm-decide}"
REPO="${FD_MERGE_REPO:-$HOME/wintermute/fleet-dash}"
REMOTE="${FD_MERGE_REMOTE:-orch}"
refuse() { echo "FD-MERGE REFUSED: $1" >&2; exit 3; }
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/wmd-row-lib.sh"

wmd_fetch "$WM_DECIDE" 2>/dev/null || refuse "wm-decide list --json failed or is not a JSON list"
vrow="$(wmd_pick "$v" 2>/dev/null)" || refuse "verdict row $v is absent or not unique"
gid="$(wmd_field "$vrow" gates)"
[ -n "$gid" ] || refuse "verdict row $v gates no row"
grow="$(wmd_pick "$gid" 2>/dev/null)" || refuse "gated row $gid is absent or not unique"

# rows -> COMMIT (stdout) or a refusal reason (stderr, rc 3)
commit="$(python3 -I -c 'import json,re,sys
v, g = json.loads(sys.argv[1]), json.loads(sys.argv[2])
def bad(m):
    sys.stderr.write(m); sys.exit(3)
rx = re.compile(r"(?:^|\s)COMMIT=([0-9a-f]{40})(?=\s|$)")
def commits(w):
    return [m.group(1) for m in rx.finditer(w)]
vw, gw = v.get("what") or "", g.get("what") or ""
if v.get("kind") != "verdict": bad("row %s kind is %r, not verdict" % (v.get("id"), v.get("kind")))
if v.get("via") != "verifier": bad("row %s via=%r, not verifier" % (v.get("id"), v.get("via")))
if (vw.split() or [""])[0] != "CONFIRM": bad("row %s verdict word is not CONFIRM" % v.get("id"))
vc = commits(vw)
if len(vc) != 1: bad("row %s needs exactly one full 40-hex COMMIT=, found %d" % (v.get("id"), len(vc)))
if g.get("kind") != "other": bad("gated row %s kind is %r, not other" % (g.get("id"), g.get("kind")))
if not gw.startswith("GATED fleet-dash "): bad("gated row %s is not a GATED fleet-dash row" % g.get("id"))
gc = commits(gw)
if gc != vc: bad("gated COMMIT differs from the verdict COMMIT")
vs, gs = v.get("session") or "", g.get("session") or ""
if not vs or not gs: bad("a row session is empty")
if vs == gs: bad("verdict and gated rows share one session (not a separate verifier)")
print(vc[0])' "$vrow" "$grow" 2>"${TMPDIR:-/tmp}/fd-merge.$$.err")" ; rc=$?
if [ $rc -ne 0 ]; then reason="$(head -n1 "${TMPDIR:-/tmp}/fd-merge.$$.err")"; rm -f "${TMPDIR:-/tmp}/fd-merge.$$.err"; refuse "${reason:-row check failed}"; fi
rm -f "${TMPDIR:-/tmp}/fd-merge.$$.err"

git -C "$REPO" fetch -q "$REMOTE" >/dev/null 2>&1 || refuse "git fetch $REMOTE failed"
bhead="$(git -C "$REPO" rev-parse --verify -q "refs/remotes/$REMOTE/$branch^{commit}")" || refuse "$REMOTE/$branch not found"
[ "$bhead" = "$commit" ] || refuse "$REMOTE/$branch is $bhead, not the verdict COMMIT $commit"
head="$(git -C "$REPO" rev-parse --verify -q HEAD)" || refuse "no HEAD in $REPO"
rmain="$(git -C "$REPO" rev-parse --verify -q "refs/remotes/$REMOTE/main^{commit}")" || refuse "$REMOTE/main not found"
[ "$rmain" = "$head" ] || refuse "$REMOTE/main ($rmain) is not local HEAD ($head)"
[ "$(git -C "$REPO" symbolic-ref -q --short HEAD)" = main ] || refuse "repo is not on main"
[ -z "$(git -C "$REPO" status --porcelain)" ] || refuse "worktree is not clean"
git -C "$REPO" merge-base --is-ancestor "$head" "$commit" || refuse "COMMIT is not a fast-forward of HEAD"

git -C "$REPO" merge --ff-only -q "$commit" >/dev/null 2>&1 || { echo "FD-MERGE FAILED: step merge" >&2; exit 4; }
git -C "$REPO" push -q "$REMOTE" HEAD:main >/dev/null 2>&1 || { echo "FD-MERGE FAILED: step push (local main is already at $commit)" >&2; exit 4; }
line="MERGED fleet-dash $branch COMMIT=$commit verdict=$v"
"$WM_DECIDE" record --agent "${WM_SEAT:-aide}" --kind other --target carbon --what "$line" --why "fd-merge.sh" --evidence "$v $gid" \
  --reverse-text "git revert the fleet-dash main tip $commit and land the revert via fd-merge.sh" >/dev/null 2>&1 \
  || { echo "FD-MERGE FAILED: step record (the push to $REMOTE/main succeeded); record by hand:" >&2; echo "$line" >&2; exit 4; }
echo "FD-MERGED $branch $commit verdict=$v"
