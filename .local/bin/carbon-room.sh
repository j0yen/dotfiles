#!/usr/bin/env bash
# carbon-room.sh - the ROOM check: a measured memory gate before every spawn on carbon.
#
# RULE (~/.claude/CLAUDE.md § Hosts): "run anything on carbon as long as there is ROOM;
#   ROOM = a measured check before every spawn: MemAvailable minus the job's measured
#   peak keeps >= 3 G for the seats."
# JOE (10-22 10:0x PM): run anything on carbon as long as there is ROOM.
#
# MECHANISM ROLE: this is the SPAWN-SIDE gate every systemd-run / tmux spawn on carbon
#   must pass. The controller's side (status.json carbon.room + an alarm when the last
#   check is stale or NO) reads the state file this script writes on every call.
#
# USAGE
#   carbon-room.sh <need-MB> [--reserve-MB N] [--json] [--selftest]
#     need-MB        the job's MEASURED peak RSS in MB (not a guess)
#     --reserve-MB N headroom kept for the seats (default 3072; env CARBON_ROOM_RESERVE_MB;
#                    the flag wins over the env)
#     --json         print the JSON record on stdout in both outcomes
#     --selftest     run the built-in cases against a fake meminfo and exit
#   room_mb = MemAvailable_MB - need_MB - reserve_MB ; ok iff room_mb >= 0
#
# ENV
#   CARBON_ROOM_RESERVE_MB  default reserve
#   CARBON_ROOM_MEMINFO     meminfo path (tests)
#   CARBON_ROOM_STATE       state JSON  (default ~/.cache/fleet-dash/carbon-room.json)
#   CARBON_ROOM_LEDGER      audit JSONL (default ~/.cache/token-ledger/carbon-room.jsonl)
#   CARBON_ROOM_CALLER      caller label for the ledger (default: comm of $PPID)
#   CARBON_ROOM_HOST        set (any value) to skip the hostname guard (tests set =carbon)
#   CARBON_ROOM_HOSTNAME    fake `hostname` output (selftest of the guard)
#
# EXIT CODES
#   0  room ok (or "room n/a: not carbon" on any other host)
#   3  room NO (short on memory, or MemAvailable unreadable: fail closed)
#   64 usage (missing / non-numeric need, reserve)
#
# State and ledger writes never fail the call; a write error is a stderr note.
set -u

self=$(readlink -f "${BASH_SOURCE[0]}")
DEFAULT_RESERVE=3072

