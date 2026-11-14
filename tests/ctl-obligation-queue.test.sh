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
  o=$(q $W/f.json observe --json | jq_ "len(d['bypasses'])"); [ "$o" = 1 ] && ok observe-detects || bad observe-detects "$o"
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
def R(i,o,d,w,rev=1,claim=None,waits=None):
    return {"ask_id":i,"row_id":"d-"+i,"owner":o,"due":d,"what":w,"check":"c","key":"k","status":"open","claim":claim,"waits_on":waits or [],"ready":False,"rev":rev}
def CE(i,rev,worker,ts,stamp=None,op="claim"):
    return {"seq":rev,"ask_id":i,"rev":rev,"ts":ts+"-08:00","actor":worker,"op":op,"detail":json.dumps({"claim":stamp or "%s@%s"%(worker,ts[:16]),"worker":worker},sort_keys=True)}
d=eval(sys.argv[2]); d.setdefault("now","2026-11-07T12:00"); d.setdefault("followups",[])
json.dump(d,open(sys.argv[1],"w"))
PY2
}
obs(){ q "$1" observe --json; }           # prints JSON; rc is observe's
field(){ python3 -c "import json,sys;d=json.loads(sys.stdin.read() or '{}');print($1)" 2>/dev/null; }
clk(){ date +%Y-%m-%dT%H:%M:%S; }
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
}

names="safety_beats_discretionary authorized_overdue_beats_discretionary blocked_higher_allows_independent dependency_repair_allowed active_worker_not_duplicated future_checkpoint_does_not_hide explicit_not_before_respected valid_exception_auditable unavailable_source_fails_visibly big_backlog_no_global_freeze blocker_without_structure_is_triage_defect row_dependency_closed_not_blocking f1_unlogged_start_detected f2_refused_then_started_detected f3_declared_class_not_authority genuine_priority_and_repair_allowed f4_valid_exception_not_bypass f5_refuse_active_logged active_healthy_claim_bound start_identity_unknown_cases malformed_decision_log_is_unknown observe_outage_no_replay wm_asks_events_interface"
if [ $# = 0 ]; then echo $names; exit 0; fi
for n in "$@"; do "t_$n" || fail=1; done
exit $fail
