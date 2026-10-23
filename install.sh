#!/usr/bin/env bash
# install.sh — symlink everything under this directory into $HOME (matching paths).
#
# Backs up any existing non-symlink target to <name>.bak.<timestamp> the
# first time it runs. Idempotent on subsequent runs (already-symlinked
# files are skipped).
#
# Run from this repo:
#   ./install.sh           # link from $PWD/<file> → $HOME/<file>
#   ./install.sh --dry-run # show what would change
#
# Files matched by skip_pattern below are *not* linked.

set -euo pipefail

DRY=0
case "${1:-}" in
  -n|--dry-run) DRY=1 ;;
  ""|--) ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "$0")" && pwd)"
home="$HOME"
ts="$(date -u +%Y%m%dT%H%M%SZ)"

# Files to skip even if present in the repo:
#   - settings.local.json: machine-local permission allowlist (also .gitignored)
skip_pattern='/(settings\.local\.json)$'

link() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
    return 0
  fi
  # dst already IS src through a parent-directory symlink (e.g. ~/.config/claude-seat -> dotfiles/.config/claude-seat):
  # linking would replace the real file inside the repo with a symlink to itself (10-22: three seat settings files
  # became "Too many levels of symbolic links" and every seat tick lost its --settings). Same inode = nothing to do.
  if [[ -e "$dst" ]] && [[ "$(readlink -f "$dst" 2>/dev/null)" == "$(readlink -f "$src")" ]]; then
    return 0
  fi
  if [[ -e "$dst" || -L "$dst" ]]; then   # -L: a dangling symlink still occupies the path
    if [[ $DRY -eq 1 ]]; then
      printf 'would back up: %s -> %s.bak.%s\n' "$dst" "$dst" "$ts"
    else
      mv "$dst" "$dst.bak.$ts"
      printf 'backed up: %s -> %s.bak.%s\n' "$dst" "$dst" "$ts"
    fi
  fi
  if [[ $DRY -eq 1 ]]; then
    printf 'would link: %s -> %s\n' "$dst" "$src"
  else
    mkdir -p "$(dirname "$dst")"
    ln -s "$src" "$dst"
    printf 'linked: %s -> %s\n' "$dst" "$src"
  fi
}

# Walk every file under the repo (excluding .git/, dotfiles meta).
while IFS= read -r -d '' src; do
  rel="${src#$repo_root/}"
  case "$rel" in
    .git/*|.gitignore|README.md|install.sh) continue ;;
  esac
  if [[ "$rel" =~ $skip_pattern ]]; then
    printf 'skip (claude-self or local-only): %s\n' "$rel"
    continue
  fi
  link "$src" "$home/$rel"
done < <(find "$repo_root" -type f -print0)

# fleet-sync post-apply check of the shared watcher lib: writes ~/.local/state/watchers/_lib.json
# (sha, bash -n, source test, every discovered consumer's --selftest). Its exit code is install.sh's, so
# fleet-sync reports "post-apply FAILED" when the lib or a consumer is broken; the links above are already in place.
post_rc=0
postapply="$repo_root/.local/bin/watcher-lib-postapply.sh"
if [[ -x "$postapply" ]]; then
  if [[ $DRY -eq 1 ]]; then
    printf 'would run: %s\n' "$postapply"
  else
    "$postapply" || post_rc=$?
  fi
fi

# live-clone guard: install the refusing pre-commit hook into each repo listed in ~/.config/live-clone-guard/repos
# (see docs/live-clone-guard.repos.example). No config = silent no-op; a failure here never fails the install.
lcg="$home/.local/bin/live-clone-guard.sh"
if [[ $DRY -eq 0 && -x "$lcg" ]]; then
  "$lcg" ensure || true
fi

printf 'done.\n'
exit "$post_rc"
