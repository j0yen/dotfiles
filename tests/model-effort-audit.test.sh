#!/usr/bin/env bash
# model-effort-audit.test.sh: deterministic drift audit (ledger A1159, routing audit A1300). Builds a fake HOME from the repo files, no provider call.
# Run alone: bash tests/model-effort-audit.test.sh
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
build(){ # fresh fake HOME in $T/h
  rm -rf "$T/h"; H="$T/h"; mkdir -p "$H/.local/lib" "$H/.local/bin" "$H/.claude/hooks" "$H/.claude/skills" "$H/.config/wm-decide" "$H/.config/aide" "$H/.cache" "$H/.config/skill-routing" "$H/.local/state/skill-routing" "$H/.claude/projects/p"
  cp "$R/.local/lib/ctl-model-policy.sh" "$R/.local/lib/skill-model-policy.sh" "$R/.local/lib/skill-route.sh" "$R/.local/lib/skill-route-resolve.py" "$H/.local/lib/"
  cp "$R/.config/skill-routing/policy.json" "$H/.config/skill-routing/"
  cp "$R/.local/bin/ctl-launch.sh" "$R/.local/bin/ctl-relaunch.sh" "$R/.local/bin/aide-launch.sh" "$R/.local/bin/aide-relaunch.sh" "$H/.local/bin/"
  cp "$R/.claude/hooks/fable-skill-spawn-gate.sh" "$R/.claude/hooks/skill-agent-effort-guard.sh" "$R/.claude/hooks/skill-route-prompt-guard.sh" "$H/.claude/hooks/"
  for s in 5whysandrhyme wwhtbt; do mkdir -p "$H/.claude/skills/$s"; printf -- '---\nname: %s\nmodel: fable\neffort: xhigh\nfable-spawn: true\n---\nbody\n' "$s" >"$H/.claude/skills/$s/SKILL.md"; done
  mkdir -p "$H/.claude/skills/maxspeed"; printf -- '---\nname: maxspeed\nfable-spawn: true\n---\nbody\n' >"$H/.claude/skills/maxspeed/SKILL.md"
  mkdir -p "$H/.claude/skills/dream"; printf -- '---\nname: dream\nmodel: fable\neffort: max\nfable-spawn: true\n---\n' >"$H/.claude/skills/dream/SKILL.md"
  jq -n '{ctl:{model:"claude-sonnet-5-5",effort:"medium"},aide:{model:"claude-sonnet-5-5",effort:"medium"},rb:{model:"claude-opus-5-5"}}' >"$H/.config/wm-decide/seat-model-hold.json"
  jq -n --arg g "$H/.claude/hooks/skill-agent-effort-guard.sh" '{model:"claude-sonnet-5-5",modelSettings:{"claude-sonnet-5-5":{effortLevel:"medium"},"claude-fable-5-1":{effortLevel:"high"}},env:{CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:"50"},hooks:{PreToolUse:[{matcher:"Agent",hooks:[{type:"command",command:$g}]}],UserPromptSubmit:[{hooks:[{type:"command",command:"/x/skill-route-prompt-guard.sh"}]}]}}' >"$H/.claude/settings.json"
  printf '{"model":"claude-sonnet-5-5","effortLevel":"high"}\n' >"$H/.claude/settings.local.json"
  printf '#!/bin/sh\ncase "$*" in *is-active*) echo "${STUB_ACTIVE:-inactive}";; *show*) echo "ExecStart={ argv[]=bash -c claude --model ${STUB_MODEL:-claude-fable-5-1} --effort ${STUB_EFFORT:-xhigh} }";; esac\n' >"$T/systemctl"; chmod +x "$T/systemctl"
  printf '#!/bin/sh\necho "$*" >>%s/notify.log\n' "$T" >"$T/notify"; chmod +x "$T/notify"
  printf '#!/usr/bin/env python3\nraise SystemExit(0)\n' >"$T/check.py"
  : >"$T/procs"; : >"$T/notify.log"; rm -rf "$T/state"
}
run(){ HOME="$H" XDG_CONFIG_HOME="$H/.config" MEA_SYSTEMCTL="$T/systemctl" MEA_PROCS="$T/procs" MEA_ANALYSIS_CHECK="$T/check.py" MEA_NOTIFY="$T/notify" MEA_STATE="$T/state/last" MEA_PROJECTS="$H/.claude/projects" \
        "$R/.local/bin/model-effort-audit.sh" "$@" 2>/dev/null; }
