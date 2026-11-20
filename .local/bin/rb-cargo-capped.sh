#!/bin/bash
# RB hand-cargo wrapper (rb seat 10-30, ctl d-20261030-125721-controller-161d; five-whys 2026-10-30-redbaron-global-oom-1149).
# Session scopes are capped at 8G (session-.scope.d/50-rb-session-memmax.conf), so hand cargo runs in its own user scope.
# Used as the fallback when /mnt/data/hand/cargo-slot.sh's cargo.lock is held (sccache inheriting the flock fd, 11-19).
# A1304 W11 2026-11-20 (Joe/Hermes no-caps authority): the scope carries TasksMax=infinity and no Memory* property, and the
#   wrapper's own predictive budgets (MemGate Σ 26G of live app.slice MemoryCurrent + ceiling, MemAvailable >= ceiling + 2G)
#   are replaced by the supported daemon admission gate, `wm-build builder cargo-jobs acquire --class hand`, which is what
#   cargo-slot.sh and r7-cargo-slot.sh use. Admission waits for room (exit 75 = no slot within the wait); it never takes cargo.lock.
#   Was (host-only, sha b7acfa84): -p MemoryMax=${RB_CARGO_CEIL_G:-12}G -p MemorySwapMax=0 plus an immediate exit-75 refusal.
#   RB_CARGO_CEIL_G / RB_MEMGATE_SIGMA_G / RB_CARGO_HEADROOM_G are accepted and ignored (one stderr note) for caller compatibility.
# Usage: rb-cargo-capped.sh [--selftest] <cargo args...>   (exit 75 = no slot within the wait, 2 = usage; else cargo's own exit)
# Env: RB_CARGO_WAIT_MIN (acquire wait, default 60 as cargo-slot.sh). Test seams: RB_CARGO_WMBUILD, RB_CARGO_BIN.
set -u
WM=${RB_CARGO_WMBUILD:-/home/jsy/.cargo/bin/wm-build}
CARGO=${RB_CARGO_BIN:-/home/jsy/.cargo/bin/cargo}
CFG=/home/jsy/.config/wm-build/config.toml
SD=/home/jsy/.local/state/wm-build
WAIT_MIN=${RB_CARGO_WAIT_MIN:-60}
SCOPE=(systemd-run --user --scope --slice=app.slice --quiet -p TasksMax=infinity)

ignored=""
for v in RB_CARGO_CEIL_G RB_MEMGATE_SIGMA_G RB_CARGO_HEADROOM_G; do [ -n "${!v:-}" ] && ignored="$ignored $v=${!v}"; done
[ -z "$ignored" ] || echo "rb-cargo-capped: ignored$ignored (no per-job memory cap or wrapper budget; admission is the daemon gate)" >&2

if [ "${1:-}" = --selftest ]; then
  rc=0
  [ -x "$WM" ] || { echo "FAIL wm-build not executable: $WM"; rc=1; }
  [ -x "$CARGO" ] || { echo "FAIL cargo not executable: $CARGO"; rc=1; }
  command -v systemd-run >/dev/null || { echo "FAIL systemd-run not found"; rc=1; }
  case "$WAIT_MIN" in ''|*[!0-9]*) echo "FAIL RB_CARGO_WAIT_MIN not a whole number: $WAIT_MIN"; rc=1 ;; esac
  echo "argv: $WM builder cargo-jobs acquire --class hand --producer rb-cargo-capped --wait-minutes $WAIT_MIN -- ${SCOPE[*]} $CARGO <args>"
  [ "$rc" = 0 ] && echo "rb-cargo-capped selftest PASS" || echo "rb-cargo-capped selftest FAIL"
  exit "$rc"
fi

[ "$#" -ge 1 ] || { echo "usage: rb-cargo-capped.sh [--selftest] <cargo args...>" >&2; exit 2; }
case "$WAIT_MIN" in ''|*[!0-9]*) echo "rb-cargo-capped: RB_CARGO_WAIT_MIN must be a whole number of minutes" >&2; exit 2 ;; esac
exec "$WM" builder cargo-jobs acquire --class hand --producer rb-cargo-capped --config "$CFG" --state-dir "$SD" \
  --wait-minutes "$WAIT_MIN" -- "${SCOPE[@]}" "$CARGO" "$@"
