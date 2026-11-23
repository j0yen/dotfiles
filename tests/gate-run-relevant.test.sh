#!/usr/bin/env bash
# Discriminating test for tests/gate/run-relevant.sh (gate bootstrap, A245/A246 B3): each vacuous/failing/skipped shape must fail the check,
# only a real pass with a count passes. The runner is copied into a throwaway tree whose tests/ holds fake tests.
set -u
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
want "typed-review without swarm-decide src" 2 director-event-consumer-typed-review
mk director-event-consumer-typed-review 'echo "COUNTS: pass=120 fail=0"'
SWARM_DECIDE_SRC="$T/nope" want "typed-review prerequisite absent -> 2, not skip" 2 director-event-consumer-typed-review
mkdir -p "$T/sd/wm_decide" "$T/sd/bin"; : > "$T/sd/wm_decide/work_binding.py"; printf '#!/bin/sh\n' > "$T/sd/bin/wm-decide"; chmod +x "$T/sd/bin/wm-decide"
SWARM_DECIDE_SRC="$T/sd" want "typed-review prerequisite present, min 120" 0 director-event-consumer-typed-review:120
SWARM_DECIDE_SRC="$T/sd" want "typed-review min 121 unmet" 4 director-event-consumer-typed-review:121
echo "COUNTS: pass=$passes fail=$fails"
[ "$fails" = 0 ]