want_clean(){ out=$(run); rc=$?; [ "$rc" = 0 ] && echo "ok $1" || { echo "FAIL $1 rc=$rc $out"; fail=1; }; }
want_id(){ out=$(run); rc=$?; if [ "$rc" = 1 ] && jq -e --arg i "$2" '.findings|any(.id==$i)' <<<"$out" >/dev/null; then echo "ok $1"; else echo "FAIL $1 rc=$rc want id $2: $out"; fail=1; fi; }
mut(){ sed -i "$2" "$3" || { echo "FAIL mutation sed $2"; fail=1; }; }

build; want_clean "pristine fixture audits clean"
build; echo "$(jq -c .info < <(run))" | grep -q 'settings.local.json effortLevel=high' && echo "ok settings.local effort high is informational only" || { echo "FAIL info"; fail=1; }

build; mut x 's/\[ "\$m" = claude-sonnet-5-5 \] \&\& \[ "\$e" = medium \]/true/' "$H/.local/lib/ctl-model-policy.sh"; sed -i 's/\[ "\$v" = "\$m" \]/true/' "$H/.local/lib/ctl-model-policy.sh"; want_id "helper accepting any model is caught (wrong-model mutation)" helper-accepts-bad
build; sed -i 's/seen_e=\$((seen_e+1)); \[ "\$seen_e" -eq 1 \] \&\& \[ "\$v" = "\$e" \]/true/' "$H/.local/lib/ctl-model-policy.sh"; want_id "helper accepting wrong effort is caught" helper-accepts-bad
build; rm "$H/.local/lib/ctl-model-policy.sh"; want_id "missing helper reported" helper-missing
build; jq '.ctl.model="claude-fable-5-1"' "$H/.config/wm-decide/seat-model-hold.json" >"$T/x" && mv "$T/x" "$H/.config/wm-decide/seat-model-hold.json"; want_id "hold ctl model drift" hold-ctl
build; jq '.aide.effort="high"' "$H/.config/wm-decide/seat-model-hold.json" >"$T/x" && mv "$T/x" "$H/.config/wm-decide/seat-model-hold.json"; want_id "hold aide compat effort drift (the pre-fix high row)" hold-aide
build; printf '#!/usr/bin/env bash\nEFFORT="$(jq -r ".ctl.effort // \\"high\\"" x)"\n' >"$H/.local/bin/ctl-relaunch.sh"; want_id "relaunch without helper / with high fallback" relaunch-unwired
build; sed -i '$a EFFORT="$(jq -r .x f 2>/dev/null || echo high)"' "$H/.local/bin/ctl-relaunch.sh"; want_id "relaunch high fallback re-introduced" relaunch-high-fallback
build; sed -i 's/ctl_model_policy "\$@" || exit \$?//' "$H/.local/bin/ctl-launch.sh"; want_id "launcher no longer calls helper" launch-order
build; printf '#!/usr/bin/env bash\nexec claude "$@"\n' >"$H/.local/bin/aide-launch.sh"; want_id "aide-launch shim bypassing ctl-launch" aide-launch-shim
build; jq '.model="claude-fable-5-1"' "$H/.claude/settings.json" >"$T/x" && mv "$T/x" "$H/.claude/settings.json"; want_id "settings model drift" settings-model
build; jq '.modelSettings["claude-sonnet-5-5"].effortLevel="high"' "$H/.claude/settings.json" >"$T/x" && mv "$T/x" "$H/.claude/settings.json"; want_id "settings effort drift" settings-effort
build; jq '.env.CLAUDE_CODE_EFFORT_LEVEL="high"' "$H/.claude/settings.json" >"$T/x" && mv "$T/x" "$H/.claude/settings.json"; want_id "env effort override in settings" settings-env-override
build; sed -i 's/^effort: max/effort: high/' "$H/.claude/skills/dream/SKILL.md"; want_clean "dream effort is not policed"
build; rm "$H/.claude/hooks/skill-agent-effort-guard.sh"; want_id "guard missing" guard-missing
build; jq '.hooks.PreToolUse=[]' "$H/.claude/settings.json" >"$T/x" && mv "$T/x" "$H/.claude/settings.json"; want_id "guard unwired" guard-unwired
# routing policy / gates / guards (A1300)
build; want_clean "legacy SKILL.md pins are informational (inline use is blocked by the gate)"
build; jq '.skills.wwhtbt.routes["sonnet-medium"].model="claude-fable-5-1"|.models["claude-fable-5-1"].efforts+=["medium"]' "$H/.config/skill-routing/policy.json" >"$T/x" && mv "$T/x" "$H/.config/skill-routing/policy.json"; want_id "wwhtbt baseline drifted off sonnet/medium" routing-baseline-wwhtbt
build; jq '.skills.x1={baseline:"a",routes:{a:{model:"claude-fable-5-1",effort:"high"}},classes:{},escalation_reasons:{}}' "$H/.config/skill-routing/policy.json" >"$T/x" && mv "$T/x" "$H/.config/skill-routing/policy.json"; want_id "policy governs a skill the guard set does not list" routing-set-drift
build; jq '.forbidden_efforts=[]|.models["claude-fable-5-1"].efforts+=["max"]|.skills["5whysandrhyme"].routes["fable-high"].effort="max"' "$H/.config/skill-routing/policy.json" >"$T/x" && mv "$T/x" "$H/.config/skill-routing/policy.json"; want_id "policy allowing Fable max is caught" routing-baseline-5whys
build; echo '{' >"$H/.config/skill-routing/policy.json"; want_id "malformed policy reported" routing-policy
build; rm "$H/.local/lib/skill-route-resolve.py"; want_id "missing resolver reported" routing-resolver
build; rm "$H/.claude/hooks/skill-route-prompt-guard.sh"; want_id "missing slash guard reported" slash-guard-missing
build; jq '.hooks.UserPromptSubmit=[]' "$H/.claude/settings.json" >"$T/x" && mv "$T/x" "$H/.claude/settings.json"; want_id "slash guard unwired" slash-guard-unwired
build; sed -i 's/--route-request/--nothing/' "$H/.local/lib/skill-route.sh"; want_id "gate recipe no longer the managed launcher" gate-wwhtbt
build; sed -i 's/^sr_managed_worker().*/sr_managed_worker() { return 1; }/' "$H/.local/lib/skill-route.sh"; want_id "gate blocking its own managed worker" gate-worker-wwhtbt
build; sed -i 's/^M=\$(sr_alias_model "\$M")/M=claude-fable-5-1; E=high/' "$H/.claude/hooks/skill-agent-effort-guard.sh"; want_id "guard accepting any model/effort is caught" guard-allows-bad
# per-turn routing audit: selected vs actual, reasons, usage, exceptions, unverifiable effort
SID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
row(){ jq -nc --arg d "$1" --arg t "$2" --arg sk "$3" --arg m "$4" --arg e "$5" --arg s "$6" --argjson r "${7:-false}" '{ts:"2026-11-08T01:00:00-08:00",decision:$d,task_id:$t,skill:$sk,route:"x",model:$m,effort:$e,account:"a",session:$s,resume:$r,reasons:"decision_class baseline"}' >>"$H/.local/state/skill-routing/decisions.jsonl"; }
tr_(){ printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":10,"output_tokens":5}}}\n' "$@" >"$H/.claude/projects/p/$SID.jsonl"; }
build; row launch A1 wwhtbt claude-sonnet-5-5 medium $SID; tr_ claude-sonnet-5-5; tr_x=$(run); jq -e '.ok and (.routing.turns[0].actual.effort=="unverifiable") and (.routing.turns[0].usage.output_tokens==5) and (.routing.turns[0].selected.model=="claude-sonnet-5-5") and (.routing.turns[0].reasons|length>0)' <<<"$tr_x" >/dev/null && echo "ok matching turn: model verified, effort reported unverifiable, usage+reasons recorded" || { echo "FAIL matching turn: $tr_x"; fail=1; }
build; row launch A1 wwhtbt claude-sonnet-5-5 medium $SID; tr_ claude-fable-5-1; want_id "runtime drift: session ran a different model than selected" routing-model-drift
build; row launch A1 wwhtbt claude-sonnet-5-5 medium $SID; printf '{"type":"assistant","effort":"high","message":{"model":"claude-sonnet-5-5"}}\n' >"$H/.claude/projects/p/$SID.jsonl"; want_id "explicit transcript effort that differs is drift" routing-effort-drift
build; row launch A1 wwhtbt claude-sonnet-5-5 low $SID; tr_ claude-sonnet-5-5; want_id "decision row selecting an effort the policy forbids" routing-row-invalid
build; row denied A2 5whysandrhyme "" "" ""; out=$(run); jq -e '.ok and (.routing.exceptions|any(.kind=="denied"))' <<<"$out" >/dev/null && echo "ok denied route listed as exception" || { echo "FAIL denied exception: $out"; fail=1; }
build; row launch A3 wwhtbt claude-sonnet-5-5 medium $SID; out=$(run); jq -e '.ok and (.routing.exceptions|any(.kind=="no-transcript"))' <<<"$out" >/dev/null && echo "ok missing transcript -> unverifiable exception, not a guess" || { echo "FAIL no-transcript: $out"; fail=1; }
build; row launch A4 wwhtbt claude-sonnet-5-5 medium $SID; row launch A4 wwhtbt claude-sonnet-5-5 medium bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee; out=$(run); jq -e '.routing.exceptions|any(.kind=="duplicate-dispatch")' <<<"$out" >/dev/null && echo "ok duplicate dispatch flagged" || { echo "FAIL duplicate: $out"; fail=1; }
build; row launch A5 wwhtbt claude-sonnet-5-5 medium $SID; row launch A5 wwhtbt claude-sonnet-5-5 medium $SID true; out=$(run); jq -e '.routing.exceptions|any(.kind=="duplicate-dispatch")|not' <<<"$out" >/dev/null && echo "ok same-session resume is not a duplicate" || { echo "FAIL resume flagged: $out"; fail=1; }
# running ctl
build; printf '1234\t/x/claude --dangerously-skip-permissions --model claude-fable-5-1 --effort medium --resume 11111111-1111-1111-1111-111111111111 hi\n' >"$T/procs"
printf '{"type":"assistant","message":{"model":"claude-sonnet-5-5"}}\n' >"$T/tr.jsonl"; export MEA_TRANSCRIPT="$T/tr.jsonl"
want_clean "stale launch --model flag with live Sonnet transcript is informational"
printf '{"type":"assistant","message":{"model":"claude-fable-5-1"}}\n' >"$T/tr.jsonl"; want_id "live transcript model is Fable" runtime-model
printf '{"type":"assistant","message":{"model":"claude-sonnet-5-5"}}\n' >"$T/tr.jsonl"
printf '1234\t/x/claude --model claude-sonnet-5-5 --effort high\n' >"$T/procs"; want_id "ctl launched with effort high" runtime-effort
unset MEA_TRANSCRIPT
# analysis unit
build; export STUB_ACTIVE=active; want_clean "active analysis unit at fable/xhigh passes"
STUB_EFFORT=max want_id "active analysis unit at max" analysis-unit
printf '#!/usr/bin/env python3\nraise SystemExit(1)\n' >"$T/check.py"; want_id "analysis process check failing" analysis-process
unset STUB_ACTIVE
# notify: changed-alarm only
build; jq '.ctl.model="claude-fable-5-1"' "$H/.config/wm-decide/seat-model-hold.json" >"$T/x" && mv "$T/x" "$H/.config/wm-decide/seat-model-hold.json"
run --notify >/dev/null; run --notify >/dev/null; n=$(wc -l <"$T/notify.log"); [ "$n" = 1 ] && grep -q 'DRIFT.*hold-ctl' "$T/notify.log" && echo "ok drift sent once, deduped on repeat" || { echo "FAIL notify dedupe n=$n $(cat "$T/notify.log")"; fail=1; }
rm "$H/.claude/hooks/skill-route-prompt-guard.sh"; run --notify >/dev/null
[ "$(wc -l <"$T/notify.log")" = 2 ] && echo "ok changed finding set re-sent" || { echo "FAIL changed set: $(cat "$T/notify.log" | cut -c1-300)"; fail=1; }
jq '.ctl.model="claude-sonnet-5-5"' "$H/.config/wm-decide/seat-model-hold.json" >"$T/x" && mv "$T/x" "$H/.config/wm-decide/seat-model-hold.json"; cp "$R/.claude/hooks/skill-route-prompt-guard.sh" "$H/.claude/hooks/"; run --notify >/dev/null; run --notify >/dev/null
[ "$(wc -l <"$T/notify.log")" = 3 ] && tail -1 "$T/notify.log" | grep -q CLEAR && echo "ok clear sent once" || { echo "FAIL clear: $(cat "$T/notify.log" | cut -c1-300)"; fail=1; }
build; run --notify >/dev/null; [ ! -s "$T/notify.log" ] && echo "ok clean first run sends nothing" || { echo "FAIL clean sends"; fail=1; }
build; jq '.ctl.model="x"' "$H/.config/wm-decide/seat-model-hold.json" >"$T/x" && mv "$T/x" "$H/.config/wm-decide/seat-model-hold.json"
printf '#!/bin/sh\nexit 1\n' >"$T/notify"; run --notify >/dev/null; [ ! -e "$T/state/last" ] && echo "ok failed bell keeps state unadvanced (retry next run)" || { echo "FAIL state advanced on failed bell"; fail=1; }
# canonical maxspeed SKILL.md (A1300 cont3 edit 6): absent = NOTE only; present must carry fable-spawn: true and no model/effort off the policy baseline
build; rm "$H/.claude/skills/maxspeed/SKILL.md"; want_clean "absent canonical maxspeed SKILL.md passes"
build; rm "$H/.claude/skills/maxspeed/SKILL.md"; run | jq -e '.info|any(test("maxspeed.*(absent|not present|NOTE)"))' >/dev/null && echo "ok absent maxspeed SKILL.md leaves a NOTE line" || { echo "FAIL no NOTE for absent maxspeed SKILL.md"; fail=1; }
build; printf -- '---\nname: maxspeed\n---\nbody\n' >"$H/.claude/skills/maxspeed/SKILL.md"; want_id "maxspeed SKILL.md without fable-spawn: true fails" skill-maxspeed-no-fable-spawn
build; printf -- '---\nname: maxspeed\nmodel: fable\neffort: max\nfable-spawn: true\n---\nbody\n' >"$H/.claude/skills/maxspeed/SKILL.md"; want_id "maxspeed SKILL.md effort: max off the baseline fails" skill-maxspeed-effort
build; printf -- '---\nname: maxspeed\nmodel: sonnet\nfable-spawn: true\n---\nbody\n' >"$H/.claude/skills/maxspeed/SKILL.md"; want_id "maxspeed SKILL.md model: sonnet off the baseline fails" skill-maxspeed-model
build; printf -- '---\nname: maxspeed\nmodel: fable\neffort: high\nfable-spawn: true\n---\nbody\n' >"$H/.claude/skills/maxspeed/SKILL.md"; want_clean "maxspeed SKILL.md matching the baseline (fable/high) passes"
# the audit makes no model call: no claude binary on its PATH is ever executed
build; mkdir -p "$T/bin"; printf '#!/bin/sh\necho called >%s/claude.called\n' "$T" >"$T/bin/claude"; chmod +x "$T/bin/claude"; PATH="$T/bin:$PATH" run >/dev/null
[ ! -e "$T/claude.called" ] && echo "ok audit never calls claude" || { echo "FAIL audit called claude"; fail=1; }
[ "$fail" = 0 ] && echo "PASS model-effort-audit" || { echo "FAILED model-effort-audit"; exit 1; }
