#!/bin/bash
# wmb-verify-suite.sh target placement (A672, Joe 11-03 12:58 AM "Ryzen has an ssd"): targets go to the mounted SSD
# run dir, an unmounted SSD path refuses (no root fallback), the suite waits below estimate + floor, the measured
# size is reused, concurrent legs reserve their estimate, the run dir is removed on exit, debuginfo is off. Fake slot + fake df; no real target is touched.
set -u
S=$(cd "$(dirname "$0")/.." && pwd)/.local/bin/wmb-verify-suite.sh
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

cat > "$T/slot" <<'EOF'
#!/bin/bash
echo "$1 $CARGO_TARGET_DIR debug=${CARGO_PROFILE_DEV_DEBUG:-unset}" >> "$SLOT_LOG"
mkdir -p "$CARGO_TARGET_DIR" && head -c 2048 /dev/zero > "$CARGO_TARGET_DIR/obj"
[ -n "${RESV_DIR:-}" ] && ls "$RESV_DIR" >> "$RESV_LOG"
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
  ( cd "$T/clone" && env -u CARGO_PROFILE_DEV_DEBUG -u CARGO_PROFILE_TEST_DEBUG SLOT_LOG="$T/$n.slot" WMB_SLOT="$T/slot" WMB_TARGET_MNT="$T/ssd" WMB_ROOT_REF=/proc \
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

# 7 another live leg's reservation counts against free space: 320G free - 200G reserved < 150G + 50G floor -> wait, 75
R=$T/ssd/cargo-target/.wmbvs-reserve; rm -f "$T"/ssd/cargo-target/.wmbvs-last-gb-*; echo 320 > "$T/avail"
sleep 30 & P=$!; echo 200 > "$R/$P.gb"
run otherleg WMB_TARGET_WAIT_S=1
kill "$P" 2>/dev/null; wait "$P" 2>/dev/null
ok "otherleg rc 75" '[ "$(cat $T/otherleg.rc)" = 75 ]'
ok "otherleg logs reserved=200G" 'grep -q "target-wait .*reserved=200G need=200G" $T/otherleg.out'
ok "otherleg: slot never ran" '[ ! -s $T/otherleg.slot ]'

# 8 a reservation whose pid has exited is dropped, and the leg runs
sh -c 'exit 0' & D=$!; wait "$D"; echo 200 > "$R/$D.gb"
run deadleg
ok "deadleg rc 0" '[ "$(cat $T/deadleg.rc)" = 0 ]'
ok "deadleg: dead reservation removed" '[ ! -f "$R/$D.gb" ]'

# 9 the leg holds its own reservation while it builds and drops it on exit
run ownresv RESV_DIR="$R" RESV_LOG="$T/ownresv.ls"
ok "ownresv rc 0" '[ "$(cat $T/ownresv.rc)" = 0 ]'
ok "ownresv: reservation held during the build" 'grep -q "^[0-9]*\.gb$" $T/ownresv.ls'
ok "ownresv: reservation removed on exit" '! ls "$R"/*.gb 2>/dev/null | grep -q .'

# 10 the fleet-dash producer: a waiting leg is listed in state.json with its need; after it starts the list is empty
ST=$T/state; rm -f "$T"/ssd/cargo-target/.wmbvs-last-gb-*; echo 10 > "$T/avail"
( for i in $(seq 1 40); do grep -q '"waits":\[{' "$ST/state.json" 2>/dev/null && break; sleep 0.2; done
  cp "$ST/state.json" "$T/state.during" 2>/dev/null; echo 500 > "$T/avail" ) &
run producer WMB_STATE_DIR="$ST" WMB_TARGET_WAIT_S=30
wait
ok "producer rc 0" '[ "$(cat $T/producer.rc)" = 0 ]'
ok "producer: waiting leg listed with need 200" 'grep -q "\"waits\":\[{\"pid\":[0-9]*,\"since\":[0-9]*,\"need_gb\":200}\]" $T/state.during'
ok "producer: est and floor recorded" 'grep -q "\"est_gb\":150,\"floor_gb\":50" $T/state.during'
ok "producer: state names the ssd root" 'grep -q "\"root\":\"$T/ssd/cargo-target\"" $ST/state.json'
ok "producer: no wait listed after the leg ran" 'grep -q "\"waits\":\[\]" $ST/state.json'
ok "producer: wait marker removed" '! ls $T/ssd/cargo-target/.wmbvs-reserve/*.wait 2>/dev/null | grep -q .'

# 11 a timed-out leg leaves no wait listed
echo 10 > "$T/avail"
run producer_to WMB_STATE_DIR="$ST" WMB_TARGET_WAIT_S=1
ok "producer timeout rc 75" '[ "$(cat $T/producer_to.rc)" = 75 ]'
ok "producer timeout: no wait listed" 'grep -q "\"waits\":\[\]" $ST/state.json'
echo 500 > "$T/avail"

# 12 incremental compilation off (CARGO_INCREMENTAL=0, page grading 2) and the base worktree lives in the run dir
ok "incremental off in the suite" 'grep -q "^export CARGO_INCREMENTAL=\${CARGO_INCREMENTAL:-0}" "$S"'
ok "base worktree under the run dir" 'grep -q "work=\$(mktemp -d -p \"\$run\"" "$S"'

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
