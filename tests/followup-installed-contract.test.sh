#!/usr/bin/env bash
# followup-installed-contract (ledger ask A1307, G5 option a): the evaluator / Stop-hook contract the carbon install (A1296 pkg2 716f4654 + the 11-14
# replay repair) already depends on, pinned in source so a main-lineage evaluator cannot silently replace it:
#   - owed-now.sh hook calls `followup-eval.py suggestion --nowait ...` (2>/dev/null): rc 0 on a clean message, never an argparse error (rc 2);
#   - --nowait never waits and never writes: a busy store gives new {"locked":true}, suggestion/emit/replay exit 75 with the store unchanged;
#   - followup-stop-nowait.sh fu_stop_new: a busy store passes the Stop with a .stoplock marker; an evaluator failure keeps the marker with `evalfail <code>`;
#   - ops is an alias of ctl; a failed ledger read is reported with a redacted stderr hint (no secret text), never as "none owed";
#   - new appends all new obligations in one write; a repeated Stop on the unchanged ledger is silent.
#   - the timer consumer followup-outbox-replay.sh (installed 0b0a91c1) replays the outbox AND then refreshes each seats.tsv seat's owed-now
#     prompt-context cache (owed-now.sh refresh --seat S -> $OWED_NOW_STATE/<seat>.ups-cache.json); a failing refresh never fails the replay (exit 0).
# Fake wm-asks / wm-decide, private HOME and state dir; no ledger, no network, no credential files read (the "secrets" are literal fixture text).
# FU_TREE=<dir> runs the same checks against another tree (RED on a8b910d, the H2 replay head without the pkg2 layer).
# shellcheck disable=SC2319  # r=$? after a [ ] condition is the intended capture (messages may run command substitutions)
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; T="${FU_TREE:-$here}"
EV="$T/.local/bin/followup-eval.py"; LIB="$T/.claude/hooks/followup-lib.sh"; NW="$T/.claude/hooks/followup-stop-nowait.sh"; OWED="$T/.claude/hooks/owed-now.sh"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-installed-contract.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
cat >"$base/wm-asks" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = asks ] && [ "${2:-}" = query ] || exit 2
if [ -n "${FU_ASKS_FAIL:-}" ]; then printf '%s\n' "${FU_ASKS_STDERR:-}" >&2; exit "$FU_ASKS_FAIL"; fi
[ -n "${FU_ASKS_GARBAGE:-}" ] && { echo 'not json'; exit 0; }
cat "$FU_ASKS"
FAKE
printf '%s\n' '#!/usr/bin/env bash' "echo '{\"owed\":0,\"ids\":[]}'" >"$base/wm-decide"
printf '#!/usr/bin/env bash\nexit 1\n' >"$base/alive"
chmod +x "$base/wm-asks" "$base/wm-decide" "$base/alive"
export PATH="$base:/usr/local/bin:/usr/bin:/bin" HOME="$base/home" WM_ASKS_BIN="$base/wm-asks" WM_DECIDE_BIN="$base/wm-decide" FU_ASKS="$base/asks.json"
export FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_OUTBOX="$base/state/outbox.jsonl" FOLLOWUP_WORKER_ALIVE_CMD="$base/alive" FOLLOWUP_NOW="2026-11-08T12:00"
export OWED_NOW_STATE="$base/owed-state" SEATS_TABLE="$base/none.tsv" FOLLOWUP_EVAL="$EV"
unset WM_DIRECTOR TMUX FOLLOWUP_DELIVER_CMD; export WM_SEAT=ctl
mkdir -p "$HOME" "$FOLLOWUP_STATE_DIR"
row() { jq -nc --arg id "$1" --arg o "${2:-ctl}" '{ask_id:$id,owner:$o,rev:1,due:"2026-11-07T10:00",status:"open",claim:null,waits_on:[],what:"w"}'; }
{ row R1; row R2; row R3; } | jq -sc . >"$FU_ASKS"
store() { cat "$FOLLOWUP_STATE_DIR"/outbox.jsonl "$FOLLOWUP_STATE_DIR"/fingerprints.json 2>/dev/null | sha256sum; }
hold() { ( exec 9>"$FOLLOWUP_STATE_DIR/lock"; flock 9; touch "$base/held"; sleep "${1:-4}" ) & HP=$!; for _ in $(seq 50); do [ -e "$base/held" ] && break; sleep 0.1; done; }
release() { kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; rm -f "$base/held"; }

