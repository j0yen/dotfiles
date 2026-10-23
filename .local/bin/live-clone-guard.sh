#!/usr/bin/env bash
# live-clone-guard.sh - install a pre-commit hook that refuses every commit in a LIVE CLONE.
# A live clone is a checkout that only moves by fast-forward from its remote (a collector reads it, or install.sh
# symlinks from it); work happens in worktrees and goes through PRs. Model: the hand-written fleet-dash hook
# (rb-coder commit ea4fa96 landed in the live fleet-dash tree 10-23 02:27 and the deploy broke).
#
#   live-clone-guard.sh install <repo-path> [--env NAME]   write/refresh <repo>/.git/hooks/pre-commit (idempotent)
#   live-clone-guard.sh ensure                             install for every path in ${XDG_CONFIG_HOME:-$HOME/.config}/live-clone-guard/repos
#   live-clone-guard.sh check <repo-path>                  exit 0 if our hook is installed there, else 1
#   live-clone-guard.sh --selftest
#
# Exit: install 3 = a foreign pre-commit hook is present (left untouched). Per-repo line:
#   live-clone-guard: <path> installed|already|skipped-missing|refused-foreign-hook
set -u

MARKER='# live-clone-guard'
DEFAULT_ENV=LIVE_CLONE_COMMIT

die() { echo "live-clone-guard: $*" >&2; exit 2; }

# repo_info <path> -> sets LIVE (canonical main-worktree path) and HOOKDIR (common hooks dir); returns 1 if not a usable repo
repo_info() {
  local p="$1" common
  [ -d "$p" ] || return 1
  common=$(git -C "$p" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) ;; *) common="$p/$common" ;; esac
  common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  [ "$(basename "$common")" = .git ] || return 1          # bare / unusual layouts: not a live clone
  LIVE=$(dirname "$common")
  HOOKDIR="$common/hooks"
  return 0
}

render_hook() {   # render_hook <live-path> <env-name>
  local live="$1" env="$2"
  cat <<HOOK
#!/bin/bash
$MARKER (installed by live-clone-guard.sh; do not edit, rerun 'live-clone-guard.sh install')
# $live is a LIVE CLONE: it only moves by fast-forward from its remote. Commits here are refused;
# work goes in a worktree + branch + PR. Override for a deliberate action: $env=1.
if [ "\${$env:-}" = 1 ]; then exit 0; fi
# hooks are shared by every worktree of this repo: only the live checkout itself is guarded
case "\$(git rev-parse --show-toplevel 2>/dev/null)" in '$live') ;; *) exit 0 ;; esac
echo "live-clone guard: commits in $live are refused (it is a live clone; it only moves by fast-forward)." >&2
echo "  use: git -C $live worktree add <dir> -b <branch> origin/main ; commit there ; push -u origin <branch> ; PR" >&2
echo "  override (deliberate action only): $env=1 git commit ..." >&2
exit 1
HOOK
}

is_ours() { [ -f "$1" ] && grep -q "^$MARKER" "$1"; }

# install_one <repo-path> <env-name> ; prints the status word on stdout, returns 0, 3 (foreign) or 1 (not a repo)
install_one() {
  local p="$1" env="$2" hook new
  repo_info "$p" || return 1
  case "$LIVE" in *\'*|*$'\n'*) die "refusing path with quote/newline: $LIVE" ;; esac
  hook="$HOOKDIR/pre-commit"
  if [ -e "$hook" ] && ! is_ours "$hook"; then
    echo "live-clone-guard: foreign pre-commit hook, not overwritten: $hook" >&2
    echo refused-foreign-hook
    return 3
  fi
  new=$(render_hook "$LIVE" "$env"; echo x)
  if [ -f "$hook" ] && [ "$(cat "$hook"; echo x)" = "$new" ] && [ -x "$hook" ]; then
    echo already
    return 0
  fi
  mkdir -p "$HOOKDIR"
  render_hook "$LIVE" "$env" > "$hook.tmp.$$" && chmod 755 "$hook.tmp.$$" && mv -f "$hook.tmp.$$" "$hook" || { rm -f "$hook.tmp.$$"; die "cannot write $hook"; }
  if hp=$(git -C "$LIVE" config --get core.hooksPath 2>/dev/null) && [ -n "$hp" ]; then
    echo "live-clone-guard: warning: core.hooksPath=$hp is set in $LIVE; $hook will not run unless it is the same dir" >&2
  fi
  echo installed
}

