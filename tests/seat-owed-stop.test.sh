#!/usr/bin/env bash
# seat-owed-stop.sh (A49 D2): Stop hook blocks on uncited overdue ids, using a stub seat-owed.sh on PATH.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/seat-owed-stop.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
pass=0; fail=0
chk() { if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

cat >"$tmp/bin/seat-owed.sh" <<'STUB'
#!/usr/bin/env bash
echo "OWED $1: owed 3, overdue 2, escalated 1, oldest d-20261024-004131-rb-b354"
echo "OVERDUE $1: d-20261024-004131-rb-b354 d-20261025-000000-rb-aaaa d-20261026-000000-rb-bbbb"
STUB
chmod +x "$tmp/bin/seat-owed.sh"
run() { # run <seat|-> <message> -> stdout in $tmp/out, stderr in $tmp/err
  local seat="$1" msg="$2" payload
  payload=$(jq -nc --arg m "$msg" '{hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$m}')
  if [ "$seat" = - ]; then
    env -u WM_SEAT PATH="$tmp/bin:$PATH" HOME="$tmp/home" bash "$hook" <<<"$payload" >"$tmp/out" 2>"$tmp/err"
  else
    WM_SEAT="$seat" PATH="$tmp/bin:$PATH" HOME="$tmp/home" bash "$hook" <<<"$payload" >"$tmp/out" 2>"$tmp/err"
  fi
}

run rb "all done"
grep -q '"decision":"block"' "$tmp/out" && grep -q 'd-20261024-004131-rb-b354' "$tmp/out" && grep -q 'd-20261025-000000-rb-aaaa' "$tmp/out" && ! grep -q 'rb-bbbb' "$tmp/out"; chk "a: uncited overdue ids block and are named (only the first overdue M)" $?
[ "$(wc -l <"$tmp/out")" = 1 ]; chk "a: reason is one line" $?

run rb "cleared d-20261024-004131-rb-b354 and d-20261025-000000-rb-aaaa"
[ ! -s "$tmp/out" ]; chk "b: full ids cited -> allowed" $?

run rb "done. FOLLOWUPS rb owed 3->1"
[ ! -s "$tmp/out" ]; chk "b2: cleared marker -> allowed" $?

run rb "cleared d-20261024-004131-rb-b354"
grep -q 'rb-aaaa' "$tmp/out"; chk "b3: partially cited -> still blocked on the missing id" $?

run - "all done"
[ ! -s "$tmp/out" ]; chk "c: no WM_SEAT -> allowed" $?

run coder "all done"
[ ! -s "$tmp/out" ]; chk "c2: non-seat WM_SEAT -> allowed" $?

printf '#!/usr/bin/env bash\nexit 3\n' >"$tmp/bin/seat-owed.sh"
run rb "all done"
[ ! -s "$tmp/out" ] && grep -q 'exit 3' "$tmp/err"; chk "d: seat-owed.sh non-zero -> allowed with stderr warning" $?

rm -f "$tmp/bin/seat-owed.sh"
run rb "all done"
[ ! -s "$tmp/out" ] && grep -q 'not found' "$tmp/err"; chk "d2: seat-owed.sh missing -> allowed with warning" $?

echo "seat-owed-stop: $pass passed, $fail failed"
[ "$fail" = 0 ] && echo "PASS seat-owed-stop" || { echo "FAIL seat-owed-stop"; exit 1; }
