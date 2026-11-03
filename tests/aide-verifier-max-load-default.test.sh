#!/usr/bin/env bash
# tests/aide-verifier-max-load-default.test.sh (A650 rb 11-02): the aide-verifier load gate default is 2 x nproc, and caps.tsv row C186 names the same value and line.
# The old default nproc - 3 (5 on carbon's 8 threads) never admitted at carbon's normal load 7.5-12, so verifier launches queued behind launch.lock.
set -u
here=$(cd "$(dirname "$0")/.." && pwd); s="$here/.local/bin/aide-verifier.sh"; c="$here/.config/fleet/caps.tsv"; fail=0
ln=$(grep -n 'max_load=$(( $(nproc 2>/dev/null || echo 4) \* 2 ))' "$s" | cut -d: -f1)
[ -n "$ln" ] && echo "PASS: default = 2 x nproc at aide-verifier.sh:$ln" || { echo "FAIL: aide-verifier.sh default is not \$(( \$(nproc) * 2 ))"; fail=1; }
! grep -q 'echo 4) - 3 ))' "$s" && echo "PASS: old nproc - 3 default gone" || { echo "FAIL: nproc - 3 default still present"; fail=1; }
row=$(grep -P '^C186\t' "$c")
[[ "$row" == *$'\t''2 × nproc'* ]] && echo "PASS: caps C186 value 2 × nproc" || { echo "FAIL: caps C186 value"; fail=1; }
[ -n "$ln" ] && [[ "$row" == *"aide-verifier.sh:$ln"$'\t'* ]] && echo "PASS: caps C186 enforced_at = aide-verifier.sh:$ln" || { echo "FAIL: caps C186 enforced_at does not name aide-verifier.sh:$ln"; fail=1; }
exit $fail
