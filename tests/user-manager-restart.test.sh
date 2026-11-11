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
# else SKIP 77 before any command variable runs. A command variable that is the same file as fsudo or $SUDO's target
# (-ef, e.g. a hardlink) or byte-identical to it (cmp -s, a copy) is refused the same way. A1486: RUNDIR gets the
# single-word rule too. Every fake runs with the fixed PATH /usr/sbin:/usr/bin:/sbin:/bin under #!/bin/bash -p.
# A1488 caller-uid guard: IDCMD -u must exit 0 and print an all-digit uid before any account is made, else ABORT
# rc 2; the scratch uid is all-digit and every uid compare aborts when it fails or errors (fail closed).
# A1488 rev 8: RESTART_WAIT and STOP_WAIT are 1-4 ASCII digits (set empty counts as malformed), else SKIP 77 before any
# command runs; every number read from a command (stat mode, MainPID, NRestarts) is checked all ASCII digits by a case
# pattern right after the read, before any arithmetic or compare (malformed NRestarts/MainPID: ABORT rc 2, owned
# cleanup only), so no outside value reaches (( )) or $(( )), where Bash would expand a subscript like a[$(cmd)].
# F1: outside live mode every dir from the matched root down to UMTEST_FAKEBIN passes the dir rule, and every command
# variable's target file is owned by this uid and not group/world-writable. F4: a byte-identity compare that cannot
# run (cmp rc other than 0/1, e.g. 127 when missing) refuses SKIP 77, never passes. F3: the single-word class is
# explicit ASCII (A-Z a-z 0-9 _ . / + @ -), independent of the locale.
# A1499: a MainPID is 1-10 ASCII digits, no leading 0, not 1 (pattern check, no arithmetic) right after each read, else
# ABORT rc 2 before the kill or compare (0 after the kill = not restarted yet). A1500: the checks run cmp, stat, id,
# realpath and dirname from /usr/bin or /bin (root-owned, go-w), never from PATH; none usable: SKIP 77.
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
  # A1488 D1: IDCMD -u that fails, prints nothing or prints a non-uid aborts rc 2 before any account is made;
  # a caller uid equal to the scratch uid aborts rc 2 with no write/start/kill and only the owned account removed
  acts2='^(useradd |userdel |kill |systemctl |mkdir |tee |rm |rmdir )'
  runcase id-empty 2 "IDCMD $bin/fid -u printed no all-digit uid" FAKE_CALLER_UID= && nocall id-empty "$acts2"
  runcase id-alpha 2 "IDCMD $bin/fid -u printed no all-digit uid" FAKE_CALLER_UID=abc && nocall id-alpha "$acts2"
  runcase id-space 2 "IDCMD $bin/fid -u printed no all-digit uid" 'FAKE_CALLER_UID=12 3' && nocall id-space "$acts2"
  runcase id-rc1 2 "IDCMD $bin/fid -u failed (rc 1)" FAKE_ID_RC=1 && nocall id-rc1 "$acts2"
  if runcase id-same 2 'equals caller uid' FAKE_CALLER_UID=990 && nocall id-same \
       '^(kill |systemctl (start|stop|kill|daemon-reload)( |$)|mkdir |tee |rm |rmdir )'; then
    log=$work/id-same/calls.log
    owned=$(sed -n 's/^useradd .* \(umtest-[0-9a-f]\{8\}\)$/\1/p' "$log")
    if [ -n "$owned" ] && [ "$(grep -c '^userdel ' "$log")" = 1 ] && grep -qx "userdel $owned" "$log"; then
      npass=$((npass + 1))
    else
      echo "FAIL case id-same: userdel not owned-only:"; cat "$log"; nfail=$((nfail + 1))
    fi
  fi
  runcase id-good 0 'user-manager-restart PASS' FAKE_CALLER_UID=1234
  # A1488 D2: a hardlink or copy of fsudo under another name is still sudo: rc 77 before any command runs
  sb=$work/d2/bin
  bash "$here/fixtures/user-manager-restart-fakes.sh" "$sb" && ln -- "$sb/fsudo" "$sb/hlink" && cp -- "$sb/fsudo" "$sb/fcopy" || exit 2
  allin="UMTEST_FAKEBIN=$sb SYSTEMCTL=$sb/fsystemctl USERADD=$sb/fuseradd USERDEL=$sb/fuserdel GETENT=$sb/fgetent"
  allin="$allin KILL=$sb/fkill SUDO=$sb/fsudo IDCMD=$sb/fid MKDIR=$sb/fmkdir RMDIR=$sb/frmdir RM=$sb/frm TEE=$sb/ftee"
  for vf in IDCMD:hlink GETENT:hlink KILL:hlink IDCMD:fcopy; do
    rm -f -- "$work/ESCAPED"
    # shellcheck disable=SC2086 # $allin is one VAR=word per field, no spaces inside a word
    runcase "sudolink-${vf%%:*}-${vf#*:}" 77 "${vf%%:*} resolves to sudo" "PATH=$work/pathbin:$PATH" $allin \
      "${vf%%:*}=$sb/${vf#*:}" && escaped "sudolink-${vf%%:*}-${vf#*:}" -
  done
  # shellcheck disable=SC2086
  runcase sudolink-good 0 'user-manager-restart PASS' $allin
  # A1488 D3: sentinels first on PATH never run from fsudo or a fake: mkdir/rm/rmdir/tee plus fsudo's own
  # realpath/dirname/cat for direct fsudo calls; only mkdir/rm/rmdir/tee for a child run (A1500 case a1500-good covers
  # realpath/dirname, which the test's checks run from /usr/bin)
  sp=$work/sentpath sp4=$work/sentpath4; mkdir -p "$sp" "$sp4"
  for m in mkdir rm rmdir tee realpath dirname cat; do
    printf '#!/bin/sh\n: > "%s"\n' "$work/ESCAPED" > "$sp/$m" && chmod +x "$sp/$m" || exit 2
  done
  for m in mkdir rm rmdir tee; do cp -- "$sp/$m" "$sp4/$m" || exit 2; done
  export STATE=$work/sentinel-direct; mkdir -p "$STATE"
  for c in "fmkdir -- $STATE/d" "ftee $STATE/f" "frm -f -- $STATE/f" "frmdir -- $STATE/d"; do
    rm -f -- "$work/ESCAPED"
    # shellcheck disable=SC2086 # $c is the fake name plus its plain-word args
    PATH="$sp:$PATH" "$bin/fsudo" -n "$bin"/$c </dev/null >/dev/null 2>&1; rc=$?
    if [ "$rc" = 0 ] && [ ! -e "$work/ESCAPED" ]; then npass=$((npass + 1))
    else echo "FAIL case sentinel-direct $c: rc $rc, ESCAPED $([ -e "$work/ESCAPED" ] && echo yes || echo no)"; nfail=$((nfail + 1)); fi
  done
  rm -f -- "$work/ESCAPED"
  runcase sentinel-run 0 'user-manager-restart PASS' "PATH=$sp4:$PATH"
  if [ -e "$work/ESCAPED" ]; then echo "FAIL case sentinel-run: ESCAPED"; nfail=$((nfail + 1)); else npass=$((npass + 1)); fi
  runcase sentinel-baseline 0 'user-manager-restart PASS'
  # A1486: RUNDIR is one word like the command variables: rc 77 before any command runs
  mkdir -p "$work/a b"
  n=0
  for r in '/tmp/a b' "$work/a b" "$work/run;x"; do
    n=$((n + 1)); rm -f -- "$work/ESCAPED"
    runcase "rundir-word$n" 77 'RUNDIR is not a single word' "RUNDIR=$r" && escaped "rundir-word$n" -
  done
  mkdir -p "$work/rundir-good"
  runcase rundir-good 0 'user-manager-restart PASS' "RUNDIR=$work/rundir-good"
  # nothing <case>: no ESCAPED and no calls.log (no fake ran)
  nothing() {
    if [ -e "$work/ESCAPED" ] || [ -e "$work/$1/calls.log" ]; then
      echo "FAIL case $1: a command ran (ESCAPED or calls.log present):"; cat "$work/$1/calls.log" 2>/dev/null
      nfail=$((nfail + 1)); return 1
    fi
    npass=$((npass + 1))
  }
  # A1488 rev 8 F2: RESTART_WAIT/STOP_WAIT not 1-4 ASCII digits -> rc 77 before any command runs; the a[$(cmd)]
  # subscript, which Bash arithmetic would expand, never reaches (( )); PATH[...] names a set variable, so under set -u
  # its subscript runs (a[...] stops at the unset a)
  inj="a[\$($work/marker.sh)]" injp="PATH[\$($work/marker.sh)]"
  n=0
  for vv in "RESTART_WAIT=$inj" "STOP_WAIT=$inj" "RESTART_WAIT=$injp" "STOP_WAIT=$injp" RESTART_WAIT= RESTART_WAIT=-1 RESTART_WAIT=1x 'RESTART_WAIT=1 2' RESTART_WAIT=12345; do
    n=$((n + 1)); rm -f -- "$work/ESCAPED"
    runcase "wait-bad$n" 77 "${vv%%=*} is not 1-4 ASCII digits" "$vv" && nothing "wait-bad$n"
  done
  runcase wait-good 0 'user-manager-restart PASS' RESTART_WAIT=3 STOP_WAIT=3
  runcase wait-leading0 0 'user-manager-restart PASS' RESTART_WAIT=08 STOP_WAIT=09
  # F2: NRestarts printed malformed before (FAKE_N0) or after (FAKE_N1) the fake kill -> rc 2 naming the field, no
  # ESCAPED; after the last NRestarts read calls.log holds only the owned cleanup, in order; no kill when n0 is bad
  for ph in 0 1; do
    n=0
    for val in "$inj" "$injp" '' 3x; do
      n=$((n + 1)) c=nr$ph-bad$n; rm -f -- "$work/ESCAPED"
      runcase "$c" 2 'NRestarts of user@990.service is not all ASCII digits' "FAKE_N$ph=$val" || continue
      log=$work/$c/calls.log dd=$work/$c/run/user@990.service.d
      owned=$(sed -n 's/^useradd .* \(umtest-[0-9a-f]\{8\}\)$/\1/p' "$log")
      after=$(awk '/ -p NRestarts /{b=""; next} {b=b $0 "\n"} END{printf "%s", b}' "$log")
      want=$(printf '%s\n' 'systemctl stop user@990.service' "rm -f -- $dd/10-restart-on-abnormal.conf" "rmdir -- $dd" \
        'systemctl daemon-reload' "userdel $owned")
      kills=$(grep -c '^kill ' "$log")
      if [ -e "$work/ESCAPED" ] || [ -z "$owned" ] || [ "$after" != "$want" ] || [ "$kills" != "$ph" ]; then
        echo "FAIL case $c: ESCAPED, kill count $kills (want $ph) or calls after the read not owned cleanup only:"
        cat "$log"; nfail=$((nfail + 1))
      else
        npass=$((npass + 1))
      fi
    done
  done
  runcase nr-good 0 'nrestarts=0->1' FAKE_N0=0 FAKE_N1=1
  # F1: the generator writes every fake 755 whatever the umask (this driver runs under the caller's umask)
  bad=$(find "$bin" -type f ! -perm 755 -printf '%m %f\n')
  if [ -z "$bad" ]; then npass=$((npass + 1)); else echo "FAIL case fakes-755: $bad"; nfail=$((nfail + 1)); fi
  # F1: a group/world-writable dir between the root and the bindir, or a fake mode 666 or g+w -> rc 77, nothing ran
  for f1 in middir:777 fkill:666 fgetent:g+w good:-; do
    t=${f1%%:*} nb=$work/f1-${f1%%:*}/mid/bin
    bash "$here/fixtures/user-manager-restart-fakes.sh" "$nb" || exit 2
    case $t in middir) chmod 777 -- "${nb%/bin}";; good) ;; *) chmod "${f1#*:}" -- "$nb/$t";; esac || exit 2
    rm -f -- "$work/ESCAPED"
    # shellcheck disable=SC2086 # $allin is one VAR=word per field, no spaces inside a word
    case $t in
      good) runcase f1-good 0 'user-manager-restart PASS' ${allin//"$sb"/"$nb"};;
      middir) runcase f1-middir 77 "dir ${nb%/bin} between .* is not of uid" ${allin//"$sb"/"$nb"} && nothing f1-middir;;
      *) runcase "f1-$t" 77 "target $nb/$t is not a file of uid" ${allin//"$sb"/"$nb"} && nothing "f1-$t";;
    esac
  done
  # F4: a copy of fsudo as IDCMD with a cmp stub first on PATH exiting 127 (= missing) or 2 -> rc 77; since A1500 the
  # compare uses /usr/bin or /bin cmp, never the PATH stub, so the copy is refused as sudo
  cs=$work/cmpstub; mkdir -p "$cs"
  for crc in 127 2; do
    printf '#!/bin/sh\nexit %s\n' "$crc" > "$cs/cmp" && chmod 755 "$cs/cmp" || exit 2
    rm -f -- "$work/ESCAPED"
    # shellcheck disable=SC2086
    runcase "cmp$crc-copy" 77 'IDCMD resolves to sudo' "PATH=$cs:$work/pathbin:$PATH" $allin \
      "IDCMD=$sb/fcopy" && nothing "cmp$crc-copy"
  done
  # F3: a command variable with a non-ASCII letter (e-acute) under LC_ALL=C.UTF-8 is not a single word: rc 77
  nb=$work/f3/bin
  bash "$here/fixtures/user-manager-restart-fakes.sh" "$nb" && cp -- "$nb/fkill" "$nb/fkill"$'\303\251' || exit 2
  rm -f -- "$work/ESCAPED"
  # shellcheck disable=SC2086
  runcase f3-utf8 77 'variable KILL is not a single word' LC_ALL=C.UTF-8 ${allin//"$sb"/"$nb"} \
    "KILL=$nb/fkill"$'\303\251' && nothing f3-utf8
  # shellcheck disable=SC2086
  runcase f3-good 0 'user-manager-restart PASS' LC_ALL=C.UTF-8 ${allin//"$sb"/"$nb"}
  # A1499: MainPID printed malformed, 0 or 1 before the kill (FAKE_P0) -> rc 2 with no kill line; malformed or 1 after
  # the kill (FAKE_P1) -> rc 2 with only the owned kill of 4200; no ESCAPED, the owned account removed once
  for ph in 0 1; do
    n=0
    for val in 00 0 1 007 12345678901 '' "$inj" "$injp"; do
      [ "$ph$val" = 10 ] && continue
      n=$((n + 1)) c=pid$ph-bad$n; rm -f -- "$work/ESCAPED"
      runcase "$c" 2 'MainPID of user@990.service is not a pid' "FAKE_P$ph=$val" || continue
      log=$work/$c/calls.log
      owned=$(sed -n 's/^useradd .* \(umtest-[0-9a-f]\{8\}\)$/\1/p' "$log")
      kills=$(grep '^kill ' "$log") wk=
      [ "$ph" = 1 ] && wk='kill -KILL 4200'
      if [ -e "$work/ESCAPED" ] || [ -z "$owned" ] || [ "$kills" != "$wk" ] ||
         [ "$(grep -c '^userdel ' "$log")" != 1 ] || ! grep -qx "userdel $owned" "$log"; then
        echo "FAIL case $c: ESCAPED, kill lines '$kills' (want '$wk') or userdel not owned-only:"; cat "$log"; nfail=$((nfail + 1))
      else
        npass=$((npass + 1))
      fi
    done
  done
  # A1499: 0 after the kill is "no main process yet" (systemd's value while restarting): no restart -> rc 1
  runcase pid1-zero 1 'no restart within' FAKE_P1=0
  runcase pid-good 0 'old=4200 new=4201' FAKE_P0=4200
  runcase pid-good2 0 'old=4200 new=4202' FAKE_P0=4200 FAKE_P1=4202
  # A1500: stubs first on PATH named cmp/stat/id (lying, each leaves ESCAPED) never run; the unsafe fixture each would
  # hide is still refused rc 77 by the /usr/bin tools: a byte copy of fsudo as IDCMD (cmp stub exits 1 = differ), a
  # 777 middle dir (stat stub prints 755 and the caller uid), a KILL whose target is root-owned (id stub)
  st=$work/a1500; mkdir -p "$st/cmp" "$st/stat" "$st/id" "$st/realpath" "$st/dirname" "$st/all"
  printf '#!/bin/sh\n: > "%s"\nexit 1\n' "$work/ESCAPED" > "$st/cmp/cmp"
  # shellcheck disable=SC2016 # $* and $UID belong to the stub
  printf '#!/bin/bash\n: > "%s"\ncase "$*" in *%%a*) echo 755;; *) echo "$UID";; esac\n' "$work/ESCAPED" > "$st/stat/stat"
  # shellcheck disable=SC2016
  printf '#!/bin/bash\n: > "%s"\necho "$UID"\n' "$work/ESCAPED" > "$st/id/id"
  for m in realpath dirname; do printf '#!/bin/sh\n: > "%s"\nexec /usr/bin/%s "$@"\n' "$work/ESCAPED" "$m" > "$st/$m/$m"; done
  for m in cmp stat id realpath dirname; do chmod 755 "$st/$m/$m" && cp -- "$st/$m/$m" "$st/all/$m" || exit 2; done
  nb=$work/a1500fx/mid/bin
  bash "$here/fixtures/user-manager-restart-fakes.sh" "$nb" && ln -s -- /usr/bin/true "$nb/froot" || exit 2
  rm -f -- "$work/ESCAPED"
  # shellcheck disable=SC2086 # $allin is one VAR=word per field, no spaces inside a word
  runcase a1500-cmp 77 'IDCMD resolves to sudo' "PATH=$st/cmp:$PATH" $allin "IDCMD=$sb/fcopy" && nothing a1500-cmp
  chmod 777 -- "${nb%/bin}" || exit 2
  rm -f -- "$work/ESCAPED"
  # shellcheck disable=SC2086
  runcase a1500-stat 77 "dir ${nb%/bin} between .* is not of uid" "PATH=$st/stat:$PATH" ${allin//"$sb"/"$nb"} &&
    nothing a1500-stat
  chmod 755 -- "${nb%/bin}" || exit 2
  rm -f -- "$work/ESCAPED"
  # shellcheck disable=SC2086
  runcase a1500-id 77 'variable KILL target /.* is not a file of uid' "PATH=$st/id:$PATH" ${allin//"$sb"/"$nb"} \
    "KILL=$nb/froot" && nothing a1500-id
  # GREEN: every stub (cmp stat id realpath dirname) first on PATH over a 755 tree: PASS and no stub ran
  rm -f -- "$work/ESCAPED"
  # shellcheck disable=SC2086
  runcase a1500-good 0 'user-manager-restart PASS' "PATH=$st/all:$PATH" ${allin//"$sb"/"$nb"}
  if [ -e "$work/ESCAPED" ]; then echo "FAIL case a1500-good: a PATH stub ran (ESCAPED)"; nfail=$((nfail + 1)); else npass=$((npass + 1)); fi
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
RESTART_WAIT=${RESTART_WAIT-15}
STOP_WAIT=${STOP_WAIT-10}
# A1500: the tools the checks below rely on (cmp, stat, id, realpath, dirname) come from /usr/bin or /bin only, never
# from the caller's PATH: the first of the two that exists is used, and it (and a symlink's final file) must be a
# regular, root-owned, executable file with no group/other write bit, else SKIP 77 before any command runs. stat is
# checked by itself. The command variables (CMDVARS) are not affected.
sysbin() {
  local p m
  for p in "/usr/bin/$1" /bin/"$1"; do [ -e "$p" ] || [ -L "$p" ] && break; p=; done
  [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ] || return 1
  m=$(LC_ALL=C "$STAT" -L -c '%u %a' -- "$p") || return 1
  case $m in "0 "[01234567][0145][0145]|"0 "[01234567][01234567][0145][0145]) ;; *) return 1;; esac
  if [ -L "$p" ]; then m=$(LC_ALL=C "$STAT" -c %u -- "$p") && [ "$m" = 0 ] || return 1; fi
  printf '%s\n' "$p"
}
STAT=/usr/bin/stat; [ -e "$STAT" ] || [ -L "$STAT" ] || STAT=/bin/stat
if ! { [ -f "$STAT" ] && [ -x "$STAT" ] && STAT=$(sysbin stat); }; then echo "SKIP: no root-owned stat in /usr/bin or /bin"; exit 77; fi
for t in CMP:cmp ID:id REALPATH:realpath DIRNAME:dirname; do
  p=$(sysbin "${t#*:}") || { echo "SKIP: no root-owned, go-w executable ${t#*:} in /usr/bin or /bin"; exit 77; }
  printf -v "${t%%:*}" '%s' "$p"
done
for v in RESTART_WAIT STOP_WAIT; do
  case ${!v} in ''|*[!0123456789]*|?????*) echo "SKIP: $v is not 1-4 ASCII digits: '${!v}'"; exit 77;; esac
done
for v in $CMDVARS RUNDIR; do
  case ${!v} in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./+@-]*)
      echo "SKIP: variable $v is not a single word: ${!v}"; exit 77;;
  esac
done
# A1488 (a): resolved target of a command word (command -v, then realpath -e), empty if none
target() { local p; p=$(command -v -- "$1" 2>/dev/null) && [ "${p#/}" != "$p" ] && "$REALPATH" -e -- "$p" 2>/dev/null; }
sudo_rp=$(target "$SUDO")
# the sudo files: $SUDO's target and a fsudo in UMTEST_FAKEBIN; a hardlink (-ef) or a copy (cmp -s) of one is sudo too
sudos=()
[ -n "$sudo_rp" ] && sudos+=("$sudo_rp")
[ -n "${UMTEST_FAKEBIN:-}" ] && [ -f "$UMTEST_FAKEBIN/fsudo" ] && sudos+=("$UMTEST_FAKEBIN/fsudo")
# rc 0 = sudo, 1 = not sudo, 2 = cmp could not compare (missing, unreadable): the caller refuses, never passes
issudo() {
  local s r
  for s in "${sudos[@]}"; do
    [ "$1" -ef "$s" ] && return 0
    "$CMP" -s -- "$1" "$s"; r=$?
    case $r in 0) return 0;; 1) ;; *) return 2;; esac
  done
  return 1
}
for v in $CMDVARS; do
  [ "$v" = SUDO ] && continue
  rp=$(target "${!v}") isu=1
  if [ -n "$rp" ]; then issudo "$rp"; isu=$?; fi
  [ "$isu" = 2 ] && { echo "SKIP: command variable $v ($rp): byte-identity compare with sudo failed (cmp unavailable)"; exit 77; }
  if [ "${rp##*/}" = fsudo ] || [ "${!v##*/}" = fsudo ] || [ "$isu" = 0 ]; then
    echo "SKIP: command variable $v resolves to sudo (${rp:-${!v}}); sudo is only the SUDO prefix"; exit 77
  fi
