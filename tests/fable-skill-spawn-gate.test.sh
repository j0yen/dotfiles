#!/usr/bin/env bash
# fable-skill-spawn-gate.sh: a non-Fable Skill call to a `fable-spawn: true` skill is
# denied with the spawn recipe; Fable/unknown/other skills allowed and marked; wired.
set -u
H="$(dirname "$0")/../.claude/hooks/fable-skill-spawn-gate.sh"
S="$(dirname "$0")/../.claude/settings.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FABLE_SKILLS_DIR="$T/skills" SKILL_MARKER_DIR="$T/marks"
fm(){ mkdir -p "$T/skills/$1"; printf -- "---\nname: %s\nmodel: fable\n$2---\n# x\nfable-spawn: true\n" "$1" >"$T/skills/$1/SKILL.md"; }
fm dream 'fable-spawn: true\n'; fm 5whysandrhyme 'fable-spawn: true\n'; fm wwhtbt 'fable-spawn: true\n'
fm write ''   # body mentions fable-spawn: true, frontmatter does not → not gated
fail=0
mk(){ printf '{"type":"assistant","message":{"model":"%s","content":[{"type":"tool_use","id":"tu1"}]}}\n' "$1" >"$T/t.jsonl"; }
chk(){ rm -rf "$T/marks"
       printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"transcript_path":"%s","tool_use_id":"tu1","session_id":"s1"}' "$2" "$T/t.jsonl" | "$H" 2>/dev/null; rc=$?
       [ "$rc" = "$3" ] && echo "ok $1" || { echo "FAIL $1 rc=$rc want $3"; fail=1; }
       n=${2##*:}
       if [ "$3" = 0 ]; then [ -e "$T/marks/$n.s1" ] || { echo "FAIL $1 no marker"; fail=1; }
       else [ ! -e "$T/marks/$n.s1" ] || { echo "FAIL $1 marker on deny"; fail=1; }; fi; }
mk claude-opus-5-5;   chk "opus dream denied" dream 2
mk claude-opus-5-5;   chk "opus plugin:dream denied" vibecode:dream 2
mk claude-opus-5-5;   chk "opus 5whysandrhyme denied" 5whysandrhyme 2
mk claude-sonnet-5-5; chk "sonnet wwhtbt denied" wwhtbt 2
mk claude-fable-5-1;  chk "fable 5whysandrhyme allowed" 5whysandrhyme 0
mk claude-opus-5-5;   chk "opus write allowed (body-only key)" write 0
mk claude-opus-5-5;   chk "opus unknown skill allowed" nosuch 0
rm -f "$T/t.jsonl";   chk "unknown model allowed" dream 0
mk claude-opus-5-5
out=$(printf '{"tool_name":"Skill","tool_input":{"skill":"wwhtbt","args":"plan X"},"transcript_path":"%s","tool_use_id":"tu1"}' "$T/t.jsonl" | "$H" 2>&1 >/dev/null)
printf '%s' "$out" | grep -q 'skill: wwhtbt, args: plan X' && echo "ok recipe names skill+args" || { echo "FAIL recipe: $out"; fail=1; }
jq -e '.hooks.PreToolUse[] | select(.matcher=="Skill") | .hooks[0] | select(.command|endswith("fable-skill-spawn-gate.sh"))' "$S" >/dev/null \
  && echo "ok wired first on Skill" || { echo "FAIL not wired first in settings.json"; fail=1; }
jq -e '[.. | .command? // empty | strings | select(endswith("dream-spawn-gate.sh"))] | length == 0' "$S" >/dev/null \
  && echo "ok old dream-spawn-gate unwired" || { echo "FAIL dream-spawn-gate.sh still wired"; fail=1; }
# No drift: every live fable-spawn skill on this host pins model: fable + effort: max.
for f in "$HOME"/.claude/skills/*/SKILL.md; do
  [ -r "$f" ] || continue
  fmx=$(awk 'NR==1&&$0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$f")
  printf '%s\n' "$fmx" | grep -qE '^fable-spawn:[[:space:]]*true' || continue
  if printf '%s\n' "$fmx" | grep -qE '^model:[[:space:]]*fable' && printf '%s\n' "$fmx" | grep -qE '^effort:[[:space:]]*max'; then
    echo "ok pins $(basename "$(dirname "$f")")"
  else echo "FAIL $f fable-spawn without model: fable + effort: max"; fail=1; fi
done
exit $fail
