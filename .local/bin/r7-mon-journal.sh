#!/bin/bash
# r7-mon-journal: alert-only tail of ryzen7's wm-build journal.jsonl -> R7-BELL lines. Modeled on rb's mon-landrisk (d-20261021-185321-rb-c116 shape:
# --selftest first, ssh loss never exits (SSH-FAIL line, 60 s, retry), heartbeat, wp_gate on EVERY loop iteration).
# PREMISE: r7 seat is tick-driven; bells wake it. This unit only READS ryzen7 (ssh tail -F of journal.jsonl + a stdlib python parser; NO writes, NO wm-build CLI) and its
#   only local writes are bells/ (log, dedup/wake-budget state, heartbeat) plus the guarded ~/.local/bin/seat-event.sh call, which an expired/gone premise turns off. EXPIRES 2026-11-21.
# Every line: R7-BELL journal <12h time> <run/slug> <what> <values>; <what> is a fixed category key, values follow it in the log only.
# Dedup (name,run,what) 30 min; seat-event.sh at most 6x per rolling hour across ALL r7 bells, overflow = R7-BELL-OVERFLOW (log only). SSH-FAIL never calls seat-event.sh.
#
# journal rows are {"op":..,"table":..,"row":{..}}. Events mapped (table/op) -> <what> -> SEAT ACTION (a bell with no action is dropped):
#   runs/update with row.outcome            run-ended-<outcome>   read the outcome; code/infra -> `wm-build run show`, classify, redrive or close per playbook
#   runs/run-ended with row.cause           run-ended-red-leg     the cause text names the red leg (live AC / gate / prd-defect): decide amend|redrive|close
#   runs/unit-stopped|operator-stop|run-finalized, daemon/claim-reaped, claims/orphan-released
#                                           run-stopped           a run was killed/reaped: confirm it was intended (pause/redrive) else redrive --from <stage>
#   runs/run-paused                         run-paused            a run row entered paused: read cause (reprice/PSI), unpause when the cause cleared
#   land/pr-merged                          land-merged           land ended merged: verify tag/deploy per playbook, nothing else
#   land/land-precheck-failed|push-refused|version-head-not-above-tag|regen-failed|generated-regen-moved-head, daemon/readmit-from-land-failed
#                                           land-failed           land ended failed: classify, `redrive --from land` after the fix
#   land/ci-red-classified                  land-ci-red           CI red on a land: kind=own -> fix; kind=main -> hold (never unpause)
#   land/land-held                          land-held             daemon HOLD (ci-main-red): NOT a stall; release only via redrive --from land when main is green
#   *work-lost* ops (not -skipped-)         work-lost             branch work reverted/lost: cordon, restore the tip under lease, merge origin/main first
#   alarms/insert                           alarm-opened          read `wm-build alarms`, classify, close or act (channel in values)
#   alarms/insert channel=quota, or any message/error field matching \b429\b|\b403\b|quota|rate.?limit|org.?disabled, or an op name matching it
#                                           quota-429             quota/org-disabled: swap account per playbook, cordon admission until placed
#   operator/limits-drift action!=reverted limits-drift         config != lock: read limits.lock vs config, decide (guard reverted ones are not belled)
#   daemon/tick: slots.counted < slots.max_runs, >=1 skipped[].reason not in {dir:,parked,status:,depends-unresolved,claimed-by,prefix-denied,cap=max_runs},
#                admitted empty, for > 10 min        idle-slot   an idle slot with an eligible PRD is a defect: read the reasons (prefix-cap, cargo-jobs-pressure) and fix or cordon
# Rare / not seen in the last 5000 lines (declared rare, selftest does not require them): runs/update-outcome, run-ended, run-paused, unit-stopped, operator-stop, run-finalized,
#   claim-reaped, orphan-released, pr-merged, land-precheck-failed, push-refused, version-head-not-above-tag, regen-failed, generated-regen-moved-head,
#   readmit-from-land-failed, ci-red-classified, land-held, *work-lost*, limits-drift. REQUIRED in the last 5000 lines: daemon/tick, alarms table, runs table, op update.
# NOT mapped here: wm-build.service inactive/restarted (r7-mon-host reads systemctl: the journal goes silent when the daemon dies); cordons are config edits by the seat itself.
# Test overrides: R7_HOST, WATCH_RETRY_SLEEP, R7_BELLS_DIR (use mktemp -d), R7_BELL_DRY=1, R7_SEAT_EVENT, WP_STATE.
SCRIPT=r7-mon-journal.sh
NAME=journal
HERE="$(dirname "$(readlink -f "$0")")"
. "$HERE/r7-watch-lib.sh"
. "$WP_LIB" 2>/dev/null || true
RJ='$HOME/.local/state/wm-build/journal.jsonl'
PARSER="$HERE/r7-journal-parse.py"
REQUIRED_PATTERNS=('"op":"tick"' '"table":"alarms"' '"table":"runs"' '"op":"update"')