usage() {
  echo "usage: carbon-room.sh <need-MB> [--reserve-MB N] [--json] [--selftest]" >&2
  exit 64
}

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# ---------------------------------------------------------------- selftest
selftest() {
  local d fails=0 n=0 out rc
  d=$(mktemp -d "${TMPDIR:-/tmp}/carbon-room-selftest.XXXXXX") || { echo "selftest: mktemp failed" >&2; exit 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$d'" EXIT

  mk() { # mk <file> <avail_mb> [swap_mb]
    printf 'MemTotal:       15467572 kB\nMemFree:         1000000 kB\nMemAvailable:   %d kB\nSwapFree:       %d kB\n' \
      $(($2 * 1024)) $((${3:-2048} * 1024)) >"$1"
  }
  # run <args...> : env prepared by caller; sets out (stdout+stderr) and rc
  run() { out=$("$self" "$@" 2>&1); rc=$?; }
  check() { # check <name> <cond-exit>
    n=$((n + 1))
    if [ "$2" -eq 0 ]; then echo "  ok   $1"; else echo "  FAIL $1 (rc=$rc out=$out)"; fails=$((fails + 1)); fi
  }
  local base=(env -u CARBON_ROOM_RESERVE_MB -u CARBON_ROOM_CALLER -u CARBON_ROOM_HOSTNAME
    CARBON_ROOM_HOST=carbon "CARBON_ROOM_MEMINFO=$d/mi" "CARBON_ROOM_STATE=$d/state.json"
    "CARBON_ROOM_LEDGER=$d/ledger.jsonl")
  run_env() { out=$("${base[@]}" "$@" 2>&1); rc=$?; }

  mk "$d/mi" 8192
  run_env "$self" 1000
  if [ $rc -eq 0 ] && [[ $out == "room ok: avail=8192 need=1000 reserve=3072 left=4120" ]]; then check "plenty of room -> 0 + line" 0; else check "plenty of room -> 0 + line" 1; fi

  run_env "$self" 5120
  if [ $rc -eq 0 ] && [[ $out == *"left=0" ]]; then check "exact boundary left=0 -> 0" 0; else check "exact boundary left=0 -> 0" 1; fi

  mk "$d/mi" 4096
  run_env "$self" 1025
  if [ $rc -eq 3 ] && [[ $out == "room NO: avail=4096 need=1025 reserve=3072 short=1" ]]; then check "short by 1 MB -> 3 + line" 0; else check "short by 1 MB -> 3 + line" 1; fi

  run_env "$self" abc
  if [ $rc -eq 64 ]; then check "non-numeric need -> 64" 0; else check "non-numeric need -> 64" 1; fi
  run_env "$self"
  if [ $rc -eq 64 ]; then check "missing need -> 64" 0; else check "missing need -> 64" 1; fi

  mk "$d/mi" 4096
  run_env "$self" 1025 --reserve-MB 1000
  if [ $rc -eq 0 ] && [[ $out == *"reserve=1000"* ]]; then check "reserve via flag" 0; else check "reserve via flag" 1; fi
  out=$(env "${base[@]:1}" CARBON_ROOM_RESERVE_MB=1000 "$self" 1025 2>&1); rc=$?
  if [ $rc -eq 0 ] && [[ $out == *"reserve=1000"* ]]; then check "reserve via env" 0; else check "reserve via env" 1; fi
  out=$(env "${base[@]:1}" CARBON_ROOM_RESERVE_MB=1000 "$self" 1025 --reserve-MB 3072 2>&1); rc=$?
  if [ $rc -eq 3 ] && [[ $out == *"reserve=3072"* ]]; then check "flag wins over env" 0; else check "flag wins over env" 1; fi

  mk "$d/mi" 8192 512
  run_env "$self" 1000 --json
  local keys=1 k
  for k in ok avail_mb need_mb reserve_mb left_mb swap_free_mb ts; do
    [[ $out == *"\"$k\":"* ]] || keys=0
  done
  if [ $rc -eq 0 ] && [ $keys -eq 1 ] && [[ $out == *'"ok":true'* && $out == *'"swap_free_mb":512'* ]]; then check "--json shape (ok case)" 0; else check "--json shape (ok case)" 1; fi
  mk "$d/mi" 4096
  run_env "$self" 5000 --json
  if [ $rc -eq 3 ] && [[ $out == *'"ok":false'* && $out == *'"left_mb":-3976'* ]]; then check "--json on NO case" 0; else check "--json on NO case" 1; fi

  rm -f "$d/state.json"
  run_env "$self" 100
  if [ -s "$d/state.json" ] && { ! command -v python3 >/dev/null || python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$d/state.json"; }; then rc=0; else rc=1; fi
  check "state file written + parses" $?
  ls "$d"/state.json.* >/dev/null 2>&1 && rc=1 || rc=0
  check "state write left no temp files" $?

  : >"$d/ledger.jsonl"
  out=$(env "${base[@]:1}" CARBON_ROOM_CALLER=selftest-caller "$self" 100 2>&1); rc=$?
  if [ "$(wc -l <"$d/ledger.jsonl")" -eq 1 ] && grep -q '"caller":"selftest-caller"' "$d/ledger.jsonl" && grep -q '"need_mb":100' "$d/ledger.jsonl"; then check "ledger row with caller" 0; else check "ledger row with caller" 1; fi

  out=$(env -u CARBON_ROOM_HOST -u CARBON_ROOM_RESERVE_MB "CARBON_ROOM_HOSTNAME=laptop" "CARBON_ROOM_MEMINFO=$d/mi" "CARBON_ROOM_STATE=$d/s2.json" "CARBON_ROOM_LEDGER=$d/l2.jsonl" "$self" 99999999 2>&1); rc=$?
  if [ $rc -eq 0 ] && [[ $out == "room n/a: not carbon" ]] && [ ! -e "$d/s2.json" ]; then check "non-carbon host -> 0 n/a" 0; else check "non-carbon host -> 0 n/a" 1; fi

  printf 'MemTotal:       15467572 kB\nMemFree:         1000000 kB\n' >"$d/mi"
  run_env "$self" 100
  if [ $rc -eq 3 ] && [[ $out == *"room NO: MemAvailable unreadable"* ]]; then check "MemAvailable missing -> 3 fail closed" 0; else check "MemAvailable missing -> 3 fail closed" 1; fi

  mk "$d/mi" 8192
  out=$(env "${base[@]:1}" "CARBON_ROOM_STATE=/proc/nope/x.json" "CARBON_ROOM_LEDGER=/proc/nope/l.jsonl" "$self" 100 2>&1); rc=$?
  if [ $rc -eq 0 ] && [[ $out == *"room ok"* ]]; then check "unwritable state/ledger never fail the call" 0; else check "unwritable state/ledger never fail the call" 1; fi

  echo "selftest: $((n - fails))/$n passed"
  [ $fails -eq 0 ]
  exit $?
}

# ---------------------------------------------------------------- args
need="" reserve_flag="" json=0 selftest_flag=0
while [ $# -gt 0 ]; do
  case $1 in
    --json) json=1 ;;
    --selftest) selftest_flag=1 ;;
    --reserve-MB)
      [ $# -ge 2 ] || usage
      reserve_flag=$2
      shift
      ;;
    --reserve-MB=*) reserve_flag=${1#*=} ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [ -z "$need" ] || usage
      need=$1
      ;;
  esac
  shift
done

[ $selftest_flag -eq 1 ] && selftest

is_uint "$need" || usage
reserve=${reserve_flag:-${CARBON_ROOM_RESERVE_MB:-$DEFAULT_RESERVE}}
is_uint "$reserve" || usage
need=$((10#$need))
reserve=$((10#$reserve))

# ---------------------------------------------------------------- host guard
if [ -z "${CARBON_ROOM_HOST:-}" ]; then
  host=${CARBON_ROOM_HOSTNAME:-$(hostname 2>/dev/null)}
  if [ "$host" != carbon ]; then
    if [ $json -eq 1 ]; then
      echo '{"ok":true,"na":true,"reason":"not carbon"}'
    else
      echo "room n/a: not carbon"
    fi
    exit 0
  fi
fi

# ---------------------------------------------------------------- measure
meminfo=${CARBON_ROOM_MEMINFO:-/proc/meminfo}
avail_kb=$(awk '$1=="MemAvailable:" {print $2; exit}' "$meminfo" 2>/dev/null)
swap_kb=$(awk '$1=="SwapFree:" {print $2; exit}' "$meminfo" 2>/dev/null)
is_uint "$swap_kb" || swap_kb=0
swap_mb=$((swap_kb / 1024))
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if is_uint "$avail_kb"; then
  avail_mb=$((avail_kb / 1024))
  left=$((avail_mb - need - reserve))
  [ $left -ge 0 ] && ok=true || ok=false
  rec=$(printf '{"ok":%s,"avail_mb":%d,"need_mb":%d,"reserve_mb":%d,"left_mb":%d,"swap_free_mb":%d,"ts":"%s"}' \
    "$ok" "$avail_mb" "$need" "$reserve" "$left" "$swap_mb" "$ts")
  ledger_left=$left
else
  ok=false
  avail_mb=""
  rec=$(printf '{"ok":false,"avail_mb":null,"need_mb":%d,"reserve_mb":%d,"left_mb":null,"swap_free_mb":%d,"ts":"%s"}' \
    "$need" "$reserve" "$swap_mb" "$ts")
  ledger_left=null
fi

# ---------------------------------------------------------------- state (atomic) + ledger
state=${CARBON_ROOM_STATE:-$HOME/.cache/fleet-dash/carbon-room.json}
if mkdir -p "$(dirname "$state")" 2>/dev/null && tmp=$(mktemp "$state.XXXXXX" 2>/dev/null) &&
  printf '%s\n' "$rec" >"$tmp" 2>/dev/null && mv -f "$tmp" "$state" 2>/dev/null; then
  :
else
  [ -n "${tmp:-}" ] && rm -f "$tmp" 2>/dev/null
  echo "carbon-room: note: could not write state $state" >&2
fi

caller=${CARBON_ROOM_CALLER:-$(ps -o comm= -p "$PPID" 2>/dev/null)}
caller=$(printf '%s' "${caller:-unknown}" | tr -c 'A-Za-z0-9._:@/-' '_')
ledger=${CARBON_ROOM_LEDGER:-$HOME/.cache/token-ledger/carbon-room.jsonl}
if mkdir -p "$(dirname "$ledger")" 2>/dev/null &&
  printf '{"ts":"%s","caller":"%s","need_mb":%d,"ok":%s,"left_mb":%s}\n' \
    "$ts" "$caller" "$need" "$ok" "$ledger_left" >>"$ledger" 2>/dev/null; then
  :
else
  echo "carbon-room: note: could not append ledger $ledger" >&2
fi

# ---------------------------------------------------------------- verdict
[ $json -eq 1 ] && printf '%s\n' "$rec"

if [ -z "$avail_mb" ]; then
  echo "room NO: MemAvailable unreadable" >&2
  exit 3
fi
if [ "$ok" = true ]; then
  [ $json -eq 1 ] || echo "room ok: avail=$avail_mb need=$need reserve=$reserve left=$left"
  exit 0
fi
echo "room NO: avail=$avail_mb need=$need reserve=$reserve short=$((-left))" >&2
exit 3