done
# A1488 (b): fixture-root containment of a set UMTEST_FAKEBIN outside live mode
# gowok <path>: stat mode is 1-4 octal digits (checked before the arithmetic) with no group/other write bit
gowok() { local m; m=$("$STAT" -c %a -- "$1") || return 1; case $m in ''|*[!01234567]*|?????*) return 1;; esac; (( (8#$m & 8#022) == 0 )); }
safedir() { [ -d "$1" ] && [ "$("$STAT" -c %u -- "$1")" = "$("$ID" -u)" ] && gowok "$1"; }
safefile() { [ -f "$1" ] && [ "$("$STAT" -c %u -- "$1")" = "$("$ID" -u)" ] && gowok "$1"; }
if [ -n "${UMTEST_FAKEBIN:-}" ] && [ "${UMTEST_LIVE:-0}" != 1 ]; then
  fb=$("$REALPATH" -e -- "$UMTEST_FAKEBIN" 2>/dev/null) || { echo "SKIP: UMTEST_FAKEBIN $UMTEST_FAKEBIN does not resolve"; exit 77; }
  safedir "$fb" || { echo "SKIP: UMTEST_FAKEBIN $fb is not a dir of uid $("$ID" -u) or is group/world-writable"; exit 77; }
  fx=$("$REALPATH" -e -- "$("$DIRNAME" -- "$0")/fixtures" 2>/dev/null) || fx=/nonexistent
  fr=
  if [ -n "${UMTEST_FAKEROOT:-}" ]; then
    fr=$("$REALPATH" -e -- "$UMTEST_FAKEROOT" 2>/dev/null) || fr=
    case ${fr##*/} in umtest-fake.??????) ;; *) fr=;; esac
    case ${fr##*/umtest-fake.} in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*) fr=;; esac
    if [ -z "$fr" ] || ! safedir "$fr"; then echo "SKIP: UMTEST_FAKEROOT $UMTEST_FAKEROOT is not an umtest-fake.XXXXXX dir of uid $("$ID" -u), mode go-w"; exit 77; fi
  fi
  root=
  case $fb in "$fx"/*) root=$fx;; esac
  [ -n "$fr" ] && case $fb in "$fr"/*) root=$fr;; esac
  [ -n "$root" ] || { echo "SKIP: UMTEST_FAKEBIN $fb is not under the mktemp root or $fx"; exit 77; }
  # F1: every dir from the root down to the bindir (both included) passes the dir rule
  p=$fb
  while :; do
    safedir "$p" || { echo "SKIP: dir $p between $root and UMTEST_FAKEBIN is not of uid $("$ID" -u) or is group/world-writable"; exit 77; }
    [ "$p" = "$root" ] && break
    p=${p%/*}
  done
  # F1: every command variable's target file is this uid's and not group/world-writable (an absolute word that
  # command -v skips, e.g. a non-executable mode-666 file, is resolved by realpath -e)
  for v in $CMDVARS; do
    rp=$(target "${!v}") || rp=$("$REALPATH" -e -- "${!v}" 2>/dev/null) || rp=
    [ -z "$rp" ] || safefile "$rp" ||
      { echo "SKIP: command variable $v target $rp is not a file of uid $("$ID" -u) or is group/world-writable"; exit 77; }
  done
fi

# live unless every command is an absolute path that resolves (realpath) into the fixture bindir, and that bindir is not a system directory;
# anything under a system path, or anywhere else, counts as live and needs UMTEST_LIVE=1
sysdir() { case $1 in /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/opt|/opt/*|/snap|/snap/*) return 0;; esac; return 1; }
fakebin=$("$REALPATH" -- "${UMTEST_FAKEBIN:-/nonexistent}" 2>/dev/null) || fakebin=
live=0
[ -n "$fakebin" ] && ! sysdir "$fakebin" || live=1
for v in $CMDVARS; do
  case ${!v} in /*) ;; *) live=1; continue;; esac
  if ! rp=$("$REALPATH" -e -- "${!v}" 2>/dev/null); then live=1; continue; fi
  sysdir "$rp" && live=1
  [ "$("$DIRNAME" -- "$rp")" = "$fakebin" ] || live=1
done
rr=$("$REALPATH" -m -- "$RUNDIR")
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
# a uid is 1-10 ASCII digits (no sign, space or empty), so every compare below gets an integer
isuid() { case $1 in ''|*[!0123456789]*) return 1;; esac; [ "${#1}" -le 10 ]; }
# a count/pid read from systemctl is 1-18 ASCII digits, checked before it reaches any compare or $(( ))
isnum() { case $1 in ''|*[!0123456789]*) return 1;; esac; [ "${#1}" -le 18 ]; }
# A1499: a MainPID is 1-10 ASCII digits with no leading 0 (0, 00, 007 refused) and is not 1 (init), checked by a
# pattern only (no arithmetic), right after the read and before any kill or compare
ispid() { case $1 in ''|0*|1|*[!0123456789]*|???????????*) return 1;; esac; }
# caller uid before any account is made: IDCMD must exit 0 and print one uid, else nothing has run to clean up
cu=$("$IDCMD" -u 2>/dev/null) || abort "IDCMD $IDCMD -u failed (rc $?)"
isuid "$cu" || abort "IDCMD $IDCMD -u printed no all-digit uid: '$cu'"

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
isuid "$uid" || abort "no all-digit uid for $UMUSER: '$uid'"
[ "$uid" -ne 1000 ] || abort "scratch uid is 1000"
[ "$uid" -ne "$cu" ] || abort "scratch uid $uid equals caller uid ($IDCMD -u)"
[ "$uid" -ge 900 ] || abort "scratch uid $uid < 900"

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

old=$(prop MainPID)
ispid "$old" || abort "MainPID of $unit is not a pid (1-10 digits, no leading 0, not 1) before SIGKILL: '$old'"
n0=$(prop NRestarts)
isnum "$n0" || abort "NRestarts of $unit is not all ASCII digits before SIGKILL: '$n0'"

# step 1: SIGKILL the manager -> restarted within RESTART_WAIT with a new MainPID and NRestarts+1
"$SUDO" -n "$KILL" -KILL "$old"
new='' n1=''
for ((i = 0; i < 10#$RESTART_WAIT; i++)); do
  sleep 1
  new=$(prop MainPID)
  # 0 = no main process yet (systemd prints 0 between the kill and the restart); anything else must be a pid
  [ "$new" = 0 ] || ispid "$new" || abort "MainPID of $unit is not a pid (1-10 digits, no leading 0, not 1) after SIGKILL: '$new'"
  n1=$(prop NRestarts)
  isnum "$n1" || abort "NRestarts of $unit is not all ASCII digits after SIGKILL: '$n1'"
  [ "$(prop ActiveState)" = active ] && [ -n "$new" ] && [ "$new" != 0 ] && [ "$new" != "$old" ] && break
  new=
done
[ -n "$new" ] || fail 1 "no restart within ${RESTART_WAIT}s after SIGKILL of $old"
[ "$n1" -eq "$((10#$n0 + 1))" ] || fail 1 "NRestarts $n0 -> $n1, expected +1"

# step 2: the restarted manager is running
[ "$(prop SubState)" = running ] || fail 2 "SubState=$(prop SubState), expected running"

# step 3: a clean stop is not restarted
"$SUDO" -n "$SYSTEMCTL" stop "$unit" || fail 3 "stop $unit"
for ((i = 0; i < 10#$STOP_WAIT; i++)); do
  sleep 1
  [ "$(prop ActiveState)" = active ] && fail 3 "$unit active again ${i}s after a clean stop"
done

echo "user-manager-restart PASS user=$UMUSER uid=$uid old=$old new=$new nrestarts=$n0->$n1"
