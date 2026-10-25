#!/usr/bin/env bash
# Live check (part b of tests/user-timers-start-trigger.test.sh; also run from seat-context-start.sh): every ENABLED user timer must show a start
# trigger in `systemctl --user show -p TimersMonotonic -p TimersCalendar`: an OnBoot/OnStartup/OnActive monotonic entry or a calendar entry.
# A timer with only OnUnitActiveSec (or nothing) has no start trigger: it cannot fire after a reboot, and nothing alarms
# (five-whys 2026-10-24, ctl 3f76: an empty OnUnitActiveSec= in a drop-in wiped OnBootSec on seat-tick@* and swarm-decide-regrade).
# usage: timers-start-trigger-live.sh [--hosts "carbon redbaron ryzen7"] [--failures-only]
#   no --hosts: this host only. A remote host is read by piping this script's --local mode over `ssh host bash -s` (read-only `systemctl --user show`).
#   output, one line per timer: "OK <host> <unit>" | "FAIL <host> <unit> no start trigger (<what it has>)" | "SKIP <host> <why>"; --failures-only prints FAIL and SKIP only.
#   exit 0 when no FAIL, 1 when any FAIL. Never runs wm-build; only `systemctl --user list-*/show`.
# TIMERS_LIVE_SHOW_FILE=<file>: canned `show -p Id -p UnitFileState -p TimersMonotonic -p TimersCalendar` text for the local host (tests); skips systemctl.
set -u
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

evaluate() {  # stdin: show output (blank-line separated records) -> OK/FAIL lines for $1 = host label
  awk -v host="$1" 'BEGIN{RS="";FS="\n"}
    { id="";st="";mono=0;cal=0;what=""
      for(i=1;i<=NF;i++){
        if($i ~ /^Id=/) id=substr($i,4)
        else if($i ~ /^UnitFileState=/) st=substr($i,15)
        else if($i ~ /^TimersMonotonic=/){ if($i ~ /[ {;]On(Boot|Startup|Active)USec=/) mono=1; if(match($i,/On[A-Za-z]+USec=[^ ;}]*/)) what=what (what?",":"") substr($i,RSTART,RLENGTH) }
        else if($i ~ /^TimersCalendar=/){ cal=1; if(match($i,/OnCalendar=[^;}]*/)) what=what (what?",":"") substr($i,RSTART,RLENGTH) }
      }
      if(id=="" || id !~ /\.timer$/) next
      if(st!="enabled" && st!="enabled-runtime") next
      if(mono||cal) print "OK " host " " id
      else print "FAIL " host " " id " no start trigger (has: " (what==""?"nothing":what) ")"
    }'
}

local_show() {
  if [ -n "${TIMERS_LIVE_SHOW_FILE:-}" ]; then cat "$TIMERS_LIVE_SHOW_FILE"; return; fi
  local names
  names="$( { timeout 20 systemctl --user list-units --type=timer --all --no-legend --plain 2>/dev/null | awk '{print $1}'
              timeout 20 systemctl --user list-unit-files --type=timer --state=enabled,enabled-runtime --no-legend --plain 2>/dev/null | awk '{print $1}'; } \
            | grep '\.timer$' | grep -v '@\.timer$' | sort -u)"
  [ -n "$names" ] || return 0
  # shellcheck disable=SC2086
  timeout 30 systemctl --user show -p Id -p UnitFileState -p TimersMonotonic -p TimersCalendar $names 2>/dev/null
}

can_systemctl() { [ -n "${TIMERS_LIVE_SHOW_FILE:-}" ] || timeout 10 systemctl --user show-environment >/dev/null 2>&1; }

check_local() {  # $1 = host label
  if ! can_systemctl; then echo "SKIP $1 systemctl --user unavailable"; return 0; fi
  local out; out="$(local_show | evaluate "$1")"
  [ -n "$out" ] || { echo "SKIP $1 no enabled user timers found"; return 0; }
  printf '%s\n' "$out"
}

hosts=""; fo=0; mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hosts) hosts="${2:-}"; shift ;;
    --failures-only) fo=1 ;;
    --local) mode=local ;;
    *) echo "usage: $0 [--hosts \"h1 h2\"] [--failures-only]" >&2; exit 2 ;;
  esac
  shift
done
if [ "$mode" = local ]; then check_local "${TIMERS_LIVE_HOST:-$(hostname -s)}"; exit 0; fi

me="$(hostname -s 2>/dev/null)"; [ -n "$hosts" ] || hosts="$me"
res=""
for h in $hosts; do
  if [ "$h" = "$me" ] || [ "$h" = localhost ]; then
    r="$(check_local "$h")"
  else
    r="$(timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" "TIMERS_LIVE_HOST=$h bash -s -- --local" <"$SELF" 2>/dev/null)" || r=""
    [ -n "$r" ] || r="SKIP $h ssh read failed"
  fi
  res="$res$r"$'\n'
done
res="$(printf '%s' "$res" | sed '/^$/d')"
if [ "$fo" = 1 ]; then printf '%s\n' "$res" | grep -E '^(FAIL|SKIP) ' || true; else printf '%s\n' "$res"; fi
printf '%s\n' "$res" | grep -q '^FAIL ' && exit 1
exit 0
