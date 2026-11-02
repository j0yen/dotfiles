#!/usr/bin/env bash
# Refuse a PR that re-adds a path main deleted after the PR's merge base (P28 mechanism 6).
# Usage: pr-readd-check.sh <repo-dir> <pr-ref> [<main-ref>=origin/main]
# Exit 0 = none, 3 = RE-ADD found, 2 = usage or git error (fails closed).
set -uo pipefail
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: pr-readd-check.sh <repo-dir> <pr-ref> [<main-ref>]" >&2
  exit 2
fi
repo=$1; pr=$2; main=${3:-origin/main}
g() { git -C "$repo" "$@"; }

g rev-parse --git-dir >/dev/null 2>&1 || { echo "error: $repo is not a git repo" >&2; exit 2; }
g rev-parse --verify --quiet "$pr^{commit}" >/dev/null || { echo "error: bad ref $pr" >&2; exit 2; }
g rev-parse --verify --quiet "$main^{commit}" >/dev/null || { echo "error: bad ref $main" >&2; exit 2; }
base=$(g merge-base "$main" "$pr") || { echo "error: no merge base for $main $pr" >&2; exit 2; }

added=$(g diff -z --no-renames --name-only --diff-filter=A "$base" "$pr" | tr '\0' '\n') || { echo "error: git diff failed" >&2; exit 2; }
[ -n "$added" ] || exit 0

# newest-first: first sighting of a path is its latest deleting commit
log=$(g log --no-renames --diff-filter=D --name-only --format='%x01%h %s' "$base..$main") || { echo "error: git log failed" >&2; exit 2; }

declare -A by
cur=
while IFS= read -r line; do
  case $line in
    $'\001'*) cur=${line#$'\001'} ;;
    '') ;;
    *) [ -n "${by[$line]+x}" ] || by[$line]=$cur ;;
  esac
done <<<"$log"

hits=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -n "${by[$p]+x}" ] || continue
  # main deleted then re-added the path: the PR's add is not a re-add
  if g cat-file -e "$main:$p" 2>/dev/null; then continue; fi
  sha=${by[$p]%% *}; subj=${by[$p]#* }
  echo "RE-ADD $p deleted-on-main-by $sha $subj"
  hits=$((hits+1))
done <<<"$added"

[ "$hits" -eq 0 ] && exit 0
exit 3
