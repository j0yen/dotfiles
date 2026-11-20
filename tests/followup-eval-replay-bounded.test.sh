#!/usr/bin/env bash
# followup-eval-replay-bounded (ledger ask A1307, 11-14 replay repair recovered into source): followup-eval.py replay stops delivering at
# FOLLOWUP_REPLAY_BUDGET_S or on SIGTERM/SIGINT/SIGHUP, carries the entries it did not reach unchanged, writes the outbox in every exit path
# (also after an exception), keeps sent_part records the deliverer appends during the run, and writes a run summary to stderr and
# <state>/replay.last.json. Before the repair a run under the unit's TimeoutStartSec=300 was killed before its single end-of-run write, so the
# SIGTERM discarded every delivery of the run and the same leading entries rang again every 5 minutes.
# Synthetic outbox + logging delivery stub in an isolated HOME / state dir; no network, no live outbox, no ledger.
# FU_EVAL=<file> runs the same checks against other evaluator bytes (RED on 3736360c, the pre-repair PR426 head).
# shellcheck disable=SC2319  # r=$? after a [ ] condition is the intended capture (the message may run command substitutions)
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
EV="${FU_EVAL:-$here/.local/bin/followup-eval.py}"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-replay-bounded.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
export HOME="$base/home" FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_DELIVER_CMD="$base/deliver.sh" DLOG="$base/delivered.log"
unset FOLLOWUP_OUTBOX FOLLOWUP_REPLAY_BUDGET_S FOLLOWUP_REPLAY_PER_S FOLLOWUP_LOCK_HELD
mkdir -p "$HOME" "$FOLLOWUP_STATE_DIR"
OB="$FOLLOWUP_STATE_DIR/outbox.jsonl"; LAST="$FOLLOWUP_STATE_DIR/replay.last.json"
cat >"$base/deliver.sh" <<'D'
#!/usr/bin/env bash
in="$(cat)"; sleep "${FAKE_SLEEP:-0.3}"
case "$in" in *FAIL*) exit 1;; esac
printf '%s\n' "$(jq -r .id <<<"$in")" >>"$DLOG"
[ -n "${FAKE_RECORD:-}" ] && printf '{"sent_part":true,"delivered":true,"key":"k","part":"p","ts":"x"}\n' >>"$FOLLOWUP_STATE_DIR/outbox.jsonl"
exit 0
D
chmod +x "$base/deliver.sh"

# 8 entries: pending at start = A0 A1 A2 FAIL3 A4 A7 (6); A5 already delivered; A6 superseded by the reviewed sidecar; plus one non-JSON line
mk() {
  : >"$DLOG"; rm -f "$LAST"
  python3 -I - "$OB" <<'P'
import json, sys
L = [{"id": "A%d" % k, "rev": 1, "fp": "fp%d" % k, "ts": "2026-11-14T00:00:0%d" % k, "seat": "ctl", "delivered": False, "resolved": False, "kind": "t", "detail": "x"} for k in range(8)]
L[3]["id"] = "FAIL3"; L[5]["delivered"] = True
open(sys.argv[1], "w").write("\n".join(json.dumps(e) for e in L) + "\nnot json line\n")
open(sys.argv[1][:-6] + ".superseded.jsonl", "w").write(json.dumps({"id": "A6", "rev": 1, "fp": "fp6", "entry_ts": "2026-11-14T00:00:06"}) + "\n")
P
}
# st -> "entries delivered_count raw_lines sent_parts FAIL3 A6 A5 pending delivered failed carried signal"
st() {
  python3 -I - "$OB" "$LAST" <<'P'
import json, os, sys
ents, raw, sent = [], 0, 0
for l in open(sys.argv[1]):
    l = l.strip()
    if not l:
        continue
    try:
        e = json.loads(l)
    except ValueError:
        raw += 1; continue
    if e.get("sent_part"):
        sent += 1; continue
    ents.append(e)
d = {e["id"]: e["delivered"] for e in ents}
s = json.load(open(sys.argv[2]))["replay"] if os.path.exists(sys.argv[2]) else {}
g = lambda k: s.get(k, -1)   # -1 = no summary (pre-repair bytes): numeric so every check still runs and fails
print(len(ents), sum(1 for v in d.values() if v), raw, sent, d.get("FAIL3"), d.get("A6"), d.get("A5"), g("pending"), g("delivered"), g("failed"), g("carried"), g("signal"))
P
}
isnum() { [[ "$1" =~ ^[0-9]+$ ]]; }

