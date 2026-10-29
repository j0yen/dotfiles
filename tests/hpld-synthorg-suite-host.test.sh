#!/usr/bin/env bash
# tests/hpld-synthorg-suite-host.test.sh: a synthorg GATED row never gets a verify on this host. The driver launches aide-verifier.sh only when AIDE_VERIFIER_SUITE_HOST
# names a real suite host; otherwise it rings ring-suite-host-missing. Reuses the stub set of tests/hand-pr-land-driver.test.sh (extracted, so no drift). Run: bash tests/hpld-synthorg-suite-host.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); DRV="$here/../.local/bin/hand-pr-land-driver.sh"; BASE="$here/hand-pr-land-driver.test.sh"
fail=0; pass() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
H1=$(printf 'a%.0s' $(seq 40)); REPO=j0yen/synthorg
eval "$(sed -n '/^iso() {/p;/^setup() {/,/^tick() {/p' "$BASE" | sed '$d')"
cleanup() { rm -rf "$T"; }
n() { grep -c "$1" "$T/calls.log"; }
ptick() {   # tick with the DEFAULT verifier name resolved through PATH (the stub), so the suite-host check is live
  T="$T" HOME="$T/home" PATH="$T/bin:$PATH" HPLD_STATE_DIR="$T/state" HPLD_VDIR="$T/vdir" HPLD_EVENTS="$T/events.jsonl" HPLD_WMD="$T/bin/wm-decide" HPLD_GH="$T/bin/gh" \
  HPLD_RBMERGE="$T/bin/rb-merge.sh" HPLD_SEATASK="$T/bin/seat-ask.sh" HPLD_ROOM="$T/bin/carbon-room.sh" HPLD_SYSTEMCTL="$T/bin/systemctl" HPLD_LINT_CMD="$T/bin/lint" \
  HPLD_REPOS="$REPO" HPLD_PREMISE_IMPORT_CMD=true bash "$DRV" >"$T/out" 2>&1; }
fresh() { setup; export T; mkdir -p "$T/home"; printf '#!/usr/bin/env bash\necho "systemd-run $*" >>"$T/calls.log"\n' >"$T/bin/systemd-run"; chmod +x "$T/bin/systemd-run"
  sed -i 's|^echo "verifier \$\*" >>"\$T/calls.log"|echo "verifier $* suite_host=${AIDE_VERIFIER_SUITE_HOST:-}" >>"$T/calls.log"|' "$T/bin/aide-verifier.sh"
  row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1 fix x"; pr $REPO 41 $H1; }

fresh; unset AIDE_VERIFIER_SUITE_HOST; ptick
[ "$(n '^verifier')" = 0 ] && [ "$(n '^systemd-run')" = 0 ] && grep -qi "ring-suite-host-missing" "$T/records.log" && [ "$(n '^seat-ask')" = 1 ]; r=$?
[ $r = 0 ] && pass "host unset + synthorg row: ring-suite-host-missing, zero verifier calls, zero local systemd-run" || { bad "host unset"; cat "$T/out" "$T/records.log"; }
ptick; [ "$(grep -ci "ring-suite-host-missing" "$T/records.log")" = 1 ] && pass "the ring is idempotent (second tick adds no row)" || bad "ring repeated"
cleanup
# a stubbed verifier (HPLD_VERIFIER set) is no bypass: no suite host still refuses
fresh; unset AIDE_VERIFIER_SUITE_HOST; T="$T" HOME="$T/home" PATH="$T/bin:$PATH" HPLD_VERIFIER="$T/bin/aide-verifier.sh" HPLD_STATE_DIR="$T/state" HPLD_VDIR="$T/vdir" HPLD_EVENTS="$T/events.jsonl" HPLD_WMD="$T/bin/wm-decide" HPLD_GH="$T/bin/gh" \
  HPLD_RBMERGE="$T/bin/rb-merge.sh" HPLD_SEATASK="$T/bin/seat-ask.sh" HPLD_ROOM="$T/bin/carbon-room.sh" HPLD_SYSTEMCTL="$T/bin/systemctl" HPLD_LINT_CMD="$T/bin/lint" HPLD_REPOS="$REPO" HPLD_PREMISE_IMPORT_CMD=true bash "$DRV" >"$T/out" 2>&1
[ "$(n '^verifier')" = 0 ] && grep -qi "ring-suite-host-missing" "$T/records.log" && pass "HPLD_VERIFIER set + no suite host: still ring-suite-host-missing, zero verifier calls" || { bad "HPLD_VERIFIER bypass"; cat "$T/out"; }
cleanup
for h in carbon localhost 127.0.0.1 "$(hostname)"; do
  fresh; AIDE_VERIFIER_SUITE_HOST=$h ptick
  [ "$(n '^verifier')" = 0 ] && [ "$(n '^systemd-run')" = 0 ] && grep -qi "ring-suite-host-missing" "$T/records.log" && pass "host=$h: refused with a ring, no local verify" || bad "host=$h launched"
  cleanup
done
fresh; AIDE_VERIFIER_SUITE_HOST=ryzen7 ptick
[ "$(n '^verifier launch')" = 1 ] && grep -q 'suite_host=ryzen7' "$T/calls.log" && [ "$(n '^systemd-run')" = 0 ] && ! grep -qi "suite-host-missing" "$T/records.log" && pass "host=ryzen7: one launch handed to the verifier with the env, no local systemd-run, no ring" || { bad "ryzen7 launch"; cat "$T/out"; }
cleanup

# no-drift: nothing tracked pins an HPLD_REPOS that omits synthorg (the live drop-in 70-synthorg-to-ryzen7.conf is deleted by the aide at deploy)
root=$(cd "$here/.." && pwd); hits=$(git -C "$root" grep -n 'HPLD_REPOS' -- . ':!tests' ':!.local/bin/hand-pr-land-driver.sh' 2>/dev/null)
bad_units=$(printf '%s\n' "$hits" | grep -v '^$' | grep -v 'j0yen/synthorg')
[ -z "$bad_units" ] && grep -q 'REPOS = os.environ.get("HPLD_REPOS", "j0yen/synthorg ' "$DRV" && pass "no tracked unit/drop-in sets HPLD_REPOS without j0yen/synthorg; the default keeps it" || bad "HPLD_REPOS drift: $bad_units"
exit $fail
