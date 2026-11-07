#!/usr/bin/env bash
# model-effort-audit.test.sh: deterministic drift audit (ledger A1159). Builds a fake HOME from the repo files, no provider call.
# Run alone: bash tests/model-effort-audit.test.sh
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
build(){ # fresh fake HOME in $T/h
  rm -rf "$T/h"; H="$T/h"; mkdir -p "$H/.local/lib" "$H/.local/bin" "$H/.claude/hooks" "$H/.claude/skills" "$H/.config/wm-decide" "$H/.config/aide" "$H/.cache"
  cp "$R/.local/lib/ctl-model-policy.sh" "$R/.local/lib/skill-model-policy.sh" "$H/.local/lib/"
  cp "$R/.local/bin/ctl-launch.sh" "$R/.local/bin/ctl-relaunch.sh" "$R/.local/bin/aide-launch.sh" "$R/.local/bin/aide-relaunch.sh" "$H/.local/bin/"
  cp "$R/.claude/hooks/fable-skill-spawn-gate.sh" "$R/.claude/hooks/skill-agent-effort-guard.sh" "$H/.claude/hooks/"
  for s in 5whysandrhyme wwhtbt; do mkdir -p "$H/.claude/skills/$s"; printf -- '---\nname: %s\nmodel: fable\neffort: xhigh\nfable-spawn: true\n---\nbody\n' "$s" >"$H/.claude/skills/$s/SKILL.md"; done
  mkdir -p "$H/.claude/skills/dream"; printf -- '---\nname: dream\nmodel: fable\neffort: max\nfable-spawn: true\n---\n' >"$H/.claude/skills/dream/SKILL.md"
  jq -n '{ctl:{model:"claude-sonnet-5-5",effort:"medium"},aide:{model:"claude-sonnet-5-5",effort:"medium"},rb:{model:"claude-opus-5-5"}}' >"$H/.config/wm-decide/seat-model-hold.json"
  jq -n --arg g "$H/.claude/hooks/skill-agent-effort-guard.sh" '{model:"claude-sonnet-5-5",modelSettings:{"claude-sonnet-5-5":{effortLevel:"medium"},"claude-fable-5-1":{effortLevel:"high"}},env:{CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:"50"},hooks:{PreToolUse:[{matcher:"Agent",hooks:[{type:"command",command:$g}]}]}}' >"$H/.claude/settings.json"
  printf '{"model":"claude-sonnet-5-5","effortLevel":"high"}\n' >"$H/.claude/settings.local.json"
  printf '#!/bin/sh\ncase "$*" in *is-active*) echo "${STUB_ACTIVE:-inactive}";; *show*) echo "ExecStart={ argv[]=bash -c claude --model ${STUB_MODEL:-claude-fable-5-1} --effort ${STUB_EFFORT:-xhigh} }";; esac\n' >"$T/systemctl"; chmod +x "$T/systemctl"
  printf '#!/bin/sh\necho "$*" >>%s/notify.log\n' "$T" >"$T/notify"; chmod +x "$T/notify"
  printf '#!/usr/bin/env python3\nraise SystemExit(0)\n' >"$T/check.py"
  : >"$T/procs"; : >"$T/notify.log"; rm -rf "$T/state"
}
run(){ HOME="$H" XDG_CONFIG_HOME="$H/.config" MEA_SYSTEMCTL="$T/systemctl" MEA_PROCS="$T/procs" MEA_ANALYSIS_CHECK="$T/check.py" MEA_NOTIFY="$T/notify" MEA_STATE="$T/state/last" \
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
build; sed -i 's/^effort: xhigh/effort: max/' "$H/.claude/skills/wwhtbt/SKILL.md"; want_id "skill frontmatter effort drift" skill-wwhtbt-effort
build; sed -i 's/^effort: max/effort: high/' "$H/.claude/skills/dream/SKILL.md"; want_clean "dream effort is not policed"
build; sed -i 's/^model: fable/model: opus/' "$H/.claude/skills/5whysandrhyme/SKILL.md"; want_id "skill frontmatter model drift" skill-5whysandrhyme-model
build; sed -i 's/effort=\${EFFORT}/effort=high/' "$H/.claude/hooks/fable-skill-spawn-gate.sh"; want_id "spawn-gate recipe drift" recipe-5whysandrhyme
build; sed -i 's/\[ "\$E" = "\$SKILL_POLICY_EFFORT" \]/true/' "$H/.claude/hooks/skill-agent-effort-guard.sh"; want_id "guard accepting any effort is caught" guard-allows-bad
build; rm "$H/.claude/hooks/skill-agent-effort-guard.sh"; want_id "guard missing" guard-missing
build; jq '.hooks.PreToolUse=[]' "$H/.claude/settings.json" >"$T/x" && mv "$T/x" "$H/.claude/settings.json"; want_id "guard unwired" guard-unwired
build; sed -i 's/^effort: xhigh/effort: high/' "$H/.claude/skills/5whysandrhyme/SKILL.md"; want_id "skill effort high" skill-5whysandrhyme-effort
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
sed -i 's/^effort: xhigh/effort: high/' "$H/.claude/skills/wwhtbt/SKILL.md"; run --notify >/dev/null
[ "$(wc -l <"$T/notify.log")" = 2 ] && echo "ok changed finding set re-sent" || { echo "FAIL changed set"; fail=1; }
jq '.ctl.model="claude-sonnet-5-5"' "$H/.config/wm-decide/seat-model-hold.json" >"$T/x" && mv "$T/x" "$H/.config/wm-decide/seat-model-hold.json"; sed -i 's/^effort: high/effort: xhigh/' "$H/.claude/skills/wwhtbt/SKILL.md"; run --notify >/dev/null; run --notify >/dev/null
[ "$(wc -l <"$T/notify.log")" = 3 ] && tail -1 "$T/notify.log" | grep -q CLEAR && echo "ok clear sent once" || { echo "FAIL clear"; fail=1; }
build; run --notify >/dev/null; [ ! -s "$T/notify.log" ] && echo "ok clean first run sends nothing" || { echo "FAIL clean sends"; fail=1; }
build; jq '.ctl.model="x"' "$H/.config/wm-decide/seat-model-hold.json" >"$T/x" && mv "$T/x" "$H/.config/wm-decide/seat-model-hold.json"
printf '#!/bin/sh\nexit 1\n' >"$T/notify"; run --notify >/dev/null; [ ! -e "$T/state/last" ] && echo "ok failed bell keeps state unadvanced (retry next run)" || { echo "FAIL state advanced on failed bell"; fail=1; }
# the audit makes no model call: no claude binary on its PATH is ever executed
build; mkdir -p "$T/bin"; printf '#!/bin/sh\necho called >%s/claude.called\n' "$T" >"$T/bin/claude"; chmod +x "$T/bin/claude"; PATH="$T/bin:$PATH" run >/dev/null
[ ! -e "$T/claude.called" ] && echo "ok audit never calls claude" || { echo "FAIL audit called claude"; fail=1; }
[ "$fail" = 0 ] && echo "PASS model-effort-audit" || { echo "FAILED model-effort-audit"; exit 1; }
