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
