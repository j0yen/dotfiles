#!/usr/bin/env bash
# watcher-skip-streak.test.sh - tsd3 F3/W3/W4/W5: the watcher lib's watcher_skip / watcher_run_end consecutive-skip alarm.
# Every fixture lives under a mktemp -d root this test created; WATCHER_STATE_DIR points there; nothing reads or writes real state.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB=$here/../.local/lib/watcher-premise.sh
WATCH=$here/../.local/bin/rb-reprice-watch.sh
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
R=$(mktemp -d "${TMPDIR:-/tmp}/watcher-skip-streak-test.XXXXXX") || exit 2
trap 'case "$R" in */watcher-skip-streak-test.*) rm -rf -- "$R";; esac' EXIT

# each case runs in a subshell with its own state dir so no streak leaks between cases
run() { ( export WP_STATE=$R/wp-$1 WATCHER_STATE_DIR=$R/st-$1; unset WATCHER_SKIP_MAX; mkdir -p "$WP_STATE" "$WATCHER_STATE_DIR"; . "$LIB"; WP_NAME=skiptest; shift; "$@" ) ; }

# F3a: 20 skips -> the 20th emits the alarm line; the state file is $WATCHER_STATE_DIR/<name>.skip (W3)
cases_a() { local i o=; for i in $(seq 1 20); do o=$(watcher_skip "no input"); done; printf '%s' "$o"; }
o=$(run a cases_a)
if [ "$o" = "alarm: skip-streak skiptest 20 no input" ]; then pass "F3 20 skips -> $o"; else bad "F3 20 skips -> [$o]"; fi
if [ "$(cat "$R/st-a/skiptest.skip" 2>/dev/null)" = "20 no input" ]; then pass "W3 state file $R/st-a/skiptest.skip = '20 no input'"; else bad "W3 state file [$(cat "$R/st-a/skiptest.skip" 2>&1)]"; fi

# F3b: 19 skips -> no alarm line at any skip
cases_b() { local i o all=; for i in $(seq 1 19); do o=$(watcher_skip "no input"); all+=$o; done; printf '[%s]' "$all"; }
o=$(run b cases_b)
if [ "$o" = "[]" ]; then pass "F3 19 skips -> no alarm"; else bad "F3 19 skips -> $o"; fi

# W3: 19 skips then 1 act (watcher_run_end) -> no alarm, counter reset; then 19 more skips still no alarm
cases_c() { local i o all=; for i in $(seq 1 19); do o=$(watcher_skip "no input"); all+=$o; done; watcher_run_end
  printf 'streak=%s alarm=[%s] ' "$(watcher_skip_streak)" "$(watcher_skip_alarm)"
  for i in $(seq 1 19); do o=$(watcher_skip "no input"); all+=$o; done; printf 'after19more=[%s] streak=%s' "$all" "$(watcher_skip_streak)"; }
o=$(run c cases_c)
if [ "$o" = "streak=0 alarm=[] after19more=[] streak=19" ]; then pass "W3 19 skips then watcher_run_end -> $o"; else bad "W3 19 skips then run_end -> [$o]"; fi

# env override: WATCHER_SKIP_MAX=3 alarms on the 3rd skip; junk and 0 fall back to 20
cases_d() { local i o=; export WATCHER_SKIP_MAX=3; for i in 1 2 3; do o=$(watcher_skip "x"); done; printf '%s' "$o"; }
o=$(run d cases_d)
if [ "$o" = "alarm: skip-streak skiptest 3 x" ]; then pass "override WATCHER_SKIP_MAX=3 -> $o"; else bad "override -> [$o]"; fi
cases_e() { local i; export WATCHER_SKIP_MAX=junk; for i in $(seq 1 5); do watcher_skip "x" >/dev/null; done; printf 'junk=[%s] ' "$(watcher_skip_alarm)"; export WATCHER_SKIP_MAX=0; printf 'zero=[%s]' "$(watcher_skip_alarm)"; }
o=$(run e cases_e)
if [ "$o" = "junk=[] zero=[]" ]; then pass "junk/0 threshold falls back to 20: $o"; else bad "fallback -> [$o]"; fi

# a skip without wp_arm/WP_NAME is refused, never counted under a shared name
o=$( ( export WP_STATE=$R/wp-f WATCHER_STATE_DIR=$R/st-f; mkdir -p "$R/st-f"; . "$LIB"; unset WP_NAME; watcher_skip x 2>&1; echo "rc=$?" ) )
if [[ $o == *"wp_arm was not called"* ]] && [ -z "$(ls "$R/st-f")" ]; then pass "skip without WP_NAME refused, no file"; else bad "no-name skip [$o] files=[$(ls "$R/st-f")]"; fi

# W5: the adopted watcher calls the helpers in the right branches (static ordering) and its own --selftest (case SK1) proves skip_streak/alarm land in status.json
if grep -n 'watcher_skip "premise-' "$WATCH" >/dev/null && grep -n 'DISARM_SEEN=; watcher_run_end' "$WATCH" >/dev/null; then pass "W5 rb-reprice-watch.sh calls watcher_skip (disarmed pass) and watcher_run_end (armed pass)"; else bad "W5 call sites missing"; fi
sqlite3 "$R/fx.db" "create table steps(id integer primary key, run_id integer, kind text, priced_peak_kb integer); insert into steps(run_id,kind,priced_peak_kb) values(1,'inner',7644528)" || exit 2
mkdir -p "$R/home"
out=$(RW_DB=$R/fx.db HOME=$R/home WP_LIB=$LIB bash "$WATCH" --selftest 2>"$R/st.err"); rc=$?
last=$(printf '%s\n' "$out" | tail -n 1)
if [ "$rc" = 0 ] && [[ $last == "SELFTEST PASS"*"SK1 ok"* ]]; then pass "W4/W5 selftest SK1: skip_streak+alarm in status.json: ${last:0:20}...SK1 ok"; else bad "selftest rc=$rc last='${last:0:200}' err=$(tail -n 3 "$R/st.err" | tr '\n' '|')"; fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
