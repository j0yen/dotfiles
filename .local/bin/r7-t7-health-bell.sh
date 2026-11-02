#!/bin/bash
# r7-t7-health-bell: notify-only watch of ryzen7's T7 USB SSD (/mnt/ssd), runs on carbon.
# ctl dcb7 edit 1 / 0464. Every 60 s over ssh: kernel-log scan for disk faults since the
# last poll + a timed write-fsync-read of a small file in a mktemp dir it creates on /mnt/ssd
# (under the user-owned wm-build-tmp: /mnt/ssd itself is root:root 755, 12:26 AM false alarm).
# Rings seat r7 via seat-event.sh on a state change only. Never writes anything else.
# Disarms when EXPIRES passes or when mount-liveness.timer (mech 1) is active on ryzen7.
# Arm-time preflight (ctl 7d67): the real probe runs once on the real path before the loop;
# anything but ok refuses to arm (exit 1, one ring). `--preflight` runs only that check.
# ctl 2527 debounce: kernel faults or a non-rw mount ring at once; a failed or slow write probe
# (W=fail / mktemp-fail) rings only after DEBOUNCE polls in a row (the 9:01 PM ring was IO PSI
# full avg10 16 under a verify, not a disk fault). W carries the sync latency: `W=ok ms=<n>`.
set -u
PREMISE="${PREMISE:-ryzen7 targets+tmp+swap on T7 USB; notify-only until mech 1 mount-liveness installs}"
EXPIRES="${EXPIRES:-2026-11-03T12:00:00-08:00}"
RX='usb [0-9.-]+: USB disconnect|uas.*reset|sd[a-z]+.*I/O error|Buffer I/O error|EXT4-fs (error|warning)|remount(ing)? .*read-only|JBD2.*I/O error|error -5'
EV=/home/jsy/.local/bin/seat-event.sh
DEBOUNCE=3  # consecutive soft failures (W != ok) before a ring; fixed so --selftest is deterministic

classify() {  # stdin: kernel lines; prints count of fault lines
  grep -cE "$RX" || true
}

probe() {  # prints MECH1 or K=/O=/W= lines; returns ssh rc
  timeout 45 ssh -o BatchMode=yes -o ConnectTimeout=10 ryzen7 '
    systemctl --user is-active -q mount-liveness.timer 2>/dev/null && { echo MECH1; exit 0; }
    echo "K=$(journalctl -k --since -75s --no-pager 2>/dev/null | grep -cE "'"$RX"'")"
    echo "O=$(findmnt -no OPTIONS /mnt/ssd 2>/dev/null | cut -d, -f1)"
    d=$(mktemp -d /mnt/ssd/wm-build-tmp/.r7-t7-bell.XXXXXX 2>/dev/null) || { echo W=mktemp-fail; exit 0; }
    t0=$(date +%s%N)
    if timeout 10 sh -c "echo t7 > $d/f && sync $d/f && [ \"\$(cat $d/f)\" = t7 ]"; then r=ok; else r=fail; fi
    echo "W=$r ms=$(( ($(date +%s%N) - t0) / 1000000 ))"
    rm -rf -- "$d"' 2>/dev/null
}

judge() {  # $1 = probe output; sets k o w ms hard soft new (hard = rings at once, soft = debounced)
  k=$(sed -n 's/^K=//p' <<<"$1"); o=$(sed -n 's/^O=//p' <<<"$1")
  w=$(sed -n 's/^W=\([^ ]*\).*/\1/p' <<<"$1"); ms=$(sed -n 's/^W=.* ms=\([0-9]*\).*/\1/p' <<<"$1")
  hard=0; soft=0
  if [ "${k:-0}" -gt 0 ] || [ "$o" != rw ]; then hard=1; fi
  if [ "$w" != ok ]; then soft=1; fi
  if [ $hard -eq 1 ] || [ $soft -eq 1 ]; then new=bad; else new=ok; fi
}

step() {  # $1 = probe output; uses/updates state fails; sets ring (0/1) and new
  judge "$1"; ring=0
  if [ $hard -eq 1 ]; then new=bad
  elif [ $soft -eq 1 ]; then
    fails=$((fails+1))
    if [ $fails -ge $DEBOUNCE ]; then new=bad; else new=$state; fi
  else fails=0; new=ok; fi
  [ "$new" != "$state" ] && ring=1
  state=$new
}

decide_seq() {  # pure, no ssh. stdin: polls of K=/O=/W= lines, polls split by a "--" line; prints ring|noring
  local buf="" line any=0
  state=ok; fails=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = -- ]; then step "$buf"; [ $ring -eq 1 ] && any=1; buf=""; else buf+="$line"$'\n'; fi
  done
  if [ -n "$buf" ]; then step "$buf"; [ $ring -eq 1 ] && any=1; fi
  [ $any -eq 1 ] && echo ring || echo noring
}

