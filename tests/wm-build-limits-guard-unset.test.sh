#!/usr/bin/env bash
# wm-build-limits-guard unset: a dead key leaves limits.lock, is commented in config.toml,
# is logged, and check/enforce stop treating it as drift; set on an unset key stays refused.
set -u
here=$(cd "$(dirname "$0")/.." && pwd); G="$here/.local/bin/wm-build-limits-guard"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T"; unset WP_STATE RW_T4R_STATE
mkdir -p "$T/.config/wm-build" "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/wm-build"; chmod +x "$T/bin/wm-build"
export PATH="$T/bin:$PATH"
L="$T/.config/wm-build/limits.lock"; C="$T/.config/wm-build/config.toml"; LOG="$T/.local/state/wm-build/limits-guard.log"
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: want [$3] got [$2]"; fi; }
lock() { printf 'box.grace_minutes=20\nbuilder.idle_minutes=20\nbox.roles.coder.max_boxes=4\nbox.roles.coder.max_leases_per_box=7\nmax_runs=2\nbuilder.type=ccx43\n' > "$L"; }
toml() { printf 'max_runs = 2\n[box]\ngrace_minutes = 20\n[builder]\nidle_minutes = 20\ntype = "ccx43"\n[box.roles.coder]\nmax_boxes = 4\nmax_leases_per_box = 7\n' > "$C"; }
rc() { "$G" "$@" >/dev/null 2>&1; echo $?; }
lock; toml

ok "unset max_boxes rc"           "$(rc unset box.roles.coder.max_boxes --by joe-x "dead")" 0
ok "lock line removed"            "$(grep -c '^box.roles.coder.max_boxes=' "$L")" 0
ok "other lock lines kept"        "$(wc -l < "$L")" 5
ok "toml line commented"          "$(grep -c '^# dead: permanent boxes only (10-11), #195: max_boxes = 4$' "$C")" 1
ok "sibling key untouched"        "$(grep -c '^max_leases_per_box = 7$' "$C")" 1
ok "unset logged"                 "$(grep -c 'limits-unset key=box.roles.coder.max_boxes by=joe-x quote="dead"' "$LOG")" 1
out=$("$G" check); crc=$?
ok "check reports unset"          "$(echo "$out" | grep -c 'key=box.roles.coder.max_boxes status=unset')" 1
ok "check has no DRIFT"           "$(echo "$out" | grep -c DRIFT):$crc" 0:0
before=$(cat "$C"); "$G" enforce >/dev/null 2>&1
ok "enforce leaves comment"       "$(cat "$C")" "$before"
ok "enforce wrote no empty value" "$(grep -c '^max_boxes' "$C")" 0
out=$("$G" unset box.roles.coder.max_boxes --by joe-x "again"); r=$?
ok "unset again already-unset"    "$out:$r" "already-unset key=box.roles.coder.max_boxes:0"
cl=$(cat "$L"); cc=$(cat "$C")
ok "watcher unset refused"        "$(rc unset box.roles.coder.max_leases_per_box --by watcher:rb-reprice-watch "q")" 1
ok "ctl unset refused"            "$(rc unset box.roles.coder.max_leases_per_box --by ctl "q")" 1
ok "unknown key refused"          "$(rc unset nope --by joe-x "q")" 1
ok "files unchanged after refusals" "$(cat "$L" "$C" | md5sum)" "$(printf '%s\n%s\n' "$cl" "$cc" | md5sum)"
ok "set on unset key refused"     "$(rc set box.roles.coder.max_boxes=2 --by joe-x "q")" 1
ok "set on live key still works"  "$(rc set max_runs=3 --by joe-x "q")" 0
echo "pass=$pass fail=$fail"; [ "$fail" = 0 ]
