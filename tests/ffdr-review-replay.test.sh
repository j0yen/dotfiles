#!/usr/bin/env bash
# ffdr-review-replay.test.sh: A1300 FFDR spec r2 R4.4 (test T4). A fresh review of a task/skill/scope_id that already has reviews: a running or
# completed prior always refuses (freeze a new manifest); failed, interrupted and unknown priors refuse unless review.replay declares exactly
# them, and then one fourteen-field `replay` row precedes the launch row; a never-dispatched prior does not block; another scope_id never
# blocks. A resumed completed review is refused, a resumed failed one continues; review.replay on a resume, an empty-blocking-set declaration
# and every malformed declaration are refused; a reader failure, timeout or garbage refuses, and so does a reply of more than one JSON object
# or an outcome outside the reader's seven, on a fresh review and on a resume (PB-L2); an absent decisions log has no priors.
# Spy CLI, private lane state and log (fable-launch-review_lib.sh); no provider call. Run alone: bash tests/ffdr-review-replay.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
RD="$D/.local/lib/skill-route-terminal.py"; AL="$D/.local/lib/account-lane.py"; AFX="$D/tests/fixtures/account-lanes"
DECL='{reason:"prior review ended without a recorded verdict",evidence:["ledger:A1300"],prior:$p}'
# rq NAME TASK MANIFEST [PRIORS_JSON]: a dream review request (opus-xhigh) for the manifest; PRIORS_JSON adds review.replay with that prior list
rq(){ if [ -n "${4:-}" ]; then flr_req "$1" "$2" "$3" ".review.replay=(${DECL//\$p/$4})"; else flr_req "$1" "$2" "$3"; fi; }
nolaunch(){ [ "$(cat "$T/rc.$1")" = 64 ] && flr_spy_empty "$1" && [ "$(flr_count "$1" launch)" = 0 ] && [ "$(flr_count "$1" replay)" = 0 ] && [ "$(flr_count "$1" denied)" = 1 ]; }
why(){ flr_get "$1" 'select(.decision=="denied") | .reasons'; }
lane_jq(){ local s="$1"; shift; jq --arg s "$s" "$@" "$ACCOUNT_LANE_STATE/sessions.json" >"$T/ss.tmp" && mv "$T/ss.tmp" "$ACCOUNT_LANE_STATE/sessions.json"; }   # SID [jq args] FILTER: a fixture edit of the private lane state
flr_begin

# --- completed and running priors always refuse, declared or not
P1="$(uuid)"; rq c0 R-C "$FX/happy.sha256"; flr_run c0 c0 --session-id "$P1" -p x
ck "setup: review P1 of happy under R-C completed (spy exit 0)" '[ "$(python3 -I "$RD" --decisions "$DEC" session "$P1" | jq -r .terminal.outcome)" = completed ]'
rq c1 R-C "$FX/happy.sha256"; flr_run c1 c1 --session-id "$(uuid)" -p x
ck "completed prior: a fresh same-scope review is refused, nothing started, one denied row" 'nolaunch c1 && why c1 | grep -qF "unchanged-review-replay: scope_id $(flr_get c0 .scope_id) already reviewed by $P1 (completed); freeze a new manifest that adds the prior review'"'"'s result/findings or the disposition file"'
rq c2 R-C "$FX/prefixed.sha256" "[\"$P1\"]"; flr_run c2 c2 --session-id "$(uuid)" -p x
ck "completed prior: refused even when review.replay declares it (completed is not declarable)" 'nolaunch c2 && why c2 | grep -qF "already reviewed by $P1 (completed)"'
P2="$(uuid)"; rq r0 R-R "$FX/happy.sha256"; flr_run r0 r0 --session-id "$P2" -p x
sleep 60 & HOLD=$!; FLR_BG+=("$HOLD"); HS="$(cut -d')' -f2- /proc/$HOLD/stat | awk '{print $20}')"
lane_jq "$P2" --argjson p "$HOLD" --argjson st "$HS" '.sessions[$s].state="running" | .sessions[$s].claim={pid:$p,start:$st}'
ck "setup: review P2 now reads running (its claim is a live process whose argv does not carry P2, so the argv duplicate guard misses it)" '[ "$(python3 -I "$RD" --decisions "$DEC" session "$P2" | jq -r .terminal.outcome)" = running ]'
rq r1 R-R "$FX/happy.sha256"; flr_run r1 r1 --session-id "$(uuid)" -p x
ck "running prior: refused (64, not the 73 argv guard), nothing started" 'nolaunch r1 && why r1 | grep -qF "already reviewed by $P2 (running)"'
rq r2 R-R "$FX/happy.sha256" "[\"$P2\"]"; flr_run r2 r2 --session-id "$(uuid)" -p x
ck "running prior: refused even when declared" 'nolaunch r2 && why r2 | grep -qF "already reviewed by $P2 (running)"'
flr_kill "$HOLD"

