#!/usr/bin/env bash
# followup-eval-replay-bounded (ledger ask A1307, 11-14 replay repair recovered into source): followup-eval.py replay stops starting deliveries at
# FOLLOWUP_REPLAY_BUDGET_S or on SIGTERM/SIGINT/SIGHUP, bounds each delivery by min(FOLLOWUP_REPLAY_PER_S, remaining budget) with a 1 s floor,
# carries the entries it did not reach unchanged, rewrites the outbox under the store lock in every exit path (also after an exception), keeps
# sent_part records the deliverer appends during the run, restores the previous signal handlers, and writes a run summary to stderr and
# <state>/replay.last.json. Before the repair a run under the unit's TimeoutStartSec=300 was killed before its single end-of-run write, so the
# SIGTERM discarded every delivery of the run and the same leading entries rang again every 5 minutes.
#
# INHERITED LIMITATIONS (identical in the installed carbon bytes 5d6e24ec; pinned below as CHAR checks so a later behaviour repair changes them on purpose):
#   R2  "no entry is lost or duplicated" does not hold on the per-entry-timeout path. subprocess.run kills only the deliverer process, so
#       (a) a no-dest seat bell that outlives the timeout still rings, the entry is counted failed and the next run rings it again (duplicate bell);
#       (b) a dest send killed after followup-deliver.sh committed its sending_part marker becomes a needs-reconcile UNKNOWN held for a human
#           --reconcile, even when nothing was sent at the kill (spurious zero-send UNKNOWN). It is never resent automatically.
#   R3  after an exception (e.g. a valid-JSON non-object outbox line) replay.last.json counts only the entries reached before the raise; the
#       lines carried verbatim after it are not counted, so pending/carried 0 on a raising run is NOT proof of a drain (rc 1 and the traceback
#       are discarded by followup-lib.sh fu_outbox_replay).
#   R4  SIGTERM while replay waits for the store lock does not end the run (handlers are installed before the lock); nothing is lost.
#   R7  on the timer path the stderr summary is discarded; replay.last.json is the only durable readback.
# Synthetic outbox + logging delivery stub (and the tree's real followup-deliver.sh with fake hermes / seat-event for the CHAR checks) in an
# isolated HOME / state dir; no network, no live outbox, no ledger.
# FU_EVAL=<file> runs the same checks against other evaluator bytes (RED on 3736360c, the pre-repair PR426 head).
# shellcheck disable=SC2319  # r=$? after a [ ] condition is the intended capture (the message may run command substitutions)
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
EV="${FU_EVAL:-$here/.local/bin/followup-eval.py}"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-replay-bounded.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
export HOME="$base/home" FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_DELIVER_CMD="$base/deliver.sh" DLOG="$base/delivered.log"
unset FOLLOWUP_OUTBOX FOLLOWUP_REPLAY_BUDGET_S FOLLOWUP_REPLAY_PER_S FOLLOWUP_LOCK_HELD HANG_ON SIG_ON
mkdir -p "$HOME" "$FOLLOWUP_STATE_DIR"
OB="$FOLLOWUP_STATE_DIR/outbox.jsonl"; LAST="$FOLLOWUP_STATE_DIR/replay.last.json"
# stub deliverer: HANG_ON=<id> makes that entry's delivery hang (exec, so the timeout kill ends it; exit 0 if it is ever allowed to finish);
# SIG_ON=<id> SIG_NAME=<sig> makes the replay process receive <sig> while that entry is being delivered (deterministic mid-run signal).
cat >"$base/deliver.sh" <<'D'
#!/usr/bin/env bash
in="$(cat)"; id="$(jq -r .id <<<"$in" 2>/dev/null)"
[ -n "${START_MARK:-}" ] && : >"$START_MARK"
[ -n "${HANG_ON:-}" ] && [ "$id" = "$HANG_ON" ] && exec sleep "${HANG_S:-6}"
sleep "${FAKE_SLEEP:-0.3}"
case "$in" in *FAIL*) exit 1;; esac
printf '%s\n' "$id" >>"$DLOG"
[ -n "${SIG_ON:-}" ] && [ "$id" = "$SIG_ON" ] && kill -s "${SIG_NAME:-TERM}" "$PPID"
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
    if not isinstance(e, dict) or e.get("sent_part") or e.get("sending_part") or e.get("needs_reconcile"):
        sent += 1 if isinstance(e, dict) and e.get("sent_part") else 0; continue
    ents.append(e)
