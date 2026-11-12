#!/bin/bash
# rb-suite-unit.sh - start a suite/verifier run as a durable systemd user unit with the fleet's no-cap argv (A1304).
#   rb-suite-unit.sh [--dry] [--setenv K=V]... UNIT WORKDIR OUTFILE -- CMD [ARG]...
#   rb-suite-unit.sh --selftest
# The unit carries -p TasksMax=infinity -p MemoryMax=infinity -p IOWeight=50: a transient unit otherwise inherits the user slice's
# TasksMax (33183 on RB), the cap ctl lifted runtime-only on rb-sd-a1573-suite 11-12 8:37 AM (row d-20261112-083731-ctl-b3c0); same
# argv as aide-verifier.sh (C187, Hermes 11-08 W11) and seat-event.sh (A1466). CMD's stdout+stderr go to OUTFILE, then one line
# EXIT=<rc>, so a waiter polls `grep -c ^EXIT= OUTFILE` and the run survives the launching ssh session.
# OUTFILE (rev 2, Hermes 8:50 AM on e39cefc: a dangling symlink passed the -e check and the payload created its target):
#   the launcher refuses any symlink at OUTFILE, then creates it with noclobber (`set -C`, O_CREAT|O_EXCL, which never follows a
#   symlink), so of two launches on one OUTFILE exactly one creates it and reaches systemd-run. The payload opens OUTFILE read-only
#   (no O_CREAT), checks the opened inode is the dev:inode the launcher created, and appends through that descriptor; a swap to a
#   symlink or another file between launch and start exits 97 and writes nothing. A failed systemd-run removes the empty OUTFILE.
# Refuses (exit 2): UNIT not rb-<lowercase/digits/->, WORKDIR not a directory, OUTFILE a symlink / present / not creatable
# exclusively, its directory missing, no `--`/CMD. SD_RUN overrides systemd-run (tests). rb's own hand units go through here
# (hook rb-hand-unit-gate.sh denies a hand `systemd-run --unit rb-*` from the rb seat).
set -u
SD_RUN=${SD_RUN:-systemd-run}
# $0 = dev:inode the launcher created, $1 = OUTFILE, $2.. = CMD
PAYLOAD='exec 4<"$1" || exit 97; [ "$(stat -L -c %d:%i /dev/fd/4)" = "$0" ] || { echo "rb-suite-unit: OUTFILE $1 is not the file the launcher created" >&2; exit 97; }; exec 3>>/dev/fd/4 4<&- || exit 97; "${@:2}" >&3 2>&3; echo "EXIT=$?" >&3'

refuse() { echo "rb-suite-unit: REFUSED $*" >&2; exit 2; }

build_argv() {  # sets ARGV and DEVINO; $1 = 1 to create OUTFILE (launch) or 0 (--dry); then the command line
  local create=$1 setenv=() unit wd out; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --setenv) [ $# -ge 2 ] || refuse "--setenv needs K=V"; case "$2" in [A-Za-z_]*=*) ;; *) refuse "--setenv '$2' is not K=V" ;; esac
                setenv+=("--setenv=$2"); shift 2 ;;
      *) break ;;
    esac
  done
  [ $# -ge 5 ] && [ "$4" = -- ] || refuse "usage: [--setenv K=V]... UNIT WORKDIR OUTFILE -- CMD [ARG]..."
  unit=$1 wd=$2 out=$3; shift 4
  [[ "$unit" =~ ^rb-[a-z0-9][a-z0-9-]*$ ]] || refuse "unit '$unit' is not rb-<lowercase/digits/->"
  [ -d "$wd" ] || refuse "workdir '$wd' is not a directory"
  [ -L "$out" ] && refuse "outfile '$out' is a symlink"
  [ -e "$out" ] && refuse "outfile '$out' already exists (no overwrite)"
  [ -d "$(dirname "$out")" ] || refuse "outfile directory '$(dirname "$out")' is missing"
  DEVINO=DRY
  if [ "$create" = 1 ]; then
    ( set -C; : > "$out" ) 2>/dev/null || refuse "outfile '$out' could not be created exclusively (exists, symlink, or another launch won)"
    [ ! -L "$out" ] && [ -f "$out" ] && DEVINO=$(stat -c %d:%i -- "$out") || refuse "outfile '$out' changed right after creation"
  fi
  OUT=$out
  ARGV=("$SD_RUN" --user --unit "$unit" --collect -p TasksMax=infinity -p MemoryMax=infinity -p IOWeight=50
        -p "WorkingDirectory=$wd" "${setenv[@]}"
        /bin/bash -c "$PAYLOAD" "$DEVINO" "$out" "$@")
}

