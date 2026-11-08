#!/usr/bin/env bash
# Shared by seat-context-start.sh (D1), followup-stop-gate.sh (D2/E) and seat-tick.sh: the one reader of the follow-up tracker.
# CONTRACT (swarm-decide part A, stubbed by tests/followup-hooks.test.sh until A installs):
#   wm-decide followups --json [--agent <seat>] prints {"owed":N,"overdue":M,"escalated":E,"oldest":"<id>","by_agent":{...},
#     "ids":[{"id":"d-...","owner":"rb","age_h":3.1,"state":"owed|provisional|overdue|escalated"}]}
# followups_read <seat|""> : the JSON into FU_JSON (empty seat = every seat). Non-zero + FU_REASON when the command is absent, fails or prints non-JSON,
#   so every consumer fails open ("unmeasured") and a broken A never wedges a seat. Call it without a subshell: FU_REASON must survive.
# followups_json <seat|""> : the same, JSON on stdout (the one place that runs `wm-decide followups --json [--agent <seat>]` under `timeout 10`).
followups_json() {
  local bin="${WM_DECIDE_BIN:-wm-decide}" out rc
  FU_JSON=""; FU_REASON=""
  command -v "$bin" >/dev/null 2>&1 || { FU_REASON="$bin absent"; return 1; }
  command -v jq >/dev/null 2>&1 || { FU_REASON="jq absent"; return 1; }
  if [ -n "${1:-}" ]; then out="$(timeout 10 "$bin" followups --json --agent "$1" 2>/dev/null)"; rc=$?
  else out="$(timeout 10 "$bin" followups --json 2>/dev/null)"; rc=$?; fi
  [ "$rc" = 0 ] || { FU_REASON="exit $rc"; return 1; }
  printf '%s' "$out" | jq -e 'type=="object" and (.owed|type)=="number" and ((.ids // [])|type)=="array"' >/dev/null 2>&1 || { FU_REASON="non-JSON output"; return 1; }
  FU_JSON="$out"; printf '%s' "$out"
}
followups_read() { followups_json "${1:-}" >/dev/null; }
# followups_line <seat> : "FOLLOW-UPS OWED (seat rb): N owed, M overdue: <id> <age>h <state>, ... and K more" (10 ids max); prints nothing when none are owed.
# rc 1 + FU_REASON when unmeasured (the caller decides whether to say so).
followups_line() {
  local j n m
  followups_read "$1" || return 1; j="$FU_JSON"
  n="$(jq -r '.owed' <<<"$j")"; m="$(jq -r '((.overdue // 0) + (.escalated // 0))' <<<"$j")"
  { [ "$n" = 0 ] && [ "$m" = 0 ]; } && return 0
  jq -r --arg s "$1" '(.ids // []) as $i | "FOLLOW-UPS OWED (seat \($s)): \(.owed) owed, \((.overdue // 0) + (.escalated // 0)) overdue: " + ([$i[0:10][] | "\(.id) \(.age_h)h \(.state)"] | join(", ")) + (if ($i|length) > 10 then " and \(($i|length) - 10) more" else "" end)' <<<"$j"
}