if [ "${1:-}" = "--selftest" ]; then
  f=0
  n=$(printf '%s\n' 'kernel: usb 2-1: USB disconnect, device number 3' 'kernel: sd 0:0:0:0: [sda] tag#1 uas_eh_abort_handler 0 uas-tag 1' 'kernel: scsi host0: uas_eh_device_reset_handler start' 'kernel: EXT4-fs warning (device sda1): ext4_end_bio:343: I/O error 10' | classify)
  [ "$n" -ge 3 ] || { echo "FAIL fault fixture n=$n"; f=1; }
  n=$(printf '%s\n' 'kernel: ee1004 0-0050: 512 byte EE1004-compliant SPD EEPROM, read-only' 'kernel: EXT4-fs (nvme0n1p2): mounted filesystem' | classify)
  [ "$n" -eq 0 ] || { echo "FAIL benign fixture n=$n"; f=1; }
  nf=2
  chk() {  # $1 name  $2 want  $3 got
    nf=$((nf+1)); [ "$2" = "$3" ] || { echo "FAIL $1 want=$2 got=$3"; f=1; }
  }
  P_OK=$'K=0\nO=rw\nW=ok ms=12'; P_WF=$'K=0\nO=rw\nW=fail ms=10000'; P_MK=$'K=0\nO=rw\nW=mktemp-fail'
  seq_of() { local s="" p; for p in "$@"; do s+="$p"$'\n--\n'; done; printf '%s' "$s"; }
  chk "a one W=fail then ok" noring "$(seq_of "$P_WF" "$P_OK" | decide_seq)"
  chk "b three W=fail" ring "$(seq_of "$P_WF" "$P_WF" "$P_WF" | decide_seq)"
  chk "c K=1 first poll" ring "$(seq_of $'K=1\nO=rw\nW=ok ms=12' | decide_seq)"
  chk "d O=ro first poll" ring "$(seq_of $'K=0\nO=ro\nW=ok ms=12' | decide_seq)"
  judge $'K=0\nO=rw\nW=ok ms=137'; chk "e ms parse" "ok/137" "$w/$ms"
  chk "f fail fail ok fail fail resets" noring "$(seq_of "$P_WF" "$P_WF" "$P_OK" "$P_WF" "$P_WF" | decide_seq)"
  chk "g mktemp-fail x3" ring "$(seq_of "$P_MK" "$P_MK" "$P_MK" | decide_seq)"
  [ "$f" -eq 0 ] && echo "SELFTEST PASS ($nf fixtures)"; exit $f
fi

# Arm-time preflight: real probe on the real path; refuse to arm unless it reads ok. A hard fault
# (kernel faults, mount not rw) refuses at once; a lone W=fail retries up to DEBOUNCE probes.
attempt=0
while :; do
  attempt=$((attempt+1))
  pf=$(probe); rc=$?
  case "$pf" in *MECH1*) echo "PREFLIGHT MECH1: mount-liveness.timer active, nothing to arm"; exit 0;; esac
  if [ $rc -ne 0 ] || [ -z "$pf" ]; then
    msg="R7-T7-BELL refused to arm: preflight ssh rc=$rc"
    echo "$msg"; [ "${1:-}" = "--preflight" ] || $EV r7 "$msg"; exit 1
  fi
  judge "$pf"
  if [ $hard -eq 1 ] || { [ $soft -eq 1 ] && [ $attempt -ge $DEBOUNCE ]; }; then
    msg="R7-T7-BELL refused to arm: preflight kernel-faults=${k:-?} mount=${o:-?} write-read=${w:-?} ms=${ms:-?} probes=$attempt"
    echo "$msg"; [ "${1:-}" = "--preflight" ] || $EV r7 "$msg"; exit 1
  fi
  [ $soft -eq 0 ] && break
  sleep "${PF_RETRY_SLEEP:-5}"
done
echo "PREFLIGHT OK kernel-faults=$k mount=$o write-read=$w ms=${ms:-?}"
[ "${1:-}" = "--preflight" ] && exit 0

state=ok; fails=0; ssh_fail=0
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
  step "$out"
  if [ $ring -eq 1 ]; then
    $EV r7 "R7-T7-BELL /mnt/ssd $new: kernel-faults=${k:-?} mount=${o:-?} write-read=${w:-?} ms=${ms:-?} fails=$fails/$DEBOUNCE. Reverse per d-6408: cap 0, cordon, NVMe target root"
  fi
  sleep 60
done
