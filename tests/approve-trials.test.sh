#!/usr/bin/env bash
# tests/approve-trials.test.sh: approve.sh trial rows (trials.json) under a throwaway HOME: the approval + trial flags, --trial-add/--trial-close/--trial-open/--trials,
# refusals (exit 2 bad input, 3 tmux seat, 4 malformed file) and the existing --selftest. Fakes only: a stub seat-event.sh (records args) and a stub tmux. Run: bash tests/approve-trials.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../.local/bin/approve.sh"
seeds="$here/fixtures/approve-trials-seeds.json"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/approve-trials-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/ev" "$T/.cache/tmp"
printf '#!/bin/bash\necho "src=${EVENT_SOURCE:-} $*" >>"%s/bell"\n' "$T" >"$T/bin/seat-event.sh"; chmod +x "$T/bin/seat-event.sh"
export HOME="$T" APPROVALS_FILE="$T/approvals.log" APPROVE_TRIALS="$T/trials.json" SEAT_EVENT_BIN="$T/bin/seat-event.sh" SEAT_EVENT_DRY=1 EVENTS_DIR="$T/ev"
export APPROVE_TRIAL_LOG_DIR="$T/trial-logs" WM_DECIDE_DB="$T/decisions.sqlite" WM_DECIDE_BIN="$T/bin/wm-decide-stub" APPROVE_NOW=2026-10-30T12:00:00-07:00
printf '#!/bin/bash\nprintf "%%s\\n" "$@" >>"%s/wmd.argv"; echo --END-- >>"%s/wmd.argv"\n[ -n "${STUB_OUT-d-20261030-000000-aide-test}" ] && printf "%%s\\n" "${STUB_OUT-d-20261030-000000-aide-test}"\nexit "${STUB_RC:-0}"\n' "$T" "$T" >"$T/bin/wm-decide-stub"; chmod +x "$T/bin/wm-decide-stub"
export PATH="$T/bin:$PATH"; unset TMUX TMUX_PANE WM_SEAT CLAUDE_SESSION_NAME   # the session name lands in the log line; the selftest expects the default 'aide'
A() { bash "$script" "$@"; }
rows() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$APPROVE_TRIALS"; }
field() { python3 -I -c 'import json,sys
r=[x for x in json.load(open(sys.argv[1])) if x["id"]==sys.argv[2]][0]; print(r.get(sys.argv[3],"<unset>"))' "$APPROVE_TRIALS" "$1" "$2"; }
nlog() { grep -cE '^#[0-9]+ \| ' "$APPROVALS_FILE" 2>/dev/null || echo 0; }
TR=(--trial-id t1 --trial-ends 2026-11-02T10:00:00-07:00 --signal 'corrected share' --revert 'undo it')

bash -n "$script" && pass "bash -n" || bad "bash -n"

# 1. approval + all four trial flags: one approval line, one open row
out=$(A 'go ahead with the trial' 're: test trial' "${TR[@]}" 2>&1); rc=$?
[ $rc = 0 ] && [ "$(nlog)" = 1 ] && [ "$(rows)" = 1 ] && pass "approval + trial: rc 0, 1 log line, 1 row" || bad "approval + trial rc=$rc log=$(nlog): $out"
[ "$(field t1 state)" = open ] && [ "$(field t1 approval)" = '#1' ] && [ "$(field t1 ends)" = 2026-11-02T10:00:00-07:00 ] && [[ "$(field t1 started)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}$ ]] \
  && pass "row: open, approval #1, ends kept, started ISO with offset ($(field t1 started))" || bad "row fields: $(cat "$APPROVE_TRIALS")"
[ "$(stat -c %a "$APPROVE_TRIALS")" = 600 ] && pass "trials.json mode 600" || bad "trials.json mode $(stat -c %a "$APPROVE_TRIALS")"
[ "$(grep -c 'APPROVAL #1 test trial' "$T/bell")" = 1 ] && pass "bell rang once (stub seat-event.sh)" || bad "bell: $(cat "$T/bell" 2>/dev/null)"

# 2. subset of the trial flags: exit 2, log and trials unchanged
cp "$APPROVALS_FILE" "$T/log.snap"; cp "$APPROVE_TRIALS" "$T/trials.snap"
for sub in '--trial-id t2' '--trial-id t2 --trial-ends 2026-11-02T10:00:00-07:00 --signal x' '--signal x --revert y' '--trial-ends 2026-11-02T10:00:00-07:00'; do
  # shellcheck disable=SC2086
  out=$(A 'q' 're: r' $sub 2>&1); rc=$?
  [ $rc = 2 ] && cmp -s "$APPROVALS_FILE" "$T/log.snap" && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "subset '$sub': exit 2, nothing written" || bad "subset '$sub': rc=$rc"
done
out=$(A 'q' 're: r' --trial-id t1 --trial-ends 2026-11-02T10:00:00-07:00 --signal x --revert y 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVALS_FILE" "$T/log.snap" && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "approval + duplicate trial id: exit 2, no approval line" || bad "duplicate via approval rc=$rc"
out=$(A 'q' 're: r' --trial-id t9 --trial-ends tomorrow --signal x --revert y 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVALS_FILE" "$T/log.snap" && pass "approval + unparseable ends: exit 2, no approval line" || bad "bad ends via approval rc=$rc"

# 3. --trial-add of the three seed rows matches seeds.json field-for-field
rm -f "$APPROVE_TRIALS"
add() { A --trial-add --trial-id "$1" --approval "$2" --started "$3" --trial-ends "$4" --signal "$5" --revert "$6" --state "$7" "${@:8}"; }
sig='corrected share over last 20 graded rows per seat from decisions.sqlite'
add seat-effort-medium-39 '#39' 2026-10-26T23:18:14-07:00 2026-10-28T00:00:00-07:00 "$sig" 'reverted by #82 2026-10-30T10:29:00-07:00' reverted --arms controller,rb,r7 >/dev/null 2>&1; r1=$?
add seat-effort-high-82 '#82' 2026-10-30T10:29:00-07:00 2026-10-31T10:29:00-07:00 "$sig" 'set CLAUDE_CODE_EFFORT_LEVEL medium in ~/.config/claude-seat/settings.json and ctl-settings.json (dotfiles PR)' open --arms controller,rb,r7 >/dev/null 2>&1; r2=$?
add fable-rb-83 '#83' '' '' 'rb corrected share over last 20 graded rows vs r7/ctl same window + rb token share vs r7 (token-ledger)' 'controller-model-required rb -> claude-opus-5-5 + seat-model-hold rb entry' pending --start-gate 'trials.json + alarm LIVE; ends = start + 48h' >/dev/null 2>&1; r3=$?
[ $r1$r2$r3 = 000 ] && pass "three seed rows added (rc 0 0 0)" || bad "seed add rc $r1 $r2 $r3"
out=$(A --trials 2>&1); rc=$?
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 3 ] && pass "--trials prints one row per line" || bad "--trials rc=$rc lines=$(printf '%s\n' "$out" | wc -l)"
if printf '%s\n' "$out" | python3 -I -c 'import json,sys
got=[json.loads(l) for l in sys.stdin if l.strip()]
want=json.load(open(sys.argv[1]))
for r in want:
    if r["id"]=="seat-effort-medium-39": r.pop("closes"); r.pop("closed")   # seed history: closes/closed are never settable from the CLI
sys.exit(0 if got==want else 1)' "$seeds"; then pass "--trials == fixtures/approve-trials-seeds.json, field-for-field"; else bad "--trials differs from the seeds"; fi
python3 -I -c 'import json,sys
want=json.load(open(sys.argv[2]))
for r in want:
    if r["id"]=="seat-effort-medium-39": r.pop("closes"); r.pop("closed")   # seed history, as above
sys.exit(0 if json.load(open(sys.argv[1]))==want else 1)' "$APPROVE_TRIALS" "$seeds" && pass "trials.json == seeds fixture (39 minus closes/closed)" || bad "trials.json differs from the seeds"

# 4. duplicate id, empty ends on open, bad state
out=$(add seat-effort-high-82 '#82' 2026-10-30T10:29:00-07:00 2026-10-31T10:29:00-07:00 s r open 2>&1); rc=$?
[ $rc = 2 ] && [ "$(rows)" = 3 ] && pass "--trial-add duplicate id: exit 2" || bad "duplicate id rc=$rc rows=$(rows)"
out=$(add open-empty '#5' 2026-10-30T10:29:00-07:00 '' s r open 2>&1); rc=$?
[ $rc = 2 ] && [ "$(rows)" = 3 ] && pass "--trial-add --state open with empty ends: exit 2" || bad "open empty ends rc=$rc"
out=$(add bad-state '#5' 2026-10-30T10:29:00-07:00 2026-10-31T10:29:00-07:00 s r maybe 2>&1); rc=$?
[ $rc = 2 ] && [ "$(rows)" = 3 ] && pass "--trial-add bad state: exit 2" || bad "bad state rc=$rc"

# 5. --trial-close
cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-close seat-effort-high-82 keep 2>&1); rc=$?   # no decisions db yet: zero graded rows per arm
[ $rc = 5 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && [ "$(field seat-effort-high-82 state)" = open ] && pass "--trial-close keep with no graded rows: exit 5, state still open" || bad "close keep unmeasured rc=$rc: $out"
out=$(A --trial-close fable-rb-83 open 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "--trial-close <id> open: exit 2, nothing written" || bad "close open rc=$rc"
out=$(A --trial-close no-such-id kept 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "--trial-close unknown id: exit 2" || bad "close unknown rc=$rc"

# 5b. close rule: Fable-graded rows per arm, verdict keep|revert|unmeasured|extend, one wm-decide plan row per close (fakes: sqlite db via python3, stub wm-decide)
mkdb() { # mkdb <graded ctl> <graded rb> <graded r7> [noise]: 20 in-window rows per arm, the first N of each Fable-graded; noise = rows that must not count
  rm -f "$WM_DECIDE_DB"
  python3 -I -c 'import sqlite3,sys,json
db,*g=sys.argv[1:]; noise=g[-1]=="noise"; g=[int(x) for x in g[:3]]
con=sqlite3.connect(db); con.execute("create table decisions (id text, ts text, agent text, kind text, tags text, regrade text)")
ok=json.dumps({"by":"fable-regrader","verdict":"CONFIRM"}); n=0
def add(ts,agent,tags,rg):
    global n; n+=1; con.execute("insert into decisions values (?,?,?,?,?,?)",("d-%d"%n,ts,agent,"plan",json.dumps(tags),rg))
for a,k in zip(("controller","rb","r7"),g):
    for i in range(20): add("2026-10-27T0%d:%02d:00-07:00"%(i%9,i), a, [], ok if i<k else None)
if noise:
    add("2026-10-27T10:00:00-07:00","controller",[],json.dumps({"by":"auto-resolve","verdict":"CONFIRM"}))
    add("2026-10-27T10:01:00-07:00","controller",[],json.dumps({"by":"fable-regrader","verdict":"UNGRADED"}))
    add("2026-10-27T10:02:00-07:00","controller",["test"],ok)
    add("2026-10-27T10:03:00-07:00","controller",["legacy","x"],ok)
    add("2026-10-25T23:00:00-07:00","controller",[],ok)
    add("2026-10-29T00:00:01-07:00","controller",[],ok)
con.commit()' "$WM_DECIDE_DB" "$@"
}
mkt() { # mkt <revert cmd> [state] [arms json]: trials.json = open row tc (window 10-26..10-29 -07:00) + the pending seed 83
  REV="$1" ST="${2:-open}" ARMS="${3:-[\"controller\",\"rb\",\"r7\"]}" python3 -I -c 'import json,os,sys
row={"id":"tc","approval":"#90","started":"2026-10-26T00:00:00-07:00","ends":"2026-10-29T00:00:00-07:00","signal":"s","revert":os.environ["REV"],"state":os.environ["ST"],"arms":json.loads(os.environ["ARMS"])}
json.dump([row]+[r for r in json.load(open(sys.argv[2])) if r["id"]=="fable-rb-83"],open(sys.argv[1],"w"))' "$APPROVE_TRIALS" "$seeds"
}
pj() { python3 -I -c 'import json,sys
r=[x for x in json.load(open(sys.argv[1])) if x["id"]==sys.argv[2]][0]; print(eval(sys.argv[3]))' "$APPROVE_TRIALS" "$1" "$2"; }
stubn() { [ -e "$T/wmd.argv" ] || { echo 0; return; }; awk '/^--END--$/{n++} END{print n+0}' "$T/wmd.argv"; }
lastcall() { awk 'BEGIN{RS="--END--\n"} {last=$0} END{printf "%s", last}' "$T/wmd.argv"; }
argpair() { lastcall | awk -v f="$1" -v v="$2" 'prev==f && $0==v {found=1} {prev=$0} END{exit !found}'; }
reset() { rm -f "$T/wmd.argv" "$T/reverted" "$T/r2"; rm -rf "$T/trial-logs"; unset STUB_RC STUB_OUT; }

# 8ca0 replay: 60 rows in the window, Fable-graded 0/0/2 -> keep refused, nothing written, stub not called
reset; mkdb 0 0 2; mkt true; cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-close tc keep 2>&1); rc=$?
[ $rc = 5 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && [ "$(stubn)" = 0 ] && [ "$(field tc state)" = open ] && pass "8ca0 replay (0/0/2 graded): keep exit 5, state open, stub not called, bytes unchanged" || bad "8ca0 replay rc=$rc: $out"
[ "$(printf '%s\n' "$out" | grep -c '^arm ')" = 3 ] && printf '%s\n' "$out" | grep -qx 'arm r7: 2/20 Fable-graded of 20 rows in 2026-10-26T00:00:00-07:00..2026-10-29T00:00:00-07:00' \
  && [ "$(printf '%s\n' "$out" | tail -n1)" = "not measured: only 'unmeasured' (runs the revert) or 'extend' (once)" ] && pass "refusal: one line per arm + the closing line" || bad "refusal text: $out"
out=$(A --trial-close tc revert 2>&1); rc=$?
[ $rc = 5 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && [ "$(stubn)" = 0 ] && pass "revert on the same counts: exit 5, nothing written" || bad "revert unmeasured rc=$rc"
mkt true open '[]'; cp "$APPROVE_TRIALS" "$T/trials.snap"; mkdb 20 20 20
out=$(A --trial-close tc keep 2>&1); rc=$?
[ $rc = 5 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "a trial with no arms is never measured: keep exit 5" || bad "no-arms keep rc=$rc: $out"

# 20/20/20 -> keep ok, one plan row
reset; mkdb 20 20 20; mkt true
out=$(A --trial-close tc keep 2>&1); rc=$?
[ $rc = 0 ] && [ "$(field tc state)" = kept ] && [ "$(stubn)" = 1 ] && argpair --kind plan && argpair --tag trial:tc && grep -qx -- '--reverse-text' "$T/wmd.argv" && ! grep -qx -- '--target' "$T/wmd.argv" \
  && pass "20/20/20: keep exit 0, state kept, one stub call with --kind plan --tag trial:tc --reverse-text and no --target" || bad "keep 20/20/20 rc=$rc: $out"
[ "$(pj tc 'len(r["closes"])')" = 1 ] && [ "$(pj tc 'r["closes"][0]["measured"]')" = True ] && [ "$(pj tc 'r["closes"][0]["row"]')" = d-20261030-000000-aide-test ] && [ "$(pj tc 'r["closes"][0]["counts"]["rb"]["graded"]')" = 20 ] \
  && [[ "$(field tc closed)" == 2026-10-30T12:00:00-07:00 ]] && pass "closes: one entry, measured true, row id, per-arm counts; closed=APPROVE_NOW" || bad "closes: $(field tc closes)"
for kw in --agent --via --what --why --evidence; do grep -qx -- "$kw" "$T/wmd.argv" || bad "stub argv missing $kw"; done
reset; mkdb 20 20 20 noise; mkt true
out=$(A --trial-close tc keep 2>&1); rc=$?
[ $rc = 0 ] && pass "20 valid graded + noise rows: keep exit 0" || bad "keep with noise rc=$rc: $out"

# rows that must not count: auto-resolve, UNGRADED, tag test, tag legacy, before started, after ends
reset; mkdb 19 20 20 noise; mkt true; cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-close tc keep 2>&1); rc=$?
[ $rc = 5 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && [ "$(stubn)" = 0 ] && printf '%s\n' "$out" | grep -q '^arm controller: 19/20 Fable-graded of 24 rows in ' \
  && pass "19 graded + auto-resolve/UNGRADED/test/legacy/before-start/after-end rows: keep refused (19/20 of 24 rows)" || bad "noise rc=$rc: $out"

# unmeasured runs the revert whatever the counts
reset; mkdb 0 0 2; mkt "touch $T/reverted"
out=$(A --trial-close tc unmeasured 2>&1); rc=$?
[ $rc = 0 ] && [ -e "$T/reverted" ] && [ "$(field tc state)" = reverted-unmeasured ] && [ "$(stubn)" = 1 ] && [ "$(pj tc 'r["closes"][-1]["measured"]')" = False ] && [ "$(ls "$T/trial-logs" | grep -c '^tc\.')" = 1 ] \
  && pass "unmeasured: revert ran, state reverted-unmeasured, one row, revert log written" || bad "unmeasured rc=$rc: $out"
reset; mkdb 0 0 2; mkt false; cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-close tc unmeasured 2>&1); rc=$?
[ $rc = 6 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && [ "$(stubn)" = 0 ] && pass "failing revert command: exit 6, state open, stub not called" || bad "failing revert rc=$rc: $out"
reset; mkdb 20 20 20; mkt "touch $T/reverted"
out=$(A --trial-close tc revert 2>&1); rc=$?
[ $rc = 0 ] && [ -e "$T/reverted" ] && [ "$(field tc state)" = reverted ] && [ "$(stubn)" = 1 ] && [ "$(pj tc 'r["closes"][-1]["verdict"]')" = revert ] && pass "measured revert: revert ran, state reverted, one row" || bad "revert rc=$rc: $out"

# extend: once, later ends only, never kept
reset; mkdb 0 0 2; mkt true
out=$(A --trial-close tc extend --trial-ends 2026-11-02T00:00:00-07:00 2>&1); rc=$?
[ $rc = 0 ] && [ "$(field tc ends)" = 2026-11-02T00:00:00-07:00 ] && [ "$(field tc extended)" = 1 ] && [ "$(field tc state)" = open ] && [ "$(stubn)" = 1 ] && grep -qx 'set ends back to 2026-10-29T00:00:00-07:00' "$T/wmd.argv" \
  && pass "extend once: ends moved, extended 1, state open, one row" || bad "extend rc=$rc: $out"
cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-close tc extend --trial-ends 2026-11-05T00:00:00-07:00 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && [ "$(stubn)" = 1 ] && pass "second extend: exit 2, nothing written" || bad "second extend rc=$rc"
mkt true; cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-close tc extend 2>&1); rc1=$?
out=$(A --trial-close tc extend --trial-ends 2026-10-29T00:00:00-07:00 2>&1); rc2=$?
out=$(A --trial-close tc extend --trial-ends 2026-10-28T00:00:00-07:00 2>&1); rc3=$?
out=$(A --trial-close tc keep --trial-ends 2026-11-05T00:00:00-07:00 2>&1); rc4=$?
[ "$rc1$rc2$rc3$rc4" = 2222 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "extend without ends / with equal / earlier ends, and --trial-ends on keep: exit 2, nothing written" || bad "extend refusals rc $rc1 $rc2 $rc3 $rc4"

# re-close of a closed row, and every verb on a pending row
reset; mkdb 20 20 20; mkt true
A --trial-close tc keep >/dev/null 2>&1; rm -f "$T/wmd.argv"; cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-close tc keep 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && [ "$(stubn)" = 0 ] && printf '%s' "$out" | grep -q 'is kept' && pass "re-close of a kept row: exit 2 naming the state, stub not called" || bad "re-close kept rc=$rc: $out"
reset; mkdb 0 0 0; mkt true
A --trial-close tc unmeasured >/dev/null 2>&1; rm -f "$T/wmd.argv"; cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-close tc unmeasured 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && [ "$(stubn)" = 0 ] && pass "re-close of a reverted-unmeasured row: exit 2, stub not called" || bad "re-close unmeasured rc=$rc: $out"
reset; mkdb 20 20 20; mkt true; cp "$APPROVE_TRIALS" "$T/trials.snap"
for v in keep revert unmeasured extend; do
  if [ "$v" = extend ]; then out=$(A --trial-close fable-rb-83 $v --trial-ends 2026-11-05T00:00:00-07:00 2>&1); rc=$?
  else out=$(A --trial-close fable-rb-83 $v 2>&1); rc=$?; fi
  [ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && [ "$(stubn)" = 0 ] && printf '%s' "$out" | grep -q 'open it first (--trial-open)' && pass "pending seed + $v: exit 2 'open it first', bytes unchanged" || bad "pending $v rc=$rc: $out"
done

# --trial-open needs arms
mkt true; cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-open fable-rb-83 --trial-ends 2026-11-01T12:00:00-07:00 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "--trial-open with no arms anywhere: exit 2, nothing written" || bad "open no arms rc=$rc: $out"
out=$(A --trial-open fable-rb-83 --trial-ends 2026-11-01T12:00:00-07:00 --arms rb 2>&1); rc=$?
[ $rc = 0 ] && [ "$(field fable-rb-83 state)" = open ] && [ "$(pj fable-rb-83 'r["arms"]')" = "['rb']" ] && pass "--trial-open --arms rb: opens with arms [rb]" || bad "open --arms rc=$rc: $out"
mkt true; python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); [r.update(arms=["controller","rb"]) for r in d if r["id"]=="fable-rb-83"]; json.dump(d,open(sys.argv[1],"w"))' "$APPROVE_TRIALS"
out=$(A --trial-open fable-rb-83 --trial-ends 2026-11-01T12:00:00-07:00 2>&1); rc=$?
[ $rc = 0 ] && [ "$(pj fable-rb-83 'r["arms"]')" = "['controller', 'rb']" ] && pass "--trial-open on a row with stored arms: opens without the flag" || bad "open stored arms rc=$rc: $out"

# wm-decide failures
reset; mkdb 20 20 20; mkt true; cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(STUB_RC=1 A --trial-close tc keep 2>&1); rc=$?
[ $rc = 7 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "stub exits 1 on keep: exit 7, state unchanged" || bad "stub fail keep rc=$rc: $out"
out=$(STUB_OUT= A --trial-close tc keep 2>&1); rc=$?
[ $rc = 7 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "stub exits 0 printing nothing: exit 7, state unchanged" || bad "stub empty rc=$rc: $out"
out=$(STUB_OUT=not-an-id A --trial-close tc keep 2>&1); rc=$?
[ $rc = 7 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "stub prints a non-id: exit 7, state unchanged" || bad "stub bad id rc=$rc: $out"
reset; mkdb 0 0 0; mkt "touch $T/r2"
out=$(STUB_RC=1 A --trial-close tc unmeasured 2>&1); rc=$?
[ $rc = 7 ] && [ -e "$T/r2" ] && [ "$(field tc state)" = reverted-unmeasured ] && [ "$(pj tc 'r["closes"][-1]["unrecorded"]')" = True ] && [ "$(pj tc 'r["closes"][-1]["row"]')" = None ] && printf '%s' "$out" | grep -q 'revert applied, wm-decide row NOT recorded' \
  && pass "stub fails after the revert ran: state saved reverted-unmeasured, closes[-1].unrecorded, exit 7" || bad "stub fail unmeasured rc=$rc: $out"
reset

# 6. --trial-open: pending only
cat "$seeds" > "$T/seeds.copy"; python3 -I -c 'import json,sys; json.dump(json.load(open(sys.argv[1])),open(sys.argv[2],"w"))' "$seeds" "$APPROVE_TRIALS"
out=$(A --trial-open fable-rb-83 --trial-ends 2026-11-01T12:00:00-07:00 --arms rb 2>&1); rc=$?   # 83 has no stored arms: --arms is now required
[ $rc = 0 ] && [ "$(field fable-rb-83 state)" = open ] && [ "$(field fable-rb-83 ends)" = 2026-11-01T12:00:00-07:00 ] && [[ "$(field fable-rb-83 started)" =~ ^20[0-9]{2}-.*[+-][0-9]{2}:[0-9]{2}$ ]] && pass "--trial-open pending: open, started=$(field fable-rb-83 started), ends set" || bad "open pending rc=$rc: $out"
cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-open seat-effort-high-82 --trial-ends 2026-11-01T12:00:00-07:00 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "--trial-open on an open row: exit 2, nothing written" || bad "open on open rc=$rc"
python3 -I -c 'import json,sys; json.dump(json.load(open(sys.argv[1])),open(sys.argv[2],"w"))' "$seeds" "$APPROVE_TRIALS"; cp "$APPROVE_TRIALS" "$T/trials.snap"
for e in '' ; do out=$(A --trial-open fable-rb-83 2>&1); rc=$?; [ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "--trial-open without --trial-ends: exit 2" || bad "open no ends rc=$rc"; done
out=$(A --trial-open fable-rb-83 --trial-ends soon 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "--trial-open unparseable ends: exit 2, row still pending" || bad "open bad ends rc=$rc"

# 7. malformed trials.json: exit 4, bytes unchanged, for every writer and the reader
printf '{"not": "an array"' > "$APPROVE_TRIALS"; cp "$APPROVE_TRIALS" "$T/mal.snap"; cp "$APPROVALS_FILE" "$T/log.snap"
MAL=("--trials" "--trial-close x kept" "--trial-open x --trial-ends 2026-11-01T12:00:00-07:00")
for cmd in "${MAL[@]}"; do
  # shellcheck disable=SC2086
  out=$(A $cmd 2>&1); rc=$?
  [ $rc = 4 ] && cmp -s "$APPROVE_TRIALS" "$T/mal.snap" && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && pass "malformed + '$cmd': exit 4, one stderr line, bytes unchanged" || bad "malformed '$cmd' rc=$rc out=$out"
done
out=$(A --trial-add --trial-id n --approval '#1' --started '' --trial-ends '' --signal s --revert r --state pending 2>&1); rc=$?
[ $rc = 4 ] && cmp -s "$APPROVE_TRIALS" "$T/mal.snap" && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && pass "malformed + --trial-add: exit 4, one stderr line, bytes unchanged" || bad "malformed add rc=$rc out=$out"
out=$(A 'q' 're: r' "${TR[@]}" 2>&1); rc=$?
[ $rc = 4 ] && cmp -s "$APPROVE_TRIALS" "$T/mal.snap" && cmp -s "$APPROVALS_FILE" "$T/log.snap" && pass "malformed + approval with trial flags: exit 4, no approval line written" || bad "malformed via approval rc=$rc"

# 8. tmux refusal still exits 3 (the script reads the seat with: tmux display-message -p '#S')
printf '#!/bin/sh\n[ "$1" = display-message ] && echo rb\n' >"$T/bin/tmux"; chmod +x "$T/bin/tmux"
python3 -I -c 'import json,sys; json.dump(json.load(open(sys.argv[1])),open(sys.argv[2],"w"))' "$seeds" "$APPROVE_TRIALS"; cp "$APPROVE_TRIALS" "$T/trials.snap"; cp "$APPROVALS_FILE" "$T/log.snap"
for cmd in '--trials' '--trial-close fable-rb-83 kept' '--trial-open fable-rb-83 --trial-ends 2026-11-01T12:00:00-07:00'; do
  # shellcheck disable=SC2086
  out=$(TMUX=stub A $cmd 2>&1); rc=$?
  [ $rc = 3 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "tmux seat rb + '$cmd': exit 3" || bad "tmux '$cmd' rc=$rc"
done
out=$(TMUX=stub A 'q' 're: r' --trial-id tt --trial-ends 2026-11-02T10:00:00-07:00 --signal s --revert r 2>&1); rc=$?
[ $rc = 3 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && cmp -s "$APPROVALS_FILE" "$T/log.snap" && pass "tmux seat rb + approval with trial flags: exit 3, nothing written" || bad "tmux approval rc=$rc"
out=$(TMUX=stub A --trial-add --trial-id z --approval '#1' --started '' --trial-ends '' --signal s --revert r --state pending 2>&1); rc=$?
[ $rc = 3 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "tmux seat rb + --trial-add: exit 3" || bad "tmux add rc=$rc"
rm -f "$T/bin/tmux"

# 9. the existing selftest still passes
out=$(bash "$script" --selftest 2>&1); rc=$?
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | tail -n1)" = "SELFTEST PASS" ] && ! printf '%s\n' "$out" | grep -q '^FAIL' && pass "--selftest rc 0 ($(printf '%s\n' "$out" | grep -c '^PASS') cases)" || { bad "--selftest rc=$rc"; printf '%s\n' "$out" | grep -v '^PASS' | tail -n 10; }

[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