# 1. budget: 1 s budget, 0.4 s per delivery -> some delivered, the rest carried, nothing lost; summary on stderr and in replay.last.json
mk; FAKE_SLEEP=0.4 FOLLOWUP_REPLAY_BUDGET_S=1 python3 -I "$EV" replay 2>"$base/err1"; rc=$?
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$rc" = 0 ]; r=$?; chk "1: budget run exits 0 (rc=$rc)" "$r"
[ "$n" = 8 ] && [ "$raw" = 1 ]; r=$?; chk "1: all 8 entries and the non-JSON line kept (entries=$n raw=$raw)" "$r"
isnum "$c" && [ "$p" = 6 ] && [ "$c" -ge 1 ] && [ "$d" -ge 1 ] && [ $((d + f + c)) = 6 ]; r=$?; chk "1: pending 6 = delivered $d + failed $f + carried $c, at least one carried" "$r"
[ "$dl" = $((d + 1)) ] && [ "$(wc -l <"$DLOG")" = "$d" ]; r=$?; chk "1: delivered flags written for exactly the $d sent entries (+A5)" "$r"
[ "$a6" = False ] && [ "$a5" = True ] && ! grep -qx A6 "$DLOG"; r=$?; chk "1: superseded A6 not sent, pre-delivered A5 kept" "$r"
[ "$(wc -l <"$DLOG")" -lt 5 ] && [ "$dl" -lt 6 ]; r=$?; chk "1: the budget stopped sending before all 5 deliverable entries went out (sends=$(wc -l <"$DLOG"), flags=$dl; summary-independent)" "$r"
grep -q '"replay"' "$base/err1" && [ -s "$LAST" ]; r=$?; chk "1: run summary on stderr and in replay.last.json" "$r"

# 2. the next run drains the carried entries exactly once; FAIL3 stays undelivered (counted failed, not carried)
: >"$DLOG"; FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$dl" = 6 ] && [ "$f3" = False ] && [ "$a6" = False ] && [ "$c" = 0 ] && [ "$f" = 1 ]; r=$?; chk "2: drain: 6 delivered, FAIL3 failed + A6 superseded undelivered, carried 0 (dl=$dl c=$c f=$f)" "$r"
sort "$DLOG" | uniq -d | grep -q . && dup=1 || dup=0; [ "$dup" = 0 ]; r=$?; chk "2: the drain run sends no entry twice" "$r"

# 3. SIGTERM mid-run (as systemd stops the unit): progress written, signal recorded, remainder carried
mk; FAKE_SLEEP=1 FOLLOWUP_REPLAY_BUDGET_S=100 timeout -s TERM 1.6 python3 -I "$EV" replay 2>"$base/err3"; rc=$?
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$rc" = 124 ]; r=$?; chk "3: timeout delivered SIGTERM (rc=$rc)" "$r"
[ "$n" = 8 ] && [ "$raw" = 1 ] && [ "$sg" = 15 ]; r=$?; chk "3: outbox intact and signal 15 recorded (entries=$n raw=$raw signal=$sg)" "$r"
[ "$(wc -l <"$DLOG")" -ge 1 ] && [ "$dl" = $(( $(wc -l <"$DLOG") + 1 )) ]; r=$?; chk "3: every send made before SIGTERM has its delivered flag on disk (sends=$(wc -l <"$DLOG") flags=$dl incl. A5; summary-independent)" "$r"
isnum "$c" && [ "$d" -ge 1 ] && [ "$c" -ge 1 ] && [ $((d + f + c)) = 6 ] && [ "$dl" = $((d + 1)) ]; r=$?; chk "3: deliveries before the signal are durable ($d), the rest carried ($c)" "$r"

