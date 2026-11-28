#!/usr/bin/env bash
# A1304 W11 H6/D12: r7-cargo-slot.sh's slot scope carries TasksMax=infinity and no Memory* property (Joe no-caps authority #195,
# as rb's cargo-slot.sh), its expired date trigger is replaced by its condition (no new date), and premises (a) daemon-gate
# admission and (b) the bwrap sandbox stay. Static checks always run; SCOPE_LIVE=1 also starts ONE harmless real transient
# scope (`sh -c cat`) with exactly the script's scope properties and reads the kernel's effective pids.max / memory.max.
# usage: tests/r7-cargo-slot-scope-props.test.sh [path/to/r7-cargo-slot.sh]   (default: this tree's copy; pass an older copy for the RED control)
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"; S=${1:-$R/.local/bin/r7-cargo-slot.sh}; fail=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
[ -r "$S" ] || { echo "FAIL no script $S"; exit 1; }
line=$(grep -E '^[[:space:]]*systemd-run --user --scope ' "$S")
[ "$(printf '%s\n' "$line" | grep -c .)" = 1 ] && ok "one slot scope launch line" || bad "slot scope launch lines: $(printf '%s\n' "$line" | grep -c .)"
props=$(printf '%s\n' "$line" | sed -E 's/.*--quiet (.*) nice -n .*/\1/')
echo "scope props: $props"
case " $props " in *" -p TasksMax=infinity "*) ok "scope carries TasksMax=infinity";; *) bad "scope lacks TasksMax=infinity (manager DefaultTasksMax applies)";; esac
if printf '%s\n' "$props" | grep -qE 'Memory(High|Max|SwapMax|Min|Low)='; then bad "scope carries a Memory* property"; else ok "scope carries no Memory* property"; fi
exp=$(grep -E '^# EXPIRES:' "$S")
if printf '%s\n' "$exp" | grep -qE '20[0-9]{2}-[0-9]{2}-[0-9]{2}'; then bad "EXPIRES carries a date trigger: $exp"; else ok "EXPIRES is condition-only"; fi
printf '%s\n' "$exp" | grep -q 'bwrap sandbox' && ok "EXPIRES condition keeps the sandbox premise" || bad "EXPIRES condition drops the sandbox premise"
grep -qE '^[[:space:]]*sandbox_exec --tmpfs-gb ' "$S" && grep -qF 'Never an unsandboxed fallback' "$S" && ok "premise (b): inner path runs through sandbox_exec" || bad "premise (b) sandbox path missing"
grep -B1 -E '^[[:space:]]*systemd-run --user --scope ' "$S" | grep -qE 'builder cargo-jobs acquire .*-- \\$' && ok "premise (a): scope runs only under the daemon acquire" || bad "premise (a): acquire does not wrap the scope"
grep -qE '\$\{?HIGH' "$S" && bad "dangling HIGH reference" || ok "no dangling HIGH reference"
bash -n "$S" && ok "bash -n" || bad "bash -n"
if [ "${SCOPE_LIVE:-0}" = 1 ]; then
  lp=$(printf '%s\n' "$props" | sed -e 's/\${HIGH}/10/g' -e 's/\${CAP}/12/g')
  # shellcheck disable=SC2086
  o=$(systemd-run --user --scope --slice=app.slice --quiet $lp -- sh -c 'c=$(sed -n "s/^0:://p" /proc/self/cgroup); echo "cg=$c pids.max=$(cat /sys/fs/cgroup$c/pids.max) memory.max=$(cat /sys/fs/cgroup$c/memory.max) memory.high=$(cat /sys/fs/cgroup$c/memory.high)"' 2>&1)
  echo "live scope: $o"
  case "$o" in *"pids.max=max memory.max=max memory.high=max"*) ok "live fresh scope: pids.max=max memory.max=max memory.high=max";; *) bad "live fresh scope not unlimited: $o";; esac
fi
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit $fail