# ---- canonical obligation evaluator (ledger ask A1307) -------------------------------------------------------------------------------------
# One deterministic evaluation of each open ask from the canonical store (`wm-asks query --status open --json`; never the retired TSV):
#   accounted  = a live claim (worker alive per FOLLOWUP_WORKER_ALIVE_CMD <worker>, default: a tmux session or process named for it), or a valid
#                structured blocker: waits_on entry {owner, dependency, next_check > now}, or an open dependency ask id that has an owner and a future due;
#                a prose "waits-on=" in the what column is neither.
#   obligation = overdue (due <= now, nothing accounting for it), stale-claim (claim whose worker is dead), blocker-expired (next_check passed),
#                bad-due (unreadable due). A row not yet due is not an obligation.
# A fingerprint "id|rev|kind|next_check" names each obligation. fu_new_obligations persists the delivered fingerprints under flock, so an unchanged
#   obligation escalates exactly once; a new id, a changed rev or an expired next_check is a new fingerprint. Escalations go to an outbox (jsonl) that
#   fu_outbox_replay delivers through FOLLOWUP_DELIVER_CMD (entry JSON on stdin); a failed delivery stays queued and replays.
# Env: WM_ASKS_BIN FOLLOWUP_STATE_DIR FOLLOWUP_OUTBOX FOLLOWUP_DELIVER_CMD FOLLOWUP_WORKER_ALIVE_CMD FOLLOWUP_NOW (tests).
fu_state_dir() { printf '%s' "${FOLLOWUP_STATE_DIR:-$HOME/.local/state/followup-loop}"; }
fu_now_min() { date -d "${FOLLOWUP_NOW:-now}" '+%Y-%m-%dT%H:%M' 2>/dev/null; }
fu_worker_alive() {
  local w="$1"
  [ -n "$w" ] || return 1
  if [ -n "${FOLLOWUP_WORKER_ALIVE_CMD:-}" ]; then "$FOLLOWUP_WORKER_ALIVE_CMD" "$w" >/dev/null 2>&1; return $?; fi
  tmux has-session -t "$w" 2>/dev/null || pgrep -f -- "$w" >/dev/null 2>&1
}
# fu_eval <seat> : FU_EVAL = JSON array of {id,rev,kind,next_check,fp,due,detail} for the seat's unaccounted obligations (ctl also owns aide rows).
#   rc 1 + FU_REASON when the canonical ledger cannot be read (the caller reports it visibly; never a permissive pass).
fu_eval() {
  local seat="$1" bin="${WM_ASKS_BIN:-wm-asks}" out rc now dead="[]" w owners catchall
  FU_EVAL="[]"; FU_REASON=""
  command -v "$bin" >/dev/null 2>&1 || { FU_REASON="$bin absent"; return 1; }
  command -v jq >/dev/null 2>&1 || { FU_REASON="jq absent"; return 1; }
  out="$(timeout 20 "$bin" query --status open --json 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] || { FU_REASON="ledger query exit $rc"; return 1; }
  printf '%s' "$out" | jq -e 'type=="array" and all(.[]; type=="object" and (.ask_id|type)=="string")' >/dev/null 2>&1 || { FU_REASON="malformed ledger output"; return 1; }
  now="$(fu_now_min)"; [ -n "$now" ] || { FU_REASON="clock unreadable"; return 1; }
  case "$seat" in ctl|aide) owners='["ctl","aide"]'; catchall=true ;; *) owners="[\"$seat\"]"; catchall=false ;; esac
  while IFS= read -r w; do [ -n "$w" ] || continue
    fu_worker_alive "$w" || dead="$(jq -c --arg w "$w" '. + [$w]' <<<"$dead")"
  done < <(jq -r '.[] | select(.claim != null) | ((.claim_session // "") | tostring) as $cs | (if $cs != "" then $cs else (.claim | split("@")[0]) end)' <<<"$out" | sort -u)
  FU_EVAL="$(jq -c --arg now "$now" --argjson owners "$owners" --argjson catchall "$catchall" --argjson dead "$dead" '
    def n16: (tostring | .[0:16]);
    def okts: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}");
    def ts: if okts then (.[0:16] | sub(" "; "T")) else "" end;
    . as $all
    | ["rb","r7","ctl","aide"] as $known
    | [ .[] | select((.owner // "" | tostring) as $o | ($owners | index($o)) or ($catchall and (($known | index($o)) | not))) | . as $r
      | (if ($r.owner // "" | tostring | length) == 0 then " (owner empty: assign an owner)" elif ($known | index($r.owner | tostring)) then "" else " (owner \($r.owner) is not a known seat: reassign)" end) as $ownnote
      | ($r.due // "" | ts) as $due
      | (($r.claim // "") | split("@")) as $cp
      | ($cp[0] // "") as $cw
      | (($cp[1] // "") | ts) as $lease
      | (($r.claim_session // "") | tostring) as $cs
      | (if $cs != "" then $cs else $cw end) as $ck
      | ($r.acceptance.verdict? // "") as $verdict
      | ([ ($r.waits_on // [])[] | select(type == "object") | select(((.owner // "") | tostring | length) > 0 and ((.dependency // "") | tostring | length) > 0 and ((.next_check // "") | ts) != "") | (.next_check | ts) ] ) as $objnc
      | ([ ($r.waits_on // [])[] | select(type == "string") as $d | $all[] | select(.ask_id == $d and .status == "open" and ((.owner // "") | length) > 0 and ((.due // "" | ts) > $now)) | (.due | ts) ]) as $depnc
      | (($objnc + $depnc) | map(select(. > $now))) as $live
      | (($objnc + $depnc) | map(select(. <= $now)) | max // "") as $lapsed
      | if ($r.verifier_required == true) and ($r.ending == true) and $verdict != "PASS" then {id: $r.ask_id, rev: $r.rev, kind: "verifier-pending", next_check: "", due: $due, detail: "ending action on a verifier-required row without a PASS acceptance (verdict: \($verdict | if . == "" then "none" else . end))"}
        elif $cw != "" and ($dead | index($ck)) then {id: $r.ask_id, rev: $r.rev, kind: "stale-claim", next_check: "", due: $due, detail: "claim by \($ck) is stale (worker or session dead or gone)"}
        elif $cw != "" and $lease != "" and $lease <= $now then {id: $r.ask_id, rev: $r.rev, kind: "stale-claim", next_check: "", due: $due, detail: "claim lease \($lease) expired (lease)"}
        elif $cw != "" and ($r.claim_rev != null) and ($r.claim_rev != $r.rev) then {id: $r.ask_id, rev: $r.rev, kind: "stale-claim", next_check: "", due: $due, detail: "claim taken at task revision \($r.claim_rev), row is at revision \($r.rev) (revision)"}
        elif $cw != "" then empty
        elif $due == "" then {id: $r.ask_id, rev: $r.rev, kind: "bad-due", next_check: "", due: "", detail: ("due unreadable" + $ownnote)}
        elif $due > $now then empty
        elif ($live | length) > 0 then empty
        elif $lapsed != "" then {id: $r.ask_id, rev: $r.rev, kind: "blocker-expired", next_check: $lapsed, due: $due, detail: "structured blocker next_check \($lapsed) passed"}
        else {id: $r.ask_id, rev: $r.rev, kind: "overdue", next_check: "", due: $due, detail: ("overdue since \($due), no live claim and no structured blocker (owner, dependency, next check)" + $ownnote)} end
      | . + {fp: "\(.id)|\(.rev)|\(.kind)|\(.next_check)"} ]' <<<"$out" 2>/dev/null)" || { FU_REASON="evaluation failed"; FU_EVAL="[]"; return 1; }
  return 0
}
# fu_outbox_path : the outbox file. fu_lock_file : the ONE lock that serialises fingerprint check, outbox append and outbox replay.
fu_outbox_path() { printf '%s' "${FOLLOWUP_OUTBOX:-$(fu_state_dir)/outbox.jsonl}"; }
fu_lock_file() { printf '%s' "$(fu_state_dir)/lock"; }
# fu_deliver_cmd : the delivery command (entry JSON on stdin): FOLLOWUP_DELIVER_CMD, else followup-deliver.sh beside the hooks' repo (.local/bin), else $HOME/.local/bin.
fu_deliver_cmd() {
  local c here
  if [ -n "${FOLLOWUP_DELIVER_CMD:-}" ]; then printf '%s' "$FOLLOWUP_DELIVER_CMD"; return 0; fi
  here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
  for c in "$here/../../.local/bin/followup-deliver.sh" "$HOME/.local/bin/followup-deliver.sh"; do [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done
  return 1
}
# fu_new_obligations <seat> : under the one flock, prints (one JSON object per line) the obligations whose fingerprint was never delivered before.
#   Each is appended to the outbox FIRST and its fingerprint recorded only after that append succeeded, so a crash or a failed write re-escalates
#   instead of losing the escalation. A ledger failure is itself an obligation (id LEDGER, fingerprint per reason). rc 0 always.
fu_new_obligations() {
  local seat="$1" sd lock seen new line ts ob
  sd="$(fu_state_dir)"; mkdir -p "$sd" 2>/dev/null || return 0
  lock="$(fu_lock_file)"; seen="$sd/delivered.fp"; ts="$(date -Iseconds)"; ob="$(fu_outbox_path)"
  (
    flock -x 9
    if fu_eval "$seat"; then new="$FU_EVAL"
    else new="$(jq -nc --arg r "$FU_REASON" '[{id:"LEDGER",rev:0,kind:"ledger-unreadable",next_check:"",due:"",detail:("ledger malformed or unreadable: " + $r),fp:("LEDGER|0|ledger-unreadable|" + $r)}]')"; fi
    touch "$seen"
    new="$(jq -c --rawfile seen "$seen" '($seen | split("\n") | map(select(length>0))) as $s | [.[] | select(.fp as $f | $s | index($f) | not)] | .[]' <<<"$new" 2>/dev/null)"
    [ -n "$new" ] || exit 0
    while IFS= read -r line; do [ -n "$line" ] || continue
      jq -c --arg seat "$seat" --arg ts "$ts" '. + {seat:$seat, ts:$ts, delivered:false}' <<<"$line" >>"$ob" 2>/dev/null || continue
      jq -r '.fp' <<<"$line" >>"$seen"
      printf '%s\n' "$line"
    done <<<"$new"
  ) 9>"$lock"
}
# fu_outbox_replay : deliver every undelivered outbox entry through fu_deliver_cmd (entry JSON on stdin); mark delivered on rc 0 only; atomic rewrite
#   under the same lock as the append, so a concurrent append is never lost.
fu_outbox_replay() {
  local sd ob lock tmp line dc
  sd="$(fu_state_dir)"; ob="$(fu_outbox_path)"; lock="$(fu_lock_file)"
  [ -s "$ob" ] || return 0
  dc="$(fu_deliver_cmd)" || return 0
  (
    flock -x 9
    tmp="$(mktemp "$ob.XXXXXX")" || exit 0
    while IFS= read -r line; do [ -n "$line" ] || continue
      if [ "$(jq -r '.delivered' <<<"$line" 2>/dev/null)" = false ] && timeout 30 "$dc" <<<"$line" >/dev/null 2>&1; then
        line="$(jq -c '.delivered = true' <<<"$line")"
      fi
      printf '%s\n' "$line" >>"$tmp"
    done <"$ob"
    mv -f "$tmp" "$ob"
  ) 9>"$lock"
}
# fu_block_reason <new-obligations jsonl> : the machine-actionable one-line reason (ids + the specific next action per kind).
fu_block_reason() {
  jq -rs '"FOLLOW-UP ACTION REQUIRED (escalated once, queued in the outbox; an unchanged id is not recited): " + ([.[0:5][] | "\(.id) [\(.kind)] \(.detail) -> next: " + (if .kind=="stale-claim" then "re-dispatch or release the claim (wm-asks claim <id> --worker <live worker>)" elif .kind=="verifier-pending" then "run the required verifier and record a PASS acceptance before the ending action; a FAIL or missing verdict keeps it blocked" elif .kind=="ledger-unreadable" then "repair the canonical ledger query (wm-asks query --status open --json)" else "claim it with a live worker, record a structured blocker (owner, dependency, next check), or resolve it with a PASS acceptance" end)] | join("; ")) + (if length > 5 then " and \(length - 5) more" else "" end)' <<<"$1"
}

# ---- shared evaluator (ledger ask A1346): when .local/bin/followup-eval.py is found, every hook below delegates to it, so owed-now.sh,
# followup-stop-gate.sh and seat-followups.sh read and write ONE fingerprint file (fingerprints.json) and one outbox. Without it the bash path above runs.
fu_eval_bin() {
  local c here
  here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
  for c in "${FOLLOWUP_EVAL:-}" "$here/../../.local/bin/followup-eval.py" "$HOME/.local/bin/followup-eval.py"; do [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return 0; }; done
  return 1
}
_fu_bash_new_obligations() { :; }
eval "$(declare -f fu_new_obligations | sed '1s/fu_new_obligations/_fu_bash_new_obligations/')"
eval "$(declare -f fu_outbox_replay | sed '1s/fu_outbox_replay/_fu_bash_outbox_replay/')"
eval "$(declare -f fu_block_reason | sed '1s/fu_block_reason/_fu_bash_block_reason/')"
fu_new_obligations() { local ev; ev="$(fu_eval_bin)" || { _fu_bash_new_obligations "$@"; return; }; python3 -I "$ev" new --seat "$1" 2>/dev/null | jq -c '.new[]?' 2>/dev/null; return 0; }
fu_outbox_replay() { local ev; ev="$(fu_eval_bin)" || { _fu_bash_outbox_replay "$@"; return; }; python3 -I "$ev" replay >/dev/null 2>&1; return 0; }
fu_block_reason() { local ev; ev="$(fu_eval_bin)" || { _fu_bash_block_reason "$@"; return; }; python3 -I "$ev" reason <<<"$1" 2>/dev/null; }
