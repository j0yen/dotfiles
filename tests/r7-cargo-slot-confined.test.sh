#!/usr/bin/env bash
# r7-cargo-slot.sh --run-confined (A1542): the script parses, the mode refuses a missing `--` with exit 2, and the selftest (PASS/FAIL cases for exit code,
# read-only $HOME, --rw dir, nested userns) runs only where a systemd user manager is reachable, else SKIP.  Run: bash tests/r7-cargo-slot-confined.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
s="$here/.local/bin/r7-cargo-slot.sh"
fail=0
bash -n "$s" && echo "PASS bash -n" || { echo "FAIL bash -n"; fail=1; }
"$s" --run-confined >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && echo "PASS --run-confined without -- exits 2" || { echo "FAIL --run-confined without -- rc=$rc want 2"; fail=1; }
"$s" --run-confined -- /nonexistent/exe >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && echo "PASS --run-confined with a missing exe exits 2" || { echo "FAIL --run-confined missing exe rc=$rc want 2"; fail=1; }
"$s" --rw /tmp -- cargo >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && echo "PASS --rw without --run-confined exits 2" || { echo "FAIL --rw alone rc=$rc want 2"; fail=1; }
st=$(systemctl --user is-system-running 2>/dev/null || true)
case $st in
  running|degraded)
    out="$("$s" --selftest 2>&1)"; rc=$?; printf '%s\n' "$out" | grep -E 'confined|SELFTEST' 
    [ $rc = 0 ] && ! grep -q '^FAIL confined' <<<"$out" && echo "PASS --selftest" || { echo "FAIL --selftest rc=$rc"; fail=1; };;
  *) echo "SKIP --selftest: no user manager reachable (is-system-running=${st:-none})";;
esac
[ $fail = 0 ] && { echo "PASS r7-cargo-slot-confined"; exit 0; }; echo "FAIL r7-cargo-slot-confined"; exit 1
