#!/usr/bin/env bash
# Gate bootstrap runner for wm-build's repo-declared checks (wm-build-ci.toml, A245/A246 B3).
# Usage: tests/gate/run-relevant.sh <test-name>[:<min-pass>] ...      (test-name = tests/<test-name>.test.sh)
#
# Why it exists: build_target `hooks` gives sh-tests, which only runs tests/<test_prefix>_* executables and *.bats and passes with
# files=0 otherwise; tests/run.sh passes with n=0 (missing file) and counts rc 77 as a non-failure. This runner turns each of those
# into a failure. A check passes only when EVERY named test:
#   1. exists                                           (missing      -> exit 2)
#   2. exits 0                                           (non-zero     -> exit 1; rc 77 -> exit 3, a skip is never a pass)
#   3. prints no SKIP line                               (any SKIP     -> exit 3, reported as UNMEASURED with its reason)
#   4. prints no FAIL / FAILURES line even at rc 0       (               exit 1)
#   5. prints a recognised pass summary with count > 0 and, when :<min-pass> is given, count >= min-pass  (none/zero/low -> exit 4)
# Prerequisites (exit 2 with the reason, never a skip): SWARM_DECIDE_SRC (default $HOME/wintermute/swarm-decide) must hold
# wm_decide/work_binding.py when a typed-review test is named, and a wm-decide with the `intake` API when ctl-intake-consumer is named
# (WM_DECIDE_PIN, else SWARM_DECIDE_SRC/bin/wm-decide). The child env is scrubbed of WM_HELPER / WM_SEAT / WM_DIRECTOR: a helper or seat
# session exports them, and the stop-gate tests then see their hooks exit early (measured: director-hermes-stop-gates fails under WM_HELPER=1,
# passes with it unset).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[ "$#" -gt 0 ] || { echo "GATE-RELEVANT: no test named (a check with nothing to run is a failure)"; exit 2; }
worst=0; problems=()
prob() { echo "$*"; problems+=("$*"); }
bump() { [ "$1" -gt "$worst" ] && worst=$1; return 0; }
for spec in "$@"; do
  name=${spec%%:*}; min=0; [ "$spec" != "$name" ] && min=${spec#*:}
  f="$here/tests/$name.test.sh"
  if [ ! -f "$f" ]; then prob "GATE-RELEVANT: $name MISSING ($f)"; bump 2; continue; fi
  case "$name" in *typed-review*)
    sd="${SWARM_DECIDE_SRC:-$HOME/wintermute/swarm-decide}"
    if [ ! -f "$sd/wm_decide/work_binding.py" ] || [ ! -x "$sd/bin/wm-decide" ]; then
      prob "GATE-RELEVANT: $name PREREQUISITE missing: SWARM_DECIDE_SRC=$sd lacks wm_decide/work_binding.py or bin/wm-decide (land the swarm-decide binding PRD first)"; bump 2; continue
    fi;;
  esac
  case "$name" in ctl-intake-consumer)
    sd="${SWARM_DECIDE_SRC:-$HOME/wintermute/swarm-decide}"; pin="${WM_DECIDE_PIN:-$sd/bin/wm-decide}"
    if [ ! -x "$pin" ] || ! "$pin" intake --help >/dev/null 2>&1; then
      prob "GATE-RELEVANT: $name PREREQUISITE missing: no wm-decide with the intake API at $pin (set WM_DECIDE_PIN or SWARM_DECIDE_SRC)"; bump 2; continue
    fi
    export WM_DECIDE_PIN="$pin";;
  esac
  out=$(mktemp "${TMPDIR:-/tmp}/gate-relevant.XXXXXX")
  timeout "${TEST_RUN_TIMEOUT_S:-1500}" env -u WM_HELPER -u WM_SEAT -u WM_DIRECTOR bash "$f" >"$out" 2>&1; rc=$?
  cat "$out"
  if [ "$rc" = 77 ]; then prob "GATE-RELEVANT: $name UNMEASURED (rc 77 skip)"; bump 3; rm -f "$out"; continue; fi
  if [ "$rc" != 0 ]; then prob "GATE-RELEVANT: $name FAILED rc=$rc"; bump 1; rm -f "$out"; continue; fi
  sk=$(grep -cE '^SKIP |SKIP-WITH-REASON' "$out" || true)
  if [ "$sk" != 0 ]; then prob "GATE-RELEVANT: $name UNMEASURED ($sk skipped guard(s) did not run):"; grep -E '^SKIP |SKIP-WITH-REASON' "$out" | cut -c1-240; bump 3; rm -f "$out"; continue; fi
  if grep -qE '^(FAIL|FAILED|FAILURES:)' "$out"; then prob "GATE-RELEVANT: $name has FAIL lines at rc 0"; bump 1; rm -f "$out"; continue; fi
  # recognised pass summaries -> a pass count (bash-only, no new dependency)
  n=""
  if l=$(grep -E '^COUNTS: pass=[0-9]+ fail=0$' "$out" | tail -1) && [ -n "$l" ]; then n=${l#COUNTS: pass=}; n=${n%% *}
  elif l=$(grep -E '^PASS=[0-9]+ FAIL=0$' "$out" | tail -1) && [ -n "$l" ]; then n=${l#PASS=}; n=${n%% *}
  elif grep -qE '^ALL PASS$' "$out"; then n=$(grep -cE '^(PASS|ok) ' "$out"); [ "$n" -gt 0 ] || n=1
  elif grep -qE '^(OK |PASS |ok - )' "$out"; then n=$(grep -cE '^(OK |PASS |ok - )' "$out"); fi
  rm -f "$out"
  if [ -z "$n" ] || [ "$n" -le 0 ]; then prob "GATE-RELEVANT: $name NO PASS EVIDENCE (no recognised pass summary with a count > 0): vacuous"; bump 4; continue; fi
  if [ "$n" -lt "$min" ]; then prob "GATE-RELEVANT: $name only $n passes, need >= $min"; bump 4; continue; fi
  echo "GATE-RELEVANT: $name PASS n=$n (min $min)"
done
if [ "$worst" = 0 ]; then echo "GATE-RELEVANT: all PASS"
else
  echo "GATE-RELEVANT: FAIL worst-rc=$worst"
  # repeated last so the gate's captured tail (wm-build keeps the last 4 KB) and `fail_marker` name every problem
  for p in "${problems[@]}"; do echo "GATE-RELEVANT-PROBLEM: $p"; done
fi
exit "$worst"