d = {e["id"]: e["delivered"] for e in ents}
s = json.load(open(sys.argv[2]))["replay"] if os.path.exists(sys.argv[2]) else {}
g = lambda k: s.get(k, -1)   # -1 = no summary (pre-repair bytes): numeric so every check still runs and fails
print(len(ents), sum(1 for v in d.values() if v), raw, sent, d.get("FAIL3"), d.get("A6"), d.get("A5"), g("pending"), g("delivered"), g("failed"), g("carried"), g("signal"))
P
}
flag() { python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
    try: e = json.loads(l)
    except ValueError: continue
    if isinstance(e, dict) and e.get("id") == sys.argv[2] and "delivered" in e and not e.get("sent_part"): print(e["delivered"]); break' "$OB" "$1"; }
isnum() { [[ "$1" =~ ^[0-9]+$ ]]; }
now() { date +%s%N; }
ms() { echo $(( ($(now) - $1) / 1000000 )); }

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

# 3. external SIGTERM mid-run (as systemd stops the unit), sent from outside once the first delivery has started (not at a fixed time, so a slow
#    interpreter start cannot turn it into a pre-handler kill): rc 0, outbox intact, signal recorded, every send made has its flag, nothing lost
mk; rm -f "$base/started"; START_MARK="$base/started" FAKE_SLEEP=1 FOLLOWUP_REPLAY_BUDGET_S=100 python3 -I "$EV" replay 2>"$base/err3" & pid=$!
for _ in $(seq 600); do [ -e "$base/started" ] && break; sleep 0.05; done; kill -s TERM "$pid"; wait "$pid"; rc=$?
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$rc" = 0 ]; r=$?; chk "3: external SIGTERM during the first delivery: replay exits 0 (rc=$rc)" "$r"
[ "$n" = 8 ] && [ "$raw" = 1 ] && [ "$sg" = 15 ]; r=$?; chk "3: outbox intact and signal 15 recorded (entries=$n raw=$raw signal=$sg)" "$r"
[ "$dl" = $(( $(wc -l <"$DLOG") + 1 )) ]; r=$?; chk "3: every send made before SIGTERM has its delivered flag on disk (sends=$(wc -l <"$DLOG") flags=$dl incl. A5; summary-independent)" "$r"
isnum "$c" && [ "$c" -ge 1 ] && [ $((d + f + c)) = 6 ] && [ "$dl" = $((d + 1)) ]; r=$?; chk "3: deliveries before the signal are durable ($d), the rest carried ($c)" "$r"

# 3b. TERM / HUP / INT arriving while A1 is being delivered (sent by the stub to its parent, the replay): rc 0, signal recorded,
#     A0 + A1 delivered, the 4 later pending entries carried unsent; the handler set covers all three signals
for sp in TERM:15 HUP:1 INT:2; do
  sn="${sp%%:*}"; sv="${sp##*:}"
  mk; SIG_ON=A1 SIG_NAME="$sn" FAKE_SLEEP=0 FOLLOWUP_REPLAY_BUDGET_S=100 python3 -I "$EV" replay 2>/dev/null; rc=$?
  read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
  [ "$rc" = 0 ] && [ "$sg" = "$sv" ] && [ "$d" = 2 ] && [ "$c" = 4 ] && [ "$f" = 0 ] && [ "$(paste -sd, "$DLOG")" = "A0,A1" ] && [ "$dl" = 3 ] && [ "$n" = 8 ]
  r=$?; chk "3b: SIG$sn during A1: rc 0, signal $sv recorded, A0+A1 delivered, 4 carried unsent (rc=$rc sig=$sg d=$d c=$c f=$f sends=$(paste -sd, "$DLOG"))" "$r"
done

# 4. records the deliverer appends to the outbox during the run survive the rewrite (sent_part tail)
mk; FAKE_RECORD=1 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$sent" = 5 ] && [ "$d" = 5 ] && [ "$n" = 8 ]; r=$?; chk "4: 5 sent_part records kept beside the 8 entries (sent=$sent delivered=$d)" "$r"

# 5. an exception inside the loop: the entries not reached are carried verbatim and the outbox is still written (finally path).
#    R3 CHAR: the summary counts only what was reached (pending 3 = A0 A1 + the raising A2, delivered 2, carried 0); the lines after the raise
#    are carried verbatim but NOT counted, so this summary must not be read as a drain.
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
grep -q '"A7"' "$OB" && [ "$a6" = False ] && [ "$(flag A2)" = False ] && [ "$(flag A7)" = False ]; r=$?; chk "5: the raising entry A2 and unreached A7 carried undelivered, superseded A6 untouched" "$r"
[ "$p" = 3 ] && [ "$d" = 2 ] && [ "$f" = 0 ] && [ "$c" = 0 ] && [ "$sg" = None ]; r=$?; chk "5: R3 CHAR summary after the raise = pending 3 delivered 2 failed 0 carried 0 (the 4 pending lines left after the raise are not counted) (p=$p d=$d f=$f c=$c sig=$sg)" "$r"

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

# 9. a hanging deliverer is bounded by FOLLOWUP_REPLAY_PER_S: A2 hangs (20 s, exit 0, if allowed), PER_S=1, budget 30 -> the run ends in well under 6 s,
#    A2 is counted failed and stays delivered:false (a timeout is never recorded as a delivery), the other entries go out
mk; s=$(now); HANG_ON=A2 HANG_S=20 FAKE_SLEEP=0 FOLLOWUP_REPLAY_PER_S=1 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null; rc=$?; el=$(ms "$s")
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$rc" = 0 ] && [ "$el" -lt 15000 ] && [ "$(flag A2)" = False ] && [ "$d" = 4 ] && [ "$f" = 2 ] && [ "$c" = 0 ] && [ "$(paste -sd, "$DLOG")" = "A0,A1,A4,A7" ]
r=$?; chk "9: PER_S=1 bounds a hanging delivery (20 s if allowed): ${el} ms < 15000, A2 failed and delivered:false, A0 A1 A4 A7 delivered (d=$d f=$f c=$c A2=$(flag A2))" "$r"

# 10. the remaining budget bounds a delivery even when PER_S is larger: budget 2, PER_S 30, A0 hangs -> killed near 2 s, failed, the rest carried
mk; s=$(now); HANG_ON=A0 HANG_S=20 FAKE_SLEEP=0 FOLLOWUP_REPLAY_PER_S=30 FOLLOWUP_REPLAY_BUDGET_S=2 python3 -I "$EV" replay 2>/dev/null; rc=$?; el=$(ms "$s")
read -r n dl raw sent f3 a6 a5 p d f c sg < <(st)
[ "$rc" = 0 ] && [ "$el" -lt 15000 ] && [ "$(flag A0)" = False ] && [ "$d" = 0 ] && [ "$f" = 1 ] && [ "$c" = 5 ]
r=$?; chk "10: remaining budget (2 s) bounds the delivery below PER_S (30 s; hang 20 s): ${el} ms < 15000, A0 failed + undelivered, 5 carried (d=$d f=$f c=$c)" "$r"

# 11. exact per-entry timeout argument (in-process, controlled clock, delivery call recorded, nothing executed): timeout = max(1, min(PER_S, left))
#     a) budget 0.2, 0.15 s already used -> left 0.05 -> 1.0 (the 1 s floor)   b) budget 2, PER_S 30 -> 2.0 (remaining budget wins)
#     c) budget 30, PER_S 1 -> 1.0 (FOLLOWUP_REPLAY_PER_S honoured)
o11="$(python3 -I - "$EV" "$OB" <<'P' 2>&1
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("fe", sys.argv[1]); fe = importlib.util.module_from_spec(spec); spec.loader.exec_module(fe)
ob = sys.argv[2]; out = []
class Done:
    returncode = 0
for name, budget, per, used in (("a", "0.2", "60", 0.15), ("b", "2", "30", 0.0), ("c", "30", "1", 0.0)):
    open(ob, "w").write(json.dumps({"id": "T" + name, "rev": 1, "fp": "t", "ts": "t", "seat": "ctl", "delivered": False}) + "\n")
    os.environ["FOLLOWUP_REPLAY_BUDGET_S"] = budget; os.environ["FOLLOWUP_REPLAY_PER_S"] = per
    clock = {"t": 100.0}; seen = []
    try:
        fe.time.monotonic = lambda: clock["t"]
    except AttributeError:
        out.append(name + "=no-clock"); continue
    real_locked = fe.locked
    def locked(sd, _r=real_locked, _u=used):
        fh = _r(sd); clock["t"] += _u; return fh
    fe.locked = locked
    fe.subprocess.run = lambda *a, **k: (seen.append(k.get("timeout")), Done())[1]
    fe.cmd_replay(); fe.locked = real_locked
    out.append("%s=%s" % (name, seen[0] if seen else "none"))
print(" ".join(out))
P
)"
[ "$(tail -1 <<<"$o11")" = "a=1.0 b=2.0 c=1.0" ]; r=$?; chk "11: per-entry timeout = max(1, min(PER_S, left)): floor a=1.0, remaining-budget b=2.0, PER_S c=1.0 (got $(tail -1 <<<"$o11" | cut -c1-80))" "$r"

