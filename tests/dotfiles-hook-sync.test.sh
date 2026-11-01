#!/usr/bin/env bash
# dotfiles-hook-sync.test.sh - dotfiles-hook-sync.sh --selftest (throwaway HOME + fixture repo: real file kept, pull guard, unresolved,
# idempotence, expiry) plus the PREMISE/EXPIRES header lines and the unit pair's shape. Never touches the real HOME's hooks.
# shellcheck disable=SC2015  # pass/bad helpers never fail, so A && pass || bad is an if-else
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../.local/bin/dotfiles-hook-sync.sh
unit=$here/../.config/systemd/user
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

bash -n "$script" && pass "bash -n" || bad "bash -n"
[ -x "$script" ] && pass "script is executable" || bad "script is not executable"
grep -q '^# PREMISE: settings.json registers hooks by absolute path and a pull does not install them$' "$script" && grep -q '^# EXPIRES: 2027-01-31' "$script" \
  && pass "PREMISE + EXPIRES header lines" || bad "PREMISE/EXPIRES header lines"

if out=$("$script" --selftest 2>&1); then pass "selftest ($(printf '%s\n' "$out" | tail -n1))"; else
  bad "selftest"; printf '%s\n' "$out" | tail -n 25
fi
for c in '(i)' '(ii)' '(iii)' '(iv)' '(v)'; do
  printf '%s\n' "${out:-}" | grep -qF "selftest $c ok" && pass "selftest case $c reported" || bad "selftest case $c missing"
done

"$script" --bogus >/dev/null 2>&1; [ $? -eq 64 ] && pass "unknown flag -> 64" || bad "unknown flag -> 64"

t=$unit/dotfiles-hook-sync.timer s=$unit/dotfiles-hook-sync.service
grep -qx 'OnBootSec=3min' "$t" && grep -qx 'OnUnitActiveSec=10min' "$t" && grep -qx 'WantedBy=timers.target' "$t" \
  && pass "timer: OnBootSec=3min OnUnitActiveSec=10min" || bad "timer fields"
grep -qx 'Type=oneshot' "$s" && grep -qx 'ExecStart=%h/.local/bin/dotfiles-hook-sync.sh' "$s" && pass "service: oneshot running dotfiles-hook-sync.sh" || bad "service fields"

[ "$fail" -eq 0 ] && echo "dotfiles-hook-sync: ALL PASS" || echo "dotfiles-hook-sync: FAILED"
exit "$fail"
