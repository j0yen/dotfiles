#!/usr/bin/env bash
# Usage: ctl-obligation-queue.test.sh <test-name>...   (no arg lists names)
# Fixture-only: CTL_OQ_FIXTURE honoured with --test; never touches the live ledger.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
Q="$HERE/.local/bin/ctl-obligation-queue.py"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export CTL_OQ_STATE="$W/state"
NOW="2026-11-07T12:00"
fail=0
ok(){ echo "PASS $1"; }
bad(){ echo "FAIL $1: $2"; fail=1; }

row(){ # id owner due what [waits_on-json] [claim]
  python3 - "$@" <<'PY'
import json,sys
a=sys.argv[1:]
i,o,d,w=a[:4]; wo=json.loads(a[4]) if len(a)>4 else []; cl=a[5] if len(a)>5 else None
print(json.dumps({"ask_id":i,"row_id":"d-"+i,"owner":o,"due":d,"what":w,"check":"c","key":"k","status":"open","claim":cl,"waits_on":wo,"ready":False}))
PY
}
fixture(){ # file row...
  local f=$1; shift; local first=1
  { echo '{"now":"'$NOW'","followups":[],"asks":['; for r in "$@"; do [ $first = 1 ] || echo ,; echo "$r"; first=0; done; echo ']}'; } >"$f"
}
q(){ CTL_OQ_FIXTURE="$1" python3 "$Q" --test "${@:2}"; }
jq_(){ python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

t_safety_beats_discretionary(){
  fixture $W/f.json "$(row A1 ctl 2026-11-05T09:00 'prod outage: data integrity check failing')" "$(row A2 ctl 2026-11-07T11:00 'discretionary: tidy notes')"
  top=$(q $W/f.json queue --json | jq_ "d['queue'][0]['ask_id']")
  [ "$top" = A1 ] && ok safety || bad safety "top=$top"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null; rc=$?
  [ $rc = 3 ] && ok safety-refuse || bad safety-refuse "rc=$rc"
}
t_authorized_overdue_beats_discretionary(){
  fixture $W/f.json "$(row A1 ctl 2026-11-01T09:00 'ship the foo report')" "$(row A2 ctl 2026-11-09T11:00 'discretionary: new idea')"
  top=$(q $W/f.json queue --json | jq_ "d['queue'][0]['ask_id']+str(d['queue'][0]['class'])")
  [ "$top" = A12 ] && ok overdue || bad overdue "top=$top"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null; rc=$?
  [ $rc = 3 ] && ok overdue-refuse || bad overdue-refuse "rc=$rc"
}
t_blocked_higher_allows_independent(){
  fixture $W/f.json "$(row A1 ctl 2026-11-01T09:00 'prod fix waits-on=person:joe key needed from joe for the rotation')" "$(row A2 ctl 2026-11-09T11:00 'discretionary: new idea')"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null; rc=$?
  [ $rc = 0 ] && ok independent || bad independent "rc=$rc"
  blk=$(q $W/f.json queue --json | jq_ "d['blocked'][0]['dependency_owner']")
  [ "$blk" = joe ] && ok blocked-owner || bad blocked-owner "$blk"
}
t_dependency_repair_allowed(){
  fixture $W/f.json "$(row A1 rb 2026-11-01T09:00 'prod fix' '["A2"]')" "$(row A2 ctl 2026-11-09T11:00 'discretionary: repair tool')" "$(row A3 ctl 2026-11-01T09:00 'overdue commitment')"
  c=$(q $W/f.json queue --json | jq_ "[x['class'] for x in d['queue'] if x['ask_id']=='A2'][0]")
  [ "$c" = 1 ] && ok repair-class || bad repair-class "$c"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null; rc=$?
  [ $rc = 0 ] && ok repair-allowed || bad repair-allowed "rc=$rc"
}
t_active_worker_not_duplicated(){
  fixture $W/f.json "$(row A1 ctl 2026-11-01T09:00 'overdue commitment' '[]' 'worker-9')" "$(row A2 ctl 2026-11-09T11:00 'discretionary: x')"
  ids=$(q $W/f.json queue --json | jq_ "[x['ask_id'] for x in d['queue']]")
  act=$(q $W/f.json queue --json | jq_ "[x['ask_id'] for x in d['active']]")
  [ "$ids" = "['A2']" ] && [ "$act" = "['A1']" ] && ok active || bad active "ids=$ids act=$act"
  q $W/f.json decide A1 --class overdue --rationale r >/dev/null; rc=$?
  [ $rc = 5 ] && ok active-dup-refused || bad active-dup-refused "rc=$rc"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null; rc=$?
  [ $rc = 0 ] && ok claimed-not-candidate || bad claimed-not-candidate "rc=$rc"
}
t_future_checkpoint_does_not_hide(){
  fixture $W/f.json "$(row A1 ctl 2026-11-20T09:00 'prod recovery drill; checkpoint 2026-11-20')"
  r=$(q $W/f.json queue --json | jq_ "[x['ask_id'] for x in d['queue']]")
  [ "$r" = "['A1']" ] && ok future-visible || bad future-visible "$r"
}
t_explicit_not_before_respected(){
  fixture $W/f.json "$(row A1 ctl 2026-11-01T09:00 'overdue commitment not-before=2026-11-08T09:00')" "$(row A2 ctl 2026-11-09T11:00 'discretionary: x')"
  r=$(q $W/f.json queue --json | jq_ "[x['ask_id'] for x in d['queue']]")
  [ "$r" = "['A2']" ] && ok not-before || bad not-before "$r"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null; rc=$?
  [ $rc = 0 ] && ok not-before-nogate || bad not-before-nogate "rc=$rc"
}
t_valid_exception_auditable(){
  fixture $W/f.json "$(row A1 ctl 2026-11-01T09:00 'overdue commitment')" "$(row A2 ctl 2026-11-09T11:00 'discretionary: x')"
  q $W/f.json decide A2 --class discretionary --rationale r --exception-reason "joe asked" >/dev/null; rc=$?
  [ $rc = 3 ] && ok partial-exception-refused || bad partial-exception-refused "rc=$rc"
  q $W/f.json decide A2 --class discretionary --rationale r --exception-reason "joe asked" --exception-owner ctl --exception-approval "approvals #999" --exception-review-trigger "A1 done" >/dev/null; rc=$?
  [ $rc = 0 ] && ok exception-allowed || bad exception-allowed "rc=$rc"
  L=$(tail -1 "$CTL_OQ_STATE/decisions.jsonl")
  echo "$L" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());assert d['task_id']=='A2' and d['higher_priority_candidates']==['A1'] and d['exception']['owner']=='ctl' and d['exception']['source_approval']=='approvals #999' and d['exception']['review_trigger']" && ok exception-recorded || bad exception-recorded "$L"
  # A1289 F4: a valid recorded exception is detected AS a valid exception, never counted as a bypass (was: len(bypasses)==1)
  o=$(q $W/f.json observe --json | jq_ "(len(d['bypasses']),[(x['task_id'],x['higher_priority_candidates'],x['exception_valid']) for x in d['valid_exceptions']])")
  [ "$o" = "(0, [('A2', ['A1'], True)])" ] && ok observe-detects || bad observe-detects "$o"
}
t_unavailable_source_fails_visibly(){
  mkdir -p $W/bin; printf '#!/bin/sh\necho boom >&2\nexit 1\n' >$W/bin/wm-asks; chmod +x $W/bin/wm-asks
  out=$(CTL_OQ_WM_ASKS="$W/bin/wm-asks" python3 "$Q" --test queue 2>&1); rc=$?
  if [ $rc = 4 ] && echo "$out" | grep -qi 'canonical source unavailable'; then ok unavailable; else bad unavailable "rc=$rc out=$out"; fi
  fixture $W/f.json "$(row A1 ctl 2026-11-01T09:00 'x')"
  src=$(CTL_OQ_FIXTURE="$W/f.json" python3 "$Q" queue --json 2>/dev/null | jq_ "d['source']")
  [ "$src" = wm-asks ] && ok no-fixture-without-test || bad no-fixture-without-test "source=$src"
  if grep -qi 'tsv' "$Q"; then bad no-tsv-fallback "script mentions a tsv"; else ok no-tsv-fallback; fi
}
t_big_backlog_no_global_freeze(){
  python3 - $W/f.json <<'PY'
import json,sys
def r(i,due,what): return {"ask_id":i,"row_id":"d-"+i,"owner":"ctl","due":due,"what":what,"check":"c","key":"k","status":"open","claim":None,"waits_on":[],"ready":False}
rows=[r("B%d"%i,"2026-10-01T00:00","stale commitment") for i in range(391)]
rows.append(r("S1","2026-10-01T00:00","security: rotate leaked credential"))
rows.append(r("D1","2026-12-01T00:00","discretionary: new thing"))
json.dump({"now":"2026-11-07T12:00","asks":rows,"followups":[]},open(sys.argv[1],"w"))
PY
  top=$(q $W/f.json queue --json | jq_ "d['queue'][0]['ask_id']"); [ "$top" = S1 ] && ok backlog-top-safety || bad backlog-top-safety "$top"
  q $W/f.json decide S1 --class safety --rationale r >/dev/null; rc=$?; [ $rc = 0 ] && ok backlog-safety-runs || bad backlog-safety-runs "rc=$rc"
  q $W/f.json decide B7 --class overdue --rationale r >/dev/null; rc=$?; [ $rc = 0 ] && ok backlog-overdue-runs || bad backlog-overdue-runs "rc=$rc"
  n=$(q $W/f.json queue --json | jq_ "len(d['queue'])"); [ "$n" -ge 392 ] && ok backlog-queue-full || bad backlog-queue-full $n
}
t_blocker_without_structure_is_triage_defect(){
  fixture $W/f.json "$(row A1 ctl 2026-11-01T09:00 'commitment; blocked on something unclear')"
  r=$(q $W/f.json queue --json | jq_ "d['queue']==[] and d['triage_defects'][0]['ask_id']=='A1'")
  [ "$r" = True ] && ok triage-defect || bad triage-defect "$r"
}
t_row_dependency_closed_not_blocking(){
  fixture $W/f.json "$(row A1 ctl 2026-11-01T09:00 'commitment waits-on=row:A99')"
  r=$(q $W/f.json queue --json | jq_ "[x['ask_id'] for x in d['queue']]")
  [ "$r" = "['A1']" ] && ok closed-dep-ready || bad closed-dep-ready "$r"
}

