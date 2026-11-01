#!/usr/bin/env bash
# tests/lib/timing.sh med_ms: median<200 AND every sample<1000; fresh state dir
# per sample. Fake commands only (sleep); throwaway dirs.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/timing.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1 ${2:-}"; }
expect() { # $1=name $2=want-rc $3=got-rc
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want rc=$2 got rc=$3 samples=${MED_SAMPLES[*]}"; fi
}

calls=0; seq_slow() { calls=$((calls + 1)); case " $SLOW " in *" $calls "*) sleep "$SLEEP" ;; esac; }

SLEEP=0.3 SLOW=""      calls=0; med_ms 3 seq_slow >/dev/null; expect "fast-3-pass" 0 $?
SLEEP=0.3 SLOW="2"     calls=0; med_ms 3 seq_slow >/dev/null; expect "slow-1-of-3-pass (tolerated)" 0 $?
SLEEP=0.3 SLOW="1 3"   calls=0; med_ms 3 seq_slow >/dev/null; expect "slow-2-of-3-fail" 1 $?
SLEEP=0.3 SLOW="1 2 3" calls=0; med_ms 3 seq_slow >/dev/null; expect "slow-3-of-3-fail" 1 $?
SLEEP=1.1 SLOW="2"     calls=0; med_ms 3 seq_slow >/dev/null; expect "one-sample-over-1000-fail (hang ceiling)" 1 $?
med_ms 3 true >/dev/null 2>&1; expect "three-samples" 3 "${#MED_SAMPLES[@]}"
out=$(SLEEP=0.3 SLOW="1 3" calls=0; med_ms 3 seq_slow); case "$out" in *"samples="*"median="*SLOW) ok "prints-samples-on-failure" ;; *) bad "prints-samples-on-failure" "$out" ;; esac

# fresh state dir per sample, removed after
dirs=(); rec() { dirs+=("$MED_STATE"); [ -z "$(ls -A "$MED_STATE")" ] && : >"$MED_STATE/x"; }
med_ms 3 rec >/dev/null
[ "$(printf '%s\n' "${dirs[@]}" | sort -u | wc -l)" = 3 ]; expect "state-dir-fresh-per-sample" 0 $?
gone=0; for d in "${dirs[@]}"; do [ -e "$d" ] && gone=1; done; expect "state-dir-removed" 0 "$gone"
med_ms 0 true 2>/dev/null; expect "n-required" 2 $?

echo "timing-lib.test: $pass passed, $fail failed"
[ "$fail" = 0 ]
