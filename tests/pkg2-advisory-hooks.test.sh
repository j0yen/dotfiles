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
  exit2) exit 2 ;; exit2json) cat "@W@/rows.json"; exit 2 ;; object) echo '{"ask_id":"A1","owner":"ctl","what":"x.service"}'; exit 0 ;; garbage) echo 'error: x.service A1 not found'; exit 0 ;; exit127) exit 127 ;; malformed) echo '{"not":"a list"}'; exit 0 ;;
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
ROWS2='[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"owed thing"},{"ask_id":"A1307","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"advisory hooks repair"}]'
echo "$ROWS2" >"$W/rows.json"
mk $'## Director aside: A1307 owed to ctl\nThe rb timer is a separate check, not investigated.\n'
ck "1a heading naming an OPEN ledger row of this seat does not trip the aside Stop hook" "$(decision "$(aside)")" allow
mk $'## Director aside\nThe rb timer is a separate check, not investigated.\n'
ck "1b control: heading with no owed item still blocks" "$(decision "$(aside)")" block
mk $'The rb timer is a separate check, not investigated.\n'
ck "1c control: no heading still blocks" "$(decision "$(aside)")" block
echo "$ROW" >"$W/rows.json"
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
WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1   # critical-path reduction (A1296): the prompt reads the producer's cache; the producer ran against the failing ledger
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

# --- F1: a token-shaped heading suppresses only when it names an actual OPEN row of this seat (healthy ledger holds only T1 owned by ctl, plus closed/foreign rows are absent or other-owned)
UN=$'The deploy is a separate check, not investigated. Also still open: the rollout, flagged for later.\n'
echo '[{"ask_id":"A55","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"owed thing at /srv/real/path and unit x.service","key":"x.service","scope":"/srv/real/path"},{"ask_id":"P7","rev":1,"owner":"rb","due":"2026-11-13T09:00","what":"foreign row"}]' >"$W/rows.json"
echo healthy >"$W/mode"
i=0; for h in '## Director aside: A99999' '## Director aside "xyz"' '###### Director aside A1' '## Director aside /tmp/x/y' '## Director aside: A2 (closed)' '## Director aside: P7 (foreign owner)' '## Director aside: d-20261113-nothing' '## Director aside: ghost.timer' '## Director aside: repo#99'; do
  i=$((i+1)); mk "$h"$'\n'"$UN"; ck "F1.$i unowed heading [$h] still blocks" "$(decision "$(aside)")" block
done
for h in '## Director aside: A55' '## Director aside /srv/real/path' '## Director aside: x.service'; do
  mk "$h"$'\n'"$UN"; ck "F1 owed heading [$h] (open row of this seat) accounts the section" "$(decision "$(aside)")" allow
done
mk $'The x.service is a separate check, not investigated.\n'; ck "F1 sentence naming a bound open row token is allowed (pins 'asks query' form)" "$(decision "$(aside)")" allow

# --- F2: failed / non-JSON canonical read = UNKNOWN: never a match, never a TSV fallback, never silent
printf 'A1\topen row about x.service\n' >"$W/legacy.tsv"
mk $'The x.service is a separate check, not investigated.\n'
echo exit2json >"$W/mode"; ck "F2a exit 2 with a valid-looking JSON list is not read (blocks)" "$(decision "$(aside)")" block
ck "F2a block says LEDGER-UNKNOWN" "$(aside | jq -r .reason | grep -c LEDGER-UNKNOWN)" 1
echo garbage >"$W/mode"; ck "F2b exit 0 non-JSON text naming the token is not a match (blocks)" "$(decision "$(aside)")" block
ck "F2b block says LEDGER-UNKNOWN" "$(aside | jq -r .reason | grep -c LEDGER-UNKNOWN)" 1
echo object >"$W/mode"; ck "F2b2 exit 0 JSON object (not a list) naming the token is not a match (blocks)" "$(decision "$(aside)")" block
echo exit2 >"$W/mode"
ck "F2c failed reader + legacy TSV holding the token: no TSV fallback (blocks)" "$(jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | ASIDE_OPEN_ASKS="$W/legacy.tsv" WM_SEAT=ctl bash "$ASIDE" 2>/dev/null | jq -r '.decision // "allow"')" block
echo healthy >"$W/mode"
echo '[{"ask_id":"U1","owner":null,"what":"x.service owner unreadable"},{"ask_id":"U2","owner":"ctl","what":{"bad":1}}]' >"$W/rows.json"
ck "F2d unreadable owner/field rows are not used (blocks)" "$(decision "$(aside)")" block
ck "F2d and the block reports them" "$(aside | jq -r .reason | grep -c 'unreadable owner')" 1
echo '[{"ask_id":"R9","owner":"rb","what":"x.service of rb"}]' >"$W/rows.json"
ck "F2e foreign-owner row does not match (seat ctl blocks)" "$(decision "$(aside)")" block
echo "$ROW" >"$W/rows.json"

