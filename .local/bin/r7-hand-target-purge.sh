#!/usr/bin/env bash
# r7-hand-target-purge.sh -- ryzen7 only. Every 30 min (r7-hand-target-purge.timer): when the filesystem holding ~/hand is >= 85 % used,
# delete idle cargo target caches ~/hand/<name>/target, oldest first, until it is < 80 %. Spec: r7 seat hand-target-purge.spec.md v2 + Fable changes (6:25 AM 10-23).
# PREMISE: ryzen7 ~/hand filesystem use >= 85 % (df --output=pcent "$HOME/hand"); EXPIRES 2026-11-06 (past it: disarmed, state still written, nothing deleted).
# Shared libs (used, not re-implemented): r7-watch-lib.sh (r7_wp_arm / r7_wp_line) -> watcher-premise.sh (wp_arm / wp_gate / wp_emit_write).
#
# A candidate is deleted only if EVERY check passes, re-run right before the rename; ANY check that errors keeps the dir (`kept <dir> check-failed:<which>`):
#   containment   realpath of ~/hand/<name> and its target both under realpath(~/hand), parent a direct child, no symlink anywhere (symlink target ->
#                 `symlink`, symlinked parent -> `refused:symlinked-parent`), never under ~/.local/state/wm-build/wt or /mnt/ssd
#   recent-write  nothing under target modified in the last 48 h (find -newermt)
#   in-use        fuser -s on the dir and its parent; /proc/*/cwd or cmdline naming the parent; /proc/*/fd open on a file under target;
#                 a live MemGate slot in `wm-build builder cargo-jobs list`; flock -n on every target/**/.cargo-lock (cargo holds it for the whole
#                 build; the flocks stay held across the rename)
# Delete = atomic `mv target target.purging.<ts>` then `rm -rf --one-file-system`. SIGTERM / RuntimeMaxSec mid-rm is harmless: the renamed dir is not a
# cargo target, and the next armed tick sweeps any *.purging.* left behind. The source tree beside target is never touched.
# Log (stdout -> journal): `premise false (<pct>%)` | `disarmed (...)` | `purged <dir> <GB> idle=<h>h` | `kept <dir> <reason>` | `swept <dir>` |
#   `r7-hand-target-purge: <before>% -> <after>%, purged N (<GB> G)`. State: ~/.local/state/r7-hand-target-purge/last.json, written on EVERY run
#   (premise false, expired, host-gated runs excepted) so "quiet" differs from "dead": {ts, armed, premise, pct, before, after, stuck, interrupted, error, purged[], kept[]}.
#   stuck:true = premise true and nothing qualified (fleet-dash reads it; this unit rings no bell).
# Guards: host must be ryzen7 and not root (else one log line, exit 0); single instance via flock on <state>/lock.
# Env for the wm-build call comes from the unit (Environment=PATH, EnvironmentFile=environment.d/*.conf); a hand run without the fleet token fails
# closed (check-failed:cargo-jobs) -- run it as `systemctl --user start r7-hand-target-purge.service`, or `--idle-h 12` by hand only with a decision row.
# Test hooks (refused with exit 2 when $INVOCATION_ID is set, i.e. under systemd): --root DIR, --candidate PATH, and env R7_PURGE_ROOT / _PROC / _NOW /
#   _HOSTNAME / _UID / _HIGH / _LOW / _EXPIRES / _SSD. df, fuser and wm-build are called unqualified so --selftest can put stubs first on PATH.
#   --selftest builds everything in its own mktemp -d and never touches a real path.
set -u
NAME=r7-hand-target-purge
SELF=$(readlink -f "$0")
HERE=$(dirname "$SELF")
export PATH="$PATH:$HOME/.cargo/bin:$HOME/.local/bin:/usr/bin:/bin"

IDLE_H=48
MODE=run; ROOT_ARG=; CANDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE=selftest ;;
    --idle-h) IDLE_H=${2:-}; shift ;;
    --root) ROOT_ARG=${2:-}; shift ;;
    --candidate) CANDS+=("${2:-}"); shift ;;
    *) echo "usage: $NAME.sh [--idle-h N] | --selftest   (test-only: --root DIR --candidate PATH)" >&2; exit 64 ;;
  esac
  shift
done
case "$IDLE_H" in ''|*[!0-9]*|0) echo "$NAME: --idle-h needs a positive integer" >&2; exit 64 ;; esac

