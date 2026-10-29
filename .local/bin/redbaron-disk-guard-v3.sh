#!/usr/bin/env bash
# redbaron-disk-guard — per-node root-disk guard for wm-build HOST mode.
# Origin: 2026-10-09 1:59 am PDT ENOSPC on RedBaron (468 G NVMe root is the only
# fast disk; each live mcphost worktree target grows to 50-90 G; nothing reaped
# ended trees' leftovers and nothing watched the disk).
# Reaps ONLY state no live run owns: wt/<slug>/target when the slug has no open
# run and no process under it, and ~/tmp/wm-build-run-<id> when run <id> ended.
# Never touches a live tree. Logs one line per tick; alarms below ALARM_GB.
set -u
STATE=${WM_BUILD_STATE_DIR:-$HOME/.local/state/wm-build}
DB=$STATE/state.db
LOG=$HOME/.local/state/disk-guard/guard.log
REAP_GB=${DISK_GUARD_REAP_GB:-120}
ALARM_GB=${DISK_GUARD_ALARM_GB:-45}
ts=$(date '+%Y-%m-%d %I:%M %p')
free_gb() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }
data_free_gb() { df -BG --output=avail /mnt/data 2>/dev/null | tail -1 | tr -dc '0-9'; }
q() { sqlite3 -readonly "$DB" "$1" 2>/dev/null; }
FREE=$(free_gb); freed=0

# v5 (ctl 55ad (4), 10-29): kernel I/O errors since the last run, per device. RedBaron's dead /mnt/ssd logged 285 EIO lines in 24 h
# while this guard exited 0. Any > 0 -> `EIO dev=<dev> n=<n>` on stdout and exit 3 (the reaping below still runs). Exit 0 only when clean.
# DISK_GUARD_EIO_FILE=<file> reads those lines instead of the journal (tests); DISK_GUARD_EIO_ONLY=1 stops after the scan.
EIO_STATE=${DISK_GUARD_EIO_STATE:-$HOME/.local/state/disk-guard/eio-last-run}
EIO_RE='I/O error|error -5|EXT4-fs error|blk_update_request|Buffer I/O'
eio_scan() {
  local since now lines
  now=$(date +%s); since=$(cat "$EIO_STATE" 2>/dev/null); since=${since:-$((now - 300))}
  if [ -n "${DISK_GUARD_EIO_FILE:-}" ]; then lines=$(cat "$DISK_GUARD_EIO_FILE")
  else lines=$(journalctl -k --no-pager -q --since "@$since" 2>/dev/null); fi
  mkdir -p "$(dirname "$EIO_STATE")" 2>/dev/null; [ -z "${DISK_GUARD_EIO_FILE:-}" ] && echo "$now" > "$EIO_STATE"
  printf '%s\n' "$lines" | grep -E "$EIO_RE" \
    | grep -oE '\b(sd[a-z]+[0-9]*|nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z]+[0-9]*|mmcblk[0-9]+(p[0-9]+)?|dm-[0-9]+)\b' | sort | uniq -c \
    | awk '{printf "EIO dev=%s n=%d\n", $2, $1; bad=1} END {exit bad ? 3 : 0}'
}
eio_scan; EIO_RC=$?
[ "${DISK_GUARD_EIO_ONLY:-0}" = "1" ] && exit "$EIO_RC"
# v4 (rb 10-17 3:4x pm, controller order): /mnt/data held 77 no-open-run wts while root-gated reaping (REAP_GB on "/")
# never fired (data free 182 G, 185 G lost in 3.5 h). Reap wt/<slug>/target (real dir, not a symlink) at ANY free level when
# the slug has no open run, no process under it, and nothing in the target's top two levels changed for WT_AGE_MIN minutes.
# The empty target dir is KEPT (v3 rule: a redrive needs it). Freed size = /mnt/data df delta (per-dir du is minutes on SATA).
# DISK_GUARD_DRY=1 lists what it would reap and deletes nothing.
WT_AGE_MIN=${DISK_GUARD_WT_AGE_MIN:-120}; DRY=${DISK_GUARD_DRY:-0}; d0=$(data_free_gb); nreap=0
for t in "$STATE"/wt/*/target; do
  [ -L "$t" ] && continue; [ -d "$t" ] || continue
  slug=$(basename "$(dirname "$t")")
  open=$(q "select count(*) from runs where slug='$slug' and ended is null;"); open=${open:-1}
  [ "$open" = "0" ] || continue
  pgrep -f "wt/$slug/" >/dev/null 2>&1 && continue
  [ -n "$(find "$t" -maxdepth 2 -newermt "-$WT_AGE_MIN minutes" -print -quit 2>/dev/null)" ] && continue
  [ -z "$(ls -A "$t" 2>/dev/null)" ] && continue
  if [ "$DRY" = "1" ]; then echo "DRY would reap wt/$slug/target (mtime $(stat -c %y "$t" | cut -c1-16))"; continue; fi
  find "$t" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && nreap=$((nreap + 1)) && echo "$ts reaped wt/$slug/target contents (no open run, idle > ${WT_AGE_MIN}m)" >> "$LOG"
done
# v4b (rb 10-17 3:4x pm): the real /mnt/data grower was HAND-coder targets (/mnt/data/hand/targets/<name>, ~43 G each;
# 6 finished ones = 258 G freed by hand 3:38 pm) — wt targets live on the SSD as symlinks. Reap a hand target at ANY free
# level when nothing in its top two levels changed for HAND_IDLE_H hours and no live cargo/rustc env references it.
# Keep-list: names matching DISK_GUARD_HAND_KEEP (regex, default the current wm-build hand target).
HT=/mnt/data/hand/targets; HKEEP=${DISK_GUARD_HAND_KEEP:-^wm-build-054}; HIDLE=${DISK_GUARD_HAND_IDLE_H:-3}
henvref() { for p in $(pgrep -x cargo; pgrep -x rustc); do tr "\0" "\n" < /proc/$p/environ 2>/dev/null | grep -q "CARGO_TARGET_DIR=$1" && return 0; done; return 1; }
for d in "$HT"/*/; do
  [ -d "$d" ] || continue; d=${d%/}; n=$(basename "$d")
  echo "$n" | grep -qE "$HKEEP" && continue
  [ -n "$(find "$d" -maxdepth 2 -newermt "-$HIDLE hours" -print -quit 2>/dev/null)" ] && continue
  henvref "$d" && continue
  if [ "$DRY" = "1" ]; then echo "DRY would reap hand target $n (mtime $(stat -c %y "$d" | cut -c1-16))"; continue; fi
  rm -rf -- "$d" && nreap=$((nreap + 1)) && echo "$ts reaped hand target $n (idle > ${HIDLE}h, no cargo env ref)" >> "$LOG"
