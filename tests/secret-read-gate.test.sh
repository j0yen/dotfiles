#!/usr/bin/env bash
# secret-read-gate.sh: --selftest passes, both PreToolUse registrations exist, the S1 member list is the documented seven,
# the hook exits 2 / 0 end to end with ONE stderr line, the refusal log is written and redacted, and 100 calls finish < 6 s.
# Every input is a synthetic command STRING fed as JSON; no real secret file is ever opened.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
G="$here/.claude/hooks/secret-read-gate.sh"; S="$here/.claude/settings.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SRG_LOG_DIR="$T/log"
fail=0; n=0
ok(){ n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "NOT OK - $1 (got '$2' want '$3')"; fail=1; fi; }
run(){ jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},session_id:"s1"}' | "$G" 2>"$T/err"; echo $?; }

bash -n "$G"; ok "bash -n hook" "$?" 0
out=$("$G" --selftest 2>&1); rc=$?
echo "$out" | tail -3
ok "--selftest exit 0" "$rc" 0
ok "--selftest reports 0 failed" "$(echo "$out" | grep -c ' 0 failed$')" 1

python3 -I - "$S" <<'PY'; ok "registered: Bash group + Read|Grep group" "$?" 0
import json,sys
d=json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
def has(m): return any(g.get("matcher")==m and any(h.get("command","").endswith("/.claude/hooks/secret-read-gate.sh") for h in g["hooks"]) for g in d)
assert has("Bash"), "no Bash matcher group runs secret-read-gate.sh"
assert has("Read|Grep"), "no Read|Grep matcher group runs secret-read-gate.sh"
PY

want='*/.config/environment.d/*
*/90-claude-oauth.conf
/proc/*/environ
*/.claude/.credentials.json
*/.config/mcphost-deploy/age-identity.txt
*/storagebox.password
*/.config/gh/hosts.yml'
ok "S1 member list" "$("$G" --list-s1)" "$want"

ok "refuse: sed form"           "$(run "sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' ~/.config/environment.d/90-claude-oauth.conf")" 2
ok "refusal is ONE stderr line" "$(wc -l <"$T/err")" 1
ok "refusal names the rule"     "$(grep -c '^secret-read-gate: REFUSED S2: ' "$T/err")" 1
ok "refusal prints no value"    "$(grep -c 'CLAUDE_CODE_OAUTH_TOKEN=' "$T/err")" 0
ok "refuse: env"                "$(run env)" 2
ok "refuse: echo token"         "$(run 'echo $CLAUDE_CODE_OAUTH_TOKEN')" 2
ok "refuse: unquoted heredoc"   "$(run $'cat > f.md <<EOF\nrun `env`\nEOF')" 2
ok "allow: git status"          "$(run 'git status')" 0
ok "allow: ls ~/.config"        "$(run 'ls ~/.config')" 0
ok "allow: grep pattern"        "$(run 'grep -n environment.d .local/bin/seat-tick.sh')" 0
ok "allow: sed with null sink"  "$(run "sed -n p ~/.config/environment.d/90-claude-oauth.conf >/dev/null 2>&1")" 0
ok "allow: quoted heredoc"      "$(run $'cat > f.md <<\'EOF\'\nrun `env`\nEOF')" 0
rd(){ jq -nc --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p},session_id:"s2"}' | "$G" 2>/dev/null; echo $?; }
gr(){ jq -nc --arg p "$1" --arg m "$2" '{tool_name:"Grep",tool_input:{pattern:"x",path:$p,output_mode:$m},session_id:"s3"}' | "$G" 2>/dev/null; echo $?; }
ok "refuse: Read env.d"         "$(rd /home/jsy/.config/environment.d/90-claude-oauth.conf)" 2
ok "allow: Read other"          "$(rd /home/jsy/dotfiles/README.md)" 0
ok "refuse: Grep content HOME"  "$(gr /home/jsy content)" 2
ok "allow: Grep files_with_matches" "$(gr ~/.config files_with_matches)" 0
ok "malformed JSON allowed"     "$(printf 'nonsense' | "$G" 2>/dev/null; echo $?)" 0

log="$T/log/refusals.log"
ok "refusal log written"        "$([ -s "$log" ] && echo yes)" yes
ok "log carries iso session tool rule" "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+ s1 Bash S2 ' "$log")" 1
run 'cat /proc/1/environ sk-ant-oat01-ZZZZZZZZZZZZZZZZZZZZZZZZZZ' >/dev/null
ok "log redacts secret-shaped strings" "$(grep -c 'sk-ant' "$log")" 0

# Best of 3 attempts: a loaded host (carbon runs seats + timers) can add seconds to one loop; a real regression fails all three.
el=99
for _ in 1 2 3; do
  t0=$(date +%s.%N)
  for _ in $(seq 100); do printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git log --oneline | head -5 && ls ~/.config"},"session_id":"s"}' | "$G" >/dev/null 2>&1; done
  t1=$(date +%s.%N)
  cur=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
  el=$(awk -v a="$el" -v b="$cur" 'BEGIN{printf "%.2f", (b<a)?b:a}')
  awk -v e="$el" 'BEGIN{exit !(e<6)}' && break
done
echo "latency: 100 calls in ${el}s (best of up to 3)"
ok "latency: 100 calls < 6 s (${el}s)" "$(awk -v e="$el" 'BEGIN{print (e<6)?"yes":"no"}')" yes

if [ $fail = 0 ]; then echo "PASS secret-read-gate ($n shell asserts)"; else echo "FAIL secret-read-gate"; fi
exit $fail
