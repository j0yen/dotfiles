#!/usr/bin/env bash
# director-hermes-stop-gates.test.sh (hermes-handover 2.7): with WM_DIRECTOR=hermes the five Stop gates REPORT one line and never emit
# decision:block, exit 0; with WM_DIRECTOR unset each still blocks (default unchanged). Stubs only; no ledger, no network.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; H="$root/.claude/hooks"
T="$(mktemp -d "${TMPDIR:-/tmp}/dhsg.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/.cache/aide" "$T/l2" "$T/l3"
fail=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
# verify <name> <out> <rc> : unset-mode must block; hermes-mode must report one line, no block, rc 0
blocks() { jq -e '.decision=="block"' <<<"$1" >/dev/null 2>&1; }
reports() { [ "$(printf '%s\n' "$1" | grep -c .)" = 1 ] && grep -q '^director=hermes report-not-block: ' <<<"$1" && ! grep -q '"decision"' <<<"$1"; }
pair() { # name  unset_out hermes_out hermes_rc
  blocks "$2"; chk "$1: WM_DIRECTOR unset blocks" $?
  reports "$3" && [ "$4" = 0 ]; chk "$1: WM_DIRECTOR=hermes reports one line, no block, exit 0" $?
}
ID=d-20261023-114753-rb-6124
JSON='{"owed":3,"overdue":1,"escalated":0,"oldest":"'$ID'","by_agent":{"rb":3},"ids":[{"state":"overdue","owner":"rb","age_h":120.5,"id":"'$ID'"}]}'
printf '#!/bin/sh\nprintf "%%s\\n" '"'%s'"'\n' "$JSON" >"$T/bin/wm-decide"; chmod +x "$T/bin/wm-decide"
printf '#!/usr/bin/env bash\necho "OWED $1: owed 3, overdue 1, escalated 0, oldest %s"\necho "OVERDUE $1: %s"\n' "$ID" "$ID" >"$T/bin/seat-owed.sh"; chmod +x "$T/bin/seat-owed.sh"
printf '#!/usr/bin/env bash\ncase "$1" in beat) exit 0;; pending) echo "inbox 2 lines"; exit 0;; esac\n' >"$T/bin/aide-wake.sh"; chmod +x "$T/bin/aide-wake.sh"
{ echo '{"type":"user","message":{"content":"go"}}'; echo '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}'; } >"$T/tr.jsonl"
printf 'A1\t2026-10-31T22:00\taide\t2026-10-31T22:30\tk\tc\toverdue row\n' >"$T/oa.tsv"
run() { # <hook-cmd...> with env: D=hermes|"" ; stdin in $T/in
  env -u WM_DIRECTOR ${D:+WM_DIRECTOR=$D} PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TERM=dumb "$@" <"$T/in"
}
IN="{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"stop_hook_active\":false,\"transcript_path\":\"$T/tr.jsonl\",\"last_assistant_message\":\"all done\"}"

# seat-owed-stop
echo "$IN" >"$T/in"
a="$(D= run env WM_SEAT=rb SEAT_OWED_BIN="$T/bin/seat-owed.sh" bash "$H/seat-owed-stop.sh")"
b="$(D=hermes run env WM_SEAT=rb SEAT_OWED_BIN="$T/bin/seat-owed.sh" bash "$H/seat-owed-stop.sh")"; rc=$?
pair seat-owed-stop "$a" "$b" "$rc"
# seat-followups stop
a="$(D= run env WM_SEAT=rb FOLLOWUP_STATE_DIR="$T/s0" WM_FOLLOWUPS_TIMEOUT=3 SEAT_FOLLOWUPS_LOG_DIR="$T/l1" bash "$H/seat-followups.sh" stop)"
b="$(D=hermes run env WM_SEAT=rb FOLLOWUP_STATE_DIR="$T/s1" WM_FOLLOWUPS_TIMEOUT=3 SEAT_FOLLOWUPS_LOG_DIR="$T/l1" bash "$H/seat-followups.sh" stop)"; rc=$?
pair seat-followups "$a" "$b" "$rc"
# followup-stop-gate  # each run gets its own FOLLOWUP_STATE_DIR: the gate delivers a fingerprint once (A1307), so a shared dir made the second run silent
a="$(D= run env WM_SEAT=rb FOLLOWUP_STATE_DIR="$T/s2" WM_DECIDE_BIN="$T/bin/wm-decide" SEATS_TABLE="$T/none.tsv" FOLLOWUP_STOP_FIRES_LOG="$T/l2/fires.log" bash "$H/followup-stop-gate.sh")"
b="$(D=hermes run env WM_SEAT=rb FOLLOWUP_STATE_DIR="$T/s3" WM_DECIDE_BIN="$T/bin/wm-decide" SEATS_TABLE="$T/none.tsv" FOLLOWUP_STOP_FIRES_LOG="$T/l3/fires.log" bash "$H/followup-stop-gate.sh")"; rc=$?
pair followup-stop-gate "$a" "$b" "$rc"
# aide-wake-stop
a="$(D= run env WM_SEAT=aide AIDE_WAKE_BIN="$T/bin/aide-wake.sh" AIDE_WAKE_DIR="$T/wake" bash "$H/aide-wake-stop.sh")"
b="$(D=hermes run env WM_SEAT=aide AIDE_WAKE_BIN="$T/bin/aide-wake.sh" AIDE_WAKE_DIR="$T/wake" bash "$H/aide-wake-stop.sh")"; rc=$?
pair aide-wake-stop "$a" "$b" "$rc"
# owed-now Stop
a="$(D= run env WM_SEAT=aide OPEN_ASKS="$T/oa.tsv" OWED_NOW_STATE="$T/st1" bash "$H/owed-now.sh" hook)"
b="$(D=hermes run env WM_SEAT=aide OPEN_ASKS="$T/oa.tsv" OWED_NOW_STATE="$T/st2" bash "$H/owed-now.sh" hook)"; rc=$?
pair owed-now "$a" "$b" "$rc"
[ "$fail" = 0 ] && echo "PASS director-hermes-stop-gates" || { echo "FAIL director-hermes-stop-gates"; exit 1; }