# ---------------------------------------------------------------------------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------------------------------------------------------------------------
run_selftest() {
  local pass=0 fail=0 NOWS C OUT RC FUT=2099-01-01T00:00:00Z
  T=
  T=$(mktemp -d "${TMPDIR:-/tmp}/$NAME-selftest.XXXXXX") || { echo "selftest FAILED: no mktemp"; return 1; }
  trap '[ -n "${T:-}" ] && rm -rf "$T"' EXIT
  NOWS=$(date +%s)
  mkdir -p "$T/bin"
  cat > "$T/bin/df" <<'EOF'
#!/bin/bash
echo "$*" >> "$R7_PURGE_ROOT/df.args"
[ -n "${STUB_DF_FAIL:-}" ] && exit 1
n=$(find "$R7_PURGE_ROOT/hand" -mindepth 2 -maxdepth 2 -name target -type d | wc -l)
p=$(( STUB_DF_START - STUB_DF_STEP * (STUB_DF_N0 - n) ))
printf 'Use%%\n %s%%\n' "$p"
EOF
  cat > "$T/bin/fuser" <<'EOF'
#!/bin/bash
[ -n "${STUB_FUSER_ERR:-}" ] && exit 2
last=${*: -1}
[ -f "${STUB_FUSER_HELD:-/nonexistent}" ] && grep -qxF -- "$last" "$STUB_FUSER_HELD" && exit 0
exit 1
EOF
  cat > "$T/bin/wm-build" <<'EOF'
#!/bin/bash
[ "$1 $2 $3" = "builder cargo-jobs list" ] || exit 64
[ -n "${STUB_WMB_ERR:-}" ] && { echo boom >&2; exit 1; }
if [ -n "${STUB_WMB_SLEEP:-}" ]; then echo $$ > "$STUB_WMB_SLEEP"; exec sleep 30; fi
[ -f "${STUB_WMB_OUT:-/nonexistent}" ] && cat "$STUB_WMB_OUT"
exit 0
EOF
  chmod +x "$T/bin/df" "$T/bin/fuser" "$T/bin/wm-build"

  ok() { pass=$((pass+1)); echo "ok   $1"; }
  bad() { fail=$((fail+1)); echo "FAIL $1: $2"; echo "---- output:"; printf '%s\n' "$OUT" | head -n 30; echo "----"; }
  expect() { # name cond-description  (rest = test command)
    local n=$1; shift; if "$@"; then ok "$n"; else bad "$n" "condition failed: $*"; fi
  }
  has() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
  hasnt() { ! printf '%s\n' "$OUT" | grep -qE -- "$1"; }
  jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$C/.local/state/$NAME/last.json" "$1" 2>&1; }

  mkcase() { # name -> $C, empty hand/, proc/
    C=$T/$1; rm -rf "$C"; mkdir -p "$C/hand" "$C/proc/1"; ln -s "$C" "$C/proc/1/cwd"   # pid 1 stands in so the proc scan has something to read
  }
  mkt() { # parent-name age-hours [lockfile]: hand/<n>/{src/main.rs,target/debug/...}; every file+dir under target aged AGE hours
    local d=$C/hand/$1
    mkdir -p "$d/src" "$d/target/debug/deps"
    echo 'fn main(){}' > "$d/src/main.rs"; head -c 4096 /dev/zero > "$d/target/debug/deps/lib.rlib"; : > "$d/target/debug/.cargo-lock"
    find "$d/target" -exec touch -d "@$((NOWS - $2 * 3600))" {} +
  }
  ntargets() { find "$C/hand" -mindepth 2 -maxdepth 2 -name target -type d | wc -l; }
  # runp START STEP [extra env VAR=val ...] -- [args]  -> OUT, RC. HOME and the root are the case dir; INVOCATION_ID dropped (test hooks are systemd-refused)
  runp() {
    local start=$1 step=$2; shift 2
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    [ "${1:-}" = -- ] && shift
    OUT=$(env -u INVOCATION_ID HOME="$C" PATH="$T/bin:$PATH" TMPDIR="$T" WP_DECIDE_BIN=none-no-such-wm-decide \
        R7_PURGE_HOSTNAME=ryzen7 R7_PURGE_UID=1000 R7_PURGE_PROC="$C/proc" R7_PURGE_NOW="$NOWS" R7_PURGE_EXPIRES="$FUT" \
        STUB_DF_START="$start" STUB_DF_STEP="$step" STUB_DF_N0="$(ntargets)" "${envs[@]}" \
        bash "$SELF" --root "$C" "$@" 2>&1); RC=$?
  }

  # (a) premise false: nothing deleted, last.json says so
  mkcase a; mkt p1 100; mkt p2 100; runp 70 12
  expect a-premise-false-log has 'premise false \(70%\)'
  expect a-premise-false-nothing-deleted test "$(ntargets)" = 2
  expect a-premise-false-no-purge-line hasnt '^purged '
  expect a-premise-false-last-json test "$(jget '(d["armed"],d["premise"],d["pct"],d["purged"])')" = "(True, False, 70, [])"
  expect a-df-asked-about-hand-only bash -c 'sort -u "$1/df.args" | grep -vqx -- "--output=pcent $1/hand" && exit 1; exit 0' _ "$C"

  # (b) three idle targets, df drops below 80 after the first deletion -> only the oldest goes, source stays
  mkcase b; mkt old 200; mkt mid 100; mkt new 60; runp 90 12
  expect b-oldest-deleted test ! -e "$C/hand/old/target"
  expect b-others-kept test -d "$C/hand/mid/target" -a -d "$C/hand/new/target"
  expect b-source-untouched test -f "$C/hand/old/src/main.rs"
  expect b-purged-line has "^purged $C/hand/old/target [0-9.]+ idle=200h"
  expect b-summary has '^r7-hand-target-purge: 90% -> 78%, purged 1 \('
  expect b-last-json test "$(jget '(len(d["purged"]),d["before"],d["after"],d["stuck"],d["purged"][0]["dir"].endswith("/old/target"))')" = "(1, 90, 78, False, True)"
  expect b-no-purging-leftover test -z "$(find "$C/hand" -name '*.purging.*')"
  # (b2) both go when one deletion is not enough
  mkcase b2; mkt old 200; mkt mid 100; mkt new 60; runp 92 5
  expect b2-hysteresis-continues test "$(ntargets)" = 0
  expect b2-stops-below-80 has '^r7-hand-target-purge: 92% -> 77%, purged 3 \('

  # (c) a 1-hour-old file keeps it
  mkcase c; mkt p1 100; touch -d "@$((NOWS - 3600))" "$C/hand/p1/target/debug/deps/lib.rlib"; runp 90 12
  expect c-recent-write-kept has "^kept $C/hand/p1/target recent-write"
  expect c-recent-write-present test -d "$C/hand/p1/target"
  expect c-stuck-flag test "$(jget 'd["stuck"]')" = True

  # (d) fuser-held target
  mkcase d; mkt p1 100; realpath -e "$C/hand/p1/target" > "$C/held"; runp 90 12 STUB_FUSER_HELD="$C/held"
  expect d-in-use-fuser has "^kept $C/hand/p1/target in-use"
  expect d-in-use-present test -d "$C/hand/p1/target"

  # (e) symlink target: skipped, never followed
  mkcase e; mkdir -p "$C/elsewhere/real/deps"; echo keep > "$C/elsewhere/real/deps/f"; mkdir -p "$C/hand/p1/src"; ln -s "$C/elsewhere/real" "$C/hand/p1/target"; runp 90 12
  expect e-symlink-kept has "^kept $C/hand/p1/target symlink"
  expect e-symlink-link-target-untouched test -f "$C/elsewhere/real/deps/f" -a -L "$C/hand/p1/target"

  # (f) a dir outside ~/hand is refused
  mkcase f; mkdir -p "$C/outside/proj/target/debug"; echo keep > "$C/outside/proj/target/debug/f"; touch -d "@$((NOWS - 999 * 3600))" "$C/outside/proj/target/debug/f" "$C/outside/proj/target/debug" "$C/outside/proj/target"
  runp 90 12 -- --candidate "$C/outside/proj/target"
  expect f-outside-refused has "^kept $C/outside/proj/target refused:outside-hand"
  expect f-outside-untouched test -f "$C/outside/proj/target/debug/f"
  # (f2) wt and /mnt/ssd stand-ins are protected even when they sit under realpath(~/hand) via the injected roots
  mkcase f2; mkdir -p "$C/ssd/wm-build-targets/x/target"; touch -d "@$((NOWS - 999 * 3600))" "$C/ssd/wm-build-targets/x/target"
  runp 90 12 R7_PURGE_SSD="$C/ssd" -- --candidate "$C/ssd/wm-build-targets/x/target"
  expect f2-ssd-refused has "^kept $C/ssd/wm-build-targets/x/target refused:outside-hand"

  # (g) expired -> no write, state still written
  mkcase g; mkt p1 100; runp 90 12 R7_PURGE_EXPIRES=2000-01-01T00:00:00Z
  expect g-expired-log has '^disarmed \(expired'
  expect g-expired-nothing-deleted test -d "$C/hand/p1/target"
  expect g-expired-last-json test "$(jget '(d["armed"],d["premise"],d["pct"],d["purged"])')" = "(False, True, 90, [])"

  # (h) a held .cargo-lock (flock) keeps it
  mkcase h; mkt p1 100; local lfd
  exec {lfd}>>"$C/hand/p1/target/debug/.cargo-lock"; flock -x "$lfd"
  runp 90 12
  exec {lfd}>&-
  expect h-flock-in-use has "^kept $C/hand/p1/target in-use"
  expect h-flock-present test -d "$C/hand/p1/target"
  # and once the lock is released the same dir is purged
  runp 90 12
  expect h-flock-released-purged test ! -e "$C/hand/p1/target"

  # (i) a check command that errors: kept check-failed, nothing deleted
  mkcase i; mkt p1 100; runp 90 12 STUB_WMB_ERR=1
  expect i-cargo-jobs-error has "^kept $C/hand/p1/target check-failed:cargo-jobs"
  expect i-cargo-jobs-error-nothing-deleted test -d "$C/hand/p1/target"
  mkcase i2; mkt p1 100; runp 90 12 STUB_FUSER_ERR=1
  expect i2-fuser-error has "^kept $C/hand/p1/target check-failed:fuser"
  expect i2-fuser-error-nothing-deleted test -d "$C/hand/p1/target"
  mkcase i3; mkt p1 100; runp 90 12 STUB_DF_FAIL=1
  expect i3-df-error has 'check-failed:df'
  expect i3-df-error-nothing-deleted test -d "$C/hand/p1/target"
  expect i3-df-error-last-json test "$(jget 'd["error"]')" = df
  mkcase i4; mkt p1 100; rm -rf "$C/proc"; runp 90 12
  expect i4-proc-missing has "^kept $C/hand/p1/target check-failed:proc"
  expect i4-proc-missing-nothing-deleted test -d "$C/hand/p1/target"

  # (j) symlinked parent (out of hand, and inside hand) refused
  mkcase j; mkdir -p "$C/elsewhere/proj/target/debug"; echo keep > "$C/elsewhere/proj/target/debug/f"
  touch -d "@$((NOWS - 999 * 3600))" "$C/elsewhere/proj/target/debug/f" "$C/elsewhere/proj/target/debug" "$C/elsewhere/proj/target"
  ln -s "$C/elsewhere/proj" "$C/hand/linkp"; mkt realq 100; ln -s "$C/hand/realq" "$C/hand/linkq"
  runp 90 12
  expect j-symlinked-parent-out has "^kept $C/hand/linkp/target refused:symlinked-parent"
  expect j-symlinked-parent-in has "^kept $C/hand/linkq/target refused:symlinked-parent"
  expect j-symlinked-parent-untouched test -f "$C/elsewhere/proj/target/debug/f"

  # (k) orphaned *.purging.* swept (armed + premise true), and not when premise is false
  mkcase k; mkdir -p "$C/hand/p1/src" "$C/hand/p1/target.purging.123/debug"; echo x > "$C/hand/p1/target.purging.123/debug/f"; runp 90 0
  expect k-orphan-swept test ! -e "$C/hand/p1/target.purging.123"
  expect k-orphan-swept-log has "^swept $C/hand/p1/target.purging.123"
  mkcase k2; mkdir -p "$C/hand/p1/target.purging.123"; runp 70 0
  expect k2-orphan-kept-when-premise-false test -d "$C/hand/p1/target.purging.123"

  # (l) in-use via a live MemGate slot, /proc cwd, /proc cmdline, /proc fd
  mkcase l; mkt p1 100; printf 'slot 1 role=gate dir=%s/hand/p1/wt\n' "$C" > "$C/jobs"; runp 90 12 STUB_WMB_OUT="$C/jobs"
  expect l-memgate-slot has "^kept $C/hand/p1/target in-use"
  mkcase l2; mkt p1 100; mkdir -p "$C/proc/4242"; ln -s "$C/hand/p1/target/debug" "$C/proc/4242/cwd"; runp 90 12
  expect l2-proc-cwd has "^kept $C/hand/p1/target in-use"
  mkcase l3; mkt p1 100; mkdir -p "$C/proc/4242"; printf 'cargo\0build\0--manifest-path\0%s/hand/p1/Cargo.toml\0' "$C" > "$C/proc/4242/cmdline"; runp 90 12
  expect l3-proc-cmdline has "^kept $C/hand/p1/target in-use"
  mkcase l4; mkt p1 100; mkdir -p "$C/proc/4242/fd"; ln -s "$C/hand/p1/target/debug/deps/lib.rlib" "$C/proc/4242/fd/7"; runp 90 12
  expect l4-proc-fd has "^kept $C/hand/p1/target in-use"
  expect l4-proc-fd-present test -d "$C/hand/p1/target"
  mkcase l5; mkt p1 100; mkt p10 200; mkdir -p "$C/proc/4242"; ln -s "$C/hand/p10" "$C/proc/4242/cwd"; runp 90 12
  expect l5-name-prefix-not-confused test ! -e "$C/hand/p1/target" -a -d "$C/hand/p10/target"

  # (m) host gate, root gate, test hooks refused under systemd, single instance
  mkcase m; mkt p1 100; runp 90 12 R7_PURGE_HOSTNAME=carbon
  expect m-host-gate has 'not ryzen7'
  expect m-host-gate-no-state test ! -e "$C/.local/state/$NAME"
  expect m-host-gate-present test -d "$C/hand/p1/target"
  runp 90 12 R7_PURGE_UID=0
  expect m-root-gate has 'running as root'
  expect m-root-gate-present test -d "$C/hand/p1/target"
  OUT=$(env INVOCATION_ID=abc HOME="$C" PATH="$T/bin:$PATH" bash "$SELF" --root "$C" 2>&1); RC=$?
  expect m-root-refused-under-systemd test "$RC" = 2
  OUT=$(env INVOCATION_ID=abc HOME="$C" PATH="$T/bin:$PATH" R7_PURGE_NOW=1 bash "$SELF" 2>&1); RC=$?
  expect m-env-hook-refused-under-systemd test "$RC" = 2
  expect m-refused-nothing-deleted test -d "$C/hand/p1/target"
  mkcase m2; mkt p1 100; mkdir -p "$C/.local/state/$NAME"; local sfd
  exec {sfd}>>"$C/.local/state/$NAME/lock"; flock -x "$sfd"
  runp 90 12
  exec {sfd}>&-
  expect m2-single-instance has 'another instance'
  expect m2-single-instance-present test -d "$C/hand/p1/target"

  # (n) SIGTERM mid-run: `interrupted` logged, last.json says so, nothing deleted
  mkcase n; mkt p1 100; local pidf=$C/stub.pid n_out=$C/n.out
  env -u INVOCATION_ID HOME="$C" PATH="$T/bin:$PATH" TMPDIR="$T" WP_DECIDE_BIN=none-no-such-wm-decide R7_PURGE_HOSTNAME=ryzen7 R7_PURGE_UID=1000 \
    R7_PURGE_PROC="$C/proc" R7_PURGE_NOW="$NOWS" R7_PURGE_EXPIRES="$FUT" STUB_DF_START=90 STUB_DF_STEP=12 STUB_DF_N0=1 STUB_WMB_SLEEP="$pidf" \
    bash "$SELF" --root "$C" > "$n_out" 2>&1 &
  local spid=$! w=0
  while [ ! -s "$pidf" ] && [ $w -lt 100 ]; do sleep 0.1; w=$((w+1)); done
  kill -TERM "$spid" 2>/dev/null; [ -s "$pidf" ] && kill -TERM "$(cat "$pidf")" 2>/dev/null
  wait "$spid" 2>/dev/null; RC=$?
  OUT=$(cat "$n_out")
  expect n-sigterm-logged has '^r7-hand-target-purge: interrupted'
  expect n-sigterm-last-json test "$(jget 'd["interrupted"]')" = True
  expect n-sigterm-present test -d "$C/hand/p1/target"

  # last.json is valid JSON on a real purge too, with kept entries
  mkcase o; mkt p1 100; mkt p2 3; runp 90 12
  expect o-last-json-kept-recorded test "$(jget '[k["reason"] for k in d["kept"]]')" = "['recent-write']"

  if [ "$fail" = 0 ]; then echo "selftest ok $pass/$((pass+fail))"; return 0; fi
  echo "selftest FAILED $fail/$((pass+fail))"; return 1
}

