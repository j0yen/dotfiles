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
#   - CLAUDE_SELF{,.default}.md / claude-self-start.sh / claude-self CLI:
#     the claude-self cluster is owned by the autobuilder pipeline. Until
#     autobuilder ships v0.2 and explicitly wires it, install.sh skips these
#     so partial drafts don't bind into a live SessionStart.
skip_pattern='/(settings\.local\.json|CLAUDE_SELF\.md|CLAUDE_SELF\.default\.md|claude-self-start\.sh|claude-self)$'

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
    printf 'skip (claude-self or local-only): %s\n' "$rel"
    continue
  fi
  link "$src" "$home/$rel"
done < <(find "$repo_root" -type f -print0)

printf 'done.\n'
