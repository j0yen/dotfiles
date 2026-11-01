#!/usr/bin/env bash
# owed-now (Joe 10-31 11:1x PM "NEVER DELAY SOMETHING YOU CAN DO NOW", "make it impossible to procrastinate on anything", approvals #181/#182):
# the hook's selftest passes and it is registered once under UserPromptSubmit and once under Stop (matcher "").
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
S="$here/.claude/settings.json"; H="$here/.claude/hooks/owed-now.sh"
bash -n "$H" && ok "bash -n owed-now.sh" || bad "bash -n owed-now.sh"
[ -x "$H" ] && ok "owed-now.sh executable" || bad "owed-now.sh not executable"
out="$(env -u WM_SEAT bash "$H" --selftest 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | tail -n1 | grep -qE '^selftest: [0-9]+ PASS 0 FAIL$' \
  && ok "owed-now.sh --selftest ($(printf '%s\n' "$out" | grep -c '^PASS') checks)" || { bad "owed-now.sh --selftest"; printf '%s\n' "$out" | tail -n 20; }
jq -e . "$S" >/dev/null && ok "settings.json parses" || { bad "settings.json parses"; exit 1; }
for ev in UserPromptSubmit Stop; do
  n="$(jq -r --arg ev "$ev" '[.hooks[$ev][] | select(.matcher=="") | .hooks[] | select(.type=="command" and .command=="/home/jsy/.claude/hooks/owed-now.sh hook")] | length' "$S")"
  [ "$n" = 1 ] && ok "owed-now.sh registered once under $ev" || bad "owed-now.sh under $ev: $n (want 1)"
done
exit $fail