if [ "$MODE" = selftest ]; then run_selftest; exit $?; fi

# ---------------------------------------------------------------------------------------------------------------------------------------------
# real run
# ---------------------------------------------------------------------------------------------------------------------------------------------
if [ -n "${INVOCATION_ID:-}" ]; then
  for v in R7_PURGE_ROOT R7_PURGE_PROC R7_PURGE_NOW R7_PURGE_HOSTNAME R7_PURGE_UID R7_PURGE_HIGH R7_PURGE_LOW R7_PURGE_EXPIRES R7_PURGE_SSD; do
    if [ -n "${!v:-}" ]; then echo "$NAME: $v is a test hook, refused under systemd" >&2; exit 2; fi
  done
  if [ -n "$ROOT_ARG" ] || [ "${#CANDS[@]}" -gt 0 ]; then echo "$NAME: --root/--candidate are test hooks, refused under systemd" >&2; exit 2; fi
fi
[ -n "$ROOT_ARG" ] && R7_PURGE_ROOT=$ROOT_ARG
ROOT=${R7_PURGE_ROOT:-$HOME}
HAND=$ROOT/hand
STATE=$ROOT/.local/state/$NAME
WTDIR=$ROOT/.local/state/wm-build/wt
SSD=${R7_PURGE_SSD:-/mnt/ssd}
PROC=${R7_PURGE_PROC:-/proc}
NOW=${R7_PURGE_NOW:-$(date +%s)}
HIGH=${R7_PURGE_HIGH:-85}
LOW=${R7_PURGE_LOW:-80}
export R7_PURGE_ROOT=$ROOT R7_PURGE_HIGH=$HIGH

