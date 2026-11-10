#!/usr/bin/env bash
# r7-cargo-slot-confined.test.sh - bash -n, --run-confined usage exit 2, and --selftest only when a user manager is reachable (else SKIP, exit 0).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../.local/bin/r7-cargo-slot.sh
fail=0
if bash -n "$script"; then echo "PASS: bash -n"; else echo "FAIL: bash -n"; fail=1; fi
if [ -r /home/jsy/.local/lib/hand-sandbox.sh ]; then
  out=$("$script" --run-confined 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && grep -q -- '--run-confined' <<<"$out"; then echo "PASS: no -- exits 2 with usage"; else echo "FAIL: no -- rc=$rc out=$out"; fail=1; fi
  out=$("$script" --run-confined -- /nonexistent/exe 2>&1); rc=$?
  if [ "$rc" -eq 2 ]; then echo "PASS: missing exe exits 2"; else echo "FAIL: missing exe rc=$rc out=$out"; fail=1; fi
else echo "SKIP: usage checks (sandbox lib absent, not a ryzen7 slot host)"; fi
st=$(systemctl --user is-system-running 2>/dev/null)
case $st in
  running|degraded) if [ -r /home/jsy/.local/lib/hand-sandbox.sh ]; then
      out=$("$script" --selftest 2>&1); rc=$?; grep -E '^(PASS|FAIL|SKIP) confined' <<<"$out"
      if [ "$rc" -eq 0 ]; then echo "PASS: --selftest"; else echo "FAIL: --selftest rc=$rc"; fail=1; fi
    else echo "SKIP: --selftest (sandbox lib absent)"; fi;;
  *) echo "SKIP: --selftest (no user manager, is-system-running=${st:-none})";;
esac
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
