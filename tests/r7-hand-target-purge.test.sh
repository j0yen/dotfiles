#!/usr/bin/env bash
# tests/r7-hand-target-purge.test.sh -- r7-hand-target-purge.sh: runs its own --selftest (stub df/fuser/wm-build, fake HOME/hand and fake /proc,
# all inside a mktemp -d; the script is never pointed at a real path) and checks the unit files carry the spec's directives.
# Run: bash tests/r7-hand-target-purge.test.sh   (rc 0 = OK; never SKIPs: the selftest needs no ryzen7)
set -u
here=$(cd "$(dirname "$0")" && pwd)
S=$here/../.local/bin/r7-hand-target-purge.sh
SVC=$here/../.config/systemd/user/r7-hand-target-purge.service
TMR=$here/../.config/systemd/user/r7-hand-target-purge.timer
fail=0
need() { if ! "$@"; then echo "NOT OK: $*"; fail=1; fi; }

out=$(bash "$S" --selftest 2>&1); rc=$?
printf '%s\n' "$out"
need test "$rc" = 0
need bash -c 'printf "%s\n" "$1" | grep -qE "^selftest ok [0-9]+/[0-9]+$"' _ "$out"
# every spec case (a)-(g) and the Fable additions must have run and passed
for c in a-premise-false-nothing-deleted b-oldest-deleted b-others-kept c-recent-write-kept d-in-use-fuser e-symlink-kept f-outside-refused g-expired-last-json \
         h-flock-in-use i-cargo-jobs-error i2-fuser-error i3-df-error j-symlinked-parent-out k-orphan-swept a-premise-false-last-json l4-proc-fd \
         m-root-refused-under-systemd m2-single-instance n-sigterm-last-json; do
  need bash -c 'printf "%s\n" "$1" | grep -qx "ok   $2"' _ "$out" "$c"
done
need bash -c '! printf "%s\n" "$1" | grep -q "^FAIL"' _ "$out"

# unit files: the spec's S1.7 + Fable changes 1, 9
need grep -qx 'Nice=19' "$SVC"
need grep -qx 'IOSchedulingClass=idle' "$SVC"
need grep -qx 'RuntimeMaxSec=1800' "$SVC"
need grep -qx 'Type=simple' "$SVC"   # RuntimeMaxSec is ignored under Type=oneshot
need grep -qx 'Environment=PATH=%h/.cargo/bin:%h/.local/bin:/usr/bin' "$SVC"
need grep -qx 'EnvironmentFile=-%h/.config/environment.d/\*.conf' "$SVC"
need grep -q '^ExecStartPre=.*r7-hand-target-purge.sh --selftest' "$SVC"
need grep -q '^ExecStart=.*r7-hand-target-purge.sh$' "$SVC"
need grep -qx 'OnUnitActiveSec=30min' "$TMR"
need grep -qx 'Persistent=false' "$TMR"
# expiry + thresholds pinned (spec: EXPIRES 2026-11-06, PREMISE >= 85 %, hysteresis 80 %, 48 h idle)
need grep -q 'R7_PURGE_EXPIRES:-2026-11-06T23:59:59-08:00' "$S"
need grep -q 'HIGH=${R7_PURGE_HIGH:-85}' "$S"
need grep -q 'LOW=${R7_PURGE_LOW:-80}' "$S"
need grep -q '^IDLE_H=48$' "$S"
# the unit must not carry a test hook
need bash -c '! grep -qE "R7_PURGE_|--root|--candidate" "$1"' _ "$SVC"

[ "$fail" = 0 ] && echo "OK r7-hand-target-purge" && exit 0
exit 1
