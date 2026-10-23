#!/usr/bin/env bash
# rb-reprice-watch.test.sh - runs the watcher's own hermetic --selftest under a throwaway HOME (AC6), plus the host guard (E4)
# and the decide wrapper's timeout cap (E6). Every fixture lives under a mktemp -d root this test created; no ssh, no real host path.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bin=$here/../.local/bin
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

R=$(mktemp -d "${TMPDIR:-/tmp}/rb-reprice-watch-test.XXXXXX") || exit 2
trap 'case "$R" in */rb-reprice-watch-test.*) rm -rf -- "$R";; esac' EXIT
mkdir -p "$R/home" "$R/bin"

# 1. --selftest: rc 0 and a SELFTEST PASS last line (HOME is throwaway; the lib is read from this checkout)
sqlite3 "$R/fx.db" "create table steps(id integer primary key, run_id integer, kind text, priced_peak_kb integer); insert into steps(run_id,kind,priced_peak_kb) values(1,'inner',7644528)" || exit 2   # the one fixture row target() needs (7.29 GiB -> 10.5)
out=$(RW_DB=$R/fx.db HOME=$R/home WP_LIB=$here/../.local/lib/watcher-premise.sh bash "$bin/rb-reprice-watch.sh" --selftest 2>"$R/selftest.err"); rc=$?
last=$(printf '%s\n' "$out" | tail -n 1)
if [ "$rc" = 0 ] && [[ $last == "SELFTEST PASS"* ]]; then pass "selftest rc=0: ${last:0:60}..."; else bad "selftest rc=$rc last='$last' err=$(tail -n 3 "$R/selftest.err" | tr '\n' '|')"; fi

# 2. E4 host guard: off RedBaron the watcher prints WRONG-HOST and exits 0 before it touches anything; --circuit-gate exits 2
printf '#!/bin/bash\necho carbon\n' > "$R/bin/hostname"; chmod +x "$R/bin/hostname"
out=$(PATH=$R/bin:$PATH HOME=$R/home bash "$bin/rb-reprice-watch.sh" 2>&1); rc=$?
if [ "$rc" = 0 ] && [[ $out == WRONG-HOST* ]] && [ ! -e "$R/home/.local" ]; then pass "off-host run -> WRONG-HOST rc=0, nothing written"; else bad "host guard rc=$rc out='$out'"; fi
out=$(PATH=$R/bin:$PATH HOME=$R/home bash "$bin/rb-reprice-watch.sh" --circuit-gate 2>&1); rc=$?
if [ "$rc" = 2 ] && [[ $out == WRONG-HOST* ]]; then pass "off-host --circuit-gate -> rc=2 (never an ok for wip-redrive)"; else bad "off-host circuit-gate rc=$rc out='$out'"; fi

# 3. E6 wrapper: a hung wm-decide is cut at the cap (1 s here, 10 s in production) and exits 124
printf '#!/bin/bash\nsleep 30\n' > "$R/bin/fake-decide"; chmod +x "$R/bin/fake-decide"
s=$(date +%s%N); RW_DECIDE_REAL=$R/bin/fake-decide RW_DECIDE_TIMEOUT=1 bash "$bin/rb-reprice-watch-decide.sh" record --x; rc=$?; ms=$(( ($(date +%s%N) - s) / 1000000 ))
if [ "$rc" = 124 ] && [ "$ms" -lt 5000 ]; then pass "decide wrapper cut a hung record at the cap (rc=124, ${ms} ms)"; else bad "decide wrapper rc=$rc ms=$ms"; fi
printf '#!/bin/bash\necho "$*" > "$FAKE_OUT"\n' > "$R/bin/ok-decide"; chmod +x "$R/bin/ok-decide"
FAKE_OUT=$R/argv RW_DECIDE_REAL=$R/bin/ok-decide bash "$bin/rb-reprice-watch-decide.sh" record --agent rb; rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$R/argv")" = "record --agent rb" ]; then pass "decide wrapper passes argv through"; else bad "decide wrapper passthrough rc=$rc argv='$(cat "$R/argv" 2>/dev/null)'"; fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
