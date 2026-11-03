#!/bin/bash
# wmb-verify-suite.sh target placement (A672, Joe 11-03 12:58 AM "Ryzen has an ssd"): targets go to the mounted SSD
# run dir, an unmounted SSD path refuses (no root fallback), the suite waits below estimate + floor, the measured
# size is reused, the run dir is removed on exit, debuginfo is off. Fake slot + fake df; no real target is touched.
set -u
S=$(cd "$(dirname "$0")/.." && pwd)/.local/bin/wmb-verify-suite.sh
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

cat > "$T/slot" <<'EOF'
#!/bin/bash
echo "$1 $CARGO_TARGET_DIR debug=${CARGO_PROFILE_DEV_DEBUG:-unset}" >> "$SLOT_LOG"
mkdir -p "$CARGO_TARGET_DIR" && head -c 2048 /dev/zero > "$CARGO_TARGET_DIR/obj"
exit 0
EOF
chmod +x "$T/slot"
git init -q "$T/clone" && cd "$T/clone" || exit 1
git -c user.name=t -c user.email=t@x commit -q --allow-empty -m base; B=$(git rev-parse HEAD)
git -c user.name=t -c user.email=t@x commit -q --allow-empty -m head
mkdir -p "$T/ssd"; echo 500 > "$T/avail"
run() { # name, extra env... ; runs the suite in the clone, output to $T/<name>.out, rc to $T/<name>.rc
  local n=$1; shift
  : > "$T/$n.slot"
  ( cd "$T/clone" && env SLOT_LOG="$T/$n.slot" WMB_SLOT="$T/slot" WMB_TARGET_MNT="$T/ssd" WMB_ROOT_REF=/proc \
      WMB_FAKE_AVAIL_FILE="$T/avail" WMB_TARGET_POLL_S=1 "$@" bash "$S" --flags '' "$B" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc" )
}

# 1 mounted SSD: every target under <mnt>/cargo-target/wmbvs-*, none in the clone, run dir removed, size kept
run mounted
ok "mounted rc 0" '[ "$(cat $T/mounted.rc)" = 0 ]'
ok "mounted: slot ran" '[ -s $T/mounted.slot ]'
ok "mounted: every target on the ssd run dir" '! grep -v " $T/ssd/cargo-target/wmbvs-" $T/mounted.slot | grep -q .'
ok "mounted: no target in the clone" '! ls -d $T/clone/target* 2>/dev/null | grep -q .'
ok "mounted: run dir removed on exit" '! ls -d $T/ssd/cargo-target/wmbvs-* 2>/dev/null | grep -q .'
ok "mounted: measured size kept" '[ -f $T/ssd/cargo-target/.wmbvs-last-gb-debug0 ]'
ok "debuginfo off" '! grep -v "debug=0$" $T/mounted.slot | grep -q .'

# 2 SSD path present but not mounted (same device as the root ref): refuse 75, slot never runs
run unmounted WMB_ROOT_REF="$T/ssd"
ok "unmounted rc 75" '[ "$(cat $T/unmounted.rc)" = 75 ]'
ok "unmounted says TARGET-REFUSED" 'grep -q TARGET-REFUSED $T/unmounted.out'
ok "unmounted: slot never ran" '[ ! -s $T/unmounted.slot ]'

# 3 free below estimate + floor: waits, then times out with 75 before any build
rm -f "$T"/ssd/cargo-target/.wmbvs-last-gb-*; echo 10 > "$T/avail"
run lowfree WMB_TARGET_WAIT_S=2
ok "lowfree rc 75" '[ "$(cat $T/lowfree.rc)" = 75 ]'
ok "lowfree logs target-wait with need=200G" 'grep -q "target-wait .*need=200G" $T/lowfree.out'
ok "lowfree: slot never ran" '[ ! -s $T/lowfree.slot ]'

# 4 free rises above the floor while waiting: the leg is delayed, not lost
( sleep 2; echo 500 > "$T/avail" ) &
run rises WMB_TARGET_WAIT_S=30
wait
ok "rises rc 0" '[ "$(cat $T/rises.rc)" = 0 ]'
ok "rises waited at least once" 'grep -q target-wait $T/rises.out'
ok "rises: slot ran" '[ -s $T/rises.slot ]'

# 5 the measured size of the last run is the estimate (300G + 50G floor > 320G free)
echo 300 > "$T/ssd/cargo-target/.wmbvs-last-gb-debug0"; echo 320 > "$T/avail"
run measured WMB_TARGET_WAIT_S=1
ok "measured estimate used: need=350G" 'grep -q "need=350G" $T/measured.out'
ok "measured rc 75" '[ "$(cat $T/measured.rc)" = 75 ]'

# 6 host without the SSD path: targets stay with the clone (redbaron), still removed on exit
echo 500 > "$T/avail"
run nossd WMB_TARGET_MNT="$T/no-such-mnt"
ok "nossd rc 0" '[ "$(cat $T/nossd.rc)" = 0 ]'
ok "nossd: targets under the clone run dir" '! grep -v " $T/clone/wmbvs-" $T/nossd.slot | grep -q .'
ok "nossd: run dir removed" '! ls -d $T/clone/wmbvs-* 2>/dev/null | grep -q .'

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
