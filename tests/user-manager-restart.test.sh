#!/usr/bin/env bash
# A1449 (five-whys 2026-11-09 mechanism 7): proves user@<uid>.service restarts after SIGKILL of its manager and
# stays down after a clean stop, on a scratch user this run creates. Never touches uid 1000 or the caller's uid.
# Acts ONLY on what this run created: a fresh umtest-<8 hex> account (any pre-existing account or useradd
# failure aborts rc 2 with no further call), a drop-in dir made by plain mkdir (a pre-existing dir aborts rc 2
# untouched), a manager that was inactive before start. Cleanup removes only the conf, dir, start and account it made.
# Default run (no environment) is FAKE: the driver below builds tests/fixtures/user-manager-restart-fakes.sh output into a
# mktemp bindir, points every command and RUNDIR at it and runs the cases, exit 0 on PASS. Live mode runs only with
# UMTEST_LIVE=1 and needs sudo -n; without working sudo: SKIP, exit 77 (never 0).
# A1482: every command variable is one word (no whitespace, glob or shell metachar, else SKIP 77 before any of
# them runs), is invoked quoted, and sudo is the single word "$SUDO" invoked as "$SUDO" -n "$X" ...
# A1488: no command variable but SUDO may resolve to fsudo or to $SUDO's own target (sudo only as the prefix), and
# outside UMTEST_LIVE=1 a set UMTEST_FAKEBIN must be a dir of this uid, not group/world-writable, under the driver's
# mktemp root (UMTEST_FAKEROOT, an umtest-fake.XXXXXX dir of this uid, mode go-w) or this repo's tests/fixtures;
# else SKIP 77 before any command variable runs.
set -u
CMDVARS='SYSTEMCTL USERADD USERDEL GETENT KILL SUDO IDCMD MKDIR RMDIR RM TEE'
if [ "${UMTEST_LIVE:-0}" != 1 ] && [ -z "${UMTEST_CHILD:-}" ]; then
  here=$(cd "$(dirname "$0")" && pwd)
  work=$(mktemp -d "${TMPDIR:-/tmp}/umtest-fake.XXXXXX") || exit 2
  trap 'rm -r -- "$work"' EXIT
  bin=$work/bin
  bash "$here/fixtures/user-manager-restart-fakes.sh" "$bin" || exit 2
  # harmless escape marker: a multi-word command variable that reaches it leaves $work/ESCAPED
  printf '#!/usr/bin/env bash\n: > "%s"\n' "$work/ESCAPED" > "$work/marker.sh" && chmod +x "$work/marker.sh" || exit 2
  npass=0 nfail=0
  # case <name> <want rc> <grep pattern on output or "-"> [VAR=val ...]
  runcase() {
    local name=$1 want=$2 pat=$3 rc out; shift 3
    export STATE=$work/$name; mkdir -p "$STATE" "$STATE/run"
    out=$(env -i PATH="$PATH" TMPDIR="$work" STATE="$STATE" UMTEST_CHILD=1 UMTEST_FAKEBIN="$bin" UMTEST_FAKEROOT="$work" \
      SYSTEMCTL="$bin/fsystemctl" USERADD="$bin/fuseradd" USERDEL="$bin/fuserdel" GETENT="$bin/fgetent" \
      KILL="$bin/fkill" SUDO="$bin/fsudo" IDCMD="$bin/fid" MKDIR="$bin/fmkdir" RMDIR="$bin/frmdir" RM="$bin/frm" \
      TEE="$bin/ftee" RUNDIR="$STATE/run" RESTART_WAIT=2 STOP_WAIT=2 "$@" bash "$0" 2>&1); rc=$?
    if [ "$rc" -ne "$want" ] || { [ "$pat" != - ] && ! grep -q -- "$pat" <<<"$out"; }; then
      echo "FAIL case $name: rc $rc (want $want): $out"; nfail=$((nfail + 1)); return 1
    fi
    npass=$((npass + 1))
  }
  runcase ok 0 'user-manager-restart PASS' FAKE_MODE=ok
  runcase norestart 1 'no restart within' FAKE_MODE=norestart
  runcase restartonstop 1 'active again' FAKE_MODE=restartonstop
  runcase nosudo 77 'needs sudo' FAKE_NOSUDO=1
  # calls.log of case $1 has no line matching ERE $2 (a missing log has none)
  nocall() {
    local log=$work/$1/calls.log
    if [ -f "$log" ] && grep -Eq -- "$2" "$log"; then
      echo "FAIL case $1: calls.log has a forbidden call ($2):"; cat "$log"; nfail=$((nfail + 1)); return 1
    fi
    npass=$((npass + 1))
  }
  acts='^(userdel |kill |systemctl (start|stop|kill|daemon-reload)( |$))'
  # A1482 F2: no account of this run -> no userdel and no start/kill/stop/daemon-reload
  runcase preexist 2 'already present' FAKE_PREEXIST=1 && nocall preexist "$acts"
  runcase useraddfail 2 'useradd .* failed' FAKE_USERADD_RC=1 && nocall useraddfail "$acts"
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
  # A1482 F3: a pre-existing drop-in dir aborts rc 2 untouched; only the owned account is removed
  sha0=$(bash "$here/fixtures/user-manager-restart-fakes.sh" --seed-dropdir "$work/dropdir/run" 990) || exit 2
  if runcase dropdir 2 'pre-existing dir left untouched' && nocall dropdir \
       '^(kill |systemctl (start|stop|kill|daemon-reload)( |$)|(rm|rmdir) .*user@990\.service\.d)'; then
    log=$work/dropdir/calls.log
    owned=$(sed -n 's/^useradd .* \(umtest-[0-9a-f]\{8\}\)$/\1/p' "$log")
    sha1=$(sha256sum < "$work/dropdir/run/user@990.service.d/sentinel" 2>/dev/null | cut -d' ' -f1)
    if [ -n "$owned" ] && [ "$sha1" = "$sha0" ] && [ "$(grep -c '^userdel ' "$log")" = 1 ] && grep -qx "userdel $owned" "$log"; then
      npass=$((npass + 1))
    else
      echo "FAIL case dropdir: sentinel $sha0 -> ${sha1:-missing} or userdel not owned-only:"; cat "$log"; nfail=$((nfail + 1))
    fi
  fi
  # A1482 F1: a multi-word, glob or metachar command variable is refused rc 77 before any command variable runs
  for v in KILL SUDO IDCMD; do
    rm -f -- "$work/ESCAPED"
    runcase "multiword-$v" 77 'not a single word' "$v=$bin/fsudo $work/marker.sh"
    if [ -e "$work/ESCAPED" ] || [ -e "$work/multiword-$v/calls.log" ]; then
      echo "FAIL case multiword-$v: a command ran (ESCAPED or calls.log present)"; nfail=$((nfail + 1))
    else
      npass=$((npass + 1))
    fi
  done
  runcase glob 77 'not a single word' "KILL=$bin/fk*"
  runcase metachar 77 'not a single word' "IDCMD=$bin/fid;$work/marker.sh"
  # A1488: escape markers on PATH under the words the test passes after GETENT (passwd) and IDCMD (-u) and the
  # sudo probe (true); a fake command that reaches any of them leaves $work/ESCAPED
  mkdir -p "$work/pathbin" && for m in passwd -u true; do cp -- "$work/marker.sh" "$work/pathbin/$m"; done
  # escaped <case> <want refusal pattern or "-">: no ESCAPED; calls.log has no fake call, only the wanted refusal
  escaped() {
    local log=$work/$1/calls.log
    if [ -e "$work/ESCAPED" ] || { [ -f "$log" ] && grep -qv '^fsudo-refused ' "$log"; } ||
       { [ "$2" != - ] && ! grep -q -- "$2" "$log" 2>/dev/null; }; then
      echo "FAIL case $1: ESCAPED or a fake ran or no refusal ($2):"; cat "$log" 2>/dev/null; nfail=$((nfail + 1)); return 1
    fi
    npass=$((npass + 1))
  }
  # A1488 (a): fsudo is only the SUDO prefix; as any other command variable it is refused rc 77 before any runs
  for v in SYSTEMCTL USERADD USERDEL GETENT KILL IDCMD MKDIR RMDIR RM TEE; do
    rm -f -- "$work/ESCAPED"
    runcase "fsudo-as-$v" 77 "$v resolves to sudo" "PATH=$work/pathbin:$PATH" "$v=$bin/fsudo" && escaped "fsudo-as-$v" -
  done
  # A1488 (b): UMTEST_FAKEBIN outside the mktemp root, group-writable, or with an unowned/bad root is refused rc 77
  # ocase <name> <pattern> <bindir> <dir to chmod g+w or "-"> [VAR=val ...]: <bindir> holds the fakes plus a marker
  # named fgetent, GETENT points at it
  ocase() {
    local name=$1 pat=$2 ob=$3 gw=$4; shift 4
    bash "$here/fixtures/user-manager-restart-fakes.sh" "$ob" && cp -- "$work/marker.sh" "$ob/fgetent" || exit 2
    [ "$gw" = - ] || chmod g+w -- "$gw" || exit 2
    rm -f -- "$work/ESCAPED"
    runcase "$name" 77 "$pat" "UMTEST_FAKEBIN=$ob" "GETENT=$ob/fgetent" "$@" && escaped "$name" -
  }
  other=$(mktemp -d "${TMPDIR:-/tmp}/umtest-other.XXXXXX") || exit 2
  ocase fakebin-outside 'UMTEST_FAKEBIN .* not under' "$other/bin" -
  rm -r -- "$other"
  ocase fakebin-groupwritable 'UMTEST_FAKEBIN .* group/world-writable' "$work/gw/bin" "$work/gw/bin"
  ocase fakebin-nofakeroot 'UMTEST_FAKEBIN .* not under' "$work/nr/bin" - UMTEST_FAKEROOT=
  fr=$(mktemp -d "${TMPDIR:-/tmp}/umtest-fake.XXXXXX") || exit 2
  ocase fakeroot-writable 'UMTEST_FAKEROOT' "$fr/bin" "$fr" "UMTEST_FAKEROOT=$fr"
  rm -r -- "$fr"
  # A1488 fsudo allowlist: a target outside its own bindir, or fsudo itself, is refused rc 126, nothing runs
  for t in passwd "$work/pathbin/passwd" "$bin/fsudo" "$bin/../marker.sh"; do
    export STATE=$work/fsudo-direct; mkdir -p "$STATE"; rm -f -- "$work/ESCAPED" "$STATE/calls.log"
    PATH="$work/pathbin:$PATH" "$bin/fsudo" -n "$t" x >/dev/null 2>&1; rc=$?
    if [ "$rc" = 126 ] && grep -q "^fsudo-refused $t " "$STATE/calls.log"; then escaped fsudo-direct fsudo-refused
    else echo "FAIL case fsudo-direct $t: rc $rc (want 126):"; cat "$STATE/calls.log" 2>/dev/null; nfail=$((nfail + 1)); fi
  done
  [ "$nfail" = 0 ] || { echo "user-manager-restart FAKE FAIL pass=$npass fail=$nfail"; exit 1; }
  echo "user-manager-restart FAKE PASS cases=$npass"
  exit 0
