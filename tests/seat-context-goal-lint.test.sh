#!/usr/bin/env bash
# seat-context-start.sh prints goal-lint: lines for a seat when goal-lint.sh is installed, and stays silent about it when not.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/home/.local/bin" "$t/home/Notes/wiki/playbooks" "$t/home/.cache/fleet-dash"
printf '## Stage\nSTAGE-LINE\n## Other\n' > "$t/home/Notes/wiki/goal.md"
printf 'PLAYBOOK\n' > "$t/home/Notes/wiki/playbooks/fleet-operations.md"
fail=0
out=$(HOME="$t/home" WM_SEAT=rb TMUX= bash "$here/.claude/hooks/seat-context-start.sh" 2>&1)
echo "$out" | grep -q 'STAGE-LINE' && echo "PASS stage printed" || { echo "FAIL stage missing"; fail=1; }
echo "$out" | grep -q 'goal-lint' && { echo "FAIL goal-lint line printed without the linter"; fail=1; } || echo "PASS silent without goal-lint.sh"
printf '#!/usr/bin/env bash\necho "CLEARWATER MISSING P1 P4"; echo "CLEARWATER-R7 ok"; exit 1\n' > "$t/home/.local/bin/goal-lint.sh"; chmod +x "$t/home/.local/bin/goal-lint.sh"
out=$(HOME="$t/home" WM_SEAT=rb TMUX= bash "$here/.claude/hooks/seat-context-start.sh" 2>&1); rc=$?
echo "$out" | grep -q '^goal-lint: CLEARWATER MISSING P1 P4' && echo "PASS MISSING line prefixed goal-lint:" || { echo "FAIL MISSING line absent"; fail=1; }
echo "$out" | grep -q '^goal-lint: CLEARWATER-R7 ok' && echo "PASS ok line prefixed" || { echo "FAIL ok line absent"; fail=1; }
[ "$rc" = 0 ] && echo "PASS hook rc 0 despite linter exit 1" || { echo "FAIL hook rc $rc"; fail=1; }
awk '/goal-lint/{g=NR} /fleet-operations.md ===/{p=NR} END{exit !(g&&p&&g<p)}' <<<"$out" && echo "PASS goal-lint block precedes the playbook" || { echo "FAIL ordering"; fail=1; }
exit $fail