# host gate (before any state write)
HOSTN=${R7_PURGE_HOSTNAME:-$(hostname -s 2>/dev/null)}
if [ "$HOSTN" != ryzen7 ]; then echo "$NAME: host is '${HOSTN:-?}', not ryzen7; nothing to do"; exit 0; fi
if [ "${R7_PURGE_UID:-$(id -u)}" = 0 ]; then echo "$NAME: running as root; refusing"; exit 0; fi

mkdir -p "$STATE" || { echo "$NAME: cannot create $STATE"; exit 1; }
exec 9>"$STATE/lock"
flock -n 9 || { echo "$NAME: another instance holds $STATE/lock; exiting"; exit 0; }

# ---- state / log helpers
PURGED_J=(); KEPT_J=(); NPURGED=0; GB_TOTAL=0
ARMED=false; PREM=null; PCT=; BEFORE=; AFTER=; STUCK=false; INTERRUPTED=false; ERROR=
log() { printf '%s\n' "$*"; }
jesc() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}
num() { case "${1:-}" in ''|*[!0-9]*) printf null ;; *) printf '%s' "$1" ;; esac; }
kept() { log "kept $1 $2"; KEPT_J+=("{\"dir\":\"$(jesc "$1")\",\"reason\":\"$(jesc "$2")\"}"); }
write_last() {
  local tmp=$STATE/.last.json.$$ pj kj err=null
  pj=$(IFS=,; printf '%s' "${PURGED_J[*]-}"); kj=$(IFS=,; printf '%s' "${KEPT_J[*]-}")
  [ -n "$ERROR" ] && err="\"$(jesc "$ERROR")\""
  printf '{"ts":"%s","armed":%s,"premise":%s,"pct":%s,"before":%s,"after":%s,"stuck":%s,"interrupted":%s,"error":%s,"purged":[%s],"kept":[%s]}\n' \
    "$(date -d "@$NOW" -Is)" "$ARMED" "$PREM" "$(num "$PCT")" "$(num "$BEFORE")" "$(num "$AFTER")" "$STUCK" "$INTERRUPTED" "$err" "$pj" "$kj" > "$tmp" \
    && mv -f "$tmp" "$STATE/last.json" || { rm -f "$tmp"; log "$NAME: last.json write failed"; }
}
on_term() { log "$NAME: interrupted"; INTERRUPTED=true; write_last; exit 143; }
trap on_term TERM INT HUP