# --- failed, interrupted and unknown priors block unless declared exactly
P3="$(uuid)"; rq f0 R-F "$FX/happy.sha256"; FLR_SPY_RC=1 flr_run f0 f0 --session-id "$P3" -p x
rq f1 R-F "$FX/happy.sha256"; flr_run f1 f1 --session-id "$(uuid)" -p x
ck "failed prior, no declaration: refused, the reason names P3 (failed) and the exact declaration to make" 'nolaunch f1 && why f1 | grep -qF "$P3 (failed)" && why f1 | grep -qF "declare review.replay {reason, evidence:[ledger:...], prior:[\"$P3\"]}"'
X1="$(uuid)"; rq f2 R-F "$FX/happy.sha256" "[\"$X1\"]"; flr_run f2 f2 --session-id "$(uuid)" -p x
ck "failed prior, a declaration missing it (names another id): refused" 'nolaunch f2 && why f2 | grep -qF "is not that set"'
rq f3 R-F "$FX/happy.sha256" "[\"$P3\",\"$X1\"]"; flr_run f3 f3 --session-id "$(uuid)" -p x
ck "failed prior, a declaration with an extra id: refused" 'nolaunch f3 && why f3 | grep -qF "is not that set"'
rq f4 R-F "$FX/happy.sha256" '[]'; flr_run f4 f4 --session-id "$(uuid)" -p x
ck "an empty prior list: refused by the resolver (review.replay.prior)" 'nolaunch f4 && why f4 | grep -qF "review.replay.prior"'
flr_req f5 R-F "$FX/happy.sha256" '.review.replay={reason:"prior review ended without a recorded verdict",evidence:["file:'"$T"'/ev.md"],prior:["'"$P3"'"]}'; flr_run f5 f5 --session-id "$(uuid)" -p x
ck "a declaration with no ledger: reference: refused" 'nolaunch f5 && why f5 | grep -qF "review.replay.evidence needs a ledger: reference"'
flr_req f6 R-F "$FX/happy.sha256" '.review.replay="replay it"'; flr_run f6 f6 --session-id "$(uuid)" -p x
ck "a malformed declaration (a string): refused" 'nolaunch f6 && why f6 | grep -qF "review.replay must be an object"'
flr_req f7 R-F - '.review={reason:"independent_verifier_required",evidence:["ledger:A1300"],replay:{reason:"prior review ended without a recorded verdict",evidence:["ledger:A1300"],prior:["'"$P3"'"]}}'; flr_run f7 f7 --session-id "$(uuid)" -p x
ck "a declaration without review.snapshot: refused" '[ "$(cat $T/rc.f7)" = 64 ] && flr_spy_empty f7 && why f7 | grep -qF "review.replay needs review.snapshot"'
SOK="$(uuid)"; rq f8 R-F "$FX/reordered.sha256" "[\"$P3\"]"; flr_mark; flr_run f8 f8 --session-id "$SOK" -p x
ck "the exact declaration [P3]: the review starts (rc 0, the spy got its id)" '[ "$FLR_RC" = 0 ] && grep -q -- "--session-id $SOK" "$T/spy.f8"'
ck "exactly one replay row, immediately before the launch row" '[ "$(jq -r .decision "$T/new.f8" | tr "\n" " ")" = "replay launch " ]'
ck "the replay row has the fourteen fields in order and route, model, effort, account, session, resume, role, scope, scope_id equal to the launch row" '[ "$(jq -c "keys_unsorted" <(head -1 "$T/new.f8"))" = "$FLR_FIELDS" ] && [ "$(head -1 "$T/new.f8" | jq -c "[.task_id,.skill,.route,.model,.effort,.account,.session,.resume,.role,.scope,.scope_id]")" = "$(tail -1 "$T/new.f8" | jq -c "[.task_id,.skill,.route,.model,.effort,.account,.session,.resume,.role,.scope,.scope_id]")" ]'
ck "the replay row reasons are compact JSON {prior, prior_outcomes, reason, evidence}" '[ "$(head -1 "$T/new.f8" | jq -r .reasons)" = "{\"prior\":[\"$P3\"],\"prior_outcomes\":{\"$P3\":\"failed\"},\"reason\":\"prior review ended without a recorded verdict\",\"evidence\":[\"ledger:A1300\"]}" ]'
ck "the launch row keeps the resolver reasons (not the declaration)" 'tail -1 "$T/new.f8" | jq -e ".decision==\"launch\" and (.reasons|startswith(\"decision_class consequential_uncertainty\"))" >/dev/null'
ck "log prefix unchanged and every appended row (the replay row included) carries the fourteen fields (flr_appended_ok)" flr_appended_ok
rq f9 R-F "$FX/single.sha256"; flr_run f9 f9 --session-id "$(uuid)" -p x
ck "another scope_id of the same task (single): never blocked by P3, no declaration needed" '[ "$FLR_RC" = 0 ] && [ "$(flr_count f9 launch)" = 1 ] && [ "$(flr_count f9 replay)" = 0 ]'
P4="$(uuid)"; rq i0 R-I "$FX/happy.sha256"; flr_run i0 i0 --session-id "$P4" -p x
lane_jq "$P4" '.sessions[$s].state="running" | .sessions[$s].claim={pid:999999999,start:1}'
ck "setup: review P4 reads interrupted (state running, claim not alive)" '[ "$(python3 -I "$RD" --decisions "$DEC" session "$P4" | jq -r .terminal.outcome)" = interrupted ]'
rq i1 R-I "$FX/happy.sha256"; flr_run i1 i1 --session-id "$(uuid)" -p x
ck "interrupted prior, no declaration: refused naming P4 (interrupted)" 'nolaunch i1 && why i1 | grep -qF "$P4 (interrupted)"'
rq i2 R-I "$FX/happy.sha256" "[\"$P4\"]"; flr_run i2 i2 --session-id "$(uuid)" -p x
ck "interrupted prior declared exactly: starts after one replay row" '[ "$FLR_RC" = 0 ] && [ "$(jq -r .decision "$T/new.i2" | tr "\n" " ")" = "replay launch " ]'
P5="$(uuid)"; flr_inject "$(jq -nc --arg s "$P5" --arg sc "$(flr_get c0 .scope_id)" '{ts:"2026-11-17T00:00:00-08:00",decision:"launch",task_id:"R-U",skill:"dream",route:"opus-xhigh",model:"claude-opus-5-5",effort:"xhigh",account:"josephsyen",session:$s,resume:false,reasons:"fixture",role:"review",scope:"/x",scope_id:$sc}')"
rq u1 R-U "$FX/happy.sha256"; flr_run u1 u1 --session-id "$(uuid)" -p x
ck "unknown prior (a review launch row with no lane entry): refused naming P5 (unknown)" 'nolaunch u1 && why u1 | grep -qF "$P5 (unknown)"'
rq u2 R-U "$FX/happy.sha256" "[\"$P5\"]"; flr_run u2 u2 --session-id "$(uuid)" -p x
ck "unknown prior declared exactly: starts after one replay row" '[ "$FLR_RC" = 0 ] && [ "$(jq -r .decision "$T/new.u2" | tr "\n" " ")" = "replay launch " ]'
rq i3 R-I "$FX/happy.sha256" "[\"$P4\"]"; flr_run i3 i3 --session-id "$(uuid)" -p x
ck "once the replayed review i2 has completed, a further same-scope review is refused even with P4 declared (i2 is a completed prior)" 'nolaunch i3 && why i3 | grep -qF "already reviewed by $(flr_get i2 "select(.decision==\"launch\") | .session") (completed)"'

