#!/usr/bin/env bash
# five-whys 2026-11-09 mechanism 2: root-level watch of user@1000.service (outside the user cgroup)
LOG=/var/lib/fleet/user-manager-watch.log; mkdir -p /var/lib/fleet
if ! systemctl is-active --quiet user@1000.service; then
  echo "$(date -Iseconds) user@1000 inactive: starting" >>"$LOG"
  systemctl start user@1000.service >>"$LOG" 2>&1; echo "$(date -Iseconds) start rc=$?" >>"$LOG"
fi
