#!/usr/bin/env bash
# r7-redrive.sh <run> <from> --expect <stage> --why "<why>" --evidence "<one read>" [--reverse "<text>"] [--model M] [--after-merge] [--stop]
#   --after-merge (only with <from>=land) is forwarded to wm-build for a PR already merged (479/#534: "pr-merged: already merged").
#   --stop (any step) is forwarded to wm-build so a redrive of an OPEN run stops its driver first (ctl ddf8, r7 8:23 PM 10-27: 503 --from inner).
#   The ONLY way the r7 seat redrives a ryzen7 run by hand: the wm-decide run-state row is recorded FIRST, and
#   `wm-build run redrive <run> --from <from> --operator r7` runs on ryzen7 ONLY when the record printed a decision id.
#   A refused or id-less record exits 2 and never reaches ssh (ctl 2:1x 10-23, class 373c: a `[ -n "$R" ] &&` in a
#   one-off command line is not a mechanism; this script is).
#   Daemon-side release timers (r7-release-after) log through the watcher lib and do not come through here.
# --selftest runs every path against stub wm-decide/ssh in a mktemp dir (no real row, no ssh).
set -uo pipefail
HOST="${R7_REDRIVE_HOST:-ryzen7}"
ID_RE='d-[0-9]{8}-[0-9]{6}-[a-z0-9:-]+-[0-9a-f]{4}'
usage() { echo "usage: r7-redrive.sh <run> <inner|gate|land|live> --expect <claimed|gate|inner|land|released> --why W --evidence E [--reverse R] [--model M] [--after-merge] [--stop]" >&2; exit 64; }

redrive() {
  [ $# -ge 2 ] || usage
  local run=$1 from=$2 expect="" why="" ev="" rev="" am="" stp="" model="${R7_MODEL:-opus}"; shift 2
  while [ $# -gt 0 ]; do case $1 in
    --expect) expect=${2:-}; shift 2 ;; --why) why=${2:-}; shift 2 ;; --evidence) ev=${2:-}; shift 2 ;;
    --reverse) rev=${2:-}; shift 2 ;; --model) model=${2:-}; shift 2 ;; --after-merge) am=" --after-merge"; shift ;; --stop) stp=" --stop"; shift ;; *) echo "r7-redrive.sh: unknown arg '$1'" >&2; usage ;; esac; done
  case $run in ''|*[!0-9]*) echo "r7-redrive.sh: run must be a number, got '$run'" >&2; usage ;; esac
  case $from in inner|gate|land|live) ;; *) echo "r7-redrive.sh: --from must be inner|gate|land|live, got '$from'" >&2; usage ;; esac
  [ -z "$am" ] || [ "$from" = land ] || { echo "r7-redrive.sh: --after-merge only applies to --from land, got --from $from; refusing" >&2; usage; }
  case $expect in claimed|gate|inner|land|released) ;; *) echo "r7-redrive.sh: --expect must be claimed|gate|inner|land|released" >&2; usage ;; esac
  [ -n "$why" ] && [ -n "$ev" ] || { echo "r7-redrive.sh: --why and --evidence are required" >&2; usage; }
  [ -n "$rev" ] || rev="no undo for a redrive; the run re-enters $from. Stopping its driver unit needs its own row (never unpause or pause a land)"
  local out err drc id WM_DECIDE="${WM_DECIDE_BIN:-wm-decide}" SSH="${R7_REDRIVE_SSH:-ssh}"   # read per call (selftest stubs)
  err=$(mktemp)
  out=$("$WM_DECIDE" record --agent r7 --model "$model" --kind run-state --run "$HOST:$run" --expect "$expect" \
        --what "redrive $run --from $from$am$stp --operator r7" --why "$why" --evidence "$ev" --reverse-text "$rev" 2>"$err"); drc=$?
  # success = rc 0 AND a stdout line that IS the id (wm_decide/cli.py record: print(id_); return 0); an id quoted
  # inside a refusal or printed under a nonzero exit is not a row (verifier 2:2x 10-23)
  id=""; [ $drc = 0 ] && id=$(printf '%s\n' "$out" | grep -xE "$ID_RE" | head -1)
  if [ -z "$id" ]; then
    echo "r7-redrive.sh: REFUSED (wm-decide rc=$drc, no id line); NOT redriving $run. wm-decide said:" >&2
    { printf '%s\n' "$out"; cat "$err"; } | sed '/^$/d' | tail -3 | cut -c1-400 >&2
    rm -f "$err"; return 2
  fi
  rm -f "$err"; echo "row=$id"
  "$SSH" "$HOST" "export PATH=\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH; wm-build run redrive $run --from $from$am$stp --operator r7" 2>&1 | tail -3
  local rc=${PIPESTATUS[0]}; echo "redrive $run --from $from rc=$rc row=$id"; return $rc
}

