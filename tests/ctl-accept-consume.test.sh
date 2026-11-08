#!/usr/bin/env bash
# ctl-accept-consume.sh known-bad tests (ledger ask A1346 delta 3). Hermetic: asks-view, wm-asks and followup-eval.py are fakes; no ledger, no network.
#  1. wm-asks printing `accept <id> FAIL rev N` and exiting 1 is a recorded FAIL: log has FAIL, never RECORD-FAIL (before the fix: RECORD-FAIL).
#  2. a wm-asks failure with no such line stays RECORD-FAIL.
#  3. a past-due gh-first check yields exactly one obligation over three runs (before the fix: SKIP lines and nothing else).
#  4. a past-due FAIL yields one acceptance-failed obligation keyed <id>|<rev>|acceptance-failed; absent followup-eval.py is skipped silently.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; S="$here/.local/bin/ctl-accept-consume.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ctl-accept-consume.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
cat >"$tmp/asks-view" <<'F'
#!/usr/bin/env bash
printf 'A1\t2020-01-01T00:00\tctl\tx\ty\t%s\tz\n' "${FAKE_CHECK:-test -e /nonexistent-ctl-accept}"
F
cat >"$tmp/wm-asks" <<'F'
#!/usr/bin/env bash
if [ "${FAKE_WM:-}" = recorded ]; then echo "accept A1 FAIL rev 7"; exit 1; fi
[ "${FAKE_WM:-}" = broken ] && { echo "boom"; exit 1; }
exit 0
F
cat >"$tmp/followup-eval.py" <<'F'
import sys, os, json
a = sys.argv[1:]; assert a[0] == "emit"
fp = a[a.index("--fp") + 1]; sd = os.environ["FAKE_STATE"]; seen = os.path.join(sd, "seen")
if os.path.exists(seen) and fp in open(seen).read().split("\n"): sys.exit(0)
open(seen, "a").write(fp + "\n"); open(os.path.join(sd, "outbox"), "a").write(fp + "\n")
F
chmod +x "$tmp/asks-view" "$tmp/wm-asks"
run() { ASKS_VIEW_BIN="$tmp/asks-view" WM_ASKS_CMD="$tmp/wm-asks" ACCEPT_LOG="$tmp/log" FAKE_STATE="$tmp" FOLLOWUP_EVAL_BIN="${EV:-$tmp/followup-eval.py}" ACCEPT_NOW=2026-11-08T10:00:00 "$S" >/dev/null 2>&1; }
reset() { rm -f "$tmp/log" "$tmp/log.err" "$tmp/seen" "$tmp/outbox"; }

reset; FAKE_WM=recorded run
grep -q ' FAIL A1' "$tmp/log" && ! grep -q RECORD-FAIL "$tmp/log"; chk "recorded FAIL (exit 1 + 'accept A1 FAIL rev 7') logs FAIL, not RECORD-FAIL" $?
[ "$(cat "$tmp/outbox" 2>/dev/null)" = "A1|7|acceptance-failed" ]; chk "past-due FAIL emits A1|7|acceptance-failed" $?

reset; FAKE_WM=broken run
grep -q 'RECORD-FAIL A1' "$tmp/log"; chk "unrecognised wm-asks failure still logs RECORD-FAIL" $?

reset; FAKE_CHECK='gh pr view 1' FAKE_WM= ; export FAKE_CHECK='gh pr view 1'
for i in 1 2 3; do run; done
[ "$(grep -c SKIP "$tmp/log")" = 3 ] && [ "$(wc -l <"$tmp/outbox")" = 1 ] && [ "$(cat "$tmp/outbox")" = "A1|0|check-unrunnable" ]; chk "gh-first past-due check: one obligation over three runs" $?
unset FAKE_CHECK

reset; EV="$tmp/absent.py" run; rc=$?
[ ! -e "$tmp/outbox" ] && grep -q ' FAIL A1' "$tmp/log"; chk "absent followup-eval.py is skipped silently" $?
exit $fail
