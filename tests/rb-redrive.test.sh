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
for c in 'admit path: row first' 'dropped once -> re-issued once' 'dropped twice -> alarm' 'refused -> alarm rc 5' 'row refused -> no redrive call' "daemon 'error:' reply" '--stop passed to the daemon' 'preflight (e) positive control' 'preflight (e): FIX_SSH_DIR empty' 'preflight (f): populated FIX_SSH_DIR'; do
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

# --- rrdfc: the selftest fails CLOSED (ctl 12:06 PM 10-23). wm-build is reachable ONLY through rssh, so the rssh guard covers ssh and wm-build; main's guard covers wm-decide ---
# (a) a scratch copy mutated BY PATTERN loses the hermetic export and the first main case's inline FIX_SSH_DIR/RB_REDRIVE_DECIDE
for b in ssh wm-decide wm-build; do : > "$R/logs/$b.log"; done
mut="$R/rb-redrive.mut.sh"
sed -e '/^  export FIX_SSH_DIR=/d' -e '0,/FIX_SSH_DIR="\$T\/s" RB_REDRIVE_DECIDE="\$T\/dec" /s///' "$script" > "$mut"
if cmp -s "$script" "$mut"; then bad "(a) the mutation changed nothing (pattern drift)"; else pass "(a) mutated copy differs from the original (cmp -s)"; fi
mout=$(XT="$R/xtrace-mut" S="$mut" bash -c 'exec 9>"$XT"; BASH_XTRACEFD=9; set -- --selftest; . "$S"' 2>&1); mrc=$?
printf '%s\n' "$mout" > "$R/mut.out"
[ "$mrc" != 0 ] && pass "(a) mutated selftest rc != 0 (rc=$mrc)" || bad "(a) mutated selftest rc 0: it failed OPEN"
grep -q 'REFUSED selftest-unhermetic' "$R/mut.out" && pass "(a) mutated selftest output: $(grep -m1 'REFUSED selftest-unhermetic' "$R/mut.out")" || bad "(a) no REFUSED selftest-unhermetic in the mutated output: $(tail -n 3 "$R/mut.out")"
for b in ssh wm-decide wm-build; do
  if [ -s "$R/logs/$b.log" ]; then bad "(a) fake $b was CALLED: $(head -c 300 "$R/logs/$b.log")"; else pass "(a) fake $b log empty"; fi
done

# (b) direct run with both seams empty: refuse before any call
for b in ssh wm-decide wm-build; do : > "$R/logs/$b.log"; done
dout=$(RB_REDRIVE_SELFTEST=1 FIX_SSH_DIR= RB_REDRIVE_DECIDE= bash "$script" 1039 --from land --why t 2>&1); drc=$?
[ "$drc" = 71 ] && pass "(b) direct run rc 71" || bad "(b) direct run rc=$drc: $dout"
grep -q 'REFUSED selftest-unhermetic' <<<"$dout" && pass "(b) direct run output: $(grep -m1 'REFUSED selftest-unhermetic' <<<"$dout")" || bad "(b) no REFUSED selftest-unhermetic: $dout"
for b in ssh wm-decide wm-build; do
  if [ -s "$R/logs/$b.log" ]; then bad "(b) fake $b was CALLED: $(head -c 300 "$R/logs/$b.log")"; else pass "(b) fake $b log empty"; fi
done

# --- rrdfc2: the two rssh guards, each reached with the DECIDE guard satisfied (a stub decide under $R), so rssh is the guard that fires ---
# rrdh: main's hoisted preflight now refuses an empty FIX_SSH_DIR before sigma/decide/rssh run, so the :18 rssh guard is reached by calling rssh directly (sourced), not through main.
printf '#!/bin/bash\nprintf "%%s\\n" "$0 $*" >> "%s/logs/stubdecide.log"\necho d-20261023-060000-rb-abcd\n' "$R" > "$R/stubdecide"; chmod +x "$R/stubdecide"
mkdir -p "$R/emptyfix"

