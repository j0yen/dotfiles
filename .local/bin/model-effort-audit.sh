#!/usr/bin/env bash
# model-effort-audit.sh — deterministic (zero inference) drift audit of the model/effort policy, ledger A1159.
#   model-effort-audit.sh            print one JSON line {ok, findings:[{id,detail}], info:[...]}; exit 0 clean / 1 drift
#   model-effort-audit.sh --notify   same, and when the SET of finding ids changed since the last run, send ONE line to ctl via
#                                    seat-event.sh (changed-alarm only; a persisting drift is not re-sent; a clear is sent once)
# Policy sources (read, never copied here): ctl = ~/.local/lib/ctl-model-policy.sh (ctl_model_policy), skills = skill-model-policy.sh.
# Checks: ctl helper behaviour (bare -> pins, wrong/dup/equals/fallback refused, bad policy fails closed) · seat-model-hold ctl+aide rows ·
#   launcher/relaunch/shim wiring · settings pins and env overrides (key names only) · skill frontmatter · spawn-gate recipe ·
#   Agent-effort guard installed, wired and behaving · running ctl (launch flags from cmdline; live model from the newest assistant
#   line of the session transcript) · the running Fable analysis unit.
# NOT covered: manual /model or /effort changes inside a session (only the transcript model is read, never effort), platform defaults,
#   a claude started outside the covered launchers, an Agent call whose hook payload omits fields, effort of an already-running session.
# Seams for tests: MEA_SYSTEMCTL MEA_NOTIFY MEA_STATE MEA_PROCS (file: "pid<TAB>cmdline") MEA_TRANSCRIPT MEA_ANALYSIS_UNIT MEA_ANALYSIS_CHECK.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
NOTIFY=0; [ "${1:-}" = --notify ] && NOTIFY=1
F=(); INFO=()
fail(){ F+=("$1|$2"); }
info(){ INFO+=("$1"); }
LIB="$HOME/.local/lib"; BIN="$HOME/.local/bin"; HK="$HOME/.claude/hooks"; SK="$HOME/.claude/skills"
HOLD="${XDG_CONFIG_HOME:-$HOME/.config}/wm-decide/seat-model-hold.json"
SET="$HOME/.claude/settings.json"; SETL="$HOME/.claude/settings.local.json"
SYSCTL="${MEA_SYSTEMCTL:-systemctl}"

# 1. ctl helper (single source of truth) -------------------------------------------------------------
EM=""; EE=""
if [ ! -r "$LIB/ctl-model-policy.sh" ]; then fail helper-missing "$LIB/ctl-model-policy.sh unreadable"; else
  out=$(bash -c '. "$1"; ctl_model_policy; rc=$?; echo "rc=$rc"; echo "${CTL_POLICY_ARGS[*]}"' _ "$LIB/ctl-model-policy.sh" 2>/dev/null)
  if [ "$(echo "$out" | sed -n 1p)" = rc=0 ] && [[ "$(echo "$out" | sed -n 2p)" =~ ^--model\ ([^\ ]+)\ --effort\ ([^\ ]+)$ ]]; then
    EM=${BASH_REMATCH[1]}; EE=${BASH_REMATCH[2]}
  else fail helper-bare "bare ctl_model_policy did not yield '--model M --effort E' ($(echo "$out" | tr '\n' ' '))"
    fail hold-ctl "helper refuses the policy; seat-model-hold ctl row is model='$(jq -r '.ctl.model // empty' "$HOLD" 2>/dev/null)' effort='$(jq -r '.ctl.effort // empty' "$HOLD" 2>/dev/null)'"; fi
  if [ -n "$EM" ]; then
    probe(){ bash -c '. "$1"; shift; ctl_model_policy "$@" >/dev/null 2>&1' _ "$LIB/ctl-model-policy.sh" "$@"; }
    probe --model "$EM" --effort "$EE" || fail helper-allows-match "matching --model/--effort refused"
    for bad in "--model claude-fable-5-1" "--model=claude-fable-5-1" "--effort high" "--effort=max" "--effort max" "--model $EM --model $EM" "--effort=$EE --effort $EE" "--fallback-model claude-fable-5-1"; do
      # shellcheck disable=SC2086
      probe $bad && fail helper-accepts-bad "helper accepted: $bad"
    done
    bash -c 'XDG_CONFIG_HOME=$(mktemp -d); trap "rm -rf $XDG_CONFIG_HOME" EXIT; . "$1"; ctl_model_policy >/dev/null 2>&1' _ "$LIB/ctl-model-policy.sh" \
      && fail helper-not-fail-closed "missing policy file did not fail closed"
  fi
