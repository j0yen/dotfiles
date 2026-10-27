#!/usr/bin/env bash
# aide-lanes step 6: aide-claim-gate.sh (PreToolUse Bash) + aide-claim.sh. Temp FLEET_DASH_DIR + HOME; the live claims/ is never touched.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"; G="$R/.claude/hooks/aide-claim-gate.sh"; C="$R/.local/bin/aide-claim.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
export HOME="$T/home" FLEET_DASH_DIR="$T/fd"; mkdir -p "$HOME"; CL="$FLEET_DASH_DIR/claims"
unset WM_AIDE_LANE CLAUDE_SESSION_ID
gate() { # <cmd> ; env passed via G_ENV words
  jq -nc --arg c "$1" --arg d "$T/home" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:"sid-test-0001"}' | env $G_ENV bash "$G" >"$T/out" 2>"$T/err"; rc=$?; }
claim() { mkdir -p "$CL"; printf 'lane=%s\nsid=sid-holder\nexpires=%s\n' "$2" "$3" >"$CL/$1"; }
FUT=$(( $(date +%s) + 3600 )); PAST=$(( $(date +%s) - 60 ))
B="WM_SEAT=aide WM_AIDE_LANE=build"
G_ENV="$B"; rm -rf "$CL"; claim 'dotfiles#127' main $FUT
gate 'gh pr merge 127 --repo j0yen/dotfiles --squash'
[ $rc = 2 ] && grep -q 'aide-claim-gate: dotfiles#127 claimed by lane main (sid sid-holder, expires ' "$T/err" && grep -q 'aide-claim.sh show dotfiles#127' "$T/err" && ok "held by main + lane build: gh pr merge denied rc 2, holder named" || bad "foreign claim rc=$rc: $(cat "$T/err")"
claim 'dotfiles#127' main $PAST; gate 'gh pr merge 127 --repo j0yen/dotfiles'
[ $rc = 0 ] && grep -q '^lane=build$' "$CL/dotfiles#127" && ok "expired foreign claim: rc 0, taken by build" || bad "expired rc=$rc"
claim 'dotfiles#127' build $FUT; before="$(cat "$CL/dotfiles#127")"; gate 'gh pr merge 127 --repo j0yen/dotfiles'
[ $rc = 0 ] && [ "$(cat "$CL/dotfiles#127")" = "$before" ] && ok "own-lane claim: rc 0, claim untouched" || bad "own rc=$rc"
G_ENV=""; claim 'dotfiles#127' main $FUT; gate 'gh pr merge 127 --repo j0yen/dotfiles'
[ $rc = 0 ] && [ ! -s "$T/out" ] && [ ! -s "$T/err" ] && ok "WM_SEAT unset: rc 0, no output" || bad "unset rc=$rc"
G_ENV="WM_SEAT=rb WM_AIDE_LANE=build"; gate 'gh pr merge 127 --repo j0yen/dotfiles'; [ $rc = 0 ] && ok "WM_SEAT=rb: rc 0" || bad "rb rc=$rc"
G_ENV="$B"
claim 'dotfiles#127' main $FUT
gate 'aide-verifier.sh launch x --repo j0yen/dotfiles --pr 127 --head 0000000000000000000000000000000000000000'; [ $rc = 2 ] && ok "aide-verifier.sh launch under a foreign claim: rc 2" || bad "verifier launch rc=$rc"
gate '/home/jsy/.local/bin/aide-verifier.sh finish x --pr 127 --repo j0yen/dotfiles'; [ $rc = 2 ] && ok "aide-verifier.sh finish (full path): rc 2" || bad "verifier finish rc=$rc"
gate 'wm-decide merge-gate PASS --pr 127 --repo j0yen/dotfiles'; [ $rc = 2 ] && ok "wm-decide merge-gate under a foreign claim: rc 2" || bad "merge-gate rc=$rc"
gate 'wm-decide promote v1 --pr 127 --repo j0yen/dotfiles'; [ $rc = 2 ] && ok "wm-decide promote: rc 2" || bad "promote rc=$rc"
gate 'gh api -X PUT repos/j0yen/dotfiles/pulls/127/merge'; [ $rc = 2 ] && ok "gh api -X PUT .../pulls/127/merge under a foreign claim: rc 2" || bad "gh api merge rc=$rc"
gate 'gh api repos/j0yen/dotfiles/pulls/127/reviews -f event=APPROVE'; [ $rc = 2 ] && ok "gh api .../reviews: rc 2" || bad "gh api reviews rc=$rc"
gate 'gh pr ready 127 -R j0yen/dotfiles'; [ $rc = 2 ] && ok "gh pr ready -R: rc 2" || bad "ready rc=$rc"
gate 'gh pr review 127 --approve --repo j0yen/dotfiles'; [ $rc = 2 ] && ok "gh pr review: rc 2" || bad "review rc=$rc"
gate 'gh pr edit 127 --repo j0yen/dotfiles --title x'; [ $rc = 2 ] && ok "gh pr edit: rc 2" || bad "edit rc=$rc"
gate 'gh pr close https://github.com/j0yen/dotfiles/pull/127'; [ $rc = 2 ] && ok "gh pr close <url>: rc 2" || bad "close url rc=$rc"
gate 'rb-merge.sh d-20261027-010101-aide-abcd 127 j0yen/dotfiles'; [ $rc = 2 ] && ok "rb-merge.sh <v> <pr> <O/R>: rc 2" || bad "rb-merge rc=$rc"
gate 'echo hi && gh pr merge 127 --repo j0yen/dotfiles'; [ $rc = 2 ] && ok "chained after && : rc 2" || bad "chain rc=$rc"
gate 'gh pr merge 128 --repo j0yen/dotfiles && gh pr merge 127 --repo j0yen/dotfiles'; [ $rc = 2 ] && [ ! -e "$CL/dotfiles#128" ] && ok "one foreign object denies the whole command and takes nothing" || bad "multi rc=$rc"
gate 'gh pr view 127 --repo j0yen/dotfiles'; [ $rc = 0 ] && ok "gh pr view is not an act: rc 0" || bad "view rc=$rc"
# claim-on-act
rm -rf "$CL"; gate 'gh pr merge 127 --repo j0yen/dotfiles'
exp="$(sed -n 's/^expires=//p' "$CL/dotfiles#127" 2>/dev/null)"; now=$(date +%s)
[ $rc = 0 ] && grep -q '^lane=build$' "$CL/dotfiles#127" && grep -q '^sid=sid-test-0001$' "$CL/dotfiles#127" && [ "${exp:-0}" -ge $((now + 7190)) ] && [ "${exp:-0}" -le $((now + 7210)) ] && ok "no claim: rc 0 and claims/dotfiles#127 names lane build, expires ~ now + 2 h" || bad "claim-on-act rc=$rc exp=$exp"
G_ENV="WM_SEAT=aide"; rm -rf "$CL"; gate 'gh pr merge 5 --repo j0yen/dotfiles'
grep -q '^lane=main$' "$CL/dotfiles#5" && ok "WM_AIDE_LANE unset: claim names main" || bad "main claim"
G_ENV="$B"; rm -rf "$CL"; gate 'git push origin aide-lanes'; [ $rc = 0 ] && [ ! -e "$CL" ] && ok "git push: rc 0, no claim written (not an object)" || bad "git push rc=$rc"
gate 'gh pr merge 9 --repo j0yen/dotfiles ; echo "unterminated'; [ $rc = 0 ] && ok "unparsable quoting fails open" || bad "quote rc=$rc"
rm -rf "$CL"; gate 'rb-land-push.sh --confirm d-1 --repo /mnt/data/wt/foo --branch wm-build/foo'; [ $rc = 0 ] && [ -e "$CL/foo#wm-build_foo" ] && ok "rb-land-push.sh: object <dir>#<branch>" || bad "land-push rc=$rc: $(ls "$CL" 2>/dev/null)"
# aide-claim.sh
rm -rf "$CL"
env WM_AIDE_LANE=main bash "$C" take 'dotfiles#999999' >/dev/null; [ $? = 0 ] && [ "$(sed -n 's/^lane=//p' "$CL/dotfiles#999999")" = main ] && ok "aide-claim take (main): file written" || bad "take"
env WM_AIDE_LANE=build bash "$C" take 'dotfiles#999999' >/dev/null 2>"$T/err"; rc=$?; [ $rc = 3 ] && grep -q 'claimed by lane main' "$T/err" && ok "take on a live foreign claim: exit 3 naming it" || bad "take foreign rc=$rc"
env WM_AIDE_LANE=build bash "$C" release 'dotfiles#999999' >/dev/null 2>&1; [ $? = 3 ] && [ -e "$CL/dotfiles#999999" ] && ok "release of a foreign live claim: exit 3, file kept" || bad "release foreign"
env WM_AIDE_LANE=main CLAUDE_SESSION_ID=abc bash "$C" take 'dotfiles#999999' --ttl 30m >/dev/null; e="$(sed -n 's/^expires=//p' "$CL/dotfiles#999999")"; n=$(date +%s)
[ "$e" -ge $((n + 1790)) ] && [ "$e" -le $((n + 1810)) ] && grep -q '^sid=abc$' "$CL/dotfiles#999999" && ok "own take overwrites, --ttl 30m, sid recorded" || bad "ttl"
env WM_AIDE_LANE=main bash "$C" show 'dotfiles#999999' | grep -q '^live$' && ok "show prints the claim and live" || bad "show"
claim 'dotfiles#7' main $PAST; env WM_AIDE_LANE=build bash "$C" take 'dotfiles#7' >/dev/null; [ "$(sed -n 's/^lane=//p' "$CL/dotfiles#7")" = build ] && ok "take over an expired claim" || bad "take expired"
env WM_AIDE_LANE=build bash "$C" release 'dotfiles#7' >/dev/null; [ ! -e "$CL/dotfiles#7" ] && ok "release own claim" || bad "release"
env bash "$C" show 'dotfiles#7' >/dev/null; [ $? = 1 ] && ok "show with no claim: exit 1" || bad "show none"
env bash "$C" take 'bad object' >/dev/null 2>&1; [ $? = 64 ] && ok "bad object: exit 64" || bad "bad obj"
env WM_AIDE_LANE=build bash "$C" take 'task:docs' >/dev/null && [ -e "$CL/task:docs" ] && ok "task:<slug> object accepted" || bad "task obj"
exit $fail
