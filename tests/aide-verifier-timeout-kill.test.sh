#!/usr/bin/env bash
# tests/aide-verifier-timeout-kill.test.sh: (1) the aide-verifier.sh --selftest TKG cases (stubs only: default timeout 2400, --timeout 5400 reaches `timeout`, 99999/59/abc exit 2,
# finish reports timeout_s, launch.sh deny rules + unit-scoped hook, prompt line); (2) verifier-kill-guard.sh refuses pkill/killall/kill-by-pattern and allows `kill 12345`.
# No claude, no systemd unit, no real row. Run: bash tests/aide-verifier-timeout-kill.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../.local/bin/aide-verifier.sh"; guard="$here/../.local/bin/verifier-kill-guard.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
th=$(mktemp -d "${TMPDIR:-/tmp}/avtk-test.XXXXXX"); trap 'rm -rf "$th"' EXIT
out=$(HOME="$th" bash "$script" --selftest 2>&1)
for c in 'default launch.sh runs' '--timeout 5400 reaches' '--timeout 99999 -> exit 2' '--timeout 59 -> exit 2' '--timeout abc -> exit 2' 'finish reports the recorded timeout_s' 'launch.sh denies Bash(pkill' 'prompt forbids pkill'; do
  printf '%s\n' "$out" | grep -F 'PASS TKG ' | grep -qF -- "$c" && pass "selftest TKG: $c" || { bad "selftest TKG case missing or failing: $c"; printf '%s\n' "$out" | grep -F 'TKG' | head -n 12; }
done
printf '%s\n' "$out" | grep -q '^FAIL' && bad "selftest has a FAIL line" || pass "selftest has no FAIL line"
hook() { printf '%s' "$1" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' | bash "$guard" >/dev/null 2>"$th/err"; }
deny() { hook "$1"; [ $? = 2 ] && grep -q 'verifier-kill-guard: refused' "$th/err" && pass "guard denies: $1" || bad "guard should deny: $1"; }
allow() { hook "$1"; [ $? = 0 ] && pass "guard allows: $1" || bad "guard should allow: $1"; }
deny "pkill -f wm-verify-run"
deny "pkill wm-verify-run"
deny "cd x && killall python3"
deny "timeout 5 pkill -9 -f foo"
deny "kill -f wm-verify-run"
deny 'kill $(pgrep -f wm-verify-run)'
deny "pgrep -f wm-verify-run | xargs kill"
deny "kill -9 wm-verify-run"
allow "kill 12345"
allow "kill -9 12345"
allow 'kill -TERM "$pid"'
allow 'sleep 1 & kill $!'
allow "systemctl --user stop aide-verifier-x"
allow "git log --oneline | head -3"
allow "grep -n pkillx file"
echo "---"; [ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
