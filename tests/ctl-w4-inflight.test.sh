#!/usr/bin/env bash
# W4 crash/replay hardening (receipt ~/.cache/ctl-indep-w4crash/receipt1.md findings 1-3). Real ctl-event-route.sh + ctl-obligation-run.py + followup-eval.py +
# approval-check.sh + the REAL wm-asks against a SCRATCH ledger (WM_DECIDE_STATE / WM_DECIDE_LEDGER under a temp dir; the wrapper refuses to run without them).
# Scratch outbox, approvals record, RT_DIR; no model call (tripwire claude), no live ledger/outbox/approvals/unit/timer touched. Crashes are kill -9 of scratch pids.
#   c5   route pid only killed, runner + test alive: the rerun must NOT start a second test (in-flight, exit 75)
#   c5b  late orphan finisher must not replace the first completed receipt (rc -9 after rc 0): it goes to <key>.late.json
#   rev  replay branch re-reads the approvals record: a revoked or swapped approval does not finish the continuation
#   dup  a second event id for the same key opens no second continuation row
# BIN_DIR=<dir> runs the scripts from another tree (e.g. ~/.local/bin, the installed copy, for the RED run).
set -u
if [ -z "$(command -v wm-asks)" ]; then echo "SKIP tests/ctl-w4-inflight.test.sh: real wm-asks not installed on this host (carbon-only evidence; see receipt)"; exit 0; fi
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SRC="${BIN_DIR:-$here/.local/bin}"
T="$(mktemp -d)" && [ -n "$T" ] && [ -d "$T" ] && [ "$T" != / ] || { echo "FAIL scratch dir (mktemp/TMPDIR); refusing to run: no pkill/kill without an owned scratch dir" >&2; exit 2; }
trap 'case "$T" in /?*/?*) pkill -9 -f "$T/" 2>/dev/null; rm -rf "$T";; esac' EXIT
kill_pids() { local p; for p in "$@"; do case "$p" in ''|*[!0-9]*|0|1) continue;; esac; kill -9 "$p" 2>/dev/null; done; }
p=0; f=0
ck() { if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
B="$T/bin"; mkdir -p "$B" "$T/otests"
for x in ctl-event-route.sh ctl-obligation-run.py followup-eval.py approval-check.sh; do cp "$SRC/$x" "$B/$x"; done
REALWMA="$(command -v wm-asks)"
cat > "$B/wma" <<EOF
#!/usr/bin/env bash
# scratch wrapper around the real wm-asks; pauses after an \`add\` when $T/pause-rowadd exists (crash boundary: row recorded, nothing else done)
export WM_DECIDE_STATE="$T/wmstate" WM_DECIDE_LEDGER="$T/wmled.md"
mkdir -p "\$WM_DECIDE_STATE"
$REALWMA "\$@"; rc=\$?
if [ "\$2" = add ] && [ -e "$T/pause-rowadd" ]; then echo \$\$ > "$T/pause.pid"; touch "$T/at-rowadd"; for i in \$(seq 1 300); do [ -e "$T/pause-rowadd" ] || break; sleep 0.2; done; fi
exit \$rc
EOF
printf '#!/bin/sh\necho "CLAUDE INVOKED" >> %s/tripwire.log\nexit 1\n' "$T" > "$B/claude"
printf '#!/bin/sh\nexit 0\n' > "$B/seat-event"
cat > "$T/otests/zz-synth-w4.test.sh" <<EOF
#!/usr/bin/env bash
echo "start \$\$" >> "$T/exec.log"; echo \$\$ > "$T/test.pid"
while [ -e "$T/hold" ]; do sleep 0.2; done
[ -e "$T/slow" ] && sleep 6   # a grandchild that keeps the runner's pipe open after the test shell is killed
echo "end \$\$" >> "$T/exec.log"; exit 0
EOF
chmod +x "$B"/* "$T/otests"/*
export WM_SEAT=zzseat RT_CLAUDE_BIN="$B/claude" SEAT_EVENT_BIN="$B/seat-event" WM_ASKS_CMD="$B/wma" WM_ASKS_BIN="$B/wma" OBL_TESTS_DIR="$T/otests" T
unset CRASH_AT FOLLOWUP_DELIVER_CMD WM_DIRECTOR

setup() {   # <case>: fresh scratch state + one typed suggestion-only obligation + one valid approval #901
  C="$T/$1"; rm -rf "$C" "$T"/exec.log "$T"/hold "$T"/slow "$T"/pause-rowadd "$T"/at-* "$T/wmstate" "$T/wmled.md"; mkdir -p "$C/state"
  ID="zz-synthetic-$1"
  export FOLLOWUP_STATE_DIR="$C/state" FOLLOWUP_OUTBOX="$C/state/outbox.jsonl" RT_DIR="$C/rt" APPROVALS_FILE="$C/approvals.log"
  printf '#901 | 2026-11-09 3:00 AM PST | zz-synthetic | Joe: "approve" | re: obligation %s approved\n#902 | 2026-11-09 3:00 AM PST | zz-synthetic | Joe: "other" | re: obligation zz-synthetic-OTHER approved\n' "$ID" > "$APPROVALS_FILE"; chmod 600 "$APPROVALS_FILE"
  echo "we should run the named test x" | python3 -I "$B/followup-eval.py" suggestion --seat zzseat --id "$ID" --rev 1 --action '{"verb":"named-test","name":"zz-synth-w4"}' >/dev/null
  FP=$(python3 -I -c 'import json,hashlib,os;e=[json.loads(l) for l in open(os.environ["FOLLOWUP_OUTBOX"])][-1];print(hashlib.sha1(e["fp"].encode()).hexdigest()[:12])')
  OBK="$ID.1.$FP"; OD="$RT_DIR/obligations"
  mkq approved "#901"
}
mkq() {   # <tag> <approval> [eventtag]: queue file; the event id is zz-synthetic-ev-<eventtag or tag>
  local qid="zz-synthetic-ev-${3:-$1}"; QF="$C/q-$1.json"
  python3 -I -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"event":{"event":"inbox","detail":{"lines":["2026-11-09T03:00:00 | hermes | hermes 3:00 AM: APPROVED-OBLIGATION id=%s rev=1 fp=%s approval=%s"%(sys.argv[2],sys.argv[3],sys.argv[4])]}}}))' "$qid" "$ID" "$FP" "$2" > "$QF"
}
route_bg() { setsid bash -c "exec $B/ctl-event-route.sh route $1" >"$C/out.bg" 2>"$C/err.bg" </dev/null & RP=$!; }
route() { timeout "${TMO:-30}" "$B/ctl-event-route.sh" route "$1" >"$C/out.last" 2>"$C/err.last"; RC=$?; }
waitfor() { local i; for i in $(seq 1 150); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
starts() { grep -c '^start' "$T/exec.log" 2>/dev/null || echo 0; }
ends() { grep -c '^end' "$T/exec.log" 2>/dev/null || echo 0; }
rjrc() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["rc"])' "$1" 2>/dev/null || echo none; }
controws() { "$B/wma" asks query --json --status all --text "okey:$OBK" | python3 -I -c 'import json,sys;print(sum(1 for r in json.load(sys.stdin) if "authorized continuation of" in r["what"]))'; }
crash_at_rowadd() {   # <qf>: route pauses right after the real wm-asks add; kill route + wrapper (scratch pids)
  touch "$T/pause-rowadd"; route_bg "$1"; waitfor "$T/at-rowadd" || echo "NEVER REACHED rowadd"
  kill_pids "$RP" "$(cat "$T/pause.pid")"; wait "$RP" 2>/dev/null; rm -f "$T/pause-rowadd"
}

# ---- c5: route pid only killed mid-run; the runner and the test live on
setup c5; touch "$T/hold"
route_bg "$QF"; waitfor "$T/exec.log" || echo "NEVER STARTED"
kill_pids "$RP"; wait "$RP" 2>/dev/null
ck "c5 test started once before the kill" "$(starts)" 1
TMO=6 route "$QF"
ck "c5 rerun with a live owner exits 75 (retry later), not a failure" "$RC" 75
ck "c5 rerun did NOT start a second test" "$(starts)" 1
ck "c5 no receipt while the owner is live" "$([ -e "$OD/$OBK.run.json" ] && echo yes || echo no)" no
rm -f "$T/hold"; for i in $(seq 1 100); do [ -e "$OD/$OBK.run.json" ] && break; sleep 0.2; done
ck "c5 the live owner finishes and writes the one receipt (rc 0)" "$(rjrc "$OD/$OBK.run.json")" 0
route "$QF"
ck "c5 rerun after completion continues (rc 0)" "$RC" 0
ck "c5 still exactly one test execution" "$(starts)" 1
ck "c5 one continuation row" "$(controws)" 1

# ---- c5b: test shell killed, its sleep child keeps the runner blocked; then a lost marker lets a second run finish first
setup c5b; touch "$T/slow"
route_bg "$QF"; waitfor "$T/exec.log" || echo "NEVER STARTED"
kill_pids "$RP" "$(cat "$T/test.pid")"; wait "$RP" 2>/dev/null; rm -f "$T/slow"
TMO=10 route "$QF"
ck "c5b rerun with a live runner exits 75" "$RC" 75
ck "c5b rerun did NOT start a second test" "$(starts)" 1
rm -f "$OD/$OBK.inflight"   # isolate the receipt rule: a lost marker lets a second execution complete first
route "$QF"
ck "c5b second execution completes (rc 0 receipt)" "$(rjrc "$OD/$OBK.run.json")" 0
sleep 7   # the orphan runner's pipe closes now and it reports rc -9
ck "c5b first completed receipt wins: rc 0 not overwritten by the late rc -9" "$(rjrc "$OD/$OBK.run.json")" 0
ck "c5b the late orphan is recorded separately (rc -9)" "$(rjrc "$OD/$OBK.late.json")" -9
python3 -I "$B/ctl-obligation-run.py" check --dir "$OD" --key "$OBK"
ck "c5b ledger done-check still passes" "$?" 0

# ---- stale owner: dead pid, no live child, no receipt => UNKNOWN (rc 75, no takeover, no execution); a pid-reuse (ticks differ) marker reads dead the same way
setup stale
mkdir -p "$OD"; printf '{"pid": 999999, "ticks": 1, "boot": "x", "ts": "old"}\n' > "$OD/$OBK.inflight"
TMO=20 route "$QF"
ck "stale dead owner: rerun exits 75 (UNKNOWN), nothing runs" "$RC/$(starts)" 75/0
ck "stale dead owner: no takeover file, marker kept, no receipt" "$(ls "$OD"/"$OBK".stale-* 2>/dev/null | wc -l | tr -d ' ')/$([ -e "$OD/$OBK.inflight" ] && echo marker || echo clean)/$([ -e "$OD/$OBK.run.json" ] && echo receipt || echo none)" 0/marker/none

# ---- rev: the replay branch re-reads the approvals record
setup rev; crash_at_rowadd "$C/q-approved.json"
ck "rev crash left the row recorded, nothing resolved or run" "$(controws)/$(starts)/$(grep -c '"resolved"' "$FOLLOWUP_OUTBOX")" 1/0/0
mkq swapped "#999" approved   # same event id, line rewritten to an approval absent from the record
route "$C/q-swapped.json"
ck "rev same event with approval=#999: replay refused, nothing run" "$(starts)/$(grep -c refused-replay-approval "$C/out.last")" 0/1
rm -f "$RT_DIR"/routed/*.json
grep -v '^#901 ' "$APPROVALS_FILE" > "$C/a.tmp"; cat "$C/a.tmp" > "$APPROVALS_FILE"   # revoke #901
route "$C/q-approved.json"
ck "rev approval revoked between crash and replay: refused, nothing run" "$(starts)/$(grep -c refused-replay-approval "$C/out.last")/$(grep -c '"resolved"' "$FOLLOWUP_OUTBOX")" 0/1/0
rm -f "$RT_DIR"/routed/*.json
printf '#901 | 2026-11-09 3:00 AM PST | zz-synthetic | Joe: "approve" | re: obligation %s approved\n' "$ID" >> "$APPROVALS_FILE"
route "$C/q-approved.json"
ck "rev approval present again: the same replay completes once" "$RC/$(starts)/$(controws)" 0/1/1

# ---- dup: a second event id for the same key opens no second continuation row
setup dup; crash_at_rowadd "$C/q-approved.json"
mkq resend "#901"
route "$C/q-resend.json"
ck "dup resend under a new event id: still ONE continuation row" "$(controws)" 1
ck "dup resend ran the named test once" "$(starts)" 1
rm -f "$RT_DIR"/routed/*.json
route "$C/q-approved.json"
ck "dup original event replayed afterwards: no third row, no second run" "$(controws)/$(starts)" 1/1

# ---- conc: two DIFFERENT events for one key routed concurrently (barrier start, fresh key each iteration): exactly one continuation row, one runner start
for n in $(seq 1 ${CONC_N:-10}); do
  setup conc$n; mkq a "#901" evA; mkq b "#901" evB; rm -f "$T/go"
  for w in a b; do setsid bash -c "while [ ! -e $T/go ]; do :; done; exec timeout 60 $B/ctl-event-route.sh route $C/q-$w.json" >"$C/out.$w" 2>"$C/err.$w" </dev/null & eval "P$w=\$!"; done
  sleep 0.3; touch "$T/go"; wait "$Pa" "$Pb" 2>/dev/null
  ck "conc#$n one continuation row for two concurrent events" "$(controws)" 1
  ck "conc#$n runner started once" "$(starts)" 1
done

# ---- D2: an unreadable/empty/torn marker is UNKNOWN (75, retry later), never dead; two concurrent routes over a dead owner's marker both read UNKNOWN: zero executions
for kind in empty torn; do
  setup m$kind; touch "$T/hold"
  route_bg "$QF"; waitfor "$T/exec.log" || echo "NEVER STARTED"
  kill_pids "$RP"; wait "$RP" 2>/dev/null
  if [ $kind = empty ]; then : > "$OD/$OBK.inflight"; else printf '{' > "$OD/$OBK.inflight"; fi
  TMO=8 route "$QF"
  ck "d2 $kind marker with a live runner: rerun exits 75" "$RC" 75
  ck "d2 $kind marker with a live runner: one execution" "$(starts)" 1
  rm -f "$T/hold"; sleep 1
done
for n in $(seq 1 ${TAKE_N:-40}); do
  setup take$n; mkdir -p "$OD"; printf '{"pid": 999999, "ticks": 1, "boot": "x", "ts": "old"}\n' > "$OD/$OBK.inflight"
  rm -f "$T/go"
  for w in a b; do setsid bash -c "while [ ! -e $T/go ]; do :; done; exec timeout 60 $B/ctl-event-route.sh route $C/q-approved.json" >"$C/out.$w" 2>"$C/err.$w" </dev/null & eval "P$w=\$!"; done
  sleep 0.3; touch "$T/go"; wait "$Pa" "$Pb" 2>/dev/null
  ck "d2 take#$n no winner: zero executions" "$(starts)" 0
  ck "d2 take#$n no stale file, no late receipt, marker kept" "$(ls "$OD" | grep -c '\.stale-')/$(ls "$OD" | grep -c '\.late\.json')/$(ls "$OD" | grep -c '\.inflight$')" 0/0/1
done

# ---- D3: two concurrent writers of <key>.handled.json both succeed (unique tmp name per writer)
for n in $(seq 1 ${CONC_N:-10}); do
  setup hw$n; mkq a "#901" evA; mkq b "#901" evB; rm -f "$T/go"
  python3 -I "$B/ctl-obligation-run.py" run --dir "$OD" --key "$OBK" --approval "#901" --action '{"verb":"named-test","name":"zz-synth-w4"}' >/dev/null
  for w in a b; do setsid bash -c "while [ ! -e $T/go ]; do :; done; timeout 60 $B/ctl-event-route.sh route $C/q-$w.json; echo \$? > $C/rc.$w" >"$C/out.$w" 2>"$C/err.$w" </dev/null & eval "P$w=\$!"; done
  sleep 0.3; touch "$T/go"; wait "$Pa" "$Pb" 2>/dev/null
  ck "d3 writers#$n both rc 0" "$(cat "$C/rc.a" 2>/dev/null)/$(cat "$C/rc.b" 2>/dev/null)" 0/0
done

echo "pass=$p fail=$f"; [ "$f" = 0 ]
