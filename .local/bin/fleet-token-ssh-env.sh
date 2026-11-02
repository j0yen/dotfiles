#!/usr/bin/env bash
# fleet-token-ssh-env.sh -- make the fleet Claude token visible to NON-interactive ssh shells (A393).
# `ssh orch 'claude -p ...'` never reads environment.d, so claude fell back to ~/.claude/.credentials.json (a depleted account).
# Installs a marker block that sources ~/.config/environment.d/90-claude-oauth.conf into ~/.zshenv (zsh reads it for every shell)
# and at the TOP of ~/.bashrc (above Debian/Ubuntu's `case $- in *i*) ;; *) return;; esac`, which sshd-spawned non-interactive bash
# hits). Neither file is repo-managed (the repo has no rc files), so this installer owns the block, not install.sh.
# Idempotent: an existing block is replaced in place by the current text; the token line itself is never read or written here.
# Usage: fleet-token-ssh-env.sh [--print-block]     (target home = $HOME)
set -euo pipefail
set +x
BEGIN='# >>> fleet-token-ssh-env (A393) >>>'
END='# <<< fleet-token-ssh-env (A393) <<<'
block() {
  cat <<'BLK'
# >>> fleet-token-ssh-env (A393) >>>
# fleet Claude token for non-interactive ssh shells; silent, no-op when the file is absent/unreadable (managed by fleet-token-ssh-env.sh)
if [ -r "$HOME/.config/environment.d/90-claude-oauth.conf" ] && [ -z "${_FLEET_TOKEN_SSH_ENV:-}" ]; then
  _FLEET_TOKEN_SSH_ENV=1
  set -a; . "$HOME/.config/environment.d/90-claude-oauth.conf" >/dev/null 2>&1; set +a
fi
# <<< fleet-token-ssh-env (A393) <<<
BLK
}
if [ "${1:-}" = "--print-block" ]; then block; exit 0; fi
[ $# -eq 0 ] || { echo "usage: $0 [--print-block]" >&2; exit 2; }
install_into() {
  local f="$1" tmp rest
  [ -e "$f" ] || : >"$f"
  tmp="$(mktemp "${f}.a393.XXXXXX")"; rest="$(mktemp "${f}.a393r.XXXXXX")"
  awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1; next} skip&&$0==e{skip=0; next} !skip{print}' "$f" >"$rest"
  { block; cat "$rest"; } >"$tmp"
  if cmp -s "$tmp" "$f"; then echo "unchanged: $f"; else cat "$tmp" >"$f"; echo "installed: $f"; fi   # cat > keeps mode and symlinks
  rm -f "$tmp" "$rest"
}
install_into "$HOME/.zshenv"
install_into "$HOME/.bashrc"
