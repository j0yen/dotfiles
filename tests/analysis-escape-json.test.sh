#!/usr/bin/env bash
# analysis-escape-count.sh --json: status.json fragment + alarm threshold + failure-as-alarm.
set -u
H="$(dirname "$0")/../.local/bin/analysis-escape-count.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
chk() { [ "$2" = "$3" ] && echo "ok $1" || { echo "FAIL $1: got $2 want $3"; fail=1; }; }
printf '%s' '[{"id":"a","what":"root cause was X","why":"","evidence":""},
 {"id":"b","what":"five whys","why":"","evidence":"wiki/answers/2026-10-24-x-five-whys-rhyme.md"},
 {"id":"d","what":"set cap","why":"","evidence":""}]' >"$T/rows.json"
out=$(WM_DECIDE_JSON="$T/rows.json" "$H" --json 24h)
chk fragment "$out" '{"analysis_escapes":1,"linked":1,"rows":3,"since":"24h","alarm":true,"ids":["a"]}'
out=$(ESCAPE_ALARM_MIN=2 WM_DECIDE_JSON="$T/rows.json" "$H" --json 24h | jq -c .alarm)
chk threshold "$out" false
printf '%s' '[{"id":"d","what":"set cap","why":"","evidence":""}]' >"$T/clean.json"
out=$(WM_DECIDE_JSON="$T/clean.json" "$H" --json | jq -c '[.analysis_escapes,.alarm]')
chk clean "$out" '[0,false]'
mkdir "$T/bin"; printf '#!/bin/sh\nexit 3\n' >"$T/bin/wm-decide"; chmod +x "$T/bin/wm-decide"
out=$(PATH="$T/bin:$PATH" "$H" --json 24h); rc=$?
chk unknown "$out" '{"analysis_escapes":null,"linked":null,"rows":null,"since":"24h","alarm":true,"ids":[]}'
chk unknown_rc "$rc" 1
exit $fail
