#!/usr/bin/env bash
# worker-route-review3.test.sh: the independent reviewer's review-3 probes (tests/seatret-probes/review3/, copied from S/in/review3-probes, repointed at this clone,
# explicit test switch added) retained as regression tests. Fake worlds only; scratch off /tmp; no real wm-asks, claim, systemd or ledger.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scratch.sh"
T="$(wr_scratch)" || exit 64; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" WR_PROBE_BASE="$T/probes"; mkdir -p "$HOME" "$WR_PROBE_BASE"
fails=0
for n in 1 2 3; do
  f="own_probes.py"; [ "$n" = 2 ] && f="own_probes2.py"; [ "$n" = 3 ] && f="own_probes3.py"
  PROBE_TAG="r3$n" python3 -I "$HERE/seatret-probes/review3/$f" > "$WR_PROBE_BASE/out-own$n.jsonl" 2> "$WR_PROBE_BASE/err-own$n.txt"; rc=$?
  if [ "$rc" = 0 ]; then echo "PASS review-3 probe script $f ran"; else echo "FAIL review-3 probe script $f ran: rc $rc"; tail -n 5 "$WR_PROBE_BASE/err-own$n.txt"; fails=$((fails+1)); fi
done
if python3 -I "$HERE/seatret-probes/review3/expect3.py"; then :; else fails=$((fails+1)); fi
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