# 12. in-process: the outbox rewrite happens while the store lock is still held, and the caller's SIGTERM/SIGINT/SIGHUP handlers are restored
mk; o12="$(FAKE_SLEEP=0 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I - "$EV" <<'P' 2>&1
import importlib.util, fcntl, os, signal, sys
spec = importlib.util.spec_from_file_location("fe", sys.argv[1]); fe = importlib.util.module_from_spec(spec); spec.loader.exec_module(fe)
sd = os.environ["FOLLOWUP_STATE_DIR"]; ob = os.path.join(sd, "outbox.jsonl"); seen = []
real_aw = fe.atomic_write
def aw(path, text):
    if os.path.abspath(path) == os.path.abspath(ob):   # a second open file description: flock conflicts with the replay's own lock fd if it is still held
        fd = os.open(os.path.join(sd, "lock"), os.O_RDWR | os.O_CREAT)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); seen.append("free"); fcntl.flock(fd, fcntl.LOCK_UN)
        except BlockingIOError:
            seen.append("held")
        finally:
            os.close(fd)
    return real_aw(path, text)
fe.atomic_write = aw
def sentinel(s, f):
    pass
for sg in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sg, sentinel)
fe.cmd_replay()
print("lock=" + ",".join(seen or ["no-write"]), "handlers=" + ("restored" if all(signal.getsignal(sg) is sentinel for sg in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)) else "not-restored"))
P
)"
grep -q 'lock=held handlers=restored' <<<"$o12"; r=$?; chk "12: outbox rewritten under the held store lock; previous TERM/INT/HUP handlers restored ($(tail -1 <<<"$o12" | cut -c1-80))" "$r"