df_pct() {
  local out p
  out=$(df --output=pcent "$HAND" 2>/dev/null) || return 1
  p=$(printf '%s\n' "$out" | sed -n 2p | tr -dc '0-9')
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

# ---- libs: r7-watch-lib (-> watcher-premise.sh). PREMISE + EXPIRES come from them; WP_LIB sits at ../lib of this script (repo and ~/.local layouts agree).
export WP_LIB=${WP_LIB:-$HERE/../lib/watcher-premise.sh} WP_GATE_TTL=0
export R7_EXPIRES=${R7_PURGE_EXPIRES:-2026-11-06T23:59:59-08:00}
PREMISE_TEXT="ryzen7 ~/hand filesystem use >= $HIGH % (df); only idle ~/hand/*/target is deleted"
PREMISE_CMD='p=$(df --output=pcent "$R7_PURGE_ROOT/hand" 2>/dev/null | sed -n 2p | tr -dc 0-9); [ -n "$p" ] || exit 2; [ "$p" -ge "$R7_PURGE_HIGH" ]'
if [ -r "$HERE/r7-watch-lib.sh" ]; then . "$HERE/r7-watch-lib.sh"; fi
[ -r "$WP_LIB" ] && . "$WP_LIB"
if declare -F r7_wp_arm >/dev/null; then
  r7_wp_arm "$NAME" "$PREMISE_TEXT" "$PREMISE_CMD"; r7_wp_line; GATE_RC=$?
else
  echo "WP-MISSING $NAME: r7-watch-lib.sh not sourced, writes disarmed"; GATE_RC=1; WP_DEFECT=lib-missing; WP_VERDICT=UNKNOWN
fi

if [ ! -d "$HAND" ]; then log "$NAME: no hand dir ($HAND)"; ERROR=no-hand-dir; write_last; exit 0; fi
if ! PCT=$(df_pct); then log "check-failed:df"; PCT=; ERROR=df; write_last; exit 0; fi
BEFORE=$PCT
[ "$PCT" -ge "$HIGH" ] && PREM=true || PREM=false

if [ "${WP_DEFECT:--}" = expired ]; then log "disarmed (expired $R7_EXPIRES)"; write_last; exit 0; fi
if [ "${WP_DEFECT:--}" = misconfigured ] || [ "${WP_DEFECT:--}" = lib-missing ]; then log "disarmed (${WP_DEFECT})"; ERROR=${WP_DEFECT}; write_last; exit 0; fi
if [ "${WP_VERDICT:-}" = GONE ] || [ "$PREM" = false ]; then log "premise false (${PCT}%)"; ARMED=true; write_last; exit 0; fi
if [ "${WP_VERDICT:-}" != HOLDS ] || [ "$GATE_RC" != 0 ]; then log "check-failed:premise (verdict=${WP_VERDICT:-?})"; ERROR=premise; write_last; exit 0; fi
ARMED=true

# ---- containment + checks (each sets REASON and returns 1 on refusal / failure)
REASON=; RP=; RT=
HR=$(realpath -e -- "$HAND" 2>/dev/null) || { log "check-failed:realpath $HAND"; ERROR=realpath; write_last; exit 0; }
WTR=$(realpath -m -- "$WTDIR" 2>/dev/null || echo "$WTDIR"); SSDR=$(realpath -m -- "$SSD" 2>/dev/null || echo "$SSD")

contain() { # $1 = the dir to delete (target, or an orphan target.purging.*)
  local t=$1 parent base
  parent=${t%/*}; base=${t##*/}
  if [ -L "$t" ]; then REASON=symlink; return 1; fi
  if [ -L "$parent" ]; then REASON=refused:symlinked-parent; return 1; fi
  [ -d "$t" ] || { REASON=not-a-dir; return 1; }
  RP=$(realpath -e -- "$parent" 2>/dev/null) && RT=$(realpath -e -- "$t" 2>/dev/null) || { REASON=check-failed:realpath; return 1; }
  case "$RP/" in "$HR"/*) ;; *) REASON=refused:outside-hand; return 1 ;; esac
  case "$RT/" in "$HR"/*) ;; *) REASON=refused:outside-hand; return 1 ;; esac
  [ "${RP%/*}" = "$HR" ] || { REASON=refused:outside-hand; return 1; }
  [ "$RP" = "$HR/${parent##*/}" ] && [ "$RT" = "$RP/$base" ] || { REASON=refused:symlinked-parent; return 1; }
  case "$RT/" in "$WTR"/*|"$SSDR"/*) REASON=refused:protected; return 1 ;; esac
  case "$RP/" in "$WTR"/*|"$SSDR"/*) REASON=refused:protected; return 1 ;; esac
  return 0
}

check_recent() { # $1 = target; recent-write if anything under it changed within IDLE_H hours
  local out rc
  out=$(find "$1" -newermt "@$((NOW - IDLE_H * 3600))" -print -quit 2>/dev/null); rc=$?
  if [ -n "$out" ]; then REASON=recent-write; return 1; fi
  [ "$rc" = 0 ] || { REASON=check-failed:find; return 1; }
  return 0
}

newest_mtime() { # $1 = target -> NEWEST (epoch s)
  NEWEST=$( set -o pipefail; find "$1" -printf '%T@\n' 2>/dev/null | awk 'BEGIN{m=0} {if ($1+0>m) m=$1+0} END{printf "%.0f\n", m}' ) || { REASON=check-failed:find; return 1; }
  case "$NEWEST" in ''|*[!0-9]*) REASON=check-failed:find; return 1 ;; esac
}

names_parent() { # stdin tokens; 0 if any token is $RP or under it
  local tok
  while IFS= read -r tok; do case "$tok" in "$RP"|"$RP"/*) return 0 ;; esac; done
  return 1
}

check_in_use() {
  local rc d c arg hit esc out tokens
  [ -d "$PROC" ] && compgen -G "$PROC/[0-9]*" >/dev/null || { REASON=check-failed:proc; return 1; }
  command -v fuser >/dev/null 2>&1 || { REASON=check-failed:fuser; return 1; }
  for d in "$RT" "$RP"; do
    fuser -s -- "$d" >/dev/null 2>&1; rc=$?
    case $rc in 0) REASON=in-use:fuser; return 1 ;; 1) ;; *) REASON=check-failed:fuser; return 1 ;; esac
  done
  for d in "$PROC"/[0-9]*; do
    [ -d "$d" ] || continue
    [ "${d##*/}" = "$$" ] && continue
    c=$(readlink "$d/cwd" 2>/dev/null)
    case "$c" in "$RP"|"$RP"/*) REASON=in-use:proc-cwd; return 1 ;; esac
    if [ -r "$d/cmdline" ]; then
      while IFS= read -r -d '' arg || [ -n "$arg" ]; do
        case "$arg" in *"$RP"/*|*"$RP") REASON=in-use:proc-cmdline; return 1 ;; esac
      done < "$d/cmdline"
    fi
  done
  esc=$(printf '%s' "$RT" | sed 's/[][*?\\]/\\&/g')
  hit=$(find "$PROC"/[0-9]*/fd -maxdepth 1 \( -lname "$esc" -o -lname "$esc/*" \) -print -quit 2>/dev/null)
  if [ -n "$hit" ]; then REASON=in-use:proc-fd; return 1; fi
  command -v wm-build >/dev/null 2>&1 || { REASON=check-failed:cargo-jobs; return 1; }
  out=$(timeout 30 wm-build builder cargo-jobs list 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || { REASON=check-failed:cargo-jobs; return 1; }
  tokens=$(printf '%s\n' "$out" | tr -s ' \t",;:=[]{}()' '\n')
  if printf '%s\n' "$tokens" | names_parent; then REASON=in-use:memgate; return 1; fi
  return 0
}

