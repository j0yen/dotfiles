#!/usr/bin/env bash
# pr-readd-check.sh: amendment 6 shape (branch re-adds a path main deleted after the merge base).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
CHK="$here/.local/bin/pr-readd-check.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
nok() { echo "NOT OK - $1"; fail=$((fail+1)); }
G() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
commit() { G add -A && G commit -q -m "$1"; }
new_repo() { R="$T/$1"; git init -q -b main "$R"; echo base >"$R/base.txt"; commit init; }
expect() { # name want_rc want_pattern pr_ref [main_ref]
  local out rc
  out=$("$CHK" "$R" "${@:4}" 2>&1); rc=$?
  if [ "$rc" -eq "$2" ] && { [ -z "$3" ] || grep -q -- "$3" <<<"$out"; }; then ok "$1 (rc=$rc)"; else nok "$1 (rc=$rc want $2) out: $out"; fi
}

# 1. amendment 6 shape
new_repo a
G branch old                       # branch point predates the add
echo x >"$R/dropin.conf"; commit "add dropin"
G rm -q dropin.conf; commit "delete dropin"; del=$(G rev-parse --short HEAD)
G checkout -q old; echo x >"$R/dropin.conf"; commit "pr adds dropin"
G checkout -q main
expect "re-add reported" 3 "RE-ADD dropin.conf deleted-on-main-by $del delete dropin" old main

# 2. healthy branch
new_repo b
G checkout -q -b pr; echo y >"$R/new.txt"; commit "pr work"; G checkout -q main
echo z >"$R/other.txt"; commit "main work"
expect "healthy branch" 0 "" pr main

# 3. branch adds a path main never had (main deleted a different file)
new_repo c
G checkout -q -b pr; echo y >"$R/never.txt"; commit "pr adds"; G checkout -q main
echo q >"$R/gone.txt"; commit "add gone"; G rm -q gone.txt; commit "del gone"
expect "path main never had" 0 "" pr main

# 4. main deletes then re-adds: ok; deleted again: RE-ADD
new_repo d
G branch pr
echo x >"$R/f.conf"; commit "add f"; G rm -q f.conf; commit "del f"
echo x >"$R/f.conf"; commit "re-add f"
G checkout -q pr; echo x >"$R/f.conf"; commit "pr adds f"; G checkout -q main
expect "main re-added path" 0 "" pr main
G rm -q f.conf; commit "del f again"
expect "main deleted again" 3 "RE-ADD f.conf" pr main

# 5. errors fail closed
expect "bad pr ref" 2 "bad ref" nosuchref main
expect "bad main ref" 2 "bad ref" pr nosuchmain
"$CHK" >/dev/null 2>&1; rc=$?; [ $rc -eq 2 ] && ok "usage (rc=2)" || nok "usage rc=$rc"
"$CHK" "$T" pr >/dev/null 2>&1; rc=$?; [ $rc -eq 2 ] && ok "not a repo (rc=2)" || nok "not a repo rc=$rc"

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
