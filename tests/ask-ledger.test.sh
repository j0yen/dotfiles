#!/usr/bin/env bash
# ask-ledger.test.sh (A10): ask-row.py writer (atomic id, above # CLOSED, trailing newline, prose refused)
# and asks-due.py (runs checks, closes passing rows, one re-ping, 2x route to ctl, asks.json).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
W="$here/.local/bin/ask-row.py"; D="$here/.local/bin/asks-due.py"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export OPEN_ASKS="$tmp/asks.tsv" ASKS_DUE_STATE="$tmp/state" FLEET_DASH_DIR="$tmp/dash" ASK_BIN="$tmp/fake-ask"
printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$1" "$2" >>"%s/pings"\n' "$tmp" >"$tmp/fake-ask"; chmod +x "$tmp/fake-ask"
pass=0; fail=0
chk() { if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }
printf '# open asks\nA7\t2026-10-31T10:00\trb\t2026-11-01T10:00\tk\ttrue\told\n# CLOSED\nA9\tMET x\trb\t2026-11-01T10:00\tk\ttrue\tdone\n' >"$OPEN_ASKS"
id=$("$W" --owner rb --due 2026-11-01T09:00 --asked 2026-11-01T08:00 --key kk --done-check 'test -f /nonexistent-a10' --what w1)
[ "$id" = A10 ]; chk "id = max over open and closed + 1 ($id)" $?
awk '/^# CLOSED/{c=NR} /^A10\t/{r=NR} END{exit !(r && r<c)}' "$OPEN_ASKS"; chk "row inserted above # CLOSED" $?
[ -z "$(tail -c1 "$OPEN_ASKS")" ]; chk "file ends in a newline" $?
awk -F'\t' '/^A10\t/{exit NF!=7}' "$OPEN_ASKS"; chk "row has 7 columns" $?
"$W" --owner rb --due 2026-11-01T09:00 --key k --done-check 'dotfiles branch/PR' --what w >/dev/null 2>&1; [ $? = 65 ]; chk "prose done-check refused (65)" $?
"$W" --owner rb --due 2026-11-01T09:00 --key k --done-check 'true' --what $'a\tb' >/dev/null 2>&1; [ $? = 64 ]; chk "tab in a field refused (64)" $?
"$W" --owner rb --due soon --key k --done-check true --what w >/dev/null 2>&1; [ $? = 64 ]; chk "non-ISO due refused (64)" $?
for n in 1 2 3 4 5 6; do "$W" --owner r7 --due 2026-11-01T09:00 --key k --done-check true --what w$n >"$tmp/id$n" & done; wait
[ "$(cat "$tmp"/id? | sort -u | wc -l)" = 6 ]; chk "6 parallel writers get 6 unique ids" $?
# executor: A10 fails its check; pass row A20 closes
"$W" --owner aide --due 2026-11-01T09:00 --asked 2026-11-01T08:00 --key p --done-check 'true' --what passer >/dev/null
export ASKS_DUE_NOW=$(date -d 2026-11-01T10:00 +%s)
"$D"; chk "asks-due runs" $?
awk '/^# CLOSED/{c=NR} /passer \| MET/{r=NR} END{exit !(r && r>c)}' "$OPEN_ASKS"; chk "passing row moved under # CLOSED with MET tail" $?
grep -q $'^A10\t2026-11-01T08:00' "$OPEN_ASKS"; chk "failing row stays open" $?
grep -q '^rb|A10 overdue' "$tmp/pings"; chk "overdue owner pinged" $?
grep -q '^ctl|A10 ' "$tmp/pings"; chk "2x due (60 min asked->due, now +120) routed to ctl" $?
"$D"; [ "$(grep -c '^rb|A10 ' "$tmp/pings")" = 1 ]; chk "second run does not re-ping" $?
jq -e '.owners.rb.overdue>=1 and .alarm==true and .closed_this_run==0' "$tmp/dash/asks.json" >/dev/null; chk "asks.json per-owner counts + alarm" $?
[ -z "$(tail -c1 "$OPEN_ASKS")" ]; chk "ledger still ends in newline" $?
echo "ask-ledger: $pass passed, $fail failed"; [ "$fail" = 0 ]