# 1. the exact installed owed-now.sh call shape (owed-now.sh hook: `suggestion --nowait --seat --id --rev`, stdin = final message)
printf 'stop message' | python3 -I "$EV" suggestion --nowait --seat ctl --id stop-s1 --rev 1 >"$base/o1" 2>"$base/e1"; rc=$?
[ "$rc" = 0 ] && jq -e '.flagged==false' "$base/o1" >/dev/null 2>&1; r=$?; chk "1: owed-now's 'suggestion --nowait' on a clean message: rc 0 flagged=false (rc=$rc $(head -c 80 "$base/e1"))" "$r"
grep -q -- '--nowait' "$OWED" 2>/dev/null && grep -q 'suggestion --nowait' "$OWED"; r=$?; chk "1: the tree's owed-now.sh is the caller of that shape (contract pinned on both sides)" "$r"

# 2. --nowait with the store lock held: never waits, never writes
hold 6; before="$(store)"
s=$(date +%s%N); printf 'you should fix the timer' | python3 -I "$EV" suggestion --nowait --seat ctl --id stop-s2 --rev 1 >/dev/null 2>&1; rc=$?; ms=$(( ($(date +%s%N) - s) / 1000000 ))
[ "$rc" = 75 ] && [ "$ms" -lt 3000 ] && [ "$(store)" = "$before" ]; r=$?; chk "2: flagged suggestion --nowait under a held lock: exit 75 in ${ms} ms, store unchanged (rc=$rc)" "$r"
o="$(python3 -I "$EV" new --nowait --seat ctl 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && jq -e '.locked==true and .new==[]' <<<"$o" >/dev/null 2>&1 && [ "$(store)" = "$before" ]; r=$?; chk "2: new --nowait under a held lock: {locked:true,new:[]} rc 0, store unchanged" "$r"
printf '{"id":"E1","rev":1,"kind":"probe","fp":"E1|1|probe","seat":"ctl","delivered":false}\n' >>"$FOLLOWUP_OUTBOX"; before="$(store)"
python3 -I "$EV" --nowait replay >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && [ "$(store)" = "$before" ]; r=$?; chk "2: replay --nowait under a held lock: exit 75, outbox untouched (rc=$rc)" "$r"
release; rm -f "$FOLLOWUP_OUTBOX"

# 3. fu_stop_new (the one Stop-path check): busy store -> pass + marker; evaluator failure -> evalfail marker, never "none owed"
fsn() { # fsn <evaluator> : prints FU_STOP_LOCKED|<new count>|rc
  # shellcheck disable=SC1090  # tree-relative library paths (FU_TREE)
  ( export FOLLOWUP_EVAL="$1"; . "$LIB" 2>/dev/null; . "$NW" 2>/dev/null || { echo "NO-NOWAIT-LIB"; exit 0; }
    fu_stop_new ctl s1 >/dev/null 2>&1; echo "${FU_STOP_LOCKED:-x}|$(printf '%s' "$FU_STOP_NEW" | grep -c .)" )
}
hold 6; s=$(date +%s%N); o="$(fsn "$EV")"; ms=$(( ($(date +%s%N) - s) / 1000000 )); release
[ "$o" = "1|0" ] && [ "$ms" -lt 3000 ] && [ -s "$OWED_NOW_STATE/s1.stoplock" ]; r=$?; chk "3: Stop check under a held store: passes in ${ms} ms, locked=1, no obligations, .stoplock marker written (got $o)" "$r"
o="$(fsn "$EV")"
[ "$o" = "0|3" ] && [ ! -e "$OWED_NOW_STATE/s1.stoplock" ]; r=$?; chk "3: next Stop with the lock free escalates R1-R3 once and clears the marker (got $o)" "$r"
o="$(fsn "$EV")"; [ "$o" = "0|0" ]; r=$?; chk "3: repeated Stop on the unchanged ledger is silent (got $o)" "$r"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(3)\n' >"$base/crash.py"
o="$(fsn "$base/crash.py")"
[ "$o" = "0|0" ] && grep -qx 'evalfail rc-3' "$OWED_NOW_STATE/s1.stoplock" 2>/dev/null; r=$?; chk "3: an evaluator crash is recorded as 'evalfail rc-3' in the marker, not as none owed (got $o)" "$r"
rm -f "$OWED_NOW_STATE/s1.stoplock"