# --- F3: trace is private (0600, no-follow)
rm -f "$W/followup-trace.log" "$W/victim"; : >"$W/victim"; ln -s "$W/victim" "$W/followup-trace.log"
jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | FOLLOWUP_TRACE=1 WM_SEAT=ctl bash "$ASIDE" >/dev/null 2>&1
ck "F3a planted symlink: victim not written" "$(wc -c <"$W/victim")" 0
rm -f "$W/followup-trace.log"
jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | (umask 002; FOLLOWUP_TRACE=1 WM_SEAT=ctl bash "$ASIDE" >/dev/null 2>&1)
ck "F3b trace file mode 600 under umask 002" "$(stat -c %a "$W/followup-trace.log")" 600
ck "F3c trace file owned by us and has phases" "$([ -O "$W/followup-trace.log" ] && grep -c phase= "$W/followup-trace.log")" 4
rm -f "$W/followup-trace.log"; : >"$W/followup-trace.log"; chmod 664 "$W/followup-trace.log"
jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | FOLLOWUP_TRACE=1 WM_SEAT=ctl bash "$ASIDE" >/dev/null 2>&1
ck "F3d pre-existing 664 own file is tightened to 600" "$(stat -c %a "$W/followup-trace.log")" 600
rm -f "$W/followup-trace.log"

# --- F5: pins for the four mutations the reviewer found alive
ASKSV="$W/bin/asks-view"
printf '#!/bin/bash\nprintf "A9\\tOPEN\\tctl\\t2026-11-13T09:00\\tk\\tc\\tctl-owned view row\\n"\n' >"$ASKSV"; chmod +x "$ASKSV"
ck "F5b asks-view failure is LEDGER-UNREADABLE rc 1 (non-asks source)" "$(OWED_NOW_SOURCE=view ASKS_VIEW_BIN=false bash "$OWED" lint --seat ctl --now 2026-11-13T12:00 2>/dev/null | grep -c LEDGER-UNREADABLE)/$(OWED_NOW_SOURCE=view ASKS_VIEW_BIN=false bash "$OWED" lint --seat ctl >/dev/null 2>&1; echo $?)" "1/1"
ck "F5c ops lint over the asks-view source lists the ctl-owned row (bash alias line)" "$(OWED_NOW_SOURCE=view ASKS_VIEW_BIN="$ASKSV" bash "$OWED" lint --seat ops --now 2026-11-13T12:00 2>/dev/null | grep -c A9)" 1

# --- G (A1296 pkg2 review 2): helpers
asidef(){ jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | WM_SEAT="${SEAT_:-ctl}" "$@" bash "$ASIDE" 2>/dev/null; }
asideenv(){ local s="$1"; shift; jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | env WM_SEAT="$s" "$@" bash "$ASIDE" 2>/dev/null; }
echo healthy >"$W/mode"

# --- G1 (major): a heading binds ONLY by exact equality on the open row's canonical ask_id or its typed key/scope field, never by free text (what/check)
echo '[{"ask_id":"A55","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"owed thing; mentions A99999 and \"xyz\" and closedref A2 at /tmp/x/y, repo#99, ghost.timer, \"owed\", foreign.timer","check":"test -e /var/chk/path","key":"k.service","scope":"/srv/real/path"},{"ask_id":"P7","rev":1,"owner":"rb","due":"2026-11-13T09:00","what":"foreign row","key":"foreign.timer"},{"ask_id":"A5000","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"long id row"}]' >"$W/rows.json"
i=0; for h in '## Director aside: A99999' '## Director aside "xyz"' '## Director aside: A2 (closed)' '## Director aside /tmp/x/y' '## Director aside: repo#99' '## Director aside: ghost.timer' '## Director aside "owed"' '## Director aside: P7 (foreign id)' '## Director aside: foreign.timer (foreign key)' '## Director aside /var/chk/path' '## Director aside: A5' '## Director aside: A500'; do
  i=$((i+1)); mk "$h"$'\n'"$UN"; ck "G1.$i id/token only in free text or foreign [$h] still blocks" "$(decision "$(aside)")" block
done
for h in '## Director aside: A55' '## Director aside: k.service' '## Director aside /srv/real/path' '## Director aside "k.service"'; do
  mk "$h"$'\n'"$UN"; ck "G1 open row bound by ask_id / typed key / typed scope [$h] accounts the section" "$(decision "$(aside)")" allow
done
mk $'The A5 item is a separate check, not investigated.\n'; ck "G1 sentence token A5 does not bind to row A55 (word-bounded)" "$(decision "$(aside)")" block

# --- G6 N5: a bound heading ends at the next heading
mk $'## Director aside: A55\nowed accounted.\n## Other section\nThe deploy is a separate check, not investigated.\n'
ck "G6 N5 section ends at next heading: unowed aside after it blocks" "$(decision "$(aside)")" block
# --- G6 N6: seat ops is a ctl alias inside the aside hook
echo '[{"ask_id":"A55","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"owed x.service","key":"x.service"}]' >"$W/rows.json"
mk $'The x.service is a separate check, not investigated.\n'
ck "G6 N6 seat ops sees the ctl-owned row (alias in aside hook): allow" "$(decision "$(asideenv ops)")" allow
ck "G6 N6 control: seat rb does not see the ctl-owned row: block" "$(decision "$(asideenv rb)")" block
mk $'## Director aside: x.service\nThe deploy is a separate check, not investigated.\n'
ck "G6 N6b seat ops heading bound to ctl-owned typed key: allow" "$(decision "$(asideenv ops)")" allow

