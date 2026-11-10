#!/usr/bin/env bash
# A1216 / A1255: run the done-check of every open ctl/aide row from the CANONICAL ledger (asks-view) and log PASS/FAIL/SKIP/PRESENCE per id to ~/.cache/aide/accept-consume.log;
# PASS/FAIL is also recorded canonically (`wm-decide asks accept --result`, idempotent for the same result + check text). Only checks starting with test|systemctl|grep|ls|[ are run
# (timeout 20 s, bash -c); anything else is SKIP. Never closes a row. `wm-asks asks accept` exiting 1 with `accept <id> FAIL rev N` on stdout is a RECORDED FAIL (the verdict landed), never RECORD-FAIL.
# A bare presence predicate (test -s/-f/-e/-r, ls, [ -s ] on one path) that exits 0 logs PRESENCE, is not recorded as PASS, and on a past-due row emits kind presence-only-check.
# A FAIL or SKIP on a row past due emits one obligation (kind acceptance-failed | check-unrunnable, fp <id>|<rev>|<kind>) through followup-eval.py `emit` (FOLLOWUP_EVAL_BIN, else ~/.local/bin; absent or unusable = EMIT-ERR in the log + an emit-interface-missing line in $FOLLOWUP_STATE_DIR/errors.jsonl + exit 4, never silent); the evaluator dedupes by fp. ASKS_FILE = fixture, honoured only with ASKS_VIEW_TEST=1.
set -u
LOG="${ACCEPT_LOG:-$HOME/.cache/aide/accept-consume.log}"; WM="${WM_ASKS_CMD:-wm-asks}"
[ "${ASKS_VIEW_TEST:-}" = 1 ] && [ -n "${ASKS_FILE:-}" ] && export OPEN_ASKS="$ASKS_FILE"
rows="$("${ASKS_VIEW_BIN:-asks-view}")" || { echo "ctl-accept-consume: canonical ask ledger unreadable (asks-view incident opened); nothing run" >&2; exit 3; }
emit_err() { # id detail: durable owned error line + EMIT-ERR log line; the run exits nonzero
  local sd="${FOLLOWUP_STATE_DIR:-$HOME/.local/state/followup-loop}"
  echo "$(date +%FT%T) EMIT-ERR $1 $2" >> "$LOG"
  mkdir -p "$sd" 2>/dev/null && python3 -c 'import json,sys;print(json.dumps({"ts":sys.argv[1],"kind":"emit-interface-missing","ask":sys.argv[2],"owner":"ctl","detail":sys.argv[3]}))' "$(date +%FT%T)" "$1" "$2" >> "$sd/errors.jsonl"
}
emit() { # id rev kind detail: contract `emit --seat S --id I --rev R --kind K --fp F --detail D` -> JSON {"emitted":bool,"deduped":bool}; a missing or unusable interface is an owned error, never a silent no-op
  local fe="${FOLLOWUP_EVAL_BIN:-$HOME/.local/bin/followup-eval.py}" o
  [ -f "$fe" ] || { emit_err "$1" "followup-eval.py absent at $fe"; return 1; }
  o="$(python3 "$fe" emit --seat ctl --id "$1" --rev "$2" --kind "$3" --fp "$1|$2|$3" --detail "$4" 2>>"$LOG.err")" || { emit_err "$1" "emit exited nonzero"; return 1; }
  printf '%s' "$o" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());assert "emitted" in d and "deduped" in d' 2>/dev/null || { emit_err "$1" "emit output is not {emitted,deduped} JSON"; return 1; }
}
now="${ACCEPT_NOW:-$(date +%FT%T)}"
printf '%s\n' "$rows" | awk -F'\t' '/^# CLOSED/{exit} /^#/{next} NF>=7 && ($3=="ctl"||$3=="aide"){print $1"\t"$4"\t"$6}' | { nerr=0; while IFS=$'\t' read -r id due chk; do
  case "$chk" in
    test\ *|systemctl\ *|grep\ *|ls\ *|\[\ *) if timeout 20 bash -c "$chk" >/dev/null 2>&1; then r=PASS; else r=FAIL; fi
      # a bare presence/shape predicate proves a file exists, not that the work happened: PRESENCE, never acceptance PASS
      if [ "$r" = PASS ] && { [[ "$chk" =~ ^(test|\[)[[:space:]]+-[sfedrwxL][[:space:]]+[^[:space:]]+([[:space:]]+\])?[[:space:]]*$ ]] || [[ "$chk" =~ ^ls([[:space:]]+-[A-Za-z]+)*[[:space:]]+[^[:space:]]+[[:space:]]*$ ]]; }; then r=PRESENCE; fi;;
    *) r=SKIP;;
  esac
  echo "$(date +%FT%T) $r $id" >> "$LOG"
  rev=0
  if [ "$r" != SKIP ] && [ "$r" != PRESENCE ] && [ "${ACCEPT_RECORD:-1}" = 1 ]; then
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
      FAIL) emit "$id" "$rev" acceptance-failed "acceptance check failed past due; next: write the receipt path named in the row" || nerr=$((nerr+1));;
      PRESENCE) emit "$id" "$rev" presence-only-check "presence predicate cannot prove acceptance; next: register a typed checker with bound evidence" || nerr=$((nerr+1));;
      SKIP) emit "$id" "$rev" check-unrunnable "check not runnable by the consumer; next: re-express the check with test, grep, ls, systemctl or [" || nerr=$((nerr+1));;
    esac
  fi
done; echo "ctl-accept-consume: ran $(date +%T)"; [ "$nerr" -eq 0 ] || { echo "ctl-accept-consume: $nerr row(s) could not emit (EMIT-ERR in $LOG, errors.jsonl)" >&2; exit 4; }; }
