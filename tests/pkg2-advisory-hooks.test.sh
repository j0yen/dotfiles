#!/usr/bin/env bash
# pkg2-advisory-hooks.test.sh (A1296 package 2, ledger asks A1307/A1346/A1384/A1387): advisory-hook repair fixtures, hermetic.
# Usage: pkg2-advisory-hooks.test.sh [repo-root]   (default: this repo; point it at a base clone to see the RED side)
# Stubs only: wm-asks / wm-decide are PATH stubs, HOME is a temp dir; the real ledger is never read.
set -u
R="${1:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
W="$(mktemp -d "${TMPDIR:-/tmp}/pkg2.XXXXXX")"; trap 'rm -rf "$W"' EXIT
p=0; f=0; ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
export HOME="$W/home"; mkdir -p "$HOME" "$W/bin"; export TMPDIR="$W"
unset WM_DIRECTOR WM_HELPER FOLLOWUP_TRACE OWED_NOW_SOURCE OPEN_ASKS
export PATH="$W/bin:$PATH" WM_ASKS_BIN="$W/bin/wm-asks" WM_DECIDE_BIN="$W/bin/wm-decide" ASIDE_WM_ASKS_BIN="$W/bin/wm-asks"
export FOLLOWUP_STATE_DIR="$W/st" FOLLOWUP_OUTBOX="$W/st/outbox.jsonl" FOLLOWUP_DELIVER_CMD=true OWED_NOW_STATE="$W/owed" ASIDE_STOP_LOG="$W/fires.log" ASIDE_OPEN_ASKS="$W/none.tsv" SEATS_TABLE="$W/seats.tsv" FOLLOWUP_NOW=2026-11-13T12:00
printf '#!/bin/bash\necho "{\\"owed\\":0,\\"overdue\\":0,\\"escalated\\":0,\\"ids\\":[]}"\n' >"$W/bin/wm-decide"
# wm-asks stub: logs argv to $W/argv.log; $W/mode picks healthy | exit2 | exit127 | malformed. Only the "asks query" form works (a bare "query" exits 2 like the real CLI).
cat >"$W/bin/wm-asks" <<'STUB'
#!/bin/bash
echo "$*" >>"@W@/argv.log"
case "$(cat "@W@/mode" 2>/dev/null)" in
  exit2) exit 2 ;; exit127) exit 127 ;; malformed) echo '{"not":"a list"}'; exit 0 ;;
esac
[ "$1 $2" = "asks query" ] || exit 2
cat "@W@/rows.json"
STUB
sed -i "s#@W@#$W#g" "$W/bin/wm-asks"; chmod +x "$W/bin/"*
ROW='[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"owed thing"}]'
echo "$ROW" >"$W/rows.json"
ASIDE="$R/.claude/hooks/aside-followup-stop.sh"; OWED="$R/.claude/hooks/owed-now.sh"; EVAL="$R/.local/bin/followup-eval.py"

# --- Item 1: director-aside heading control (stdin = Stop hook JSON with transcript_path; the hook reads the last assistant text from the JSONL)
mk(){ jq -nc --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >"$W/tr.jsonl"; }
aside(){ jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | WM_SEAT=ctl WM_DIRECTOR=hermes bash "$ASIDE" 2>/dev/null; }
decision(){ jq -r '.decision // "allow"' <<<"${1:-null}" 2>/dev/null || echo allow; }
mk $'## Director aside: A1307 owed to ctl\nThe rb timer is a separate check, not investigated.\n'
ck "1a heading naming the owed item does not trip the aside Stop hook" "$(decision "$(aside)")" allow
mk $'## Director aside\nThe rb timer is a separate check, not investigated.\n'
ck "1b control: heading with no owed item still blocks" "$(decision "$(aside)")" block
mk $'The rb timer is a separate check, not investigated.\n'
ck "1c control: no heading still blocks" "$(decision "$(aside)")" block
mk $'## Director aside: A1307 owed to ctl\nok.\n'
jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | WM_SEAT=ctl bash "$ASIDE" >/dev/null 2>&1
ck "1d tracing is off by default (no trace log)" "$([ -e "$W/followup-trace.log" ] && echo yes || echo no)" no
jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | FOLLOWUP_TRACE=1 WM_SEAT=ctl bash "$ASIDE" >/dev/null 2>&1
ck "1e FOLLOWUP_TRACE=1 logs every phase" "$(for ph in stdin-parse transcript-read ledger-query phrase-scan; do grep -q "phase=$ph" "$W/followup-trace.log" 2>/dev/null && printf y || printf n; done)" yyyy

