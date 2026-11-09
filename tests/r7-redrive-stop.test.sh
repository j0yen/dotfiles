#!/usr/bin/env bash
# tests/r7-redrive-stop.test.sh — r7-redrive.sh forwards --stop for every step (ctl ddf8 authorized
# `redrive 503 --from inner --stop`). wm-decide and ssh are stubbed; the ssh stub records the remote command line.
# Run: bash tests/r7-redrive-stop.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); sc="$here/../.local/bin/r7-redrive.sh"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT; fail=0
printf '#!/bin/sh\necho "$@" >> %s/ssh.log\necho queued\n' "$S" > "$S/ssh"
printf '#!/bin/sh\necho "$@" >> %s/dec.log\necho d-20261027-192500-r7-ab12\n' "$S" > "$S/dec"; chmod +x "$S/ssh" "$S/dec"
chk() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
run() { WM_DECIDE_BIN=$S/dec R7_REDRIVE_SSH=$S/ssh bash "$sc" "$@" 2>&1; }
A=(--expect inner --why w --evidence e)
out=$(bash "$sc" 2>&1); chk 'echo "$out" | grep -q "usage:.*--stop"' "usage line lists --stop"
rm -f "$S/ssh.log" "$S/dec.log"; out=$(run 503 inner "${A[@]}" --stop); rc=$?
chk '[ $rc = 0 ] && [ "$(sed "s/.*wm-build/wm-build/" "$S/ssh.log")" = "wm-build run redrive 503 --from inner --stop --operator r7" ]' "inner --stop -> exact argv"
chk 'grep -q -- "--what redrive 503 --from inner --stop --operator r7" "$S/dec.log"' "wm-decide row text carries --stop"
rm -f "$S/ssh.log"; out=$(run 503 inner --stop "${A[@]}"); rc=$?
chk '[ $rc = 0 ] && grep -q "wm-build run redrive 503 --from inner --stop --operator r7" "$S/ssh.log"' "--stop first among options works"
rm -f "$S/ssh.log"; out=$(run 479 land --expect land --why w --evidence e --after-merge --stop); rc=$?
chk '[ $rc = 0 ] && grep -q "wm-build run redrive 479 --from land --after-merge --stop --operator r7" "$S/ssh.log"' "land --after-merge --stop -> both flags reach wm-build"
rm -f "$S/ssh.log"; out=$(run 503 inner "${A[@]}"); rc=$?
chk '[ $rc = 0 ] && [ "$(sed "s/.*wm-build/wm-build/" "$S/ssh.log")" = "wm-build run redrive 503 --from inner --operator r7" ] && ! grep -q -- --stop "$S/ssh.log"' "no flag -> argv unchanged, no --stop"
[ $fail = 0 ] && echo "OK r7-redrive stop" || { echo "NOT OK r7-redrive stop"; exit 1; }
