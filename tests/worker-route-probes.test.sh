#!/usr/bin/env bash
# worker-route-probes.test.sh: the independent reviewer's review-2 probes (tests/seatret-probes/, copied from S/in/review2-probes, repointed at this clone,
# with a unit-probe stub and the entrypoint binding added) retained as regression tests against the repaired route. Fake worlds only; HOME and every world
# live under a temp dir; no real wm-asks, claim, systemd or ledger. Fixtures do not prove installed behaviour.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" WR_PROBE_BASE="$T/probes"; mkdir -p "$HOME" "$WR_PROBE_BASE"
fails=0
python3 -I "$HERE/seatret-probes/probe_addendum.py" > "$WR_PROBE_BASE/probe_addendum.out" 2>&1; rc1=$?
python3 -I "$HERE/seatret-probes/probe_f.py" > "$WR_PROBE_BASE/probe_f.out" 2>&1; rc2=$?
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ]; then echo "PASS probes ran (addendum + F1) without error"; else echo "FAIL probes ran: rc $rc1 $rc2"; tail -n 5 "$WR_PROBE_BASE/probe_addendum.out" "$WR_PROBE_BASE/probe_f.out"; fails=$((fails+1)); fi
if python3 -I "$HERE/seatret-probes/expect.py"; then :; else fails=$((fails+1)); fi
[ -s "$WR_PROBE_BASE/probe_addendum.json" ] || { echo "FAIL no probe output"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
