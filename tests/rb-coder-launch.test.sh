#!/usr/bin/env bash
# rb-coder-launch.sh refuses a RedBaron coder spawn below the room floors (fed a fixed room read, no ssh).
set -u; s="$(dirname "$0")/../.local/bin/rb-coder-launch.sh"; f=0
RB_ROOM_READ="10 5 1 0 0" bash "$s" t1 --dry-run >/dev/null; [ $? -eq 2 ] || { echo "FAIL low mem not refused"; f=1; }
RB_ROOM_READ="23 55 1 0 0" bash "$s" t2 --dry-run >/dev/null; [ $? -eq 2 ] || { echo "FAIL psi io not refused"; f=1; }
RB_ROOM_READ="23 5 12 0 0" bash "$s" t3 --dry-run >/dev/null; [ $? -eq 2 ] || { echo "FAIL psi mem not refused"; f=1; }
RB_ROOM_READ="23 5 1 3 0" bash "$s" t4 --dry-run >/dev/null; [ $? -eq 2 ] || { echo "FAIL 3 coders not refused"; f=1; }
out=$(RB_ROOM_READ="23 26.3 0.33 1 1" bash "$s" t5 --dry-run); [ $? -eq 0 ] && grep -q "ROOM OK" <<<"$out" || { echo "FAIL room ok path"; f=1; }
[ $f -eq 0 ] && echo "PASS rb-coder-launch 5/5"; exit $f
