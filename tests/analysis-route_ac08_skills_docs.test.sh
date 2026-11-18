#!/usr/bin/env bash
# analysis-route AC 8 (A1300 E13 R5, R7): both analysis SKILL.md files have no model or effort key, carry R5's fixed sentence and one
# machine-readable example request naming the policy's listed alternate, and no other line with a case-insensitive "fable" outside
# fable-spawn and fable-*.sh names; docs/adaptive-skill-routing.md carries every R7 anchor and pairs these files with no model or
# effort pin; the three tests R5 changes pass with R5's replacements. From R (AR_ROOT): the SKILL.md files, the doc, the policy and the
# three tests. Run alone: bash tests/analysis-route_ac08_skills_docs.test.sh
. "$(dirname "$0")/analysis-route_lib.sh"
POL="$R/.config/skill-routing/policy.json"; DOC="$R/docs/adaptive-skill-routing.md"
SENT="The routing policy chooses the model and effort: Fable is its default for this skill's consequential classes, and a listed non-Fable alternate runs only when the launch request names it in requested.route with its model and effort."
fm(){ awk 'NR==1&&$0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$1"; }
fable_lines(){ sed -E 's/fable-spawn//g; s/fable-[a-z-]+\.sh//g' "$1" | grep -ni fable; }
for sk in wwhtbt 5whysandrhyme; do
  sf="$R/.claude/skills/$sk/SKILL.md"
  case "$sk" in wwhtbt) cls=unresolved_consequential ;; 5whysandrhyme) cls=consequential_prevention ;; esac
  ck "$sk: frontmatter has no model: or effort: key" '[ -r "$sf" ] && ! fm "$sf" | grep -qE "^(model|effort)[[:space:]]*:"'
  ck "$sk: frontmatter keeps name, description, fable-spawn: true and last_updated (and nothing else)" '[ "$(fm "$sf" | grep -oE "^[a-z_-]+:" | tr -d : | sort | paste -sd" ")" = "description fable-spawn last_updated name" ] && fm "$sf" | grep -qx "fable-spawn: true" && fm "$sf" | grep -qx "name: $sk"'
  ck "$sk: R5's fixed sentence verbatim on one line, once" '[ "$(grep -cxF "$SENT" "$sf")" = 1 ]'
  ck "$sk: outside fable-spawn and fable-*.sh names, a case-insensitive fable occurs only on the fixed sentence's line" '[ "$(fable_lines "$sf" | wc -l)" = 1 ] && [ "$(fable_lines "$sf" | cut -d: -f2-)" = "$SENT" ]' || fable_lines "$sf" | head -5
  ck "$sk: exactly one line begins {\"task_id\"" '[ "$(grep -c "^{\"task_id\"" "$sf")" = 1 ]'
  grep '^{"task_id"' "$sf" | head -1 >"$T/ex.$sk"
  sed -e 's|<TASK_ID>|AR8-T|g' -e 's|<LEDGER_REF>|ledger:A1300|g' -e "s|<FILE_REF>|file:$T/ev.md|g" "$T/ex.$sk" >"$T/ex.$sk.json"
  want=$(jq -c --arg s "$sk" --arg c "$cls" '.skills[$s] as $k | $k.classes[$c].route as $r | $k.alternates[$r][0] as $a | {route:$a, model:$k.routes[$a].model, effort:$k.routes[$a].effort}' "$POL" 2>/dev/null)
  ck "$sk: the example line has the placeholders <TASK_ID>, <LEDGER_REF>, <FILE_REF> and is JSON once they are filled" 'grep -qF "<TASK_ID>" "$T/ex.$sk" && grep -qF "<LEDGER_REF>" "$T/ex.$sk" && grep -qF "<FILE_REF>" "$T/ex.$sk" && jq -e "type==\"object\"" "$T/ex.$sk.json" >/dev/null 2>&1'
  ck "$sk: the example names skill $sk, class $cls (its consequential Fable xhigh class), evidence_refs [<LEDGER_REF>, <FILE_REF>]" 'jq -e --arg s "$sk" --arg c "$cls" --arg f "file:$T/ev.md" ".skill==\$s and .decision_class==\$c and .evidence_refs==[\"ledger:A1300\",\$f] and .task_id==\"AR8-T\"" "$T/ex.$sk.json" >/dev/null 2>&1 && [ "$(jq -r --arg s "$sk" --arg c "$cls" ".skills[\$s].classes[\$c].route" "$POL")" = fable-xhigh ]'
  ck "$sk: the example's requested is the policy's listed alternate for that class, with its route, model and effort ($want)" '[ -n "$want" ] && [ "$want" != null ] && [ "$(jq -c ".requested" "$T/ex.$sk.json" 2>/dev/null)" = "$want" ]'
  ck "$sk: the filled example resolves to that alternate on the policy under test" 'ar_res "$POL" "$R/.local/lib/skill-route-resolve.py" "$(cat "$T/ex.$sk.json")"; [ "$AR_RC" = 0 ] && jq -e --argjson w "$want" ".route==\$w.route and .model_id==\$w.model and .effort==\$w.effort and .alternate_of==\"fable-xhigh\"" "$T/res.out" >/dev/null 2>&1'
  ck "$sk: recipe is fable-launch.sh --route-request <request file> --session-id <pre-drawn id>; the separate-process-on-jyen.pm recipe is gone" 'grep -qF "fable-launch.sh --route-request <request file> --session-id <pre-drawn id>" "$sf" && ! grep -qiE "separate [a-z]+ process on jyen\.pm|--model claude-fable" "$sf"'
  ck "$sk: page status and amendment heading carry the model as a placeholder" 'grep -qF "status: draft for <model> regrade" "$sf" && grep -qF "## Amendments after <model> regrade" "$sf"'
  ck "$sk: a run that asked for an alternate asks the same requested for its review" 'grep -qi "asked for an alternate asks the same" "$sf"'
  ck "$sk: kept: review heading \"Review only when justified (default: no second launch)\", review_reason:, explicit_user_request" 'grep -qF "Review only when justified (default: no second launch)" "$sf" && grep -qF "review_reason:" "$sf" && grep -qF "explicit_user_request" "$sf"'
  ck "$sk: exactly one fable-launch.sh line from the review heading on" '[ "$(awk "/Review only when justified/{c=1} c&&/fable-launch\\.sh/{k++} END{print k+0}" "$sf")" = 1 ]'
  ck "$sk: xhigh only from an evidenced class or escalation; max only as the policy's recorded exception" 'grep -qE "xhigh comes only from an evidenced class or escalation" "$sf" && grep -qE "max is only the policy.s recorded exception" "$sf"'
