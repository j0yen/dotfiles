#!/usr/bin/env bash
# git-no-force-push hook: denied forms emit a deny JSON, allowed forms emit nothing.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/git-no-force-push.sh"
fail=0
run() { # want(deny|allow) command
    local want="$1" cmd="$2" out got rc
    out=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | "$hook"); rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'git-no-force-push: force push and history rewrite are not done in this fleet (Joe 10-29)'; then got=deny
    elif [ "$rc" -eq 0 ] && [ -z "$out" ]; then got=allow; else got="bad rc=$rc"; fi
    if [ "$got" = "$want" ]; then echo "ok   $want: $cmd"; else echo "FAIL want $want got $got: $cmd"; fail=1; fi
}
run deny 'git push --force origin main'
run deny 'git push -f origin main'
run deny 'git push origin br --force-with-lease'
run deny 'git push --force-with-lease=br:abc origin br'
run deny 'git push origin +br:br'
run deny 'git -C /tmp/x push -f'
run deny 'git filter-branch --tree-filter true'
run deny 'git filter-repo --path x'
run deny 'git rebase -i HEAD~3'
run deny 'git rebase --interactive origin/main'
run deny 'cd x && git push --force'
run allow 'git push origin main'
run allow 'git push -u origin br'
run allow 'git rebase origin/main'
run allow 'git log --force-color'
run allow 'ls -la'
[ "$fail" -eq 0 ] && echo "ALL PASS git-no-force-push" || { echo "FAILED git-no-force-push"; exit 1; }
