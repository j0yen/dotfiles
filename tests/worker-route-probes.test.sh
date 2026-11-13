#!/usr/bin/env bash
# worker-route-probes.test.sh: the independent reviewer's review-2 probes (tests/seatret-probes/, copied from S/in/review2-probes, repointed at this clone,
# with a unit-probe stub and the entrypoint binding added) retained as regression tests against the repaired route. Fake worlds only; HOME and every world
# live under a temp dir; no real wm-asks, claim, systemd or ledger. Fixtures do not prove installed behaviour.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scratch.sh"; T="$(wr_scratch)" || exit 64; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" WR_PROBE_BASE="$T/probes"; mkdir -p "$HOME" "$WR_PROBE_BASE"
fails=0
# R3-5: a systemctl on PATH that logs: the probes must never reach the default unit-probe client (every world sets the WR_UNIT_PROBE seam)
mkdir -p "$T/forbid"; printf '#!/usr/bin/env bash\necho "systemctl $*" >> "%s/forbidden.log"\nexit 0\n' "$T" > "$T/forbid/systemctl"; chmod 755 "$T/forbid/systemctl"; export PATH="$T/forbid:$PATH"
python3 -I "$HERE/seatret-probes/probe_addendum.py" > "$WR_PROBE_BASE/probe_addendum.out" 2>&1; rc1=$?
python3 -I "$HERE/seatret-probes/probe_f.py" > "$WR_PROBE_BASE/probe_f.out" 2>&1; rc2=$?
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ]; then echo "PASS probes ran (addendum + F1) without error"; else echo "FAIL probes ran: rc $rc1 $rc2"; tail -n 5 "$WR_PROBE_BASE/probe_addendum.out" "$WR_PROBE_BASE/probe_f.out"; fails=$((fails+1)); fi
if python3 -I "$HERE/seatret-probes/expect.py"; then :; else fails=$((fails+1)); fi
if [ -s "$T/forbidden.log" ]; then echo "FAIL a probe reached the default systemctl unit probe"; fails=$((fails+1)); else echo "PASS no probe called systemctl"; fi
[ -s "$WR_PROBE_BASE/probe_addendum.json" ] || { echo "FAIL no probe output"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
