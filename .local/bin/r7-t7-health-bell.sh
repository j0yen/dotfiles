#!/bin/bash
# r7-t7-health-bell: notify-only watch of ryzen7's T7 USB SSD (/mnt/ssd), runs on carbon.
# ctl dcb7 edit 1 / 0464. Every 60 s over ssh: kernel-log scan for disk faults since the
# last poll + a timed write-fsync-read of a small file in a mktemp dir it creates on /mnt/ssd
# (under the user-owned wm-build-tmp: /mnt/ssd itself is root:root 755, 12:26 AM false alarm).
# Rings seat r7 via seat-event.sh on a state change only. Never writes anything else.
# Disarms when EXPIRES passes or when mount-liveness.timer (mech 1) is active on ryzen7.
# Arm-time preflight (ctl 7d67): the real probe runs once on the real path before the loop;
# anything but ok refuses to arm (exit 1, one ring). `--preflight` runs only that check.
set -u
PREMISE="${PREMISE:-ryzen7 targets+tmp+swap on T7 USB; notify-only until mech 1 mount-liveness installs}"
EXPIRES="${EXPIRES:-2026-11-03T12:00:00-08:00}"
RX='usb [0-9.-]+: USB disconnect|uas.*reset|sd[a-z]+.*I/O error|Buffer I/O error|EXT4-fs (error|warning)|remount(ing)? .*read-only|JBD2.*I/O error|error -5'
EV=/home/jsy/.local/bin/seat-event.sh

classify() {  # stdin: kernel lines; prints count of fault lines
  grep -cE "$RX" || true
}

probe() {  # prints MECH1 or K=/O=/W= lines; returns ssh rc
  timeout 45 ssh -o BatchMode=yes -o ConnectTimeout=10 ryzen7 '
    systemctl --user is-active -q mount-liveness.timer 2>/dev/null && { echo MECH1; exit 0; }
    echo "K=$(journalctl -k --since -75s --no-pager 2>/dev/null | grep -cE "'"$RX"'")"
    echo "O=$(findmnt -no OPTIONS /mnt/ssd 2>/dev/null | cut -d, -f1)"
    d=$(mktemp -d /mnt/ssd/wm-build-tmp/.r7-t7-bell.XXXXXX 2>/dev/null) || { echo W=mktemp-fail; exit 0; }
    if timeout 10 sh -c "echo t7 > $d/f && sync $d/f && [ \"\$(cat $d/f)\" = t7 ]"; then echo W=ok; else echo W=fail; fi
    rm -rf -- "$d"' 2>/dev/null
}

judge() {  # $1 = probe output; sets k o w new
  k=$(sed -n 's/^K=//p' <<<"$1"); o=$(sed -n 's/^O=//p' <<<"$1"); w=$(sed -n 's/^W=//p' <<<"$1")
  if [ "${k:-0}" -gt 0 ] || [ "$o" != rw ] || [ "$w" != ok ]; then new=bad; else new=ok; fi
}

if [ "${1:-}" = "--selftest" ]; then
  f=0
  n=$(printf '%s\n' 'kernel: usb 2-1: USB disconnect, device number 3' 'kernel: sd 0:0:0:0: [sda] tag#1 uas_eh_abort_handler 0 uas-tag 1' 'kernel: scsi host0: uas_eh_device_reset_handler start' 'kernel: EXT4-fs warning (device sda1): ext4_end_bio:343: I/O error 10' | classify)
  [ "$n" -ge 3 ] || { echo "FAIL fault fixture n=$n"; f=1; }
  n=$(printf '%s\n' 'kernel: ee1004 0-0050: 512 byte EE1004-compliant SPD EEPROM, read-only' 'kernel: EXT4-fs (nvme0n1p2): mounted filesystem' | classify)
  [ "$n" -eq 0 ] || { echo "FAIL benign fixture n=$n"; f=1; }
  [ "$f" -eq 0 ] && echo "SELFTEST PASS (2 fixtures)"; exit $f
fi

# Arm-time preflight: one real probe on the real path; refuse to arm unless it reads ok.
pf=$(probe); rc=$?
case "$pf" in *MECH1*) echo "PREFLIGHT MECH1: mount-liveness.timer active, nothing to arm"; exit 0;; esac
if [ $rc -ne 0 ] || [ -z "$pf" ]; then
  msg="R7-T7-BELL refused to arm: preflight ssh rc=$rc"
  echo "$msg"; [ "${1:-}" = "--preflight" ] || $EV r7 "$msg"; exit 1
fi
judge "$pf"
if [ "$new" != ok ]; then
  msg="R7-T7-BELL refused to arm: preflight kernel-faults=${k:-?} mount=${o:-?} write-read=${w:-?}"
  echo "$msg"; [ "${1:-}" = "--preflight" ] || $EV r7 "$msg"; exit 1
fi
echo "PREFLIGHT OK kernel-faults=$k mount=$o write-read=$w"
[ "${1:-}" = "--preflight" ] && exit 0

state=ok; ssh_fail=0
while :; do
  if [ "$(date +%s)" -ge "$(date -d "$EXPIRES" +%s)" ]; then
    $EV r7 "R7-T7-BELL disarmed: EXPIRES $EXPIRES passed"; exit 0
  fi
  out=$(probe)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    ssh_fail=$((ssh_fail+1))
    [ $ssh_fail -eq 5 ] && $EV r7 "R7-T7-BELL ssh to ryzen7 failed 5 polls in a row (network, not disk)"
    sleep 60; continue
  fi
  ssh_fail=0
  case "$out" in *MECH1*) $EV r7 "R7-T7-BELL disarmed: mount-liveness.timer active on ryzen7 (mech 1)"; exit 0;; esac
  judge "$out"
  if [ "$new" != "$state" ]; then
    $EV r7 "R7-T7-BELL /mnt/ssd $new: kernel-faults=${k:-?} mount=${o:-?} write-read=${w:-?}. Reverse per d-6408: cap 0, cordon, NVMe target root"
    state=$new
  fi
  sleep 60
done
