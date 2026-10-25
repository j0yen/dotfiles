#!/usr/bin/env bash
# hook-registration.test.sh - every hook a tracked settings file registers by absolute path (~/.claude/hooks/X,
# $HOME/.claude/hooks/X, ${HOME}/.claude/hooks/X, /home/jsy/.claude/hooks/X, anywhere in the command string) must exist as
# .claude/hooks/X in this repo, and every tracked file under .claude/hooks must be executable (git mode).
# Why: a pull installs settings.json but not a hook file that was never tracked (dotfiles#90 registered a land gate with no
# install; cargo-block-carbon.* lived only on carbon), and a registered hook that does not resolve silently never runs.
# Exemption: the peon-ping/ subtree is owned by the third-party peon-ping installer (never tracked here); the live post-check in
# .local/bin/dotfiles-hook-sync.sh still requires those paths to resolve on each node.
# Self-test fixtures (temp dir) must FAIL on the plain, `bash ~/...` and `python3 /home/jsy/...` missing-hook forms and on a non-exec hook.
# shellcheck disable=SC2016  # single-quoted $HOME / ${HOME} are literals by design
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXTERNAL_PREFIX='peon-ping/'
RE='(~|\$HOME|\$\{HOME\})/\.claude/hooks/[A-Za-z0-9._/-]+|/home/jsy/\.claude/hooks/[A-Za-z0-9._/-]+'

# settings_paths FILE: every distinct registered hook path token (whole command string scanned), one per line
settings_paths() {
  jq -r '[.. | objects | select(has("command")) | .command | strings] | .[]' "$1" 2>/dev/null \
    | grep -oE "$RE" | sort -u
}

# check_root ROOT: prints MISSING / NOT-EXEC lines, returns 1 when any
check_root() {
  local root=$1 bad=0 f p rest mode
  local -a files=()
  while IFS= read -r f; do files+=("$f"); done < <(
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then git -C "$root" ls-files -- '.claude/settings.json' '.claude/settings*.json'
    else (cd "$root" && ls .claude/settings*.json 2>/dev/null); fi | sort -u)
  for f in "${files[@]}"; do
    [ -f "$root/$f" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      rest=${p#*/.claude/hooks/}
      case $rest in "$EXTERNAL_PREFIX"*) continue ;; esac
      [ -e "$root/.claude/hooks/$rest" ] || { echo "MISSING $p (named in $f; no .claude/hooks/$rest in the repo)"; bad=1; }
    done < <(settings_paths "$root/$f")
  done
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    while read -r mode _ _ f; do
      [ "$mode" = 100755 ] || { echo "NOT-EXEC $f (git mode $mode)"; bad=1; }
    done < <(git -C "$root" ls-files -s -- .claude/hooks)
  else
    while IFS= read -r f; do [ -x "$root/$f" ] || { echo "NOT-EXEC $f"; bad=1; }; done < <(cd "$root" && find .claude/hooks -type f 2>/dev/null)
  fi
  return $bad
}

fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# ---- self-test fixtures ----
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkfix() { # NAME COMMAND [nonexec]: a fixture repo with hooks/ok.sh and one settings file registering COMMAND
  local d=$T/$1; mkdir -p "$d/.claude/hooks"
  printf '#!/bin/sh\nexit 0\n' > "$d/.claude/hooks/ok.sh"; chmod +x "$d/.claude/hooks/ok.sh"
  [ "${3:-}" = nonexec ] && chmod -x "$d/.claude/hooks/ok.sh"
  jq -n --arg c "$2" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c}]}]}}' > "$d/.claude/settings.json"
}
expect_fail() { # NAME DESC
  if out=$(check_root "$T/$1" 2>&1); then bad "selftest: $2 was NOT caught"; else pass "selftest: $2 fails ($(printf '%s' "$out" | head -n1 | cut -c1-70))"; fi
}
expect_pass() {
  if out=$(check_root "$T/$1" 2>&1); then pass "selftest: $2 passes"; else bad "selftest: $2 wrongly failed: $out"; fi
}
mkfix plain   '/home/jsy/.claude/hooks/missing.sh';              expect_fail plain  'plain missing hook'
mkfix bashf   'bash ~/.claude/hooks/missing.sh';                 expect_fail bashf  'bash ~/.claude/hooks/missing.sh'
mkfix pyf     'python3 /home/jsy/.claude/hooks/missing.py';      expect_fail pyf    'python3 /home/jsy/.claude/hooks/missing.py'
mkfix chain   'timeout 5 env X=1 $HOME/.claude/hooks/ok.sh && ${HOME}/.claude/hooks/missing.sh'; expect_fail chain 'missing hook behind timeout/env/&& and ${HOME}'
mkfix nonexec '/home/jsy/.claude/hooks/ok.sh' nonexec;           expect_fail nonexec 'non-executable hook file'
mkfix good    'bash ~/.claude/hooks/ok.sh && python3 "${HOME}/.claude/hooks/ok.sh"'; expect_pass good 'registered hooks that exist'

# ---- the real repo ----
if out=$(check_root "$here" 2>&1); then pass "real repo: every registered hook is tracked and every tracked hook is executable"
else bad "real repo"; printf '%s\n' "$out"; fi

[ "$fail" -eq 0 ] && echo "hook-registration: ALL PASS" || echo "hook-registration: FAILED"
exit "$fail"
