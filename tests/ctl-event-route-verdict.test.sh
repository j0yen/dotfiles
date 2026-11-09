#!/usr/bin/env bash
# A1307: the router's verifier classifier takes the verdict from the LAST `VERDICT:` line (else the last line that leads with a
# terminal token), never from a 'FAIL' substring in prose. Stub: wm-asks (WM_ASKS_CMD). No model call is reachable on these paths.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
R="$root/.local/bin/ctl-event-route.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
f=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; f=1; fi; }
printf '#!/bin/sh\n[ "$2" = query ] && { echo "[]"; exit 0; }\nif [ "$2" = add ]; then echo A9999; echo add >> %s/adds.$$; exit 0; fi\nexit 0\n' "$T" > "$T/wm-asks"; chmod +x "$T/wm-asks"
mkdir -p "$T/av"
art() { python3 -I -c 'import json,sys; json.dump({"is_error":False,"subtype":"success","result":sys.argv[2]},open(sys.argv[1],"w"))' "$T/av/$1.json" "$2"; }
art merge $'Checked: the gate did not FAIL, no FAIL rows, nothing GATED.\nMERGE-OK PR 321 merged on d-20261108-041309-aide-80b5'
art verd $'earlier line said FAIL once\nVERDICT: CONFIRM'
art realfail $'all checks ran\nVERDICT: FAIL (AC3 red)'
art prose $'The previous attempt was a FAIL but it is fixed now.\nVERDICT: PASS'
route() { # route <name> -> router JSON on stdout
  local n="$1"; local q="$T/q-$n.json"
  echo "{\"id\":\"ev-$n\",\"event\":{\"event\":\"verifier\",\"ts\":\"t\",\"detail\":{\"files\":[\"$T/av/$n.json\"]}}}" > "$q"
  env -i HOME="$T" PATH="$PATH" RT_DIR="$T/rt" WM_ASKS_CMD="$T/wm-asks" bash "$R" route "$q" 2>/dev/null
}
adds() { ls "$T"/adds.* 2>/dev/null | wc -l; }
out="$(route merge)"; a=$(adds)
grep -q '"outcome": \["MERGE-OK"\]' <<<"$out" && grep -q '"exit": 0' <<<"$out"; chk "MERGE-OK with FAIL/GATED in prose: outcome MERGE-OK, exit 0" $?
[ "$a" = 0 ]; chk "no ledger row opened for MERGE-OK" $?
out="$(route verd)"
grep -q '"outcome": \["CONFIRM"\]' <<<"$out"; chk "last VERDICT line wins over earlier FAIL text" $?
out="$(route prose)"
grep -q '"outcome": \["PASS"\]' <<<"$out" && [ "$(adds)" = 0 ]; chk "VERDICT: PASS after a FAIL sentence: record, no row" $?
out="$(route realfail)"
grep -q '"outcome": \["FAIL"\]' <<<"$out" && [ "$(adds)" = 1 ]; chk "genuine VERDICT: FAIL still surfaces a row" $?
echo "ctl-event-route-verdict test: $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
