#!/usr/bin/env bash
# rb-redrive.test.sh - rb-redrive.sh --selftest runs hermetically: AC2 (rc 0 + SELFTEST PASS), AC3 (fake ssh / wm-decide / wm-build
# on PATH, each logs argv and exits 99; all three logs stay EMPTY), R1 (positive control: fixtures WERE consumed), R2 (no absolute
# binary path outside the selftest block), R5 (HERMETIC line: FIX_SSH_DIR + RB_REDRIVE_DECIDE under the selftest mktemp).
# 10-23 11:48 AM leak: a selftest case without fixtures fired a REAL `wm-build run redrive 1046 --from land --stop` (row 0cd9).
# Every root, home, fake and log lives under a mktemp -d this test created; HOME and XDG_CONFIG_HOME point there; nothing real is touched.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=${RB_REDRIVE_UNDER_TEST:-$here/../.local/bin/rb-redrive.sh}   # the mutation proof points this at a throwaway copy
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

R=$(mktemp -d "${TMPDIR:-/tmp}/rb-redrive-test.XXXXXX") || exit 2
trap 'case "$R" in */rb-redrive-test.*) rm -rf -- "${R:?}";; esac' EXIT
mkdir -p "$R/fakes" "$R/logs" "$R/home" "$R/xdg" "$R/tmp"

# --- the three fakes: log argv, exit 99 (a real call would have printed nothing useful and failed loudly) ---
for b in ssh wm-decide wm-build; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$0 $*" >> "%s/logs/%s.log"\nexit 99\n' "$R" "$b" > "$R/fakes/$b"
  chmod +x "$R/fakes/$b"; : > "$R/logs/$b.log"
done
export HOME="$R/home" XDG_CONFIG_HOME="$R/xdg" TMPDIR="$R/tmp"
PATH="$R/fakes:$PATH"; export PATH

# --- fakes control: each fake is first on PATH, logs, exits 99 (so an empty log later means "never called") ---
for b in ssh wm-decide wm-build; do
  [ "$(command -v "$b")" = "$R/fakes/$b" ] && "$b" probe >/dev/null 2>&1; rc=$?
  if [ "$rc" = 99 ] && [ -s "$R/logs/$b.log" ]; then pass "fake $b is first on PATH, exits 99, logs argv"; else bad "fake $b not intercepting (rc=$rc)"; fi
  : > "$R/logs/$b.log"
done

# --- AC2: the selftest, with xtrace on so the fixture reads are traceable (R1) ---
# xtrace goes to its own fd (BASH_XTRACEFD) because the selftest cases capture stderr with 2>&1
out=$(XT="$R/xtrace" S="$script" bash -c 'exec 9>"$XT"; BASH_XTRACEFD=9; set -x; set -- --selftest; . "$S"' 2>&1); rc=$?
printf '%s\n' "$out" > "$R/selftest.out"
[ "$rc" = 0 ] && pass "selftest rc 0" || bad "selftest rc=$rc"
last=$(tail -n 1 "$R/selftest.out")
[ "$last" = "SELFTEST PASS rb-redrive.sh" ] && pass "last selftest line: $last" || bad "last selftest line: $last"
grep -q '^FAIL ' "$R/selftest.out" && bad "selftest printed a FAIL case: $(grep '^FAIL ' "$R/selftest.out" | head -3)" || pass "no FAIL case line"

# --- AC3: all three fake logs stay empty ---
for b in ssh wm-decide wm-build; do
  if [ -s "$R/logs/$b.log" ]; then bad "fake $b was CALLED: $(head -c 300 "$R/logs/$b.log")"; else pass "fake $b log empty (never reached)"; fi
done

# --- R1: positive control. Empty logs must mean interception, not inactivity ---
n_read=$(grep -cE '^\++ cat .*/s/[0-9]+\.out$' "$R/xtrace")
[ "$n_read" -ge 10 ] && pass "R1 fixture reads traced: $n_read 'cat <FIX_SSH_DIR>/N.out' lines (>= 10)" || bad "R1 only $n_read fixture reads traced"
for c in 'admit path: row first' 'dropped once -> re-issued once' 'dropped twice -> alarm' 'refused -> alarm rc 5' 'row refused -> no redrive call' "daemon 'error:' reply" '--stop passed to the daemon'; do
  grep -qF "ok   $c" "$R/selftest.out" && pass "R1 fixture-driven case ran: $c" || bad "R1 case missing: $c"
done

# --- R5: the hermetic default is observable, under the selftest mktemp ---
h=$(grep '^HERMETIC ' "$R/selftest.out" | head -1)
fx=$(sed -n 's/^HERMETIC FIX_SSH_DIR=\([^ ]*\) RB_REDRIVE_DECIDE=.*/\1/p' <<<"$h"); dc=$(sed -n 's/.* RB_REDRIVE_DECIDE=\(.*\)$/\1/p' <<<"$h")
case "$fx" in "$R"/tmp/tmp.*/s) pass "R5 FIX_SSH_DIR under the selftest mktemp: $fx";; *) bad "R5 FIX_SSH_DIR not under the selftest mktemp: '$h'";; esac
case "$dc" in "$R"/tmp/tmp.*/dec) [ "$(dirname "$dc")" = "$(dirname "$fx")" ] && pass "R5 RB_REDRIVE_DECIDE under the same mktemp: $dc" || bad "R5 DECIDE dir differs from FIX_SSH_DIR dir: '$h'";; *) bad "R5 RB_REDRIVE_DECIDE not under the selftest mktemp: '$h'";; esac

# --- R2: absolute binary paths outside the selftest block ---
nonself=$(awk '/^if \[ "\$\{1:-\}" = --selftest \]; then/{s=1} !s{print NR": "$0} s&&/^fi$/{s=0}' "$script")
hits=$(grep -E '/usr/bin/ssh|/usr/bin/wm|\.cargo/bin/wm-build|command -v ssh|/usr/(local/)?bin/(ssh|wm)' <<<"$nonself" || true)
[ -z "$hits" ] && pass "R2 no /usr/bin/ssh, /usr/bin/wm*, .cargo/bin/wm-build or 'command -v ssh' outside the selftest block" || bad "R2 absolute binary path outside the selftest block: $hits"
echo "INFO R2 other absolute-ish paths outside the selftest block (not a fail; real-mode only):"
grep -nE '\.cargo/bin|\.local/bin|/usr/|/opt/' <<<"$nonself" | cut -c1-140 | sed 's/^/INFO   /' || true

if [ "$fail" = 0 ]; then echo "rb-redrive.test: PASS"; else echo "rb-redrive.test: FAIL"; fi
exit "$fail"
