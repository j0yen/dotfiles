#!/usr/bin/env bash
# A1449 (five-whys 2026-11-09 mechanism 7): proves user@<uid>.service restarts after SIGKILL of its manager and
# stays down after a clean stop, on a scratch user this run creates. Never touches uid 1000 or the caller's uid.
# Acts ONLY on what this run created: a fresh umtest-<8 hex> account (any pre-existing account or useradd
# failure aborts rc 2 with no further call), a drop-in dir made by plain mkdir (a pre-existing dir aborts rc 2
# untouched), a manager that was inactive before start. Cleanup removes only the conf, dir, start and account it made.
# Default run (no environment) is FAKE: the driver below builds tests/fixtures/user-manager-restart-fakes.sh output into a
# mktemp bindir, points every command and RUNDIR at it and runs the cases, exit 0 on PASS. Live mode runs only with
# UMTEST_LIVE=1 and needs sudo -n; without working sudo: SKIP, exit 77 (never 0).
set -u
if [ "${UMTEST_LIVE:-0}" != 1 ] && [ -z "${UMTEST_CHILD:-}" ]; then
  here=$(cd "$(dirname "$0")" && pwd)
  work=$(mktemp -d "${TMPDIR:-/tmp}/umtest-fake.XXXXXX") || exit 2
  trap 'rm -r -- "$work"' EXIT
  bin=$work/bin
  bash "$here/fixtures/user-manager-restart-fakes.sh" "$bin" || exit 2
  npass=0 nfail=0
  # case <name> <want rc> <grep pattern on output or "-"> [VAR=val ...]
  runcase() {
    local name=$1 want=$2 pat=$3 rc out; shift 3
    export STATE=$work/$name; mkdir -p "$STATE" "$STATE/run"
    out=$(env -i PATH="$PATH" TMPDIR="$work" STATE="$STATE" UMTEST_CHILD=1 UMTEST_FAKEBIN="$bin" \
      SYSTEMCTL="$bin/fsystemctl" USERADD="$bin/fuseradd" USERDEL="$bin/fuserdel" GETENT="$bin/fgetent" \
      KILL="$bin/fkill" SUDO="$bin/fsudo" IDCMD="$bin/fid" MKDIR="$bin/fmkdir" RMDIR="$bin/frmdir" RM="$bin/frm" \
      TEE="$bin/ftee" RUNDIR="$STATE/run" RESTART_WAIT=2 STOP_WAIT=2 "$@" bash "$0" 2>&1); rc=$?
    CASE_OUT=$out
    if [ "$rc" -ne "$want" ] || { [ "$pat" != - ] && ! grep -q -- "$pat" <<<"$out"; }; then
      echo "FAIL case $name: rc $rc (want $want): $out"; nfail=$((nfail + 1)); return 1
    fi
    npass=$((npass + 1))
  }
  runcase ok 0 'user-manager-restart PASS' FAKE_MODE=ok
  runcase norestart 1 'no restart within' FAKE_MODE=norestart
  runcase restartonstop 1 'active again' FAKE_MODE=restartonstop
  runcase nosudo 77 'needs sudo' FAKE_NOSUDO=1
  runcase preexist 2 'already present' FAKE_PREEXIST=1
  runcase useraddfail 2 'useradd .* failed' FAKE_USERADD_RC=1
  runcase preactive 2 'not inactive before this run' FAKE_PREACTIVE=1
  # R4: start fails -> cleanup still stops the unit and deletes the owned account, and only that account
  if runcase startfail 2 'start user@990.service' FAKE_STARTRC=1; then
    log=$work/startfail/calls.log
    owned=$(sed -n 's/^useradd .* \(umtest-[0-9a-f]\{8\}\)$/\1/p' "$log")
    if [ -n "$owned" ] && grep -qx 'systemctl stop user@990.service' "$log" &&
       [ "$(grep -c '^userdel ' "$log")" = 1 ] && grep -qx "userdel $owned" "$log"; then
      npass=$((npass + 1))
    else
      echo "FAIL case startfail: calls.log lacks stop or owned-only userdel:"; cat "$log"; nfail=$((nfail + 1))
    fi
  fi
  [ "$nfail" = 0 ] || { echo "user-manager-restart FAKE FAIL pass=$npass fail=$nfail"; exit 1; }
  echo "user-manager-restart FAKE PASS cases=$npass"
  exit 0
fi
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

# live unless every command resolves (realpath) into the fixture bindir, and that bindir is not a system directory;
# anything under a system path, or anywhere else, counts as live and needs UMTEST_LIVE=1
sysdir() { case $1 in /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/opt|/opt/*|/snap|/snap/*) return 0;; esac; return 1; }
fakebin=$(realpath -- "${UMTEST_FAKEBIN:-/nonexistent}" 2>/dev/null) || fakebin=
live=0
[ -n "$fakebin" ] && ! sysdir "$fakebin" || live=1
for c in "$SYSTEMCTL" "$USERADD" "$USERDEL" "$GETENT" "$KILL" "$SUDO" "$MKDIR" "$RMDIR" "$RM" "$TEE"; do
  p=$(command -v -- "${c%% *}") && rp=$(realpath -- "$p" 2>/dev/null) || { live=1; continue; }
  sysdir "$rp" && live=1
  [ "$(dirname -- "$rp")" = "$fakebin" ] || live=1
done
rr=$(realpath -m -- "$RUNDIR")
case $rr in /run/systemd|/run/systemd/*|/etc/systemd|/etc/systemd/*|/usr/lib/systemd/*) live=1;; esac
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

# every action below is gated on a flag set by this run; started is set BEFORE the start call, so a failed or
# timed-out start still gets a stop and the account removal below
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
started=1
$SUDO $SYSTEMCTL start "$unit" || abort "start $unit"

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