# --- A1289 F1-F5 correction (SYNTHETIC fixtures only; not live runtime acceptance) ---
# Start evidence is the existing canonical wm-asks interface: `asks query --json` (claim, rev) and
# `asks events ID --json` (op=claim rows: rev, ts, detail {"worker","claim"}). Fixtures model those
# outputs under the key "events"; a fixture without that key models an events source that is unavailable.
pyfx(){ # file python-dict-expression; helpers R(...) row and CE(...) canonical claim event
  python3 - "$1" "$2" <<'PY2'
import json,sys
def R(i,o,d,w,rev=1,claim=None,waits=None,status="open"):
    return {"ask_id":i,"row_id":"d-"+i,"owner":o,"due":d,"what":w,"check":"c","key":"k","status":status,"claim":claim,"waits_on":waits or [],"ready":False,"rev":rev}
def CE(i,rev,worker,ts,stamp=None,op="claim"):
    # canonical event ts carries its UTC offset (store.now().isoformat()); a bare local time is given the fixture's -08:00
    return {"seq":rev,"ask_id":i,"rev":rev,"ts":ts if len(ts)>19 else ts+"-08:00","actor":worker,"op":op,"detail":json.dumps({"claim":stamp or "%s@%s"%(worker,ts[:16]),"worker":worker},sort_keys=True)}
d=eval(sys.argv[2]); d.setdefault("now","2026-11-07T12:00"); d.setdefault("followups",[])
json.dump(d,open(sys.argv[1],"w"))
PY2
}
obs(){ q "$1" observe --json; }           # prints JSON; rc is observe's
field(){ python3 -c "import json,sys;d=json.loads(sys.stdin.read() or '{}');print($1)" 2>/dev/null; }
clk(){ date +%Y-%m-%dT%H:%M:%S%:z; }   # offset-aware local time, as the canonical ledger writes it
BASE='R("S1","ctl","2026-11-01T09:00","security: rotate leaked credential"), R("A1","ctl","2026-11-01T09:00","ship the foo report")'

