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
t "a \$VAR refspec is refused (indirection rule)" block 'git push origin HEAD:refs/heads/$BR' $RB
t "unbalanced quotes on a push line are refused" unparsed "git push origin 'HEAD:refs/heads/x" $RB
t "a tag push passes" pass "git push origin refs/tags/v1" $RB
t "a command that only mentions git push in an echo passes (no wm-build/)" pass "echo git push origin HEAD:refs/heads/ci/x" $RB
t "an echo of a wm-build/ push is refused (coarse rule: push + wm-build/)" block "echo git push origin HEAD:refs/heads/wm-build/x" $RB
t "git status passes" pass "git status" $RB
# rlp1b indirection bypasses (Fable edits 1-3)
t "eval of a push to wm-build/ is refused" block 'eval "git push origin HEAD:refs/heads/wm-build/foo"' $RB
t "bash -c of a push to wm-build/ is refused" block 'bash -c "git push origin HEAD:wm-build/x"' $RB
t "xargs git push with a wm-build/ name is refused" block 'echo wm-build/x | xargs git push origin' $RB
t "xargs git push without any wm-build/ name is refused (xargs + push)" block 'echo ci/x | xargs git push origin' $RB
t "sh -c of a push without wm-build/ is refused (sh -c + push)" block "sh -c 'git push origin ci/x'" $RB
t "rb-land-push.sh chained with ; git push is refused" block 'rb-land-push.sh --confirm x --branch wm-build/x; git push origin HEAD:refs/heads/wm-build/y' $RB
t "rb-land-push.sh chained with && git push is refused" block 'rb-land-push.sh --confirm x --branch wm-build/x && git push origin HEAD:refs/heads/wm-build/y' $RB
t "rb-land-push.sh piped is refused" block 'rb-land-push.sh --confirm x --branch wm-build/x | git push origin HEAD:refs/heads/wm-build/y' $RB
t "rb-land-push.sh backgrounded with & then git push is refused" block 'rb-land-push.sh --confirm x --branch wm-build/x & git push origin HEAD:refs/heads/wm-build/y' $RB
t "rb-land-push.sh then a newline git push is refused" block $'rb-land-push.sh --confirm x --branch wm-build/x\ngit push origin HEAD:refs/heads/wm-build/y' $RB
t "rb-land-push.sh with a \$( ) after it is refused" block 'rb-land-push.sh --confirm x --branch wm-build/x $(git push origin HEAD:refs/heads/wm-build/y)' $RB
t "rb-land-push.sh with a backtick after it is refused" block 'rb-land-push.sh --confirm x --branch wm-build/x `git push origin HEAD:refs/heads/wm-build/y`' $RB
t "a \${B}build/x splice is refused" block 'B=wm-; git push origin HEAD:${B}build/x' $RB
t "the single simple rb-land-push.sh --confirm ... --branch wm-build/x passes" pass 'rb-land-push.sh --confirm d-20261024-100000-controller-abcd --repo /x --branch wm-build/x' $RB
t "the single simple rb-land-push.sh passes with 2>&1 after it" pass 'rb-land-push.sh --confirm d-20261024-100000-controller-abcd --repo /x --branch wm-build/x 2>&1' $RB
t "git log wm-build/x (no push) passes" pass "git log wm-build/x" $RB
t "the chained form from an unmarked session passes" pass 'rb-land-push.sh --confirm x --branch wm-build/x; git push origin HEAD:refs/heads/wm-build/y'
# refspec-less pushes rely solely on the parser's unparsed-target path (no wm-build/ in the text)
t "refspec-less 'git push' is refused via the unparsed-target path" unparsed "git push" $RB
t "'git push origin HEAD' is refused via the unparsed-target path" unparsed "git push origin HEAD" $RB
t "'git push --force-with-lease origin HEAD' is refused via the unparsed-target path" unparsed "git push --force-with-lease origin HEAD" $RB
# rlp1c: ssh-wrapped pushes (the sanctioned path for a RedBaron worktree is `rb-land-push.sh --host redbaron`, never `ssh <h> ...`); each case under WM_SEAT=rb and again under RB_CODER_ID
ID=d-20261024-000000-controller-abcd
for who in "$RB" RB_CODER_ID=x; do
  t "[$who] ssh with cd && git push is refused" block 'ssh redbaron "cd /mnt/data/wt/x && git push origin HEAD:wm-build/x"' $who
  t "[$who] ssh with git -C ... push is refused" block "ssh redbaron 'git -C /mnt/data/wt/x push origin HEAD:wm-build/x'" $who
  t "[$who] ssh with an unquoted git -C push --dry-run is refused" block 'ssh redbaron git -C /mnt/data/wt/x push --dry-run origin HEAD:wm-build/gate-probe' $who
  t "[$who] bash -c push is refused" block 'bash -c "git push origin HEAD:wm-build/x"' $who
  t "[$who] ssh bash -s with the push in a heredoc body is refused" block $'ssh redbaron bash -s <<\'EOF\'\ngit -C /mnt/data/wt/x push origin HEAD:refs/heads/wm-build/x\nEOF' $who
  t "[$who] remote invocation of rb-land-push.sh over ssh stays refused" block "ssh redbaron '~/.local/bin/rb-land-push.sh --confirm $ID --repo /x --branch wm-build/x'" $who
  t "[$who] ssh with cd; git push origin HEAD:refs/heads/... is refused" block "ssh redbaron 'cd /mnt/data/wt/x; git push origin HEAD:refs/heads/wm-build/x'" $who
  t "[$who] a cd && git push (no refspec) is refused as an unparsed target" unparsed 'cd /mnt/data/wt/x && git push' $who
  t "[$who] ssh with 'cd ... && git push' is refused (the ssh remainder is parsed)" unparsed "ssh redbaron 'cd /mnt/data/wt/x && git push'" $who
  t "[$who] ssh with a hand-branch push passes (same as locally)" pass "ssh redbaron 'git -C /mnt/data/wt/x push origin HEAD:refs/heads/ci/x'" $who
  t "[$who] rb-land-push.sh --host chained with && true is refused" block "rb-land-push.sh --confirm $ID --host redbaron --repo /x --branch wm-build/x && true" $who
  t "[$who] rb-land-push.sh --host redbaron --repo --branch as ONE simple command passes" pass "rb-land-push.sh --confirm $ID --host redbaron --repo /mnt/data/wt/x --branch wm-build/x" $who
  t "[$who] rb-land-push.sh --host redbaron --check as ONE simple command passes" pass "rb-land-push.sh --confirm $ID --host redbaron --repo /mnt/data/wt/x --branch wm-build/x --check" $who
done
payload "$R" Read | env WM_SEAT=rb bash "$hook" >/dev/null 2>&1; n=$((n+1)); [ $? = 0 ] && echo "ok - a non-Bash tool passes" || { echo "NOT OK - non-Bash tool"; fail=1; }
# registered in the settings.json Bash PreToolUse list
n=$((n+1)); jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command] | any(endswith("/.claude/hooks/land-push-gate.sh"))' "$here/.claude/settings.json" >/dev/null && echo "ok - land-push-gate.sh is registered under PreToolUse/Bash in .claude/settings.json" || { echo "NOT OK - hook not registered"; fail=1; }
# the rb coder launcher exports the marker
n=$((n+1)); grep -q "RB_CODER_ID='\"\$n\"'" "$here/.local/bin/rb-run-coder.sh" && echo "ok - rb-run-coder.sh exports RB_CODER_ID (on the remote host)" || { echo "NOT OK - RB_CODER_ID not exported by rb-run-coder.sh"; fail=1; }
echo "land-push-gate: $n checks, fail=$fail"; exit $fail
