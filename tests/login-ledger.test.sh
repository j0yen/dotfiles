#!/usr/bin/env bash
# login-ledger (A264): selftest passes and the hook is registered once under SessionStart and once under UserPromptSubmit.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
S="$here/.claude/settings.json"; H="$here/.claude/hooks/login-ledger.sh"
bash -n "$H" && ok "bash -n login-ledger.sh" || bad "bash -n login-ledger.sh"
[ -x "$H" ] && ok "login-ledger.sh executable" || bad "login-ledger.sh not executable"
out="$(env -u WM_SEAT bash "$H" --selftest 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | tail -n1 | grep -qE '^selftest: [0-9]+ PASS 0 FAIL$' && ok "login-ledger.sh --selftest" || { bad "login-ledger.sh --selftest"; printf '%s\n' "$out" | tail -n 20; }
jq -e . "$S" >/dev/null && ok "settings.json parses" || { bad "settings.json parses"; exit 1; }
for ev in SessionStart UserPromptSubmit; do
  n="$(jq -r --arg ev "$ev" '[.hooks[$ev][]? | .hooks[] | select(.type=="command" and .command=="/home/jsy/.claude/hooks/login-ledger.sh")] | length' "$S")"
  [ "$n" = 1 ] && ok "login-ledger.sh registered once under $ev" || bad "login-ledger.sh under $ev: $n (want 1)"
done
exit $fail
