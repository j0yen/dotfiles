#!/usr/bin/env bash
# approval-check.sh: a row whose stamp fails date -d is flagged and included in --since, never skipped.
# Fixtures are temp files only; the real approvals.log is never touched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHK="${APCHECK_BIN:-$HERE/.local/bin/approval-check.sh}"
export TMPDIR="${TMPDIR:-/mnt/data/tmp}"
d=$(mktemp -d "$TMPDIR/apcheck-unparsed.XXXXXX"); trap 'rm -rf "$d"' EXIT
pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass+1)); }; bad() { echo "FAIL $1"; fail=$((fail+1)); }
f="$d/a.log"
good_ts=$(date -d '10 minutes ago' '+%F %-I:%M %p %Z')
{ echo '# header'; echo "#1 | $good_ts | aide | Joe: \"good row\" | re: good"; echo '#2 | 2026-10-22 1:5x PM EDT | aide | Joe: "bad stamp" | re: bad'; } > "$f"
chmod 600 "$f"
out=$(APPROVALS_FILE="$f" "$CHK" --since '1 hour ago'); rc=$?
[ $rc -eq 0 ] && ok "since exit 0" || bad "since rc=$rc"
echo "$out" | grep -q '^age=? UNPARSED-STAMP #2 | .*1:5x PM' && ok "bad row prints UNPARSED-STAMP and is in --since window" || bad "bad row missing: $out"
echo "$out" | grep -q '^age=[0-9]*m #1 | .*good row' && ok "good row unchanged" || bad "good row changed: $out"
echo "$out" | grep -c UNPARSED-STAMP | grep -qx 1 && ok "good row not flagged" || bad "flag count"
out=$(APPROVALS_FILE="$f" "$CHK"); echo "$out" | grep -q 'UNPARSED-STAMP #2' && ok "no-window read includes bad row" || bad "no-window"
echo "pass=$pass fail=$fail"; [ $fail -eq 0 ]
