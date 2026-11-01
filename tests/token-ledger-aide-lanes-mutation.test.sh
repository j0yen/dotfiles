#!/usr/bin/env bash
# tests/token-ledger-aide-lanes-mutation.test.sh — proves tests/token-ledger-aide-lanes.test.sh catches a planted regression on a main-only day.
# The lanes test compares the new token-ledger with main's token-ledger byte for byte; a base that is the in-tree copy (no main ref) compares the code with itself and passes any regression.
# Mutation: build-share.json excluded_weighted gets +1 (main-only day: compared via jq -S in the lanes test, asserted nowhere else). Everything happens in a throwaway clone.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_SHA=fa5df101046f1aa43c329ba863da21ee145ca655
work="$(mktemp -d "${TMPDIR:-/tmp}/tl-mutation.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail=0
git clone --no-local -q "$here/.." "$work/clone" || { echo "NOT OK - mutation: clone failed"; exit 1; }
g() { git -C "$work/clone" "$@"; }
sed -i 's/excluded_weighted: \$excl,/excluded_weighted: ($excl + 1),/' "$work/clone/.local/bin/token-ledger"
if cmp -s "$here/../.local/bin/token-ledger" "$work/clone/.local/bin/token-ledger"; then echo "NOT OK - mutation: plant did not change token-ledger"; exit 1; fi
g -c user.name=mut -c user.email=mut@example.invalid commit -q -am "planted regression: excluded_weighted + 1" || { echo "NOT OK - mutation: commit failed"; exit 1; }

# Case A: main ref present -> the byte-for-byte compare against main must catch it
g update-ref refs/remotes/origin/main "$BASE_SHA"
outA="$(bash "$work/clone/tests/token-ledger-aide-lanes.test.sh" 2>&1)"; rcA=$?
if [ "$rcA" -ne 0 ] && grep -q '^NOT OK' <<<"$outA"; then echo "ok - ref present: planted regression caught (rc=$rcA)"
else echo "NOT OK - ref present: planted regression not caught (rc=$rcA)"; fail=1; fi

# Case B: no main ref -> must still fail (regression or missing-ref NOT OK), never pass by self-comparison
g update-ref -d refs/remotes/origin/main
g update-ref -d refs/heads/main
outB="$(bash "$work/clone/tests/token-ledger-aide-lanes.test.sh" 2>&1)"; rcB=$?
if [ "$rcB" -ne 0 ] && grep -q '^NOT OK' <<<"$outB"; then echo "ok - no main ref: lanes test fails instead of self-comparing (rc=$rcB)"
else echo "NOT OK - no main ref: lanes test passed without a base (rc=$rcB)"; fail=1; fi
exit $fail
