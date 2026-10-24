#!/usr/bin/env bash
# tests/land-push-gate.test.sh -- .claude/hooks/land-push-gate.sh: an rb-marked process (WM_SEAT=rb|rb-coder or RB_CODER_ID set) may not `git push` to a wm-build/* run branch
# except through rb-land-push.sh; hand branches pass; an unparseable push target is refused (fail closed); every other session passes untouched.
# Plain bash, run from the repo root:  bash tests/land-push-gate.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${LAND_PUSH_GATE_UNDER_TEST:-$here/.claude/hooks/land-push-gate.sh}"   # a mutation proof points this at a throwaway copy
fail=0; n=0
payload() { jq -n --arg c "$1" --arg t "${2:-Bash}" '{tool_name:$t,tool_input:{command:$c}}'; }
# t <name> <want: pass|block|unparsed> <command> [VAR=val ...]   (env is cleared of the markers, then the given ones set)
t() {
  local name=$1 want=$2 cmd=$3; shift 3; n=$((n+1))
  local err rc; err=$(payload "$cmd" | env -u WM_SEAT -u RB_CODER_ID "$@" bash "$hook" 2>&1 >/dev/null); rc=$?
  case "$want" in
    pass) [ $rc = 0 ] && [ -z "$err" ] && echo "ok - $name" || { echo "NOT OK - $name: rc=$rc $err"; fail=1; } ;;
    block) [ $rc = 2 ] && [[ "$err" == *"rb-land-push.sh"* ]] && [[ "$err" != *"unparsed push target"* ]] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && echo "ok - $name" || { echo "NOT OK - $name: rc=$rc $err"; fail=1; } ;;
    unparsed) [ $rc = 2 ] && [[ "$err" == *"unparsed push target"* ]] && echo "ok - $name" || { echo "NOT OK - $name: rc=$rc $err"; fail=1; } ;;
  esac
}
RB=WM_SEAT=rb
R='git push origin HEAD:refs/heads/wm-build/some-slug'
t "bare push to a wm-build run branch from WM_SEAT=rb is refused" block "$R" $RB
t "the same push from an unmarked session passes" pass "$R"
t "the same push from another seat (WM_SEAT=r7) passes" pass "$R" WM_SEAT=r7
t "RB_CODER_ID marks a coder (WM_SEAT unset): refused" block "$R" RB_CODER_ID=rlp1
t "WM_SEAT=rb-coder: refused" block "$R" WM_SEAT=rb-coder
t "a hand branch ci/split-contracts-core passes from rb" pass "git push origin HEAD:refs/heads/ci/split-contracts-core" $RB
t "the PR branch rb/land-push-wrapper passes from rb" pass "git push -u origin rb/land-push-wrapper" $RB
t "rb-land-push.sh passes (bare name)" pass "rb-land-push.sh --confirm d-20261024-100000-controller-abcd --repo /x --branch wm-build/some-slug" $RB
t "rb-land-push.sh passes (full path)" pass "/home/jsy/.local/bin/rb-land-push.sh --confirm d-20261024-100000-controller-abcd --repo /x --branch wm-build/some-slug" $RB
t "git -C <dir> push to wm-build/ is refused" block "git -C /tmp/wt push origin HEAD:refs/heads/wm-build/some-slug" $RB
t "short refspec <branch> (no refs/heads/) is refused" block "git push origin wm-build/some-slug" $RB
t "a + forced refspec is refused" block "git push origin +HEAD:wm-build/some-slug" $RB
t "--force-with-lease to wm-build is refused" block "git push --force-with-lease origin HEAD:refs/heads/wm-build/some-slug" $RB
t "a chained cd && git push is refused" block "cd /tmp/wt && git push origin HEAD:refs/heads/wm-build/some-slug" $RB
t "bash -c '...git push...' is unwrapped and refused" block "bash -c 'git push origin HEAD:refs/heads/wm-build/some-slug'" $RB
t "a wm-build/train/N branch is refused" block "git push origin HEAD:refs/heads/wm-build/train/57" $RB
t "a bare 'git push' (destination unknown) is refused" unparsed "git push" $RB
t "'git push origin' with no refspec is refused" unparsed "git push origin" $RB
t "'git push origin HEAD' is refused (current-branch destination)" unparsed "git push origin HEAD" $RB
t "--all is refused" unparsed "git push --all origin" $RB
t "a \$VAR refspec is refused" unparsed 'git push origin HEAD:refs/heads/$BR' $RB
t "unbalanced quotes on a push line are refused" unparsed "git push origin 'HEAD:refs/heads/x" $RB
t "a tag push passes" pass "git push origin refs/tags/v1" $RB
t "a command that only mentions git push in an echo passes" pass "echo git push origin HEAD:refs/heads/wm-build/x" $RB
t "git status passes" pass "git status" $RB
payload "$R" Read | env WM_SEAT=rb bash "$hook" >/dev/null 2>&1; n=$((n+1)); [ $? = 0 ] && echo "ok - a non-Bash tool passes" || { echo "NOT OK - non-Bash tool"; fail=1; }
# registered in the settings.json Bash PreToolUse list
n=$((n+1)); jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command] | any(endswith("/.claude/hooks/land-push-gate.sh"))' "$here/.claude/settings.json" >/dev/null && echo "ok - land-push-gate.sh is registered under PreToolUse/Bash in .claude/settings.json" || { echo "NOT OK - hook not registered"; fail=1; }
# the rb coder launcher exports the marker
n=$((n+1)); grep -q 'RB_CODER_ID="\$n"' "$here/.local/bin/rb-run-coder.sh" && echo "ok - rb-run-coder.sh exports RB_CODER_ID" || { echo "NOT OK - RB_CODER_ID not exported by rb-run-coder.sh"; fail=1; }
echo "land-push-gate: $n checks, fail=$fail"; exit $fail
