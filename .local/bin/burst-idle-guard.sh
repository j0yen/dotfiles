#!/usr/bin/env bash
# burst-idle-guard.sh — Joe 2026-09-11: "keep casper up until just before the hour in case something comes in,
# but NEVER NOT DELETE THE BOX IF IT'S IDLE AT THAT TIME."
# Hetzner bills per started hour. Runs every 5 min. In the last 6 minutes of each billed hour (measured from the
# server's own creation time) it deletes the box if NO routed run happened in that billed hour, or the loop is stopped.
# Direct `hcloud server delete`; no sweep, no pulls, no TTL games. Cargo/ssh only; never Claude.
set -uo pipefail
S=$HOME/.claude/skills/build/state/burst-lane/session.json
J=$HOME/brain/journal/build/burst-lane.log
set -a; . "$HOME/.config/wm-burst/.env" 2>/dev/null; set +a
now=$(date +%s)
loop_active=$(systemctl --user is-active claude-build.path 2>/dev/null)
hcloud server list -o noheader -o columns=id,name,created 2>/dev/null | awk '/burst/' | while read -r id name created; do
  created_s=$(date -d "$created" +%s 2>/dev/null) || continue
  age=$(( now - created_s ))
  into_hour=$(( age % 3600 ))            # seconds into the current billed hour
  hour_start=$(( now - into_hour ))
  # Fast path (checked BEFORE the last-6-minutes billed-hour gate below): a
  # box that has served zero runs across its entire lifetime and is already
  # older than ~15 min is dead weight regardless of where it sits in the
  # billed hour — waiting for the hour boundary just burns another full
  # billed hour on nothing. Conservative: only fires when jq is present and
  # session.json parses cleanly; any other case falls through to the
  # existing gates unchanged.
  cause=""
  if command -v jq >/dev/null 2>&1 && [ -f "$S" ] && [ "$age" -gt "${BURST_IDLE_GUARD_ZERO_RUNS_AGE_S:-900}" ]; then
    runs_served=$(jq -er '.runs_served' "$S" 2>/dev/null)
    [ "$runs_served" = "0" ] && cause="zero-runs-lifetime"
  fi
  if [ -z "$cause" ]; then
    [ "$into_hour" -lt 3240 ] && continue   # act only in the last 6 minutes of the billed hour
  fi
  runs_this_hour=0
  while read -r line; do
    t=$(date -d "${line:0:20}" +%s 2>/dev/null) || continue
    [ "$t" -ge "$hour_start" ] && runs_this_hour=$((runs_this_hour+1))
  done < <(grep -E 'run  routed|gate  .*host=' "$J" 2>/dev/null | tail -200)
  [ -z "$cause" ] && [ "$loop_active" != "active" ] && cause="loop-stopped"
  [ -z "$cause" ] && [ "$runs_this_hour" -eq 0 ] && cause="idle-this-billed-hour"
  if [ -z "$cause" ]; then
    echo "$(date -u +%FT%TZ)  burst-lane  idle-guard  keep  (server_id=$id billed_hour=$((age/3600+1)) runs_this_hour=$runs_this_hour)" >> "$J"
    continue
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "$(date -u +%FT%TZ)  burst-lane  idle-guard  DRY-RUN would-delete  (server_id=$id cause=idle-guard:$cause billed_hours=$((age/3600+1)) runs_this_hour=$runs_this_hour)" >> "$J"
    continue
  fi
  if hcloud server delete "$id" >/dev/null 2>&1; then
    echo "$(date -u +%FT%TZ)  burst-lane  down  decision=deleted  (server_id=$id cause=idle-guard:$cause billed_hours=$((age/3600+1)) runs_this_hour=$runs_this_hour)" >> "$J"
    [ -f "$S" ] && mv "$S" "$S.deleted-$(date -u +%Y%m%dT%H%MZ)"
    rm -f "$HOME/.claude/skills/build/state/burst-lane/dirty/"*.json 2>/dev/null
  else
    echo "$(date -u +%FT%TZ)  burst-lane  idle-guard  DELETE-FAILED  (server_id=$id cause=$cause — RETRY NEXT RUN, ALERT)" >> "$J"
  fi
done
