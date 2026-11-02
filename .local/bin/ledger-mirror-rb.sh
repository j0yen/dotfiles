#!/usr/bin/env bash
# ledger-mirror-rb.sh: mirror carbon's wm-decide ledger to redbaron every 10 min (ctl d-20261101-231026-controller-4bed, option a; #180 small shell).
# sqlite3 .backup -> temp -> scp as .tmp -> ssh mv (atomic). rb-fable-gate.py reads the mirror with a 30-min staleness refusal.
set -euo pipefail
SRC=$HOME/.local/state/swarm-decide/decisions.sqlite
DST_DIR='~/.local/state/swarm-decide'
DST=decisions-carbon.sqlite
TMP=$(mktemp "${TMPDIR:-/tmp}/ledger-mirror.XXXXXX")
trap 'rm -f "$TMP"' EXIT
sqlite3 "$SRC" ".backup '$TMP'"
scp -q -o BatchMode=yes -o ConnectTimeout=15 "$TMP" "redbaron:$DST_DIR/$DST.tmp"
ssh -o BatchMode=yes -o ConnectTimeout=15 redbaron "mv -f $DST_DIR/$DST.tmp $DST_DIR/$DST"
echo "ledger-mirror-rb: $(date -Is) $(stat -c %s "$TMP") bytes -> redbaron:$DST_DIR/$DST"