# 4. ops = ctl alias (one owner set)
a="$(python3 -I "$EV" eval --seat ops 2>/dev/null | jq -c '[.dispositions[].id]|sort')"; b="$(python3 -I "$EV" eval --seat ctl 2>/dev/null | jq -c '[.dispositions[].id]|sort')"
[ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" != "[]" ]; r=$?; chk "4: eval --seat ops == eval --seat ctl ($a)" "$r"

# 5. failed ledger read: UNKNOWN with a redacted hint (fixture text only), never none owed
o="$(FU_ASKS_FAIL=3 FU_ASKS_STDERR='error: token=SECRETVALUE1 Authorization: Bearer SECRETVALUE2 https://u:SECRETVALUE3@h/x?api_key=SECRETVALUE4' python3 -I "$EV" eval --seat ctl 2>/dev/null)"
jq -e '.error | startswith("ledger query exit 3: error:") and contains("redacted")' <<<"$o" >/dev/null 2>&1 && ! grep -q 'SECRETVALUE' <<<"$o"; r=$?; chk "5: ledger exit 3 -> error carries the stderr hint, redacted, no secret text ($(jq -r .error <<<"$o" | head -c 120))" "$r"
o="$(FU_ASKS_GARBAGE=1 python3 -I "$EV" new --seat ctl 2>/dev/null)"
jq -e '.new[0].kind=="ledger-unreadable"' <<<"$o" >/dev/null 2>&1; r=$?; chk "5: non-JSON ledger -> a ledger-unreadable obligation (fail-closed), not an empty list" "$r"

# 6. batched new: one outbox write for all new obligations (fresh store)
rm -rf "$FOLLOWUP_STATE_DIR"; mkdir -p "$FOLLOWUP_STATE_DIR"
{ row B1; row B2; row B3; row B4; } | jq -sc . >"$FU_ASKS"
strace -f -e trace=openat -o "$base/st" python3 -I "$EV" new --seat ctl >/dev/null 2>&1 || python3 -I "$EV" new --seat ctl >/dev/null 2>&1
n="$(grep -c '"seat":"ctl"' "$FOLLOWUP_OUTBOX" 2>/dev/null)"; opens="$(grep -c 'outbox.jsonl.*O_APPEND' "$base/st" 2>/dev/null)"
[ "$n" = 4 ] && { [ ! -s "$base/st" ] || [ "$opens" = 1 ]; }; r=$?; chk "6: 4 new obligations queued with one outbox append (lines=$n appends=${opens:-n/a})" "$r"

# 7. the third installed consumer: followup-outbox-replay.sh = replay, then one owed-now refresh per seats.tsv seat (best-effort, exit 0)
rm -rf "$FOLLOWUP_STATE_DIR" "$OWED_NOW_STATE"; mkdir -p "$FOLLOWUP_STATE_DIR"; { row W1; } | jq -sc . >"$FU_ASKS"
printf '#!/usr/bin/env bash\ncat >>"%s"\n' "$base/delivered7.log" >"$base/deliver7"; chmod +x "$base/deliver7"
printf '{"id":"W0","rev":1,"fp":"w0","ts":"t","seat":"ctl","delivered":false}\n' >"$FOLLOWUP_OUTBOX"
printf 'ctl\t-\t-\nrb\t-\t-\n# comment\n' >"$base/seats7.tsv"
FOLLOWUP_DELIVER_CMD="$base/deliver7" SEATS_TABLE="$base/seats7.tsv" bash "$T/.local/bin/followup-outbox-replay.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '"W0"' "$base/delivered7.log" 2>/dev/null && [ -s "$OWED_NOW_STATE/ctl.ups-cache.json" ] && [ -s "$OWED_NOW_STATE/rb.ups-cache.json" ]
r=$?; chk "7: followup-outbox-replay.sh: rc 0, outbox entry W0 delivered, then owed-now caches refreshed for ctl and rb (ctl=$([ -s "$OWED_NOW_STATE/ctl.ups-cache.json" ] && echo yes || echo no) rb=$([ -s "$OWED_NOW_STATE/rb.ups-cache.json" ] && echo yes || echo no))" "$r"
rm -rf "$OWED_NOW_STATE"; printf '{"id":"W1","rev":1,"fp":"w1","ts":"t","seat":"ctl","delivered":false}\n' >"$FOLLOWUP_OUTBOX"
FU_ASKS_FAIL=3 FOLLOWUP_DELIVER_CMD="$base/deliver7" SEATS_TABLE="$base/seats7.tsv" bash "$T/.local/bin/followup-outbox-replay.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '"W1"' "$base/delivered7.log" 2>/dev/null; r=$?; chk "7: with the ledger failing, the refresh step does not fail the replay (rc=$rc, W1 delivered)" "$r"

echo "followup-installed-contract: pass=$pass fail=$fail"
[ "$fail" = 0 ]