# --- G4/E1: any malformed row (missing ask_id) makes the whole read UNKNOWN; the partial rows are not used
mk $'The x.service is a separate check, not investigated.\n'
echo '[{"ask_id":"A55","owner":"ctl","what":"x.service","key":"x.service"},{"owner":"ctl"}]' >"$W/rows.json"
ck "G4 row lacking ask_id: blocks (partial rows not used)" "$(decision "$(aside)")" block
ck "G4 and says LEDGER-UNKNOWN malformed" "$(aside | jq -r .reason | grep -c 'LEDGER-UNKNOWN: malformed ledger output')" 1
echo '[{"owner":"rb"}]' >"$W/rows.json"
ck "G4 row lacking ask_id, other owner: still LEDGER-UNKNOWN malformed" "$(aside | jq -r .reason | grep -c 'LEDGER-UNKNOWN: malformed ledger output')" 1
echo '[{"ask_id":7,"owner":"ctl"}]' >"$W/rows.json"
ck "G4 non-string ask_id: LEDGER-UNKNOWN malformed" "$(aside | jq -r .reason | grep -c 'LEDGER-UNKNOWN: malformed ledger output')" 1
echo '["A55"]' >"$W/rows.json"
ck "G4 list of non-dicts: LEDGER-UNKNOWN malformed" "$(aside | jq -r .reason | grep -c 'LEDGER-UNKNOWN: malformed ledger output')" 1
echo "$ROW" >"$W/rows.json"

# --- G5/E2: the fires log (holds sentence excerpts) is private under a permissive caller umask
rm -rf "$W/fl"; mk $'The deploy is a separate check, not investigated.\n'
jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | (umask 002; ASIDE_STOP_LOG="$W/fl/sub/fires.log" WM_SEAT=ctl bash "$ASIDE" >/dev/null 2>&1)
ck "G5 fires log dir mode 700 under umask 002" "$(stat -c %a "$W/fl/sub" 2>/dev/null)" 700
ck "G5 fires log file mode 600 under umask 002" "$(stat -c %a "$W/fl/sub/fires.log" 2>/dev/null)" 600

# --- G2/G3: opt-in trace refuses a FIFO (no hang), a hardlink and a symlinked parent dir
tr_run(){ jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | TMPDIR="$1" FOLLOWUP_TRACE=1 WM_SEAT=ctl timeout 6 bash "$ASIDE" >/dev/null 2>&1; echo $?; }
mkdir -p "$W/tf"; rm -f "$W/tf/followup-trace.log"; mkfifo "$W/tf/followup-trace.log"
ck "G2 planted FIFO, no reader: hook returns promptly (rc 0, no hang)" "$(tr_run "$W/tf")" 0
( timeout 8 cat "$W/tf/followup-trace.log" >"$W/fifo.got" 2>/dev/null & ) ; sleep 0.3
ck "G2 planted FIFO, reader present: hook returns promptly (rc 0)" "$(tr_run "$W/tf")" 0
sleep 0.5; ck "G2 nothing was written into the FIFO" "$(wc -c <"$W/fifo.got" 2>/dev/null || echo 0)" 0
rm -f "$W/tf/followup-trace.log"
mkdir -p "$W/th"; : >"$W/th/orig"; chmod 666 "$W/th/orig"; ln "$W/th/orig" "$W/th/followup-trace.log"
ck "G3 hardlinked trace path: hook returns rc 0" "$(tr_run "$W/th")" 0
ck "G3 hardlink: other name not written" "$(wc -c <"$W/th/orig")" 0
ck "G3 hardlink: other name mode untouched (666)" "$(stat -c %a "$W/th/orig")" 666
mkdir -p "$W/real"; rm -f "$W/lnk"; ln -s "$W/real" "$W/lnk"
ck "G3 symlinked parent dir: hook returns rc 0" "$(tr_run "$W/lnk")" 0
ck "G3 symlinked parent dir: nothing created in the target" "$(ls -A "$W/real" | wc -l)" 0
# --- G6 N9: a regular, single-link trace file owned by ANOTHER uid is refused (user namespace maps a second uid; no root needed)
mkdir -p "$W/tu"; rm -f "$W/tu/followup-trace.log"
nsout="$(unshare -U --map-users=0:$(id -u):1 --map-users=1:100000:10 --map-groups=0:$(id -g):1 --map-groups=1:100000:10 bash -c '
  : >"$1/tu/followup-trace.log"; chown 1:1 "$1/tu/followup-trace.log"; chmod 666 "$1/tu/followup-trace.log"
  jq -nc --arg tp "$1/tr.jsonl" "{transcript_path:\$tp,stop_hook_active:false,session_id:\"s1\"}" | TMPDIR="$1/tu" FOLLOWUP_TRACE=1 WM_SEAT=ctl bash "$2" >/dev/null 2>&1
  echo "$(stat -c %s "$1/tu/followup-trace.log") $(stat -c %u "$1/tu/followup-trace.log")"' _ "$W" "$ASIDE" 2>&1)"
ck "G6 N9 foreign-uid trace file is not written (size 0, uid 1)" "$nsout" "0 1"

