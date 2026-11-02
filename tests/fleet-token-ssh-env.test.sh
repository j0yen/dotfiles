#!/usr/bin/env bash
# tests/fleet-token-ssh-env.test.sh -- A393: the fleet token reaches non-interactive ssh shells via the block fleet-token-ssh-env.sh installs.
# Fake HOME, fake token value; the value must never reach stdout/stderr. Run: bash tests/fleet-token-ssh-env.test.sh
set -euo pipefail
set +x
root="$(cd "$(dirname "$0")/.." && pwd)"
inst="$root/.local/bin/fleet-token-ssh-env.sh"
fail=0; skipped=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
tok=fake-token-for-test
h="$(mktemp -d)"; trap 'rm -rf "$h"' EXIT
mkdir -p "$h/.config/environment.d"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" >"$h/.config/environment.d/90-claude-oauth.conf"
# Ubuntu-style .bashrc with the interactive-only early return; zshenv pre-existing content must survive
printf '%s\n' '# ~/.bashrc' 'case $- in' '    *i*) ;;' '      *) return;;' 'esac' 'echo interactive-only-ran' >"$h/.bashrc"
printf '%s\n' 'export KEEP_ME=1' >"$h/.zshenv"

out="$(env -i PATH="$PATH" HOME="$h" bash "$inst" 2>&1)"; echo "$out" | grep -q 'installed: .*bashrc' && echo "$out" | grep -q 'installed: .*zshenv' && ok "first run installs both files" || bad "first run installs both files"
[ "$(head -n1 "$h/.bashrc")" = '# >>> fleet-token-ssh-env (A393) >>>' ] && ok "block sits above the case \$- early return" || bad "block sits above the early return"
grep -q interactive-only-ran "$h/.bashrc" && grep -qx 'export KEEP_ME=1' "$h/.zshenv" && ok "pre-existing rc content kept" || bad "pre-existing rc content kept"

# bash non-interactive (what sshd runs: bash -c with ~/.bashrc sourced, as Debian's SSH_SOURCE_BASHRC does)
o="$(env -i PATH="$PATH" HOME="$h" bash -c '. "$HOME/.bashrc"; test -n "$CLAUDE_CODE_OAUTH_TOKEN" && test "$CLAUDE_CODE_OAUTH_TOKEN" = "'"$tok"'"' 2>&1)" && ok "bash non-interactive sees the token" || bad "bash non-interactive sees the token"
[ -z "$o" ] && ok "bash source prints nothing" || bad "bash source printed: no value shown"
case "$o" in *"$tok"*) bad "token leaked to output";; *) ok "token not in bash output";; esac
# exported to children (claude is a child process)
env -i PATH="$PATH" HOME="$h" bash -c '. "$HOME/.bashrc"; bash -c "test \"\$CLAUDE_CODE_OAUTH_TOKEN\" = \"'"$tok"'\""' && ok "token exported to child processes" || bad "token exported to child processes"
# second source harmless
o="$(env -i PATH="$PATH" HOME="$h" bash -c '. "$HOME/.bashrc"; . "$HOME/.bashrc"; test "$CLAUDE_CODE_OAUTH_TOKEN" = "'"$tok"'"' 2>&1)" && [ -z "$o" ] && ok "second source harmless" || bad "second source harmless"
# absent conf = silent no-op
h2="$(mktemp -d)"; env -i PATH="$PATH" HOME="$h2" bash "$inst" >/dev/null
o="$(env -i PATH="$PATH" HOME="$h2" bash -c '. "$HOME/.bashrc"; test -z "${CLAUDE_CODE_OAUTH_TOKEN:-}"' 2>&1)" && [ -z "$o" ] && ok "absent conf: silent no-op" || bad "absent conf: silent no-op"
rm -rf "$h2"
# idempotent installer
before="$(cat "$h/.bashrc" "$h/.zshenv" | cksum)"
out="$(env -i PATH="$PATH" HOME="$h" bash "$inst" 2>&1)"
after="$(cat "$h/.bashrc" "$h/.zshenv" | cksum)"
[ "$before" = "$after" ] && [ "$(grep -c 'unchanged:' <<<"$out")" = 2 ] && ok "installer re-run is a no-op" || bad "installer re-run is a no-op"
[ "$(grep -c '>>> fleet-token-ssh-env' "$h/.bashrc")" = 1 ] && ok "exactly one block" || bad "exactly one block"
# installer never carries or prints the token
case "$out$(bash "$inst" --print-block)" in *"$tok"*) bad "installer leaked token";; *) ok "installer output free of token";; esac
grep -q "$tok" "$h/.bashrc" "$h/.zshenv" && bad "token copied into rc" || ok "token not copied into rc files"
# stale block is replaced, not duplicated
sed -i 's/silent, no-op/OLD TEXT/' "$h/.bashrc"
env -i PATH="$PATH" HOME="$h" bash "$inst" >/dev/null
[ "$(grep -c '>>> fleet-token-ssh-env' "$h/.bashrc")" = 1 ] && ! grep -q 'OLD TEXT' "$h/.bashrc" && ok "stale block replaced in place" || bad "stale block replaced in place"

# zsh form (skipped and counted when zsh is absent)
if command -v zsh >/dev/null 2>&1; then
  o="$(env -i PATH="$PATH" HOME="$h" ZDOTDIR="$h" zsh -c 'test "$CLAUDE_CODE_OAUTH_TOKEN" = "'"$tok"'" && test "$KEEP_ME" = 1' 2>&1)" && [ -z "$o" ] && ok "zsh non-interactive sees the token" || bad "zsh non-interactive sees the token"
else
  skipped=$((skipped+1)); echo "skipped: zsh not installed (zsh cases skipped=$skipped)"
fi
[ "$fail" = 0 ] && echo "TEST PASS (skipped=$skipped)" || { echo "TEST FAIL"; exit 1; }
