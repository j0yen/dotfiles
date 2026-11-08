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
  local seat="$1" bin="${WM_ASKS_BIN:-wm-asks}" out rc now dead="[]" w owners
  FU_EVAL="[]"; FU_REASON=""
  command -v "$bin" >/dev/null 2>&1 || { FU_REASON="$bin absent"; return 1; }
  command -v jq >/dev/null 2>&1 || { FU_REASON="jq absent"; return 1; }
  out="$(timeout 20 "$bin" query --status open --json 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] || { FU_REASON="ledger query exit $rc"; return 1; }
  printf '%s' "$out" | jq -e 'type=="array" and all(.[]; type=="object" and (.ask_id|type)=="string")' >/dev/null 2>&1 || { FU_REASON="malformed ledger output"; return 1; }
  now="$(fu_now_min)"; [ -n "$now" ] || { FU_REASON="clock unreadable"; return 1; }
  case "$seat" in ctl|aide) owners='["ctl","aide"]' ;; *) owners="[\"$seat\"]" ;; esac
  while IFS= read -r w; do [ -n "$w" ] || continue
    fu_worker_alive "$w" || dead="$(jq -c --arg w "$w" '. + [$w]' <<<"$dead")"
  done < <(jq -r '.[] | select(.claim != null) | .claim | split("@")[0]' <<<"$out" | sort -u)
  FU_EVAL="$(jq -c --arg now "$now" --argjson owners "$owners" --argjson dead "$dead" '
    def n16: (tostring | .[0:16]);
    def okts: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}");
    def ts: if okts then (.[0:16] | sub(" "; "T")) else "" end;
    . as $all
    | [ .[] | select(.owner as $o | $owners | index($o)) | . as $r
      | ($r.due // "" | ts) as $due
      | (($r.claim // "") | split("@")[0] // "") as $cw
      | ([ ($r.waits_on // [])[] | select(type == "object") | select(((.owner // "") | tostring | length) > 0 and ((.dependency // "") | tostring | length) > 0 and ((.next_check // "") | ts) != "") | (.next_check | ts) ] ) as $objnc
      | ([ ($r.waits_on // [])[] | select(type == "string") as $d | $all[] | select(.ask_id == $d and .status == "open" and ((.owner // "") | length) > 0 and ((.due // "" | ts) > $now)) | (.due | ts) ]) as $depnc
      | (($objnc + $depnc) | map(select(. > $now))) as $live
      | (($objnc + $depnc) | map(select(. <= $now)) | max // "") as $lapsed
      | if $cw != "" and ($dead | index($cw)) then {id: $r.ask_id, rev: $r.rev, kind: "stale-claim", next_check: "", due: $due, detail: "claim by \($cw) is stale (worker dead or gone)"}
        elif $cw != "" then empty
        elif $due == "" then {id: $r.ask_id, rev: $r.rev, kind: "bad-due", next_check: "", due: "", detail: "due unreadable"}
        elif $due > $now then empty
        elif ($live | length) > 0 then empty
        elif $lapsed != "" then {id: $r.ask_id, rev: $r.rev, kind: "blocker-expired", next_check: $lapsed, due: $due, detail: "structured blocker next_check \($lapsed) passed"}
        else {id: $r.ask_id, rev: $r.rev, kind: "overdue", next_check: "", due: $due, detail: "overdue since \($due), no live claim and no structured blocker (owner, dependency, next check)"} end
      | . + {fp: "\(.id)|\(.rev)|\(.kind)|\(.next_check)"} ]' <<<"$out" 2>/dev/null)" || { FU_REASON="evaluation failed"; FU_EVAL="[]"; return 1; }
  return 0
}
# fu_new_obligations <seat> : under flock, prints (one JSON object per line) the obligations whose fingerprint was never delivered before, records
#   them as delivered and appends one outbox entry each. A ledger failure is itself an obligation (id LEDGER, fingerprint per reason). Prints nothing
#   when everything was already delivered. rc 0 always (the caller decides on output).
fu_new_obligations() {
  local seat="$1" sd lock seen new line ts
  sd="$(fu_state_dir)"; mkdir -p "$sd" 2>/dev/null || return 0
  lock="$sd/lock"; seen="$sd/delivered.fp"; ts="$(date -Iseconds)"
  (
    flock -x 9
    if fu_eval "$seat"; then new="$FU_EVAL"
    else new="$(jq -nc --arg r "$FU_REASON" '[{id:"LEDGER",rev:0,kind:"ledger-unreadable",next_check:"",due:"",detail:("ledger malformed or unreadable: " + $r),fp:("LEDGER|0|ledger-unreadable|" + $r)}]')"; fi
    touch "$seen"
    new="$(jq -c --rawfile seen "$seen" '($seen | split("\n") | map(select(length>0))) as $s | [.[] | select(.fp as $f | $s | index($f) | not)] | .[]' <<<"$new" 2>/dev/null)"
    [ -n "$new" ] || exit 0
    while IFS= read -r line; do [ -n "$line" ] || continue
      jq -r '.fp' <<<"$line" >>"$seen"
      jq -c --arg seat "$seat" --arg ts "$ts" '. + {seat:$seat, ts:$ts, delivered:false}' <<<"$line" >>"${FOLLOWUP_OUTBOX:-$sd/outbox.jsonl}"
      printf '%s\n' "$line"
    done <<<"$new"
  ) 9>"$lock"
}
# fu_outbox_replay : deliver every undelivered outbox entry through FOLLOWUP_DELIVER_CMD (entry JSON on stdin); mark delivered on rc 0 only; atomic rewrite.
fu_outbox_replay() {
  local sd ob lock tmp line fp
  sd="$(fu_state_dir)"; ob="${FOLLOWUP_OUTBOX:-$sd/outbox.jsonl}"; lock="$sd/outbox.lock"
  [ -s "$ob" ] && [ -n "${FOLLOWUP_DELIVER_CMD:-}" ] || return 0
  (
    flock -x 9
    tmp="$(mktemp "$ob.XXXXXX")" || exit 0
    while IFS= read -r line; do [ -n "$line" ] || continue
      if [ "$(jq -r '.delivered' <<<"$line" 2>/dev/null)" = false ] && timeout 30 "$FOLLOWUP_DELIVER_CMD" <<<"$line" >/dev/null 2>&1; then
        line="$(jq -c '.delivered = true' <<<"$line")"
      fi
      printf '%s\n' "$line" >>"$tmp"
    done <"$ob"
    mv -f "$tmp" "$ob"
  ) 9>"$lock"
}
# fu_block_reason <new-obligations jsonl> : the machine-actionable one-line reason (ids + the specific next action per kind).
fu_block_reason() {
  jq -rs '"FOLLOW-UP ACTION REQUIRED (escalated once, queued in the outbox; an unchanged id is not recited): " + ([.[0:5][] | "\(.id) [\(.kind)] \(.detail) -> next: " + (if .kind=="stale-claim" then "re-dispatch or release the claim (wm-asks claim <id> --worker <live worker>)" elif .kind=="ledger-unreadable" then "repair the canonical ledger query (wm-asks query --status open --json)" else "claim it with a live worker, record a structured blocker (owner, dependency, next check), or resolve it with a PASS acceptance" end)] | join("; ")) + (if length > 5 then " and \(length - 5) more" else "" end)' <<<"$1"
}
