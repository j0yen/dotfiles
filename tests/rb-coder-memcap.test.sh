#!/usr/bin/env bash
# rb-coder-memcap.test.sh - memcap: .local/bin/rb-coder-memcap.sh, cases a-h. Hermetic: fixture cgroup file + cgroup root, stub systemctl on PATH;
# no real unit is touched. Defaults are infinity (d-20261109-125934-hermes-98a1, A1483). The rb-run-coder.sh side (WARN, no exit 71) is cases mc1-mc2 of tests/rb-run-coder-room.test.sh.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mc=${RB_CODER_MEMCAP_UNDER_TEST:-$here/../.local/bin/rb-coder-memcap.sh}
fail=0; npass=0
pass() { npass=$((npass+1)); echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
R=$(mktemp -d "${TMPDIR:-/tmp}/rb-coder-memcap-test.XXXXXX") || exit 2
trap 'case "$R" in */rb-coder-memcap-test.*) rm -rf "$R";; esac' EXIT

# case <name> <cgroup-line> <systemctl-rc> <memory.high> <memory.max> [env...]; pids.max reads $PM (default max); sets C (case dir), out, rc
case_() {
  local name=$1 cgl=$2 src=$3 mh=$4 mm=$5; shift 5
  C=$R/$name; mkdir -p "$C/bin" "$C/root/user.slice/app.slice/rb-coder-t.service" "$C/root/user.slice/tmux.scope"
  printf '%s\n' "$cgl" > "$C/cgroup"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/systemctl.argv"\nexit %s\n' "$C" "$src" > "$C/bin/systemctl"; chmod +x "$C/bin/systemctl"
  for d in "$C/root/user.slice/app.slice/rb-coder-t.service" "$C/root/user.slice/tmux.scope"; do
    [ "$mh" = - ] || printf '%s\n' "$mh" > "$d/memory.high"; [ "$mm" = - ] || printf '%s\n' "$mm" > "$d/memory.max"; printf '%s\n' "${PM:-max}" > "$d/pids.max"; done
  out=$(env PATH="$C/bin:$PATH" RB_CODER_CGROUP_FILE="$C/cgroup" RB_CODER_CGROUP_ROOT="$C/root" "$@" bash "$mc" 2>&1); rc=$?
}
svc='0::/user.slice/app.slice/rb-coder-t.service'

# (a) service unit, set-property ok, cgroup reads max -> rc 0, ok line, argv carries MemoryHigh/MemoryMax/TasksMax=infinity
case_ a "$svc" 0 max max
argv=$(cat "$C/systemctl.argv" 2>/dev/null)
[ $rc = 0 ] && [ "$out" = "memcap ok: unit=rb-coder-t.service high=max max=max tasks=max" ] \
  && [ "$argv" = "--user set-property --runtime rb-coder-t.service MemoryHigh=infinity MemoryMax=infinity TasksMax=infinity" ] \
  && pass "(a) ok -> '$out'" || bad "(a) rc=$rc out='$out' argv='$argv'"
# (b) scope cgroup (not a service) -> rc 3, systemctl never called
case_ b '0::/user.slice/tmux.scope' 0 max max
[ $rc = 3 ] && [[ $out == "memcap NO: not in a .service unit"* ]] && [ ! -e "$C/systemctl.argv" ] && pass "(b) scope -> rc=3 '$out'" || bad "(b) rc=$rc out='$out'"
# (c) set-property fails -> rc 3
case_ c "$svc" 1 max max
[ $rc = 3 ] && [[ $out == "memcap NO: set-property rb-coder-t.service failed"* ]] && pass "(c) set-property rc=1 -> rc=3" || bad "(c) rc=$rc out='$out'"
# (d) set-property claims success but the cgroup still reads a finite memory.high -> rc 3
case_ d "$svc" 0 12884901888 max
[ $rc = 3 ] && [ "$out" = "memcap NO: rb-coder-t.service cgroup reads high=12884901888 max=max tasks=max" ] && pass "(d) finite readback -> rc=3" || bad "(d) rc=$rc out='$out'"
# (e) cgroup file missing -> rc 3
case_ e "$svc" 0 max max RB_CODER_CGROUP_FILE="$R/none"
[ $rc = 3 ] && [ "$out" = "memcap NO: not in a .service unit (cgroup=none)" ] && pass "(e) no cgroup file -> rc=3" || bad "(e) rc=$rc out='$out'"
# (f) finite overrides reach set-property and read back as numbers; missing memory.high file -> rc 3
case_ f "$svc" 0 - 15032385536 RB_CODER_MEM_HIGH=8G RB_CODER_MEM_MAX=10G
argv=$(cat "$C/systemctl.argv" 2>/dev/null)
[ $rc = 3 ] && [[ $argv == *"MemoryHigh=8G MemoryMax=10G TasksMax=infinity" ]] && [[ $out == *"high=none"* ]] && pass "(f) overrides in argv, missing memory.high -> rc=3" || bad "(f) rc=$rc out='$out' argv='$argv'"
# (g) pids.max still finite (inherited slice default 33183) -> rc 3
PM=33183 case_ g "$svc" 0 max max
[ $rc = 3 ] && [ "$out" = "memcap NO: rb-coder-t.service cgroup reads high=max max=max tasks=33183" ] && pass "(g) finite pids.max -> rc=3" || bad "(g) rc=$rc out='$out'"
# (h) RB_CODER_TASKS_MAX override reaches argv
case_ h "$svc" 0 max max RB_CODER_TASKS_MAX=5000
argv=$(cat "$C/systemctl.argv" 2>/dev/null)
[[ $argv == *"TasksMax=5000" ]] && [ $rc = 3 ] && pass "(h) RB_CODER_TASKS_MAX=5000 in argv (pids.max max != 5000 -> rc=3)" || bad "(h) rc=$rc argv='$argv' out='$out'"

echo "pass=$npass fail=$fail"
[ $fail = 0 ] && echo "ALL PASS ($npass checks)"
exit $fail