# --- never-dispatched priors do not block; a declaration with an empty blocking set is stale
cat >"$T/claude-limit" <<'S'
#!/usr/bin/env bash
sid=""; prev=""; for x in "$@"; do case "$prev" in --session-id|--resume) sid="$x";; esac; prev="$x"; done
echo "spy args=$*" >>"$SPYLOG"; jq -c --arg s "$sid" '.session_id=$s' "$T4_AFX/native-fable-limit-observed.json"; exit 1
S
chmod +x "$T/claude-limit"
P6="$(sid="$(uuid)"; printf '7b82413f-%s' "${sid:9}")"
jq -nc --arg s "$FX/happy.sha256" --arg ev "file:$T/ev.md" '{task_id:"R-N",skill:"5whysandrhyme",review:{reason:"independent_verifier_required",evidence:["ledger:A1300",$ev],snapshot:$s}}' >"$T/req.n0.json"
FABLE_CLAUDE_BIN="$T/claude-limit" T4_AFX="$AFX" flr_run n0 n0 --session-id "$P6" --output-format json -p x >/dev/null
ck "setup: a Fable review P6 refused at start by the observed limit reads never-dispatched" '[ "$(python3 -I "$RD" --decisions "$DEC" session "$P6" | jq -r .terminal.outcome)" = never-dispatched ]'
cp "$T/req.n0.json" "$T/req.n1.json"; flr_run n1 n1 --session-id "$(uuid)" -p x
ck "never-dispatched prior: a fresh same-scope review starts without a declaration and writes no replay row" '[ "$FLR_RC" = 0 ] && [ "$(flr_count n1 launch)" = 1 ] && [ "$(flr_count n1 replay)" = 0 ]'
python3 -I "$AL" clear --account jyen.pm --lane fable --by t4 --reason "reset between T4 scenarios" >/dev/null
P7="$(uuid)"; jq -c '.task_id="R-N2"' "$T/req.n0.json" >"$T/req.n3.json"; FABLE_CLAUDE_BIN="$T/claude-limit" T4_AFX="$AFX" flr_run n3 n3 --session-id "$P7" --output-format json -p x >/dev/null
jq -c --arg p "$P7" '.review.replay={reason:"prior review ended without a recorded verdict",evidence:["ledger:A1300"],prior:[$p]}' "$T/req.n3.json" >"$T/req.n4.json"; flr_run n4 n4 --session-id "$(uuid)" -p x
ck "a declaration over only a never-dispatched prior (empty blocking set): refused as a stale replay declaration" 'nolaunch n4 && why n4 | grep -qF "stale replay declaration"'
rq s1 R-NEW "$FX/happy.sha256" "[\"$(uuid)\"]"; flr_run s1 s1 --session-id "$(uuid)" -p x
ck "a declaration on a scope with no prior review at all: stale replay declaration" 'nolaunch s1 && why s1 | grep -qF "stale replay declaration"'

