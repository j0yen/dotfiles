#!/usr/bin/env bash
# tests/verifier-low-priority.test.sh: every aide-verifier transient unit runs low priority (CPUWeight=20, Nice=10, IOWeight=20) and the land driver's verifier pytest uses 2 xdist workers.
# Stubs only (fake systemd-run in --selftest, pure-function selftest of the driver). Run: bash tests/verifier-low-priority.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); bin="$here/../.local/bin"
fail=0; pass() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
th=$(mktemp -d "${TMPDIR:-/tmp}/vlp-test.XXXXXX"); trap 'rm -rf "$th"' EXIT
grep -E '"\$SD_RUN" --user --unit "\$unit"' "$bin/aide-verifier.sh" | grep -q -- '-p CPUWeight=20' && grep -E '"\$SD_RUN" --user --unit' "$bin/aide-verifier.sh" | grep -q -- '-p Nice=10' && pass "launch line carries CPUWeight=20 and Nice=10" || bad "launch line lacks CPUWeight=20/Nice=10"
out=$(HOME="$th" bash "$bin/aide-verifier.sh" --selftest 2>&1)
printf '%s\n' "$out" | grep -F 'PASS ' | grep -qF 'the unit launch carries CPUWeight=20 Nice=10 IOWeight=20' && pass "selftest: fake systemd-run received the properties" || { bad "selftest case missing or failing"; printf '%s\n' "$out" | grep '^FAIL' | head -n 5; }
printf '%s\n' "$out" | grep -q '^FAIL' && bad "aide-verifier selftest has a FAIL line" || pass "aide-verifier selftest has no FAIL line"
out=$(HOME="$th" bash "$bin/hand-pr-land-driver.sh" --selftest 2>&1)
printf '%s\n' "$out" | grep -F 'PASS ' | grep -qF 'verifier pytest runs 2 xdist workers' && pass "driver selftest: suite ends -n 2" || bad "driver selftest case missing or failing"
printf '%s\n' "$out" | grep -q '^FAIL' && bad "driver selftest has a FAIL line" || pass "driver selftest has no FAIL line"
grep -q -- ' -n 4' "$bin/hand-pr-land-driver.sh" && bad "driver still mentions -n 4" || pass "no -n 4 left in the driver"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