# --- Item 2: no instruct-write text in the block message
mk $'The rb timer is a separate check, not investigated.\n'
ck "2a block text does not tell the session to write open-asks.tsv" "$(aside | jq -r '.reason // ""' | grep -c 'open-asks.tsv')" 0
ck "2b block text names the typed ask path" "$(aside | jq -r '.reason // ""' | grep -c 'wm-asks asks add')" 1

# --- Item 3 / AC2: a failed ledger read is loud, never "none owed" (hermetic stub modes)
for m in exit2 exit127 malformed; do
  echo $m >"$W/mode"; out="$(WM_SEAT=ctl bash "$OWED" lint --seat ctl 2>/dev/null)"; rc=$?
  ck "3 $m: lint rc 1" "$rc" 1
  ck "3 $m: LEDGER-UNREADABLE printed" "$(grep -c LEDGER-UNREADABLE <<<"$out")" 1
done
echo exit2 >"$W/mode"
hk="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"s2"}' | WM_SEAT=ctl bash "$OWED" hook 2>/dev/null)"; hrc=$?
ck "3 hook mode: exit 0 with LEDGER-UNREADABLE context" "$hrc/$(grep -c LEDGER-UNREADABLE <<<"$hk")" "0/1"
echo healthy >"$W/mode"
out="$(WM_SEAT=ctl bash "$OWED" lint --seat ctl --now 2026-11-13T12:00 2>/dev/null)"; rc=$?
ck "3 healthy ledger: rows listed, rc 1 (overdue row)" "$rc/$(grep -c '^OVERDUE.*T1' <<<"$out")" "1/1"
ck "3 healthy ledger: no LEDGER-UNREADABLE" "$(grep -c LEDGER-UNREADABLE <<<"$out")" 0
echo '[]' >"$W/rows.json"; out="$(WM_SEAT=ctl bash "$OWED" lint --seat ctl --now 2026-11-13T12:00 2>/dev/null)"; rc=$?
ck "3 empty healthy ledger: rc 0, silent" "$rc/${out:-}" "0/"
echo "$ROW" >"$W/rows.json"
ck "3 A1387: no bare 'wm-asks query' call in hooks or evaluator" "$(grep -rEn 'wm-asks +query|WMA\" +query|WM_ASKS_BIN[^ ]*\}? +query' "$R/.claude/hooks" "$R/.local/bin/followup-eval.py" | grep -vc '^[^:]*:[0-9]*:[[:space:]]*#')" 0
rm -f "$W/argv.log"; WM_SEAT=ctl python3 -I "$EVAL" eval --seat ctl >/dev/null 2>&1
ck "3 A1387: evaluator argv uses the asks query form" "$(head -1 "$W/argv.log")" "asks query --status open --json"

# --- Item 4: ops and ctl are one alias (identical ledger query arguments and dispositions)
args(){ rm -f "$W/argv.log"; python3 -I "$EVAL" eval --seat "$1" >"$W/disp.$1" 2>/dev/null; cat "$W/argv.log"; }
a_ctl="$(args ctl)"; a_ops="$(args ops)"
ck "4a ledger query arguments byte-identical for ops and ctl" "$(printf '%s' "$a_ops" | sha256sum)" "$(printf '%s' "$a_ctl" | sha256sum)"
ck "4b dispositions identical for ops and ctl" "$(sha256sum <"$W/disp.ops")" "$(sha256sum <"$W/disp.ctl")"
ck "4c ops sees the ctl-owned row" "$(jq -r '[.dispositions[]|select(.actionable)|.id]|join(",")' "$W/disp.ops")" T1
ck "4d lint --seat ops lists the same rows as ctl" "$(WM_SEAT=ops bash "$OWED" lint --seat ops --now 2026-11-13T12:00 2>/dev/null | sha256sum)" "$(WM_SEAT=ctl bash "$OWED" lint --seat ctl --now 2026-11-13T12:00 2>/dev/null | sha256sum)"
ck "4e seats.tsv has no ops row (one alias, no duplicate actor)" "$(grep -c '^ops	' "$R/.claude/state/seats.tsv")" 0
echo "pass=$p fail=$f"; [ "$f" = 0 ]
