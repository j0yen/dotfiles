#!/usr/bin/env bash
# kill-list-gate.sh: ssh to a build host may not kill a computed pid list; registered once in settings.json.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$here/.claude/hooks/kill-list-gate.sh"
S="$here/.claude/settings.json"
H=$(mktemp -d); trap 'rm -rf "$H"' EXIT
fail=0
run() { # name expected-rc command
  local name=$1 want=$2 c=$3 rc
  local j; j=$(python3 -I -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$c")
  HOME="$H" bash "$HOOK" <<<"$j" 2>/dev/null
  rc=$?
  if [ "$rc" = "$want" ]; then echo "ok - $name (rc $rc)"; else echo "NOT OK - $name: rc $rc, want $want"; fail=1; fi
}
run "ssh redbaron kill \$p blocked" 2 "ssh redbaron 'kill \$p'"
run "ssh redbaron pkill blocked" 2 "ssh redbaron 'pkill -f foo'"
run "ssh redbaron awk | xargs kill blocked" 2 "ssh redbaron 'ps aux | awk \"{print \\\$2}\" | xargs kill'"
run "rb-kill-tree.sh allowed" 0 "ssh redbaron 'bash /mnt/data/hand/rb-kill-tree.sh 1234'"
run "kill \$p without ssh allowed" 0 'kill $p'
run "ssh redbaron kill literal pid allowed" 0 "ssh redbaron 'kill 12345'"
# escape hatch works once, against the temp HOME only
mkdir -p "$H/.claude"; : > "$H/.claude/.allow-kill-list"
run "escape hatch lets one call through" 0 "ssh redbaron 'pkill -f foo'"
if [ -e "$H/.claude/.allow-kill-list" ]; then echo "NOT OK - escape hatch file not consumed"; fail=1; else echo "ok - escape hatch consumed"; fi
run "after the hatch, blocked again" 2 "ssh redbaron 'pkill -f foo'"
n=$(grep -c 'kill-list-gate\.sh' "$S")
if [ "$n" = 1 ]; then echo "ok - settings.json registers kill-list-gate.sh once"; else echo "NOT OK - settings.json registers kill-list-gate.sh $n times"; fail=1; fi
[ -x "$HOOK" ] && echo "ok - hook is executable" || { echo "NOT OK - hook not executable"; fail=1; }
exit $fail
