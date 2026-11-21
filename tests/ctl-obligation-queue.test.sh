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
  printf '#!/bin/sh\necho "[]"\n' >$W/bin/wm-asks; cp $W/bin/wm-asks $W/bin/wm-decide
  src=$(PATH="$W/bin:$PATH" CTL_OQ_FIXTURE="$W/f.json" python3 "$Q" queue --json 2>/dev/null | jq_ "d['source']")
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

names="safety_beats_discretionary authorized_overdue_beats_discretionary blocked_higher_allows_independent dependency_repair_allowed active_worker_not_duplicated future_checkpoint_does_not_hide explicit_not_before_respected valid_exception_auditable unavailable_source_fails_visibly big_backlog_no_global_freeze blocker_without_structure_is_triage_defect row_dependency_closed_not_blocking"
[ $# = 0 ] && set -- $names
for n in "$@"; do "t_$n" || fail=1; done
exit $fail
