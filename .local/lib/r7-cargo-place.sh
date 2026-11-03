#!/bin/bash
# r7-cargo-place.sh — shared target-dir placement for ryzen7 cargo (A681; sourced by .local/bin/r7-cargo-slot.sh and .local/bin/cargo).
# PREMISE: on ryzen7 a cargo target dir on the root device fills / (11-02 ENOSPC: three 140 G targets on the root NVMe); /mnt/ssd is the build disk.
# r7_cargo_place [topdir]: resolve the target (CARGO_TARGET_DIR, else <cwd>/target; a relative value is taken from cwd). If the nearest existing
#   parent is on the same device as the root path, rewrite CARGO_TARGET_DIR to $R7_SSD_ROOT/cargo-target/hand-<basename of git toplevel or cwd> and
#   say so on stderr. A target already off the root device is left untouched. Returns 75 when the ssd root is not a mountpoint.
# test overrides (names ours): R7_SSD_ROOT (default /mnt/ssd), R7_FINDMNT (default findmnt), R7_ROOT_PATH (default /).
r7_cargo_place() {
  local top=${1:-} t p rootdev tdev name dest
  t=${CARGO_TARGET_DIR:-}; [ -n "$t" ] || t=$PWD/target
  case $t in /*) ;; *) t=$PWD/$t;; esac
  p=$t; while [ ! -e "$p" ] && [ "$p" != / ] && [ -n "$p" ]; do p=$(dirname "$p"); done
  rootdev=$(stat -c %d "${R7_ROOT_PATH:-/}" 2>/dev/null) || return 0
  tdev=$(stat -c %d "$p" 2>/dev/null) || return 0
  [ "$tdev" = "$rootdev" ] || return 0
  "${R7_FINDMNT:-findmnt}" -n "${R7_SSD_ROOT:-/mnt/ssd}" >/dev/null 2>&1 || { echo "r7-cargo-slot: /mnt/ssd not mounted, refusing root target" >&2; return 75; }
  [ -n "$top" ] || top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
  name=$(basename "$top")
  dest=${R7_SSD_ROOT:-/mnt/ssd}/cargo-target/hand-$name
  mkdir -p "$dest" 2>/dev/null || true
  export CARGO_TARGET_DIR=$dest
  echo "r7-cargo-slot: target moved off root -> $dest" >&2
  return 0
}
