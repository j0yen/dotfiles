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

grep -q '^CHAIN_MARKER=.# live-clone-guard-chain' "$script" && pass "script defines the chain marker '# live-clone-guard-chain'" || bad "chain marker missing"
grep -q 'inert-hookspath' "$script" && pass "ensure has the inert-hookspath status" || bad "inert-hookspath missing"

# end to end: a repo with core.hooksPath set and no chaining pre-commit -> check 1 + ensure inert-hookspath exit 6; with a chain -> 0 and refused
r="$h/repo"; hp="$h/hp"; mkdir -p "$hp" "$h/.config/live-clone-guard"
(export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
 git init -q "$r" && git -C "$r" commit -q --allow-empty -m init && git -C "$r" config core.hooksPath "$hp") 
printf '%s\n' "$r" > "$h/.config/live-clone-guard/repos"
out=$(HOME="$h" XDG_CONFIG_HOME="$h/.config" "$script" ensure 2>&1); rc=$?
{ [ $rc -eq 6 ] && grep -q ' inert-hookspath$' <<<"$out"; } && pass "ensure: hooksPath without chain -> inert-hookspath, exit 6" || bad "ensure inert rc=$rc out=$out"
HOME="$h" "$script" check "$r" >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && pass "check: hooksPath without chain -> 1" || bad "check inert rc=$rc"
printf '#!/bin/sh\n# live-clone-guard-chain\nh="$(git rev-parse --git-common-dir)/hooks/pre-commit"\n[ -x "$h" ] && exec "$h" "$@"\nexit 0\n' > "$hp/pre-commit"; chmod 755 "$hp/pre-commit"
HOME="$h" "$script" check "$r" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && pass "check: chained hooksPath -> 0" || bad "check chained rc=$rc"
out=$(GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -C "$r" commit --allow-empty -m x 2>&1); rc=$?
{ [ $rc -eq 1 ] && grep -q 'live-clone guard' <<<"$out"; } && pass "commit in the live clone refused through the chain" || bad "chain commit rc=$rc out=$out"
rm -f "$h/.config/live-clone-guard/repos"

# ensure with no config under the throwaway HOME is a silent no-op
out=$(HOME="$h" XDG_CONFIG_HOME="$h/.config" "$script" ensure 2>&1); rc=$?
{ [ $rc -eq 0 ] && [ -z "$out" ]; } && pass "ensure without a config is silent, exit 0" || bad "ensure no-config rc=$rc out=$out"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