# --- G7: a reader timeout is UNKNOWN (never a match, never silent); knob ASIDE_WM_ASKS_TIMEOUT (default 5 s of the 10 s hook budget)
printf '#!/bin/bash\nexec sleep 20\n' >"$W/bin/wm-asks-slow"; chmod +x "$W/bin/wm-asks-slow"
mk $'The x.service is a separate check, not investigated.\n'; : >"$W/fires.log"
t0=$(date +%s); o="$(asideenv ctl ASIDE_WM_ASKS_BIN="$W/bin/wm-asks-slow" ASIDE_WM_ASKS_TIMEOUT=1)"; t1=$(date +%s)
ck "G7 slow reader: blocks" "$(decision "$o")" block
ck "G7 slow reader: says LEDGER-UNKNOWN TimeoutExpired" "$(jq -r .reason <<<"$o" | grep -c 'LEDGER-UNKNOWN: ledger command failed: TimeoutExpired')" 1
ck "G7 slow reader: bounded wall time (<= 4 s with a 1 s timeout)" "$([ $((t1-t0)) -le 4 ] && echo ok)" ok
ck "G7 timeout is logged (not silent)" "$(grep -c 'ledger-unknown ledger command failed: TimeoutExpired' "$W/fires.log")" 1
printf '#!/bin/bash\nexec sleep 20\n' >"$W/bin/wm-asks-slow2"
mk $'## Director aside: x.service\nThe deploy is a separate check, not investigated.\n'
ck "G7 slow reader: a heading is not suppressed (blocks)" "$(decision "$(asideenv ctl ASIDE_WM_ASKS_BIN="$W/bin/wm-asks-slow" ASIDE_WM_ASKS_TIMEOUT=1)")" block

