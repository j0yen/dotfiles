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
#   ./install.sh --link-only [--paths-from <old> <new>]
#       link loop + protected-hooks check only (the git post-merge/post-rewrite/post-checkout hooks written by
#       live-clone-guard.sh call this, so a pull IS an install). Never replaces or backs up a non-symlink target
#       (prints "conflict: <dst>"), skips the consumer --selftest loop and live-clone-guard ensure, still runs
#       bash -n on linked *.sh and the watcher-lib sha/source check. --paths-from links only the files changed
#       between the two revs and prints "stale: <dst>" for deleted/renamed-away paths still linked into the repo.
#       Combines with --dry-run.
#
# Files matched by skip_pattern below are *not* linked.

set -euo pipefail

DRY=0
LINK_ONLY=0
PF_OLD="" PF_NEW="" PATHS_FROM=0
usage() { echo "usage: $0 [--dry-run] [--link-only [--paths-from <old> <new>]]" >&2; exit 2; }
if [[ $# -eq 0 ]]; then :; else
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) DRY=1; shift ;;
      --link-only) LINK_ONLY=1; shift ;;
      --paths-from) [[ $# -ge 3 ]] || usage; PATHS_FROM=1; PF_OLD="$2"; PF_NEW="$3"; shift 3 ;;
      --) shift ;;
      *) usage ;;
    esac
  done
  [[ $PATHS_FROM -eq 0 || $LINK_ONLY -eq 1 ]] || usage
fi

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
  if [[ $LINK_ONLY -eq 1 ]]; then
    # a pull must never move user data: a real file/dir at dst is reported, never replaced or backed up.
    # A symlink (dangling or pointing elsewhere) loses nothing when re-pointed.
    if [[ -e "$dst" && ! -L "$dst" ]]; then
      printf 'conflict: %s\n' "$dst"
      return 0
    fi
    if [[ $DRY -eq 1 ]]; then
      printf 'would link: %s -> %s\n' "$dst" "$src"
    else
      mkdir -p "$(dirname "$dst")"
      ln -sfn "$src" "$dst"
      printf 'linked: %s -> %s\n' "$dst" "$src"
    fi
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

