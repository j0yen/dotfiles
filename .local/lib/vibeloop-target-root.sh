#!/usr/bin/env bash
# vibeloop-target-root.sh — cargo target-dir root resolution + the release-tag
# build/cleanup helpers for vibeloop-measure.sh's "hub behind a shipped tag"
# path. Function-only, no side effects at source time, so
# tests/vibeloop-target-root.test.sh can source it directly against a fixture
# repo with no network/hub calls — same convention as
# .local/lib/vibeloop-measure-guards.sh.
#
# PRD-build-worktree-targets-off-root (2026-09-08): a tag's release build is
# another ~52G `target/`; building it under ~/.cache (root filesystem) is the
# same failure mode that filled root and killed two truth-tier measure runs
# that day. cargo_target_root()'s precedence is kept in sync BY HAND with
# build-skill's scripts/worktree-extend.sh target_root() (separate repo, same
# convention): $BUILD_TARGET_ROOT env, else /mnt/data/jsy/cargo-targets when
# /mnt/data exists, else $HOME/.cache/cargo-targets.
set -uo pipefail

cargo_target_root() {
  if [ -n "${BUILD_TARGET_ROOT:-}" ]; then
    printf '%s\n' "$BUILD_TARGET_ROOT"
  elif [ -d /mnt/data ]; then
    printf '%s\n' /mnt/data/jsy/cargo-targets
  else
    printf '%s\n' "$HOME/.cache/cargo-targets"
  fi
}

# Build $build_ref of $crate in a detached worktree at
# $HOME/.cache/vibeloop-build/mcphost-$built (small git checkout, stays on
# root — not the concern here), with CARGO_TARGET_DIR under
# cargo_target_root()/vibeloop-build-$built so the big release build never
# sits on the root filesystem. $logfile (optional) collects worktree/build
# output; defaults to /dev/null for test runs.
#
# On success: echoes the built binary path ("$tdir/release/mcphost") on
# stdout, returns 0, target dir left in place for the caller to use then free
# via cleanup_tag_worktree.
# On failure (worktree add or cargo build): cleans up the worktree AND the
# target dir itself before returning 1 (nothing echoed) — a failed build
# never leaves its target dir behind.
build_tag_worktree() {
  local crate="$1" built="$2" build_ref="$3" logfile="${4:-/dev/null}"
  local wt="$HOME/.cache/vibeloop-build/mcphost-$built"
  local tdir; tdir="$(cargo_target_root)/vibeloop-build-$built"
  git -C "$crate" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$crate" worktree add --detach -f "$wt" "$build_ref" >>"$logfile" 2>&1 || return 1
  if ! ( cd "$wt" && CARGO_TARGET_DIR="$tdir" cargo build --release -q ) >>"$logfile" 2>&1; then
    rm -rf "$tdir"
    git -C "$crate" worktree remove --force "$wt" >/dev/null 2>&1
    return 1
  fi
  echo "$tdir/release/mcphost"
}

# Remove a tag build's worktree + cargo target dir. Idempotent — safe to call
# whether build_tag_worktree succeeded (target dir still present) or already
# cleaned up after its own failure.
cleanup_tag_worktree() {
  local crate="$1" built="$2"
  rm -rf "$(cargo_target_root)/vibeloop-build-$built"
  git -C "$crate" worktree remove --force "$HOME/.cache/vibeloop-build/mcphost-$built" >/dev/null 2>&1 || true
}
