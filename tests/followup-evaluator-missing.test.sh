#!/usr/bin/env bash
# A1346 R4: evaluator-missing visibility is a CHAIN-level contract. On the seat Stop chain (followup-stop-gate.sh, seat-followups.sh stop, owed-now.sh hook),
# exactly one entrypoint (owed-now.sh) reports a missing followup-eval.py, once per session; the other two return silently by design, and the settings wiring
# keeps owed-now.sh on the same Stop chain as the other two. A silent entrypoint is never the only reader of that state.
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
p=0; f=0; ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
# a tree with the hooks but NO .local/bin/followup-eval.py, and an empty HOME
mkdir -p "$W/t/.claude/hooks" "$W/home"; cp "$here"/.claude/hooks/{followup-stop-gate.sh,seat-followups.sh,owed-now.sh,followup-lib.sh} "$W/t/.claude/hooks/"
printf '#!/bin/bash\necho "[]"\n' >"$W/asks.sh"; printf '#!/bin/bash\necho "{\\"owed\\":0,\\"overdue\\":0,\\"escalated\\":0,\\"ids\\":[]}"\n' >"$W/dec.sh"; chmod +x "$W"/*.sh
export HOME="$W/home" WM_ASKS_BIN="$W/asks.sh" WM_DECIDE_BIN="$W/dec.sh" FOLLOWUP_STATE_DIR="$W/st" FOLLOWUP_OUTBOX="$W/st/outbox.jsonl" FOLLOWUP_DELIVER_CMD=true WM_SEAT=ctl OWED_NOW_SOURCE=asks SEATS_TABLE="$W/none.tsv"
unset WM_DIRECTOR FOLLOWUP_EVAL
J='{"hook_event_name":"Stop","session_id":"s1"}'
H="$W/t/.claude/hooks"
ck "precondition: no evaluator resolves" "$(bash -c ". $H/followup-lib.sh; fu_eval_bin >/dev/null && echo found || echo missing")" missing
ck "followup-stop-gate is silent by design" "$(printf '%s' "$J" | bash "$H/followup-stop-gate.sh")" ""
ck "seat-followups\\.sh stop is silent by design" "$(printf '%s' "$J" | bash "$H/seat-followups.sh" stop)" ""
o1="$(printf '%s' "$J" | bash "$H/owed-now.sh" hook)"
ck "owed-now reports the missing evaluator" "$(grep -c 'EVALUATOR MISSING' <<<"$o1")" 1
ck "owed-now reports it once per session" "$(printf '%s' "$J" | bash "$H/owed-now.sh" hook)" ""
ck "settings keeps owed-now on the same Stop chain" "$(jq -r '[.hooks.Stop[]?.hooks[]?.command]|map(select(test("owed-now|followup-stop-gate|seat-followups\\.sh stop")))|length' "$here/.claude/settings.json")" 3
echo "followup-evaluator-missing: $p PASS $f FAIL"; [ "$f" = 0 ]
