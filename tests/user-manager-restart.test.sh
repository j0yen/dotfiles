#!/usr/bin/env bash
# A1449 (five-whys 2026-11-09 mechanism 7): proves user@<uid>.service restarts after SIGKILL of its manager and
# stays down after a clean stop, on a scratch user this run creates. Never touches uid 1000 or the caller's uid.
# Acts ONLY on what this run created: a fresh umtest-<8 hex> account (any pre-existing account or useradd
# failure aborts rc 2 with no further call), a drop-in dir made by plain mkdir (a pre-existing dir aborts rc 2
# untouched), a manager that was inactive before start. Cleanup removes only the conf, dir, start and account it made.
# Live mode needs sudo -n and UMTEST_LIVE=1 whenever any command below is left at its real default; fake mode
# points every one of them at tests/fixtures/user-manager-restart-fakes.sh output. Without working sudo: SKIP, exit 77 (never 0).
set -u
SYSTEMCTL=${SYSTEMCTL:-systemctl}
USERADD=${USERADD:-useradd}
USERDEL=${USERDEL:-userdel}
GETENT=${GETENT:-getent}
KILL=${KILL:-kill}
SUDO=${SUDO:-sudo -n}
IDCMD=${IDCMD:-id}
MKDIR=${MKDIR:-mkdir}
RMDIR=${RMDIR:-rmdir}
RM=${RM:-rm}
TEE=${TEE:-tee}
RUNDIR=${RUNDIR:-/run/systemd/system}
RESTART_WAIT=${RESTART_WAIT:-15}
STOP_WAIT=${STOP_WAIT:-10}

live=0
for c in "$SYSTEMCTL" "$USERADD" "$USERDEL" "$GETENT" "$KILL" "$SUDO" "$MKDIR" "$RMDIR" "$RM" "$TEE"; do
  b=${c%% *}
  case ${b##*/} in systemctl|useradd|userdel|getent|kill|sudo|mkdir|rmdir|rm|tee) live=1;; esac
done
[ "$RUNDIR" = /run/systemd/system ] && live=1
if [ "$live" = 1 ] && [ "${UMTEST_LIVE:-0}" != 1 ]; then
  echo "SKIP: live mode needs UMTEST_LIVE=1"
  exit 77
fi
if ! $SUDO true >/dev/null 2>&1; then
  echo "SKIP: needs sudo -n"
  exit 77
fi

OWNED_USER=0 made_dir=0 wrote_conf=0 started=0
uid= unit= dropdir= conf=
fail() { echo "FAIL step $1: $2" >&2; exit 1; }
abort() { echo "ABORT: $*" >&2; exit 2; }

# every action below is gated on a flag set only after this run itself did the matching create
cleanup() {
  local rc=$?
  trap - EXIT
  [ "$started" = 1 ] && $SUDO $SYSTEMCTL stop "$unit" >/dev/null 2>&1
  [ "$wrote_conf" = 1 ] && $SUDO $RM -f -- "$conf"
  [ "$made_dir" = 1 ] && $SUDO $RMDIR -- "$dropdir"
  [ "$wrote_conf" = 1 ] && $SUDO $SYSTEMCTL daemon-reload >/dev/null 2>&1
  [ "$OWNED_USER" = 1 ] && $SUDO $USERDEL "$UMUSER" >/dev/null 2>&1
  exit $rc
}
trap cleanup EXIT

# P1/P2: a unique name, refused if any account by that name exists; owned only on useradd rc 0 for it
UMUSER=umtest-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
case $UMUSER in umtest-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) abort "bad scratch name $UMUSER";; esac
pw=$($GETENT passwd "$UMUSER" 2>/dev/null); grc=$?
[ -z "$pw" ] && [ "$grc" -eq 2 ] || abort "account $UMUSER already present or lookup failed (getent rc $grc)"
$SUDO $USERADD --system --no-create-home --home-dir "/var/tmp/$UMUSER" --shell /usr/sbin/nologin "$UMUSER" ||
  abort "useradd $UMUSER failed"
OWNED_USER=1
IFS=: read -r pwname _ uid _ <<<"$($GETENT passwd "$UMUSER" 2>/dev/null)"
[ "${pwname:-}" = "$UMUSER" ] || abort "getent has no entry for $UMUSER after useradd"
# HARD GUARD: before any write, start or kill
case $uid in ''|*[!0-9]*) abort "no numeric uid for $UMUSER";; esac
[ "$uid" -eq 1000 ] && abort "scratch uid is 1000"
[ "$uid" -eq "$($IDCMD -u)" ] && abort "scratch uid equals caller uid"
[ "$uid" -lt 900 ] && abort "scratch uid $uid < 900"

unit=user@$uid.service
prop() { $SUDO $SYSTEMCTL show "$unit" -p "$1" --value 2>/dev/null; }
# P3: a manager already running for this uid is not ours
[ "$(prop ActiveState)" = inactive ] || abort "$unit not inactive before this run"
dropdir=$RUNDIR/$unit.d
$SUDO $MKDIR -- "$dropdir" || abort "mkdir $dropdir (pre-existing dir left untouched)"
made_dir=1
conf=$dropdir/10-restart-on-abnormal.conf
wrote_conf=1
# drop-in embedded verbatim from PR #362 (.config/carbon-sigkill-trace/10-restart-on-abnormal.conf)
$SUDO $TEE "$conf" >/dev/null <<'CONF' || abort "write $conf"
# five-whys 2026-11-09 mechanism 1: PID 1 restarts the user manager after a signal/timeout death; a clean logind stop is not restarted
[Service]
Restart=on-abnormal
RestartSec=5
CONF
$SUDO $SYSTEMCTL daemon-reload || abort "daemon-reload"
[ "$(prop ActiveState)" = inactive ] || abort "$unit not inactive before start"
$SUDO $SYSTEMCTL start "$unit" || abort "start $unit"
started=1

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

echo "user-manager-restart PASS user=$UMUSER uid=$uid old=$old new=$new nrestarts=$n0->$n1"
