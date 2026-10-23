#!/usr/bin/env bash
# gate-wait-minutes.py: the in-script --selftest passes under a throwaway HOME and leaves the real state path alone;
# the committed rb-gate-wait unit/timer match what the script's default window needs (no fixed --since, no drop-in).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
S="$here/.local/bin/gate-wait-minutes.py"
fail=0
H="$(mktemp -d)"; trap 'rm -rf -- "${H:?}"' EXIT
out="$(HOME="$H" python3 -I "$S" --selftest 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'SELFTEST PASS'; then echo "ok - --selftest prints SELFTEST PASS (rc 0)"
else echo "NOT OK - --selftest rc=$rc: $(printf '%s\n' "$out" | tail -n 3)"; fail=1; fi
if [ ! -e "$H/.local/state/rb-gate-wait" ]; then echo "ok - --selftest wrote nothing under the default state dir"
else echo "NOT OK - --selftest created $H/.local/state/rb-gate-wait"; fail=1; fi
if ! grep -nE '20[0-9]{2}-[0-9]{2}-[0-9]{2}T' "$S" | grep -v '^[0-9]*:[[:space:]]*#' | grep -vE 'dt\.datetime\(20[0-9]{2}, [0-9]+, [0-9]+' | grep -q .; then echo "ok - no fixed ISO date literal outside selftest fixtures and comments"
else echo "NOT OK - fixed date literal in the script"; grep -nE '20[0-9]{2}-[0-9]{2}-[0-9]{2}T' "$S"; fail=1; fi
SVC="$here/.config/systemd/user/rb-gate-wait.service"
if grep -q '^ExecStartPre=.*gate-wait-minutes.py --selftest$' "$SVC" && ! grep -q -- '--since' "$SVC"; then echo "ok - rb-gate-wait.service runs --selftest first and passes no --since"
else echo "NOT OK - rb-gate-wait.service drifted"; fail=1; fi
grep -q '^OnUnitActiveSec=15min$' "$here/.config/systemd/user/rb-gate-wait.timer" && echo "ok - rb-gate-wait.timer fires every 15 min" || { echo "NOT OK - rb-gate-wait.timer interval"; fail=1; }
exit $fail
