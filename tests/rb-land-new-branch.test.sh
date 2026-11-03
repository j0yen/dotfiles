#!/usr/bin/env bash
# tests/rb-land-new-branch.test.sh -- A537: the land wrapper accepts a branch absent on origin (old=empty) when the CONFIRM row names the branch,
# and still refuses (fetch-failed) when it does not. Runs the wrapper's own --selftest (throwaway HOME, fake ssh, bare origin; no network, no sudo).
# Plain bash, run from the repo root:  bash tests/rb-land-new-branch.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrap="${RB_LAND_UNDER_TEST:-$here/.local/bin/rb-land-push.sh}"
out=$(bash "$wrap" --selftest 2>&1); rc=$?
fail=0
for c in "new-branch-named" "new-branch-unnamed"; do
  if printf '%s\n' "$out" | grep -q "^ok - $c\$"; then echo "ok - rb-land-new-branch: $c"; else echo "NOT OK - rb-land-new-branch: $c (case missing or failing)"; fail=1; fi
done
[ $rc = 0 ] || { echo "NOT OK - rb-land-new-branch: selftest rc=$rc"; fail=1; }
exit $fail
