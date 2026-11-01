#!/usr/bin/env bash
# tests/seat-followups-consumers.test.sh -- A49 D1 + D2: SessionStart prints the seat's owed line; the Stop hook refuses a turn that cites none of the seat's 5 oldest overdue ids.
# wm-decide is a stub on PATH printing fixed JSON; the log dir is a throwaway. No ledger, no ssh.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; START="$root/.claude/hooks/seat-context-start.sh"; FU="$root/.claude/hooks/seat-followups.sh"
fail=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T="$(mktemp -d "${TMPDIR:-/tmp}/sfc.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
ID=d-20261023-114753-rb-6124; ID2=d-20261024-090000-rb-7000
JSON='{"owed":105,"overdue":2,"escalated":1,"oldest":"'$ID'","by_agent":{"rb":105},"ids":[{"state":"overdue","owner":"rb","age_h":120.5,"id":"'$ID2'"},{"state":"escalated","owner":"rb","age_h":200.1,"id":"'$ID'"},{"state":"provisional","owner":"rb","age_h":300.0,"id":"d-prov-1"}]}'
stub() { printf '#!/bin/sh\n%s\n' "$1" >"$T/bin/wm-decide"; chmod +x "$T/bin/wm-decide"; }
okstub() { stub "printf '%s\n' '$JSON'"; }
env_() { env -i PATH="$T/bin:$PATH" HOME="$T/home" TERM=dumb SEAT_FOLLOWUPS_LOG_DIR="$T/log" WM_FOLLOWUPS_TIMEOUT=2 "$@"; }
tr_() { # transcript with a prior turn citing $ID, then a real user msg, then the current turn containing $1
  { echo '{"type":"assistant","message":{"content":[{"type":"text","text":"old turn '"$ID"'"}]}}'
    echo '{"type":"user","message":{"content":"next please"}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"'"$1"'"}]}}'; } >"$T/tr.jsonl"; }
stop() { printf '{"transcript_path":"%s","stop_hook_active":%s}' "$T/tr.jsonl" "${1:-false}" | env_ WM_SEAT="${2-rb}" bash "$FU" stop; }

okstub
out="$(env_ WM_SEAT=rb bash "$START" </dev/null 2>/dev/null)"; rc=$?; echo "D1: $(printf '%s\n' "$out" | grep '^FOLLOWUPS')"
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "^FOLLOWUPS rb: owed 105 overdue 2 escalated 1; oldest 5: $ID $ID2$"; chk "SessionStart prints the owed line with the oldest id first" $?
stub 'sleep 30'; out="$(env_ WM_SEAT=rb bash "$START" </dev/null 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^FOLLOWUPS rb: unknown (timeout)'; chk "stub timeout: unknown line, exit 0" $?
stub 'echo not-json'; out="$(env_ WM_SEAT=rb bash "$FU" line)"; printf '%s' "$out" | grep -q 'unknown (bad JSON)'; chk "bad JSON: unknown line" $?
out="$(env -i PATH=/usr/bin:/bin HOME="$T/home" WM_SEAT=rb bash "$FU" line)"; printf '%s' "$out" | grep -q 'unknown (wm-decide not found)'; chk "missing binary: unknown line" $?

okstub; tr_ "done with the sweep"
out="$(stop)"; echo "D2: $out"
printf '%s' "$out" | jq -e --arg id "$ID" '.decision=="block" and (.reason|contains($id)) and (.reason|contains("\n")|not)' >/dev/null; chk "uncited overdue id: block naming the id, one-line reason" $?
grep -q 'BLOCK' "$T/log/fires.log"; chk "refusal logged to fires.log" $?
tr_ "cleared $ID2 with a verdict row"; out="$(stop)"; [ -z "$out" ]; chk "id cited in the turn: allow" $?
tr_ "FOLLOWUPS rb owed 105->95"; out="$(stop)"; [ -z "$out" ]; chk "FOLLOWUPS owed n->n line: allow" $?
tr_ "done with the sweep"; out="$(stop true)"; [ -z "$out" ]; chk "stop_hook_active true: allow" $?
out="$(stop false '')"; [ -z "$out" ]; chk "no WM_SEAT: allow" $?
stub 'sleep 30'; out="$(stop)"; rc=$?; [ "$rc" = 0 ] && [ -z "$out" ] && grep -q 'ALLOW wm-decide unavailable: timeout' "$T/log/fires.log"; chk "wm-decide timeout on Stop: allow + logged" $?
stub "echo '{\"owed\":0,\"overdue\":0,\"escalated\":0,\"oldest\":null,\"by_agent\":{},\"ids\":[]}'"; out="$(stop)"; [ -z "$out" ]; chk "no overdue ids: allow" $?
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit "$fail"