# --- resumes: a completed review is not resumed; a failed one continues; a declaration on a resume is refused
rq m1 R-C "$FX/happy.sha256"; flr_run m1 m1 --resume "$P1" -p again
ck "resume of the completed review P1: refused unchanged-review-replay, nothing started" 'nolaunch m1 && why m1 | grep -qF "review session $P1 already completed"'
rq m2 R-F "$FX/happy.sha256" "[\"$P3\"]"; FABLE_LAUNCH_ACK_UNKNOWN_EFFECT=1 flr_run m2 m2 --resume "$P3" -p again
ck "a review.replay declaration on a resume (of failed P3): refused" 'nolaunch m2 && why m2 | grep -qF "stale replay declaration: review.replay on a resume"'
rq m3 R-F "$FX/happy.sha256"; FABLE_LAUNCH_ACK_UNKNOWN_EFFECT=1 flr_run m3 m3 --resume "$P3" -p again
ck "resume of the failed review P3 (with the ack): continues with its own role and scope, no replay row" '[ "$FLR_RC" = 0 ] && grep -q -- "--resume $P3" "$T/spy.m3" && [ "$(flr_get m3 "[.decision,.role]|join(\",\")")" = "launch,review" ] && [ "$(flr_count m3 replay)" = 0 ]'

