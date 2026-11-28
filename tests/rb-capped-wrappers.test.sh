#!/usr/bin/env bash
# A1304 W11: rb-cargo-capped.sh admits through the daemon gate (cargo-jobs acquire --class hand) and its scope carries
# TasksMax=infinity and no Memory* property, with no wrapper-own predictive budget; rb-wmb-capped.sh keeps its 4G/no-swap
# bound only under a stated premise + expiry condition (the whole-journal runs/status defect).
# Fakes on a temp PATH (wm-build, systemd-run, cargo): no real acquire, no real cargo. SCOPE_LIVE=1 also starts ONE harmless real
# transient scope (`sh -c cat`) with exactly the cargo wrapper's scope properties and reads the kernel's effective values.
# usage: tests/rb-capped-wrappers.test.sh [path/to/rb-cargo-capped.sh]   (pass the old host-only copy for the RED control)
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"; S=${1:-$R/.local/bin/rb-cargo-capped.sh}; W=$R/.local/bin/rb-wmb-capped.sh; fail=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"; LOG=$T/log
cat > "$T/bin/wm-build" <<'X'
#!/bin/bash
echo "WM $*" >> "$FAKE_LOG"; [ -n "${FAKE_ACQ_RC:-}" ] && exit "$FAKE_ACQ_RC"
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift; exec "$@"
X
cat > "$T/bin/systemd-run" <<'X'
#!/bin/bash
echo "SR $*" >> "$FAKE_LOG"; while [ $# -gt 0 ]; do case "$1" in -p) shift 2;; -*) shift;; *) break;; esac; done; exec "$@"
X
cat > "$T/bin/cargo" <<'X'
#!/bin/bash
echo "CARGO $*" >> "$FAKE_LOG"; exit "${FAKE_CARGO_RC:-0}"
X
chmod 755 "$T/bin/"*
run() { : > "$LOG"; env -u RB_CARGO_CEIL_G -u RB_MEMGATE_SIGMA_G -u RB_CARGO_HEADROOM_G PATH="$T/bin:/usr/bin:/bin" FAKE_LOG="$LOG" \
  RB_CARGO_WMBUILD="$T/bin/wm-build" RB_CARGO_BIN="$T/bin/cargo" "$@" 2>"$T/err"; }
# 0. a candidate that ignores the test seams would run the REAL wm-build/cargo: its dynamic cases are not executed (counted FAIL)
if ! grep -q 'RB_CARGO_BIN' "$S" || ! grep -q 'RB_CARGO_WMBUILD' "$S"; then
  bad "candidate ignores the RB_CARGO_BIN/RB_CARGO_WMBUILD seams: dynamic cases 1-3 not executed (would run real cargo)"; dyn=0
else dyn=1; fi
# 2. (static, runs for every candidate) no wrapper-own predictive budget in code lines
grep -vE '^[[:space:]]*#' "$S" | grep -qE 'MemAvailable|SIGMA_G \* G|REFUSE reason=' && bad "wrapper-own predictive budget still present" || ok "no wrapper-own predictive budget"
grep -vE '^[[:space:]]*#' "$S" | grep -qE 'Memory(High|Max|SwapMax)=' && bad "wrapper code sets a Memory* property" || ok "wrapper code sets no Memory* property"
cd "$T" || exit 1
if [ $dyn = 1 ]; then
# 1. normal call: daemon acquire wraps the scope, cargo gets its args unchanged
run bash "$S" test --locked --offline; rc=$?
grep -qE '^WM builder cargo-jobs acquire --class hand --producer rb-cargo-capped .*--wait-minutes 60 -- systemd-run ' "$LOG" && ok "admits through cargo-jobs acquire --class hand" || bad "no daemon acquire: $(cat "$LOG")"
sr=$(grep '^SR ' "$LOG")
case " $sr " in *" -p TasksMax=infinity "*) ok "scope TasksMax=infinity";; *) bad "scope lacks TasksMax=infinity: $sr";; esac
printf '%s\n' "$sr" | grep -qE 'Memory(High|Max|SwapMax|Min|Low)=' && bad "scope carries a Memory* property: $sr" || ok "scope carries no Memory* property"
grep -qx 'CARGO test --locked --offline' "$LOG" && [ $rc = 0 ] && ok "cargo args unchanged, rc 0" || bad "cargo call rc=$rc: $(cat "$LOG")"
# 3. compatibility: old env knobs accepted and ignored with one note; exit codes propagate
run env RB_CARGO_CEIL_G=5 bash "$S" build; rc=$?
[ $rc = 0 ] && grep -q 'ignored RB_CARGO_CEIL_G=5' "$T/err" && ! grep -q 'Memory' "$LOG" && ok "RB_CARGO_CEIL_G=5 ignored with a note" || bad "ceil knob rc=$rc err=$(cat "$T/err") log=$(cat "$LOG")"
run env FAKE_ACQ_RC=75 bash "$S" build; rc=$?; [ $rc = 75 ] && ! grep -q '^CARGO' "$LOG" && ok "acquire 75 -> exit 75, cargo not run" || bad "acquire 75 rc=$rc"
run env FAKE_CARGO_RC=101 bash "$S" test; rc=$?; [ $rc = 101 ] && ok "cargo exit 101 propagates" || bad "cargo rc propagation rc=$rc"
run bash "$S"; rc=$?; [ $rc = 2 ] && ok "no args -> usage exit 2" || bad "usage rc=$rc"
run env RB_CARGO_WAIT_MIN=x bash "$S" build; rc=$?; [ $rc = 2 ] && ! grep -q '^WM' "$LOG" && ok "bad wait -> exit 2, no acquire" || bad "bad wait rc=$rc"
fi
bash -n "$S" && ok "bash -n rb-cargo-capped" || bad "bash -n rb-cargo-capped"
# 4. rb-wmb-capped keeps its bound only under a stated premise and expiry condition
if [ -r "$W" ]; then
  grep -q '^# PREMISE (A1304' "$W" && grep -q 'State::journal_lines' "$W" && ok "rb-wmb-capped premise names the whole-journal defect" || bad "rb-wmb-capped premise missing"
  grep -qE '^# EXPIRES: when the installed wm-build' "$W" && ! grep -E '^# EXPIRES' "$W" | grep -qE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' && ok "rb-wmb-capped expiry is condition-only" || bad "rb-wmb-capped expiry missing or dated"
  bash -n "$W" && ok "bash -n rb-wmb-capped" || bad "bash -n rb-wmb-capped"
fi
if [ "${SCOPE_LIVE:-0}" = 1 ]; then
  props=$(sed -n 's/.*systemd-run --user --scope \(.*\) "\$CARGO" "\$@".*/\1/p; s/^SCOPE=(systemd-run --user --scope \(.*\))$/\1/p' "$S" | head -1 | sed 's/"\${CEIL_G}G"/12G/; s/--slice=app.slice //; s/--quiet //')
  echo "live props: $props"
  # shellcheck disable=SC2086
  o=$(systemd-run --user --scope --slice=app.slice --quiet $props -- sh -c 'c=$(sed -n "s/^0:://p" /proc/self/cgroup); echo "pids.max=$(cat /sys/fs/cgroup$c/pids.max) memory.max=$(cat /sys/fs/cgroup$c/memory.max) memory.swap.max=$(cat /sys/fs/cgroup$c/memory.swap.max)"' 2>&1)
  echo "live scope: $o"
  case "$o" in "pids.max=max memory.max=max memory.swap.max=max") ok "live fresh scope unlimited";; *) bad "live fresh scope not unlimited: $o";; esac
fi
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit $fail
