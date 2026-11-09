#!/usr/bin/env bash
# followup-eval supported blocker (ledger ask A1346 R2): the evaluator advice names the form the canonical asks parser accepts, waits-on=row:<ids>.
# The ledger is the real pinned wm-decide asks CLI in a temp HOME (no dict fixture). The evaluator reads that ledger's own open-row query before and after the
# dependency closes: open owned dependency -> structured-blocker (blocked, not actionable); closed dependency -> dependency-cleared (ready); a bare waits-on=A1 is never a dependency.
# A missing real parser is a FAILURE, not a skip. Discriminating control: the same row with its parsed waits_on removed must not read dependency-open.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-blocker.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
EV="$here/.local/bin/followup-eval.py"
grep -q 'waits-on=row:<open-ask-id>' "$EV"; chk "1: advice names the supported waits-on=row:<open-ask-id> form" $?
! grep -q 'structured blocker (owner, dependency, next check)' "$EV"; chk "1: advice no longer advertises the unsupported dict blocker" $?
WM="$(command -v wm-decide || true)"; { [ -n "$WM" ] && "$WM" asks -h 2>&1 | grep -q claim; } || WM="$(ls -d "$HOME"/.local/share/swarm-decide/asks-pinned/*/bin/wm-decide 2>/dev/null | tail -1)"   # resolved before HOME is swapped
{ [ -n "$WM" ] && "$WM" asks -h 2>&1 | grep -q claim; }; chk "2: a real asks-capable parser is available (missing parser = FAIL, not skip)" $?
[ -n "$WM" ] || { echo "followup-eval-blocker: $pass PASS $fail FAIL"; exit 1; }
mkdir -p "$base/h" "$base/state"; W() { HOME="$base/h" "$WM" "$@"; }
W asks add --by ctl --owner rb --due 2026-11-30T09:00 --what dependency --check true >/dev/null
W asks add --by ctl --owner ctl --due 2026-11-20T09:00 --what "dependent waits-on=row:A1" --check true >/dev/null
W asks add --by ctl --owner ctl --due 2026-11-20T09:00 --what "bare waits-on=A1" --check true >/dev/null
DB="$base/h/.local/state/swarm-decide/decisions.sqlite"
f() { W asks query --json --status all | jq -r --arg id "$1" '.[]|select(.ask_id==$id)|"\(.waits_on|join(","))/\(.ready)"'; }
snap() { W asks query --json --status open >"$base/asks.json"; }   # evaluator input = the real open-row query of the temp ledger, every row kept
printf '#!/usr/bin/env bash\ncat "%s"\n' "$base/asks.json" >"$base/wm-asks"; chmod +x "$base/wm-asks"
ev() { WM_ASKS_BIN="$base/wm-asks" FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_NOW="2026-11-21T12:00" python3 -I "$EV" eval --seat ctl 2>/dev/null | jq -r --arg id "$1" '.dispositions[]|select(.id==$id)|.kind+"/"+(.actionable|tostring)'; }
[ "$(f A2)" = "A1/false" ]; chk "3: open dependency -> real parser gives waits_on=A1, ready=false" $?
[ "$(f A3)" = "/false" ]; chk "3: bare waits-on=A1 is not parsed (empty waits_on)" $?
snap
[ "$(ev A2)" = "structured-blocker/false" ]; chk "4: evaluator on the real open-row query: A2 = blocked on the open owned dependency (structured-blocker), not actionable" $?
[ "$(ev A3)" != "structured-blocker/false" ] && [ -n "$(ev A3)" ]; chk "4: bare waits-on row is never blocked on A1" $?
jq '[.[]|select(.ask_id!="A1")|if .ask_id=="A2" then .waits_on=[] else . end]' "$base/asks.json" >"$base/asks.broken.json"
cp "$base/asks.json" "$base/asks.keep.json"; cp "$base/asks.broken.json" "$base/asks.json"
[ "$(ev A2)" != "structured-blocker/false" ] && [ -n "$(ev A2)" ]; chk "5: broken control (waits_on removed): A2 no longer reads blocked, so the assertion discriminates" $?
python3 -I - "$DB" <<'PY'
import sqlite3,sys
d=sqlite3.connect(sys.argv[1]); d.execute("UPDATE asks SET section='closed' WHERE ask_id='A1'"); d.commit()
PY
[ "$(f A2)" = "A1/true" ]; chk "6: closed dependency -> real parser ready=true" $?
snap
! jq -e '.[]|select(.ask_id=="A1")' "$base/asks.json" >/dev/null; chk "6: refreshed evaluator input no longer holds A1" $?
[ "$(ev A2)" = "dependency-cleared/true" ]; chk "6: evaluator after refresh: A2 = dependency-cleared, actionable" $?
echo "followup-eval-blocker: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
