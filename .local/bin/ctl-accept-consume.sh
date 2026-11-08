#!/usr/bin/env bash
# A1216 / A1255: run the done-check of every open ctl/aide row from the CANONICAL ledger (asks-view) and log PASS/FAIL/SKIP per id to ~/.cache/aide/accept-consume.log;
# PASS/FAIL is also recorded canonically (`wm-decide asks accept --result`, idempotent for the same result + check text). Only checks starting with test|systemctl|grep|ls|[ are run
# (timeout 20 s, bash -c); anything else is SKIP. Never closes a row. `wm-asks asks accept` exiting 1 with `accept <id> FAIL rev N` on stdout is a RECORDED FAIL (the verdict landed), never RECORD-FAIL.
# A FAIL or SKIP on a row past due emits one obligation (kind acceptance-failed | check-unrunnable, fp <id>|<rev>|<kind>) through followup-eval.py `emit` (FOLLOWUP_EVAL_BIN, else ~/.local/bin, else absent = skipped silently); the evaluator dedupes by fp. ASKS_FILE = fixture, honoured only with ASKS_VIEW_TEST=1.
set -u
LOG="${ACCEPT_LOG:-$HOME/.cache/aide/accept-consume.log}"; WM="${WM_ASKS_CMD:-wm-asks}"
[ "${ASKS_VIEW_TEST:-}" = 1 ] && [ -n "${ASKS_FILE:-}" ] && export OPEN_ASKS="$ASKS_FILE"
rows="$("${ASKS_VIEW_BIN:-asks-view}")" || { echo "ctl-accept-consume: canonical ask ledger unreadable (asks-view incident opened); nothing run" >&2; exit 3; }
emit() { # id rev kind detail: defensive, never fails the run
  local fe="${FOLLOWUP_EVAL_BIN:-$HOME/.local/bin/followup-eval.py}"
  [ -f "$fe" ] || return 0
  python3 "$fe" emit --seat ctl --id "$1" --rev "$2" --kind "$3" --fp "$1|$2|$3" --detail "$4" >/dev/null 2>>"$LOG.err" || true
}
now="${ACCEPT_NOW:-$(date +%FT%T)}"
printf '%s\n' "$rows" | awk -F'\t' '/^# CLOSED/{exit} /^#/{next} NF>=7 && ($3=="ctl"||$3=="aide"){print $1"\t"$2"\t"$6}' | while IFS=$'\t' read -r id due chk; do
  case "$chk" in
    test\ *|systemctl\ *|grep\ *|ls\ *|\[\ *) if timeout 20 bash -c "$chk" >/dev/null 2>&1; then r=PASS; else r=FAIL; fi;;
    *) r=SKIP;;
  esac
  echo "$(date +%FT%T) $r $id" >> "$LOG"
  rev=0
  if [ "$r" != SKIP ] && [ "${ACCEPT_RECORD:-1}" = 1 ]; then
    out="$("$WM" asks accept "$id" --by ctl --result "$r" --evidence "accept-consume $(date +%FT%T): bash -c on the row check" 2>>"$LOG.err")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      if printf '%s\n' "$out" | grep -Eq "^accept $id FAIL rev [0-9]+"; then
        rev="$(printf '%s\n' "$out" | sed -n "s/^accept $id FAIL rev \([0-9]*\).*/\1/p" | head -1)"
      else
        echo "$(date +%FT%T) RECORD-FAIL $id" >> "$LOG"
      fi
    fi
  fi
  d="${due#due=}"; d="${d%% *}"
  if [ -n "$d" ] && [[ "$d" < "$now" ]]; then
    case "$r" in
      FAIL) emit "$id" "$rev" acceptance-failed "acceptance check failed past due; next: write the receipt path named in the row";;
      SKIP) emit "$id" "$rev" check-unrunnable "check not runnable by the consumer; next: re-express the check with test, grep, ls, systemctl or [";;
    esac
  fi
done
echo "ctl-accept-consume: ran $(date +%T)"
