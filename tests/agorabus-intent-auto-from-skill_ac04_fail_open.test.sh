#!/usr/bin/env bash
# PRD agorabus-intent-auto-from-skill AC4: with no agorabus on PATH, or one
# whose daemon never answers, all three hook modes exit 0 in < 200 ms with
# empty stderr.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/agorabus-intent-auto-from-skill_test_helpers.sh"
intent_setup

# Minimal PATH: only the tools the hook needs, never agorabus.
mini="$work/mini"; mkdir -p "$mini"
for t in bash env jq cat head tr sed mkdir rm dirname basename sleep printf mkfifo kill; do
  p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$mini/$t"
done
# A "socket nobody listens on": an agorabus that blocks like an unanswered connect.
hang="$work/hang"; mkdir -p "$hang"
printf '#!/bin/sh\nexec sleep 5\n' >"$hang/agorabus"; chmod +x "$hang/agorabus"

skill_json=$(jq -cn --arg c "$cwd" '{tool_input:{skill:"dream",args:"x"},cwd:$c}')
prompt_json=$(jq -cn --arg c "$cwd" '{prompt:"/dream x",cwd:$c}')
stop_json=$(jq -cn --arg c "$cwd" '{hook_event_name:"Stop",cwd:$c}')

check() { # $1=label $2=PATH $3=json $4…=hook args
  local label="$1" path="$2" json="$3" t0 t1 ms err rc; shift 3
  t0=$(date +%s%N)
  err=$(printf '%s' "$json" | PATH="$path" "$HOOK" "$@" 2>&1 >/dev/null); rc=$?
  t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))
  assert_eq "$rc" "0" "$label: exit 0"
  assert_eq "$err" "" "$label: empty stderr"
  [ "$ms" -lt 200 ] && echo "ok - $label: ${ms}ms < 200ms" || { echo "NOT OK - $label: ${ms}ms"; fail=1; }
}

for env in "no-binary:$mini" "dead-daemon:$hang:$mini"; do
  label=${env%%:*}; path=${env#*:}
  check "$label skill" "$path" "$skill_json"
  check "$label prompt" "$path" "$prompt_json"
  # Stop only does work after a start; the start above left state behind in the hang case.
  printf 'dream\n' >"$AGORABUS_INTENT_STATE_DIR/intent-$sid.state"
  check "$label stop" "$path" "$stop_json" stop
done
exit $fail