done
# v4c (rb 10-17 5:0x pm, after ryzen7's /tmp hit 100 % INODES from leaked test temp dirs): reap /tmp test leftovers
# (wm-build-*, mcphost-*, synthorg-*, .tmp*) owned by us, mtime > TMP_AGE_MIN, that no open fd or process cwd references.
# RedBaron 5:04 pm: 7,345 such dirs, /tmp inodes 15 % -> 3 %.
TMP_AGE_MIN=${DISK_GUARD_TMP_AGE_MIN:-60}
theld=$( { lsof -nP 2>/dev/null | awk '{print $NF}'; for pp in /proc/[0-9]*; do readlink "$pp/cwd" 2>/dev/null; done; } | grep -oE '^/tmp/[^/]+' | sort -u)
for d in $(find /tmp -mindepth 1 -maxdepth 1 -user "$(id -un)" -mmin +"$TMP_AGE_MIN" \( -name 'wm-build-*' -o -name 'mcphost-*' -o -name 'synthorg-*' -o -name '.tmp*' \) 2>/dev/null); do
  echo "$theld" | grep -qx "$d" && continue
  if [ "$DRY" = "1" ]; then echo "DRY would reap $d"; continue; fi
  find "$d" -depth -delete 2>/dev/null && nreap=$((nreap + 1))
