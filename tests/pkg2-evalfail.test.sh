#!/usr/bin/env bash
# pkg2-evalfail.test.sh (A1296 P2 successor, residual R8-7): an evaluator failure at the Stop obligation check is not "none owed".
# followup-stop-nowait.sh fu_stop_new used to discard the evaluator's exit status, read empty or malformed output as {"locked":false,"new":[]}, remove the
# <sid>.stoplock skip marker and pass silently. Contract: evaluator nonzero exit / empty stdout / malformed JSON / a JSON value that is not the `new` contract
# (not an object, `new` not an array, `locked` present and not a boolean) keeps an existing marker, records the failure in that same marker with a short
# reason code (no evaluator output echoed), and owed-now.sh's next prompt says "evaluator failed ... NOT none owed" through the LOCKNOTE line it already prints.
# Genuine success (rc 0, object, array `new`, `locked` absent or false) still clears the marker and discloses nothing; the locked path and the unwritable-marker
# path are unchanged (controls). The success output of the real evaluator carries no `locked` key, so a missing `locked` is NOT a failure shape.
# Hermetic: HOME, TMPDIR, state dirs are a temp dir; the evaluator is a stub (FOLLOWUP_EVAL) except in the real-evaluator control, whose ledger is a PATH stub.
# Usage: pkg2-evalfail.test.sh [repo-root]   (point it at a parent clone to see the RED side)
set -u
R="${1:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
W="$(mktemp -d "${TMPDIR:-/tmp}/evalfail.XXXXXX")"; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
p=0; f=0; ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
export HOME="$W/home"; mkdir -p "$HOME" "$W/bin"; export TMPDIR="$W"
unset WM_DIRECTOR WM_HELPER FOLLOWUP_TRACE OWED_NOW_SOURCE OPEN_ASKS WM_SEAT FOLLOWUP_EVAL
export PATH="$W/bin:$PATH" WM_ASKS_BIN="$W/bin/wm-asks" WM_DECIDE_BIN="$W/bin/wm-decide" SEATS_TABLE="$W/seats.tsv"
export FOLLOWUP_STATE_DIR="$W/st" FOLLOWUP_OUTBOX="$W/st/outbox.jsonl" FOLLOWUP_DELIVER_CMD=true OWED_NOW_STATE="$W/owed" FOLLOWUP_STOP_FIRES_LOG="$W/fires.log"
export FOLLOWUP_NOW=2026-11-13T12:00 OWED_CACHE_REFRESH_S=99999   # a fresh seeded cache: no detached refresh is ever started by these controls
printf '#!/bin/bash\necho "{\\"owed\\":0,\\"overdue\\":0,\\"escalated\\":0,\\"ids\\":[]}"\n' >"$W/bin/wm-decide"
printf '#!/bin/bash\ncat "%s/rows.json"\n' "$W" >"$W/bin/wm-asks"; chmod +x "$W/bin/"*; echo '[]' >"$W/rows.json"
# evaluator stub: $W/mode picks the `new` answer; stderr always carries a canary that must never reach a disclosure
cat >"$W/stub-eval.py" <<'PY'
import sys
W = sys.argv[0].rsplit("/", 1)[0]
mode = open(W + "/mode").read().strip()
if sys.argv[1] == "reason":
    print("STUB REASON: new obligation"); sys.exit(0)
sys.stderr.write("Traceback CANARYSTDERR token=FAKESECRET\n")
out = {
    "rc1-noout": ("", 1), "rc1-validjson": ('{"new":[],"reason":"","error":null}', 1), "rc137": ("", 137),
    "empty": ("", 0), "blank": ("  \n", 0), "malformed": ('{"new":[CANARYSTDOUT', 0), "garbage": ("CANARYSTDOUT not json", 0),
    "shape-noarray": ('{"error":"CANARYSTDOUT boom"}', 0), "shape-newstring": ('{"new":"CANARYSTDOUT"}', 0), "shape-array": ("[]", 0),
    "shape-null": ("null", 0), "shape-lockedstring": ('{"locked":"true","new":[]}', 0),
    "ok-real": ('{"new":[],"reason":"","error":null}', 0), "ok-spec": ('{"locked":false,"new":[]}', 0),
    "ok-obl": ('{"new":[{"id":"T9","rev":1,"disposition":"ready","kind":"overdue","fp":"T9|1|ready|overdue"}],"reason":"x","error":null}', 0),
    "locked": ('{"new":[],"reason":"","error":null,"locked":true}', 0),
}[mode]
if out[0]:
    sys.stdout.write(out[0] + ("\n" if not out[0].endswith("\n") else ""))
