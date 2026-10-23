#!/usr/bin/env bash
# tests/r7-mcp-gate.test.sh — the mcphost hand-PR gate pair (row 2726 touched-test mapping; ctl c0f8 MemGate slot, no fixed 8 G).
# Runs both scripts' own --selftest (stub cargo in a mktemp dir; no ssh, no clone, no cargo). Run: bash tests/r7-mcp-gate.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); bad=0
o=$(bash "$here/../.local/bin/r7-mcp-gate-remote.sh" --selftest 2>&1); rc=$?; printf '%s\n' "$o"
[ $rc = 0 ] && printf '%s\n' "$o" | grep -qx 'selftest ok' && printf '%s\n' "$o" | grep -q '^ok   a #\[path\] module runs as its parent target' && printf '%s\n' "$o" | grep -q '^ok   rc 0 with 0 tests ran -> EXIT=1' || bad=1
o=$(bash "$here/../.local/bin/r7-mcp-gate.sh" --selftest 2>&1); rc=$?; printf '%s\n' "$o"
[ $rc = 0 ] && printf '%s\n' "$o" | grep -qx 'selftest ok' && printf '%s\n' "$o" | grep -q '^ok   no fixed 8 G cap' && printf '%s\n' "$o" | grep -q '^ok   exit 75 = INFRA' || bad=1
[ $bad = 0 ] || { echo "NOT OK r7-mcp-gate"; exit 1; }
echo "OK r7-mcp-gate"
