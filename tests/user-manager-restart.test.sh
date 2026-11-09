#!/usr/bin/env bash
# A1449 (five-whys 2026-11-09 mechanism 7): proves user@<uid>.service restarts after SIGKILL of its manager and
# stays down after a clean stop, on a disposable scratch user. Never touches uid 1000 or the caller's uid.
# Live mode needs sudo -n; fake mode points SYSTEMCTL/USERADD/USERDEL/KILL/SUDO/IDCMD/RUNDIR at
# tests/fixtures/user-manager-restart-fakes.sh output. Live mode (real systemctl) also needs UMTEST_LIVE=1. Without working sudo: SKIP, exit 77 (never 0).
set -u
SYSTEMCTL=${SYSTEMCTL:-systemctl}
USERADD=${USERADD:-useradd}
USERDEL=${USERDEL:-userdel}
KILL=${KILL:-kill}
SUDO=${SUDO:-sudo -n}
IDCMD=${IDCMD:-id}
RUNDIR=${RUNDIR:-/run/systemd/system}
UMUSER=${UMUSER:-umtest}
UMHOME=${UMHOME:-/var/tmp/umtest}
RESTART_WAIT=${RESTART_WAIT:-15}
STOP_WAIT=${STOP_WAIT:-10}

if [ "${SYSTEMCTL}" = systemctl ] && [ "${UMTEST_LIVE:-0}" != 1 ]; then
  echo "SKIP: live mode needs UMTEST_LIVE=1"
  exit 77
fi
if ! $SUDO true >/dev/null 2>&1; then
  echo "SKIP: needs sudo -n"
  exit 77
fi

uid= unit= dropdir= created=0
fail() { echo "FAIL step $1: $2" >&2; exit 1; }
abort() { echo "ABORT: $*" >&2; exit 2; }

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$unit" ]; then
    $SUDO $SYSTEMCTL stop "$unit" >/dev/null 2>&1
    [ -n "$dropdir" ] && $SUDO rm -rf "$dropdir"
    $SUDO $SYSTEMCTL daemon-reload >/dev/null 2>&1
  fi
  [ "$created" = 1 ] && $SUDO $USERDEL "$UMUSER" >/dev/null 2>&1
  exit $rc
}
trap cleanup EXIT

if ! $IDCMD -u "$UMUSER" >/dev/null 2>&1; then
  $SUDO $USERADD --system --no-create-home --home-dir "$UMHOME" --shell /usr/sbin/nologin "$UMUSER" || abort "useradd failed"
  created=1
fi
uid=$($IDCMD -u "$UMUSER" 2>/dev/null)
# HARD GUARD: before any start or kill
case $uid in ''|*[!0-9]*) abort "no numeric uid for $UMUSER";; esac
[ "$uid" -eq 1000 ] && abort "scratch uid is 1000"
[ "$uid" -eq "$($IDCMD -u)" ] && abort "scratch uid equals caller uid"
[ "$uid" -lt 900 ] && abort "scratch uid $uid < 900"

unit=user@$uid.service
dropdir=$RUNDIR/$unit.d
$SUDO mkdir -p "$dropdir" || abort "mkdir $dropdir"
# drop-in embedded verbatim from PR #362 (.config/carbon-sigkill-trace/10-restart-on-abnormal.conf)
$SUDO tee "$dropdir/10-restart-on-abnormal.conf" >/dev/null <<'CONF'
# five-whys 2026-11-09 mechanism 1: PID 1 restarts the user manager after a signal/timeout death; a clean logind stop is not restarted
[Service]
Restart=on-abnormal
RestartSec=5
CONF
$SUDO $SYSTEMCTL daemon-reload || abort "daemon-reload"
$SUDO $SYSTEMCTL start "$unit" || abort "start $unit"

prop() { $SUDO $SYSTEMCTL show "$unit" -p "$1" --value 2>/dev/null; }
old=$(prop MainPID); n0=$(prop NRestarts)
case $old in ''|0|*[!0-9]*) abort "no MainPID for $unit";; esac

# step 1: SIGKILL the manager -> restarted within RESTART_WAIT with a new MainPID and NRestarts+1
$SUDO $KILL -KILL "$old"
new= n1=
for ((i = 0; i < RESTART_WAIT; i++)); do
  sleep 1
  new=$(prop MainPID); n1=$(prop NRestarts)
  [ "$(prop ActiveState)" = active ] && [ -n "$new" ] && [ "$new" != 0 ] && [ "$new" != "$old" ] && break
  new=
done
[ -n "$new" ] || fail 1 "no restart within ${RESTART_WAIT}s after SIGKILL of $old"
[ "$n1" -eq $((n0 + 1)) ] || fail 1 "NRestarts $n0 -> $n1, expected +1"

# step 2: the restarted manager is running
[ "$(prop SubState)" = running ] || fail 2 "SubState=$(prop SubState), expected running"

# step 3: a clean stop is not restarted
$SUDO $SYSTEMCTL stop "$unit" || fail 3 "stop $unit"
for ((i = 0; i < STOP_WAIT; i++)); do
  sleep 1
  [ "$(prop ActiveState)" = active ] && fail 3 "$unit active again ${i}s after a clean stop"
done

echo "user-manager-restart PASS uid=$uid old=$old new=$new nrestarts=$n0->$n1"