# 13. R3 CHAR (natural raise): a valid-JSON non-object line raises every run; run 2's summary reads drained (pending 0, carried 0) while the
#     two entries after the bad line are never processed. Pinned so the misleading summary is visible, not taken as drain proof.
: >"$DLOG"; rm -f "$LAST" "${OB%.jsonl}.superseded.jsonl"
for k in 0 1; do printf '{"id":"B%d","rev":1,"fp":"b%d","ts":"t","seat":"ctl","delivered":false}\n' "$k" "$k"; done >"$OB"
printf '[1]\n' >>"$OB"; for k in 2 3; do printf '{"id":"B%d","rev":1,"fp":"b%d","ts":"t","seat":"ctl","delivered":false}\n' "$k" "$k"; done >>"$OB"
FAKE_SLEEP=0 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null; rc1=$?
FAKE_SLEEP=0 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null; rc2=$?
s13="$(jq -c '.replay | [.pending, .delivered, .failed, .carried]' "$LAST" 2>/dev/null)"
[ "$rc1" != 0 ] && [ "$rc2" != 0 ] && [ "$s13" = "[0,0,0,0]" ] && [ "$(flag B1)" = True ] && [ "$(flag B2)" = False ] && [ "$(flag B3)" = False ] && [ "$(grep -c . "$OB")" = 5 ]
r=$?; chk "13: R3 CHAR: run 2 rc=$rc2 and summary $s13 reads drained while B2 B3 stay undelivered behind the non-object line (all 5 lines kept)" "$r"

