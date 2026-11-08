#!/usr/bin/env bash
# ctl-accept-consume.sh integration test against the REAL followup-eval.py (ledger ask A1346). The evaluator is extracted with `git show $EVAL_REF:.local/bin/followup-eval.py`
# (default origin/ctl-followup-loop-repair, PR 325) into a temp dir. asks-view and wm-asks stay fakes (no ledger, no network); the evaluator and its store are real.
#  1. a past-due gh-first row over three consumer runs yields exactly one outbox line in the real store (dedupe by fp in the evaluator's own store).
#  2. known-bad: with the emit interface removed the consumer writes errors.jsonl + EMIT-ERR and exits nonzero, not success.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; S="$here/.local/bin/ctl-accept-consume.sh"
ref="${EVAL_REF:-origin/ctl-followup-loop-repair}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ctl-accept-integ.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
mkdir -p "$tmp/ev"
git -C "$here" show "$ref:.local/bin/followup-eval.py" >"$tmp/ev/followup-eval.py" 2>"$tmp/show.err" || { echo "FAIL cannot extract followup-eval.py from $ref: $(cat "$tmp/show.err")"; exit 1; }
cat >"$tmp/asks-view" <<'F'
#!/usr/bin/env bash
printf 'A1\t2020-01-01T00:00\tctl\tx\ty\tgh pr view 1\tz\n'
F
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/wm-asks"; chmod +x "$tmp/asks-view" "$tmp/wm-asks"
run() { ASKS_VIEW_BIN="$tmp/asks-view" WM_ASKS_CMD="$tmp/wm-asks" ACCEPT_LOG="$tmp/log" FOLLOWUP_STATE_DIR="$tmp/state" FOLLOWUP_EVAL_BIN="$1" FOLLOWUP_DELIVER_CMD=true ACCEPT_NOW=2026-11-08T10:00:00 "$S" >/dev/null 2>&1; RC=$?; }

grep -q 'emit' "$tmp/ev/followup-eval.py"; chk "real evaluator at $ref declares an emit subcommand" $?
for i in 1 2 3; do run "$tmp/ev/followup-eval.py"; done
[ "$RC" -eq 0 ] && [ "$(grep -c SKIP "$tmp/log")" = 3 ] && [ "$(cat "$tmp/state/outbox.jsonl" 2>/dev/null | wc -l)" = 1 ] && grep -q 'A1|0|check-unrunnable' "$tmp/state/outbox.jsonl"
chk "past-due gh-first row over three runs: exactly one outbox line from the real store" $?

rm -rf "$tmp/state" "$tmp/log" "$tmp/log.err"; run "$tmp/ev/absent.py"
[ "$RC" -ne 0 ] && grep -q 'EMIT-ERR A1' "$tmp/log" && grep -q 'emit-interface-missing' "$tmp/state/errors.jsonl" && [ ! -s "$tmp/state/outbox.jsonl" ]
chk "known-bad: interface removed -> errors.jsonl + EMIT-ERR + nonzero" $?
exit $fail
