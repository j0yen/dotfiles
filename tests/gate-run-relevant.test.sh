#!/usr/bin/env bash
# Discriminating test for tests/gate/run-relevant.sh (gate bootstrap, A245/A246 B3): each vacuous/failing/skipped shape must fail the check,
# only a real pass with a count passes. The runner is copied into a throwaway tree whose tests/ holds fake tests.
set -u
# hermetic: a gate host (or a seat) may export these; the cases below set them explicitly
unset SWARM_DECIDE_SRC WM_DECIDE_PIN WM_HELPER WM_SEAT WM_DIRECTOR
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/gate-rr.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tests/gate"; cp "$HERE/gate/run-relevant.sh" "$T/tests/gate/"
R="$T/tests/gate/run-relevant.sh"
passes=0; fails=0
mk() { printf '%s\n' "$2" > "$T/tests/$1.test.sh"; }
want() { # <label> <expected rc> <args...>
  local label=$1 exp=$2; shift 2
  bash "$R" "$@" >"$T/out" 2>&1; local rc=$?
  if [ "$rc" = "$exp" ]; then passes=$((passes+1)); echo "PASS $label (rc $rc)"; else fails=$((fails+1)); echo "FAIL $label: rc $rc want $exp"; sed 's/^/    /' "$T/out" | tail -5; fi
}
mk good-counts 'echo "COUNTS: pass=7 fail=0"'
mk good-allpass 'echo "PASS a"; echo "PASS b"; echo "ALL PASS"'
mk good-passfail 'echo "PASS=3 FAIL=0"'
mk good-ok 'echo "OK thing"'
mk zero-counts 'echo "COUNTS: pass=0 fail=0"'
mk silent 'true'
mk failing 'echo "COUNTS: pass=3 fail=1"; exit 1'
mk fail-at-rc0 'echo "FAIL x: broke"; echo "COUNTS: pass=3 fail=0"'
mk skipline 'echo "SKIP T38 /etc/hosts alias: not here"; echo "COUNTS: pass=3 fail=0"'
mk skip-with-reason 'echo "SKIP unit_socket: SKIP-WITH-REASON no systemd"; echo "OK x"'
mk rc77 'echo "SKIP t: nope"; exit 77'
want "good COUNTS"               0 good-counts
want "good ALL PASS"             0 good-allpass
want "good PASS=N FAIL=0"        0 good-passfail
want "good OK line"              0 good-ok
want "min met"                   0 good-counts:7
want "no test named"             2
want "missing test file"         2 no-such-test
want "good then missing"         2 good-counts no-such-test
want "zero-count pass summary"   4 zero-counts
want "silent test (vacuous)"     4 silent
want "count below min"           4 good-counts:8
want "non-zero exit"             1 failing
want "FAIL line at rc 0"         1 fail-at-rc0
want "SKIP line is unmeasured"   3 skipline
want "SKIP-WITH-REASON"          3 skip-with-reason
want "rc 77 is unmeasured"       3 rc77
want "worst of mixed wins"       3 good-counts skipline
HOME="$T/emptyhome" want "typed-review without swarm-decide src" 2 director-event-consumer-typed-review
mk director-event-consumer-typed-review 'echo "COUNTS: pass=120 fail=0"'
SWARM_DECIDE_SRC="$T/nope" want "typed-review prerequisite absent -> 2, not skip" 2 director-event-consumer-typed-review
mkdir -p "$T/sd/wm_decide" "$T/sd/bin"; : > "$T/sd/wm_decide/work_binding.py"; printf '#!/bin/sh\n' > "$T/sd/bin/wm-decide"; chmod +x "$T/sd/bin/wm-decide"
SWARM_DECIDE_SRC="$T/sd" want "typed-review prerequisite present, min 120" 0 director-event-consumer-typed-review:120
SWARM_DECIDE_SRC="$T/sd" want "typed-review min 121 unmet" 4 director-event-consumer-typed-review:121
# env scrub: a seat/helper/director marker in the caller's env must not reach the test
mk envprobe 'if [ -n "${WM_HELPER:-}${WM_SEAT:-}${WM_DIRECTOR:-}" ]; then echo "FAIL leaked marker"; exit 1; fi; echo "OK clean"'
WM_HELPER=1 WM_SEAT=rb WM_DIRECTOR=hermes want "WM_HELPER/WM_SEAT/WM_DIRECTOR scrubbed from the test env" 0 envprobe
# ctl-intake prerequisite: a wm-decide with the intake API
mk ctl-intake-consumer 'echo "OK ctl-intake-consumer pin=$WM_DECIDE_PIN"'
WM_DECIDE_PIN="$T/none" SWARM_DECIDE_SRC="$T/none" want "ctl-intake without an intake-capable wm-decide -> 2" 2 ctl-intake-consumer
printf '#!/bin/sh\n[ "$1" = intake ] && [ "$2" = --help ] && exit 0\nexit 1\n' > "$T/sd/bin/wm-decide"
SWARM_DECIDE_SRC="$T/sd" want "ctl-intake with intake API via SWARM_DECIDE_SRC" 0 ctl-intake-consumer
# the last lines name every problem, so wm-build's captured tail and fail_marker carry the cause
bash "$R" good-counts failing skipline no-such-test >"$T/out" 2>&1
tailn=$(tail -5 "$T/out" | grep -c '^GATE-RELEVANT-PROBLEM: ')
if [ "$tailn" -ge 3 ]; then passes=$((passes+1)); echo "PASS problems repeated in the tail ($tailn)"; else fails=$((fails+1)); echo "FAIL problems not repeated in the tail ($tailn)"; fi
bash "$R" good-counts >"$T/out2" 2>&1
if grep -q PROBLEM "$T/out2"; then fails=$((fails+1)); echo "FAIL a clean run prints problems"; else passes=$((passes+1)); echo "PASS a clean run prints no problems"; fi
# F6 (review 74270b28): the test must run against the swarm-decide tree the runner validated, and the runner records which one
mk director-event-consumer-typed-review 'if [ "${SWARM_DECIDE_SRC:-}" = "'"$T"'/sd" ]; then echo "COUNTS: pass=120 fail=0"; else echo "FAIL wrong tree ${SWARM_DECIDE_SRC:-<unset>}"; fi'
( cd "$T/sd" && git init -q . && git add -A && git -c user.name=x -c user.email=x@x commit -qm sd ) >/dev/null 2>&1
SWARM_DECIDE_SRC="$T/sd" want "typed test receives the validated tree (exported)" 0 director-event-consumer-typed-review:120
SWARM_DECIDE_SRC="$T/sd" bash "$R" director-event-consumer-typed-review:120 >"$T/prov" 2>&1
if grep -qE "^GATE-RELEVANT: provenance director-event-consumer-typed-review swarm-decide=$T/sd HEAD=[0-9a-f]{40} dirty-files=0$" "$T/prov"; then passes=$((passes+1)); echo "PASS provenance line: path, HEAD, dirty count"; else fails=$((fails+1)); echo "FAIL provenance line"; cat "$T/prov"; fi
echo dirt > "$T/sd/untracked"; SWARM_DECIDE_SRC="$T/sd" bash "$R" director-event-consumer-typed-review:120 >"$T/prov" 2>&1; rm "$T/sd/untracked"
if grep -q "dirty-files=1" "$T/prov"; then passes=$((passes+1)); echo "PASS dirty tree is recorded"; else fails=$((fails+1)); echo "FAIL dirty not recorded"; fi
# F6 reviewer counterexample: no SWARM_DECIDE_SRC in the caller env; the runner validates the DEFAULT $HOME tree, the test must receive that same tree
mkdir -p "$T/home/wintermute"; cp -r "$T/sd" "$T/home/wintermute/swarm-decide"
mk director-event-consumer-typed-review 'if [ "${SWARM_DECIDE_SRC:-}" = "'"$T"'/home/wintermute/swarm-decide" ]; then echo "COUNTS: pass=120 fail=0"; else echo "FAIL wrong tree ${SWARM_DECIDE_SRC:-<unset>}"; fi'
HOME="$T/home" want "default-tree validated and exported to the test (no env set)" 0 director-event-consumer-typed-review:120
# N2 (review delta-01): wm-build keeps only the LAST 4 KiB of a check's output. A typed test that prints more than that pushes the provenance line
# (printed before the test) out of the receipt, on pass and on fail. The runner repeats provenance in its final block.
mk director-event-consumer-typed-review 'if [ "${SWARM_DECIDE_SRC:-}" = "'"$T"'/sd" ]; then for i in $(seq 1 400); do echo "noise line $i to fill the receipt tail well past four kib of output"; done; echo "COUNTS: pass=120 fail='"'"'${TYPED_FAILS:-0}'"'"'"; exit ${TYPED_FAILS:-0}; else echo "FAIL wrong tree"; exit 1; fi'
sdhead=$(git -C "$T/sd" rev-parse HEAD)
for mode in pass fail; do
  fails_env=0; [ "$mode" = fail ] && fails_env=1
  TYPED_FAILS=$fails_env SWARM_DECIDE_SRC="$T/sd" bash "$R" director-event-consumer-typed-review:120 >"$T/big-$mode" 2>&1
  size=$(wc -c < "$T/big-$mode"); tail -c 4096 "$T/big-$mode" > "$T/big-$mode.tail"
  if [ "$size" -gt 8192 ] && grep -q "provenance director-event-consumer-typed-review swarm-decide=$T/sd HEAD=$sdhead dirty-files=0" "$T/big-$mode.tail"; then passes=$((passes+1)); echo "PASS provenance survives the 4 KiB tail ($mode, output $size bytes)"; else fails=$((fails+1)); echo "FAIL provenance lost from the last 4 KiB ($mode, output $size bytes)"; fi
done
echo "COUNTS: pass=$passes fail=$fails"
[ "$fails" = 0 ]