fi
SYSTEMCTL=${SYSTEMCTL:-systemctl}
USERADD=${USERADD:-useradd}
USERDEL=${USERDEL:-userdel}
GETENT=${GETENT:-getent}
KILL=${KILL:-kill}
SUDO=${SUDO:-sudo}
IDCMD=${IDCMD:-id}
MKDIR=${MKDIR:-mkdir}
RMDIR=${RMDIR:-rmdir}
RM=${RM:-rm}
TEE=${TEE:-tee}
RUNDIR=${RUNDIR:-/run/systemd/system}
RESTART_WAIT=${RESTART_WAIT:-15}
STOP_WAIT=${STOP_WAIT:-10}
for v in $CMDVARS; do
  case ${!v} in ''|*[![:alnum:]_./+@-]*) echo "SKIP: command variable $v is not a single word: ${!v}"; exit 77;; esac
done
# A1488 (a): resolved target of a command word (command -v, then realpath -e), empty if none
target() { local p; p=$(command -v -- "$1" 2>/dev/null) && [ "${p#/}" != "$p" ] && realpath -e -- "$p" 2>/dev/null; }
sudo_rp=$(target "$SUDO")
for v in $CMDVARS; do
  [ "$v" = SUDO ] && continue
  rp=$(target "${!v}")
  if [ "${rp##*/}" = fsudo ] || [ "${!v##*/}" = fsudo ] || { [ -n "$rp" ] && [ "$rp" = "$sudo_rp" ]; }; then
    echo "SKIP: command variable $v resolves to sudo (${rp:-${!v}}); sudo is only the SUDO prefix"; exit 77
  fi
