#!/usr/bin/env bash
# live-clone-guard.test.sh - runs live-clone-guard.sh --selftest under a throwaway HOME and pins the two load-bearing
# lines of the hook (marker + the worktree pass-through) so a rewrite cannot silently drop them.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../.local/bin/live-clone-guard.sh
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

h=$(mktemp -d "${TMPDIR:-/tmp}/lcg-test-home.XXXXXX")
trap 'rm -rf "$h"' EXIT

if out=$(HOME="$h" XDG_CONFIG_HOME="$h/.config" "$script" --selftest 2>&1); then pass "selftest ($(printf '%s\n' "$out" | tail -n1))"
else bad "selftest"; printf '%s\n' "$out" | tail -n 25; fi

grep -q '^MARKER=.# live-clone-guard' "$script" && pass "script defines the marker line '# live-clone-guard'" || bad "marker line missing"
grep -qF 'rev-parse --show-toplevel' "$script" && pass "hook passes through when rev-parse --show-toplevel is not the live path" || bad "rev-parse --show-toplevel missing"

# ensure with no config under the throwaway HOME is a silent no-op
out=$(HOME="$h" XDG_CONFIG_HOME="$h/.config" "$script" ensure 2>&1); rc=$?
{ [ $rc -eq 0 ] && [ -z "$out" ]; } && pass "ensure without a config is silent, exit 0" || bad "ensure no-config rc=$rc out=$out"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
