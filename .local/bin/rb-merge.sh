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
set -euo pipefail
usage() { echo "usage: rb-merge.sh <verdict-id> <pr-number> <owner/name> [--handoff <aide d-id>]" >&2; exit 64; }
handoff=""
if [ $# -eq 5 ] && [ "$4" = "--handoff" ]; then handoff="$5"; set -- "$1" "$2" "$3"; fi
[ $# -eq 3 ] || usage
v="$1"; pr="$2"; repo="$3"
case "$pr" in ''|*[!0-9]*) echo "rb-merge.sh: pr must be a number, got '$pr'" >&2; usage ;; esac
case "$repo" in */*) ;; *) echo "rb-merge.sh: repo must be owner/name, got '$repo'" >&2; usage ;; esac
WM_DECIDE="${WM_DECIDE_BIN:-wm-decide}"
GH="${RB_MERGE_GH:-gh}"

# DISCOVERY CHAIN GUARD (r7 9:26 PM, ctl 382b, approval 51): r7 merged synthorg #449 from its own seat; r7 verifies and gates, the AIDE runs this script.
# A PR in a CHAIN_REPOS repo merges only with WM_SEAT=aide, or with --handoff <d-id> naming a wm-decide row (read-only `list --json`) whose agent is aide and whose text names this repo and pr=N / #N.
CHAIN_REPOS=(j0yen/synthorg)   # the ONE place the discovery chain repos are listed (no other dotfiles script keeps this set: hand-pr-land-driver HPLD_REPOS is the wider hand-PR set)
chain_guard() {
  local r in_chain=0 nrepo
  # normalise ONCE (gh accepts URL / .git / mixed-case spellings of the same repo): lowercase, strip scheme+host prefix, trailing .git and /; anything that is then not plain owner/name is REFUSED outright
  nrepo="$(printf '%s' "$repo" | tr 'A-Z' 'a-z' | sed -e 's#^https\?://github\.com/##' -e 's#^github\.com/##' -e 's#^git@github\.com:##' -e 's#/*$##' -e 's#\.git$##' -e 's#/*$##')"
  if ! printf '%s' "$nrepo" | grep -Eq '^[a-z0-9._-]+/[a-z0-9._-]+$'; then
    echo "rb-merge: REFUSED repo '$repo' is not plain owner/name after normalisation" >&2; exit 3
  fi
  for r in "${CHAIN_REPOS[@]}"; do [ "$r" = "$nrepo" ] && in_chain=1; done
  [ "$in_chain" = 1 ] || return 0
  [ "${WM_SEAT:-}" = aide ] && return 0
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
sys.exit(1)' "$handoff" "$pr" "$nrepo"; then return 0; fi
  fi
  echo "rb-merge: REFUSED discovery chain PR $repo#$pr needs WM_SEAT=aide or --handoff <aide d-id> (approval 51)" >&2
  exit 3
}
chain_guard

pr_meta="$("$GH" pr view "$pr" --repo "$repo" --json title,body)"   # read ONCE, before the gate; set -e: an unreadable PR stops here
gate_out="$("$WM_DECIDE" merge-gate "$v" --pr "$pr" --repo "$repo")"   # set -e: rc 2 ends the script here; stdout is held, stderr streams
oid="$(printf '%s\n' "$gate_out" | sed -n 's/^PASS .* oid=\([0-9a-f]\{40\}\)$/\1/p')"
[ -n "$oid" ] || { echo "rb-merge.sh: the gate returned 0 but printed no full 40-hex oid; refusing to merge" >&2; exit 3; }
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
