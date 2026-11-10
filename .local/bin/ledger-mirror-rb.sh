#!/usr/bin/env bash
# ledger-mirror-rb.sh: mirror carbon's wm-decide ledger to redbaron every 10 min (ctl d-20261101-231026-controller-4bed, option a; #180 small shell).
# sqlite3 .backup -> zstd -6 -> scp the .zst as .zst.tmp -> one ssh: zstd -d to .tmp, quick_check must print ok, then mv -f (atomic).
# A failed check removes the .tmp, leaves the old mirror and exits nonzero. rb-fable-gate.py reads the mirror with a 30-min staleness refusal. (A1467)
set -euo pipefail
SRC=${LEDGER_MIRROR_SRC:-$HOME/.local/state/swarm-decide/decisions.sqlite}
HOST=${LEDGER_MIRROR_HOST:-redbaron}
DST_DIR=${LEDGER_MIRROR_DST_DIR:-'~/.local/state/swarm-decide'}
DST=decisions-carbon.sqlite
TMP=$(mktemp "${TMPDIR:-/tmp}/ledger-mirror.XXXXXX")
trap 'rm -f "$TMP" "$TMP.zst"' EXIT
sqlite3 "$SRC" ".backup '$TMP'"
zstd -q -6 -f "$TMP" -o "$TMP.zst"
scp -q -o BatchMode=yes -o ConnectTimeout=15 "$TMP.zst" "$HOST:$DST_DIR/$DST.zst.tmp"
printf -v dir_q '%q' "$DST_DIR"
printf -v dst_q '%q' "$DST"
# shellcheck disable=SC2016 # expanded on the far side
remote='d=%s; n=%s; d="${d/#\~/$HOME}"; cd "$d" || exit 1
if zstd -q -d -f "$n.zst.tmp" -o "$n.tmp" && [ "$(sqlite3 -readonly "$n.tmp" "pragma quick_check")" = ok ]; then
  rm -f "$n.zst.tmp"; mv -f "$n.tmp" "$n"
else
  rm -f "$n.zst.tmp" "$n.tmp"; echo "ledger-mirror-rb: far-side check failed" >&2; exit 1
fi'
# shellcheck disable=SC2059 # remote is the format string by design
printf -v remote_cmd "$remote" "$dir_q" "$dst_q"
ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "$remote_cmd"
echo "ledger-mirror-rb: $(date -Is) $(stat -c %s "$TMP") bytes ($(stat -c %s "$TMP.zst") zst) -> $HOST:$DST_DIR/$DST"
