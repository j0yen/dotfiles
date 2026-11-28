#!/usr/bin/env bash
# Regression (A1235): a ledger edit is durable only if wm-decide asks holds the same ids; an import failure or id mismatch rolls the TSV back.
set -u; D="$(mktemp -d)"; f=0; T="$(cd "$(dirname "$0")/.." && pwd)/.local/bin/ctl-ledger-txn.sh"
printf 'A1\t2026-11-07T10:00\tctl\t2099-01-01T00:00\twhat\tc\twaits-on=x\n# CLOSED\n' > "$D/l.tsv"; cp "$D/l.tsv" "$D/l.orig"; : > "$D/canon"
printf '#!/bin/sh\ncat "$1" > %s/canon\n' "$D" > "$D/imp-ok"; printf '#!/bin/sh\nexit 1\n' > "$D/imp-bad"
printf '#!/bin/sh\ncat %s/canon\n' "$D" > "$D/lst"; printf '#!/bin/sh\ncat "$1" > /dev/null\n' > "$D/imp-lossy"
printf 'print("# rows checked: 1; violations: 0")\n' > "$D/val.py"; chmod +x "$D"/imp-* "$D/lst"
run() { LEDGER="$D/l.tsv" LEDGER_VALIDATE="$D/val.py" ASKS_IMPORT_CMD="$1" ASKS_LIST_CMD="$D/lst" bash "$T" add 2099-02-02T00:00 w c "waits-on=y" >"$D/out" 2>&1; }
ck() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; f=1; fi; }
run "$D/imp-bad"; cmp -s "$D/l.tsv" "$D/l.orig"; ck "import failure restores the TSV" $?
run "$D/imp-lossy"; cmp -s "$D/l.tsv" "$D/l.orig"; ck "canonical id mismatch restores the TSV" $?
run "$D/imp-ok"; [ "$(grep -c '^A[0-9]' "$D/l.tsv")" = 2 ] && [ "$(grep -c '^A[0-9]' "$D/canon")" = 2 ]; ck "success: TSV and canonical both hold the new row" $?
LEDGER="$D/l.tsv" LEDGER_VALIDATE="$D/val.py" ASKS_IMPORT_CMD="$D/imp-ok" ASKS_LIST_CMD="$D/lst" bash "$T" claim A1 worker-x >/dev/null 2>&1; grep -q "^A1.*claim=worker-x@" "$D/l.tsv" && grep -q "claim=worker-x" "$D/canon"; ck "claim stamps the row in TSV and canonical" $?
LEDGER="$D/l.tsv" LEDGER_VALIDATE="$D/val.py" ASKS_IMPORT_CMD="$D/imp-ok" ASKS_LIST_CMD="$D/lst" bash "$T" claim A1 worker-y >/dev/null 2>&1; [ $? != 0 ]; ck "second claim refused" $?
echo "pass/fail f=$f"; exit $f