done
# A1488 (b): fixture-root containment of a set UMTEST_FAKEBIN outside live mode
safedir() { local m; [ -d "$1" ] && [ "$(stat -c %u -- "$1")" = "$(id -u)" ] && m=$(stat -c %a -- "$1") && (( (8#$m & 8#022) == 0 )); }
if [ -n "${UMTEST_FAKEBIN:-}" ] && [ "${UMTEST_LIVE:-0}" != 1 ]; then
  fb=$(realpath -e -- "$UMTEST_FAKEBIN" 2>/dev/null) || { echo "SKIP: UMTEST_FAKEBIN $UMTEST_FAKEBIN does not resolve"; exit 77; }
  safedir "$fb" || { echo "SKIP: UMTEST_FAKEBIN $fb is not a dir of uid $(id -u) or is group/world-writable"; exit 77; }
  fx=$(realpath -e -- "$(dirname -- "$0")/fixtures" 2>/dev/null) || fx=/nonexistent
  fr=
  if [ -n "${UMTEST_FAKEROOT:-}" ]; then
    fr=$(realpath -e -- "$UMTEST_FAKEROOT" 2>/dev/null) || fr=
    case ${fr##*/} in umtest-fake.[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]) ;; *) fr=;; esac
    if [ -z "$fr" ] || ! safedir "$fr"; then echo "SKIP: UMTEST_FAKEROOT $UMTEST_FAKEROOT is not an umtest-fake.XXXXXX dir of uid $(id -u), mode go-w"; exit 77; fi
  fi
  in=0
  case $fb in "$fx"/*) in=1;; esac
  [ -n "$fr" ] && case $fb in "$fr"/*) in=1;; esac
  [ "$in" = 1 ] || { echo "SKIP: UMTEST_FAKEBIN $fb is not under the mktemp root or $fx"; exit 77; }
fi

# live unless every command is an absolute path that resolves (realpath) into the fixture bindir, and that bindir is not a system directory;
# anything under a system path, or anywhere else, counts as live and needs UMTEST_LIVE=1
sysdir() { case $1 in /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/opt|/opt/*|/snap|/snap/*) return 0;; esac; return 1; }
fakebin=$(realpath -- "${UMTEST_FAKEBIN:-/nonexistent}" 2>/dev/null) || fakebin=
live=0
[ -n "$fakebin" ] && ! sysdir "$fakebin" || live=1
for v in $CMDVARS; do
  case ${!v} in /*) ;; *) live=1; continue;; esac
  if ! rp=$(realpath -e -- "${!v}" 2>/dev/null); then live=1; continue; fi
  sysdir "$rp" && live=1
  [ "$(dirname -- "$rp")" = "$fakebin" ] || live=1
done
rr=$(realpath -m -- "$RUNDIR")
case $rr in /run/systemd|/run/systemd/*|/etc/systemd|/etc/systemd/*|/usr/lib/systemd/*) live=1;; esac
if [ "$live" = 1 ] && [ "${UMTEST_LIVE:-0}" != 1 ]; then
  echo "SKIP: live mode needs UMTEST_LIVE=1"
  exit 77
fi
if ! "$SUDO" -n true >/dev/null 2>&1; then
  echo "SKIP: needs sudo -n"
  exit 77
fi

OWNED_USER=0 made_dir=0 wrote_conf=0 started=0
uid='' unit='' dropdir='' conf=''
fail() { echo "FAIL step $1: $2" >&2; exit 1; }
abort() { echo "ABORT: $*" >&2; exit 2; }

# every action below is gated on a flag set by this run; started is set BEFORE the start call, so a failed or
# timed-out start still gets a stop and the account removal below
cleanup() {
  local rc=$?
  trap - EXIT
  [ "$started" = 1 ] && "$SUDO" -n "$SYSTEMCTL" stop "$unit" >/dev/null 2>&1
  [ "$wrote_conf" = 1 ] && "$SUDO" -n "$RM" -f -- "$conf"
  [ "$made_dir" = 1 ] && "$SUDO" -n "$RMDIR" -- "$dropdir"
  [ "$wrote_conf" = 1 ] && "$SUDO" -n "$SYSTEMCTL" daemon-reload >/dev/null 2>&1
  [ "$OWNED_USER" = 1 ] && "$SUDO" -n "$USERDEL" "$UMUSER" >/dev/null 2>&1
  exit $rc
}
trap cleanup EXIT

# P1/P2: a unique name, refused if any account by that name exists; owned only on useradd rc 0 for it
UMUSER=umtest-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
case $UMUSER in umtest-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) abort "bad scratch name $UMUSER";; esac
pw=$("$GETENT" passwd "$UMUSER" 2>/dev/null); grc=$?
[ -z "$pw" ] && [ "$grc" -eq 2 ] || abort "account $UMUSER already present or lookup failed (getent rc $grc)"
"$SUDO" -n "$USERADD" --system --no-create-home --home-dir "/var/tmp/$UMUSER" --shell /usr/sbin/nologin "$UMUSER" ||
  abort "useradd $UMUSER failed"
OWNED_USER=1
IFS=: read -r pwname _ uid _ <<<"$("$GETENT" passwd "$UMUSER" 2>/dev/null)"
[ "${pwname:-}" = "$UMUSER" ] || abort "getent has no entry for $UMUSER after useradd"
# HARD GUARD: before any write, start or kill
case $uid in ''|*[!0-9]*) abort "no numeric uid for $UMUSER";; esac
[ "$uid" -eq 1000 ] && abort "scratch uid is 1000"
[ "$uid" -eq "$("$IDCMD" -u)" ] && abort "scratch uid equals caller uid"
[ "$uid" -lt 900 ] && abort "scratch uid $uid < 900"

unit=user@$uid.service
prop() { "$SUDO" -n "$SYSTEMCTL" show "$unit" -p "$1" --value 2>/dev/null; }
# P3: a manager already running for this uid is not ours
[ "$(prop ActiveState)" = inactive ] || abort "$unit not inactive before this run"
dropdir=$RUNDIR/$unit.d
"$SUDO" -n "$MKDIR" -- "$dropdir" || abort "mkdir $dropdir (pre-existing dir left untouched)"
made_dir=1
conf=$dropdir/10-restart-on-abnormal.conf
wrote_conf=1
# drop-in embedded verbatim from PR #362 (.config/carbon-sigkill-trace/10-restart-on-abnormal.conf)
"$SUDO" -n "$TEE" "$conf" >/dev/null <<'CONF' || abort "write $conf"
# five-whys 2026-11-09 mechanism 1: PID 1 restarts the user manager after a signal/timeout death; a clean logind stop is not restarted
[Service]
Restart=on-abnormal
RestartSec=5
CONF
"$SUDO" -n "$SYSTEMCTL" daemon-reload || abort "daemon-reload"
[ "$(prop ActiveState)" = inactive ] || abort "$unit not inactive before start"
started=1
"$SUDO" -n "$SYSTEMCTL" start "$unit" || abort "start $unit"

old=$(prop MainPID); n0=$(prop NRestarts)
case $old in ''|0|*[!0-9]*) abort "no MainPID for $unit";; esac

# step 1: SIGKILL the manager -> restarted within RESTART_WAIT with a new MainPID and NRestarts+1
"$SUDO" -n "$KILL" -KILL "$old"
new='' n1=''
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
"$SUDO" -n "$SYSTEMCTL" stop "$unit" || fail 3 "stop $unit"
for ((i = 0; i < STOP_WAIT; i++)); do
  sleep 1
  [ "$(prop ActiveState)" = active ] && fail 3 "$unit active again ${i}s after a clean stop"
done

echo "user-manager-restart PASS user=$UMUSER uid=$uid old=$old new=$new nrestarts=$n0->$n1"
