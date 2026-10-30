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
export PATH="$T/bin:$PATH"; unset TMUX TMUX_PANE CLAUDE_SESSION_NAME   # the session name lands in the log line; the selftest expects the default 'aide'
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
add seat-effort-medium-39 '#39' 2026-10-25T00:00:00-07:00 2026-10-28T00:00:00-07:00 "$sig" 'reverted by #82 2026-10-30T10:29:00-07:00' reverted >/dev/null 2>&1; r1=$?
add seat-effort-high-82 '#82' 2026-10-30T10:29:00-07:00 2026-10-31T10:29:00-07:00 "$sig" 'set CLAUDE_CODE_EFFORT_LEVEL medium in ~/.config/claude-seat/settings.json and ctl-settings.json (dotfiles PR)' open >/dev/null 2>&1; r2=$?
add fable-rb-83 '#83' '' '' 'rb corrected share over last 20 graded rows vs r7/ctl same window + rb token share vs r7 (token-ledger)' 'controller-model-required rb -> claude-opus-5-5 + seat-model-hold rb entry' pending --start-gate 'trials.json + alarm LIVE; ends = start + 48h' >/dev/null 2>&1; r3=$?
[ $r1$r2$r3 = 000 ] && pass "three seed rows added (rc 0 0 0)" || bad "seed add rc $r1 $r2 $r3"
out=$(A --trials 2>&1); rc=$?
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 3 ] && pass "--trials prints one row per line" || bad "--trials rc=$rc lines=$(printf '%s\n' "$out" | wc -l)"
if printf '%s\n' "$out" | python3 -I -c 'import json,sys
got=[json.loads(l) for l in sys.stdin if l.strip()]
want=json.load(open(sys.argv[1]))
sys.exit(0 if got==want else 1)' "$seeds"; then pass "--trials == fixtures/approve-trials-seeds.json, field-for-field"; else bad "--trials differs from the seeds"; fi
python3 -I -c 'import json,sys
sys.exit(0 if json.load(open(sys.argv[1]))==json.load(open(sys.argv[2])) else 1)' "$APPROVE_TRIALS" "$seeds" && pass "trials.json == seeds fixture" || bad "trials.json differs from the seeds"

# 4. duplicate id, empty ends on open, bad state
out=$(add seat-effort-high-82 '#82' 2026-10-30T10:29:00-07:00 2026-10-31T10:29:00-07:00 s r open 2>&1); rc=$?
[ $rc = 2 ] && [ "$(rows)" = 3 ] && pass "--trial-add duplicate id: exit 2" || bad "duplicate id rc=$rc rows=$(rows)"
out=$(add open-empty '#5' 2026-10-30T10:29:00-07:00 '' s r open 2>&1); rc=$?
[ $rc = 2 ] && [ "$(rows)" = 3 ] && pass "--trial-add --state open with empty ends: exit 2" || bad "open empty ends rc=$rc"
out=$(add bad-state '#5' 2026-10-30T10:29:00-07:00 2026-10-31T10:29:00-07:00 s r maybe 2>&1); rc=$?
[ $rc = 2 ] && [ "$(rows)" = 3 ] && pass "--trial-add bad state: exit 2" || bad "bad state rc=$rc"

# 5. --trial-close
out=$(A --trial-close seat-effort-high-82 kept 2>&1); rc=$?
[ $rc = 0 ] && [ "$(field seat-effort-high-82 state)" = kept ] && [[ "$(field seat-effort-high-82 closed)" =~ ^20[0-9]{2}-.*[+-][0-9]{2}:[0-9]{2}$ ]] && pass "--trial-close kept: state kept, closed=$(field seat-effort-high-82 closed)" || bad "close kept rc=$rc: $out"
cp "$APPROVE_TRIALS" "$T/trials.snap"
out=$(A --trial-close fable-rb-83 open 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "--trial-close <id> open: exit 2, nothing written" || bad "close open rc=$rc"
out=$(A --trial-close no-such-id kept 2>&1); rc=$?
[ $rc = 2 ] && cmp -s "$APPROVE_TRIALS" "$T/trials.snap" && pass "--trial-close unknown id: exit 2" || bad "close unknown rc=$rc"

# 6. --trial-open: pending only
cat "$seeds" > "$T/seeds.copy"; python3 -I -c 'import json,sys; json.dump(json.load(open(sys.argv[1])),open(sys.argv[2],"w"))' "$seeds" "$APPROVE_TRIALS"
out=$(A --trial-open fable-rb-83 --trial-ends 2026-11-01T12:00:00-07:00 2>&1); rc=$?
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