# 14-15. R2 CHAR through the tree's real followup-deliver.sh (fake seat-event.sh / hermes on PATH; nothing leaves the sandbox)
DEL="$here/.local/bin/followup-deliver.sh"; mkdir -p "$base/bin"
cat >"$base/bin/seat-event.sh" <<'B'
#!/usr/bin/env bash
sleep "${BELL_SLOW:-0}"; printf '%s\n' "$*" >>"$BELL_LOG"
B
cat >"$base/bin/hermes" <<'H'
#!/usr/bin/env bash
[ "${1:-}" = send ] || exit 2
sleep "${HERMES_SLOW:-0}"; printf 'send\n' >>"$FH_LOG"; n=$(grep -c . "$FH_LOG"); echo "{\"success\":true,\"message_id\":\"m$n\"}"
H
chmod +x "$base/bin/seat-event.sh" "$base/bin/hermes"
export BELL_LOG="$base/bell.log" FH_LOG="$base/fh.log"
# 14. no-dest entry whose seat bell outlives the per-entry timeout: run 1 kills only the deliverer, the bell still rings, the entry is failed;
#     run 2 rings it again -> 2 bells for one entry (duplicate bell). Wide margins: the deliverer has 4 s to reach the bell, the bell takes 10 s
: >"$BELL_LOG"; rm -f "$LAST"; printf '{"id":"C9","rev":1,"fp":"c9","ts":"t","seat":"ctl","kind":"overdue","detail":"x","delivered":false}\n' >"$OB"
PATH="$base/bin:$PATH" SEAT_EVENT_BIN="$base/bin/seat-event.sh" BELL_SLOW=10 FOLLOWUP_DELIVER_CMD="$DEL" FOLLOWUP_REPLAY_PER_S=4 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null
f14="$(jq -r .replay.failed "$LAST" 2>/dev/null)"; for _ in $(seq 400); do [ -s "$BELL_LOG" ] && break; sleep 0.1; done   # the orphaned bell lands ~10 s in
PATH="$base/bin:$PATH" SEAT_EVENT_BIN="$base/bin/seat-event.sh" BELL_SLOW=0 FOLLOWUP_DELIVER_CMD="$DEL" FOLLOWUP_REPLAY_PER_S=10 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null
b14="$(grep -c 'C9' "$BELL_LOG")"
[ "$f14" = 1 ] && [ "$b14" = 2 ] && [ "$(flag C9)" = True ]; r=$?; chk "14: R2 CHAR duplicate bell: 10 s bell killed at PER_S=4 counts failed (failed=$f14) yet rings; next run rings again -> bells=$b14 for one entry" "$r"
# 15. dest entry whose hermes send outlives the per-entry timeout: the deliverer is killed after committing its sending_part marker and
#     before any send completed (0 sends at the kill) -> UNKNOWN; the next run raises needs-reconcile and does NOT resend
: >"$BELL_LOG"; : >"$FH_LOG"; rm -f "$LAST"
printf '{"id":"ev-T9","seat":"ctl","kind":"result","dest":"discord:#ops","task":"T9","rev":1,"result":"R1","summary":"done","delivered":false,"ts":"t"}\n' >"$OB"
PATH="$base/bin:$PATH" SEAT_EVENT_BIN="$base/bin/seat-event.sh" HERMES_SLOW=40 FOLLOWUP_DELIVER_CMD="$DEL" FOLLOWUP_REPLAY_PER_S=6 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null
s15a="$(grep -c . "$FH_LOG")"; m15="$(grep -c '"sending_part":true' "$OB")"; s15b="$s15a"   # the orphaned 40 s send is still in flight: its outcome is genuinely unknown
PATH="$base/bin:$PATH" SEAT_EVENT_BIN="$base/bin/seat-event.sh" HERMES_SLOW=0 FOLLOWUP_DELIVER_CMD="$DEL" FOLLOWUP_REPLAY_PER_S=10 FOLLOWUP_REPLAY_BUDGET_S=30 python3 -I "$EV" replay 2>/dev/null
s15c="$(grep -c . "$FH_LOG")"; rc15="$(grep -c '"needs_reconcile":true' "$OB")"
pkill -f "$base/bin/hermes" 2>/dev/null   # end the orphaned in-flight send of run 1 (sandbox only)
[ "$s15a" = 0 ] && [ "$m15" -ge 1 ] && [ "$s15c" = "$s15b" ] && [ "$rc15" -ge 1 ] && [ "$(flag ev-T9)" = False ]; r=$?; chk "15: R2 CHAR zero-send UNKNOWN: killed (PER_S=6, send 40 s) with marker=$m15 and sends=$s15a; run 2 resends nothing ($s15c), needs_reconcile=$rc15, entry undelivered" "$r"

echo "followup-eval-replay-bounded: pass=$pass fail=$fail"
[ "$fail" = 0 ]
