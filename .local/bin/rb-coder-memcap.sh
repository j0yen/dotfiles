#!/usr/bin/env bash
# rb-coder-memcap.sh: cap the calling coder's own systemd user unit at MemoryHigh/MemoryMax and prove it by reading the cgroup back.
# rb 11-02, Fable CORRECT fcdf/05b3: coders ran on redbaron with MemoryMax=infinity while RB rang OOM bells (6:21/7:00 AM 11-02).
# Called by rb-run-coder.sh just before `claude -p` (memcap gate, exit 71). Prints one line and exits:
#   `memcap ok: unit=U high=<bytes> max=<bytes>` rc 0 | `memcap NO: <why>` rc 3 (not in a .service unit, set-property failed, cgroup reads `max`).
# env: RB_CODER_MEM_HIGH (12G), RB_CODER_MEM_MAX (14G), RB_CODER_CGROUP_FILE (/proc/self/cgroup), RB_CODER_CGROUP_ROOT (/sys/fs/cgroup); tests: tests/rb-coder-memcap.test.sh.
set -uo pipefail
high="${RB_CODER_MEM_HIGH:-12G}"; max="${RB_CODER_MEM_MAX:-14G}"
cgp=$(sed -n 's|^0::||p' "${RB_CODER_CGROUP_FILE:-/proc/self/cgroup}" 2>/dev/null | head -n 1)
unit=${cgp##*/}
case "$unit" in *.service) ;; *) echo "memcap NO: not in a .service unit (cgroup=${cgp:-none})"; exit 3 ;; esac
if ! sp=$(timeout 20 systemctl --user set-property --runtime "$unit" MemoryHigh="$high" MemoryMax="$max" 2>&1); then
  echo "memcap NO: set-property $unit failed: $(printf '%s\n' "$sp" | head -n 1)"; exit 3
fi
d="${RB_CODER_CGROUP_ROOT:-/sys/fs/cgroup}$cgp"
rh=$(cat "$d/memory.high" 2>/dev/null); rm=$(cat "$d/memory.max" 2>/dev/null)
if ! [[ $rh =~ ^[0-9]+$ && $rm =~ ^[0-9]+$ ]]; then echo "memcap NO: $unit cgroup reads high=${rh:-none} max=${rm:-none}"; exit 3; fi
echo "memcap ok: unit=$unit high=$rh max=$rm"
