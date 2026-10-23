#!/usr/bin/env bash
# r7-run-coder.sh <name> <prompt-file>: one sonnet `claude -p` coder turn for the r7 seat, under a systemd-run unit
# (premise + expiry in the unit Description/RuntimeMaxSec). Rings the seat when the turn ends. Installed as ~/.cache/r7-seat/coders/run-coder.sh.
# v2 10-23 1:18 PM (row d-20261023-131752-r7-1804): removes the coder's own clone dirs /tmp/<name>.XXXXXX and /tmp/<name>.root when no
#   process has its cwd inside (carbon /tmp is tmpfs = RAM).
# v3 10-23 1:48 PM (row d-20261023-134850-r7-7c28, ctl df62 five whys): every git commit/push the coder makes runs
#   .local/share/r7-git-hooks/{commit-msg,pre-push} (strip / refuse Co-Authored-By and "Generated with Claude" lines) via env-level
#   core.hooksPath (GIT_CONFIG_COUNT outranks repo config and survives the coder's own HOME change).
# v4 10-23 (ctl 1:34 PM fdc8): the reap runs from an EXIT trap for EVERY rc (a failed or killed coder leaked /tmp, d392/h2b class);
#   TERM/INT/HUP exit through the same trap; the no-live-process guard stays. Versioned in dotfiles (unversioned = drift).
#   `r7-run-coder.sh --selftest` tests the reaper, the trap on rc!=0 and on SIGTERM, and both hooks, all on mktemp roots.
set -uo pipefail
self="$(readlink -f "${BASH_SOURCE[0]}")"; HOOKS="$(cd "$(dirname "$self")/../share/r7-git-hooks" 2>/dev/null && pwd)"
reap() { # $1 root (/tmp in prod), $2 name; prints what it removed or kept
  local root="$1" nm="$2" d busy c
  for d in "$root/$nm".??????  "$root/$nm.root"; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in "$nm".root|"$nm".[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) continue ;; esac
    busy=0; while IFS= read -r c; do case "$c/" in "$d"/*) busy=1; break ;; esac; done < <(find /proc -mindepth 2 -maxdepth 2 -name cwd -printf '%l\n' 2>/dev/null)
    if [ $busy = 1 ]; then echo "kept-busy $d"; else rm -rf -- "$d" && echo "reaped $d"; fi
  done; }
hooktest() { # commit-msg strips, pre-push refuses a cherry-picked trailer and passes a clean push; throwaway repos only
  local T r1=0 r2=0 c b old; T=$(mktemp -d)
  ( set -e; cd "$T"; git init -q --bare b.git; git init -q r; cd r; export HOME="$T/h" GIT_CONFIG_NOSYSTEM=1; G="git -c user.email=t@t -c user.name=t"
    $G commit -q --allow-empty -m init; git remote add o ../b.git; git push -q o HEAD:refs/heads/m 2>/dev/null
    $G commit -q --allow-empty -m "$(printf 'old\n\nCo-Authored-By: X <x@x>')"; old=$(git rev-parse HEAD); git reset -q --hard HEAD~1
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS" R7_GIT_HOOK_LOG="$T/strip.log"
    $G commit -q --allow-empty -m "$(printf 'fix: x\n\nbody\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n🤖 Generated with [Claude Code](https://claude.com/claude-code)')" 2>/dev/null
    c=$(git log -1 --format=%B | grep -ciE 'co-authored-by|generated with' || true); b=$(git log -1 --format=%B | grep -c '^body$')
    [ "$c" = 0 ] && [ "$b" = 1 ] && git push -q o HEAD:refs/heads/m 2>/dev/null || exit 11
    $G cherry-pick --allow-empty "$old" >/dev/null 2>&1; if git push -q o HEAD:refs/heads/m 2>/dev/null; then exit 12; fi
    git reset -q --hard HEAD~1; $G commit -q --allow-empty -m clean 2>/dev/null; git push -q o HEAD:refs/heads/m 2>/dev/null || exit 13 ); r1=$?
  rm -rf -- "$T"; [ $r1 = 0 ] && echo "PASS hooks (commit-msg strip; pre-push refused cherry-picked trailer, clean pushed)" || echo "FAIL hooks step=$r1"; return $r1; }
if [ "${1:-}" = --selftest ]; then
  ok=1; T=$(mktemp -d); mkdir -p "$T/cx.AbC123/s" "$T/cx.root" "$T/cx.toolongname/x" "$T/cxy.AbC123" "$T/cx.Busy12"
  ( cd "$T/cx.Busy12" && sleep 20 ) & sp=$!; sleep 0.3
  out=$(reap "$T" cx); kill $sp 2>/dev/null; wait $sp 2>/dev/null
  [ ! -e "$T/cx.AbC123" ] && [ ! -e "$T/cx.root" ] && [ -d "$T/cx.toolongname" ] && [ -d "$T/cxy.AbC123" ] && [ -d "$T/cx.Busy12" ] || ok=0
  grep -q "kept-busy $T/cx.Busy12" <<<"$out" || ok=0
  # trap path: a fake turn that fails (rc 3) and one killed by SIGTERM both reap their clone
  for mode in fail term; do mkdir -p "$T/ct$mode.Xy12Ab/s"
    R7_RUN_CODER_FAKE="$mode" R7_RUN_CODER_TMP="$T" R7_RUN_CODER_DIR="$T" R7_RUN_CODER_NOEVENT=1 "$self" "ct$mode" /dev/null >/dev/null 2>&1 & fp=$!
    [ $mode = term ] && { sleep 1; kill -TERM $fp; }; wait $fp 2>/dev/null
    [ ! -e "$T/ct$mode.Xy12Ab" ] || { ok=0; echo "FAIL trap $mode kept clone"; }; done
  rm -rf -- "$T"; hooktest || ok=0
  [ $ok = 1 ] && { echo SELFTEST OK; exit 0; }; echo "SELFTEST FAIL: $out"; exit 1
fi
n="$1"; pf="$2"; D="${R7_RUN_CODER_DIR:-$HOME/.cache/r7-seat/coders}"; TMPROOT="${R7_RUN_CODER_TMP:-/tmp}"; rc=1
finish() { trap - EXIT TERM INT HUP; local cl; cl="$(reap "$TMPROOT" "$n" | tr '\n' ' ')"
  [ -n "${R7_RUN_CODER_NOEVENT:-}" ] || EVENT_SOURCE="r7-coder-$n" timeout 30 "$HOME/.local/bin/seat-event.sh" r7 "R7-CODER $n ended rc=$rc report=$D/$n.report.md tmp: ${cl:-none}" || true
  exit $rc; }
stop() { rc=$1; [ -n "${cp:-}" ] && { kill -TERM "$cp" 2>/dev/null; sleep 2; kill -KILL "$cp" 2>/dev/null; }; exit "$rc"; }
trap finish EXIT; trap 'stop 143' TERM; trap 'stop 130' INT; trap 'stop 129' HUP
if [ -n "${R7_RUN_CODER_FAKE:-}" ]; then [ "$R7_RUN_CODER_FAKE" = term ] && { ( cd "$TMPROOT/$n".??????/s && sleep 30 ) & cp=$!; wait $cp; }; rc=3; exit 3; fi
# 10-22 9:17 PM: a relative prompt path resolved against the unit's cwd and launched claude with an empty prompt (cls-fix rc=1); a bare name resolves under $D.
case "$pf" in /*) ;; */*) echo "r7-run-coder.sh: prompt path must be absolute or a bare name under $D: $pf" >&2; rc=2; exit 2 ;; *) pf="$D/$pf" ;; esac
[ -s "$pf" ] || { echo "r7-run-coder.sh: prompt file missing or empty: $pf" >&2; rc=2; exit 2; }
[ -x "$HOOKS/commit-msg" ] && [ -x "$HOOKS/pre-push" ] || { echo "r7-run-coder.sh: git hooks missing under $HOOKS" >&2; rc=2; exit 2; }
set -a; . "$HOME/.config/environment.d/90-claude-oauth.conf"; set +a
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" WM_SEAT=r7-coder CLAUDE_SESSION_NAME="r7-coder-$n"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS" R7_GIT_HOOK_LOG="$HOME/.local/state/r7-git-hooks-strip.log"
cd "$HOME"
claude -p --dangerously-skip-permissions --model sonnet "$(cat "$pf")" > "$D/$n.out" 2> "$D/$n.err" & cp=$!
wait $cp; rc=$?
