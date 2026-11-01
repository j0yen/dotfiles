#!/usr/bin/env bash
# rb-reprice-watch-legacy-key.test.sh - after the 2026-10-29 TODO the legacy t4_lowered_from state key is not read.
# DEFINED BEHAVIOR: a state file carrying ONLY t4_lowered_from loads without crashing, T4R_FROM is empty (the pause is
# treated as having lowered nothing, so recovery never raises max_runs), cause stays T4, and --selftest prints no FAIL.
# Fixtures live under a mktemp -d root; the live state path is never touched.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=$here/../.local/bin/rb-reprice-watch.sh
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
R=$(mktemp -d "${TMPDIR:-/tmp}/rb-reprice-legacy-key.XXXXXX") || exit 2
trap 'case "$R" in */rb-reprice-legacy-key.*) rm -rf -- "$R";; esac' EXIT

now=$(date +%s)
printf 'T4R_RUN=7\nT4R_PAUSED_AT=%s\nT4R_COST=0\nT4R_LAST=x\nT4R_STUCK=0\nt4_lowered_from=2\n' "$now" > "$R/legacy.state"

# 1. no reader of the legacy key and no fallback marker remain in the script's code
if ! grep -q 'T4LF-FALLBACK' "$src" && ! grep -Eq 't4_lowered_from\)' "$src"; then pass "no legacy-key reader or fallback marker in the script"; else bad "legacy reader still present"; fi

# 2. normal load: run the real t4r_load text against the legacy-only file (host loop not started; log/rowq stubbed)
sed -n '/^t4r_load(){/,/window re-earned from 0)"; }$/p' "$src" > "$R/fn.sh"
out=$(T4R_STATE=$R/legacy.state; LOGF=$R/log
  log(){ echo "$*" >> "$LOGF"; }; rowq(){ ROWV=1; return 0; }; t4r_state_rm(){ rm -f -- "$T4R_STATE"; }
  . "$R/fn.sh" && t4r_load && echo "RUN=$T4R_RUN FROM=[$T4R_FROM] CAUSE=$T4R_CAUSE RESTART=$T4R_RESTART" ) ; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "RUN=7 FROM=[] CAUSE=T4 RESTART=unknown" ] && [ -e "$R/legacy.state" ]; then pass "legacy-only file loads, from empty, state kept: $out"; else bad "legacy load rc=$rc out='$out'"; fi

# 3. --selftest prints no FAIL line with the legacy file as the configured state path (selftest uses its own fixtures)
sqlite3 "$R/fx.db" "create table steps(id integer primary key, run_id integer, kind text, priced_peak_kb integer); insert into steps(run_id,kind,priced_peak_kb) values(1,'inner',7644528)" || exit 2
st=$(RW_T4R_STATE=$R/legacy.state RW_DB=$R/fx.db HOME=$R/home bash "$src" --selftest 2>&1); rc=$?
if [ "$rc" = 0 ] && ! printf '%s\n' "$st" | grep -q FAIL; then pass "selftest rc=0, no FAIL line"; else bad "selftest rc=$rc first_fail=$(printf '%s\n' "$st" | grep -m1 FAIL)"; fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
