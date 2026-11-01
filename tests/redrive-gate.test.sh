#!/usr/bin/env bash
# tests/redrive-gate.test.sh — .claude/hooks/redrive-gate.sh denies a bare `wm-build run redrive` for WM_SEAT=r7
# (route: ~/.local/bin/r7-redrive.sh, which files the wm-decide row first) and is registered as a PreToolUse Bash hook.
# Runs the hook's own --selftest under a throwaway HOME (no real command is executed). Run: bash tests/redrive-gate.test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/redrive-gate.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

out=$(HOME="$tmp" bash "$hook" --selftest 2>&1); rc=$?
printf '%s\n' "$out" | grep -v '^PASS'
[ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q '^FAIL'; chk "selftest rc 0, no FAIL (rc=$rc)" $?
n=$(printf '%s\n' "$out" | grep -c '^PASS'); [ "$n" -ge 10 ]; chk "selftest ran >= 10 passing cases (n=$n)" $?

command -v jq >/dev/null; chk "jq present" $?
[ -x "$hook" ]; chk "hook is executable" $?
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]?.command | select(endswith("/.claude/hooks/redrive-gate.sh"))] | length == 1' \
    "$here/.claude/settings.json" >/dev/null; chk "settings.json registers redrive-gate.sh once under PreToolUse matcher Bash" $?
exit $fail
