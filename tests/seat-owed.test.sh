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
echo '{"per_agent":{"rb":{"owed":3,"overdue":1,"oldest":"d-aaaa1111bbbb","overdue_ids":["d-aaaa1111bbbb"]},"r7":{"owed":0,"overdue":0}}}'
STUB
cat >"$tmp/wmd-fail" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$tmp/wmd-ok" "$tmp/wmd-fail"
past=$(date -d '2 hours ago' -Iseconds); future=$(date -d '2 hours' -Iseconds)
printf '%s\n' '# open asks' \
  "A1	OPEN	rb	$past	check" \
  "A2	MET	rb	$past	check" \
  "A3	OPEN	rb	$future	check" \
  "A4	OPEN	r7	$past	check" \
  '# CLOSED' \
  "A5	OPEN	rb	$past	check" >"$tmp/asks.tsv"

out=$(WM_DECIDE_BIN="$tmp/wmd-ok" OPEN_ASKS="$tmp/asks.tsv" bash "$helper" rb); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | sed -n 1p)" = 'OWED rb: owed 3, overdue 1, oldest d-aaaa1111bbbb' ] \
  && [ "$(printf '%s\n' "$out" | sed -n 2p)" = 'OVERDUE rb: d-aaaa1111bbbb' ]; chk "(a) rb owed 3 overdue 1: OWED and OVERDUE lines exact" $?
[ "$(printf '%s\n' "$out" | sed -n 3p)" = 'ASKS rb: overdue A1' ] && [ "$(printf '%s\n' "$out" | wc -l)" = 3 ]; chk "(b) ASKS lists the past-due open row only (MET, future, below # CLOSED, other owner skipped)" $?
out=$(WM_DECIDE_BIN="$tmp/wmd-ok" OPEN_ASKS="$tmp/asks.tsv" bash "$helper" r7)
[ "$(printf '%s\n' "$out" | sed -n 1p)" = 'OWED r7: owed 0, overdue 0, oldest none' ] && [ "$(printf '%s\n' "$out" | sed -n 2p)" = 'ASKS r7: overdue A4' ]; chk "(a) r7 filter picks the r7 entry" $?
out=$(WM_DECIDE_BIN="$tmp/wmd-fail" OPEN_ASKS="$tmp/asks.tsv" bash "$helper" rb); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | head -1 | grep -q '^OWED rb: unknown (' && printf '%s\n' "$out" | grep -q '^ASKS rb: overdue A1$'; chk "(c) stub exit 1: 'unknown (' line, ASKS still printed, exit 0" $?
out=$(WM_DECIDE_BIN="$tmp/none" OPEN_ASKS="$tmp/asks.tsv" bash "$helper" rb); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | head -1 | grep -q '^OWED rb: unknown (wm-decide missing'; chk "(c) missing binary: unknown line, exit 0" $?

cp "$helper" "$H/.local/bin/seat-owed.sh"
out=$(HOME="$H" WM_SEAT=rb TMUX='' WM_DECIDE_BIN="$tmp/wmd-ok" OPEN_ASKS="$tmp/asks.tsv" bash "$hook" </dev/null 2>/dev/null)
printf '%s\n' "$out" | grep -qx 'OWED rb: owed 3, overdue 1, oldest d-aaaa1111bbbb'; chk "(d) WM_SEAT=rb: seat-context-start.sh prints the OWED line" $?
out=$(env -u WM_SEAT -u TMUX HOME="$H" WM_DECIDE_BIN="$tmp/wmd-ok" OPEN_ASKS="$tmp/asks.tsv" bash "$hook" </dev/null 2>/dev/null)
! printf '%s\n' "$out" | grep -q '^OWED'; chk "(d) WM_SEAT unset: no OWED line" $?
echo "seat-owed: $pass passed, $fail failed"
[ "$fail" = 0 ]
