#!/usr/bin/env bash
# seat-owed.sh (A49 D1): per-seat owed/overdue lines from a stubbed wm-decide + fixture open-asks, and the seat-context-start.sh wiring.
# shellcheck disable=SC2319  # chk NAME $? deliberately reads the preceding test
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
helper="$here/.local/bin/seat-owed.sh"
hook="$here/.claude/hooks/seat-context-start.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
H="$tmp/home"; mkdir -p "$H/.local/bin"
pass=0; fail=0
chk() { if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

cat >"$tmp/wmd-ok" <<'STUB'
#!/usr/bin/env bash
[ "$1" = followups ] && [ "$2" = --json ] || exit 2
printf '%s\n' "$*" >"${ARGV_LOG:-/dev/null}"
echo '{"by_agent":{"rb":3},"escalated":1,"ids":[{"age_h":50.1,"id":"d-20261024-004131-rb-b354","owner":"rb","state":"escalated"},{"age_h":40.0,"id":"d-20261025-000000-rb-aaaa","owner":"rb","state":"provisional"},{"age_h":30.0,"id":"d-20261026-000000-rb-bbbb","owner":"rb","state":"provisional"}],"oldest":"d-20261024-004131-rb-b354","overdue":1,"owed":3}'
STUB
cat >"$tmp/wmd-empty" <<'STUB'
#!/usr/bin/env bash
echo '{"by_agent":{},"escalated":0,"ids":[],"oldest":null,"overdue":0,"owed":0}'
STUB
cat >"$tmp/wmd-nofilter" <<'STUB'
#!/usr/bin/env bash
echo '{"by_agent":{"r7":9,"rb":2},"escalated":2,"ids":[{"age_h":9,"id":"d-r7-1","owner":"r7","state":"escalated"},{"age_h":8,"id":"d-rb-1","owner":"rb","state":"provisional"},{"age_h":7,"id":"d-rb-2","owner":"rb","state":"escalated"}],"oldest":"d-r7-1","overdue":2,"owed":11}'
STUB
cat >"$tmp/wmd-fail" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$tmp/wmd-ok" "$tmp/wmd-fail" "$tmp/wmd-empty" "$tmp/wmd-nofilter"
past=$(date -d '2 hours ago' -Iseconds); future=$(date -d '2 hours' -Iseconds)
printf '%s\n' '# open asks' \
  "A1	OPEN	rb	$past	check" \
  "A2	MET	rb	$past	check" \
  "A3	OPEN	rb	$future	check" \
  "A4	OPEN	r7	$past	check" \
  '# CLOSED' \
  "A5	OPEN	rb	$past	check" >"$tmp/asks.tsv"

out=$(WM_DECIDE_BIN="$tmp/wmd-ok" OPEN_ASKS="$tmp/asks.tsv" bash "$helper" rb); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | sed -n 1p)" = 'OWED rb: owed 3, overdue 1, escalated 1, oldest d-20261024-004131-rb-b354' ] \
  && [ "$(printf '%s\n' "$out" | sed -n 2p)" = 'OVERDUE rb: d-20261024-004131-rb-b354 d-20261025-000000-rb-aaaa d-20261026-000000-rb-bbbb' ]; chk "(a) rb owed 3 overdue 1: OWED and OVERDUE lines exact" $?
[ "$(printf '%s\n' "$out" | sed -n 3p)" = 'ASKS rb: overdue A1' ] && [ "$(printf '%s\n' "$out" | wc -l)" = 3 ]; chk "(b) ASKS lists the past-due open row only (MET, future, below # CLOSED, other owner skipped)" $?
out=$(WM_DECIDE_BIN="$tmp/wmd-empty" OPEN_ASKS="$tmp/asks.tsv" bash "$helper" r7)
[ "$(printf '%s\n' "$out" | sed -n 1p)" = 'OWED r7: owed 0, overdue 0, escalated 0, oldest none' ] && [ "$(printf '%s\n' "$out" | sed -n 2p)" = 'ASKS r7: overdue A4' ]; chk "(a) r7 empty ledger: zero line, no OVERDUE line" $?
out=$(WM_DECIDE_BIN="$tmp/wmd-fail" OPEN_ASKS="$tmp/asks.tsv" bash "$helper" rb); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | head -1 | grep -q '^OWED rb: unknown (' && printf '%s\n' "$out" | grep -q '^ASKS rb: overdue A1$'; chk "(c) stub exit 1: 'unknown (' line, ASKS still printed, exit 0" $?
out=$(WM_DECIDE_BIN="$tmp/none" OPEN_ASKS="$tmp/asks.tsv" bash "$helper" rb); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | head -1 | grep -q '^OWED rb: unknown (wm-decide missing'; chk "(c) missing binary: unknown line, exit 0" $?

out=$(WM_DECIDE_BIN="$tmp/wmd-nofilter" OPEN_ASKS=/nonexistent bash "$helper" rb)
[ "$(printf '%s\n' "$out" | sed -n 1p)" = 'OWED rb: owed 2, overdue 1, escalated 1, oldest d-rb-1' ] && [ "$(printf '%s\n' "$out" | sed -n 2p)" = 'OVERDUE rb: d-rb-2 d-rb-1' ]; chk "(e) stub ignores --agent: ids filtered to owner rb, escalated first" $?
ARGV_LOG="$tmp/argv" WM_DECIDE_BIN="$tmp/wmd-ok" OPEN_ASKS=/nonexistent bash "$helper" ctl >"$tmp/ctl.out"
[ "$(cat "$tmp/argv")" = 'followups --json --agent controller' ] && head -1 "$tmp/ctl.out" | grep -q '^OWED ctl: owed '; chk "(f) ctl maps to --agent controller, label stays ctl" $?
ARGV_LOG="$tmp/argv" WM_DECIDE_BIN="$tmp/wmd-ok" OPEN_ASKS=/nonexistent bash "$helper" rb >/dev/null
[ "$(cat "$tmp/argv")" = 'followups --json --agent rb' ]; chk "(f) rb passes --agent rb" $?
printf '%s' '{"by_agent":{}}' >"$tmp/nokey.json"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$tmp/nokey.json" >"$tmp/wmd-nokey"; chmod +x "$tmp/wmd-nokey"
WM_DECIDE_BIN="$tmp/wmd-nokey" OPEN_ASKS=/nonexistent bash "$helper" rb | grep -q '^OWED rb: unknown (no owed'; chk "(g) JSON without owed: unknown line" $?

cp "$helper" "$H/.local/bin/seat-owed.sh"
out=$(HOME="$H" WM_SEAT=rb TMUX='' WM_DECIDE_BIN="$tmp/wmd-ok" OPEN_ASKS="$tmp/asks.tsv" bash "$hook" </dev/null 2>/dev/null)
printf '%s\n' "$out" | grep -qx 'OWED rb: owed 3, overdue 1, escalated 1, oldest d-20261024-004131-rb-b354'; chk "(d) WM_SEAT=rb: seat-context-start.sh prints the OWED line" $?
out=$(env -u WM_SEAT -u TMUX HOME="$H" WM_DECIDE_BIN="$tmp/wmd-ok" OPEN_ASKS="$tmp/asks.tsv" bash "$hook" </dev/null 2>/dev/null)
! printf '%s\n' "$out" | grep -q '^OWED'; chk "(d) WM_SEAT unset: no OWED line" $?
echo "seat-owed: $pass passed, $fail failed"
[ "$fail" = 0 ]
