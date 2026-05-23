#!/usr/bin/env bash
# install.sh — symlink everything under .claude/ into ~/.claude/.
#
# Backs up any existing non-symlink target to <name>.bak.<timestamp> the
# first time it runs. Idempotent on subsequent runs (already-symlinked
# files are skipped).
#
# Run from this repo:
#   ./install.sh           # link from $HOME/dotfiles/<file> → $HOME/<file>
#   ./install.sh --dry-run # show what would change
#
# Files under .gitignore (settings.local.json by default) are *not*
# linked — they stay machine-local.

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

# Files to skip even if present in the repo. Keep machine-local.
skip_pattern='/(settings\.local\.json)$'

link() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
    return 0
  fi
  if [[ -e "$dst" ]]; then
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
    printf 'skip (machine-local): %s\n' "$rel"
    continue
  fi
  link "$src" "$home/$rel"
done < <(find "$repo_root" -type f -print0)

printf 'done.\n'
