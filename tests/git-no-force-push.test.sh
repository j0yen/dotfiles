#!/usr/bin/env bash
# git-no-force-push hook (Joe 10-29 "why force push?"): denies force pushes and history rewrites in every session.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
H="$here/.claude/hooks/git-no-force-push.sh"
S="$here/.claude/settings.json"
T="$(mktemp -d "${TMPDIR:-/tmp}/nfp-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export NFP_STATE_DIR="$T/state"
LOG="$NFP_STATE_DIR/fires.log"
pass=0; fail=0
ok() { echo "ok - $1"; pass=$((pass + 1)); }
no() { echo "NOT OK - $1"; fail=$((fail + 1)); }
lines() { if [ -f "$LOG" ]; then wc -l < "$LOG"; else echo 0; fi; }
mk() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

DENY=(
  'git push --force origin main' 'git push -f' 'git push -fu origin br' 'git push --force-with-lease'
  'git push --force-with-lease=main:abc origin main' 'git push --force-if-includes origin br'
  'git push origin +main' 'git push origin +HEAD:refs/heads/x' 'git -C /tmp/r push -f origin b'
  'cd x && git push --force' "ssh redbaron 'cd /w && git push -f origin b'"
  'git filter-branch --tree-filter x HEAD' 'git filter-repo --path y' 'git push --mirror'
  'git push origin --delete main' 'git push origin :main' 'env git push -f origin b'
  'bash -c "git push --force"' '/usr/bin/git push -f' 'FOO=1 git push -f'
  "git config alias.fp 'push --force'" "git -c alias.p='push -f' p"
)
ALLOW=(
  'git push origin br' 'git push -u origin br' 'git push origin br:refs/heads/br' 'rm -f x && git push origin br'
  'git fetch -f origin' 'git commit -m "explain why --force is banned"' 'git push origin --delete feature-x'
  'git push origin :feature-x' 'echo git push --force' 'grep -- --force file'
)

for c in "${DENY[@]}"; do
  before=$(lines)
  out=$(mk "$c" | "$H"); rc=$?
  after=$(lines)
  if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] \
     && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" = PreToolUse ] \
     && [ "$((after - before))" = 1 ]; then ok "deny: $c"; else no "deny: $c (rc=$rc out=$out log+=$((after - before)))"; fi
done
reason=$(mk 'git push -f' | "$H" | jq -r '.hookSpecificOutput.permissionDecisionReason')
if [ "$reason" = 'NEVER force push (Joe 10-29 "why force push?", CLAUDE.md): use a real merge of origin/main' ]; then ok "deny reason text"; else no "deny reason text: $reason"; fi

# the log holds the matched token, never the command
rm -f "$LOG"
mk 'git push --force origin secret-branch-name' | "$H" >/dev/null
if [ "$(tail -1 "$LOG" | awk -F' [|] ' '{print NF}')" = 3 ] && ! grep -q secret-branch-name "$LOG"; then ok "fires.log is iso | seat | token, no full command"; else no "fires.log format: $(cat "$LOG")"; fi
rm -f "$LOG"

for c in "${ALLOW[@]}"; do
  before=$(lines)
  out=$(mk "$c" | "$H"); rc=$?
  after=$(lines)
  if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$after" = "$before" ]; then ok "allow: $c"; else no "allow: $c (rc=$rc out=$out)"; fi
done
out=$(printf 'not json at all' | "$H"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok "allow: non-JSON stdin"; else no "non-JSON stdin rc=$rc out=$out"; fi
out=$(printf '{"tool_input":{}}' | "$H"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok "allow: JSON without command"; else no "JSON without command rc=$rc out=$out"; fi
if [ ! -f "$LOG" ]; then ok "allows added zero log lines"; else no "allows added log lines: $(wc -l < "$LOG")"; fi

st=$("$H" --selftest 2>&1); rc=$?
if [ "$rc" = 0 ] && [[ $st == *"selftest: pass="*" fail=0" ]]; then ok "--selftest: $st"; else no "--selftest rc=$rc: $st"; fi

# jq-missing fallback: PATH holds only the tools the hook needs, not jq
NB="$T/nojq"; mkdir -p "$NB"
for b in bash cat grep tr cut date mkdir; do ln -s "$(command -v "$b")" "$NB/$b"; done
out=$(printf '%s' '{"tool_input":{"command":"git push -f"}}' | env PATH="$NB" "$NB/bash" "$H"); rc=$?
if [ "$rc" = 0 ] && [[ $out == *'deny'* ]] && [[ $out == *'(parser missing)'* ]]; then ok "jq missing: fallback denies git push -f"; else no "jq missing fallback rc=$rc out=$out"; fi
out=$(printf '%s' '{"tool_input":{"command":"rm -f x && git push origin br"}}' | env PATH="$NB" "$NB/bash" "$H"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok "jq missing: fallback allows plain push"; else no "jq missing allow rc=$rc out=$out"; fi

# registration
if jq . "$S" >/dev/null 2>&1; then ok "settings.json parses"; else no "settings.json does not parse"; fi
if jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command] | any(endswith("git-no-force-push.sh"))' "$S" >/dev/null; then ok "PreToolUse Bash includes git-no-force-push.sh"; else no "git-no-force-push.sh not registered under PreToolUse Bash"; fi
if [ -x "$H" ]; then ok "hook is executable"; else no "hook not executable"; fi
# .config/claude-seat/settings.json is a hand-kept --settings overlay (hooks merge with the user settings), not generated from .claude/settings.json
echo "NEEDS: seat settings not in dotfiles (.config/claude-seat/settings.json is a hand-kept overlay, not generated from .claude/settings.json; seats inherit the hook via user-settings merge, confirm on a live seat)"

echo "git-no-force-push.test: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