# --- the reader: failure, timeout or garbage refuses; a reply about another session counts as unknown
cat >"$T/rd-fake" <<'S'
#!/usr/bin/env python3
# T4 fake reader (the launcher runs it as `python3 -I <file>`): review-ancestor goes to the real reader (mode anc-null answers it with
# null instead, without reading the log); session misbehaves by T4_RD_MODE (twice: the real reader's reply printed twice; bogus: one object
# about the asked session whose outcome is not one of the reader's seven).
import json, os, subprocess, sys, time
if "review-ancestor" in sys.argv[1:]:
    if os.environ.get("T4_RD_MODE") == "anc-null":
        print('{"review_session": null, "pid": null, "reason": "stand-in"}')
        sys.exit(0)
    os.execvp("python3", ["python3", "-I", os.environ["T4_RD"]] + sys.argv[1:])
mode = os.environ.get("T4_RD_MODE", "")
if mode == "exit":
    sys.exit(3)
if mode == "sleep":
    time.sleep(15)
if mode == "garbage":
    print("not json {")
if mode == "other":
    print('{"session":"00000000-0000-4000-8000-000000000000","terminal":{"outcome":"completed","rc":0,"reasons":[]}}')
if mode == "twice":
    r = subprocess.run(["python3", "-I", os.environ["T4_RD"]] + sys.argv[1:], capture_output=True, text=True)
    sys.stdout.write(r.stdout + r.stdout)
    sys.exit(r.returncode)
if mode == "bogus":
    print(json.dumps({"session": sys.argv[sys.argv.index("session") + 1], "terminal": {"outcome": "bogus", "rc": None, "reasons": []}}))
S
chmod +x "$T/rd-fake"; export T4_RD="$RD"
P8="$(uuid)"; rq g0 R-G "$FX/happy.sha256"; FLR_SPY_RC=1 flr_run g0 g0 --session-id "$P8" -p x
for mode in exit garbage; do
  rq "g$mode" R-G "$FX/happy.sha256" "[\"$P8\"]"; SKILL_ROUTE_TERMINAL="$T/rd-fake" T4_RD_MODE=$mode flr_run "g$mode" "g$mode" --session-id "$(uuid)" -p x
  ck "reader $mode (the declaration would be exact): refused, check failed" 'nolaunch g$mode && why g$mode | grep -qF "unchanged-review-replay check failed"'
done
rq gsleep R-G "$FX/happy.sha256" "[\"$P8\"]"; s0=$(date +%s); SKILL_ROUTE_TERMINAL="$T/rd-fake" T4_RD_MODE=sleep flr_run gsleep gsleep --session-id "$(uuid)" -p x; s1=$(date +%s)
ck "reader hangs: refused after the 10 s bound (timeout), check failed" 'nolaunch gsleep && why gsleep | grep -qF "check failed" && [ $((s1-s0)) -ge 9 ] && [ $((s1-s0)) -lt 15 ]'
rq gother R-G "$FX/happy.sha256"; SKILL_ROUTE_TERMINAL="$T/rd-fake" T4_RD_MODE=other flr_run gother gother --session-id "$(uuid)" -p x
ck "a reader reply about another session: the prior counts as unknown (blocks; never read as completed)" 'nolaunch gother && why gother | grep -qF "$P8 (unknown)"'
rq greal R-G "$FX/happy.sha256"; flr_run greal greal --session-id "$(uuid)" -p x
ck "without SKILL_ROUTE_TERMINAL the same request reads the real outcome (failed)" 'nolaunch greal && why greal | grep -qF "$P8 (failed)"'
# A1300 FFDR PB-L2: the reply is exactly one JSON object, and both outcome checks deny every outcome outside the reader's seven. P9 completed.
P9="$(uuid)"; rq t0 R-T "$FX/happy.sha256"; flr_run t0 t0 --session-id "$P9" -p x
rq t1 R-T "$FX/happy.sha256"; SKILL_ROUTE_TERMINAL="$T/rd-fake" T4_RD_MODE=twice flr_run t1 t1 --session-id "$(uuid)" -p x
ck "PB-L2: a two-object reply (P9's real completed reply, twice) refuses a fresh same-scope review: check failed, not exactly one JSON object" 'nolaunch t1 && why t1 | grep -qF "session $P9: non-zero exit, timeout, or output that is not exactly one JSON object"'
rq t2 R-T "$FX/happy.sha256"; SKILL_ROUTE_TERMINAL="$T/rd-fake" T4_RD_MODE=twice flr_run t2 t2 --resume "$P9" -p again
ck "PB-L2: the same two-object reply refuses a resume of P9, nothing started" 'nolaunch t2 && why t2 | grep -qF "session $P9: non-zero exit, timeout, or output that is not exactly one JSON object"'
rq t3 R-T "$FX/happy.sha256"; SKILL_ROUTE_TERMINAL="$T/rd-fake" T4_RD_MODE=bogus flr_run t3 t3 --session-id "$(uuid)" -p x
ck "PB-L2: one object whose outcome is outside the reader's seven (bogus) refuses a fresh review (the fresh-review check is exhaustive)" 'nolaunch t3 && why t3 | grep -qF "session $P9: unexpected outcome" && why t3 | grep -qF bogus'
rq t4 R-T "$FX/happy.sha256"; SKILL_ROUTE_TERMINAL="$T/rd-fake" T4_RD_MODE=bogus flr_run t4 t4 --resume "$P9" -p again
ck "PB-L2: the same outcome refuses a resume of P9 (the resume check is exhaustive), nothing started" 'nolaunch t4 && why t4 | grep -qF "session $P9: unexpected outcome" && why t4 | grep -qF bogus'
rq t5 R-T "$FX/happy.sha256"; flr_run t5 t5 --session-id "$(uuid)" -p x
ck "control: with the real reader the same fresh request is refused by P9's real outcome (completed)" 'nolaunch t5 && why t5 | grep -qF "already reviewed by $P9 (completed)"'

