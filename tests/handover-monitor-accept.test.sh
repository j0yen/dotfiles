#!/usr/bin/env bash
# handover-monitor-accept.test.sh (A1150): status.json churn is not progress; cutover alone (timer+delivery) does not complete a task.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; MON="$HERE/.local/bin/handover-monitor.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; F=0
chk(){ if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; F=1; fi; }
py(){ MON="$MON" T="$T" python3 -I -c "
import importlib.util,os,json
sp=importlib.util.spec_from_file_location('hm',os.environ['MON']); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
$1"; }
chk "default progress_paths exclude event-bridge status.json" '[ "$(py "print(any(\"status.json\" in p for p in m.DEFAULT_CFG[\"progress_paths\"]))")" = False ]'
chk "task done_requires needs acceptance, not cutover alone" '[ "$(py "print(\"accept:model-free\" in m.DEFAULT_CFG[\"tasks\"][0][\"done_requires\"])")" = True ]'
chk "deadline satisfied_by needs acceptance" '[ "$(py "print(\"accept:model-free\" in m.DEFAULT_CFG[\"deadlines\"][0][\"satisfied_by\"])")" = True ]'
echo '{"independent_verified":true,"effort_pinned":true,"quiet_checks":3}' > "$T/a.json"
chk "cutover ok + no acceptance file => not satisfied" '[ "$(py "print(m.satisfied(\"cutover:model-free+accept:model-free\",{\"cutover\":{\"ok\":True},\"accept\":m.accept_facts({\"acceptance_file\":\"$T/none.json\"})}))")" = False ]'
chk "cutover ok + full acceptance => satisfied" '[ "$(py "print(m.satisfied(\"cutover:model-free+accept:model-free\",{\"cutover\":{\"ok\":True},\"accept\":m.accept_facts({\"acceptance_file\":\"$T/a.json\"})}))")" = True ]'
echo '{"independent_verified":true,"effort_pinned":true,"quiet_checks":2}' > "$T/b.json"
chk "2 quiet checks => not accepted" '[ "$(py "print(m.accept_facts({\"acceptance_file\":\"$T/b.json\"})[\"ok\"])")" = False ]'
echo '{"independent_verified":true,"effort_pinned":false,"quiet_checks":5}' > "$T/c.json"
chk "effort not pinned => not accepted" '[ "$(py "print(m.accept_facts({\"acceptance_file\":\"$T/c.json\"})[\"ok\"])")" = False ]'
chk "cutover not ok + full acceptance => not satisfied" '[ "$(py "print(m.satisfied(\"cutover:model-free+accept:model-free\",{\"cutover\":{\"ok\":False},\"accept\":{\"ok\":True}}))")" = False ]'
chk "triage call pins --effort low and haiku model" '[ "$(py "print(m.HAIKU_EFFORT)")" = low ] && grep -q -- "\"--effort\", HAIKU_EFFORT" "$MON"'
[ $F = 0 ] && echo ALL PASS
