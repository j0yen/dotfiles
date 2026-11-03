#!/usr/bin/env bash
# rb-restart-precheck.sh (A630): rc 0 when only MainPID sits in the wm-build.service
# cgroup, rc 1 naming every other pid, rc 2 when the cgroup cannot be read.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../.local/bin/rb-restart-precheck.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
chk () { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fail=1; fi; }

fake_systemctl () { printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$tmp/systemctl"; chmod +x "$tmp/systemctl"; }
fake_cgls () { # $1 = rc, rest = tree lines
  local rc=$1; shift
  { printf '#!/usr/bin/env bash\n'; printf 'cat <<"T"\n'; printf '%s\n' "$@"; printf 'T\nexit %s\n' "$rc"; } > "$tmp/cgls"
  chmod +x "$tmp/cgls"
}
run () { out="$(RBP_SYSTEMCTL="$tmp/systemctl" RBP_CGLS="$tmp/cgls" bash "$sut" 2>&1)"; rc=$?; }

fake_systemctl 3406389
fake_cgls 0 "Unit wm-build.service (/user.slice/user-1000.slice/user@1000.service/rb.slice/rb-infra.slice/wm-build.service):" "└─3406389 /home/jsy/.cargo/bin/wm-build daemon"
run; chk "$rc" 0 "daemon alone -> rc 0"; chk "$(grep -c 'OK wm-build.service MainPID=3406389' <<<"$out")" 1 "OK line names MainPID"

fake_cgls 0 "Unit wm-build.service (...):" "├─3406389 /home/jsy/.cargo/bin/wm-build daemon" "├─3411001 cargo test --workspace" "└─3411077 /usr/bin/rustc --crate-name foo"
run; chk "$rc" 1 "inner build in cgroup -> rc 1"
chk "$(grep -c 'REFUSE wm-build.service MainPID=3406389 holds other processes: 3411001 3411077' <<<"$out")" 1 "REFUSE line lists every other pid, sorted"
chk "$(grep -c 'cargo test --workspace' <<<"$out")" 1 "the offending tree line is echoed"

fake_cgls 1 "Failed to get cgroup of unit wm-build.service: No such file or directory"
run; chk "$rc" 2 "cgls failure -> rc 2"; chk "$(grep -c 'cgroup unreadable (systemd-cgls rc=1)' <<<"$out")" 1 "rc 2 line names the cgls rc"

fake_systemctl 0
run; chk "$rc" 0 "inactive unit (MainPID=0) -> rc 0"; chk "$(grep -c 'inactive (MainPID=0)' <<<"$out")" 1 "inactive line"

fake_systemctl ""
run; chk "$rc" 2 "unreadable MainPID -> rc 2"

printf '#!/usr/bin/env bash\necho 777\n' > "$tmp/systemctl"
fake_cgls 0 "Unit other.service (...):" "└─777 /bin/sleep"
out="$(RBP_UNIT=other.service RBP_SYSTEMCTL="$tmp/systemctl" RBP_CGLS="$tmp/cgls" bash "$sut" 2>&1)"; rc=$?
chk "$rc" 0 "RBP_UNIT override"; chk "$(grep -c 'OK other.service' <<<"$out")" 1 "override unit named"

exit $fail
