#!/usr/bin/env bash
# merge-gate-guard.sh: a bare `gh pr merge` (or a `gh api -X PUT .../merge`) on a merge-gate repo is
# denied; an `&&` chain after `wm-decide merge-gate`, rb-merge.sh, an unlisted repo and non-merge gh
# commands pass; the repo list comes from the contract (fixture via MERGE_GATE_CONTRACT); wired.
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
G="$D/.claude/hooks/merge-gate-guard.sh"; S="$D/.claude/settings.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat >"$T/merge-gate.json" <<'J'
{"repo_tokens": {"j0yen/dotfiles": ["tests/*.test.sh EXIT=0"], "j0yen/vibecode-kit": ["tests/*.sh EXIT=0"], "j0yen/mcphost": ["cargo test EXIT=0"]}}
J
export MERGE_GATE_CONTRACT="$T/merge-gate.json"
# a listed and an unlisted clone, for the no---repo case
git init -q "$T/listed" && git -C "$T/listed" remote add origin https://github.com/j0yen/dotfiles.git
git init -q "$T/ssh" && git -C "$T/ssh" remote add origin git@github.com:j0yen/vibecode-kit.git
git init -q "$T/other" && git -C "$T/other" remote add origin https://github.com/j0yen/unlisted.git
fail=0
ok(){ [ "$2" = "$3" ] && echo "ok $1" || { echo "FAIL $1 rc=$2 want $3"; fail=1; }; }
run(){ jq -nc --arg c "$1" --arg d "${2:-$T}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | "$G" 2>"$T/err"; echo $?; }
GATE='wm-decide merge-gate V1 --pr 5 --repo j0yen/dotfiles'

ok "deny: bare merge on dotfiles"          "$(run 'gh pr merge 5 --repo j0yen/dotfiles --squash --delete-branch')" 2
grep -q 'wm-decide merge-gate <verdict-id> --pr 5 --repo j0yen/dotfiles && gh pr merge 5 --repo j0yen/dotfiles --squash --delete-branch' "$T/err" \
  && echo "ok deny message prints the allowed line" || { echo "FAIL deny message: $(cat "$T/err")"; fail=1; }
ok "deny: bare merge on vibecode-kit"      "$(run 'gh pr merge 7 --repo j0yen/vibecode-kit --squash')" 2
ok "deny: bare merge on mcphost"           "$(run 'gh pr merge 9 -R j0yen/mcphost --squash')" 2
ok "deny: --repo=owner/name form"          "$(run 'gh pr merge 9 --repo=j0yen/mcphost')" 2
ok "deny: repo from the cwd origin"        "$(run 'gh pr merge 5 --squash' "$T/listed")" 2
ok "deny: repo from an ssh origin"         "$(run 'gh pr merge 5' "$T/ssh")" 2
ok "deny: repo after a cd in the command"  "$(run "cd $T/listed && gh pr merge 5")" 2
ok "deny: PR url names the repo"           "$(run 'gh pr merge https://github.com/j0yen/dotfiles/pull/5')" 2
ok "deny: GH_REPO env"                     "$(run 'GH_REPO=j0yen/dotfiles gh pr merge 5')" 2
ok "deny: ; chain after the gate"          "$(run "$GATE ; gh pr merge 5 --repo j0yen/dotfiles --squash")" 2
ok "deny: || chain after the gate"         "$(run "$GATE || gh pr merge 5 --repo j0yen/dotfiles --squash")" 2
ok "deny: gate piped to tail (10-22 #73)"  "$(run "$GATE | tail -3 && gh pr merge 5 --repo j0yen/dotfiles --squash")" 2
ok "deny: newline after the gate"          "$(run "$GATE
gh pr merge 5 --repo j0yen/dotfiles --squash")" 2
ok "deny: merge before the gate"           "$(run "gh pr merge 5 --repo j0yen/dotfiles && $GATE")" 2
ok "deny: bash -c wrapper"                 "$(run "bash -c 'gh pr merge 5 --repo j0yen/dotfiles'")" 2
ok "deny: gh api PUT merge (-X)"           "$(run 'gh api -X PUT repos/j0yen/dotfiles/pulls/5/merge -f merge_method=squash')" 2
ok "deny: gh api PUT merge (--method)"     "$(run 'gh api --method PUT repos/j0yen/mcphost/pulls/9/merge')" 2
ok "deny: gh api PUT merge (-XPUT, /lead)" "$(run 'gh api -XPUT /repos/j0yen/vibecode-kit/pulls/9/merge')" 2
ok "deny: gh api PUT even after the gate"  "$(run "$GATE && gh api -X PUT repos/j0yen/dotfiles/pulls/5/merge")" 2

ok "allow: && chain after the gate"        "$(run "$GATE && gh pr merge 5 --repo j0yen/dotfiles --squash --delete-branch")" 0
ok "allow: && chain, link in between"      "$(run "$GATE && echo ok && gh pr merge 5 --repo j0yen/dotfiles")" 0
ok "allow: && chain from a cwd origin"     "$(run "$GATE && gh pr merge 5 --squash" "$T/listed")" 0
ok "allow: rb-merge.sh"                    "$(run 'rb-merge.sh V1 5 j0yen/dotfiles')" 0
ok "allow: rb-merge.sh by path + env"      "$(run 'RB_MERGE_GH=gh ~/.local/bin/rb-merge.sh V1 5 j0yen/mcphost')" 0
ok "allow: merge on an unlisted repo"      "$(run 'gh pr merge 5 --repo j0yen/unlisted --squash')" 0
ok "allow: unlisted cwd origin"            "$(run 'gh pr merge 5' "$T/other")" 0
ok "allow: no repo, no origin (unknown)"   "$(run 'gh pr merge 5' "$T")" 0
ok "allow: gh api PUT on an unlisted repo" "$(run 'gh api -X PUT repos/j0yen/unlisted/pulls/5/merge')" 0
ok "allow: gh api GET on a listed merge"   "$(run 'gh api repos/j0yen/dotfiles/pulls/5/merge')" 0
ok "allow: gh pr view"                     "$(run 'gh pr view 5 --repo j0yen/dotfiles --json state')" 0
ok "allow: gh pr create"                   "$(run 'gh pr create --repo j0yen/dotfiles --title x --body y')" 0
ok "allow: gh pr list"                     "$(run 'gh pr list --repo j0yen/mcphost --state merged')" 0
ok "allow: gh api listed, no PUT"          "$(run 'gh api repos/j0yen/dotfiles/pulls/5 -q .state')" 0
ok "allow: merge text inside a commit msg" "$(run "git commit -m 'run gh pr merge 5 --repo j0yen/dotfiles later'")" 0
ok "allow: merge text in a heredoc"        "$(run "cat <<'X'
gh pr merge 5 --repo j0yen/dotfiles
X")" 0
ok "allow: non-Bash tool"                  "$(printf '{"tool_name":"Write","tool_input":{"command":"gh pr merge 5 --repo j0yen/dotfiles"}}' | "$G" 2>/dev/null; echo $?)" 0
ok "allow: garbage input"                  "$(printf 'not json' | "$G" 2>/dev/null; echo $?)" 0
ok "allow: empty input"                    "$(printf '' | "$G" 2>/dev/null; echo $?)" 0
ok "allow: unbalanced quote (unparseable)" "$(run "gh pr merge 5 --repo j0yen/dotfiles --body 'oops")" 0
ok "allow: contract missing (unknown)" "$(MERGE_GATE_CONTRACT="$T/missing.json" run 'gh pr merge 5 --repo j0yen/dotfiles')" 0

# the list is read from the contract, not hardcoded: swap the fixture
echo '{"repo_tokens": {"j0yen/unlisted": ["x"]}}' >"$T/merge-gate.json"
ok "list is the contract's: dotfiles now free"   "$(run 'gh pr merge 5 --repo j0yen/dotfiles')" 0
ok "list is the contract's: unlisted now denied" "$(run 'gh pr merge 5 --repo j0yen/unlisted')" 2

jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command|endswith("merge-gate-guard.sh")) | select(.timeout==5)' "$S" >/dev/null \
  && echo "ok wired on Bash PreToolUse, timeout 5" || { echo "FAIL not wired on Bash PreToolUse with timeout 5"; fail=1; }
exit $fail
