#!/usr/bin/env bash
# W4 typed-authorized continuation (ledger ask A1346): suggestion-only bell -> waiter `obligation` event -> bridge queue -> ctl-event-route.sh.
# Only an `APPROVED-OBLIGATION id= rev= fp= approval=` line from hermes*/joe* naming the exact key opens ONE owned continuation row and resolves the
# outbox entry; everything else is surfaced and never executed. Sandbox: temp HOME, stub wm-asks, stub tmux, spy claude, spy seat-event, a COPY of the
# bin set with its own BR_DIR/RT_DIR/EW_DIR. No live service, restart or send. SRC=<tree> runs the test against another tree (e.g. the base commit).
set -u
SRC="${SRC:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
T="$(mktemp -d)"; [ -n "${KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
n=0; f=0
chk() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got [$2] want [$3])"; f=1; fi; }
B="$T/bin"; mkdir -p "$B" "$T/home" "$T/ev" "$T/av" "$T/fb"
for x in ctl-event-bridge.sh ctl-event-route.sh ctl-event-wait.sh followup-eval.py followup-deliver.sh approval-check.sh ctl-obligation-run.py; do cp "$SRC/.local/bin/$x" "$B/$x" 2>/dev/null || true; done
mkdir -p "$T/otests"; printf 'aide\tinbox\t-\t0\t0\t-\t-\n' > "$T/seats.tsv"
printf '#!/bin/sh\necho "$@" >> %s/tmux.log\n[ "$1" = list-panes ] && echo claude\nexit 0\n' "$T" > "$T/tmux"
printf '#!/bin/sh\necho "$@" >> %s/claude.calls\ncat >/dev/null; echo "{\\"is_error\\":false,\\"result\\":\\"OUTCOME: DONE spy\\"}"\n' "$T" > "$T/claude"
printf '#!/bin/sh\nprintf "t | %%s | %%s\\n" "${EVENT_SOURCE:-x}" "$2" >> %s/ev/aide-events.log\necho "$2" >> %s/deliver.spy\n' "$T" "$T" > "$T/seatevent"
printf '#!/bin/sh\ncat %s/asks.jsonl 2>/dev/null\n' "$T" > "$T/asksview"
cat > "$T/wma" <<'WMA'
#!/usr/bin/env python3
import json, sys, os
a = sys.argv[1:]; st = os.environ["ASKS_STORE"]
rows = [json.loads(l) for l in open(st)] if os.path.exists(st) else []
if a[:2] == ["asks", "query"]:
    o = a[2:]; txt = o[o.index("--text") + 1] if "--text" in o else None
    print(json.dumps([r for r in rows if txt is None or txt in r["what"]])); sys.exit(0)
if a[:2] == ["asks", "add"]:
    o = a[2:]; g = lambda k: o[o.index(k) + 1]
    r = {"ask_id": "A%d" % (2000 + len(rows)), "owner": g("--owner"), "check": g("--check"), "what": g("--what")}
    open(st, "a").write(json.dumps(r) + "\n"); print(r["ask_id"]); sys.exit(0)
sys.exit(2)
WMA
printf '#!/bin/sh\nexec bash %s/ctl-event-wait.sh "$@" --poll 1\n' "$B" > "$T/ewrap"   # the bridge passes no --poll; keep each cycle ~1 s
chmod +x "$T/ewrap" "$T/tmux" "$T/claude" "$T/seatevent" "$T/asksview" "$T/wma"
# crash injector: the evaluator wrapper performs the REAL non-check resolve, then kills the whole bridge process group (restart mid-queue)
cat > "$T/evalwrap" <<EOF2
#!/bin/sh
python3 -I $B/followup-eval.py "\$@"; rc=\$?
case " \$* " in *" --check "*) exit \$rc;; esac
if [ -e $T/crash.once ]; then rm -f $T/crash.once; kill -s KILL -- -\$(ps -o pgid= \$\$ | tr -d ' '); fi
exit \$rc
EOF2
chmod +x "$T/evalwrap"
ENVV=(HOME="$T/home" PATH="$PATH" BR_DIR="$T/br" EW_BIN="$T/ewrap" TMUX_BIN="$T/tmux" CTL_PANE=t:0.0 RETRY_SEC=1 WAIT_MAX_SEC=1 BR_ROUTE=1 BR_FABLE=0
  RT_BIN="$B/ctl-event-route.sh" RT_DIR="$T/rt" RT_STATE="$T/rt/state.json" WM_ASKS_CMD="$T/wma" ASKS_VIEW_BIN="$T/asksview" ASKS_STORE="$T/asks.jsonl" RT_CLAUDE_BIN="$T/claude"
  EW_DIR="$T/ew" EVENTS_DIR="$T/ev" OPEN_ASKS="$T/oa" HOLD_FILE="$T/hold" AV_DIR="$T/av" FEEDBACK_DIR="$T/fb" STATUS_JSON="$T/sj" AIDE_WAKE_BIN="$T/nowake"
  FOLLOWUP_STATE_DIR="$T/st" APPROVALS_FILE="$T/approvals.log" RT_APPROVAL_BIN="$B/approval-check.sh" OBL_TESTS_DIR="$T/otests" OBL_RUN_BIN="$B/ctl-obligation-run.py" FOLLOWUP_NOW=2026-11-08T15:00 WM_ASKS_BIN="$T/wma" SEAT_EVENT_BIN="$T/seatevent" )