# --- an absent decisions log has no priors (no reader call); a present but unreadable one refuses
mkdir -p "$T/fresh"; rq a1 R-A "$FX/happy.sha256"; : >"$T/spy.a1"
SKILL_ROUTING_DECISIONS="$T/fresh/dec.jsonl" SKILL_ROUTE_TERMINAL="$T/rd-fake" T4_RD_MODE=exit SPYLOG="$T/spy.a1" "$L" --route-request "$T/req.a1.json" --session-id "$(uuid)" -p x 2>"$T/err.a1"; arc=$?
ck "absent decisions log: a review starts with no prior lookup (the failing fake reader is never asked for an outcome)" '[ "$arc" = 0 ] && [ -s "$T/spy.a1" ] && [ "$(jq -r .decision "$T/fresh/dec.jsonl" | tr "\n" " ")" = "launch " ]'
cp "$DEC" "$T/dec.noread"; chmod 000 "$T/dec.noread"
if [ -r "$T/dec.noread" ]; then echo "NOTE running as a user who can read mode 000 files; the unreadable-log case is not exercised"; else
  rq a2 R-F "$FX/happy.sha256" "[\"$P3\"]"; : >"$T/spy.a2"
  SKILL_ROUTING_DECISIONS="$T/dec.noread" SPYLOG="$T/spy.a2" "$L" --route-request "$T/req.a2.json" --session-id "$(uuid)" -p x 2>"$T/err.a2"; urc=$?
  ck "present but unreadable decisions log: refused (64), nothing started; its first reader, R4.2's review-ancestor, already fails closed" '[ "$urc" = 64 ] && [ ! -s "$T/spy.a2" ] && grep -qF "nested-dispatch check failed" "$T/err.a2"'
  rq a3 R-U "$FX/happy.sha256"; : >"$T/spy.a3"
  SKILL_ROUTING_DECISIONS="$T/dec.noread" SKILL_ROUTE_TERMINAL="$T/rd-fake" T4_RD_MODE=anc-null SPYLOG="$T/spy.a3" "$L" --route-request "$T/req.a3.json" --session-id "$(uuid)" -p x 2>"$T/err.a3"; u3=$?
  ck "with review-ancestor answered by a stand-in, R4.4's own check refuses the unreadable log for a review with no declaration (never read as no priors)" '[ "$u3" = 64 ] && [ ! -s "$T/spy.a3" ] && grep -qF "decisions log $T/dec.noread present but unreadable" "$T/err.a3"'; fi
flr_end