# (c) FIX_SSH_DIR empty -> the rssh :18 guard (rssh called directly)
for b in ssh wm-decide wm-build stubdecide; do : > "$R/logs/$b.log"; done
cout=$(RB_REDRIVE_SELFTEST=1 FIX_SSH_DIR= S="$script" bash -c '. "$S"; rssh "echo hi"' 2>&1); crc=$?
printf '%s\n' "$cout" > "$R/c.out"
[ "$crc" = 71 ] && pass "(c) rssh with FIX_SSH_DIR empty: rc 71" || bad "(c) rc=$crc (expected 71): $cout"
grep -q 'REFUSED selftest-unhermetic: FIX_SSH_DIR unset' <<<"$cout" && pass "(c) output: $(grep -m1 'REFUSED selftest-unhermetic: FIX_SSH_DIR unset' <<<"$cout")" || bad "(c) no 'REFUSED selftest-unhermetic: FIX_SSH_DIR unset': $cout"
for b in ssh wm-decide wm-build; do
  if [ -s "$R/logs/$b.log" ]; then bad "(c) fake $b was CALLED: $(head -c 300 "$R/logs/$b.log")"; else pass "(c) fake $b log empty"; fi
done

# (d) FIX_SSH_DIR an EMPTY dir -> the :20 guard; the .n counter lives in the sigma/rssh subshells, so a repeating "fixture 1 missing" is expected
for b in ssh wm-decide wm-build stubdecide; do : > "$R/logs/$b.log"; done
dout=$(RB_REDRIVE_SELFTEST=1 FIX_SSH_DIR="$R/emptyfix" RB_REDRIVE_DECIDE="$R/stubdecide" bash "$script" 1039 --from land --why t 2>&1); drc=$?
printf '%s\n' "$dout" > "$R/d.out"
[ "$drc" != 0 ] && pass "(d) empty-fixture-dir run rc != 0 (rc=$drc)" || bad "(d) rc 0: it failed OPEN: $dout"
grep -qE 'REFUSED selftest-unhermetic: fixture [0-9]+ missing' <<<"$dout" && pass "(d) output: $(grep -m1 -E 'REFUSED selftest-unhermetic: fixture [0-9]+ missing' <<<"$dout")" || bad "(d) no 'REFUSED selftest-unhermetic: fixture N missing': $dout"
for b in ssh wm-decide wm-build; do
  if [ -s "$R/logs/$b.log" ]; then bad "(d) fake $b was CALLED: $(head -c 300 "$R/logs/$b.log")"; else pass "(d) fake $b log empty"; fi
done
echo "INFO (d) stub decide invoked $(wc -l < "$R/logs/stubdecide.log") time(s)"

# --- rrdh (e): the hoisted preflight. FIX_SSH_DIR empty + a RECORDING stub decide + the recording fake ssh: main must refuse rc 71 BEFORE any call ---
# e_eval SCRIPT -> e_fails[] holds the quoted text of every failed assertion. The positive control (R4) runs first: each recorder must gain exactly one line when called directly,
# so an empty log after main means "never called", not "recorder broken". Reused on the mutated copies so m1/m2 are judged by the SAME assertions.
e_eval() {
  local s=$1 n m; e_fails=()
  for b in ssh wm-decide wm-build stubdecide; do : > "$R/logs/$b.log"; done
  "$R/stubdecide" probe >/dev/null; ssh probe >/dev/null 2>&1
  n=$(wc -l < "$R/logs/stubdecide.log"); m=$(wc -l < "$R/logs/ssh.log")
  [ "$n" = 1 ] && [ "$m" = 1 ] || e_fails+=("positive control: recorders gained stubdecide=$n ssh=$m lines, expected 1 and 1")
  for b in ssh wm-decide wm-build stubdecide; do : > "$R/logs/$b.log"; done
  eout=$( (RB_REDRIVE_SELFTEST=1 FIX_SSH_DIR= RB_REDRIVE_DECIDE="$R/stubdecide" bash "$s" 1039 --from land --why t) 2>&1 ); erc=$?
  printf '%s\n' "$eout" > "$R/e.out"
  [ "$erc" = 71 ] || e_fails+=("rc == 71 (got rc=$erc)")
  grep -qx 'REFUSED selftest-unhermetic: FIX_SSH_DIR' <<<"$eout" || e_fails+=("stderr has the hoist's own line 'REFUSED selftest-unhermetic: FIX_SSH_DIR' (got: $(grep -m1 REFUSED <<<"$eout"))")
  for b in stubdecide ssh wm-decide wm-build; do [ ! -s "$R/logs/$b.log" ] || e_fails+=("$b calls file empty (got $(wc -l < "$R/logs/$b.log") line(s): $(head -c 120 "$R/logs/$b.log"))"); done
}
e_eval "$script"
[ "${#e_fails[@]}" = 0 ] && pass "(e) positive control ok (recorders gained exactly one line each), then FIX_SSH_DIR empty: rc 71, hoist stderr, stubdecide/ssh/wm-decide/wm-build logs empty" || bad "(e) failed: $(printf '%s | ' "${e_fails[@]}")"