t_f1_unlogged_start_detected(){
  # A2 is discretionary; ready class-1 S1 and class-2 A1 exist; A2 was claimed (canonical claim event) with no decide call.
  # A logged decision for a DIFFERENT task (A1, wrong-task evidence) must not cover the A2 start.
  pyfx $W/f.json "{'asks':[$BASE]}"
  q $W/f.json decide A1 --class overdue --rationale r >/dev/null
  T=$(clk)
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes',rev=2,claim='w2@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w2','$T')]}}"
  out=$(obs $W/f.json); rc=$?
  k=$(echo "$out" | field "[b['kind'] for b in d['bypasses'] if b['ask_id']=='A2']")
  [ "$k" = "['unlogged-start']" ] && ok f1-unlogged-bypass || bad f1-unlogged-bypass "kinds=$k"
  r=$(echo "$out" | field "d['result']"); [ "$r" = BYPASS ] && [ $rc = 6 ] && ok f1-result-bypass || bad f1-result-bypass "result=$r rc=$rc"
  w=$(echo "$out" | field "[s['worker']+':'+str(s['claim_rev']) for s in d['starts'] if s['ask_id']=='A2']")
  [ "$w" = "['w2:2']" ] && ok f1-start-identity || bad f1-start-identity "$w"
  # the same unlogged start is a bypass even when the events source is unavailable: no decision record exists at all
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes',rev=2,claim='w2@'+'$T'[:16])]}"
  k=$(obs $W/f.json | field "[b['kind'] for b in d['bypasses'] if b['ask_id']=='A2']")
  [ "$k" = "['unlogged-start']" ] && ok f1-unlogged-without-events || bad f1-unlogged-without-events "kinds=$k"
}
t_f2_refused_then_started_detected(){
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes')]}"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null; rc=$?
  [ $rc = 3 ] && ok f2-refused || bad f2-refused "rc=$rc"
  T=$(clk)
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes',rev=2,claim='w2@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w2','$T')]}}"
  out=$(obs $W/f.json); rc=$?
  k=$(echo "$out" | field "[b['kind'] for b in d['bypasses'] if b['ask_id']=='A2']")
  [ "$k" = "['refused-then-started']" ] && [ $rc = 6 ] && ok f2-detected || bad f2-detected "kinds=$k rc=$rc"
  n=$(echo "$out" | field "len([x for x in d['refusals'] if x['task_id']=='A2'])"); [ "$n" = 1 ] && ok f2-attempt-listed || bad f2-attempt-listed "$n"
}
t_f3_declared_class_not_authority(){
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes')]}"
  for c in unblocker safety overdue; do
    q $W/f.json decide A2 --class $c --rationale r >/dev/null; rc=$?
    [ $rc = 3 ] && ok f3-forged-$c-refused || bad f3-forged-$c-refused "rc=$rc"
  done
  L=$(tail -1 "$CTL_OQ_STATE/decisions.jsonl")
  echo "$L" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());assert d['class_label']=='overdue' and d['computed_priority_class']==3 and d['class_supported'] is False and d['higher_priority_candidates']==['S1','A1'] and d['outcome']=='refused'" 2>/dev/null && ok f3-computed-recorded || bad f3-computed-recorded "$L"
  # a legacy allowed record that trusted a forged class, followed by a claim, is reported as a bypass
  T=$(clk)
  printf '%s\n' '{"ts":"'"$T"'","task_id":"A2","actor":"ctl","priority_class":1,"class_label":"unblocker","rationale":"r","higher_priority_candidates":[],"dependency_repair":false,"exception":null,"exception_valid":false,"outcome":"allowed","decision_reason":"no actionable higher-priority candidate","source":"fixture","ledger_now":"2026-11-07T12:00"}' > "$CTL_OQ_STATE/decisions.jsonl"
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes',rev=2,claim='w2@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w2','$T')]}}"
  k=$(obs $W/f.json | field "[b['kind'] for b in d['bypasses'] if b['ask_id']=='A2']")
  [ "$k" = "['forged-class']" ] && ok f3-legacy-forged-detected || bad f3-legacy-forged-detected "kinds=$k"
}
t_genuine_priority_and_repair_allowed(){
  # controls: authoritative class 1/2 and genuine dependency repair still start
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: repair tool'), R('A9','rb','2026-11-01T09:00','prod fix',waits=['A2'])]}"
  q $W/f.json decide S1 --class safety --rationale r >/dev/null; rc=$?; [ $rc = 0 ] && ok ctl-genuine-safety || bad ctl-genuine-safety "rc=$rc"
  q $W/f.json decide A1 --class overdue --rationale r >/dev/null; rc=$?; [ $rc = 0 ] && ok ctl-genuine-overdue || bad ctl-genuine-overdue "rc=$rc"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null; rc=$?; [ $rc = 0 ] && ok ctl-repair-discretionary || bad ctl-repair-discretionary "rc=$rc"
  q $W/f.json decide A2 --class unblocker --rationale r >/dev/null; rc=$?; [ $rc = 0 ] && ok ctl-repair-unblocker || bad ctl-repair-unblocker "rc=$rc"
  L=$(tail -1 "$CTL_OQ_STATE/decisions.jsonl")
  echo "$L" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());assert d['dependency_repair'] is True and d['computed_priority_class']==1 and d['outcome']=='allowed'" 2>/dev/null && ok ctl-repair-recorded || bad ctl-repair-recorded "$L"
}
t_f4_valid_exception_not_bypass(){
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment'), R('A2','ctl','2026-11-09T11:00','discretionary: x')]}"
  q $W/f.json decide A2 --class discretionary --rationale r --exception-reason "joe asked" --exception-owner ctl --exception-approval "approvals #999" --exception-review-trigger "A1 done" >/dev/null; rc=$?
  [ $rc = 0 ] && ok f4-exception-allowed || bad f4-exception-allowed "rc=$rc"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "(len(d['bypasses']),len(d['valid_exceptions']),d['result'])")
  [ "$r" = "(0, 1, 'CLEAN')" ] && [ $rc = 0 ] && ok f4-exception-not-bypass || bad f4-exception-not-bypass "$r rc=$rc"
  T=$(clk)
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment'), R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='w1@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w1','$T')]}}"
  r=$(obs $W/f.json | field "([s['authorization'] for s in d['starts']],len(d['bypasses']),d['result'])")
  [ "$r" = "(['valid-exception'], 0, 'CLEAN')" ] && ok f4-bound-exception-start || bad f4-bound-exception-start "$r"
}
t_f5_refuse_active_logged(){
  # A1 was started properly (allowed decision, then a canonical claim by w9); a second decide on A1 is refused as active
  # and that refusal is itself recorded; it is an attempt, not a bypass, and the bound start stays authorized.
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment')]}"
  q $W/f.json decide A1 --class overdue --rationale r --worker w9 >/dev/null
  T=$(clk)
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,claim='w9@'+'$T'[:16])], 'events':{'A1':[CE('A1',2,'w9','$T')]}}"
  q $W/f.json decide A1 --class overdue --rationale r >/dev/null; rc=$?
  [ $rc = 5 ] && ok f5-rc || bad f5-rc "rc=$rc"
  L=$(tail -1 "$CTL_OQ_STATE/decisions.jsonl" 2>/dev/null)
  echo "$L" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());assert d['task_id']=='A1' and d['outcome']=='refused-active' and d['existing_claim']=='w9@$T'[:19]" 2>/dev/null && ok f5-recorded || bad f5-recorded "$L"
  n=$(obs $W/f.json | field "([x['outcome'] for x in d['refusals']],[s['authorization'] for s in d['starts']],len(d['bypasses']))")
  [ "$n" = "(['refused-active'], ['allowed'], 0)" ] && ok f5-observed-as-attempt || bad f5-observed-as-attempt "$n"
}
t_active_healthy_claim_bound(){
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x')]}"
  q $W/f.json decide A2 --class discretionary --rationale r --worker w1 >/dev/null; rc=$?
  [ $rc = 0 ] && ok healthy-allowed || bad healthy-allowed "rc=$rc"
  T=$(clk)
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='w1@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w1','$T')]}}"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "([(s['authorization'],s['useful_effect'],s['worker_liveness']) for s in d['starts']],len(d['bypasses']),len(d['unknown']),d['result'])")
  [ "$r" = "([('allowed', 'UNKNOWN', 'UNKNOWN')], 0, 0, 'CLEAN')" ] && [ $rc = 0 ] && ok healthy-bound-not-bypass || bad healthy-bound-not-bypass "$r rc=$rc"
  echo "$out" | field "d['missing_producer']" | grep -q 'ask_events' && ok healthy-names-missing-producer || bad healthy-names-missing-producer "no missing_producer"
}
t_start_identity_unknown_cases(){
  # an allowed decision exists, but the canonical claim evidence cannot be bound to it: UNKNOWN, never CLEAN, never BYPASS
  ex='R("A1","ctl","2026-11-01T09:00","overdue commitment")'
  pyfx $W/f.json "{'asks':[$ex, R('A5','ctl','2026-11-01T09:00','prod fix')]}"
  q $W/f.json decide A1 --class overdue --rationale r --worker w1 >/dev/null
  q $W/f.json decide A5 --class safety --rationale r --worker w1 >/dev/null
  T=$(clk)
  chk(){ # name fixture-expr [expected unknown ids]
    pyfx $W/f.json "$2"; out=$(obs $W/f.json); rc=$?
    r=$(echo "$out" | field "(d['result'],[u['ask_id'] for u in d['unknown']],len(d['bypasses']))")
    [ "$r" = "('UNKNOWN', ${3:-['A1']}, 0)" ] && [ $rc = 7 ] && ok "$1" || bad "$1" "$r rc=$rc"
  }
  C="claim='w1@'+'$T'[:16]"
  chk unk-changed-revision "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=3,$C)], 'events':{'A1':[CE('A1',3,'w1','$T')]}}"
  chk unk-unrelated-worker "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,claim='w7@'+'$T'[:16])], 'events':{'A1':[CE('A1',2,'w7','$T')]}}"
  chk unk-claim-before-decision "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,claim='w1@2026-11-07T11:00')], 'events':{'A1':[CE('A1',2,'w1','2026-11-07T11:00:00')]}}"
  chk unk-duplicate-claim-events "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,$C)], 'events':{'A1':[CE('A1',2,'w1','$T'),CE('A1',2,'w1','$T')]}}"
  chk unk-duplicate-identity-across-asks "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,$C), R('A5','ctl','2026-11-01T09:00','prod fix',rev=2,$C)], 'events':{'A1':[CE('A1',2,'w1','$T')],'A5':[CE('A5',2,'w1','$T')]}}" "['A1', 'A5']"
  chk unk-events-missing "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,$C)]}"
  chk unk-events-malformed "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,$C)], 'events':{'A1':'garbage'}}"
  chk unk-no-claim-event "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,$C)], 'events':{'A1':[]}}"
  chk unk-stamp-mismatch "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,$C)], 'events':{'A1':[CE('A1',2,'w1','$T',stamp='w1@2026-01-01T00:00')]}}"
  # A1289 fix2: the UNKNOWN for an events outage names the canonical events source as the cause (not a substituted event)
  for v in "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,$C)]}" "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,$C)], 'events':{'A1':'garbage'}}"; do
    pyfx $W/f.json "$v"
    r=$(obs $W/f.json | field "[('canonical events' in u['reason'], u['claim_rev']) for u in d['unknown']]")
    [ "$r" = "[(True, None)]" ] && ok unk-events-reason-named || bad unk-events-reason-named "$r"
  done
}
t_malformed_decision_log_is_unknown(){
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,claim='w1@2026-11-07T10:00')], 'events':{'A1':[CE('A1',2,'w1','2026-11-07T10:00:00')]}}"
  mkdir -p "$CTL_OQ_STATE"; printf '{"ts": "2026-11-07T09:00:00", "task_id": "A1", "outc\n' > "$CTL_OQ_STATE/decisions.jsonl"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "(d['result'],d['decision_log']['malformed'],[u['ask_id'] for u in d['unknown']],len(d['bypasses']))")
  [ "$r" = "('UNKNOWN', 1, ['A1'], 0)" ] && [ $rc = 7 ] && ok malformed-log-unknown || bad malformed-log-unknown "$r rc=$rc"
}
t_observe_outage_no_replay(){
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment')]}"
  r=$(obs $W/f.json | field "d['result']"); [ "$r" = CLEAN ] && ok outage-baseline-clean || bad outage-baseline-clean "$r"
  mkdir -p $W/bin; printf '#!/bin/sh\necho boom >&2\nexit 1\n' >$W/bin/wm-asks; chmod +x $W/bin/wm-asks
  out=$(CTL_OQ_WM_ASKS="$W/bin/wm-asks" python3 "$Q" --test observe --json 2>&1); rc=$?
  if [ $rc = 4 ] && echo "$out" | grep -qi 'canonical source unavailable' && ! echo "$out" | grep -q -e CLEAN -e 'no discretionary start'; then ok outage-rc4-no-replay; else bad outage-rc4-no-replay "rc=$rc out=$out"; fi
  printf 'garbage' > $W/f.json
  out=$(obs $W/f.json 2>&1); rc=$?
  [ $rc = 4 ] && ! echo "$out" | grep -q CLEAN && ok outage-malformed-source || bad outage-malformed-source "rc=$rc"
  left=$(ls "$CTL_OQ_STATE" 2>/dev/null | grep -v '^decisions.jsonl$' | tr '\n' ' ')
  [ -z "$left" ] && ok outage-no-observer-cache || bad outage-no-observer-cache "state files: $left"
}
t_wm_asks_events_interface(){
  # SYNTHETIC stand-in for the existing wm-asks CLI: answers `asks query --json --status open` and `asks events ID --json`
  # with the real shapes (claim 'worker@ts', events detail as a JSON string). Any other call fails loudly.
  mkdir -p $W/bin
  cat >$W/bin/wm-asks <<'SH'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/calls.log"
if [ "$1 $2" = "asks query" ]; then
  echo '[{"ask_id":"S1","row_id":"d-S1","owner":"ctl","due":"2026-11-01T09:00","what":"security: rotate leaked credential","claim":null,"rev":1,"status":"open","waits_on":[]},{"ask_id":"A2","row_id":"d-A2","owner":"ctl","due":"2026-11-09T11:00","what":"discretionary: tidy","claim":"w2@2026-11-07T11:30","rev":2,"status":"open","waits_on":[]}]'
  exit 0
fi
if [ "$1 $2 $3 $4" = "asks events A2 --json" ]; then
  echo '[{"actor":"w2","ask_id":"A2","detail":"{\"claim\": \"w2@2026-11-07T11:30\", \"worker\": \"w2\"}","op":"claim","rev":2,"seq":9,"ts":"2026-11-07T11:30:05-08:00"}]'
  exit 0
fi
echo "unexpected: $*" >&2; exit 9
SH
  chmod +x $W/bin/wm-asks; : > $W/bin/calls.log
  out=$(CTL_OQ_WM_ASKS="$W/bin/wm-asks" python3 "$Q" --test --now 2026-11-07T12:00 observe --json 2>&1); rc=$?
  r=$(echo "$out" | field "([(b['ask_id'],b['kind'],b['worker'],b['claim_rev']) for b in d['bypasses']],d['result'])")
  [ "$r" = "([('A2', 'unlogged-start', 'w2', 2)], 'BYPASS')" ] && [ $rc = 6 ] && ok iface-unlogged-bypass || bad iface-unlogged-bypass "$r rc=$rc out=$out"
  grep -qx 'asks events A2 --json' $W/bin/calls.log && ok iface-events-call || bad iface-events-call "$(cat $W/bin/calls.log)"
  # A1289 fix2 D2: one consistent canonical snapshot over open AND closed asks (existing supported --status all)
  grep -qx 'asks query --json --status all' $W/bin/calls.log && ok iface-query-status-all || bad iface-query-status-all "$(cat $W/bin/calls.log)"
}