sys.exit(out[1])
PY
OWED="$R/.claude/hooks/owed-now.sh"; GATE="$R/.claude/hooks/followup-stop-gate.sh"
EPOCH=1731500000; MK(){ printf '%s/%s.stoplock' "$OWED_NOW_STATE" "${1:-s1}"; }
seed(){ rm -rf "$W/owed" "$W/st"; mkdir -p "$W/owed" "$W/st"; printf '{"v":1,"seat":"ctl","ts":%s,"clean":true,"rows":""}' "$(date +%s)" >"$W/owed/ctl.ups-cache.json"; }
STOP(){ jq -nc --arg s "${1:-s1}" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,last_assistant_message:""}' | WM_SEAT=ctl FOLLOWUP_EVAL="${EVAL-$W/stub-eval.py}" timeout 20 bash "$OWED" hook 2>"$W/stop.err"; }
UPS(){ printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s"}' "${1:-s1}" | WM_SEAT=ctl FOLLOWUP_EVAL="${EVAL-$W/stub-eval.py}" timeout 20 bash "$OWED" hook 2>/dev/null; }
ctx(){ jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1" 2>/dev/null; }
now(){ date +%s.%N; }; within(){ awk -v a="$1" -v b="$2" -v lim="$3" 'BEGIN{print ((b-a)<=lim)?"ok":"slow " (b-a)}'; }
leak(){ grep -c 'CANARY\|FAKESECRET\|Traceback' <<<"$1"; }

# --- item 1: evaluator failure shapes, each with a pre-existing locked-skip marker (another consumer reads it)
for m in rc1-noout rc1-validjson rc137 empty blank malformed garbage shape-noarray shape-newstring shape-array shape-null shape-lockedstring; do
  seed; echo "$m" >"$W/mode"; echo "$EPOCH" >"$(MK)"
  t0=$(now); S="$(STOP)"; rc=$?; t1=$(now)
  ck "R87-1 $m: Stop returns promptly, rc 0, no block decision" "$(within "$t0" "$t1" 4)/$rc/$(jq -r '.decision // "pass"' <<<"${S:-null}" 2>/dev/null)" "ok/0/pass"
  ck "R87-1 $m: the pre-existing skip marker is kept, its locked line intact" "$([ -e "$(MK)" ] && echo kept || echo cleared)/$(grep -cx "$EPOCH" "$(MK)" 2>/dev/null || echo 0)" "kept/1"
  o="$(ctx "$(UPS)")"
  ck "R87-1 $m: next prompt discloses evaluator failed, NOT none owed" "$(grep -c 'evaluator failed' <<<"$o")/$(grep -c 'NOT \\"none owed\\"\|NOT "none owed"' <<<"$o")" "1/1"
  ck "R87-1 $m: the locked-skip disclosure is still shown next to it" "$(grep -c 'STOP CHECK SKIPPED' <<<"$o")" 1
  ck "R87-1 $m: bounded (<= 600 chars) and no evaluator stdout/stderr content echoed" "$([ "${#o}" -le 600 ] && echo bounded || echo "long ${#o}")/$(leak "$o$S$(cat "$W/stop.err")")" "bounded/0"
done
# reason codes are a fixed sanitized set
seed; echo rc137 >"$W/mode"; STOP >/dev/null; o="$(ctx "$(UPS)")"
ck "R87-1 reason code: nonzero exit names rc-137" "$(grep -c 'evaluator failed (rc-137)' <<<"$o")" 1
seed; echo malformed >"$W/mode"; STOP >/dev/null; o="$(ctx "$(UPS)")"
ck "R87-1 reason code: malformed names malformed" "$(grep -c 'evaluator failed (malformed)' <<<"$o")" 1
# no prior marker: the failure itself creates the marker and is disclosed (failure-only text, no false 'locked' claim)
seed; echo empty >"$W/mode"; S="$(STOP)"; o="$(ctx "$(UPS)")"
ck "R87-1 no prior marker, empty stdout: marker recorded, failure disclosed, no locked claim" "$([ -e "$(MK)" ] && echo marked)/$(grep -c 'evaluator failed (empty)' <<<"$o")/$(grep -c 'STOP CHECK SKIPPED' <<<"$o")" "marked/1/0"
# every later prompt still says so until a Stop check succeeds (no silence after the first prompt)
o2="$(ctx "$(UPS)")"
ck "R87-1 a second prompt still discloses the failed check" "$(grep -c 'evaluator failed' <<<"$o2")" 1
# a failed check through the other P2 Stop entrypoint (followup-stop-gate.sh) uses the same helper and marker
seed; echo "$EPOCH" >"$(MK g1)"; echo rc1-noout >"$W/mode"
G="$(jq -nc '{session_id:"g1",stop_hook_active:false}' | WM_SEAT=ctl FOLLOWUP_EVAL="$W/stub-eval.py" timeout 20 bash "$GATE" 2>/dev/null)"
ck "R87-1 followup-stop-gate.sh: passes, keeps the marker, records the failure" "${G:-pass}/$(grep -cx "$EPOCH" "$(MK g1)" 2>/dev/null || echo 0)/$(grep -c '^evalfail rc-1$' "$(MK g1)" 2>/dev/null || echo 0)" "pass/1/1"
# failure + unwritable marker dir: not silent (the F7-3 channel: a systemMessage on stdout and a stderr line), never a block
seed; echo malformed >"$W/mode"; chmod 555 "$W/owed"; S="$(STOP sU)"; chmod 755 "$W/owed"
ck "R87-1 failure + unwritable marker dir: systemMessage says evaluator failed, could not be written, NOT none owed; no block" "$(jq -r '.systemMessage // ""' <<<"$S" 2>/dev/null | grep -c 'evaluator failed.*could not be written.*NOT')/$(jq -r '.decision // "pass"' <<<"${S:-null}" 2>/dev/null)/$(leak "$S")" "1/pass/0"
ck "R87-1 failure + unwritable marker dir: a stderr line too" "$(grep -c 'STOP CHECK FAILED' "$W/stop.err")" 1

# --- item 2: genuine empty success clears the marker and discloses nothing (both shapes: the real evaluator's and the spec's)
for m in ok-real ok-spec; do
  seed; echo "$m" >"$W/mode"; echo "$EPOCH" >"$(MK)"; S="$(STOP)"; o="$(UPS)"
  ck "R87-2 $m: Stop passes silently, marker cleared, next prompt silent" "${S:-pass}/$([ -e "$(MK)" ] && echo kept || echo cleared)/${o:-silent}" "pass/cleared/silent"
done
# a success after a recorded failure clears it too
seed; echo malformed >"$W/mode"; STOP >/dev/null; echo ok-real >"$W/mode"; STOP >/dev/null; o="$(UPS)"
ck "R87-2 success after a failure: marker cleared, next prompt silent" "$([ -e "$(MK)" ] && echo kept || echo cleared)/${o:-silent}" "cleared/silent"
# the real evaluator on an empty ledger (no stub): genuine success
seed; echo "$EPOCH" >"$(MK)"; S="$(EVAL='' STOP)"; o="$(EVAL='' UPS)"
ck "R87-2 real followup-eval.py, empty ledger: pass, marker cleared, prompt silent" "${S:-pass}/$([ -e "$(MK)" ] && echo kept || echo cleared)/${o:-silent}" "pass/cleared/silent"
# success with an obligation still blocks (the evaluator's answer is used, not suppressed)
seed; echo ok-obl >"$W/mode"; S="$(STOP)"
ck "R87-2 success with a new obligation: blocks with the reason" "$(jq -r '.decision // "pass"' <<<"${S:-null}" 2>/dev/null)/$(jq -r '.reason // ""' <<<"${S:-null}" 2>/dev/null | grep -c 'STUB REASON')" "block/1"

# --- item 3: locked path and unwritable-marker path unchanged
seed; echo locked >"$W/mode"; S="$(STOP)"; o="$(ctx "$(UPS)")"
ck "R87-3 locked: pass, marker written with an epoch, prompt says STOP CHECK SKIPPED, no evaluator-failed text" "${S:-pass}/$(grep -cxE '[0-9]+' "$(MK)" 2>/dev/null || echo 0)/$(grep -c 'STOP CHECK SKIPPED' <<<"$o")/$(grep -c 'evaluator failed' <<<"$o")" "pass/1/1/0"
seed; echo locked >"$W/mode"; chmod 555 "$W/owed"; S="$(STOP sL)"; chmod 755 "$W/owed"
ck "R87-3 locked + unwritable marker dir: systemMessage skipped/could not be written, stderr line, no block" "$(jq -r '.systemMessage // ""' <<<"$S" 2>/dev/null | grep -c 'NOT checked.*could not be written')/$(grep -c 'STOP CHECK SKIPPED' "$W/stop.err")/$(jq -r '.decision // "pass"' <<<"${S:-null}" 2>/dev/null)" "1/1/pass"
# helper unit: FU_STOP_NEW / FU_STOP_LOCKED on each class, return 0
unit(){ ( . "$R/.claude/hooks/followup-lib.sh"; . "$R/.claude/hooks/followup-stop-nowait.sh"; FOLLOWUP_EVAL="$W/stub-eval.py" fu_stop_new ctl u1 >/dev/null 2>&1; echo "$?/${FU_STOP_LOCKED}/$(grep -c . <<<"$FU_STOP_NEW")" ); }
seed; echo locked >"$W/mode"; a="$(unit)"; echo malformed >"$W/mode"; b="$(unit)"; echo ok-obl >"$W/mode"; c="$(unit)"
ck "R87-3 helper: locked / failed / obligation -> rc/LOCKED/new-count" "$a $b $c" "0/1/0 0/0/0 0/0/1"
echo "pass=$p fail=$f"; [ "$f" = 0 ]