# --- rrdh mutations, scratch copies by pattern, each guarded by cmp -s ---
# m1: delete the hoist call. The sigma guard still stops main before decide, so rc 71 and the empty logs HOLD (masked); only the hoist's own stderr line goes missing (R1).
m1="$R/rb-redrive.m1.sh"; sed -e '/^  selftest_preflight || return 71/d' "$script" > "$m1"
if cmp -s "$script" "$m1"; then bad "m1 changed nothing (pattern drift)"; else
  e_eval "$m1"
  if [ "${#e_fails[@]}" = 1 ] && [[ "${e_fails[0]}" == "stderr has the hoist's own line"* ]]; then pass "m1 (hoist deleted): (e) FAILS on exactly: ${e_fails[0]}"; else bad "m1 expected exactly the hoist-stderr assertion to fail, got ${#e_fails[@]}: $(printf '%s | ' "${e_fails[@]}")"; fi
fi
# m2: hoist deleted AND the sigma guard dropped -> decide runs (one logged call) and the later rssh refusal ends as rc 4.
m2="$R/rb-redrive.m2.sh"; sed -e '/^  selftest_preflight || return 71/d' -e 's/^  sig=\$(sigma) || {.*$/  sig=$(sigma)/' "$script" > "$m2"
if cmp -s "$m1" "$m2"; then bad "m2 changed nothing beyond m1 (pattern drift)"; else
  e_eval "$m2"; mf=$(printf '%s | ' "${e_fails[@]}")
  if [[ "$mf" == *"rc == 71"* && "$mf" == *"stubdecide calls file empty"* ]]; then pass "m2 (hoist deleted + sigma guard dropped): (e) FAILS on: $mf"; else bad "m2 expected the rc and stubdecide-calls assertions to fail, got: $mf"; fi
fi

# --- rrdh (f): FIX_SSH_DIR populated, RB_REDRIVE_DECIDE = wm-decide (bare name resolved on PATH, then an absolute path with that basename): R3 refuses before any call ---
mkdir -p "$R/popfix"; echo "MemAvailable_G=25.0" > "$R/popfix/1.out"
for want in "wm-decide:RB_REDRIVE_DECIDE-not-absolute" "$R/fakes/wm-decide:RB_REDRIVE_DECIDE-is-wm-decide"; do
  dv=${want%%:RB*}; line="REFUSED selftest-unhermetic: RB${want#*:RB}"
  for b in ssh wm-decide wm-build; do : > "$R/logs/$b.log"; done; rm -f -- "$R/popfix/argv" "$R/popfix/.n"
  fout=$(RB_REDRIVE_SELFTEST=1 FIX_SSH_DIR="$R/popfix" RB_REDRIVE_DECIDE="$dv" bash "$script" 1039 --from land --why t 2>&1); frc=$?
  [ "$frc" = 71 ] && grep -qx "$line" <<<"$fout" && pass "(f) DECIDE=$dv with a populated FIX_SSH_DIR: rc 71, $line" || bad "(f) DECIDE=$dv rc=$frc: $fout"
  if [ -s "$R/logs/ssh.log" ] || [ -s "$R/logs/wm-decide.log" ] || [ -s "$R/logs/wm-build.log" ] || [ -e "$R/popfix/argv" ] || [ -e "$R/popfix/.n" ]; then bad "(f) DECIDE=$dv: something was called (ssh/wm-decide/wm-build logs or the fixture argv)"; else pass "(f) DECIDE=$dv: fake ssh/wm-decide/wm-build logs empty and no fixture consumed"; fi
done

if [ "$fail" = 0 ]; then echo "rb-redrive.test: PASS"; else echo "rb-redrive.test: FAIL"; fi
exit "$fail"
