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
# ADV PRE-CHECK (INTERIM; the real gate is a future G8 in wm_decide, because a hand `gh pr merge` after a merge-gate pass bypasses this script): after the PR is read and BEFORE merge-gate, a PR in
# j0yen/mcphost or j0yen/synthorg (any PR, brief or not), or any PR whose gated row G cites a brief (what/why/evidence), needs an adversarial-pass row for (G, the verdict's COMMIT): the NEWEST
# one decides. Refusals exit 4 (exit 3 stays attribution-only) with ONE stderr line `ADV-<REASON> <G> <owner/name>#<pr>` and gh is never asked to merge: ADV-MISSING, ADV-STALE (other COMMIT),
# ADV-NOT-PASS (newest is FAIL/UNVERIFIED), ADV-NOLOG (the log= file is not a non-empty regular file here), ADV-UNCHECKED (row read failed), ADV-WAIVER-BAD.
# RB_MERGE_ADV_WAIVE=<d-id> skips it only for a controller-authored (agent=controller, via=seat-tick) kind=other row naming this PR with a future until= AND its own `regrade` column = fable-regrader CONFIRM with graded_at later than the row's ts (stderr ADV-WAIVED <d-id>; a refusal adds an `ADV-REASON <why>` line).
# A triggered pass prints `ADV-OK <A-id> <A-ts> <H> <owner/name>#<pr>` on stderr before the gate; an ADV row counts only with ledger via=verifier. Grammar: .local/lib/adv-grammar.sh (the one copy).
# The ledger is read from the sqlite file wm-decide writes ($WM_DECIDE_STATE or ~/.local/state/swarm-decide), mode=ro, no time window, by .local/lib/rb-merge-adv-check.py.
set -euo pipefail
usage() { echo "usage: rb-merge.sh <verdict-id> <pr-number> <owner/name>" >&2; exit 64; }
[ $# -eq 3 ] || usage
v="$1"; pr="$2"; repo="$3"
case "$pr" in ''|*[!0-9]*) echo "rb-merge.sh: pr must be a number, got '$pr'" >&2; usage ;; esac
case "$repo" in */*) ;; *) echo "rb-merge.sh: repo must be owner/name, got '$repo'" >&2; usage ;; esac
WM_DECIDE="${WM_DECIDE_BIN:-wm-decide}"
GH="${RB_MERGE_GH:-gh}"

pr_meta="$("$GH" pr view "$pr" --repo "$repo" --json title,body)"   # read ONCE, before the gate; set -e: an unreadable PR stops here
adv_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib"
adv_refuse() { echo "$1 ${2:--} $repo#$pr" >&2; [ -z "${3:-}" ] || echo "ADV-REASON $3" >&2; exit "${ADV_EXIT:-4}"; }   # ADV_EXIT=4 from adv-grammar.sh (not sourced yet when the lib itself is missing)
[ -r "$adv_lib/adv-grammar.sh" ] && [ -r "$adv_lib/rb-merge-adv-check.py" ] || adv_refuse ADV-UNCHECKED -
. "$adv_lib/adv-grammar.sh"
adv_env=(); for adv_v in $(compgen -A variable ADV_); do adv_env+=("$adv_v=${!adv_v}"); done   # every ADV_* variable of the lib reaches the helper: no second list to drift
adv_out="$(env "${adv_env[@]}" python3 -I "$adv_lib/rb-merge-adv-check.py" "${WM_DECIDE_STATE:-$HOME/.local/state/swarm-decide}/decisions.sqlite" "$v" "$repo" "$pr" ${RB_MERGE_ADV_WAIVE:+"$RB_MERGE_ADV_WAIVE"} 2>/dev/null)" \
  || adv_out="REFUSE ADV-UNCHECKED -"
case "$adv_out" in
  NOTRIGGER) ;;
  "OK "*) read -r _ adv_g adv_aid adv_ats adv_h <<<"$adv_out"; echo "ADV-OK $adv_aid $adv_ats $adv_h $repo#$pr" >&2 ;;   # the merge log can be re-checked against the ledger row
  "WAIVED "*) echo "ADV-WAIVED ${adv_out#WAIVED }" >&2 ;;   # merge-done has no note flag, so the waiver id reaches the terminal/journal only
  "REFUSE "*) read -r _ adv_tok adv_g adv_why <<<"$adv_out"; adv_refuse "$adv_tok" "$adv_g" "${adv_why:-}" ;;
  *) adv_refuse ADV-UNCHECKED - ;;
esac
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