parse_loop() {   # stdin: parser output (CAND/HB lines); stdout: bells. wp_gate runs on every HB (30 s) so an expired premise stops the wake.
  local tag what run vals
  set -f
  while IFS=$'\t' read -r tag what run vals; do
    case "$tag" in
      HB) r7_hb "$NAME"
          if r7_gate >/dev/null 2>&1; then unset R7_BELL_DRY_GATE; else R7_BELL_DRY_GATE=1; fi ;;
      CAND) R7_BELL_DRY=${R7_BELL_DRY:-${R7_BELL_DRY_GATE:-}} r7_bell "$NAME" "$run" "$what" "$vals" ;;
    esac
  done
}

selftest() {
  local out rc missing="" p T n line cnt
  for b in ssh python3 flock md5sum; do command -v "$b" >/dev/null 2>&1 || { echo "SELFTEST FAIL $SCRIPT missing local binary: $b"; return 1; }; done
  out=$(ssh $R7_SSH_OPTS "$R7_HOST" "J=$RJ; [ -s \$J ] || { echo journal-absent; exit 4; }; command -v python3 tail >/dev/null || { echo missing-python3-or-tail; exit 3; }; tail -n 5000 \$J | grep -aoE '^\{\"op\":\"[^\"]*\"|\"table\":\"[a-z_]+\"' | sort -u | tr '\n' ' '" 2>&1); rc=$?
  if [ $rc != 0 ] || [ -z "$out" ]; then echo "SELFTEST FAIL $SCRIPT ssh/remote rc=$rc: $(printf '%s' "${out:-no output}" | tr '\n' ' ' | cut -c1-200)"; return 1; fi
  for p in "${REQUIRED_PATTERNS[@]}"; do case "$out" in *"$p"*) ;; *) missing="$missing $p";; esac; done
  [ -z "$missing" ] || { echo "SELFTEST FAIL $SCRIPT hard-coded journal events absent from the last 5000 lines:$missing"; return 1; }
  # remote parser runs under the remote python (compile check, read-only)
  out=$(ssh $R7_SSH_OPTS "$R7_HOST" "python3 -I -c $(printf %q "$(<"$PARSER")") </dev/null" 2>&1); rc=$?
  [ $rc = 0 ] || { echo "SELFTEST FAIL $SCRIPT remote python3 cannot run the parser rc=$rc $(printf '%s' "$out" | head -n1 | cut -c1-120)"; return 1; }
  # synthetic: tempdir root created here, never a real path; the SAME parser, fed on stdin, through the SAME parse_loop and r7_bell
  T=$(mktemp -d) || { echo "SELFTEST FAIL $SCRIPT mktemp"; return 1; }
  line=$(
    R7_BELLS_DIR=$T R7_STATE_DIR=$T/state R7_HB_DIR=$T/hb R7_BELL_DRY=1
    printf '%s\n' '{"op":"update","row":{"id":999,"outcome":"code"},"table":"runs","ts":"2026-10-22T22:00:00+00:00"}' \
      | python3 -I "$PARSER" | parse_loop)
  cnt=$(printf '%s\n' "$line" | grep -c '^R7-BELL ')
  if [ "$cnt" != 1 ]; then echo "SELFTEST FAIL $SCRIPT synthetic ended-run line gave $cnt bells (want exactly 1): $line"; rm -rf "$T"; return 1; fi
  # quota anchoring: a run id/sha containing 429/403 must NOT ring; a real error field must
  n=$(
    R7_BELLS_DIR=$T R7_STATE_DIR=$T/state2 R7_HB_DIR=$T/hb R7_BELL_DRY=1
    printf '%s\n' '{"op":"cargo-jobs-wait","row":{"run":"429","sha":"403abc","id":4290},"table":"builder"}' \
      | python3 -I "$PARSER" | parse_loop | grep -c '^R7-BELL ')
  [ "$n" = 0 ] || { echo "SELFTEST FAIL $SCRIPT quota match fired on a run id/sha ($n bells)"; rm -rf "$T"; return 1; }
  n=$(
    R7_BELLS_DIR=$T R7_STATE_DIR=$T/state3 R7_HB_DIR=$T/hb R7_BELL_DRY=1
    printf '%s\n' '{"op":"x","row":{"error":"HTTP 429 Too Many Requests"},"table":"inner"}' | python3 -I "$PARSER" | parse_loop | grep -c '^R7-BELL ')
  [ "$n" = 1 ] || { echo "SELFTEST FAIL $SCRIPT quota error field gave $n bells (want 1)"; rm -rf "$T"; return 1; }
  # wake budget: 8 distinct bells -> 6 R7-BELL + 2 R7-BELL-OVERFLOW (dry: no seat-event call)
  n=$(
    R7_BELLS_DIR=$T R7_STATE_DIR=$T/state4 R7_HB_DIR=$T/hb R7_BELL_DRY=1
    for i in 1 2 3 4 5 6 7 8; do printf '{"op":"update","row":{"id":%s,"outcome":"code"},"table":"runs"}\n' "$i"; done | python3 -I "$PARSER" | parse_loop | awk '/^R7-BELL-OVERFLOW /{o++} /^R7-BELL /{b++} END{print b+0 "/" o+0}')
  [ "$n" = 6/2 ] || { echo "SELFTEST FAIL $SCRIPT wake budget gave bells/overflow=$n (want 6/2)"; rm -rf "$T"; return 1; }
  rm -rf "$T"
  r7_selftest_event_err $NAME || return 1
  echo "SELFTEST PASS $SCRIPT journal readable, required events present, synthetic ended-run -> exactly 1 bell [$(printf '%s' "$line" | cut -c1-110)], 429-in-id no bell, error-field 429 bell, wake budget 6/2; stub seat-event rc=64 -> 1 EVENT-ERR line, EVENT_SOURCE=r7-mon-$NAME"
}

r7_wp_arm r7-mon-journal "$R7_PREMISE_TEXT" "ssh $R7_SSH_OPTS $R7_HOST 'test -s $RJ'"
if [ "${1:-}" = --selftest ]; then selftest; rc=$?; r7_wp_line || rc=1; exit $rc; fi
R7_HB_NAME=$NAME; export R7_HB_NAME
r7_hb "$NAME"
r7_hb_ticker "$NAME"
trap 'kill $R7_TICKER_PID 2>/dev/null' EXIT
until line=$(selftest); do
  echo "$line"; r7_ssh_fail "$(printf '%s' "$line" | sed -n 's/.* rc=\([0-9]*\).*/\1/p')" "$NAME"
done
echo "$line"
r7_wp_line
PSRC=$(<"$PARSER")
while true; do
  r7_hb "$NAME"
  r7_gate >/dev/null 2>&1 || echo "WP-DISARMED r7-mon-journal $(r7_ts) premise gone or expired; bells keep logging, seat-event.sh calls off at the next HB"
  ssh $R7_SSH_OPTS "$R7_HOST" "python3 -I -u -c $(printf %q "$PSRC") --follow $RJ" | parse_loop
  r7_ssh_fail "${PIPESTATUS[0]}" "$NAME"
done