# 4. records the deliverer appends to the outbox during the run survive the rewrite (sent_part tail)
mk; FAKE_RECORD=1 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$sent" = 5 ] && [ "$d" = 5 ] && [ "$n" = 8 ]; r=$?; chk "4: 5 sent_part records kept beside the 8 entries (sent=$sent delivered=$d)" "$r"

# 5. an exception inside the loop: the entries not reached are carried verbatim and the outbox is still written (finally path)
mk; python3 -I - "$EV" <<'P' >"$base/out5" 2>&1
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("fe", sys.argv[1]); fe = importlib.util.module_from_spec(spec); spec.loader.exec_module(fe)
real, calls = subprocess.run, {"n": 0}
def boom(*a, **k):
    calls["n"] += 1
    if calls["n"] == 3:
        raise RuntimeError("injected")
    return real(*a, **k)
fe.subprocess.run = boom
try:
    fe.cmd_replay()
    print("NO-RAISE")
except RuntimeError:
    print("RAISED")
P
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
grep -q RAISED "$base/out5" && [ "$n" = 8 ] && [ "$raw" = 1 ] && [ "$dl" = 3 ] && [ "$(wc -l <"$DLOG")" = 2 ]; r=$?; chk "5: exception on the 3rd delivery: 8 entries + raw line kept, the 2 sent stay delivered (dl=$dl)" "$r"
grep -q '"A7"' "$OB" && [ "$a6" = False ]; r=$?; chk "5: unreached entries (A7) and superseded A6 carried undelivered" "$r"

# 6. two replays at once on one store: the lock serialises them, every pending entry is sent exactly once, none lost
mk; ( FAKE_SLEEP=0.2 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null ) & p1=$!
( FAKE_SLEEP=0.2 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null ) & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$(wc -l <"$DLOG")" = 5 ] && [ -z "$(sort "$DLOG" | uniq -d)" ] && [ "$n" = 8 ] && [ "$dl" = 6 ]; r=$?; chk "6: concurrent replays: 5 sends, no duplicate, 8 entries, A0-A4/A7 delivered (sends=$(wc -l <"$DLOG") dl=$dl)" "$r"

# 7. invalid budget values fall back to the defaults (no crash, no zero budget that would carry everything forever)
mk; FOLLOWUP_REPLAY_BUDGET_S=abc FOLLOWUP_REPLAY_PER_S=-5 FAKE_SLEEP=0 python3 -I "$EV" replay 2>/dev/null; rc=$?
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$rc" = 0 ] && [ "$c" = 0 ] && [ "$d" = 5 ] && grep -q '"budget_s":240' "$LAST"; r=$?; chk "7: bad budget env -> defaults 240 s / 60 s, 5 delivered, 0 carried" "$r"

# 8. the timer's consumer (.local/bin/followup-outbox-replay.sh -> followup-lib.sh fu_outbox_replay) drives the same bounded replay and exits 0
mk; FOLLOWUP_EVAL="$EV" FOLLOWUP_REPLAY_BUDGET_S=1 FAKE_SLEEP=0.4 SEATS_TABLE="$base/no-seats.tsv" bash "$here/.local/bin/followup-outbox-replay.sh"; rc=$?
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$rc" = 0 ] && [ -s "$LAST" ] && isnum "$c" && [ "$c" -ge 1 ] && [ "$n" = 8 ]; r=$?; chk "8: followup-outbox-replay.sh exits 0, budget honoured through the consumer (carried=$c), outbox intact" "$r"

echo "followup-eval-replay-bounded: pass=$pass fail=$fail"
[ "$fail" = 0 ]
