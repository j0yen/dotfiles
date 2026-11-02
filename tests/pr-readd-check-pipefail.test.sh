#!/usr/bin/env bash
# pr-readd-check.sh: a failing `git diff` must exit 2 (fails closed), never read as "none found" (A350).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
CHK="${CHK:-$here/.local/bin/pr-readd-check.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
nok() { echo "NOT OK - $1"; fail=$((fail+1)); }
R="$T/r"; git init -q -b main "$R"
G() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
echo base >"$R/base.txt"; G add -A; G commit -q -m init
G checkout -q -b pr; echo y >"$R/new.txt"; G add -A; G commit -q -m "pr adds"
G checkout -q main
# both refs resolve as commits, but the PR head's tree object is gone, so `git diff` fails
tree=$(G rev-parse pr^{tree})
rm -f "$R/.git/objects/${tree:0:2}/${tree:2}"
out=$("$CHK" "$R" pr main 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "failed git diff exits 2 (rc=$rc)"; else nok "failed git diff rc=$rc want 2 out: $out"; fi
if grep -q "git diff failed" <<<"$out"; then ok "git error reported"; else nok "git error not reported, out: $out"; fi
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