done

# R7 anchors in the doc
ck "doc: alternates with R3's data as its example" 'grep -qF "\"alternates\": {\"fable-high\": [\"opus-high\"], \"fable-xhigh\": [\"opus-xhigh\"]}" "$DOC" && grep -qE "opus-high.*claude-opus-5-5.*high.*opus-xhigh.*claude-opus-5-5.*xhigh" "$DOC"'
ck "doc: the request rule (requested.route with the alternate's model and effort together)" 'grep -qE "selected only by \`requested.route\` naming it together with \`requested.model\` and \`requested.effort\`" "$DOC"'
ck "doc: R2's malformed cases (not an object; key not a route/deterministic/exception/non-fable family; non-empty unique list; member not a route/deterministic/exception; no string family/fable family/id with fable; forbidden/unsupported/different effort; equal to its key)" '
  grep -qF "\`alternates\` is not an object" "$DOC" && grep -qF "a key that is not a route of the skill, is a deterministic or exception route, or is a route whose model'"'"'s \`family\` is not \`fable\`" "$DOC" \
  && grep -qF "a value that is not a non-empty list of unique route names" "$DOC" && grep -qF "a member that is not a route of the skill, or is a deterministic or exception route" "$DOC" \
  && grep -qF "a member whose model entry has no string \`family\`, whose \`family\` is \`fable\`, or whose model id contains \`fable\` in any case" "$DOC" \
  && grep -qF "a member whose effort is forbidden or unsupported for its model, or differs from its key'"'"'s effort" "$DOC" && grep -qF "a member equal to its key" "$DOC"'
ck "doc: R4's echo rule" 'grep -qF "the echo is the skill'"'"'s \`review_route\` if it declares one, else the selected alternate'"'"'s own model and effort" "$DOC"'
ck "doc: the scope sentence (the analysis skills, under the 2026-11-17 approval)" 'grep -E "^Scope:" "$DOC" | grep -qF "/wwhtbt" && grep -E "^Scope:" "$DOC" | grep -qF "/5whysandrhyme" && grep -E "^Scope:" "$DOC" | grep -qF "2026-11-17"'
ck "doc: R6's routed rule" 'grep -E "^- Routed rule:" "$DOC" | grep -qF "role \`author\`, a skill the path needs, \`reasons\` containing \`requested alternate\`, and a \`model\` equal to the turn'"'"'s"'
ck "doc: R6's identity rule" 'grep -E "^- Identity rule:" "$DOC" | grep -qF "a writing turn whose model differs from that row'"'"'s \`model\` is refused"'
ck "doc: no line pairs the analysis SKILL.md files with model: fable or an effort key (lines 61 and 76 corrected)" '! grep -E "SKILL\.md|analysis skill" "$DOC" | grep -qE "model: *fable|effort: *[a-z]"'
ck "doc: no line says model: fable at all" '! grep -qE "model: *fable" "$DOC"'

# the tests R5 changes, at the tree under test, with R5's replacements in place
for t in fable-quota-routing skill-no-default-second-review analysis-page-gate; do
  bash "$R/tests/$t.test.sh" >"$T/$t.log" 2>&1; echo $? >"$T/$t.rc"
  ck "tests/$t.test.sh passes" '[ "$(cat "$T/$t.rc")" = 0 ]' || grep -E "^FAIL" "$T/$t.log" | head -5
done
ck "R5 replacement present in fable-quota-routing.test.sh: no model:/effort: key; escalation+exception; default: no second launch; example request launched and denied by f9066716" 'grep -qF "frontmatter has no model: or effort: key" "$R/tests/fable-quota-routing.test.sh" && grep -qF "grep -qi \"escalation\" \"\$sf\" && grep -qi \"exception\" \"\$sf\"" "$R/tests/fable-quota-routing.test.sh" && grep -qF "grep -q \"default: no second launch\" \"\$sf\"" "$R/tests/fable-quota-routing.test.sh" && grep -qF "the same request exits 2 on the vendored f9066716 resolver and policy" "$R/tests/fable-quota-routing.test.sh" && ! grep -qF "FABLE_LAUNCH_EFFORT_REASON\" \"\$sf\"" "$R/tests/fable-quota-routing.test.sh"'
ck "R5 replacement present in skill-no-default-second-review.test.sh (No second launch by default | default: no second launch)" 'grep -qF "grep -q \"No second launch by default\\|default: no second launch\" \"\$f\"" "$R/tests/skill-no-default-second-review.test.sh"'
ck "R5 replacement present in analysis-page-gate.test.sh (private empty SKILL_ROUTING_DECISIONS)" 'grep -qE "^export SKILL_ROUTING_DECISIONS=\"\\\$T/" "$R/tests/analysis-page-gate.test.sh"'
ar_end
