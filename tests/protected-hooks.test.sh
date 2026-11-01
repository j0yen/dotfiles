#!/usr/bin/env bash
# protected hooks (Joe 10-23): summa + wintermute hooks listed in .claude/protected-hooks.txt must stay wired in the repo's
# .claude/settings.json (repo-relative, not $HOME) and summa-lookup-inject.sh keeps timeout >= 10; the checker's own --selftest must pass.
# Runs under a throwaway HOME: APPROVALS_LOG points at an empty file so only the repo's settings decide.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
C="$here/.claude/hooks/protected-hooks-check.sh"

bash -n "$C" && ok "bash -n protected-hooks-check.sh" || bad "bash -n protected-hooks-check.sh"
[ -x "$C" ] && ok "checker executable" || bad "checker not executable"
[ -s "$here/.claude/protected-hooks.txt" ] && ok "protected-hooks.txt present" || bad "protected-hooks.txt missing"

: > "$tmp/approvals.log"
out="$(HOME="$tmp" APPROVALS_LOG="$tmp/approvals.log" bash "$C" "$here/.claude/settings.json" "$here/.claude/protected-hooks.txt" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "repo settings.json passes the protected-hooks check" || { bad "repo settings.json protected-hooks check"; printf '%s\n' "$out" | grep -v '^ok '; }

out="$(HOME="$tmp" bash "$C" --selftest 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | tail -n1 | grep -Eq '^protected-hooks-check selftest ([0-9]+)/\1$' \
  && ok "--selftest ($(printf '%s\n' "$out" | tail -n1))" || { bad "--selftest"; printf '%s\n' "$out"; }
exit $fail