# --- A1289 fix2 (reviewfix1 D1, D2, T1, L2, L3; SYNTHETIC fixtures only; not live runtime acceptance) ---
standin(){ # dir all-rows-json events-py-dict : SYNTHETIC wm-asks answering the two supported query calls truthfully
  mkdir -p "$1"; python3 - "$1" "$2" "$3" <<'PY3'
import json,sys
d,rows,ev=sys.argv[1],json.loads(sys.argv[2]),eval(sys.argv[3])
op=[r for r in rows if r.get("status")=="open"]
b=['#!/bin/sh','echo "$*" >> "%s/calls.log"'%d,
   'if [ "$*" = "asks query --json --status all" ]; then cat <<\'EOF\'',json.dumps(rows),'EOF','exit 0; fi',
   'if [ "$*" = "asks query --json --status open" ]; then cat <<\'EOF\'',json.dumps(op),'EOF','exit 0; fi']
for k,v in ev.items():
    b+=['if [ "$*" = "asks events %s --json" ]; then cat <<\'EOF\''%k,json.dumps(v),'EOF','exit 0; fi']
b+=['echo "[]"; exit 0']   # canonical events() returns [] for an id without events
open(d+"/wm-asks","w").write("\n".join(b)+"\n")
PY3
  chmod +x "$1/wm-asks"; : > "$1/calls.log"
}
qs(){ CTL_OQ_WM_ASKS="$1/wm-asks" python3 "$Q" --test --now 2026-11-07T12:00 "${@:2}"; }
lastdec(){ tail -1 "$CTL_OQ_STATE/decisions.jsonl" 2>/dev/null; }
PYR='import json
def R(i,o,d,w,rev=1,claim=None,waits=None,status="open"):
    return {"ask_id":i,"row_id":"d-"+i,"owner":o,"due":d,"what":w,"check":"c","key":"k","status":status,"claim":claim,"waits_on":waits or [],"ready":False,"rev":rev}
