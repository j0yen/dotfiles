#!/bin/bash
# rb-suite-unit.sh - start a suite/verifier run as a durable systemd user unit with the fleet's no-cap argv (A1304).
#   rb-suite-unit.sh [--dry] [--setenv K=V]... UNIT WORKDIR OUTFILE -- CMD [ARG]...
#   rb-suite-unit.sh --selftest
# The unit carries -p TasksMax=infinity -p MemoryMax=infinity -p IOWeight=50: a transient unit otherwise inherits the user slice's
# TasksMax (33183 on RB), the cap ctl lifted runtime-only on rb-sd-a1573-suite 11-12 8:37 AM (row d-20261112-083731-ctl-b3c0); same
# argv as aide-verifier.sh (C187, Hermes 11-08 W11) and seat-event.sh (A1466). CMD's stdout+stderr go to OUTFILE, then one line
# EXIT=<rc>, so a waiter polls `grep -c ^EXIT= OUTFILE` and the run survives the launching ssh session.
# Refuses (exit 2): UNIT not rb-<lowercase/digits/->, WORKDIR not a directory, OUTFILE already present or its directory missing, no `--`/CMD.
# SD_RUN overrides systemd-run (selftest).
set -u
SD_RUN=${SD_RUN:-systemd-run}

refuse() { echo "rb-suite-unit: REFUSED $*" >&2; exit 2; }

build_argv() {  # sets ARGV; $@ = full command line minus --dry
  local setenv=() unit wd out
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
  [ -e "$out" ] && refuse "outfile '$out' already exists (no overwrite)"
  [ -d "$(dirname "$out")" ] || refuse "outfile directory '$(dirname "$out")' is missing"
  ARGV=("$SD_RUN" --user --unit "$unit" --collect -p TasksMax=infinity -p MemoryMax=infinity -p IOWeight=50
        -p "WorkingDirectory=$wd" "${setenv[@]}"
        /bin/bash -c '"$@" >"$0" 2>&1; echo "EXIT=$?" >>"$0"' "$out" "$@")
}

selftest() {
  local fail=0 rc log
  T=$(mktemp -d) || exit 1   # global: the EXIT trap runs after this function returns
  trap 'rm -rf "$T"' EXIT
  chk() { if [ "$2" = 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/sdrun.log"\n' "$T" > "$T/fake-sdrun"; chmod +x "$T/fake-sdrun"
  mkdir "$T/wd" "$T/o"
  SD_RUN=$T/fake-sdrun "$0" --setenv WM_DECIDE_SUITE=1 rb-sd-x1 "$T/wd" "$T/o/out.txt" -- python3 -m unittest -v >/dev/null 2>&1; rc=$?
  log=$(cat "$T/sdrun.log" 2>/dev/null)
  chk "launch rc 0" "$rc"
  [[ "$log" == "--user --unit rb-sd-x1 --collect -p TasksMax=infinity -p MemoryMax=infinity -p IOWeight=50 -p WorkingDirectory=$T/wd --setenv=WM_DECIDE_SUITE=1 /bin/bash -c "* ]]; chk "argv: unit, collect, TasksMax=infinity, MemoryMax=infinity, IOWeight=50, WorkingDirectory, setenv ($log)" $?
  [[ "$log" == *" $T/o/out.txt python3 -m unittest -v" ]]; chk "argv ends with OUTFILE then CMD" $?
  [[ "$log" != *MemoryHigh* ]]; chk "no MemoryHigh" $?
  # the payload itself: CMD output then EXIT=<rc> land in OUTFILE
  /bin/bash -c '"$@" >"$0" 2>&1; echo "EXIT=$?" >>"$0"' "$T/o/p.txt" sh -c 'echo hi; echo err >&2; exit 3'
  [ "$(cat "$T/o/p.txt")" = "$(printf 'hi\nerr\nEXIT=3')" ]; chk "payload writes output then EXIT=3" $?
  : > "$T/sdrun.log"
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x2 "$T/wd" "$T/o/p.txt" -- true 2>/dev/null; rc=$?
  [ "$rc" = 2 ] && [ ! -s "$T/sdrun.log" ]; chk "existing OUTFILE refused, systemd-run not called" $?
  SD_RUN=$T/fake-sdrun "$0" "Bad Unit" "$T/wd" "$T/o/n1.txt" -- true 2>/dev/null; [ $? = 2 ]; chk "bad unit name refused" $?
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x3 "$T/nowd" "$T/o/n2.txt" -- true 2>/dev/null; [ $? = 2 ]; chk "missing WORKDIR refused" $?
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x4 "$T/wd" "$T/nodir/n3.txt" -- true 2>/dev/null; [ $? = 2 ]; chk "missing OUTFILE directory refused" $?
  SD_RUN=$T/fake-sdrun "$0" rb-sd-x5 "$T/wd" "$T/o/n4.txt" true 2>/dev/null; [ $? = 2 ]; chk "missing -- refused" $?
  SD_RUN=$T/fake-sdrun "$0" --setenv NOEQ rb-sd-x6 "$T/wd" "$T/o/n5.txt" -- true 2>/dev/null; [ $? = 2 ]; chk "--setenv without K=V refused" $?
  [ ! -s "$T/sdrun.log" ]; chk "no refusal reached systemd-run" $?
  out=$(SD_RUN=$T/fake-sdrun "$0" --dry rb-sd-x7 "$T/wd" "$T/o/n6.txt" -- echo a) && [[ "$out" == *"-p TasksMax=infinity -p MemoryMax=infinity"* ]] && [ ! -s "$T/sdrun.log" ]
  chk "--dry prints the argv and does not launch" $?
  return $fail
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --dry) shift; build_argv "$@"; printf '%q ' "${ARGV[@]}"; echo; exit 0 ;;
  *) build_argv "$@"; exec "${ARGV[@]}" ;;
esac
