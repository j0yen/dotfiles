#!/usr/bin/env bash
# approval-check.sh flags DUPLICATE-NUMBER and X-MINUTE-STAMP rows (both stay included);
# approve.sh numbers concurrent appends distinctly. Temp fixtures only; never the real approvals.log.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHK="${APCHECK_BIN:-$HERE/.local/bin/approval-check.sh}"
APP="${APPROVE_BIN:-$HERE/.local/bin/approve.sh}"
export TMPDIR="${TMPDIR:-/mnt/data/tmp}"
d=$(mktemp -d "$TMPDIR/apcheck-dup.XXXXXX"); trap 'rm -rf "$d"' EXIT
pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass+1)); }; bad() { echo "FAIL $1"; fail=$((fail+1)); }
t=$(date -d '10 minutes ago' '+%F %-I:%M %p %Z')

f="$d/dup.log"
{ echo '# header'; echo "#70 | $t | aide | Joe: \"seventy\" | re: a"; echo "#71 | $t | aide | Joe: \"first 71\" | re: b"; echo "#71 | $t | aide | Joe: \"second 71\" | re: c"; } > "$f"; chmod 600 "$f"
out=$(APPROVALS_FILE="$f" "$CHK")
[ "$(echo "$out" | grep -c '^age=[0-9]*m DUPLICATE-NUMBER #71 #71 | ')" = 2 ] && ok "both #71 rows flagged and present" || bad "dup: $out"
echo "$out" | grep -q '^age=[0-9]*m #70 | ' && ok "unique row not flagged" || bad "unique row: $out"

f="$d/x.log"
{ echo "#1 | 2026-10-22 2:1x PM EDT | aide | Joe: \"x\" | re: x"; echo "#2 | $t | aide | Joe: \"ok\" | re: ok"; } > "$f"; chmod 600 "$f"
out=$(APPROVALS_FILE="$f" "$CHK" --since '1 hour ago')
echo "$out" | grep -q 'X-MINUTE-STAMP #1 | .*2:1x PM' && ok "2:1x row flagged X-MINUTE-STAMP and included" || bad "xmin: $out"
echo "$out" | grep -q '^age=[0-9]*m #2 | ' && ok "normal row unflagged" || bad "normal row: $out"

f="$d/c.log"; N=8
for i in $(seq 1 $N); do
  ( APPROVALS_FILE="$f" SEAT_EVENT_BIN="$d/none" "$APP" "q$i" "re: r$i" >/dev/null 2>&1 ) &
done; wait
ids=$(grep -oE '^#[0-9]+' "$f" | tr -d '#' | sort -n | tr '\n' ' ')
[ "$ids" = "$(seq -s ' ' 1 $N) " ] && ok "concurrent appends numbered 1..$N distinct" || bad "ids: $ids"

echo "pass=$pass fail=$fail"; [ $fail -eq 0 ]
