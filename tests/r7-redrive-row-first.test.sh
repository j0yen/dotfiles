#!/usr/bin/env bash
# tests/r7-redrive-row-first.test.sh — r7-redrive.sh records the wm-decide row FIRST and redrives only on a
# decision id (ctl 2:1x 10-23, class 373c). Runs the script's own --selftest (stub wm-decide + ssh in a mktemp
# dir; no real row, no ssh). Run: bash tests/r7-redrive-row-first.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
out=$(bash "$here/../.local/bin/r7-redrive.sh" --selftest 2>&1); rc=$?
printf '%s\n' "$out"
[ $rc = 0 ] && printf '%s\n' "$out" | grep -qx 'selftest ok' && printf '%s\n' "$out" | grep -q '^ok   refused row -> rc 2' && printf '%s\n' "$out" | grep -q '^ok   refusal QUOTING an id' && printf '%s\n' "$out" | grep -q '^ok   id line under a nonzero exit' && printf '%s\n' "$out" | grep -q '^ok   rc 0 but the id only INSIDE' || { echo "NOT OK r7-redrive row-first"; exit 1; }
echo "OK r7-redrive row-first"
