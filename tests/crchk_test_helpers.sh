#!/usr/bin/env bash
# tests/crchk_test_helpers.sh — shared setup for tests/crchk_ac*.test.sh
# (PRD dotfiles-config-edit-reload-check). Isolates config path, journal,
# operator cache and PATH (fake wm-build printing a canned `config effective`,
# fake systemctl answering is-active) so the hook never touches the real daemon.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/config-reload-check.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%S.%N+00:00; }

# crchk_setup — creates $work; exports the env the hook reads.
crchk_setup() {
  work="$(mktemp -d)"
  trap 'pkill -f "config-reload-check.sh --wait $work" 2>/dev/null; rm -rf "$work"' EXIT
  mkdir -p "$work/bin" "$work/cache"
  export WM_BUILD_CONFIG="$work/config.toml"; : >"$WM_BUILD_CONFIG"
  export WM_BUILD_JOURNAL="$work/journal.jsonl"
  export OPERATOR_CACHE_DIR="$work/cache"; unset OPERATOR_NOTICES_DIR
  export CRCHK_POLL=1
  export FAKE_EFFECTIVE="$work/effective.txt"
  cat >"$FAKE_EFFECTIVE" <<'TXT'
tick_interval_secs 180
max_runs 3 → 4 (reloadable)
state_dir /old/state → /new/state (restart-required)
gates 2
TXT
  cat >"$work/bin/wm-build" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "config effective" ] && cat "$FAKE_EFFECTIVE"
SH
  cat >"$work/bin/systemctl" <<'SH'
#!/usr/bin/env bash
echo "${FAKE_ACTIVE:-active}"; [ "${FAKE_ACTIVE:-active}" = active ]
SH
  chmod +x "$work/bin/wm-build" "$work/bin/systemctl"
  export PATH="$work/bin:$PATH"
  # an old tick that predates any edit: must be ignored by the waiter
  printf '{"op":"tick","row":{"admitted":[],"skipped":[],"config_loaded_at":"2020-01-01T00:00:00.000000000+00:00"},"table":"daemon","ts":"2020-01-01T00:00:00+00:00"}\n' >"$WM_BUILD_JOURNAL"
}

# append_tick ADMITTED SKIPPED — a tick row loaded just now, preceded by the
# reload rows for max_runs (the daemon logs them in the same tick).
append_tick() {
  local n=$(now_iso) a="" s="" i
  for ((i=0;i<${1:-0};i++)); do a+="${a:+,}\"a$i\""; done
  for ((i=0;i<${2:-0};i++)); do s+="${s:+,}{\"reason\":\"cap=max_runs\",\"slug\":\"s$i\"}"; done
  {
    printf '{"op":"config-reloaded","row":{"key":"max_runs","new":4,"old":3},"table":"daemon","ts":"%s"}\n' "$n"
    printf '{"op":"tick","row":{"admitted":[%s],"skipped":[%s],"config_loaded_at":"%s"},"table":"daemon","ts":"%s"}\n' "$a" "$s" "$n" "$n"
  } >>"$WM_BUILD_JOURNAL"
}

edit_payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "${1:-$WM_BUILD_CONFIG}"; }
run_hook() { "$HOOK" "$@"; }