def CE(i,rev,worker,ts,stamp=None,op="claim"):
    return {"seq":rev,"ask_id":i,"rev":rev,"ts":ts if len(ts)>19 else ts+"-08:00","actor":worker,"op":op,"detail":json.dumps({"claim":stamp or "%s@%s"%(worker,ts[:16]),"worker":worker},sort_keys=True)}'
rows(){ python3 -c "$PYR
print(json.dumps([$1]))"; }
evs(){ python3 -c "$PYR
print(repr($1))"; }

t_d1_owner_scopes_candidates(){
  # D1: the canonical task owner, never the caller-declared --actor, scopes the higher-priority candidates.
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes')]}"
  q $W/f.json decide A2 --class discretionary --rationale r --actor nobody >/dev/null; rc=$?
  [ $rc = 3 ] && ok d1-forged-actor-refused || bad d1-forged-actor-refused "rc=$rc"
  lastdec | python3 -c "import json,sys;d=json.loads(sys.stdin.read());assert d['actor']=='nobody' and d['candidate_owner']=='ctl' and d['higher_priority_candidates']==['S1','A1'] and d['outcome']=='refused'" 2>/dev/null && ok d1-owner-scope-recorded || bad d1-owner-scope-recorded "$(lastdec)"
  T=$(clk)
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes',rev=2,claim='w2@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w2','$T')]}}"
  out=$(obs $W/f.json); rc=$?
  k=$(echo "$out" | field "([b['kind'] for b in d['bypasses'] if b['ask_id']=='A2'],d['result'])")
  [ "$k" = "(['refused-then-started'], 'BYPASS')" ] && [ $rc = 6 ] && ok d1-forged-actor-start-detected || bad d1-forged-actor-start-detected "$k rc=$rc"
  # paired positive: an rb-owned discretionary task is gated by rb's ready work, not by the deciding seat's (ctl) work
  rm -f "$CTL_OQ_STATE/decisions.jsonl"
  pyfx $W/f.json "{'asks':[$BASE, R('R3','rb','2026-11-09T11:00','discretionary: rb chore')]}"
  q $W/f.json decide R3 --class discretionary --rationale r >/dev/null; rc=$?
  [ $rc = 0 ] && ok d1-other-owner-allowed || bad d1-other-owner-allowed "rc=$rc"
  lastdec | python3 -c "import json,sys;d=json.loads(sys.stdin.read());assert d['candidate_owner']=='rb' and d['higher_priority_candidates']==[] and d['actor']=='ctl'" 2>/dev/null && ok d1-other-owner-scope || bad d1-other-owner-scope "$(lastdec)"
}
t_d1_observe_revalidates_scope(){
  # D1: observe re-checks the candidate scope of a bound decision against the canonical owner (a decision written by
  # the fix1 bytes or appended by hand with actor != owner and no candidate_owner cannot certify the start).
  mk(){ # actor fixture-asks
    mkdir -p "$CTL_OQ_STATE"; T0=$(clk)
    printf '%s\n' '{"ts":"'"$T0"'","task_id":"A2","actor":"'"$1"'","priority_class":3,"class_label":"discretionary","declared_priority_class":3,"computed_priority_class":3,"computed_class_reason":"discretionary marker","class_supported":true,"rationale":"r","task_rev":1,"worker":null,"higher_priority_candidates":[],"dependency_repair":false,"exception":null,"exception_valid":false,"outcome":"allowed","decision_reason":"no actionable higher-priority candidate","source":"fixture","ledger_now":"2026-11-07T12:00"}' > "$CTL_OQ_STATE/decisions.jsonl"
    T=$(clk)
    pyfx $W/f.json "{'asks':[$2 R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes',rev=2,claim='w2@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w2','$T')]}}"
    out=$(obs $W/f.json); rc=$?
    echo "$out" | field "([(s['authorization'],s['kind']) for s in d['starts']],d['result'])"
  }
  r=$(mk nobody "$BASE,"); rc=$?
  [ "$r" = "([('bypass', 'owner-scope-mismatch')], 'BYPASS')" ] && ok d1-observe-actor-scope-bypass || bad d1-observe-actor-scope-bypass "$r"
  r=$(mk nobody ""); [ "$r" = "([('unknown', None)], 'UNKNOWN')" ] && ok d1-observe-actor-scope-unknown || bad d1-observe-actor-scope-unknown "$r"
  r=$(mk ctl "$BASE,"); [ "$r" = "([('allowed', None)], 'CLEAN')" ] && ok d1-observe-owner-actor-control || bad d1-observe-owner-actor-control "$r"
  # a legacy (PR315-format) allowed row with a forged class is re-checked against the canonical owner's ready work, not its actor's
  T0=$(clk); mkdir -p "$CTL_OQ_STATE"
  printf '%s\n' '{"ts":"'"$T0"'","task_id":"A2","actor":"nobody","priority_class":1,"class_label":"unblocker","rationale":"r","higher_priority_candidates":[],"dependency_repair":false,"exception":null,"exception_valid":false,"outcome":"allowed","decision_reason":"no actionable higher-priority candidate","source":"fixture","ledger_now":"2026-11-07T12:00"}' > "$CTL_OQ_STATE/decisions.jsonl"
  T=$(clk)
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes',rev=2,claim='w2@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w2','$T')]}}"
  r=$(obs $W/f.json | field "([(s['authorization'],s['kind']) for s in d['starts']],d['result'])")
  [ "$r" = "([('bypass', 'forged-class')], 'BYPASS')" ] && ok d1-legacy-forged-owner-scoped || bad d1-legacy-forged-owner-scoped "$r"
}
t_d2_closed_claim_read_from_ledger(){
  # D2: observe reads one canonical snapshot over open and closed asks (asks query --json --status all); a refused task
  # that was claimed and has since closed stays covered, and its refusal is never described as "no canonical claim".
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes')]}"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null; rc=$?
  [ $rc = 3 ] && ok d2-refused-first || bad d2-refused-first "rc=$rc"
  T=$(clk)
  standin $W/sb "$(rows "R('S1','ctl','2026-11-01T09:00','security: rotate leaked credential'), R('A1','ctl','2026-11-01T09:00','ship the foo report'), R('A2','ctl','DONE','discretionary: tidy notes',rev=4,claim='w2@'+'$T'[:16],status='closed')")" \
    "$(evs "{'A2':[CE('A2',2,'w2','$T'), CE('A2',3,'w2','$T',op='accept'), CE('A2',4,'w2','$T',op='resolve')]}")"
  out=$(qs $W/sb observe --json); rc=$?
  r=$(echo "$out" | field "([(b['ask_id'],b['kind'],b.get('ask_status')) for b in d['bypasses']],d['result'])")
  [ "$r" = "([('A2', 'refused-then-started', 'closed')], 'BYPASS')" ] && [ $rc = 6 ] && ok d2-closed-claimed-start-covered || bad d2-closed-claimed-start-covered "$r rc=$rc"
  e=$(echo "$out" | field "[x['start_evidence'] for x in d['refusals'] if x['task_id']=='A2']")
  [ "$e" = "['canonical claim present']" ] && ok d2-closed-refusal-evidence || bad d2-closed-refusal-evidence "$e"
  out=$(qs $W/sb queue --json); rc=$?
  r=$(echo "$out" | field "(d['open_total'],[x['ask_id'] for x in d['queue']+d['active']])")
  [ "$r" = "(2, ['S1', 'A1'])" ] && [ $rc = 0 ] && ok d2-closed-not-scheduled || bad d2-closed-not-scheduled "$r rc=$rc"
}
t_d2_refusal_evidence_states(){
  # every refusal states the canonical claim state actually read: present | no canonical claim | UNKNOWN (not in the ledger)
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes'), R('A3','ctl','2026-11-09T11:00','discretionary: other')]}"
  q $W/f.json decide A2 --class discretionary --rationale r >/dev/null
  q $W/f.json decide A3 --class discretionary --rationale r >/dev/null
  q $W/f.json decide A77 --class discretionary --rationale r >/dev/null
  T=$(clk)
  pyfx $W/f.json "{'asks':[$BASE, R('A2','ctl','2026-11-09T11:00','discretionary: tidy notes',rev=2,claim='w2@'+'$T'[:16]), R('A3','ctl','2026-11-09T11:00','discretionary: other')], 'events':{'A2':[CE('A2',2,'w2','$T')]}}"
  e=$(obs $W/f.json | field "sorted((x['task_id'],x['start_evidence'].split(' ')[0]) for x in d['refusals'])")
  [ "$e" = "[('A2', 'canonical'), ('A3', 'no'), ('A77', 'UNKNOWN:')]" ] && ok d2-refusal-evidence-read || bad d2-refusal-evidence-read "$e"
}
t_d2_status_schema_refused(){
  # a canonical row whose status is neither open nor closed is an unknown schema: refuse (rc 4), never classify it
  standin $W/sm "$(rows "R('S1','ctl','2026-11-01T09:00','security: x',status='weird')")" "{}"
  out=$(qs $W/sm queue --json 2>&1); rc=$?
  [ $rc = 4 ] && echo "$out" | grep -qi 'canonical source unavailable' && ok d2-unknown-status-refused || bad d2-unknown-status-refused "rc=$rc out=$out"
}
t_t1_decide_not_open_refused(){
  # r01: decide on an ask that is absent or closed is refused and recorded, never allowed
  standin $W/sn "$(rows "R('A1','ctl','2026-11-01T09:00','ship the foo report'), R('C1','ctl','DONE','prod fix',rev=5,status='closed')")" "{}"
  qs $W/sn decide A77 --class overdue --rationale r >/dev/null; rc=$?
  lastdec | python3 -c "import json,sys;d=json.loads(sys.stdin.read());assert d['task_id']=='A77' and d['outcome']=='refused' and 'absent' in d['decision_reason']" 2>/dev/null && [ $rc = 3 ] && ok t1-absent-refused || bad t1-absent-refused "rc=$rc $(lastdec)"
  qs $W/sn decide C1 --class safety --rationale r >/dev/null; rc=$?
  lastdec | python3 -c "import json,sys;d=json.loads(sys.stdin.read());assert d['task_id']=='C1' and d['outcome']=='refused' and 'closed' in d['decision_reason']" 2>/dev/null && [ $rc = 3 ] && ok t1-closed-refused || bad t1-closed-refused "rc=$rc $(lastdec)"
}
t_t1_queue_start_check(){
  # r02: queue shows each active claim's start check (bound start allowed; unlogged start bypass)
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment')]}"
  q $W/f.json decide A1 --class overdue --rationale r --worker w1 >/dev/null
  T=$(clk)
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,claim='w1@'+'$T'[:16]), R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='w2@'+'$T'[:16])], 'events':{'A1':[CE('A1',2,'w1','$T')],'A2':[CE('A2',2,'w2','$T')]}}"
  r=$(q $W/f.json queue --json | field "sorted((x['ask_id'],x.get('start_check')) for x in d['active'])")
  [ "$r" = "[('A1', 'allowed'), ('A2', 'bypass:unlogged-start')]" ] && ok t1-queue-start-check || bad t1-queue-start-check "$r"
}
t_t1_unbound_decisions_unknown(){
  # r04: a legacy allowed decision (no task_rev, PR315 format) on a class-2 task cannot be bound: UNKNOWN, never allowed
  T0=$(clk); mkdir -p "$CTL_OQ_STATE"
  printf '%s\n' '{"ts":"'"$T0"'","task_id":"A1","actor":"ctl","priority_class":2,"class_label":"overdue","rationale":"r","higher_priority_candidates":[],"dependency_repair":false,"exception":null,"exception_valid":false,"outcome":"allowed","decision_reason":"no actionable higher-priority candidate","source":"fixture","ledger_now":"2026-11-07T12:00"}' > "$CTL_OQ_STATE/decisions.jsonl"
  T=$(clk)
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,claim='w1@'+'$T'[:16])], 'events':{'A1':[CE('A1',2,'w1','$T')]}}"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "([(s['authorization'],'legacy' in s['reason']) for s in d['starts']],d['result'])")
  [ "$r" = "([('unknown', True)], 'UNKNOWN')" ] && [ $rc = 7 ] && ok t1-legacy-unbound-unknown || bad t1-legacy-unbound-unknown "$r rc=$rc"
  # r05: a decision on a ledger row that carried no rev has no task_rev: UNKNOWN, never allowed
  rm -f "$CTL_OQ_STATE/decisions.jsonl"
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=None)]}"
  q $W/f.json decide A1 --class overdue --rationale r --worker w1 >/dev/null
  T=$(clk)
  pyfx $W/f.json "{'asks':[R('A1','ctl','2026-11-01T09:00','overdue commitment',rev=2,claim='w1@'+'$T'[:16])], 'events':{'A1':[CE('A1',2,'w1','$T')]}}"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "([(s['authorization'],'no task_rev' in s['reason']) for s in d['starts']],d['result'])")
  [ "$r" = "([('unknown', True)], 'UNKNOWN')" ] && [ $rc = 7 ] && ok t1-no-task-rev-unknown || bad t1-no-task-rev-unknown "$r rc=$rc"
}
t_l3_worker_with_at(){
  # L3: canonical claim() accepts any worker token without whitespace or '|'; stamp is worker@YYYY-MM-DDTHH:MM
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x')]}"
  q $W/f.json decide A2 --class discretionary --rationale r --worker seat@host >/dev/null
  T=$(clk)
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='seat@host@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'seat@host','$T')]}}"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "([(s['worker'],s['authorization']) for s in d['starts']],d['result'])")
  [ "$r" = "([('seat@host', 'allowed')], 'CLEAN')" ] && [ $rc = 0 ] && ok l3-worker-with-at-bound || bad l3-worker-with-at-bound "$r rc=$rc"
  # a claim stamp that is not worker@YYYY-MM-DDTHH:MM is not a canonical start identity: UNKNOWN
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='seat@host')], 'events':{'A2':[CE('A2',2,'seat','$T',stamp='seat@host')]}}"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "([(s['authorization'],s['worker'],'worker@YYYY-MM-DDTHH:MM' in s['reason']) for s in d['starts']],d['result'])")
  [ "$r" = "([('unknown', None, True)], 'UNKNOWN')" ] && [ $rc = 7 ] && ok l3-noncanonical-stamp-unknown || bad l3-noncanonical-stamp-unknown "$r rc=$rc"
}
t_l2_offset_aware_order(){
  # L2: decisions record an offset-aware ts; order against the claim event is compared as aware instants.
  for tz in Asia/Tokyo UTC; do
    rm -f "$CTL_OQ_STATE/decisions.jsonl"
    pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x')]}"
    TZ=$tz q $W/f.json decide A2 --class discretionary --rationale r --worker w1 >/dev/null
    lastdec | python3 -c "import json,sys,datetime;d=json.loads(sys.stdin.read());assert datetime.datetime.fromisoformat(d['ts']).utcoffset() is not None" 2>/dev/null && ok l2-ts-offset-$tz || bad l2-ts-offset-$tz "$(lastdec)"
    T=$(TZ=America/Los_Angeles date -d '+60 seconds' +%Y-%m-%dT%H:%M:%S%:z)   # the claim really happens 60 s later, ledger in PST
    pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='w1@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w1','$T')]}}"
    r=$(TZ=America/Los_Angeles obs $W/f.json | field "([s['authorization'] for s in d['starts']],d['result'])")
    [ "$r" = "(['allowed'], 'CLEAN')" ] && ok l2-mixed-zone-bound-$tz || bad l2-mixed-zone-bound-$tz "$r"
  done
  # ledger writes UTC, decider PST, the claim really happened 30 min BEFORE the decision: never bound as allowed
  rm -f "$CTL_OQ_STATE/decisions.jsonl"
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x')]}"
  TZ=America/Los_Angeles q $W/f.json decide A2 --class discretionary --rationale r --worker w1 >/dev/null
  T=$(TZ=UTC date -d '-30 minutes' +%Y-%m-%dT%H:%M:%S%:z)
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='w1@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w1','$T')]}}"
  out=$(TZ=America/Los_Angeles obs $W/f.json); rc=$?
  r=$(echo "$out" | field "([s['authorization'] for s in d['starts']],d['result'])")
  [ "$r" = "(['unknown'], 'UNKNOWN')" ] && [ $rc = 7 ] && ok l2-utc-ledger-claim-before-decision || bad l2-utc-ledger-claim-before-decision "$r rc=$rc"
  # a bound-format decision whose ts has no UTC offset (fix1 format) cannot be ordered against the claim: UNKNOWN
  T0=$(date +%Y-%m-%dT%H:%M:%S); mkdir -p "$CTL_OQ_STATE"
  printf '%s\n' '{"ts":"'"$T0"'","task_id":"A2","actor":"ctl","priority_class":3,"class_label":"discretionary","computed_priority_class":3,"task_rev":1,"worker":"w1","higher_priority_candidates":[],"dependency_repair":false,"exception":null,"exception_valid":false,"outcome":"allowed","decision_reason":"x","source":"fixture"}' > "$CTL_OQ_STATE/decisions.jsonl"
  T=$(clk)
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='w1@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w1','$T')]}}"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "([(s['authorization'],'UTC offset' in s['reason']) for s in d['starts']],d['result'])")
  [ "$r" = "([('unknown', True)], 'UNKNOWN')" ] && [ $rc = 7 ] && ok l2-naive-decision-ts-unknown || bad l2-naive-decision-ts-unknown "$r rc=$rc"
  # mixed formats at the governing revision: an offset-aware allowed row and a refusal without a UTC offset (older bytes)
  # cannot be ordered against each other or the claim: UNKNOWN, never allowed on the orderable row alone
  rm -f "$CTL_OQ_STATE/decisions.jsonl"
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x')]}"
  q $W/f.json decide A2 --class discretionary --rationale r --worker w1 >/dev/null
  printf '%s\n' '{"ts":"'"$(date +%Y-%m-%dT%H:%M:%S)"'","task_id":"A2","actor":"ctl","priority_class":3,"class_label":"discretionary","computed_priority_class":3,"task_rev":1,"worker":null,"higher_priority_candidates":["S9"],"dependency_repair":false,"exception":null,"exception_valid":false,"outcome":"refused","decision_reason":"x","source":"fixture"}' >> "$CTL_OQ_STATE/decisions.jsonl"
  T=$(clk)
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='w1@'+'$T'[:16])], 'events':{'A2':[CE('A2',2,'w1','$T')]}}"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "([(s['authorization'],'UTC offset' in s['reason']) for s in d['starts']],d['result'])")
  [ "$r" = "([('unknown', True)], 'UNKNOWN')" ] && [ $rc = 7 ] && ok l2-mixed-format-same-rev-unknown || bad l2-mixed-format-same-rev-unknown "$r rc=$rc"
  # a canonical claim event whose ts has no UTC offset cannot be ordered: UNKNOWN naming the claim event, claim_rev unset
  rm -f "$CTL_OQ_STATE/decisions.jsonl"
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x')]}"
  q $W/f.json decide A2 --class discretionary --rationale r --worker w1 >/dev/null
  T=$(date -d '+60 seconds' +%Y-%m-%dT%H:%M:%S)
  pyfx $W/f.json "{'asks':[R('A2','ctl','2026-11-09T11:00','discretionary: x',rev=2,claim='w1@'+'$T'[:16])], 'events':{'A2':[dict(CE('A2',2,'w1','$T'),ts='$T')]}}"
  out=$(obs $W/f.json); rc=$?
  r=$(echo "$out" | field "([(s['authorization'],s['claim_rev'],'claim event ts' in s['reason']) for s in d['starts']],d['result'])")
  [ "$r" = "([('unknown', None, True)], 'UNKNOWN')" ] && [ $rc = 7 ] && ok l2-naive-claim-event-ts-unknown || bad l2-naive-claim-event-ts-unknown "$r rc=$rc"
}

names="safety_beats_discretionary authorized_overdue_beats_discretionary blocked_higher_allows_independent dependency_repair_allowed active_worker_not_duplicated future_checkpoint_does_not_hide explicit_not_before_respected valid_exception_auditable unavailable_source_fails_visibly big_backlog_no_global_freeze blocker_without_structure_is_triage_defect row_dependency_closed_not_blocking f1_unlogged_start_detected f2_refused_then_started_detected f3_declared_class_not_authority genuine_priority_and_repair_allowed f4_valid_exception_not_bypass f5_refuse_active_logged active_healthy_claim_bound start_identity_unknown_cases malformed_decision_log_is_unknown observe_outage_no_replay wm_asks_events_interface d1_owner_scopes_candidates d1_observe_revalidates_scope d2_closed_claim_read_from_ledger d2_refusal_evidence_states d2_status_schema_refused t1_decide_not_open_refused t1_queue_start_check t1_unbound_decisions_unknown l3_worker_with_at l2_offset_aware_order"
if [ $# = 0 ]; then echo $names; exit 0; fi
for n in "$@"; do "t_$n" || fail=1; done
exit $fail
