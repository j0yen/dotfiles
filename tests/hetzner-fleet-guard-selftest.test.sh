#!/usr/bin/env bash
# The tracked Hetzner fixed-fleet guard has a hermetic --selftest (no token, no API, no delete); it must pass.
set -u
G="$(cd "$(dirname "$0")/.." && pwd)/.local/bin/hetzner-fixed-fleet-guard.sh"
fail=0
out=$(bash "$G" --selftest 2>&1); rc=$?
printf '%s\n' "$out"
if [ "$rc" -eq 0 ]; then echo "ok - --selftest rc 0"; else echo "NOT OK - --selftest rc $rc"; fail=1; fi
n=$(printf '%s\n' "$out" | grep -c '^PASS ')
if [ "$n" -eq 4 ]; then echo "ok - 4 PASS lines"; else echo "NOT OK - expected 4 PASS lines, got $n"; fail=1; fi
exit "$fail"