selftest() {
  local S fail=0 rc out; S=$(mktemp -d); trap 'rm -rf "$S"' RETURN
  chk() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
  printf '#!/bin/sh\necho "$@" >> %s/ssh.log\necho "redrive queued"\n' "$S" > "$S/ssh"; chmod +x "$S/ssh"
  printf '#!/bin/sh\necho "$@" >> %s/dec.log\necho "refused: record --kind run-state needs --expect STATE"\nexit 2\n' "$S" > "$S/dec-refuse"
  printf '#!/bin/sh\necho "$@" >> %s/dec.log\necho "recorded"\nexit 0\n' "$S" > "$S/dec-noid"
  printf '#!/bin/sh\necho "$@" >> %s/dec.log\necho "d-20261023-021500-r7-ab12"\n' "$S" > "$S/dec-ok"
  printf '#!/bin/sh\necho "$@" >> %s/dec.log\necho "refused: conflicts with earlier row d-20261023-021500-r7-ab12"\nexit 2\n' "$S" > "$S/dec-quote"
  printf '#!/bin/sh\necho "$@" >> %s/dec.log\necho "d-20261023-021500-r7-ab12"\nexit 3\n' "$S" > "$S/dec-idrc"
  printf '#!/bin/sh\necho "$@" >> %s/dec.log\necho "warning: see d-20261023-021500-r7-ab12"\nexit 0\n' "$S" > "$S/dec-embed"; chmod +x "$S"/dec-*
  local A=(--expect land --why w --evidence e)
  out=$(WM_DECIDE_BIN=$S/dec-refuse R7_REDRIVE_SSH=$S/ssh redrive 490 land "${A[@]}" 2>&1); rc=$?
  chk '[ $rc = 2 ] && [ ! -e "$S/ssh.log" ] && echo "$out" | grep -q "REFUSED" && echo "$out" | grep -q "needs --expect"' "refused row -> rc 2, wm-decide reason shown, ssh never called"
  out=$(WM_DECIDE_BIN=$S/dec-noid R7_REDRIVE_SSH=$S/ssh redrive 490 land "${A[@]}" 2>&1); rc=$?
  chk '[ $rc = 2 ] && [ ! -e "$S/ssh.log" ]' "record rc 0 but no id printed -> rc 2, ssh never called"
  out=$(WM_DECIDE_BIN=$S/dec-quote R7_REDRIVE_SSH=$S/ssh redrive 490 land "${A[@]}" 2>&1); rc=$?
  chk '[ $rc = 2 ] && [ ! -e "$S/ssh.log" ] && echo "$out" | grep -q "conflicts with earlier row"' "refusal QUOTING an id -> rc 2, ssh never called"
  out=$(WM_DECIDE_BIN=$S/dec-idrc R7_REDRIVE_SSH=$S/ssh redrive 490 land "${A[@]}" 2>&1); rc=$?
  chk '[ $rc = 2 ] && [ ! -e "$S/ssh.log" ] && echo "$out" | grep -q "rc=3"' "id line under a nonzero exit -> rc 2, ssh never called"
  out=$(WM_DECIDE_BIN=$S/dec-embed R7_REDRIVE_SSH=$S/ssh redrive 490 land "${A[@]}" 2>&1); rc=$?
  chk '[ $rc = 2 ] && [ ! -e "$S/ssh.log" ]' "rc 0 but the id only INSIDE a sentence -> rc 2, ssh never called"
  rm -f "$S/ssh.log"; : > "$S/dec.log"
  out=$(WM_DECIDE_BIN=$S/dec-ok R7_REDRIVE_SSH=$S/ssh redrive 490 land "${A[@]}" 2>&1); rc=$?
  chk '[ $rc = 0 ] && [ "$(wc -l < "$S/ssh.log")" = 1 ] && grep -q "wm-build run redrive 490 --from land --operator r7" "$S/ssh.log" && echo "$out" | grep -q "row=d-20261023-021500-r7-ab12"' "id -> exactly one ssh redrive with the exact argv, row quoted"
  chk 'grep -q -- "--kind run-state --run ryzen7:490 --expect land" "$S/dec.log"' "row is a run-state row on ryzen7:490 with --expect"
  rm -f "$S/ssh.log" "$S/dec.log"
  out=$(WM_DECIDE_BIN=$S/dec-ok R7_REDRIVE_SSH=$S/ssh redrive 490 build "${A[@]}" 2>&1); rc=$?
  chk '[ $rc = 64 ] && [ ! -e "$S/dec.log" ] && [ ! -e "$S/ssh.log" ]' "bad --from -> rc 64, no row, no ssh"
  out=$(WM_DECIDE_BIN=$S/dec-ok R7_REDRIVE_SSH=$S/ssh redrive 49x land "${A[@]}" 2>&1); rc=$?
  chk '[ $rc = 64 ] && [ ! -e "$S/dec.log" ]' "non-numeric run -> rc 64, no row"
  out=$(WM_DECIDE_BIN=$S/dec-ok R7_REDRIVE_SSH=$S/ssh redrive 490 land --expect land --why w 2>&1); rc=$?
  chk '[ $rc = 64 ] && [ ! -e "$S/dec.log" ]' "missing --evidence -> rc 64, no row"
  [ $fail = 0 ] && echo "selftest ok" || echo "selftest FAIL"; return $fail
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi
redrive "$@"