# --- H1 (A1296 pkg2 repair 3, drift): stderr_hint on the canonical-reader failure path of followup-eval.py. Advisory text only: the verdict (error set, no dispositions, lint rc 1) never changes. FAKE canaries only.
printf '#!/bin/bash\ncat "%s/err.bin" >&2\nexit 2\n' "$W" >"$W/bin/wm-asks-err"; chmod +x "$W/bin/wm-asks-err"
hint(){ WM_ASKS_BIN="$W/bin/wm-asks-err" python3 -I "$EVAL" eval --seat ctl 2>/dev/null | jq -r '.error // "NOERROR"'; }
hc(){ # hc <name> <stderr-bytes-printf-fmt> <canary...>: no canary survives in the error text; the failure prefix is intact
  local n="$1" b="$2" e c bad=0; shift 2; printf "$b" >"$W/err.bin"; e="$(hint)"
  for c in "$@"; do case "$e" in *"$c"*) bad=1;; esac; done
  ck "H1 redaction $n: no canary survives" "$bad" 0
  ck "H1 redaction $n: reason keeps 'ledger query exit 2'" "$([ "${e#ledger query exit 2}" != "$e" ] && echo ok)" ok
}
hc kv-token 'wm-asks: auth failed token=FAKECANARY1234567890abc\n' FAKECANARY1234567890abc
hc kv-key 'wm-asks: bad key=FAKEKEYVALUE99 supplied\n' FAKEKEYVALUE99
hc kv-password 'wm-asks: password: FAKEPASSWORD77 rejected\n' FAKEPASSWORD77
hc kv-secret-colon 'secret=FAKESECRETVALUE5\n' FAKESECRETVALUE5
hc bearer 'HTTP 401 Authorization: Bearer FAKEBEARER.abc-def_123456\n' FAKEBEARER
hc basic 'Authorization: Basic ZmFrZTpjYW5hcnk=\n' ZmFrZTpjYW5hcnk
hc sk-ant 'invalid credential sk-ant-api03-FAKEANTCANARY0123456789\n' FAKEANTCANARY0123456789
hc ghp 'clone failed ghp_FAKEGHPCANARY123456 denied\n' FAKEGHPCANARY123456
hc url-userinfo 'dial https://fakeuser:FAKEURLPASS@ledger.example/x failed\n' FAKEURLPASS fakeuser
hc url-query 'GET https://ledger.example/q?api_key=FAKEQUERYSECRET&x=1 refused\n' FAKEQUERYSECRET
hc url-query-sig 'GET https://ledger.example/q?x=1&signature=FAKESIGVALUE88 refused\n' FAKESIGVALUE88
hc email 'denied for fake.canary+tag@example.invalid on ledger\n' fake.canary example.invalid
hc quoted-multiword 'bad password="FAKEQ one FAKEQ two three" given\n' 'FAKEQ one' 'FAKEQ two' three
hc single-quoted 'bad token='"'"'FAKESQ alpha beta'"'"' given\n' 'FAKESQ' alpha beta
hc long-blob 'blob FAKELONGBLOB0123456789abcdefghijklmnopqrstuvwxyz0123 end\n' FAKELONGBLOB0123456789
hc multiline-second 'wm-asks: database is locked\ntoken=FAKESECONDLINECANARY\n' FAKESECONDLINECANARY
hc cookie 'Cookie: session=FAKECOOKIEVALUE12345\n' FAKECOOKIEVALUE12345
printf 'wm-asks: database is locked\ntoken=FAKESECONDLINECANARY\n' >"$W/err.bin"
ck "H1 multi-line: first line only, kept" "$(hint | grep -c 'database is locked')" 1
printf '' >"$W/err.bin"
ck "H1 empty stderr: exactly 'ledger query exit 2'" "$(hint)" "ledger query exit 2"
printf '   \n\n' >"$W/err.bin"
ck "H1 blank-only stderr: exactly 'ledger query exit 2'" "$(hint)" "ledger query exit 2"
printf 'wm-asks: database is locked\n' >"$W/err.bin"
ck "H1 benign stderr is shown as advisory text" "$(hint)" "ledger query exit 2: wm-asks: database is locked"
python3 -c 'import sys; sys.stdout.buffer.write(b"bad bytes \xff\xfe\x80 then token=FAKENONUTF8CANARY end\n")' >"$W/err.bin"
e="$(hint)"; ck "H1 non-UTF-8 stderr: no crash, prefix kept" "$([ "${e#ledger query exit 2}" != "$e" ] && echo ok)" ok
ck "H1 non-UTF-8 stderr: canary redacted" "$(grep -c FAKENONUTF8CANARY <<<"$e")" 0
python3 -c 'print("x"*5000 + " token=FAKELONGLINECANARY")' >"$W/err.bin"
e="$(hint)"; ck "H1 very long line: bounded (<= 21+160 chars)" "$([ ${#e} -le 181 ] && echo ok)" ok
python3 -c 'print("short token=FAKELONGLINECANARY2 " + "y "*5000)' >"$W/err.bin"
ck "H1 very long line: canary at the start redacted" "$(hint | grep -c FAKELONGLINECANARY2)" 0
printf 'ctl\001\033[31m red\033[0m control\n' >"$W/err.bin"
ck "H1 control characters dropped" "$(hint | LC_ALL=C grep -c "[[:cntrl:]]")" 0
# verdict never changes: same rc / error presence / no dispositions for empty, benign and hostile stderr; owed-now lint stays fail-closed (rc 1, LEDGER-UNREADABLE)
for body in '' 'wm-asks: database is locked\n' 'token=FAKEVERDICTCANARY\n'; do
  printf "$body" >"$W/err.bin"
  ck "H1 verdict unchanged [$body]: error set, no dispositions" "$(WM_ASKS_BIN="$W/bin/wm-asks-err" python3 -I "$EVAL" eval --seat ctl 2>/dev/null | jq -c '[(.error|startswith("ledger query exit 2")), (.dispositions // [] | length)]')" "[true,0]"
  out="$(WM_ASKS_BIN="$W/bin/wm-asks-err" WM_SEAT=ctl bash "$OWED" lint --seat ctl 2>/dev/null)"; rc=$?
  ck "H1 lint [$body]: rc 1 + LEDGER-UNREADABLE, no canary" "$rc $(grep -c LEDGER-UNREADABLE <<<"$out") $(grep -c FAKEVERDICTCANARY <<<"$out")" "1 1 0"
done

# --- R3-2: pin the DEFAULT reader timeout (no knob), the WM_HELPER bypass and every aside phrase
printf '#!/bin/bash\nexec sleep 9\n' >"$W/bin/wm-asks-slow9"; chmod +x "$W/bin/wm-asks-slow9"
echo "$ROW" >"$W/rows.json"; echo healthy >"$W/mode"
mk $'The x.service is a separate check, not investigated.\n'; : >"$W/fires.log"
t0=$(date +%s); o="$(asideenv ctl ASIDE_WM_ASKS_BIN="$W/bin/wm-asks-slow9")"; t1=$(date +%s)
ck "R3-2 default timeout (no knob): slow reader times out with TimeoutExpired" "$(jq -r '.reason // ""' <<<"$o" | grep -c 'LEDGER-UNKNOWN: ledger command failed: TimeoutExpired')" 1
ck "R3-2 default timeout is 5 s, not longer (returns in < 8 s)" "$([ $((t1-t0)) -lt 8 ] && [ $((t1-t0)) -ge 4 ] && echo ok)" ok
mk $'The rb timer is a separate check, not investigated.\n'
ck "R3-2 V8 control: no WM_HELPER blocks" "$(decision "$(asideenv ctl)")" block
ck "R3-2 V8 WM_HELPER=1 child exits allow without a ledger read" "$(decision "$(asideenv ctl WM_HELPER=1)")" allow
: >"$W/argv.log"; asideenv ctl WM_HELPER=1 >/dev/null
ck "R3-2 V8 WM_HELPER=1 does not query the ledger" "$(wc -l <"$W/argv.log")" 0
for ph in "separate check" "not investigated" "unrelated to" "informational" "still open" "has not been done" "flagged" "worth a look" "later"; do
  mk "The zzz item is $ph for the rb timer."$'\n'
  ck "R3-2 V10 phrase [$ph] blocks an unrowed sentence" "$(decision "$(asideenv ctl)")" block
done

# --- R3-3: the SENTENCE path binds the same way the heading path does: exact equality of a sentence token with the typed ask_id / key / scope of an open row of THIS seat; free text (what/check) never binds
echo '[{"ask_id":"A55","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"owed thing; mentions A99999 and \"xyz\" and closedref A2 at /tmp/x/y, repo#99, ghost.timer, \"owed\", foreign.timer","check":"test -e /var/chk/path","key":"k.service","scope":"/srv/real/path"},{"ask_id":"P7","rev":1,"owner":"rb","due":"2026-11-13T09:00","what":"foreign row","key":"foreign.timer"},{"ask_id":"A5000","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"long id row"}]' >"$W/rows.json"
for t in A99999 '"xyz"' A2 /tmp/x/y repo#99 ghost.timer '"owed"' foreign.timer /var/chk/path A5 A500 P7 d-20261113-ghost; do
  mk "The item $t is a separate check, not investigated."$'\n'
  ck "R3-3 sentence token [$t] (ghost/closed/quoted/in-other-row-text/path/foreign) does not suppress" "$(decision "$(asideenv ctl)")" block
done
for t in A55 k.service /srv/real/path A5000; do
  mk "The item $t is a separate check, not investigated."$'\n'
  ck "R3-3 sentence token [$t] bound by ask_id/key/scope of an open row of this seat allows" "$(decision "$(asideenv ctl)")" allow
done
mk $'The item "k.service" is a separate check, not investigated.\n'
ck "R3-3 quoted typed key allows" "$(decision "$(asideenv ctl)")" allow
mk $'The item P7 is a separate check, not investigated.\n'
ck "R3-3 foreign-seat ask_id as seen by rb allows (own row)" "$(decision "$(asideenv rb)")" allow
mk $'The item A55 is a separate check, not investigated.\n'
ck "R3-3 ctl row id seen by rb (foreign) blocks" "$(decision "$(asideenv rb)")" block
echo "$ROW" >"$W/rows.json"

# --- pins for the remaining base-line gates and the hint's shape (review-3 survivors V7, V9; hint first-non-empty-line and the 160-char bound)
mk $'The rb timer is a separate check, not investigated.\n'
ck "R3-2 V7 control: seat session blocks" "$(decision "$(asideenv ctl)")" block
ck "R3-2 V7 no WM_SEAT (plain/director session) is never gated" "$(decision "$(jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:false,session_id:"s1"}' | env -u WM_SEAT bash "$ASIDE" 2>/dev/null)")" allow
ck "R3-2 V9 stop_hook_active=true (loop guard) allows" "$(decision "$(jq -nc --arg tp "$W/tr.jsonl" '{transcript_path:$tp,stop_hook_active:true,session_id:"s1"}' | WM_SEAT=ctl bash "$ASIDE" 2>/dev/null)")" allow
printf '\n   \nwm-asks: database is locked\nsecond line\n' >"$W/err.bin"
ck "H1 leading blank lines skipped: first NON-EMPTY line is the hint" "$(hint)" "ledger query exit 2: wm-asks: database is locked"
python3 -c 'print("wm-asks: " + "word " * 200)' >"$W/err.bin"
e="$(hint)"; ck "H1 long benign line: truncated to 160 chars after the prefix" "$([ ${#e} -eq 181 ] && echo ok)" ok
# --- rv4 repair 4 (F4-1..F4-6): the hint redacts every class the installed helper does (no leading \b), JSON keys, credential-like URL query names by pattern, every Cookie pair, and pins redact-then-truncate
# F4-1 prefixed / compound credential names (installed helper redacted all of these)
hc f41-db_password 'x db_password=FAKEF41A1\n' FAKEF41A1
hc f41-GITHUB_TOKEN 'x GITHUB_TOKEN=FAKEF41A2\n' FAKEF41A2
hc f41-x_api_key 'x x_api_key=FAKEF41A3\n' FAKEF41A3
hc f41-apikey-colon 'x apikey: FAKEF41A4\n' FAKEF41A4
hc f41-authToken 'x authToken=FAKEF41A5\n' FAKEF41A5
hc f41-secret_key 'x secret_key=FAKEF41A6\n' FAKEF41A6
hc f41-AWS_SECRET_ACCESS_KEY 'AWS_SECRET_ACCESS_KEY=FAKEF41A7\n' FAKEF41A7
hc f41-client_secret 'client_secret=FAKEF41A8\n' FAKEF41A8
hc f41-private_key-colon 'my_private_key: FAKEF41A9\n' FAKEF41A9
hc f41-X-Api-Key 'X-Api-Key: FAKEF41B1\n' FAKEF41B1
hc f41-refresh_token 'refresh_token=FAKEF41B2\n' FAKEF41B2
hc f41-DB-PASSWORD 'DB-PASSWORD=FAKEF41B3\n' FAKEF41B3
hc f41-suffix-token_value 'x token_value=FAKEF41C1\n' FAKEF41C1
hc f41-suffix-passwordhash 'x passwordhash: FAKEF41C2\n' FAKEF41C2
hc f41-suffix-keyid-json '{"keyid":"FAKEF41C3"}\n' FAKEF41C3
# F4-2 JSON-embedded keys (quoted key, spacing variants)
hc f42-json-password '{"password":"FAKEF42A1","u":1}\n' FAKEF42A1
hc f42-json-token-space '{"token": "FAKEF42A2"}\n' FAKEF42A2
hc f42-json-api_key '{"api_key":"FAKEF42A3"}\n' FAKEF42A3
hc f42-json-client_secret '{ "client_secret" : "FAKEF42A4" }\n' FAKEF42A4
hc f42-json-single "{'secret': 'FAKEF42A5'}\n" FAKEF42A5
hc f42-json-nested '{"a":{"authorization":"FAKEF42A6"},"b":2}\n' FAKEF42A6
hc f42-json-multiword '{"password":"FAKEF42A7 two words"}\n' FAKEF42A7 'two words'
hc f42-json-numeric '{"pin_token":FAKEF42A8}\n' FAKEF42A8
# F4-3 URL query credential-like names by pattern + userinfo
for nm in code session sid jwt otp ticket access_token id_token X-Amz-Signature refresh_token client_secret apikey signature X-Amz-Credential nonce sessionid csrf_token; do
  hc "f43-query-$nm" "GET https://h/p?a=1&$nm=FAKEF43V1&b=2\n" FAKEF43V1
  hc "f43-query-first-$nm" "GET https://h/p?$nm=FAKEF43V2\n" FAKEF43V2
done
hc f43-userinfo-user-only 'GET https://FAKEF43U1@h/p\n' FAKEF43U1
hc f43-userinfo-pass 'GET http://usr:FAKEF43U2@h:8080/p\n' FAKEF43U2
hc f43-query-then-text 'GET https://h/p?a=1&code=FAKEF43V3 failed\n' FAKEF43V3
printf 'GET https://h/p?page=2&limit=5 refused\n' >"$W/err.bin"
ck "F4-3 benign query names (page, limit) stay visible" "$(hint | grep -c 'page=2&limit=5')" 1
# F4-4 Cookie: every pair; residual survivors outside the brief list
hc f44-cookie-pairs 'Cookie: sid=FAKEF44A1; other=FAKEF44A2; third=FAKEF44A3\n' FAKEF44A1 FAKEF44A2 FAKEF44A3
hc f44-set-cookie 'Set-Cookie: sid=FAKEF44B1; Path=/; HttpOnly\n' FAKEF44B1
hc f44-cookie-three-lower 'cookie: a=FAKEF44B2; b=FAKEF44B3\n' FAKEF44B2 FAKEF44B3
hc f44-pwd 'pwd=FAKEF44C1\n' FAKEF44C1
hc f44-passwd-colon 'passwd: FAKEF44C2\n' FAKEF44C2
hc f44-pass-eq 'pass=FAKEF44C3\n' FAKEF44C3
hc f44-passphrase 'passphrase=FAKEF44C4\n' FAKEF44C4
hc f44-minus-p 'mysql -pFAKEF44C5 db\n' FAKEF44C5
hc f44-password-flag 'cmd --password FAKEF44C6\n' FAKEF44C6
hc f44-token-flag 'cmd --token=FAKEF44C7\n' FAKEF44C7
hc f44-pem 'x -----BEGIN PRIVATE KEY----- FAKEF44D1\n' FAKEF44D1
hc f44-pem-rsa 'x -----BEGIN RSA PRIVATE KEY----- FAKEF44D2\n' FAKEF44D2
hc f44-ssh-rsa 'ssh-rsa AAAAB3NzaC1yc2EFAKEF44D3 user\n' FAKEF44D3
hc f44-ssh-ed25519 'ssh-ed25519 AAAAC3NzaFAKEF44D4 user\n' FAKEF44D4
hc f44-control-in-label 'tok\033en=FAKEF44E1\n' FAKEF44E1
hc f44-nul-in-label 'pass\001word=FAKEF44E2\n' FAKEF44E2
# F4-5 redact BEFORE truncate: a 32+ char blob starting before char 160 and straddling it must not leak its head
python3 -c 'print("w " * 68 + "A" * 10 + "FAKEF45STRADDLEBLOBCANARY" + "B" * 30)' >"$W/err.bin"
ck "F4-5 blob straddling char 160: head not visible (redact before truncate)" "$(hint | grep -c 'FAKEF45\|AAAAAAAAAA')" 0
python3 -c 'print("v " * 70 + "token=FAKEF45B" + "C" * 40)' >"$W/err.bin"
ck "F4-5 kv straddling char 160: value head not visible" "$(hint | grep -c 'FAKEF45B')" 0
python3 -c 'print("u " * 75 + "x" * 40)' >"$W/err.bin"
e="$(hint)"; ck "F4-5 straddling blob: output still bounded (<= 181)" "$([ ${#e} -le 181 ] && echo ok)" ok
# F4-6 INTENDED narrowing (R3-3 typed binding, ctl ruling 11-13 6:06 AM): an open row whose unit appears ONLY in free what/check text no longer rows an aside
echo '[{"ask_id":"A77","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"restart zzz-unit.service","check":"systemctl is-active zzz-unit.service"}]' >"$W/rows.json"
mk $'The zzz-unit.service item is a separate check, not investigated.\n'
ck "F4-6 narrowing (intended): unit only in what/check text, no key/scope, does NOT row the aside" "$(decision "$(asideenv ctl)")" block
echo '[{"ask_id":"A77","rev":1,"owner":"ctl","due":"2026-11-13T09:00","what":"restart zzz-unit.service","check":"systemctl is-active zzz-unit.service","key":"zzz-unit.service"}]' >"$W/rows.json"
ck "F4-6 same row with the typed key rows the aside" "$(decision "$(asideenv ctl)")" allow
echo "$ROW" >"$W/rows.json"
# --- rv5 repair 5 (F5-1, F5-2): escaped credential names + short JWT (bounded decoding), and linear-time redaction (cost bound by the patterns, not a timeout/cap)
# canaries are assembled at run time from pieces; each FAKE value contains FAKEF5
hc f51-pct-password-eq 'user%%3Dbob%%26password%%3DFAKEF51A1\n' FAKEF51A1
hc f51-pct-token-eq 'x token%%3DFAKEF51A2\n' FAKEF51A2
hc f51-pct-underscore-name 'GET /p?access%%5Ftoken=FAKEF51A3\n' FAKEF51A3
hc f51-pct-letters-in-name 'x %%70assword=FAKEF51A4\n' FAKEF51A4
hc f51-pct-colon 'api%%5Fkey%%3A FAKEF51A5\n' FAKEF51A5
hc f51-pct-double 'token%%253DFAKEF51A6\n' FAKEF51A6
hc f51-pct-triple 'password%%25253DFAKEF51A7\n' FAKEF51A7
hc f51-u-json-key '{"\\u0074oken":"FAKEF51B1"}\n' FAKEF51B1
hc f51-u-value 'password=\\u0041FAKEF51B2\n' FAKEF51B2
hc f51-u-name-sep 'secret\\u003dFAKEF51B3\n' FAKEF51B3
hc f51-u-upper 'x api\\u005Fkey: FAKEF51B4\n' FAKEF51B4
hc f51-x-escaped 'pass\\x77ord=FAKEF51B5\n' FAKEF51B5
hc f51-mixed-pct-u 'a\\u0070ass%%77ord=FAKEF51B6\n' FAKEF51B6
hc f51-nul-pct-in-label 'pass%%00word=FAKEF51B7\n' FAKEF51B7
hc f51-newline-pct-in-label 'pass%%0Aword=FAKEF51B8\n' FAKEF51B8
hc f51-deep-encoding-withheld 'password%%252525253DFAKEF51B9\n' FAKEF51B9
hc f51-short-jwt 'bad eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxFAKEF51C1.sig\n' FAKEF51C1
hc f51-short-jwt-nosig 'eyJhbGciOi.eyJzdWIiOiFAKEF51C2.\n' FAKEF51C2
hc f51-jwt-after-colon 'jwt:eyJhbGciOi.eyJzdWIiOiFAKEF51C3.xyz\n' FAKEF51C3
hc f51-pct-url-userinfo 'postgres://u:FAKEF51D1%%40x@h/db\n' FAKEF51D1
# own negatives, beyond the reviewer's list: encoded cookie pair, encoded Authorization header, hex-escaped bearer
hc f51-own-pct-cookie 'Set%%2DCookie: sid=FAKEF51E1\n' FAKEF51E1
hc f51-own-pct-bearer 'authorization%%3A%%20bearer%%20FAKEF51E2\n' FAKEF51E2
hc f51-own-u-bearer 'Authorization:\\u0020Bearer\\u0020FAKEF51E3\n' FAKEF51E3
# benign encoded text stays readable and bounded
e="$(printf 'wm-asks: path%%2Fto%%2Ffile not found (100%% sure)\n' >"$W/err.bin"; hint)"
ck "F5-1 benign percent text: still a readable hint" "$(case "$e" in *"path/to/file not found"*) echo ok;; esac)" ok
# F5-2: cost is bound by the patterns. Same host, in-process: each adversarial 20 KB line within 2x a normal 20 KB line (min of 3 runs each)
cat >"$W/patho.py" <<'PYEOF'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("fe", sys.argv[1] + "/.local/bin/followup-eval.py"); fe = importlib.util.module_from_spec(spec); spec.loader.exec_module(fe)
def best(t, n=3):
    r = []
    for _ in range(n):
        a = time.perf_counter(); fe.stderr_hint(t); r.append(time.perf_counter() - a)
    return min(r)
normal = ("wm-asks: ledger database is busy, retry the query later " * 400)[:20000]
shapes = {
    "key*7000": "key" * 7000,
    "pass_*4000": "pass_" * 4000,
    "?token*4000": "?" + "token" * 4000,
    "a@*": "a" * 20000,
    "ecdsa": "ecdsa-sha2-" * 1800,
    "eyJ*": "eyJ" * 6600,
    "pct": "%41" * 6600,
    "u-esc": "\\u0041" * 3300,
    "token-space": "token " * 3300,
    "password=*": "password=" * 2200,
    "&key*": "&key" * 5000,
    "cookie": "cookie " * 2800,
    "BEGIN": "-----BEGIN " * 1800,
    "dots": "a." * 10000,
    "ssh": "ssh-" * 5000,
}
tn = best(normal); worst = 0
for k, v in shapes.items():
    t = best(v[:20000]); worst = max(worst, t / tn)
    print("TIMING %s %.4f normal %.4f ratio %.2f" % (k, t, tn, t / tn))
print("WORST %.2f" % worst)
PYEOF
python3 -I "$W/patho.py" "$R" >"$W/patho.out" 2>&1; cat "$W/patho.out" | sed 's/^/  /' >>"${PATHO_LOG:-/dev/null}"
ck "F5-2 the 15 adversarial 20 KB shapes each finish within 2x the normal-line time" "$(awk '/^WORST/{print ($2<=2.0)?"ok":"slow " $2}' "$W/patho.out")" ok
echo "pass=$p fail=$f"; [ "$f" = 0 ]
