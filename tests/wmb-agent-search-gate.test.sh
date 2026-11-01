#!/usr/bin/env bash
# tests/wmb-agent-search-gate.test.sh — .claude/hooks/wmb-agent-search-gate.sh refuses whole-tree searches from
# wm-build agents (WM_BUILD_AGENT=1), allows scoped ones and everything when the marker is absent, logs each deny to
# $HOME/.cache/wmb-agent-search-gate/fires.log, and is registered once as a PreToolUse Bash hook.
# Feeds the hook Claude Code's stdin JSON under a throwaway HOME. Run: bash tests/wmb-agent-search-gate.test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/wmb-agent-search-gate.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/wt/run1"
wt="$T/wt/run1"
fires="$T/.cache/wmb-agent-search-gate/fires.log"
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
mkjson() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$2"; }
# run <marker 1|unset> <cwd> <command>  -> sets rc, err
run() {
  local json; json=$(mkjson "$3" "$2")
  if [ "$1" = 1 ]; then err=$(printf '%s' "$json" | env HOME="$T" WM_BUILD_AGENT=1 WM_BUILD_RUN=run1 bash "$hook" 2>&1 >/dev/null); rc=$?
  else err=$(printf '%s' "$json" | env -u WM_BUILD_AGENT HOME="$T" bash "$hook" 2>&1 >/dev/null); rc=$?; fi
}
lines() { if [ -f "$fires" ]; then wc -l <"$fires"; else echo 0; fi; }
deny() { # deny <cwd> <command>
  local before after; before=$(lines); run 1 "$1" "$2"; after=$(lines)
  [ "$rc" = 2 ] && [[ "$err" == "wmb-agent-search-gate: whole-tree search refused ("* ]] && [ "$after" = $((before + 1)) ]; chk "DENY  $2" $?
}
allow() { # allow <marker> <cwd> <command>
  local before after; before=$(lines); run "$1" "$2" "$3"; after=$(lines)
  [ "$rc" = 0 ] && [ -z "$err" ] && [ "$after" = "$before" ]; chk "ALLOW $3" $?
}

deny "$wt" 'bfs -S dfs / -name PRD-mcphost-docs-import*'
deny "$wt" 'ugrep -rl dimp_ac08 . ~/.local/state/wm-build'
deny "$wt" 'find /mnt/data -name x'
deny "$wt" 'rg foo /'
deny "$wt" 'grep -R foo ~'
deny "$wt" 'grep -R foo $HOME'
deny "$wt" 'cd /x && find $HOME -name y'
deny "$wt" 'find .. -name x'
deny "$wt" 'rg foo ~/.cache'
deny "$wt" 'cd /mnt/data && rg foo'
deny /mnt/data 'grep -r foo'

allow 1 "$wt" 'grep -rn dimp_ac08 .'
allow 1 "$wt" 'grep -rn foo src/ tests/'
allow 1 "$wt" 'rg foo'
allow 1 "$wt" "find . -name '*.rs'"
allow 1 "$wt" 'grep foo /etc/hosts'
allow 1 "$wt" 'ls /'
allow unset "$wt" 'bfs -S dfs / -name x'
allow 1 "$wt" 'grep -r "foo .'

grep -qE '^[0-9T:+-]+ run1 bfs /$' "$fires"; chk "fires.log line format (<time> <run> <tool> <root>)" $?

command -v jq >/dev/null; chk "jq present" $?
[ -x "$hook" ] && [ -f "$here/.claude/hooks/wmb-agent-search-gate.py" ]; chk "hook + classifier present, hook executable" $?
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]?.command | select(endswith("/.claude/hooks/wmb-agent-search-gate.sh"))] | length == 1' \
    "$here/.claude/settings.json" >/dev/null; chk "settings.json registers wmb-agent-search-gate.sh once under PreToolUse matcher Bash" $?
exit $fail
