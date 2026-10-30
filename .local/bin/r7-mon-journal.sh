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

stall_age() {   # af51 (row 37ea): minutes since the newest coder session JSONL for slug $1 on the build host; "none" if no session dir/file
  local d; d=".claude/projects/$(printf %s "/home/jsy/.local/state/wm-build/wt/$1" | sed 's/[^A-Za-z0-9]/-/g')"
  ${R7_STALL_SH:-ssh $R7_SSH_OPTS $R7_HOST} "cd ~ && f=\$(ls -t $d/*.jsonl 2>/dev/null | head -1); if [ -n \"\$f\" ]; then echo \$(( (\$(date +%s) - \$(stat -c %Y \"\$f\")) / 60 )); else echo none; fi" 2>/dev/null || echo unread
}
step_read() {  # ctl 8898 (10-30): "<step> <unit> <cpu_ns> <io_bytes>" of slug $1's live `wm-build step` child; "none" when no step child runs
  local q='p=$(pgrep -o -f "wm-build step PAT "); [ -n "$p" ] || { echo none; exit 0; }; set -- $(ps -o args= -p "$p"); s=$4; u=$(ps -o unit= -p "$p" | tr -d " ")
g() { v=$(systemctl --user show -p "$1" --value "$u" 2>/dev/null | tr -dc 0-9); [ -n "$v" ] || v=$(systemctl show -p "$1" --value "$u" 2>/dev/null | tr -dc 0-9); echo "${v:-0}"; }
echo "$s $u $(g CPUUsageNSec) $(( $(g IOReadBytes) + $(g IOWriteBytes) ))"'
  q=${q/PAT/[${1:0:1}]${1:1}}   # bracketed first char: the remote shell's own cmdline never matches the pattern
  ${R7_STALL_SH:-ssh $R7_SSH_OPTS $R7_HOST} "$q" 2>/dev/null || echo unread
}
stall_note() {  # INNER LIVENESS. Coder JSONL age is read ONLY while the step is the coder (inner/coder) or no step child runs;
  # any other step (gate/land/live) is judged by CPU+IO deltas of its unit over R7_STALL_GAP s (506 at 2:29 AM 10-30: gate live, jsonl 46m, called STALLED)
  local a s u c0 i0 s1 c1 i1 g=${R7_STALL_GAP:-10}
  read -r s u c0 i0 <<<"$(step_read "$1")"
  case "${s:-none}" in
    none|unread|inner|coder) ;;
    *) sleep "$g"; read -r s1 _ c1 i1 <<<"$(step_read "$1")"
       if [ "$s1" != "$s" ]; then echo "step=$s changed to ${s1:-none} during the read: NOT a stall"
       elif [ $((c1-c0)) -gt 0 ] || [ $((i1-i0)) -gt 0 ]; then echo "step=$s unit=$u cpu_delta_ns=$((c1-c0)) io_delta=$((i1-i0)) over ${g}s LIVE: NOT a stall (coder jsonl not read outside the coder step)"
       else echo "step=$s unit=$u cpu_delta_ns=0 io_delta=0 over ${g}s NO PROGRESS: read the step unit; never redrive --from inner for a $s step"; fi
       return;;
  esac
  a=$(stall_age "$1")
  case "$a" in none|unread|'') echo "step=${s:-none} coder_jsonl=$a (no live coder session read)";;
    *) if [ "$a" -lt 15 ]; then echo "step=${s:-none} coder_jsonl_age=${a}m LIVE: NOT a stall"; else echo "step=${s:-none} coder_jsonl_age=${a}m STALLED: redrive from inner"; fi;; esac
}
stall_selftest() {  # hermetic: stub pgrep/ps/systemctl on PATH; case 4 replays 506 at 2:29 AM 10-30 (gate child, jsonl 46m, CPU moving) -> NOT a stall
  local t f=0 o j b; t=$(mktemp -d); b=$t/bin; j="$t/.claude/projects/-home-jsy--local-state-wm-build-wt-x-slug"; mkdir -p "$j" "$b"
  printf '#!/bin/sh\n[ -s "%s/step" ] && echo 2687066\nexit 0\n' "$t" > "$b/pgrep"
  printf '#!/bin/sh\ncase "$*" in *unit=*) echo wm-build-inner506-a.service;; *) echo "/home/jsy/.cargo/bin/wm-build step x-slug $(cat %s/step) --run 506";; esac\n' "$t" > "$b/ps"
  printf '#!/bin/sh\ncase "$*" in *CPUUsageNSec*) c=$(cat %s/cpu); echo $c; echo $((c+$(cat %s/inc))) > %s/cpu;; *) echo "[not set]";; esac\n' "$t" "$t" "$t" > "$b/systemctl"
  chmod +x "$b"/*; echo 6348364184000 > "$t/cpu"; echo 1660000000 > "$t/inc"; : > "$t/step"
  run() { HOME=$t PATH=$b:$PATH R7_STALL_SH="bash -c" R7_STALL_GAP=0 stall_note x-slug; }
  o=$(run); [[ $o == *none* ]] || { f=1; echo "case1 none: $o"; }
  touch "$j/a.jsonl"; o=$(run); [[ $o == *LIVE* ]] || { f=1; echo "case2 fresh jsonl: $o"; }
  touch -d '-46 min' "$j/a.jsonl"; o=$(run); [[ $o == *STALLED* ]] || { f=1; echo "case3 no step, jsonl 46m: $o"; }
  echo gate > "$t/step"; o=$(run); [[ $o == *"step=gate"*LIVE* && $o != *STALLED* ]] || { f=1; echo "case4 REPLAY-506 gate cpu moving, jsonl 46m: $o"; }
  echo 0 > "$t/inc"; o=$(run); [[ $o == *"NO PROGRESS"* && $o != *"redrive from inner"* ]] || { f=1; echo "case5 gate cpu flat: $o"; }
  echo inner > "$t/step"; o=$(run); [[ $o == *"step=inner"*STALLED* ]] || { f=1; echo "case6 coder step, jsonl 46m: $o"; }
  rm -rf "$t"; [ $f = 0 ] && echo "STALL-NOTE SELFTEST OK (none/LIVE/STALLED/REPLAY-506 gate LIVE/gate flat NO PROGRESS/inner STALLED)" || { echo "STALL-NOTE SELFTEST FAIL"; return 1; }
}

parse_loop() {   # stdin: parser output (CAND/HB lines); stdout: bells. wp_gate runs on every HB (30 s) so an expired premise stops the wake.
  local tag what run vals
  set -f
  while IFS=$'\t' read -r tag what run vals; do
    case "$tag" in
      HB) r7_hb "$NAME"
          if r7_gate >/dev/null 2>&1; then unset R7_BELL_DRY_GATE; else R7_BELL_DRY_GATE=1; fi ;;
      CAND) if [[ $what == alarm-opened && $vals == *channel=stall* ]]; then vals="$vals $(stall_note "$run")"; fi
            R7_BELL_DRY=${R7_BELL_DRY:-${R7_BELL_DRY_GATE:-}} r7_bell "$NAME" "$run" "$what" "$vals" ;;
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

if [ "${1:-}" = --stall-selftest ]; then stall_selftest; exit $?; fi   # hermetic, no ssh (tests/r7-mon-journal-stall.test.sh)
r7_wp_arm r7-mon-journal "$R7_PREMISE_TEXT" "ssh $R7_SSH_OPTS $R7_HOST 'test -s $RJ'"
if [ "${1:-}" = --selftest ]; then selftest; rc=$?; stall_selftest || rc=1; r7_wp_line || rc=1; exit $rc; fi
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
