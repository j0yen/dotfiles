#!/usr/bin/env bash
# verifier-record.sh --pr <owner/name#N> --suite <wm-verify-run log> --agent <agent> --name <unit-name> [--note TEXT] [-- <extra wm-decide record args>]
# The ONE writer of a merge-verdict row (grammar: .local/lib/merge-verdict-grammar.sh). A merge verdict is recorded only through this script, never as a hand-composed MERGE-OK line.
# COMMIT is the `WM-VERIFY HEAD=<40 hex>` trailer of the log the verifier ran (--suite: the wm-verify-run log / bundle.log that carries the HEAD/CMD/DIRTY/EXIT trailers;
# the launcher's suite.txt holds only the command, no head), never a fresh `gh` headRefOid read at record time: a branch update between suite and record must not name an unverified head.
# owner/name comes from gh (the PR's BASE repo url). No --suite, or a log without the trailer: the row is written as free text starting CONFIRM and the script prints
# `NOT-MERGE-GRADE: no suite head` (rb-merge.sh pre-gate A refuses it). Env: WM_DECIDE_BIN, VERIFIER_RECORD_GH. Exit: 0 recorded (stdout carries the wm-decide output), 64 usage, 2 a refusal.
set -euo pipefail
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
. "$here/../lib/merge-verdict-grammar.sh"
WM_DECIDE="${WM_DECIDE_BIN:-wm-decide}"; GH="${VERIFIER_RECORD_GH:-gh}"
usage() { echo "usage: verifier-record.sh --pr <owner/name#N> [--suite <wm-verify-run log>] --agent <agent> --name <unit-name> [--note TEXT] [-- <wm-decide record args>]" >&2; exit 64; }
pr_ref="" suite="" agent="" name="" note="" extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || usage; pr_ref="$2"; shift 2 ;;
    --suite) [ $# -ge 2 ] || usage; suite="$2"; shift 2 ;;
    --agent) [ $# -ge 2 ] || usage; agent="$2"; shift 2 ;;
    --name) [ $# -ge 2 ] || usage; name="$2"; shift 2 ;;
    --note) [ $# -ge 2 ] || usage; note="$2"; shift 2 ;;
    --) shift; extra=("$@"); break ;;
    *) usage ;;
  esac
done
[[ "$pr_ref" =~ ^([^#]+)#([0-9]+)$ ]] || usage
repo_given="${BASH_REMATCH[1]}"; pr="${BASH_REMATCH[2]}"
[ -n "$agent" ] && [ -n "$name" ] || usage
head=""
if [ -n "$suite" ] && [ -r "$suite" ]; then
  head="$(sed -n 's/^WM-VERIFY HEAD=\([0-9a-f]\{40\}\)$/\1/p' "$suite" | tail -n 1)"
fi
if [ -z "$head" ]; then
  echo "NOT-MERGE-GRADE: no suite head" >&2
  what="CONFIRM $repo_given#$pr (no suite head: not merge-grade)${note:+ $note}"
else
  url="$("$GH" pr view "$pr" --repo "$repo_given" --json url -q .url)" || { echo "verifier-record.sh: cannot read the PR's base repo from gh" >&2; exit 2; }
  [[ "$url" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/$pr$ ]] || { echo "verifier-record.sh: unexpected PR url '$url'" >&2; exit 2; }
  repo="${BASH_REMATCH[1]}"
  prefix="$(mvg_format "$repo" "$pr" "$head" "$agent-verifier-$name")" || exit 2
  what="$prefix${note:+ $note}"
fi
"$WM_DECIDE" record --agent "$agent" --via verifier --kind verdict --what "$what" ${extra[@]+"${extra[@]}"}
