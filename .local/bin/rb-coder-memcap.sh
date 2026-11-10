#!/usr/bin/env bash
# rb-coder-memcap.sh: set the calling coder's own systemd user unit to MemoryHigh/MemoryMax/TasksMax (default infinity) and prove it by reading the cgroup back.
# rb 11-02 first capped coders at 12G/14G (Fable CORRECT fcdf/05b3); Hermes row d-20261109-125934-hermes-98a1 lifted the finite memory caps and
# ask A1483 r6 makes this wrapper stop re-creating them (it also sets TasksMax=infinity; a transient unit otherwise inherits the user slice's 33183).
# Called by rb-run-coder.sh just before `claude -p`; the caller records a NO as WARN and continues (no exit 71). Prints one line and exits:
#   `memcap ok: unit=U high=<v> max=<v> tasks=<v>` rc 0 | `memcap NO: <why>` rc 3 (not in a .service unit, set-property failed, cgroup differs from the request).
# env: RB_CODER_MEM_HIGH, RB_CODER_MEM_MAX, RB_CODER_TASKS_MAX (all infinity), RB_CODER_CGROUP_FILE (/proc/self/cgroup), RB_CODER_CGROUP_ROOT (/sys/fs/cgroup); tests: tests/rb-coder-memcap.test.sh.
set -uo pipefail
high="${RB_CODER_MEM_HIGH:-infinity}"; max="${RB_CODER_MEM_MAX:-infinity}"; tasks="${RB_CODER_TASKS_MAX:-infinity}"
cgp=$(sed -n 's|^0::||p' "${RB_CODER_CGROUP_FILE:-/proc/self/cgroup}" 2>/dev/null | head -n 1)
unit=${cgp##*/}
case "$unit" in *.service) ;; *) echo "memcap NO: not in a .service unit (cgroup=${cgp:-none})"; exit 3 ;; esac
if ! sp=$(timeout 20 systemctl --user set-property --runtime "$unit" MemoryHigh="$high" MemoryMax="$max" TasksMax="$tasks" 2>&1); then
  echo "memcap NO: set-property $unit failed: $(printf '%s\n' "$sp" | head -n 1)"; exit 3
fi
d="${RB_CODER_CGROUP_ROOT:-/sys/fs/cgroup}$cgp"
rh=$(cat "$d/memory.high" 2>/dev/null); rm=$(cat "$d/memory.max" 2>/dev/null); rt=$(cat "$d/pids.max" 2>/dev/null)
# a requested `infinity` reads back as `max`; any other request must read back as a number
chk() { if [ "$1" = infinity ]; then [ "$2" = max ]; else [[ $2 =~ ^[0-9]+$ ]]; fi; }
if ! { chk "$high" "$rh" && chk "$max" "$rm" && chk "$tasks" "$rt"; }; then echo "memcap NO: $unit cgroup reads high=${rh:-none} max=${rm:-none} tasks=${rt:-none}"; exit 3; fi
echo "memcap ok: unit=$unit high=$rh max=$rm tasks=$rt"
