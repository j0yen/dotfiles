#!/usr/bin/env bash
# dream-spawn-gate.sh: non-Fable Skill(dream) denied, Fable/unknown/other skills allowed, hook wired.
set -u
H="$(dirname "$0")/../.claude/hooks/dream-spawn-gate.sh"
S="$(dirname "$0")/../.claude/settings.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
mk(){ printf '{"type":"assistant","message":{"model":"%s","content":[{"type":"tool_use","id":"tu1"}]}}\n' "$1" >"$T/t.jsonl"; }
chk(){ printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"transcript_path":"%s","tool_use_id":"tu1"}' "$2" "$T/t.jsonl" | "$H" 2>/dev/null; rc=$?
       [ "$rc" = "$3" ] && echo "ok $1" || { echo "FAIL $1 rc=$rc want $3"; fail=1; }; }
mk claude-opus-5-5;   chk "opus dream denied" dream 2
mk claude-opus-5-5;   chk "opus plugin:dream denied" vibecode:dream 2
mk claude-sonnet-5-5; chk "sonnet dream denied" dream 2
mk claude-fable-5-1;  chk "fable dream allowed" dream 0
mk claude-opus-5-5;   chk "opus write allowed" write 0
rm -f "$T/t.jsonl";   chk "unknown model allowed" dream 0
jq -e '.hooks.PreToolUse[] | select(.matcher=="Skill") | .hooks[] | select(.command|endswith("dream-spawn-gate.sh"))' "$S" >/dev/null \
  && echo "ok wired" || { echo "FAIL not wired in settings.json"; fail=1; }
exit $fail
