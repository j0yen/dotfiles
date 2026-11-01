#!/usr/bin/env bash
# analysis-page-gate.sh + skill-marker.sh: a new five-whys / decisions page needs the
# skill's fresh marker AND a Fable turn; existing pages + other paths pass; wired.
set -u
D="$(dirname "$0")/.."
G="$D/.claude/hooks/analysis-page-gate.sh"; M="$D/.claude/hooks/skill-marker.sh"; S="$D/.claude/settings.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export ANALYSIS_WIKI_DIR="$T/wiki" SKILL_MARKER_DIR="$T/marks" FABLE_SKILLS_DIR="$T/skills"
mkdir -p "$T/wiki/answers" "$T/wiki/decisions" "$T/skills/5whysandrhyme" "$T/skills/wwhtbt"
A="$T/wiki/answers/2026-10-24-x-five-whys-rhyme.md"; DP="$T/wiki/decisions/2026-10-24-plan-wwhtbt.md"
fail=0
ok(){ [ "$2" = "$3" ] && echo "ok $1" || { echo "FAIL $1 rc=$2 want $3"; fail=1; }; }
mk(){ printf '{"type":"assistant","message":{"model":"%s","content":[{"type":"tool_use","id":"tu1"}]}}\n' "$1" >"$T/t.jsonl"; }
w(){ printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"transcript_path":"%s","tool_use_id":"tu1","session_id":"s1"}' "$1" "$T/t.jsonl" | "$G" 2>/dev/null; echo $?; }
b(){ jq -nc --arg c "$1" --arg t "$T/t.jsonl" '{tool_name:"Bash",tool_input:{command:$c},transcript_path:$t,tool_use_id:"tu1",session_id:"s1"}' | "$G" 2>/dev/null; echo $?; }
mk claude-fable-5-1
ok "no marker: new five-whys page denied"   "$(w "$A")" 2
ok "no marker: new decisions page denied"   "$(w "$DP")" 2
ok "no marker: other answers page allowed"  "$(w "$T/wiki/answers/2026-10-24-plain.md")" 0
ok "no marker: bash heredoc denied"         "$(b "cat > $A <<'X'")" 2
ok "no marker: bash tee denied"             "$(b "printf x | tee $DP")" 2
ok "no marker: bash mv denied"              "$(b "mv /tmp/x.md $A")" 2
ok "no marker: bash read allowed"           "$(b "grep -l foo $T/wiki/answers/*.md")" 0
ok "no marker: glob read 2>/dev/null ok"    "$(b "grep -l x $T/wiki/answers/*five-whys* 2>/dev/null")" 0
ok "no marker: missing-path ls 2>&1 ok"     "$(b "ls $A 2>&1")" 0
touch "$A"
ok "existing page Write allowed"            "$(w "$A")" 0
ok "existing page bash >> allowed"          "$(b "echo x >> $A")" 0
rm -f "$A"
printf '{"prompt":"/5whysandrhyme why did X","session_id":"s1"}' | "$M"
[ -e "$T/marks/5whysandrhyme.s1" ] && echo "ok typed /5whysandrhyme marks" || { echo "FAIL typed form not marked"; fail=1; }
printf '{"prompt":"/nosuch x","session_id":"s1"}' | "$M"
[ ! -e "$T/marks/nosuch.s1" ] && echo "ok unknown skill not marked" || { echo "FAIL nosuch marked"; fail=1; }
ok "marker + fable: five-whys allowed"      "$(w "$A")" 0
ok "5whys marker: decisions page allowed"   "$(w "$DP")" 0
mk claude-opus-5-5
ok "marker + opus parent: denied"           "$(w "$A")" 2
rm -f "$T/t.jsonl"
ok "marker + unknown model: allowed"        "$(w "$A")" 0
mk claude-fable-5-1
printf '{"prompt":"/5whysandrhyme x","session_id":"s2"}' | "$M"; rm -f "$T/marks/5whysandrhyme.s1"
ok "other session's marker: denied"         "$(w "$A")" 2
touch -d '-200 min' "$T/marks/5whysandrhyme.s2"; cp -p "$T/marks/5whysandrhyme.s2" "$T/marks/5whysandrhyme.s1"
ok "stale marker: denied"                   "$(w "$A")" 2
for e in Write Bash; do
  jq -e --arg e "$e" '.hooks.PreToolUse[] | select(.matcher==$e) | .hooks[] | select(.command|endswith("analysis-page-gate.sh"))' "$S" >/dev/null \
    && echo "ok wired $e" || { echo "FAIL not wired on $e"; fail=1; }
done
jq -e '.hooks.UserPromptSubmit[] | .hooks[] | select(.command|endswith("skill-marker.sh"))' "$S" >/dev/null \
  && echo "ok skill-marker wired" || { echo "FAIL skill-marker not wired"; fail=1; }
exit $fail