done
ti=$(df -i /tmp | tail -1 | awk '{print $5}' | tr -d %)
if [ "${ti:-0}" -ge 80 ]; then echo "$ts ALARM /tmp inodes ${ti}%" >> "$LOG"; fi
if [ "$DRY" != "1" ] && [ "$nreap" -gt 0 ]; then d1=$(data_free_gb); echo "$ts v4 wt reap: $nreap targets, data_free ${d0}G -> ${d1}G" >> "$LOG"; fi
[ "$DRY" = "1" ] && exit "$EIO_RC"
if [ "${FREE:-0}" -lt "$REAP_GB" ]; then
  for t in "$STATE"/wt/*/target; do
    [ -L "$t" ] && continue  # 10-15 2:25 pm rb: a SYMLINK target frees nothing and redrive wts need it (class 24 / R10)
    [ -d "$t" ] || continue
    slug=$(basename "$(dirname "$t")")
    open=$(q "select count(*) from runs where slug='$slug' and ended is null;"); open=${open:-1}
    if [ "$open" = "0" ] && ! pgrep -f "wt/$slug/" >/dev/null 2>&1; then
      sz=$(du -sm "$t" 2>/dev/null | cut -f1)
      rm -rf "$t" && freed=$((freed + ${sz:-0})) && echo "$ts reaped wt/$slug/target ${sz}M (no open run)" >> "$LOG"
    fi
  done
  for d in "$HOME"/tmp/wm-build-run-*; do
    [ -d "$d" ] || continue
    id=${d##*-}; case "$id" in ''|*[!0-9]*) continue;; esac
    ended=$(q "select count(*) from runs where id=$id and ended is not null;"); ended=${ended:-0}
    if [ "$ended" = "1" ]; then
      sz=$(du -sm "$d" 2>/dev/null | cut -f1)
      rm -rf "$d" && freed=$((freed + ${sz:-0})) && echo "$ts reaped tmp/wm-build-run-$id ${sz}M (run ended)" >> "$LOG"
    fi
  done
  FREE=$(free_gb)
fi

# v3 (rb 10-16 4:33 am: a slug reap KEEPS the empty dir — wt/<slug>/target is a symlink to it and a redrive dies ENOTDIR without it, 913/847 a5/a15)
# v2 (rb 10-16 4:3x am, after the 11:10Z /mnt/ssd ENOSPC that killed 913/914 and the 918 binary push): the SSD holds
# per-slug targets (/mnt/ssd/wm-build-targets/<slug>) AND hand-coder targets (any other name) that nobody reaped after
# their PR merged (hr 146 G, mc-base 130 G, rs2 96 G ...). Reap when SSD free < SSD_REAP_GB: a slug dir with no open run;
# a hand dir idle > HAND_IDLE_H hours whose path no live cargo/rustc env references. Alarm when SSD free < SSD_ALARM_GB.
SSD_REAP_GB=${DISK_GUARD_SSD_REAP_GB:-400}; SSD_ALARM_GB=${DISK_GUARD_SSD_ALARM_GB:-100}; HAND_IDLE_H=${DISK_GUARD_HAND_IDLE_H:-3}
SSDT=/mnt/ssd/wm-build-targets
SFREE0=$(df -BG --output=avail /mnt/ssd 2>/dev/null | tail -1 | tr -dc 0-9)
if [ -d "$SSDT" ] && [ "${SFREE0:-999}" -lt "$SSD_REAP_GB" ]; then
  envref() { for p in $(pgrep -x cargo; pgrep -x rustc); do tr "\0" "\n" < /proc/$p/environ 2>/dev/null | grep -q "CARGO_TARGET_DIR=$1" && return 0; done; return 1; }
  for d in "$SSDT"/*/; do
    [ -d "$d" ] || continue; n=$(basename "$d"); d=${d%/}
    case "$n" in
      mcphost-*|synthorg-*)
        open=$(q "select count(*) from runs where slug='$n' and ended is null;"); open=${open:-1}
        if [ "$open" = "0" ] && ! pgrep -f "wt/$n/" >/dev/null 2>&1 && ! envref "$d"; then
          sz=$(du -sm "$d" 2>/dev/null | cut -f1); rm -rf -- "$d" && mkdir -p -- "$d" && freed=$((freed + ${sz:-0})) && echo "$ts reaped ssd-target $n ${sz}M (no open run; dir kept: wt/$n/target symlinks here, a redrive needs it)" >> "$LOG"; fi;;
      *)
        if [ -z "$(find "$d" -newermt "-$HAND_IDLE_H hours" -print -quit 2>/dev/null)" ] && ! envref "$d"; then
          sz=$(du -sm "$d" 2>/dev/null | cut -f1); rm -rf -- "$d" && freed=$((freed + ${sz:-0})) && echo "$ts reaped ssd-target $n ${sz}M (hand dir idle > ${HAND_IDLE_H}h)" >> "$LOG"; fi;;
    esac
  done
fi
live=$(q "select count(*) from runs where ended is null;")
trees=$(du -sc "$STATE"/wt/*/target 2>/dev/null | tail -1 | awk '{printf "%.0f", $1/1048576}')
DFREE=$(data_free_gb); SFREE=$(df -BG --output=avail /mnt/ssd 2>/dev/null | tail -1 | tr -dc 0-9)
echo "$ts root_free=${FREE}G data_free=${DFREE:-?}G ssd_free=${SFREE:-?}G live_runs=${live:-?} wt_targets=${trees:-0}G freed=${freed}M" >> "$LOG"
if [ "${FREE:-0}" -lt "$ALARM_GB" ] || [ "${DFREE:-999}" -lt "$ALARM_GB" ] || [ "${SFREE:-999}" -lt "$SSD_ALARM_GB" ]; then
  echo "$ts ALARM root free ${FREE}G < ${ALARM_GB}G — wm-build gates defer at host_min_free_gb; close the youngest run (wm-build run close <id> --cause disk-low) if nothing frees" >> "$LOG"
fi
"$HOME/.local/bin/redbaron-ssd-target-cap.sh"  # 10-15 2:4x pm rb: SSD warm-target cap (controller/Joe)
tail -n 2000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
exit "$EIO_RC"
