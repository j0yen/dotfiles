#!/usr/bin/env bash
# rb-restart-precheck.sh — may wm-build.service be restarted right now?
# ctl 2026-11-02 8:19 PM (A630): a restart kills every process in the unit's
# cgroup, so a restart is refused while the cgroup holds anything besides the
# daemon itself (an inner build, a coder, a test run adopted into the unit).
# fleet-token-rotate.sh's bell names this script as the gate before a restart.
#   rc 0  only MainPID in the cgroup (or the unit is inactive): restart is safe
#   rc 1  other processes present: REFUSE, each pid listed
#   rc 2  the cgroup could not be read: REFUSE, cause unknown
# Overrides for tests: RBP_SYSTEMCTL, RBP_CGLS (commands), RBP_UNIT (unit name).
set -uo pipefail
unit="${RBP_UNIT:-wm-build.service}"
systemctl_cmd="${RBP_SYSTEMCTL:-systemctl}"
cgls_cmd="${RBP_CGLS:-systemd-cgls}"

main_pid="$($systemctl_cmd --user show -p MainPID --value "$unit" 2>/dev/null)" || main_pid=""
case "$main_pid" in
  ''|*[!0-9]*) echo "rb-restart-precheck: REFUSE $unit MainPID unreadable (got '${main_pid}')" >&2; exit 2 ;;
esac
if [ "$main_pid" = 0 ]; then
  echo "rb-restart-precheck: OK $unit inactive (MainPID=0), nothing to lose"
  exit 0
fi

cgls_out="$($cgls_cmd --user-unit "$unit" --no-pager 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then
  echo "rb-restart-precheck: REFUSE $unit cgroup unreadable (systemd-cgls rc=$rc): ${cgls_out%%$'\n'*}" >&2
  exit 2
fi
# tree lines look like "├─3406389 /path/wm-build daemon" or "└─1234 cargo test"
others="$(printf '%s\n' "$cgls_out" | sed -n 's/^[[:space:]]*[├└│]*─\{0,1\}\([0-9]\{1,\}\) .*/\1/p' | grep -vx "$main_pid" | sort -un | tr '\n' ' ')"
others="${others% }"
if [ -n "$others" ]; then
  echo "rb-restart-precheck: REFUSE $unit MainPID=$main_pid holds other processes: $others" >&2
  printf '%s\n' "$cgls_out" | grep -E "^[[:space:]]*[├└│]*─?(${others// /|}) " >&2
  exit 1
fi
echo "rb-restart-precheck: OK $unit MainPID=$main_pid is alone in its cgroup"
exit 0