selftest() {
  local fail=0 rc log i
  T=$(mktemp -d) || exit 1   # global: the EXIT trap runs after this function returns
  trap 'rm -rf "$T"' EXIT
  chk() { if [ "$2" = 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/sdrun.log"\n' "$T" > "$T/fake-sdrun"; chmod +x "$T/fake-sdrun"
  mkdir "$T/wd" "$T/o"
  SD_RUN=$T/fake-sdrun "$0" --setenv WM_DECIDE_SUITE=1 rb-sd-x1 "$T/wd" "$T/o/out.txt" -- python3 -m unittest -v >/dev/null 2>&1; rc=$?
  log=$(cat "$T/sdrun.log" 2>/dev/null)
  chk "launch rc 0" "$rc"
  [[ "$log" == "--user --unit rb-sd-x1 --collect -p TasksMax=infinity -p MemoryMax=infinity -p IOWeight=50 -p WorkingDirectory=$T/wd --setenv=WM_DECIDE_SUITE=1 /bin/bash -c "* ]]; chk "argv: unit, collect, TasksMax=infinity, MemoryMax=infinity, IOWeight=50, WorkingDirectory, setenv" $?
  [[ "$log" == *" $(stat -c %d:%i "$T/o/out.txt") $T/o/out.txt python3 -m unittest -v" ]]; chk "argv ends with the created OUTFILE's dev:inode, OUTFILE, CMD" $?
  [ -f "$T/o/out.txt" ] && [ ! -L "$T/o/out.txt" ] && [ ! -s "$T/o/out.txt" ]; chk "launch created OUTFILE empty and regular" $?
  [[ "$log" != *MemoryHigh* ]]; chk "no MemoryHigh" $?
  # the payload: CMD output then EXIT=<rc> land in OUTFILE; a different inode or a symlink exits 97 and writes nothing
  : > "$T/o/p.txt"
  /bin/bash -c "$PAYLOAD" "$(stat -c %d:%i "$T/o/p.txt")" "$T/o/p.txt" sh -c 'echo hi; echo err >&2; exit 3'
  [ "$(cat "$T/o/p.txt")" = "$(printf 'hi\nerr\nEXIT=3')" ]; chk "payload writes output then EXIT=3" $?
  : > "$T/o/q.txt"; : > "$T/o/other.txt"
  /bin/bash -c "$PAYLOAD" "$(stat -c %d:%i "$T/o/other.txt")" "$T/o/q.txt" echo x 2>/dev/null; rc=$?
  [ "$rc" = 97 ] && [ ! -s "$T/o/q.txt" ]; chk "payload: OUTFILE inode differs from the created one -> 97, nothing written" $?
  ln -s "$T/o/dangle-target" "$T/o/dl.txt"
  /bin/bash -c "$PAYLOAD" "1:1" "$T/o/dl.txt" echo x 2>/dev/null; rc=$?
  [ "$rc" = 97 ] && [ ! -e "$T/o/dangle-target" ]; chk "payload: OUTFILE swapped to a dangling symlink -> 97, target not created" $?
  # launcher refusals
  : > "$T/sdrun.log"
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x2 "$T/wd" "$T/o/p.txt" -- true 2>/dev/null; rc=$?
  [ "$rc" = 2 ]; chk "existing OUTFILE refused" $?
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x8 "$T/wd" "$T/o/dl.txt" -- true 2>/dev/null; rc=$?
  [ "$rc" = 2 ] && [ ! -e "$T/o/dangle-target" ]; chk "dangling-symlink OUTFILE refused, target not created" $?
  echo keep > "$T/o/victim"; ln -s "$T/o/victim" "$T/o/sl.txt"
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x9 "$T/wd" "$T/o/sl.txt" -- true 2>/dev/null; rc=$?
  [ "$rc" = 2 ] && [ "$(cat "$T/o/victim")" = keep ]; chk "symlink-to-file OUTFILE refused, target unchanged" $?
  SD_RUN=$T/fake-sdrun "$0" "Bad Unit" "$T/wd" "$T/o/n1.txt" -- true 2>/dev/null; [ $? = 2 ]; chk "bad unit name refused" $?
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x3 "$T/nowd" "$T/o/n2.txt" -- true 2>/dev/null; [ $? = 2 ]; chk "missing WORKDIR refused" $?
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x4 "$T/wd" "$T/nodir/n3.txt" -- true 2>/dev/null; [ $? = 2 ]; chk "missing OUTFILE directory refused" $?
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x5 "$T/wd" "$T/o/n4.txt" true 2>/dev/null; [ $? = 2 ]; chk "missing -- refused" $?
  SD_RUN=$T/fake-sdrun "$0" --setenv NOEQ rb-sd-x6 "$T/wd" "$T/o/n5.txt" -- true 2>/dev/null; [ $? = 2 ]; chk "--setenv without K=V refused" $?
  [ ! -s "$T/sdrun.log" ]; chk "no refusal reached systemd-run" $?
  # concurrent: 8 launches on one OUTFILE -> exactly one rc 0 and one systemd-run call
  for i in 1 2 3 4 5 6 7 8; do ( SD_RUN=$T/fake-sdrun "$0" "rb-sd-c$i" "$T/wd" "$T/o/race.txt" -- true 2>/dev/null; echo $? > "$T/rc.$i" ) & done; wait
  [ "$(cat "$T"/rc.* | grep -c '^0$')" = 1 ] && [ "$(cat "$T"/rc.* | grep -c '^2$')" = 7 ] && [ "$(grep -c . "$T/sdrun.log")" = 1 ]
  chk "8 concurrent launches on one OUTFILE: one rc 0, seven rc 2, one systemd-run call" $?
  # a failed systemd-run leaves no OUTFILE behind, so a retry is not refused
  printf '#!/bin/bash\nexit 1\n' > "$T/fail-sdrun"; chmod +x "$T/fail-sdrun"
  SD_RUN=$T/fail-sdrun "$0" rb-sd-xf "$T/wd" "$T/o/f.txt" -- true 2>/dev/null; rc=$?
  [ "$rc" = 1 ] && [ ! -e "$T/o/f.txt" ]; chk "failed systemd-run: rc passed through, empty OUTFILE removed" $?
  : > "$T/sdrun.log"
  out=$(SD_RUN=$T/fake-sdrun "$0" --dry rb-sd-x7 "$T/wd" "$T/o/n6.txt" -- echo a) && [[ "$out" == *"-p TasksMax=infinity -p MemoryMax=infinity"* ]] && [ ! -s "$T/sdrun.log" ] && [ ! -e "$T/o/n6.txt" ]
  chk "--dry prints the argv, creates nothing and does not launch" $?
  return $fail
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --dry) shift; build_argv 0 "$@"; printf '%q ' "${ARGV[@]}"; echo; exit 0 ;;
  *) build_argv 1 "$@"
     "${ARGV[@]}"; rc=$?
     if [ "$rc" != 0 ] && [ ! -L "$OUT" ] && [ ! -s "$OUT" ] && [ "$(stat -c %d:%i -- "$OUT" 2>/dev/null)" = "$DEVINO" ]; then rm -f -- "$OUT"; fi
     exit "$rc" ;;
esac