LOCKFDS=()
release_locks() { local fd; for fd in "${LOCKFDS[@]-}"; do [ -n "$fd" ] && exec {fd}<&-; done; LOCKFDS=(); }
probe_locks() { # flock -n every target/**/.cargo-lock; the fds stay open (held) until release_locks
  local f fd rc found
  found=$(find "$RT" -maxdepth 3 -name .cargo-lock -type f 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || { REASON=check-failed:flock; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    exec {fd}<"$f" || { release_locks; REASON=check-failed:flock; return 1; }
    flock -n -E 99 "$fd"; rc=$?
    case $rc in
      0) LOCKFDS+=("$fd") ;;
      99) exec {fd}<&-; release_locks; REASON=in-use:flock; return 1 ;;
      *) exec {fd}<&-; release_locks; REASON=check-failed:flock; return 1 ;;
    esac
  done <<<"$found"
  return 0
}

precheck() { # all checks for one candidate, right before the rename; rc 0 = deletable (locks held)
  contain "$1" || return 1
  check_recent "$RT" || return 1
  check_in_use || return 1
  probe_locks || return 1
  return 0
}

# ---- sweep orphans from an interrupted tick, then pick candidates
sweep() {
  local o
  for o in "$HAND"/*/target.purging.*; do
    [ -e "$o" ] || [ -L "$o" ] || continue
    if contain "$o"; then
      if rm -rf --one-file-system -- "$o"; then log "swept $o"; else kept "$o" sweep-failed; fi
    else
      kept "$o" "$REASON"
    fi
  done
}
sweep
cur=$(df_pct) || { kept "$HAND" check-failed:df; ERROR=df; write_last; exit 0; }
PCT=$cur

declare -A SEEN=(); ELIG=()
if [ "$PCT" -ge "$LOW" ]; then
  for t in "$HAND"/*/target "${CANDS[@]-}"; do
    [ -n "$t" ] || continue
    [ -e "$t" ] || [ -L "$t" ] || continue
    [ -n "${SEEN[$t]:-}" ] && continue; SEEN[$t]=1
    if ! contain "$t"; then kept "$t" "$REASON"; continue; fi
    if ! newest_mtime "$t"; then kept "$t" "$REASON"; continue; fi
    if [ $((NOW - NEWEST)) -lt $((IDLE_H * 3600)) ]; then kept "$t" recent-write; continue; fi
    ELIG+=("$NEWEST"$'\t'"$t")
  done
fi

if [ "${#ELIG[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r nw t; do
    cur=$(df_pct) || { kept "$t" check-failed:df; break; }
    if [ "$cur" -lt "$LOW" ]; then log "stop: ${cur}% < ${LOW}%"; break; fi
    if [ "$(date +%s)" -gt "${WP_EXPIRES_EPOCH:-0}" ]; then log "disarmed (expired $R7_EXPIRES) mid-run"; break; fi
    if ! precheck "$t"; then kept "$t" "$REASON"; continue; fi
    dst=$RT.purging.$NOW
    if [ -e "$dst" ] || [ -L "$dst" ]; then release_locks; kept "$t" "check-failed:purging-name-taken"; continue; fi
    # outbox row first (watcher-premise write protocol); a failed append blocks this delete
    if declare -F wp_emit_write >/dev/null && ! wp_emit_write purge "$RT" "rm -rf --one-file-system $RT (renamed to $dst first)" \
        "premise ${PCT}% >= ${HIGH}%, idle>=${IDLE_H}h, no in-use signal" "none; hand cargo target cache, rebuilt on demand"; then
      release_locks; kept "$t" check-failed:outbox; continue
    fi
    if ! mv -T -- "$RT" "$dst"; then release_locks; kept "$t" check-failed:rename; continue; fi
    release_locks
    gb=$(du -sb --one-file-system -- "$dst" 2>/dev/null | awk '{printf "%.1f", $1/1073741824}')
    rm -rf --one-file-system -- "$dst"
    if [ -e "$dst" ]; then kept "$t" "purge-incomplete (swept next tick)"; continue; fi
    idle=$(( (NOW - nw) / 3600 ))
    log "purged $t ${gb:-?} idle=${idle}h"
    PURGED_J+=("{\"dir\":\"$(jesc "$t")\",\"gb\":${gb:-null},\"idle_h\":$idle}")
    NPURGED=$((NPURGED + 1)); GB_TOTAL=$(awk -v a="$GB_TOTAL" -v b="${gb:-0}" 'BEGIN{printf "%.1f", a+b}')
  done < <(printf '%s\n' "${ELIG[@]}" | sort -n -t $'\t' -k1,1)
fi

AFTER=$(df_pct) || AFTER=
[ -n "$AFTER" ] && PCT=$AFTER
if [ "$NPURGED" = 0 ] && [ "$BEFORE" -ge "$HIGH" ]; then STUCK=true; log "STUCK: premise true (${BEFORE}%) and nothing qualified"; fi
log "$NAME: ${BEFORE}% -> ${AFTER:-?}%, purged $NPURGED (${GB_TOTAL} G)"
write_last
exit 0
