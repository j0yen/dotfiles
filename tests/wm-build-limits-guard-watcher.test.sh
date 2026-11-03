#!/usr/bin/env bash
# wm-build-limits-guard --by watcher:<name> (ctl k1050): live arm only, max_runs only,
# value 1 or exactly the logged lowered_from, never above the lock value at arm time; joe-* unchanged.
set -u
here=$(cd "$(dirname "$0")/.." && pwd); G="$here/.local/bin/wm-build-limits-guard"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T" LG_T4R_STATE="$T/t4r.state"; unset WP_STATE RW_T4R_STATE
mkdir -p "$T/.config/wm-build" "$T/.local/state/watcher-premise"
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: want [$3] got [$2]"; fi; }
lock() { printf 'box.grace_minutes=20\nbuilder.idle_minutes=20\nbox.roles.coder.max_boxes=4\nbox.roles.coder.max_leases_per_box=7\nmax_runs=%s\nbuilder.type=ccx43\n' "$1" > "$T/.config/wm-build/limits.lock"; }
lockv() { grep '^max_runs=' "$T/.config/wm-build/limits.lock" | cut -d= -f2; }
arm() { # armed verdict expires checked_ts
  printf 'rb-reprice-watch\tredbaron\tpremise\t%s\t%s\t%s\t-\t%s\t0\t-\trc=0 -\n' "$2" "$3" "$1" "$4" > "$T/.local/state/watcher-premise/rb-reprice-watch.tsv"; }
now=$(date +%s); fut=$(date -d '+2 days' '+%Y-%m-%d %H:%M:%S'); past=$(date -d '-1 day' '+%Y-%m-%d %H:%M:%S')
W=(--by watcher:rb-reprice-watch "q")
run() { "$G" set "$@" >/dev/null 2>&1; echo $?; }

lock 2; arm 1 HOLDS "$fut" "$now"
ok "joe path unchanged"            "$(run max_runs=2 --by joe-2026-11-03 "q")" 0
ok "other --by refused"            "$(run max_runs=1 --by rb "q")" 1
ok "unknown watcher refused"       "$(run max_runs=1 --by watcher:other "q")" 1
ok "key other than max_runs"       "$(run box.grace_minutes=5 "${W[@]}")" 1
ok "restore before any lowering"   "$(run max_runs=2 "${W[@]}")" 1
arm 1 HOLDS "$past" "$now";  ok "expired arm refused"     "$(run max_runs=1 "${W[@]}")" 1
arm 0 GONE "$fut" "$now";    ok "disarmed arm refused"    "$(run max_runs=1 "${W[@]}")" 1
arm 1 HOLDS "$fut" $((now-900)); ok "stale premise refused" "$(run max_runs=1 "${W[@]}")" 1
rm -f "$T/.local/state/watcher-premise/rb-reprice-watch.tsv"; ok "no arm record refused" "$(run max_runs=1 "${W[@]}")" 1
arm 1 HOLDS "$fut" "$now"
ok "lower to 1 accepted"           "$(run max_runs=1 "${W[@]}"):$(lockv)" 0:1
ok "arm-time lock recorded"        "$(cat "$T/.local/state/wm-build/limits-guard.watcher-rb-reprice-watch.armlock")" 2
ok "accept logged with arm id"     "$(tail -n1 "$T/.local/state/wm-build/limits-guard.log" | grep -c 'by=watcher:rb-reprice-watch arm=rb-reprice-watch@')" 1
echo "lowered_from=3" > "$LG_T4R_STATE"
ok "above arm-time lock refused"   "$(run max_runs=3 "${W[@]}"):$(lockv)" 1:1
echo "lowered_from=2" > "$LG_T4R_STATE"
ok "not the logged value refused"  "$(run max_runs=3 "${W[@]}"):$(lockv)" 1:1
ok "exact lowered_from accepted"   "$(run max_runs=2 "${W[@]}"):$(lockv)" 0:2
ok "arm-time record consumed"      "$(ls "$T/.local/state/wm-build/" | grep -c armlock)" 0
ok "second restore refused"        "$(run max_runs=2 "${W[@]}")" 1
echo "pass=$pass fail=$fail"; [ "$fail" = 0 ]
