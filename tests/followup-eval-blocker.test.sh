#!/usr/bin/env bash
# followup-eval supported blocker (ledger ask A1346 R2): the evaluator advice names the form the canonical asks parser accepts, waits-on=row:<ids>.
# The ledger is the real pinned wm-decide asks CLI in a temp HOME (not a fixture dict): an open dependency leaves the dependent not ready, a closed one makes it ready.
# Skips (PASS-with-note) only when no asks-capable wm-decide exists on the host.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-blocker.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
EV="$here/.local/bin/followup-eval.py"
grep -q 'waits-on=row:<open-ask-id>' "$EV"; chk "1: advice names the supported waits-on=row:<open-ask-id> form" $?
! grep -q 'structured blocker (owner, dependency, next check)' "$EV"; chk "1: advice no longer advertises the unsupported dict blocker" $?
WM="$(command -v wm-decide || true)"; "$WM" asks -h 2>&1 | grep -q claim || WM="$(ls -d "$HOME"/.local/share/swarm-decide/asks-pinned/*/bin/wm-decide 2>/dev/null | tail -1)"   # resolved before HOME is swapped
if [ -z "$WM" ] || ! "$WM" asks -h 2>&1 | grep -q claim; then echo "PASS 2: no asks-capable wm-asks on this host (real-parser controls skipped)"; echo "followup-eval-blocker: $((pass+1)) PASS $fail FAIL"; [ "$fail" = 0 ]; exit; fi
mkdir -p "$base/h"; W() { HOME="$base/h" "$WM" "$@"; }
W asks add --by ctl --owner rb --due 2026-11-20T09:00 --what dependency --check true >/dev/null
W asks add --by ctl --owner ctl --due 2026-11-20T09:00 --what "dependent waits-on=row:A1" --check true >/dev/null
W asks add --by ctl --owner ctl --due 2026-11-20T09:00 --what "bare waits-on=A1" --check true >/dev/null
f() { W asks query --json --status all | jq -r --arg id "$1" '.[]|select(.ask_id==$id)|"\(.waits_on|join(","))/\(.ready)"'; }
[ "$(f A2)" = "A1/false" ]; chk "2: open dependency -> parsed waits_on=A1, not ready" $?
[ "$(f A3)" = "/false" ]; chk "2: bare waits-on=A1 is not parsed (empty waits_on)" $?
# the evaluator reading that real row stays blocked on the open dependency
W asks query --json --status all | jq -c '[.[]|select(.ask_id=="A2")]' >"$base/asks.json"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$base/asks.json" >"$base/wm-asks"; chmod +x "$base/wm-asks"
ev() { WM_ASKS_BIN="$base/wm-asks" FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_NOW="2026-11-21T12:00" python3 -I "$EV" eval --seat ctl 2>/dev/null | jq -r '.dispositions[]|select(.id=="A2")|.kind'; }
mkdir -p "$base/state"
[ "$(ev)" != "" ]; chk "2: evaluator produces a disposition for the real row" $?
# closed-dependency control: close A1 in the temp ledger (fixture state change only; the parser and ready computation stay real)
python3 -I - "$base/h/.local/state/swarm-decide/decisions.sqlite" <<'PY'
import sqlite3,sys
d=sqlite3.connect(sys.argv[1]); d.execute("UPDATE asks SET section='closed' WHERE ask_id='A1'"); d.commit()
PY
[ "$(f A2)" = "A1/true" ]; chk "3: closed dependency -> dependent ready" $?
echo "followup-eval-blocker: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
