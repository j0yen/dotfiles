#!/usr/bin/env bash
# tests/r7-redrive-after-merge.test.sh — r7-redrive.sh forwards --after-merge only for --from land (479/#534
# "already merged -- resume with --after-merge"). wm-decide and ssh are stubbed; the ssh stub records the remote
# command line (which carries the wm-build argv). Run: bash tests/r7-redrive-after-merge.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); sc="$here/../.local/bin/r7-redrive.sh"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT; fail=0
printf '#!/bin/sh\necho "$@" >> %s/ssh.log\necho queued\n' "$S" > "$S/ssh"
printf '#!/bin/sh\necho d-20261027-192500-r7-ab12\n' > "$S/dec"; chmod +x "$S/ssh" "$S/dec"
chk() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
run() { WM_DECIDE_BIN=$S/dec R7_REDRIVE_SSH=$S/ssh bash "$sc" "$@" 2>&1; }
A=(--expect land --why w --evidence e)
out=$(bash "$sc" 2>&1); chk 'echo "$out" | grep -q "usage:.*--after-merge"' "usage line lists --after-merge"
rm -f "$S/ssh.log"; out=$(run 479 land "${A[@]}" --after-merge); rc=$?
chk '[ $rc = 0 ] && grep -q "wm-build run redrive 479 --from land --after-merge --operator r7" "$S/ssh.log"' "land --after-merge -> wm-build run redrive 479 --from land --after-merge --operator r7"
rm -f "$S/ssh.log"; out=$(run 479 land --after-merge "${A[@]}"); rc=$?
chk '[ $rc = 0 ] && grep -q -- "--from land --after-merge --operator r7" "$S/ssh.log"' "flag position first among options works"
rm -f "$S/ssh.log"; out=$(run 479 inner "${A[@]}" --after-merge); rc=$?
chk '[ $rc != 0 ] && [ ! -e "$S/ssh.log" ] && echo "$out" | grep -q "after-merge only applies"' "inner --after-merge -> refused, ssh/wm-build never called"
rm -f "$S/ssh.log"; out=$(run 479 land "${A[@]}"); rc=$?
chk '[ $rc = 0 ] && grep -q "wm-build run redrive 479 --from land --operator r7" "$S/ssh.log" && ! grep -q after-merge "$S/ssh.log"' "land without flag -> argv unchanged"
[ $fail = 0 ] && echo "OK r7-redrive after-merge" || { echo "NOT OK r7-redrive after-merge"; exit 1; }
