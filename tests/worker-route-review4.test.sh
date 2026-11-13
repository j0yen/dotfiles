#!/usr/bin/env bash
# worker-route-review4.test.sh: review-4 repair (R4-1..R4-5, seams, m11). Runs (1) the production-entrypoint seam proof (the real .local/bin/worker-route.py as __main__, every seam
# env var forged with and without WR_TEST_SEAMS), (2) the reviewer's own seams probe, (3) the retained review-4 probe rows p01-p15, (4) the same-author R4-3/R4-4/R4-5/m11 tests.
# Fake worlds only; HOME and every world under a scratch root outside /tmp; no real wm-asks, claim, systemd, tmux or ledger. Fixtures do not prove installed behaviour.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scratch.sh"; T="$(wr_scratch)" || exit 64; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" WR_PROBE_BASE="$T/probes"; mkdir -p "$HOME" "$WR_PROBE_BASE"
fails=0
P="$HERE/seatret-probes/review4"
RH="$(python3 -I -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)')/.local/state/worker-route"; [ -e "$RH" ] && had_real=1 || had_real=0     # the REAL worker-route state dir: this script must never create it
# no probe may reach the real systemd-run / systemctl: recording stubs first on PATH (the seams probe's begin_start calls the DEFAULT start client when the forged WR_START_CMD is not honoured)
mkdir -p "$T/stubs"; printf '#!/bin/sh\necho "$*" >> "%s/sdrun.log"\nexit 0\n' "$T" > "$T/stubs/systemd-run"; printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\nexit 3\n' "$T" > "$T/stubs/systemctl"; chmod 755 "$T/stubs/"*; export PATH="$T/stubs:$PATH"
python3 -I "$P/prod_entry.py" || fails=$((fails+1))
python3 -I "$P/seams.py" > "$T/seams.out" 2>"$T/seams.err"; rcs=$?
if [ "$rcs" = 0 ] && python3 -I - "$T/seams.out" <<'PY'
import json, sys
j = json.loads([l for l in open(sys.argv[1]) if l.startswith('{"ASKS_CMD"')][0])
ok = (j["WR_START_CMD_honoured_without_seams"] is False and j["unit_probe_argv0_without_seams"] == ["systemctl", "--user", "show"] and j["passwd_home"] and not j["HOME_env_used"] and not j["HOST_is_env"]
      and j["ASKS_CMD"] is None and j["LAUNCHERS"] == ["rb-coder-launch.sh", "r7-run-coder.sh", "rb-run-coder.sh"] and j["ASKS_TIMEOUT"] == 120.0 and j["BINDING"].endswith("/.local/state/worker-route/asks-binding.json"))
sys.exit(0 if ok else 1)
PY
then if [ "$(wc -l < "$T/sdrun.log" 2>/dev/null || echo 0)" = 1 ]; then echo "PASS review-4 seams probe (module imported without the switch, every seam env var forged): the start client is NOT honoured (the default systemd-run stub ran once), every constant at its fixed value"; else echo "FAIL review-4 seams probe: default start client not run exactly once ($(cat "$T/sdrun.log" 2>/dev/null | wc -l))"; fails=$((fails+1)); fi; else echo "FAIL review-4 seams probe: rc=$rcs $(tail -c 400 "$T/seams.out") $(tail -c 300 "$T/seams.err")"; fails=$((fails+1)); fi
python3 -I "$P/expect4.py" || fails=$((fails+1))
python3 -I "$P/r4_own.py" || fails=$((fails+1))
if [ "$had_real" = 0 ] && [ -e "$RH" ]; then echo "FAIL a probe created the real passwd-home state dir $RH"; fails=$((fails+1)); else echo "PASS no probe created the real passwd-home worker-route state dir"; fi
[ -e "$T/systemctl.log" ] && { echo "FAIL a probe reached the default systemctl: $(head -c 200 "$T/systemctl.log")"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
