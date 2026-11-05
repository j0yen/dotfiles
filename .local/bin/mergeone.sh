#!/usr/bin/env bash
# mergeone.sh <repo> <n> : #194 merge-all drain. OPEN + MERGEABLE + no red check + changed .sh pass bash -n + .py compile -> squash merge pinned to head; refuses a PR that re-adds a path deleted on main after its merge base (exit 8).
set -uo pipefail
repo=$1 n=$2 vid=${3:-}; R=j0yen/$repo
# VID-REQUIRED (11-03 8:4x AM, Fable CORRECT on 8304: arg 3 was optional, so a call without it merged ungated): no verdict id = no merge.
[ -n "$vid" ] || { echo "$repo#$n SKIP: verdict id (arg 3) is required; no ungated merge" >&2; exit 8; }
# k1051 (ctl 11-03 7:10 AM): with a verdict id as $3 the shim gate runs first and writes the gate-pass event; after gh merge rc 0, merge-done writes pr-merged. No vid = the #194 drain path (audit-merges lists it unaudited).
j=$(gh pr view "$n" -R "$R" --json state,mergeable,headRefOid,isDraft,statusCheckRollup,files 2>/dev/null) || { echo "$repo#$n SKIP view-failed"; exit 3; }
st=$(jq -r .state <<<"$j"); mg=$(jq -r .mergeable <<<"$j"); sha=$(jq -r .headRefOid <<<"$j"); dr=$(jq -r .isDraft <<<"$j")
red=$(jq -r '[.statusCheckRollup[]?|(.conclusion//.state)|select(.=="FAILURE" or .=="ERROR" or .=="CANCELLED" or .=="TIMED_OUT")]|length' <<<"$j")
[ "$st" = OPEN ] || { echo "$repo#$n SKIP state=$st"; exit 0; }
[ "$mg" = MERGEABLE ] || [ "$mg" = UNKNOWN ] || { echo "$repo#$n SKIP mergeable=$mg"; exit 4; }
[ "$red" = 0 ] || { echo "$repo#$n SKIP red=$red"; exit 5; }
tmp=$(mktemp -d); bad=""
for f in $(jq -r '.files[]?.path' <<<"$j"); do
  case "$f" in *.sh|*.py) ;; *) continue;; esac
  gh api "repos/$R/contents/$f?ref=$sha" -H 'Accept: application/vnd.github.raw' > "$tmp/x" 2>/dev/null || continue   # deleted file
  case "$f" in
    *.sh) if head -1 "$tmp/x" | grep -q python; then python3 -I -c 'import sys,ast;ast.parse(open(sys.argv[1]).read())' "$tmp/x" 2>/dev/null || bad="$bad $f"; elif ! bash -n "$tmp/x" 2>/dev/null; then gh api "repos/$R/contents/$f?ref=main" -H 'Accept: application/vnd.github.raw' > "$tmp/m" 2>/dev/null && ! bash -n "$tmp/m" 2>/dev/null || bad="$bad $f"; fi;;   # polyglot files fail bash -n on main too: not a regression
    *.py) python3 -I -c 'import sys,ast;ast.parse(open(sys.argv[1]).read())' "$tmp/x" 2>/dev/null || bad="$bad $f";;
  esac
done; rm -rf "$tmp"
[ -z "$bad" ] || { echo "$repo#$n SKIP syntax:$bad"; exit 6; }
# Re-add check (P28 five-whys 11-01, A318): a PR that ADDS a path deleted on main after the PR's merge base is refused (dotfiles#131 re-added the voided 60-quota-stretch drop-ins 24 min after #181 deleted them).
if cmp=$(gh api "repos/$R/compare/main...$sha" 2>/dev/null) && mb=$(jq -r '.merge_base_commit.sha // empty' <<<"$cmp") && [ -n "$mb" ]; then
  added=$(jq -r '.files[]?|select(.status=="added")|.filename' <<<"$cmp" | sort -u)
  if [ -n "$added" ]; then
    removed=$(gh api "repos/$R/compare/$mb...main" --jq '.files[]?|select(.status=="removed")|.filename' 2>/dev/null | sort -u)
    readd=$(comm -12 <(printf '%s\n' "$added") <(printf '%s\n' "$removed") | tr '\n' ' ')
    [ -z "${readd// }" ] || { echo "$repo#$n SKIP re-add:$readd(deleted on main after merge base ${mb:0:8}; rebase by hand)"; exit 8; }
  fi
fi
[ "$dr" = true ] && gh pr ready "$n" -R "$R" >/dev/null 2>&1
if [ -n "$vid" ]; then
  if ! WM_SEAT=aide wm-decide merge-gate "$vid" --pr "$n" --repo "$R" > "${MERGEONE_GATE_OUT:-/dev/null}" 2>&1; then echo "$repo#$n SKIP merge-gate rc!=0 (verdict $vid; fails in ${MERGEONE_GATE_OUT:-/dev/null})"; exit 9; fi
fi
# trailer strip (11-03 7:5x AM): GitHub's default squash body carries branch co-author lines (#285 a4bd4fc1 landed one on main); pass subject+body with attribution lines removed, as rb-merge.sh does.
ATTR_RE='^[[:space:]]*(co-authored-by:|generated with)'
title=$(gh pr view "$n" -R "$R" --json title -q .title); body=$(gh pr view "$n" -R "$R" --json body -q .body | grep -viE "$ATTR_RE" || true)
if out=$(gh pr merge "$n" -R "$R" --squash --match-head-commit "$sha" --subject "$title (#$n)" --body "$body" 2>&1); then echo "$repo#$n MERGED head=${sha:0:8}"; [ -z "$vid" ] || WM_SEAT=aide wm-decide merge-done "$vid" --pr "$n" --repo "$R" --oid "$sha" 2>&1 | tail -1; else echo "$repo#$n FAIL ${out:0:160}"; exit 7; fi