# report_stale <rel>: report-only. A deleted/renamed-away path whose $HOME dst is still a symlink into this repo.
report_stale() {
  skip_rel "$1" >/dev/null && return 0
  local dst="$home/$1"
  if [[ -L "$dst" ]]; then
    case "$(readlink "$dst")" in "$repo_root"/*) printf 'stale: %s\n' "$dst" ;; esac
  fi
}

# skip_rel <rel>: 0 when the repo-relative path is dotfiles meta or local-only (never linked)
skip_rel() {
  case "$1" in
    .git/*|.gitignore|README.md|install.sh) return 0 ;;
  esac
  if [[ "$1" =~ $skip_pattern ]]; then
    printf 'skip (claude-self or local-only): %s\n' "$1"
    return 0
  fi
  return 1
}

linked_srcs=()   # --link-only: every src handled this run, for the bash -n pass
do_link() {      # do_link <rel>
  skip_rel "$1" && return 0
  link "$repo_root/$1" "$home/$1"
  linked_srcs+=("$repo_root/$1")
}

# --paths-from <old> <new>: parse `git diff --name-status -M -z` (A/M/T link, D stale, R old stale + new link, C link).
# Unusable revs fall back to the full walk (never a silent skip).
paths_from_ok=0
if [[ $LINK_ONLY -eq 1 && $PATHS_FROM -eq 1 ]]; then
  diff_tmp="$(mktemp)"   # NUL-separated: a command substitution would drop the NULs
  if git -C "$repo_root" diff --name-status -M -z --diff-filter=ADMRTC "$PF_OLD" "$PF_NEW" > "$diff_tmp" 2>/dev/null; then
    paths_from_ok=1
    while IFS= read -r -d '' status; do
      case "$status" in
        R*) IFS= read -r -d '' oldp; IFS= read -r -d '' newp
            report_stale "$oldp"; [[ -f "$repo_root/$newp" ]] && do_link "$newp" ;;
        C*) IFS= read -r -d '' oldp; IFS= read -r -d '' newp
            [[ -f "$repo_root/$newp" ]] && do_link "$newp" ;;
        D*) IFS= read -r -d '' oldp; report_stale "$oldp" ;;
        *)  IFS= read -r -d '' newp; [[ -f "$repo_root/$newp" ]] && do_link "$newp" ;;
      esac
    done < "$diff_tmp"
  else
    printf 'paths-from: cannot diff %s..%s; falling back to the full link-only walk\n' "$PF_OLD" "$PF_NEW" >&2
  fi
  rm -f "$diff_tmp"
fi

# Walk every file under the repo (excluding .git/, dotfiles meta).
if [[ $paths_from_ok -eq 0 ]]; then
  while IFS= read -r -d '' src; do
    rel="${src#$repo_root/}"
    if [[ $LINK_ONLY -eq 1 ]]; then
      do_link "$rel"
      continue
    fi
    case "$rel" in
      .git/*|.gitignore|README.md|install.sh) continue ;;
    esac
    if [[ "$rel" =~ $skip_pattern ]]; then
      printf 'skip (claude-self or local-only): %s\n' "$rel"
      continue
    fi
    link "$src" "$home/$rel"
  done < <(find "$repo_root" -type f -print0)
fi

# fleet-sync post-apply check of the shared watcher lib: writes ~/.local/state/watchers/_lib.json
# (sha, bash -n, source test, every discovered consumer's --selftest). Its exit code is install.sh's, so
# fleet-sync reports "post-apply FAILED" when the lib or a consumer is broken; the links above are already in place.
post_rc=0
postapply="$repo_root/.local/bin/watcher-lib-postapply.sh"
if [[ $LINK_ONLY -eq 1 ]]; then
  # cheap half only: bash -n on every linked *.sh + the watcher-lib sha/source check. The consumer --selftest loop
  # (load-heavy; the 10-27 df130c verify flake) stays with the full install.
  bashn_fail=0
  for f in "${linked_srcs[@]+"${linked_srcs[@]}"}"; do
    case "$f" in *.sh) [[ -f "$f" ]] && ! bash -n "$f" 2>/dev/null && { printf 'bash-n FAILED: %s\n' "$f" >&2; bashn_fail=$((bashn_fail+1)); } ;; esac
  done
  wlib="$home/.local/lib/watcher-premise.sh"
  if [[ -r "$wlib" ]]; then
    wsha="$(sha256sum "$wlib" | cut -d' ' -f1)"
    if bash -n "$wlib" 2>/dev/null && bash -c 'source "$1" && declare -F wp_arm wp_gate wp_emit_write wp_selftest >/dev/null' _ "$wlib" >/dev/null 2>&1 </dev/null; then
      printf 'watcher-lib: ok sha=%s\n' "$wsha"
    else
      printf 'watcher-lib: FAILED sha=%s\n' "$wsha" >&2
    fi
  fi
  printf 'bash-n: fail=%s\n' "$bashn_fail"
  printf 'selftest=skipped\n'
elif [[ -x "$postapply" ]]; then
  if [[ $DRY -eq 1 ]]; then
    printf 'would run: %s\n' "$postapply"
  else
    "$postapply" || post_rc=$?
  fi
fi

# live-clone guard: install the refusing pre-commit hook into each repo listed in ~/.config/live-clone-guard/repos
# (see README.md § Live-clone guard). No config = silent no-op; a failure here never fails the install.
lcg="$home/.local/bin/live-clone-guard.sh"
if [[ $LINK_ONLY -eq 0 && $DRY -eq 0 && -x "$lcg" ]]; then
  "$lcg" ensure || true
fi

# protected-hooks check: summa + wintermute hooks (.claude/protected-hooks.txt) must still be wired in the installed settings.json
# unless Joe's approval is in ~/.claude/state/approvals.log. A failure makes install.sh exit non-zero (links are already in place).
phc="$home/.claude/hooks/protected-hooks-check.sh"
if [[ -x "$phc" && -r "$home/.claude/settings.json" ]]; then
  if [[ $DRY -eq 1 ]]; then
    printf 'would run: %s %s\n' "$phc" "$home/.claude/settings.json"
  else
    "$phc" "$home/.claude/settings.json" || { post_rc=$?; printf 'protected-hooks-check FAILED (rc=%s)\n' "$post_rc" >&2; }
  fi
fi

printf 'done.\n'
exit "$post_rc"