E() { env -i "${ENVV[@]}" "$@"; }   # RT_EVAL_BIN is set only by crashcycle (router default = the sibling followup-eval.py)
cycle() { E BR_CYCLES=2 timeout 40 bash "$B/ctl-event-bridge.sh" run >/dev/null 2>&1; }
crashcycle() { E BR_CYCLES=2 RT_EVAL_BIN="$T/evalwrap" timeout 40 setsid -w bash "$B/ctl-event-bridge.sh" run >/dev/null 2>&1; }
fresh() { rm -rf "$T/br" "$T/rt" "$T/st" "$T/ew" "$T/ev/aide-events.log" "$T/claude.calls" "$T/deliver.spy" "$T/asks.jsonl" "$T/pwned" "$T/tmux.log" "$T/approvals.log" "$T/ran" "$T/otests"/*
  : > "$T/approvals.log"; chmod 600 "$T/approvals.log";   : > "$T/ev/aide-events.log"; : > "$T/asks.jsonl"; : > "$T/claude.calls"; : > "$T/deliver.spy"; printf 'id\tasked\n' > "$T/oa"; E bash "$B/ctl-event-wait.sh" wait --max-sec 1 --poll 1 >/dev/null 2>&1; }
suggest() { printf '%s' "$2" | E python3 -I "$B/followup-eval.py" suggestion --seat ctl --id "$1" --rev "${3:-1}" ${ACTION:+--action "$ACTION"} >/dev/null; E python3 -I "$B/followup-eval.py" replay; }
keyof() { grep -a "OBLIGATION-KEY id=$1 rev=${2:-1} " "$T/ev/aide-events.log" | tail -1 | sed -E 's/.*OBLIGATION-KEY id=([^ ]+) rev=([0-9]+) fp=([0-9a-f]{12}).*/\1 \2 \3/'; }
# the REAL seat-event.sh writer (stamps `<src> H:MM AM/PM:` onto the third field) and a canonical approvals.log row (approve.sh format) unless NOGRANT=1
appr() { local a n; n="$(sed -nE 's/.* approval=#([0-9]+)$/\1/p' <<<"$1")"; a="$(sed -nE 's/.* id=([A-Za-z0-9._-]+) .*/\1/p' <<<"$1")"
  [ -n "${NOGRANT:-}" ] || [ -z "$n" ] || printf '#%s | 2026-11-08 10:00 PM PST | ctl | Joe: "ok" | re: approve obligation %s\n' "$n" "${GRANT_RE:-$a}" >> "$T/approvals.log"
  EVENT_SOURCE="${APPR_SRC:-hermes}" SEAT_EVENT_NOWAKE=1 SEAT_EVENT_DRY=1 SEAT_EVENT_ACT=0 EVENTS_DIR="$T/ev" SEATS_TABLE="$T/seats.tsv" bash "$SRC/.local/bin/seat-event.sh" aide "$1"; }
cont() { grep -c 'authorized continuation' "$T/asks.jsonl"; }
surf() { grep -c 'awaiting a typed approval' "$T/asks.jsonl"; }
calls() { grep -c . "$T/claude.calls"; }
resolved() { local c; c="$(grep -c '"resolved"' "$T/st/outbox.jsonl" 2>/dev/null)"; echo "${c:-0}"; }
qn() { ls "$T/br/queue"/*.json 2>/dev/null | wc -l | tr -d ' '; }
BAD='I recommend moving the retry guard into the shared hook, and the next step would be to add a regression test.'

# 1. the bell reaches the bridge queue as an obligation event and is surfaced once, zero execution
fresh; suggest stop-t1 "$BAD"
read -r ID REV FP <<<"$(keyof stop-t1)"
chk "deliverer bell carries the typed key (id rev fp)" "$ID $REV ${#FP}" "stop-t1 1 12"
cycle
chk "bell -> one surfaced row for the obligation" "$(surf)" 1
chk "bell executes nothing (no model call, no continuation row)" "$(calls)/$(cont)" "0/0"
chk "bell event acked from the queue after the route evidence" "$(qn)" 0
chk "outbox entry still unresolved after a bell" "$(resolved)" 0
# 2. approved: exactly one effect
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#901"; cycle
chk "approved -> exactly one continuation row" "$(cont)" 1
chk "continuation done-check is keyed to the obligation" "$(grep -c "obligations/$ID.$REV.$FP.done" "$T/asks.jsonl")" 1
chk "outbox entry marked resolved with the approval id" "$(grep -c '"approval":"#901"' "$T/st/outbox.jsonl")" 1
chk "handled receipt keyed to the obligation" "$([ -s "$T/rt/obligations/$ID.$REV.$FP.handled.json" ] && echo yes || echo no)" yes
chk "approved path ran no model" "$(calls)" 0
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#902"; cycle
chk "second approval of the same key: still one continuation row" "$(cont)" 1
# 3. unapproved (bell only, rejection, deferral): zero effect
fresh; suggest stop-t2 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t2)"; cycle
appr "REJECTED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#903"; cycle
appr "DEFERRED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#904"; cycle
chk "rejected/deferred/unapproved: zero continuation, zero resolved, zero model" "$(cont)/$(resolved)/$(calls)" 0/0/0
# 4. stale revision / wrong fingerprint / wrong seat
fresh; suggest stop-t3 "$BAD"; suggest stop-t3 "$BAD plus a lint" 2; cycle
read -r ID REV FP <<<"$(keyof stop-t3 1)"
appr "APPROVED-OBLIGATION id=$ID rev=1 fp=$FP approval=#905"; cycle
chk "stale revision (rev 2 exists): zero continuation, nothing resolved" "$(cont)/$(resolved)" 0/0
read -r ID REV2 FP2 <<<"$(keyof stop-t3 2)"
appr "APPROVED-OBLIGATION id=$ID rev=2 fp=000000000000 approval=#906"; cycle
chk "fingerprint mismatch: zero continuation" "$(cont)/$(resolved)" 0/0
printf 't | rb | APPROVED-OBLIGATION id=%s rev=2 fp=%s approval=#907\n' "$ID" "$FP2" >> "$T/ev/aide-events.log"; cycle
chk "approval text from a non-hermes/joe seat: zero continuation" "$(cont)/$(resolved)" 0/0
chk "none of the refusals reached the executor" "$(calls)" 0
# 5. arbitrary shell in the message is never run
fresh; suggest stop-t4 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t4)"
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#908; touch $T/pwned"; cycle
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=\$(touch $T/pwned)"; cycle
appr "APPROVED-OBLIGATION id=\$(touch $T/pwned) rev=$REV fp=$FP approval=#909"; cycle
chk "shell strings in an approval line: nothing executed, no file created" "$([ -e "$T/pwned" ] && echo ran || echo clean)/$(cont)/$(calls)" clean/0/0
# 6. restart mid-queue (bridge killed right after the resolve): queue kept, one effect after restart
fresh; suggest stop-t5 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t5)"; cycle
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#910"; : > "$T/crash.once"
crashcycle
chk "bridge killed mid-route: approval event still queued" "$(qn)" 1
chk "outbox resolved before the kill" "$(resolved)" 1
cycle
chk "after restart: queue drained" "$(qn)" 0
chk "after restart: exactly one continuation row" "$(cont)" 1
chk "after restart: handled receipt keyed to the obligation" "$([ -s "$T/rt/obligations/$ID.$REV.$FP.handled.json" ] && echo yes || echo no)" yes
chk "after restart: no model call" "$(calls)" 0
# 7. real-writer contract: the stamped third field is what the router accepts (section 2 already used the real writer); the stamp is really there
fresh; suggest stop-t6 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t6)"; cycle
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#920"
chk "real writer stamped the approval line (<src> H:MM AM/PM: APPROVED-OBLIGATION)" "$(grep -cE '\| hermes \| hermes [0-9]{1,2}:[0-9]{2} [AP]M: APPROVED-OBLIGATION' "$T/ev/aide-events.log")" 1
cycle; chk "stamped approval from the real writer -> one continuation row" "$(cont)" 1
# 8. key survives a 408-char bell (the waiter cut at 400 used to drop fp to 4 chars)
fresh; LONGID="stop-$(printf 'a1b2c3d4-%.0s' 1 2 3 4 5 6 7)"; suggest "$LONGID" "$BAD $BAD"
BL="$(grep -a "OBLIGATION-KEY id=$LONGID" "$T/ev/aide-events.log" | tail -1 | wc -c)"
chk "bell line is over 400 chars (realistic long id + detail)" "$([ "$BL" -gt 400 ] && echo long || echo "short $BL")" long
read -r ID REV FP <<<"$(keyof "$LONGID")"; cycle
chk "long bell -> surfaced with a whole key (no malformed row)" "$(surf)/$(grep -c 'without a usable typed key' "$T/asks.jsonl")" 1/0
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#921"; cycle
chk "long bell key approves: one continuation row" "$(cont)" 1
# 9. canonical approval validation: the caller label is not authority
fresh; suggest stop-t7 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t7)"; cycle
NOGRANT=1 APPR_SRC=hermes-joe-approved appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#777"; cycle
chk "forged hermes label + unknown approval id: zero continuation, nothing resolved" "$(cont)/$(resolved)" 0/0
NOGRANT=1 APPR_SRC=joe-fake appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#778"; cycle
chk "forged joe label + unknown approval id: zero continuation" "$(cont)/$(resolved)" 0/0
GRANT_RE="something else entirely" appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#779"; cycle
chk "approval id exists but its record names another subject: refused" "$(cont)/$(resolved)" 0/0
chk "refusals are surfaced as rows, never reach the executor" "$([ "$(grep -c 'approval' "$T/asks.jsonl")" -ge 2 ] && echo yes || echo no)/$(calls)" yes/0
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#780"; cycle
chk "a canonical approval record naming the obligation is accepted" "$(cont)/$(resolved)" 1/1
# 10. typed approved-action runner
printf '#!/bin/sh\ntouch %s/ran\nexit 0\n' "$T" > "$T/otests/demo.test.sh"; printf '#!/bin/sh\nexit 1\n' > "$T/otests/bad.test.sh"
dchk() { grep -a '"check"' "$T/asks.jsonl" | tail -1 | python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read())["check"])'; }
fresh; printf '#!/bin/sh\ntouch %s/ran\nexit 0\n' "$T" > "$T/otests/demo.test.sh"; printf '#!/bin/sh\nexit 1\n' > "$T/otests/bad.test.sh"
ACTION='{"verb":"named-test","name":"demo"}' suggest stop-t8 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t8)"; cycle
chk "typed action: nothing runs on the bell alone" "$([ -e "$T/ran" ] && echo ran || echo clean)" clean
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#930"; cycle
chk "typed action runs once under the approval" "$([ -e "$T/ran" ] && echo ran || echo clean)/$(cont)" ran/1
chk "run receipt keyed to the obligation (rc 0, approval, verb)" "$(grep -c '"rc": *0' "$T/rt/obligations/$ID.$REV.$FP.run.json" 2>/dev/null)/$(grep -c '#930' "$T/rt/obligations/$ID.$REV.$FP.run.json" 2>/dev/null)/$(python3 -I -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["verb"]=="named-test"))' "$T/rt/obligations/$ID.$REV.$FP.run.json" 2>/dev/null)" 1/1/1
chk "done-check is derived from the run receipt and passes without any manual touch" "$(E sh -c "$(dchk)" >/dev/null 2>&1 && echo pass || echo fail)/$(grep -c 'touch' "$T/asks.jsonl")" pass/0
chk "typed action ran no model" "$(calls)" 0
fresh; printf '#!/bin/sh\nexit 1\n' > "$T/otests/bad.test.sh"
ACTION='{"verb":"named-test","name":"bad"}' suggest stop-t9 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t9)"; cycle
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#931"; cycle
chk "failing action: receipt rc 1 and the done-check stays false" "$(grep -c '"rc": *1' "$T/rt/obligations/$ID.$REV.$FP.run.json" 2>/dev/null)/$(E sh -c "$(dchk)" >/dev/null 2>&1 && echo pass || echo fail)" 1/fail
fresh
ACTION="{\"verb\":\"sh\",\"cmd\":\"touch $T/pwned\"}" suggest stop-t10 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t10)"; cycle
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#932"; cycle
chk "verb outside the allow-list: nothing runs, receipt says refused" "$([ -e "$T/pwned" ] && echo ran || echo clean)/$(grep -c refused "$T/rt/obligations/$ID.$REV.$FP.run.json" 2>/dev/null)" clean/1
fresh
ACTION='{"verb":"named-test","name":"../../etc/x"}' suggest stop-t11 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t11)"; cycle
appr "APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=#933"; cycle
chk "path-traversal arg for an allowed verb: refused" "$(grep -c refused "$T/rt/obligations/$ID.$REV.$FP.run.json" 2>/dev/null)" 1
# 11. the surfaced row tells the approver the obligation id, the exact key and the two-step (approvals.log record naming the id, then the hermes line)
fresh; suggest stop-t12 "$BAD"; read -r ID REV FP <<<"$(keyof stop-t12)"; cycle
chk "surfaced row names id, exact key, approve.sh re: <id> and the approval= field" "$(grep -c "obligation id $ID .*key $ID.$REV.$FP.*approve.sh.*re: .*$ID.*APPROVED-OBLIGATION id=$ID rev=$REV fp=$FP approval=<id>" "$T/asks.jsonl")" 1
echo "ctl-event-obligation test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
