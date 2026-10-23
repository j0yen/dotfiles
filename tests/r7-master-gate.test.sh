#!/usr/bin/env bash
# tests/r7-master-gate.test.sh — r7-synthorg-master-gate.sh classifies flaky-lane, part-red and timeout runs (row 8ec8).
# Runs the script's own --selftest (fixtures in a mktemp dir). Run: bash tests/r7-master-gate.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
out=$(bash "$here/../.local/bin/r7-synthorg-master-gate.sh" --selftest 2>&1); rc=$?
printf '%s\n' "$out"
[ $rc = 0 ] && printf '%s\n' "$out" | grep -qx 'selftest ok' || { echo "NOT OK r7-master-gate"; exit 1; }
echo "OK r7-master-gate"
