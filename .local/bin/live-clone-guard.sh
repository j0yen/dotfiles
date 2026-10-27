#!/usr/bin/env bash
# live-clone-guard.sh - install a pre-commit hook that refuses every commit in a LIVE CLONE.
# A live clone is a checkout that only moves by fast-forward from its remote (a collector reads it, or install.sh
# symlinks from it); work happens in worktrees and goes through PRs. Model: the hand-written fleet-dash hook
# (rb-coder commit ea4fa96 landed in the live fleet-dash tree 10-23 02:27 and the deploy broke).
#
#   live-clone-guard.sh install <repo-path> [--env NAME]   write/refresh <repo>/.git/hooks/pre-commit (idempotent)
#   live-clone-guard.sh ensure                             install for every path in ${XDG_CONFIG_HOME:-$HOME/.config}/live-clone-guard/repos
#   live-clone-guard.sh check <repo-path>                  report pre-commit/post-merge/post-rewrite/post-checkout; exit 0 if all in place
#   live-clone-guard.sh --selftest
#
# A repo whose root has an executable install.sh that supports --link-only ("a pull IS an install") also gets post-merge,
# post-rewrite and post-checkout hooks that run `./install.sh --link-only` after the tree moves and append a line to
# ${XDG_STATE_HOME:-$HOME/.local/state}/live-clone-guard/postmerge.log. They never fail the git command. `git reset --hard`
# fires no hook (fleet-sync's install stamp covers it).
#
# Exit: install 3 = a foreign hook is present (left untouched). Per-repo line:
#   live-clone-guard: <path> installed|already|skipped-missing|refused-foreign-hook
# and one `live-clone-guard: <path> <hook> installed|already|refused-foreign-hook` line per post hook.
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
  COMMON_HOOKS="$common/hooks"
  # where git will actually run hooks from (core.hooksPath, local or global, wins over <common>/hooks)
  HOOKDIR=$(git -C "$LIVE" rev-parse --git-path hooks 2>/dev/null) || HOOKDIR="$COMMON_HOOKS"
  case "$HOOKDIR" in /*) ;; *) HOOKDIR="$LIVE/$HOOKDIR" ;; esac
  return 0
}

# supports_link_only <live>: the repo installs from itself and its install.sh knows --link-only
supports_link_only() { [ -x "$1/install.sh" ] && grep -q -- '--link-only' "$1/install.sh"; }

POST_HOOKS="post-merge post-rewrite post-checkout"

# render_post_hook <kind> <live-path>: kind-specific old/new discovery + the shared runner (templates are quoted heredocs,
# placeholders substituted, so no \$ escaping can drift)
render_post_hook() {
  local kind="$1" live="$2" head block tail
  read -r -d '' head <<'T' || true
#!/bin/bash
# live-clone-guard (installed by live-clone-guard.sh; do not edit, rerun 'live-clone-guard.sh install') - @KIND@
# @LIVE@ is a LIVE CLONE that installs from itself: when its tree moves, link what moved (a pull IS an install).
# Never fails the git command (exit 0 always). `git reset --hard` fires no hook; fleet-sync's install stamp covers that.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX; cd "$(git rev-parse --show-toplevel)" || exit 0
# hooks are shared by every worktree of this repo: only the live checkout itself installs
case "$(pwd -P)" in '@LIVE@') ;; *) exit 0 ;; esac
new=$(git rev-parse -q --verify HEAD 2>/dev/null) || exit 0
old=""; paths=0; extra=""
T
  case "$kind" in
    post-merge) read -r -d '' block <<'T' || true
extra="squash=${1:-0}"
old=$(git rev-parse -q --verify ORIG_HEAD 2>/dev/null) || old=$(git rev-parse -q --verify 'HEAD@{1}' 2>/dev/null) || old=""
# a stale ORIG_HEAD that is not an ancestor of the new HEAD cannot bound the diff: full link-only instead
[ -n "$old" ] && git merge-base --is-ancestor "$old" "$new" 2>/dev/null && paths=1
T
    ;;
    post-rewrite) read -r -d '' block <<'T' || true
cat >/dev/null 2>&1   # stdin (the rewritten-sha list) is ignored: always a full --link-only
extra="rewrite=${1:-}"
old=$(git rev-parse -q --verify ORIG_HEAD 2>/dev/null) || old=""
T
    ;;
    post-checkout) read -r -d '' block <<'T' || true
[ "${3:-}" = 1 ] || exit 0   # branch checkout only; a file checkout ($3 = 0) moves no tree
extra="checkout"
old=$(git rev-parse -q --verify "${1:-}^{commit}" 2>/dev/null) || old=""
[ -n "$old" ] && [ "${2:-}" != "" ] && paths=1
T
    ;;
  esac
  read -r -d '' tail <<'T' || true
[ "$old" = "$new" ] && paths=0
args=(); [ "$paths" = 1 ] && args=(--paths-from "$old" "$new")
[ -x ./install.sh ] && grep -q -- '--link-only' ./install.sh || exit 0
dry=(); [ "${LIVE_CLONE_GUARD_DRY:-}" = 1 ] && dry=(--dry-run)
out=$(./install.sh --link-only "${dry[@]}" "${args[@]}" 2>&1 </dev/null); rc=$?
n_linked=$(printf '%s\n' "$out" | grep -c '^linked:')
n_stale=$(printf '%s\n' "$out" | grep -c '^stale:')
n_conflict=$(printf '%s\n' "$out" | grep -c '^conflict:')
logdir="${XDG_STATE_HOME:-$HOME/.local/state}/live-clone-guard"; log="$logdir/postmerge.log"
if mkdir -p "$logdir" 2>/dev/null; then
  {
    if command -v flock >/dev/null 2>&1; then flock 9; fi
    printf '%s %s..%s rc=%s linked=%s stale=%s conflict=%s selftest=skipped hook=@KIND@ %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${old:0:12}" "${new:0:12}" "$rc" "$n_linked" "$n_stale" "$n_conflict" "$extra"
    printf '%s\n' "$out" | grep -E '^(stale|conflict):' | sed 's/^/  /'
  } 9>>"$log" >&9 2>/dev/null
fi
[ "$rc" = 0 ] || echo "live-clone-guard: install.sh --link-only exited rc=$rc in $(pwd -P) (see $log)" >&2
exit 0
T
  local all="$head
$block
$tail"
  all=${all//@KIND@/$kind}
  printf '%s\n' "${all//@LIVE@/$live}"
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

# install_post_hooks <repo-path>: for a repo that installs from itself (executable install.sh with --link-only) write
# post-merge/post-rewrite/post-checkout. Prints `live-clone-guard: <path> <hook> <status>` per hook; returns 3 if any is foreign.
install_post_hooks() {
  local p="$1" hk hook worst=0 st new
  repo_info "$p" || return 1
  supports_link_only "$LIVE" || return 0
  for hk in $POST_HOOKS; do
    hook="$HOOKDIR/$hk"
    if [ -e "$hook" ] && ! is_ours "$hook"; then
      echo "live-clone-guard: foreign $hk hook, not overwritten: $hook" >&2
      echo "live-clone-guard: $p $hk refused-foreign-hook"
      worst=3; continue
    fi
    new=$(render_post_hook "$hk" "$LIVE"; echo x)
    if [ -f "$hook" ] && [ "$(cat "$hook"; echo x)" = "$new" ] && [ -x "$hook" ]; then
      st=already
    else
      mkdir -p "$HOOKDIR"
      render_post_hook "$hk" "$LIVE" > "$hook.tmp.$$" && chmod 755 "$hook.tmp.$$" && mv -f "$hook.tmp.$$" "$hook" || { rm -f "$hook.tmp.$$"; die "cannot write $hook"; }
      st=installed
    fi
    echo "live-clone-guard: $p $hk $st"
  done
  return $worst
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
  install_post_hooks "$path" || [ $rc -ne 0 ] || rc=3
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
    [ $rc -eq 1 ] || install_post_hooks "$p" || worst=3
  done < "$cfg"
  return $worst
}

# check <repo-path>: one line per hook (ok | missing | foreign | n/a), RED when core.hooksPath resolves away from
# <common>/hooks. Exit 0 only when every applicable hook is ours + executable and no RED.
cmd_check() {
  [ $# -eq 1 ] || die "usage: check <repo-path>"
  repo_info "$1" || return 1
  local bad=0 hk hook st want_post=0 hp hpd
  supports_link_only "$LIVE" && want_post=1
  for hk in pre-commit $POST_HOOKS; do
    hook="$HOOKDIR/$hk"
    if [ "$hk" != pre-commit ] && [ $want_post -eq 0 ]; then st=n/a
    elif [ ! -e "$hook" ]; then st=missing; bad=1
    elif ! is_ours "$hook"; then st=foreign; bad=1
    elif [ ! -x "$hook" ]; then st=not-executable; bad=1
    else st=ok; fi
    echo "live-clone-guard: $LIVE $hk $st"
  done
  if hp=$(git -C "$LIVE" config --get core.hooksPath 2>/dev/null) && [ -n "$hp" ]; then
    hpd=$(cd "$LIVE" 2>/dev/null && cd "$hp" 2>/dev/null && pwd -P) || hpd="$hp"
    if [ "$hpd" != "$(cd "$COMMON_HOOKS" 2>/dev/null && pwd -P || echo "$COMMON_HOOKS")" ]; then
      echo "live-clone-guard: $LIVE RED core.hooksPath=$hp resolves to $hpd, not $COMMON_HOOKS"
      bad=1
    fi
  fi
  return $bad
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

  "$self" check "$live" >/dev/null && ok "check: installed -> 0" || bad "check installed"
  "$self" check "$foreign" >/dev/null && bad "check foreign should be 1" || ok "check: foreign hook -> 1"
  mk "$t/plain"; "$self" check "$t/plain" >/dev/null && bad "check plain should be 1" || ok "check: no hook -> 1"

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