cmd_install() {
  local path="" env="$DEFAULT_ENV" st rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) [ $# -ge 2 ] || die "--env needs a name"; env="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$path" ] || die "one repo path only"; path="$1"; shift ;;
    esac
  done
  [ -n "$path" ] || die "usage: install <repo-path> [--env NAME]"
  [[ "$env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "bad env name: $env"
  st=$(install_one "$path" "$env"); rc=$?
  if [ $rc -eq 1 ]; then echo "live-clone-guard: $path is not a git repo" >&2; return 1; fi
  echo "live-clone-guard: $path $st"
  return $rc
}

cmd_ensure() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/live-clone-guard/repos" line p st rc worst=0
  [ -f "$cfg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    p="${line%%#*}"; p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] || continue
    if [ ! -d "$p" ] || ! git -C "$p" rev-parse --git-common-dir >/dev/null 2>&1; then
      echo "live-clone-guard: $p skipped-missing"; continue
    fi
    st=$(install_one "$p" "$DEFAULT_ENV"); rc=$?
    [ $rc -eq 1 ] && st=skipped-missing
    [ $rc -eq 3 ] && worst=3
    echo "live-clone-guard: $p $st"
  done < "$cfg"
  return $worst
}

cmd_check() {
  [ $# -eq 1 ] || die "usage: check <repo-path>"
  repo_info "$1" || return 1
  is_ours "$HOOKDIR/pre-commit" && [ -x "$HOOKDIR/pre-commit" ]
}

selftest() {
  local self t pass=0 fail=0 out rc
  self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
  t=$(mktemp -d "${TMPDIR:-/tmp}/lcg-selftest.XXXXXX") || { echo "FAIL: mktemp"; return 1; }
  trap 'rm -rf "$t"' RETURN
  ok()  { echo "PASS: $1"; pass=$((pass+1)); }
  bad() { echo "FAIL: $1"; fail=$((fail+1)); }
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  unset LIVE_CLONE_COMMIT

  mk() { git init -q "$1" && git -C "$1" commit -q --allow-empty -m init; }
  local live="$t/live" wt="$t/wt" foreign="$t/foreign"
  mk "$live"; live=$(cd "$live" && pwd -P)

  "$self" install "$live" >"$t/o1" 2>&1; rc=$?
  { [ $rc -eq 0 ] && grep -q ' installed$' "$t/o1"; } && ok "install writes hook (installed)" || bad "install rc=$rc: $(cat "$t/o1")"

  out=$(git -C "$live" commit --allow-empty -m x 2>&1); rc=$?
  if [ $rc -eq 1 ] && grep -qF "$live" <<<"$out" && grep -q 'LIVE_CLONE_COMMIT=1' <<<"$out"; then ok "commit in live clone refused (exit 1, names path + override)"
  else bad "live commit rc=$rc out=$out"; fi

  LIVE_CLONE_COMMIT=1 git -C "$live" commit -q --allow-empty -m ov 2>/dev/null && ok "commit with LIVE_CLONE_COMMIT=1 accepted" || bad "override commit refused"

  git -C "$live" worktree add -q "$wt" -b feat 2>/dev/null
  git -C "$wt" commit -q --allow-empty -m wtc 2>/dev/null && ok "commit in a worktree of the same repo accepted" || bad "worktree commit refused"

  local h1 h2
  h1=$(cksum < "$live/.git/hooks/pre-commit")
  "$self" install "$live" >"$t/o2" 2>&1; rc=$?
  h2=$(cksum < "$live/.git/hooks/pre-commit")
  { [ $rc -eq 0 ] && [ "$h1" = "$h2" ] && grep -q ' already$' "$t/o2"; } && ok "install is idempotent (already, hook unchanged)" || bad "idempotent rc=$rc $(cat "$t/o2")"

  "$self" install "$wt" >"$t/o3" 2>&1; rc=$?
  { [ $rc -eq 0 ] && grep -q ' already$' "$t/o3" && [ "$h1" = "$(cksum < "$live/.git/hooks/pre-commit")" ]; } && ok "install from a worktree path targets the common hooks dir and live path" || bad "worktree install rc=$rc $(cat "$t/o3")"

  "$self" install "$live" --env MY_OVERRIDE >/dev/null 2>&1
  MY_OVERRIDE=1 git -C "$live" commit -q --allow-empty -m e 2>/dev/null && ! git -C "$live" commit -q --allow-empty -m n 2>/dev/null && ok "--env NAME changes the override variable" || bad "--env override"
  "$self" install "$live" >/dev/null 2>&1

  mk "$foreign"; printf '#!/bin/sh\necho mine\nexit 0\n' > "$foreign/.git/hooks/pre-commit"; chmod 755 "$foreign/.git/hooks/pre-commit"
  h1=$(cksum < "$foreign/.git/hooks/pre-commit")
  "$self" install "$foreign" >"$t/o4" 2>&1; rc=$?
  { [ $rc -eq 3 ] && grep -qF "$foreign/.git/hooks/pre-commit" "$t/o4" && [ "$h1" = "$(cksum < "$foreign/.git/hooks/pre-commit")" ]; } && ok "foreign hook refused (exit 3, file named, byte-identical)" || bad "foreign rc=$rc $(cat "$t/o4")"

  local cfg="$t/cfg" fresh="$t/fresh"
  mk "$fresh"; fresh=$(cd "$fresh" && pwd -P); rm -f "$live/.git/hooks/pre-commit"
  mkdir -p "$cfg/live-clone-guard"
  printf '# comment\n%s\n\n%s  # trailing\n%s\n' "$live" "$t/nope" "$fresh" > "$cfg/live-clone-guard/repos"
  out=$(XDG_CONFIG_HOME="$cfg" "$self" ensure 2>/dev/null); rc=$?
  if [ $rc -eq 0 ] && [ "$out" = "live-clone-guard: $live installed
live-clone-guard: $t/nope skipped-missing
live-clone-guard: $fresh installed" ]; then ok "ensure prints installed / skipped-missing / installed"; else bad "ensure rc=$rc out=$out"; fi
  out=$(XDG_CONFIG_HOME="$cfg" "$self" ensure 2>/dev/null)
  grep -q "$live already" <<<"$out" && ok "ensure re-run reports already" || bad "ensure rerun: $out"
  printf '%s\n' "$foreign" > "$cfg/live-clone-guard/repos"
  out=$(XDG_CONFIG_HOME="$cfg" "$self" ensure 2>/dev/null); rc=$?
  { [ $rc -eq 3 ] && [ "$out" = "live-clone-guard: $foreign refused-foreign-hook" ]; } && ok "ensure reports refused-foreign-hook (exit 3)" || bad "ensure foreign rc=$rc out=$out"
  out=$(XDG_CONFIG_HOME="$t/none" "$self" ensure 2>&1); rc=$?
  { [ $rc -eq 0 ] && [ -z "$out" ]; } && ok "ensure with no config file is a silent no-op" || bad "ensure no-config rc=$rc out=$out"

  "$self" check "$live" && ok "check: installed -> 0" || bad "check installed"
  "$self" check "$foreign" && bad "check foreign should be 1" || ok "check: foreign hook -> 1"
  mk "$t/plain"; "$self" check "$t/plain" && bad "check plain should be 1" || ok "check: no hook -> 1"

  echo "selftest: $pass passed, $fail failed"
  [ $fail -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  install) shift; cmd_install "$@"; exit $? ;;
  ensure) cmd_ensure; exit $? ;;
  check) shift; cmd_check "$@"; exit $? ;;
  *) echo "usage: live-clone-guard.sh install <repo-path> [--env NAME] | ensure | check <repo-path> | --selftest" >&2; exit 2 ;;
esac