# crchk_children_cpu_ms — sets CRCHK_CPU to the CPU ms (user+sys) of all reaped
# children of this shell. `times` runs in this shell (no command substitution:
# a subshell would report its own, empty, children).
crchk_children_cpu_ms() {
  local f="$work/times.out" l u s x t=0 m r
  times >"$f"; { read -r l; read -r u s; } <"$f"
  for x in $u $s; do # "1m2.345s" -> ms, pure bash so the probe adds no CPU of its own
    m=${x%%m*}; r=${x#*m}; r=${r%s}; t=$(( t + m*60000 + ${r%.*}*1000 + 10#${r#*.} ))
  done
  CRCHK_CPU=$t
}

# crchk_time_best_of N PAYLOAD — feeds PAYLOAD to the hook N times and sets
# CRCHK_BEST_MS / CRCHK_BEST_CPU_MS to the MINIMUM wall / CPU ms over the runs;
# CRCHK_OUT/CRCHK_RC hold the FIRST run's stdout/exit code (so "prints nothing"
# stays a single-run check). Only for idempotent payloads (a non-matching Edit
# writes no state).
#
# The property under test is "the hook CAN answer within the budget and does no
# waiting", not "one wall-clock sample is fast". On 10-23 the 50 ms assertion
# failed on a loaded host (headless verifier unit aide-verifier-df41 plus
# coders) while the same tree passed alone; min-of-N alone is not enough once
# the CPUs stay saturated (every run is slowed, 55-95 ms measured with 4 hogs
# plus concurrent suites). crchk_assert_fast therefore also accepts a run whose
# CPU time is within budget and whose wall time is at most CRCHK_LOAD_FACTOR
# (default 8) times its CPU time: contention stretches wall by a bounded
# factor, a hook that sleeps or polls (poll >= 1 s) stretches it far more.
CRCHK_MS_BUDGET="${CRCHK_MS_BUDGET:-50}"
CRCHK_LOAD_FACTOR="${CRCHK_LOAD_FACTOR:-8}"
crchk_time_best_of() {
  local n=$1 payload=$2 i start ms o rc c0 cpu
  CRCHK_BEST_MS= CRCHK_BEST_CPU_MS=
  for ((i=0;i<n;i++)); do
    crchk_children_cpu_ms; c0=$CRCHK_CPU
    start=$EPOCHREALTIME
    o=$(printf '%s' "$payload" | run_hook); rc=$?
    ms=$(( (${EPOCHREALTIME/[.,]/} - ${start/[.,]/}) / 1000 ))
    crchk_children_cpu_ms; cpu=$(( CRCHK_CPU - c0 ))
    if [ "$i" -eq 0 ]; then CRCHK_OUT=$o; CRCHK_RC=$rc; fi
    if [ -z "$CRCHK_BEST_MS" ] || [ "$ms" -lt "$CRCHK_BEST_MS" ]; then CRCHK_BEST_MS=$ms; fi
    if [ -z "$CRCHK_BEST_CPU_MS" ] || [ "$cpu" -lt "$CRCHK_BEST_CPU_MS" ]; then CRCHK_BEST_CPU_MS=$cpu; fi
  done
}

# crchk_assert_fast DESCRIPTION — after crchk_time_best_of: pass if the best
# wall time is under the budget, or (host loaded) the best CPU time is under the
# budget and wall <= CRCHK_LOAD_FACTOR x max(CPU, 1 ms).
crchk_assert_fast() {
  local w=$CRCHK_BEST_MS c=$CRCHK_BEST_CPU_MS b=$CRCHK_MS_BUDGET
  local cm=$(( c > 1 ? c : 1 ))
  if [ "$w" -lt "$b" ]; then
    echo "ok - $1: best of runs ${w} ms < ${b}"
  elif [ "$c" -lt "$b" ] && [ "$w" -le $(( cm * CRCHK_LOAD_FACTOR )) ]; then
    echo "ok - $1: loaded host, best wall ${w} ms, cpu ${c} ms (<= ${CRCHK_LOAD_FACTOR}x cpu, cpu < ${b})"
  else
    echo "NOT OK - $1: best wall ${w} ms, cpu ${c} ms (budget ${b} ms, load factor ${CRCHK_LOAD_FACTOR})"; fail=1
  fi
}

# wait_notice SECS — echoes the path of the first notices/*-config-reload.txt.
wait_notice() {
  local i f
  for ((i=0;i<${1:-30}*2;i++)); do
    f=$(ls "$OPERATOR_CACHE_DIR"/notices/*-config-reload.txt 2>/dev/null | head -n 1)
    [ -n "$f" ] && { echo "$f"; return 0; }
    sleep 0.5
  done
  return 1
}