fi

# 2. hold rows -------------------------------------------------------------------------------------------
if [ -n "$EM" ]; then
  for row in ctl aide; do
    m=$(jq -r ".$row.model // empty" "$HOLD" 2>/dev/null); e=$(jq -r ".$row.effort // empty" "$HOLD" 2>/dev/null)
    { [ "$m" = "$EM" ] && [ "$e" = "$EE" ]; } || fail "hold-$row" "seat-model-hold $row row is model='$m' effort='$e', helper says $EM/$EE"
  done
fi

# 3. launcher wiring -----------------------------------------------------------------------------------
L=$(readlink -f "$BIN/ctl-launch.sh" 2>/dev/null); R=$(readlink -f "$BIN/ctl-relaunch.sh" 2>/dev/null)
if [ -r "$L" ]; then
  grep -q 'ctl-model-policy.sh' "$L" && grep -q 'ctl_model_policy' "$L" || fail launch-unwired "ctl-launch.sh does not source/call the policy helper"
  a=$(grep -n 'ctl_model_policy "\$@"' "$L" | head -1 | cut -d: -f1); b=$(grep -nE '^(exec|if .*exec) .*claude|exec \$\{AIDE_CLAUDE_BIN' "$L" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail launch-order "policy check is not before the claude exec"
  grep -q 'aide.model // empty' "$L" && fail launch-old-fallback "old hold-row model fallback still present"
else fail launch-missing "ctl-launch.sh unreadable"; fi
if [ -r "$R" ]; then
  grep -q 'ctl_model_policy' "$R" || fail relaunch-unwired "ctl-relaunch.sh does not call the policy helper"
  grep -qE '// "high"|echo high' "$R" && fail relaunch-high-fallback "ctl-relaunch.sh still has a high effort fallback"
  grep -qE -- '--model claude-fable|--effort (high|max|xhigh)' "$R" && fail relaunch-wrong-pin "ctl-relaunch.sh pins a non-policy model/effort"
else fail relaunch-missing "ctl-relaunch.sh unreadable"; fi
for s in launch relaunch; do
  t=$(readlink -f "$BIN/aide-$s.sh" 2>/dev/null)
  [ -r "$t" ] && grep -q "ctl-$s.sh" "$t" || fail "aide-$s-shim" "aide-$s.sh does not hand off to ctl-$s.sh"
done

# 4. settings pins -----------------------------------------------------------------------------------------
if [ -n "$EM" ]; then
  sm=$(jq -r '.model // empty' "$SET" 2>/dev/null); [ "$sm" = "$EM" ] || fail settings-model "settings.json model='$sm', policy $EM"
  se=$(jq -r --arg m "$EM" '.modelSettings[$m].effortLevel // empty' "$SET" 2>/dev/null); [ "$se" = "$EE" ] || fail settings-effort "settings.json modelSettings[$EM].effortLevel='$se', policy $EE"
  if [ -r "$SETL" ]; then
    lm=$(jq -r '.model // empty' "$SETL" 2>/dev/null); [ -z "$lm" ] || [ "$lm" = "$EM" ] || fail settings-local-model "settings.local.json model='$lm', policy $EM"
    le=$(jq -r '.effortLevel // empty' "$SETL" 2>/dev/null); [ -z "$le" ] || [ "$le" = "$EE" ] || info "settings.local.json effortLevel=$le (ctl launches pass --effort explicitly; plain sessions use this value)"
  fi
  for f in "$SET" "$SETL"; do
    [ -r "$f" ] && for k in CLAUDE_CODE_EFFORT_LEVEL ANTHROPIC_MODEL CLAUDE_CODE_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL; do
      jq -e --arg k "$k" '(.env // {}) | has($k)' "$f" >/dev/null 2>&1 && fail settings-env-override "$f env defines $k"; done
  done
fi
fe=$(jq -r '.modelSettings["claude-fable-5-1"].effortLevel // empty' "$SET" 2>/dev/null)
[ "$fe" = xhigh ] || info "settings modelSettings[claude-fable-5-1].effortLevel='${fe:-unset}' (skill spawns pass effort explicitly; the guard rejects an unset one)"

# 5. skills frontmatter + 6. recipe + 7. guard --------------------------------------------------------------
SP="$LIB/skill-model-policy.sh"
if [ -r "$SP" ]; then . "$SP"; else fail skillpolicy-missing "$SP unreadable"; fi
fmget(){ awk 'NR==1&&$0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$1" | sed -n "s/^$2:[[:space:]]*\\([A-Za-z0-9._-]*\\)[[:space:]]*$/\\1/p" | head -1; }
if [ -n "${SKILL_POLICY_SKILLS:-}" ]; then
  for s in $SKILL_POLICY_SKILLS; do
    f="$SK/$s/SKILL.md"
    [ -r "$f" ] || { fail "skill-$s-missing" "$f unreadable"; continue; }
    [ "$(fmget "$f" model)" = fable ] || fail "skill-$s-model" "$s frontmatter model='$(fmget "$f" model)'"
    [ "$(fmget "$f" effort)" = "$SKILL_POLICY_EFFORT" ] || fail "skill-$s-effort" "$s frontmatter effort='$(fmget "$f" effort)', policy $SKILL_POLICY_EFFORT"
    [ "$(fmget "$f" fable-spawn)" = true ] || fail "skill-$s-spawn" "$s lacks fable-spawn: true"
    d=$(printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"transcript_path":"/nonexistent","tool_use_id":"x"}' "$s")
    # gate recipe: needs a non-Fable transcript to print the recipe
    tf=$(mktemp); printf '{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"x"}]}}\n' >"$tf"
    d=$(printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"transcript_path":"%s","tool_use_id":"x"}' "$s" "$tf")
    r=$(printf '%s' "$d" | SKILL_MARKER_DIR=$(mktemp -d) "$HK/fable-skill-spawn-gate.sh" 2>&1 >/dev/null); rm -f "$tf"
    printf '%s' "$r" | grep -q "model=fable, effort=$SKILL_POLICY_EFFORT" || fail "recipe-$s" "spawn-gate recipe for $s does not say model=fable, effort=$SKILL_POLICY_EFFORT"
  done
  d="$SK/dream/SKILL.md"; [ -r "$d" ] && info "dream effort=$(fmget "$d" effort) (own pin, not policed)"
  G="$HK/skill-agent-effort-guard.sh"
  if [ ! -x "$G" ]; then fail guard-missing "$G missing or not executable"; else
    gp(){ printf '{"tool_name":"Agent","tool_input":{"model":"%s","effort":"%s","prompt":"%s"}}' "$1" "$2" "$3" | "$G" >/dev/null 2>&1; echo $?; }
    [ "$(gp fable "$SKILL_POLICY_EFFORT" 'Invoke the wwhtbt skill for plan X')" = 0 ] || fail guard-blocks-good "guard refused fable/$SKILL_POLICY_EFFORT"
    for bad in "fable||" "fable|high|" "fable|max|" "sonnet|xhigh|" "|xhigh|"; do
      IFS='|' read -r bm be _ <<<"$bad"
      [ "$(gp "$bm" "$be" 'Invoke the 5whysandrhyme skill for incident Y')" = 2 ] || fail guard-allows-bad "guard allowed model='$bm' effort='$be'"
    done
    [ "$(gp sonnet medium 'Read the dream notes and summarise')" = 0 ] && [ "$(gp haiku "" 'find the wwhtbt page path')" = 0 ] || fail guard-overblocks "guard blocked a non-skill spawn"
    jq -e --arg g "$G" '[.hooks.PreToolUse[]? | select((.matcher|test("(^|\\|)Agent(\\||$)"))) | .hooks[]?.command] | any(. == $g)' "$SET" >/dev/null 2>&1 || fail guard-unwired "settings.json PreToolUse has no Agent entry for $G"
  fi
fi

# 8. running ctl -----------------------------------------------------------------------------------------------
procs(){
  if [ -n "${MEA_PROCS:-}" ]; then cat "$MEA_PROCS"; return; fi
  { cat "$HOME/.config/aide/channel-pid" 2>/dev/null
    for pp in $(tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null | awk '$1=="aide"{print $2}'); do echo "$pp"; pgrep -P "$pp" 2>/dev/null; done; } | sort -u | while read -r p; do
    [ -r "/proc/$p/cmdline" ] || continue
    c=$(tr '\0' ' ' <"/proc/$p/cmdline"); case "${c%% *}" in */claude|claude) printf '%s\t%s\n' "$p" "$c" ;; esac; done
}
if [ -n "$EM" ]; then
  P=$(procs)
  if [ -z "$P" ]; then info "no ctl claude process found (not running or not launched in tmux aide)"; else
    while IFS=$'\t' read -r pid cmd; do
      [ -n "$pid" ] || continue
      pm=$(grep -oE -- '--model[= ][^ ]+' <<<"$cmd" | head -1 | sed 's/--model[= ]//'); pe=$(grep -oE -- '--effort[= ][^ ]+' <<<"$cmd" | head -1 | sed 's/--effort[= ]//')
      [ -z "$pe" ] && info "ctl pid $pid launched without --effort (live effort not readable)"
      [ -n "$pe" ] && [ "$pe" != "$EE" ] && fail runtime-effort "ctl pid $pid launched with --effort $pe, policy $EE"
      [ -n "$pm" ] && [ "$pm" != "$EM" ] && info "ctl pid $pid launch flag --model $pm differs from $EM (live model judged from the transcript below)"
      sid=$(grep -oE -- '--resume [0-9a-f-]{36}' <<<"$cmd" | head -1 | awk '{print $2}'); [ -n "$sid" ] || sid=$(cat "$HOME/.config/aide/session-id" 2>/dev/null)
      tr_="${MEA_TRANSCRIPT:-}"; [ -n "$tr_" ] || tr_=$(ls "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
      if [ -n "$tr_" ] && [ -r "$tr_" ]; then
        lm=$(tail -n 400 "$tr_" 2>/dev/null | jq -R -r 'fromjson? | select(.type=="assistant") | .message.model // empty' 2>/dev/null | grep -v '^<synthetic>$' | tail -1)
        [ -z "$lm" ] || [ "$lm" = "$EM" ] || fail runtime-model "ctl session $sid last assistant turn ran on $lm, policy $EM"
      else info "no transcript for ctl session ${sid:-?}; live model unverified"; fi
    done <<<"$P"
  fi
fi

# 9. running analysis unit ----------------------------------------------------------------------------------------
U="${MEA_ANALYSIS_UNIT:-hermes-work-stoppage-fivewhys-xhigh-20261106.service}"
if [ -n "${SKILL_POLICY_EFFORT:-}" ]; then
  st=$("$SYSCTL" --user is-active "$U" 2>/dev/null)
  if [ "$st" = active ]; then
    ex=$("$SYSCTL" --user show -p ExecStart "$U" 2>/dev/null)
    grep -q -- "--model $SKILL_POLICY_MODEL --effort $SKILL_POLICY_EFFORT" <<<"$ex" || fail analysis-unit "running $U is not $SKILL_POLICY_MODEL/$SKILL_POLICY_EFFORT"
    CK="${MEA_ANALYSIS_CHECK:-$HOME/wintermute-operations/check-analysis-xhigh.py}"
    [ -r "$CK" ] && { python3 "$CK" >/dev/null 2>&1 || fail analysis-process "check-analysis-xhigh.py failed (process effort is not xhigh)"; }
  else info "analysis unit $U is ${st:-unknown} (nothing to check)"; fi
fi

# report ------------------------------------------------------------------------------------------------------------------
fj=$(for x in "${F[@]:-}"; do [ -n "$x" ] && jq -n --arg i "${x%%|*}" --arg d "${x#*|}" '{id:$i,detail:$d}'; done | jq -s .)
ij=$(for x in "${INFO[@]:-}"; do [ -n "$x" ] && jq -n --arg d "$x" '$d'; done | jq -s .)
jq -n -c --argjson f "${fj:-[]}" --argjson i "${ij:-[]}" '{ok:(($f|length)==0), findings:$f, info:$i}'
if [ "$NOTIFY" = 1 ]; then
  STATE="${MEA_STATE:-$HOME/.cache/model-effort-audit/last}"; mkdir -p "$(dirname "$STATE")"
  ids=$(printf '%s\n' "${F[@]:-}" | grep -v '^$' | cut -d'|' -f1 | sort | paste -sd, -)
  if [ "$ids" != "$(cat "$STATE" 2>/dev/null || true)" ]; then
    if [ -n "$ids" ]; then msg="model-effort-audit DRIFT (ledger A1159): $ids; run ~/.local/bin/model-effort-audit.sh for details; no model calls were made"
    else msg="model-effort-audit CLEAR (ledger A1159): no drift"; fi
    # the state advances only when the bell was delivered, so a failed send is retried next run
    if ${MEA_NOTIFY:-$BIN/seat-event.sh ctl} "$msg" >/dev/null 2>&1; then printf '%s' "$ids" >"$STATE"; fi
  fi
fi
[ ${#F[@]} -eq 0 ]
