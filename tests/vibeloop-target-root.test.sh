#!/usr/bin/env bash
# tests/vibeloop-target-root.test.sh — PRD-build-worktree-targets-off-root AC5:
# vibeloop-measure.sh's release-tag build step sets CARGO_TARGET_DIR under the
# configured root (not the root filesystem), and removes it after the step —
# success or failure. Exercises the function-only helpers in
# .local/lib/vibeloop-target-root.sh directly against a fixture git repo, with
# no network, no hub, no real cargo toolchain (a stub `cargo` on PATH stands
# in — same convention as build-skill's own worktree-targets tests). Run with:
#   bash tests/vibeloop-target-root.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Function-only at source time (no top-level git/curl/systemctl calls) —
# safe to source directly, same convention as vibeloop-measure-guards.sh.
. "$here/../.local/lib/vibeloop-target-root.sh"

fail=0
assert() { # $1=cond $2=description
  if eval "$1"; then echo "ok - $2"; else echo "NOT OK - $2"; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/vlt-ac5.XXXXXX")"
# Safety net: build_tag_worktree/cleanup_tag_worktree hardcode
# $HOME/.cache/vibeloop-build/mcphost-<built> (matching production, which is
# not overridable) — every assertion below expects them self-cleaned, but
# belt-and-suspenders in case one fails before its own cleanup runs. Test
# version strings are deliberately un-semver-like so they can never collide
# with a real mcphost release directory.
trap 'rm -rf "$T" "$HOME/.cache/vibeloop-build/mcphost-9999.0.0-"*' EXIT

CRATE="$T/crate"
mkdir -p "$CRATE"
git -C "$CRATE" init -q
git -C "$CRATE" checkout -q -b main
echo hi > "$CRATE/README"
git -C "$CRATE" add README
git -C "$CRATE" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$CRATE" tag v0.1.0

# Stub cargo: `build --release` creates release/mcphost under $CARGO_TARGET_DIR
# (the only thing build_tag_worktree needs to prove the redirect worked).
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/cargo" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "build" ]; then
  td="${CARGO_TARGET_DIR:-target}"
  mkdir -p "$td/release"
  touch "$td/release/mcphost"
  exit "${FAKE_CARGO_EXIT:-0}"
fi
exit 0
EOF
chmod +x "$BIN/cargo"
export PATH="$BIN:$PATH"

ROOT="$T/target-root"
export BUILD_TARGET_ROOT="$ROOT"

# -- cargo_target_root: honors BUILD_TARGET_ROOT -----------------------------
assert "[ \"\$(cargo_target_root)\" = '$ROOT' ]" "cargo_target_root honors BUILD_TARGET_ROOT"

# -- build_tag_worktree: success path -----------------------------------------
built="9999.0.0-ac5success"
bin="$(build_tag_worktree "$CRATE" "$built" v0.1.0 /dev/null)"; rc=$?
tdir="$ROOT/vibeloop-build-$built"
assert "[ $rc -eq 0 ]"                              "build_tag_worktree exits 0 on a successful build"
assert "[[ '$bin' == '$tdir'/* ]]"                  "built binary path starts with the configured root"
assert "[ -f '$bin' ]"                              "built binary exists at the reported path"
assert "[ -d '$tdir' ]"                             "target dir exists immediately after a successful build (freed by cleanup, not by build)"

cleanup_tag_worktree "$CRATE" "$built"
assert "[ ! -d '$tdir' ]"                           "cleanup_tag_worktree removes the target dir after redeploy"
assert "[ ! -d '$HOME/.cache/vibeloop-build/mcphost-$built' ]" "cleanup_tag_worktree removes the tag worktree"

# -- build_tag_worktree: failure path (bad build_ref) removes what it made --
badbuilt="9999.0.0-ac5badref"
bad_tdir="$ROOT/vibeloop-build-$badbuilt"
if bin2="$(build_tag_worktree "$CRATE" "$badbuilt" "does-not-exist" /dev/null)"; then
  echo "NOT OK - build_tag_worktree should fail for a nonexistent build_ref"; fail=1
else
  assert "[ -z '${bin2:-}' ]" "build_tag_worktree echoes nothing on failure"
fi
assert "[ ! -d '$bad_tdir' ]"                       "target dir absent after a worktree-add failure (nothing to build, nothing to free)"

# -- build_tag_worktree: failure path (cargo build itself fails) also cleans up --
export FAKE_CARGO_EXIT=1
failbuilt="9999.0.0-ac5cargofail"
git -C "$CRATE" tag "v$failbuilt"
fail_tdir="$ROOT/vibeloop-build-$failbuilt"
if bin3="$(build_tag_worktree "$CRATE" "$failbuilt" "v$failbuilt" /dev/null)"; then
  echo "NOT OK - build_tag_worktree should fail when cargo build fails"; fail=1
fi
assert "[ ! -d '$fail_tdir' ]"                       "target dir removed after a failed cargo build"
assert "[ ! -d '$HOME/.cache/vibeloop-build/mcphost-$failbuilt' ]" "worktree removed after a failed cargo build"
unset FAKE_CARGO_EXIT

exit $fail
