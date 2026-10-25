#!/usr/bin/env bash
# tests/hand-pr-land-driver.test.sh: hermetic end-to-end cases for .local/bin/hand-pr-land-driver.sh against STUBS of gh, wm-decide, aide-verifier.sh, rb-merge.sh,
# seat-ask.sh, carbon-room.sh, systemctl and the gate lint (HPLD_* env). Touches no real ledger, unit, PR or seat.
# Cases: (a) launch (fast and full tier), ROOM fail = no launch, (b) finish + lint-refuse, (c) merge + void + gate refuse, (d) post-merge ring, (e) head moved,
# idempotency (two ticks = one action), dry-run changes nothing, only rb-merge.sh ever merges. Run: bash tests/hand-pr-land-driver.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
DRV="$here/../.local/bin/hand-pr-land-driver.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
H1=$(printf 'a%.0s' $(seq 40)); H2=$(printf 'b%.0s' $(seq 40)); REPO=j0yen/synthorg
iso() { python3 -c "import datetime,sys; print((datetime.datetime.now().astimezone()-datetime.timedelta(minutes=float(sys.argv[1]))).isoformat(timespec='seconds'))" "$1"; }

setup() {   # fresh sandbox in $T with the stub set
  T=$(mktemp -d); mkdir -p "$T/bin" "$T/vdir" "$T/active" "$T/state"
  echo '[]' >"$T/rows.json"; : >"$T/events.jsonl"; : >"$T/calls.log"; : >"$T/records.log"; echo 0 >"$T/lint.rc"; echo 0 >"$T/room.rc"; echo 0 >"$T/merge.rc"
  cat >"$T/bin/wm-decide" <<'E'
#!/usr/bin/env python3
import json, os, sys
T = os.environ["T"]; a = sys.argv[1:]
open(T + "/calls.log", "a").write("wm-decide " + " ".join(a[:1]) + "\n")
if a[0] == "list":
    sys.stdout.write(open(T + "/rows.json").read())
elif a[0] == "record":
    d = {a[i][2:]: a[i + 1] for i in range(1, len(a) - 1, 2) if a[i].startswith("--")}
    open(T + "/records.log", "a").write(d["agent"] + " | " + d["what"] + "\n")
    rows = json.load(open(T + "/rows.json"))
    rows.append({"id": "d-rec-%d" % len(rows), "ts": "2099-01-01T00:00:00+00:00", "agent": d["agent"], "kind": d["kind"], "what": d["what"], "gates": None})
    json.dump(rows, open(T + "/rows.json", "w"))
E
  cat >"$T/bin/gh" <<'E'
#!/usr/bin/env bash
echo "gh $*" >>"$T/calls.log"
case "$1 $2" in
  "pr list") f="$T/prs-$(echo "$4" | tr / -).json"; [ -f "$f" ] && cat "$f" || echo '[]' ;;
  "api repos/"*) echo tests/foo_test.py ;;
  *) echo "stub gh: unexpected $*" >&2; exit 9 ;;
esac
E
  cat >"$T/bin/aide-verifier.sh" <<'E'
#!/usr/bin/env bash
echo "verifier $*" >>"$T/calls.log"
if [ "$1" = launch ]; then mkdir -p "$T/vdir/$2"; shift 2; while [ $# -gt 0 ]; do case "$1" in --repo) r=$2 ;; --pr) p=$2 ;; --head) h=$2 ;; --gated) g=$2 ;; esac; shift; done; printf 'repo=%s\npr=%s\nhead=%s\ngated=%s\nagent=aide\n' "$r" "$p" "$h" "$g" >"$T/vdir/$(ls -t "$T/vdir" | head -1)/meta"; set -- launch "$(ls -t "$T/vdir" | head -1)"; touch "$T/active/aide-verifier-$2.service"; echo "aide-verifier-$2"; fi
exit "${VERIFIER_RC:-0}"
E
  cat >"$T/bin/rb-merge.sh" <<'E'
#!/usr/bin/env bash
echo "rb-merge $*" >>"$T/calls.log"
rc=$(cat "$T/merge.rc")
[ "$rc" = 0 ] && echo "PASS stub oid=$(printf 'a%.0s' $(seq 40))" || echo "G4 refused (stub)" >&2
exit "$rc"
E
  cat >"$T/bin/seat-ask.sh" <<'E'
#!/usr/bin/env bash
echo "seat-ask $1 $2" >>"$T/calls.log"
E
  cat >"$T/bin/carbon-room.sh" <<'E'
#!/usr/bin/env bash
echo "room $*" >>"$T/calls.log"; exit "$(cat "$T/room.rc")"
E
  cat >"$T/bin/systemctl" <<'E'
#!/usr/bin/env bash
[ -e "$T/active/$3" ] && { echo active; exit 0; }; echo inactive; exit 3
E
  cat >"$T/bin/lint" <<'E'
#!/usr/bin/env bash
echo "lint $*" >>"$T/calls.log"; [ "$(cat "$T/lint.rc")" = 0 ] || echo "G4: stub refusal"; exit "$(cat "$T/lint.rc")"
E
  chmod +x "$T"/bin/*
}
row() {   # row <id> <minutes-ago> <agent> <kind> <what> [gates]
  python3 - "$T/rows.json" "$1" "$(iso "$2")" "$3" "$4" "$5" "${6:-}" <<'E'
import json, sys
f, i, ts, ag, kd, w, g = sys.argv[1:8]
r = json.load(open(f)); r.append({"id": i, "ts": ts, "agent": ag, "kind": kd, "what": w, "gates": g or None}); json.dump(r, open(f, "w"))
E
}
pr() { echo "[{\"number\":$2,\"headRefOid\":\"$3\",\"headRefName\":\"${4:-hand/x}\"}]" >"$T/prs-$(echo "$1" | tr / -).json"; }
unitdir() {   # unitdir <name> <pr> <head> <gated> [result-verdict]
  mkdir -p "$T/vdir/$1"; printf 'repo=%s\npr=%s\nhead=%s\ngated=%s\ntoken=pytest EXIT=0\nagent=aide\n' "$REPO" "$2" "$3" "$4" >"$T/vdir/$1/meta"
  [ -n "${5:-}" ] && printf '{"result":"verdict row %s\\nLOG: /x.log"}' "$5" >"$T/vdir/$1/result.json"
}
tick() {   # tick [--dry-run]  (stdout kept in $T/out)
  T="$T" HPLD_STATE_DIR="$T/state" HPLD_VDIR="$T/vdir" HPLD_EVENTS="$T/events.jsonl" HPLD_WMD="$T/bin/wm-decide" HPLD_GH="$T/bin/gh" \
  HPLD_VERIFIER="$T/bin/aide-verifier.sh" HPLD_RBMERGE="$T/bin/rb-merge.sh" HPLD_SEATASK="$T/bin/seat-ask.sh" HPLD_ROOM="$T/bin/carbon-room.sh" \
  HPLD_SYSTEMCTL="$T/bin/systemctl" HPLD_LINT_CMD="$T/bin/lint" HPLD_REPOS="$REPO" bash "$DRV" "$@" >"$T/out" 2>&1; }
n() { grep -c "$1" "$T/calls.log"; }   # count of calls matching
cleanup() { rm -rf "$T"; }
export T

# ---- (a) GATED, no verdict, no unit: ROOM check then a fast-tier launch with the PR's own tests
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1 fix x"; pr $REPO 41 $H1
tick; L=$(grep '^verifier launch' "$T/calls.log")
[ "$(n '^verifier launch')" = 1 ] && [[ "$L" == *"--repo $REPO --pr 41 --head $H1 --gated g1 --token pytest EXIT=0"* ]] && [[ "$L" == *'-m "not flaky and not slow"'* ]] && [[ "$L" == *tests/foo_test.py* ]] && [[ "$L" != *--timeout* ]]; [ $? = 0 ] && pass "(a) fast-tier launch with token, suite and PR's own tests, no --timeout" || bad "(a) launch ($L)"
grep -q '^room 1024 --reserve-MB 3072' "$T/calls.log" && pass "(a) ROOM check ran before the launch (1024 MB, 3072 reserve)" || bad "(a) no ROOM call"
grep -q 'HPLD LAUNCH .*#41 k=launch:' "$T/records.log" && grep -q '^coder:hand-pr-land-driver | ' "$T/records.log" && pass "(a) ledger row HPLD LAUNCH (agent coder:hand-pr-land-driver)" || bad "(a) no launch row"
# idempotency: the launched unit is now active -> a second tick acts on nothing
tick; [ "$(n '^verifier launch')" = 1 ] && [ "$(wc -l <"$T/records.log")" = 1 ] && pass "idempotent: two ticks = one launch, one row" || bad "second tick acted again"
cleanup

# ---- (a) full tier
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1 TIER=full"; pr $REPO 41 $H1; tick; L=$(grep '^verifier launch' "$T/calls.log")
[[ "$L" == *"--timeout 5400"* ]] && [[ "$L" != *'-m "not flaky'* ]] && pass "(a) TIER=full: --timeout 5400 and no marker filter" || bad "(a) full tier ($L)"
cleanup

# ---- ROOM fail: no launch, no row
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; pr $REPO 41 $H1; echo 3 >"$T/room.rc"; tick
[ "$(n '^verifier launch')" = 0 ] && [ ! -s "$T/records.log" ] && grep -q 'ROOM NO' "$T/out" && pass "ROOM fail: no launch, no row" || bad "ROOM fail still acted"
cleanup

# ---- (b) finished unit: lint clean -> finish; lint refuses -> no finish, ring
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; pr $REPO 41 $H1; unitdir u1 41 $H1 g1 d-20261024-231015-aide-6865; tick
[ "$(n '^verifier finish u1 --pr 41 --repo')" = 1 ] && [ "$(n '^lint d-20261024-231015-aide-6865 41')" = 1 ] && grep -q 'HPLD FINISH .*k=finish:u1' "$T/records.log" && pass "(b) lint clean -> aide-verifier.sh finish + row" || bad "(b) finish"
tick; [ "$(n '^verifier finish')" = 1 ] && pass "(b) idempotent: second tick does not finish again" || bad "(b) finished twice"
cleanup
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; pr $REPO 41 $H1; unitdir u1 41 $H1 g1 d-20261024-231015-aide-6865; echo 2 >"$T/lint.rc"; tick; tick
[ "$(n '^verifier finish')" = 0 ] && [ "$(n '^seat-ask r7')" = 1 ] && [ "$(n '^verifier launch')" = 0 ] && pass "(b) lint refuse: no finish, one ring, no relaunch over a gate-failed head, none on tick 2" || bad "(b) lint refuse"
cleanup

# ---- (c) MERGE-OK for the live head -> rb-merge.sh; never any other merge path
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; row v1 500 aide verdict "MERGE-OK $REPO#41 COMMIT=$H1 agent=verifier:x" g1; pr $REPO 41 $H1; tick
[ "$(n "^rb-merge v1 41 $REPO")" = 1 ] && grep -q 'HPLD MERGED .*k=merge:v1' "$T/records.log" && [ "$(n 'gh pr merge')" = 0 ] && pass "(c) MERGE-OK -> rb-merge.sh v1 41 $REPO + MERGED row, no direct gh merge" || bad "(c) merge"
cleanup
# prefix match (short COMMIT), PR-number boundary (#4 verdict must not merge #41)
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; row v1 500 aide verdict "MERGE-OK $REPO#4 COMMIT=$H1" g1; pr $REPO 41 $H1; tick
[ "$(n '^rb-merge')" = 0 ] && pass "(c) a MERGE-OK for #4 never merges #41" || bad "(c) PR number boundary"
cleanup
# voided by CORRECT-SCOPE
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; row v1 500 aide verdict "MERGE-OK $REPO#41 COMMIT=${H1:0:12}" g1; row c1 400 controller verdict "CORRECT-SCOPE v1" v1; pr $REPO 41 $H1; tick
[ "$(n '^rb-merge')" = 0 ] && [ "$(n '^verifier launch')" = 1 ] && pass "(c) a CORRECT-SCOPE row voids the verdict: no merge, re-verify" || bad "(c) void"
cleanup
# gate refuse: no merge succeeds, one row, one ring, never retried
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; row v1 500 aide verdict "MERGE-OK $REPO#41 COMMIT=$H1" g1; pr $REPO 41 $H1; echo 2 >"$T/merge.rc"; tick; tick
[ "$(n '^rb-merge')" = 1 ] && grep -q 'HPLD MERGE-REFUSED .*rc=2' "$T/records.log" && ! grep -q 'HPLD MERGED' "$T/records.log" && [ "$(n '^seat-ask r7')" = 1 ] && [ "$(n 'gh pr merge')" = 0 ] && pass "gate refuse: no MERGED row, one refusal row, one ring, no retry on tick 2" || bad "gate refuse"
cleanup

# ---- (d) merged >= 15 min ago with no r7 START -> one ring; with a START or too young -> none
setup; row g1 900 r7 design "x"; printf '{"event":"pr-merged","oid":"%s","pr":41,"repo":"%s","ts":"%s","verdict":"v1"}\n' "$H1" "$REPO" "$(iso 20)" >"$T/events.jsonl"
tick; tick
[ "$(n '^seat-ask r7')" = 1 ] && grep -q "seat-ask r7 $REPO#41 merged $H1; run post-merge suite" "$T/calls.log" && pass "(d) one post-merge ring to r7, not repeated" || bad "(d) ring ($(grep seat-ask "$T/calls.log"))"
cleanup
setup; printf '{"event":"pr-merged","oid":"%s","pr":41,"repo":"%s","ts":"%s","verdict":"v1"}\n' "$H1" "$REPO" "$(iso 20)" >"$T/events.jsonl"; row s1 5 r7 plan "START r7-suite-41 on ryzen7 ($REPO#41)"; tick
[ "$(n '^seat-ask')" = 0 ] && pass "(d) an r7 START row naming the PR suppresses the ring" || bad "(d) START ignored"
cleanup
setup; printf '{"event":"pr-merged","oid":"%s","pr":41,"repo":"%s","ts":"%s","verdict":"v1"}\n' "$H1" "$REPO" "$(iso 5)" >"$T/events.jsonl"; tick
[ "$(n '^seat-ask')" = 0 ] && pass "(d) merged 5 min ago: not yet" || bad "(d) rang too early"
cleanup

# ---- (e) head moved since GATED: no verify, one ring to the owning seat
setup; row g1 600 rb design "GATED $REPO#41 COMMIT=$H1"; pr $REPO 41 $H2; tick; tick
[ "$(n '^verifier')" = 0 ] && [ "$(n '^rb-merge')" = 0 ] && [ "$(n '^seat-ask rb')" = 1 ] && grep -q 'HPLD RING-MOVED' "$T/records.log" && pass "(e) head moved: no verify/merge, one ring to rb (the GATED row's owner), none on tick 2" || bad "(e) moved"
cleanup
# a daemon land (wm-build/ branch) is not a hand PR
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; pr $REPO 41 $H1 wm-build/run-9; tick
[ "$(n '^verifier')" = 0 ] && pass "daemon-land branch (wm-build/*) is skipped" || bad "daemon branch acted"
cleanup

# ---- dry-run changes nothing
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; row g2 600 rb design "GATED $REPO#42 COMMIT=$H1"; pr $REPO 41 $H1; tick --dry-run
grep -q '^PLAN launch ' "$T/out" && [ "$(n '^verifier')" = 0 ] && [ "$(n '^room')" = 0 ] && [ "$(n '^seat-ask')" = 0 ] && [ ! -s "$T/records.log" ] && [ ! -e "$T/state/tick.lock" ] && pass "dry-run: PLAN lines only; no verifier, ROOM, ring, row or lock" || bad "dry-run changed something"
cleanup

# ---- the lock: a held lock makes the tick exit without acting
setup; row g1 600 r7 design "GATED $REPO#41 COMMIT=$H1"; pr $REPO 41 $H1; mkdir -p "$T/state"
( exec 8>"$T/state/tick.lock"; flock -n 8; tick; ) ; [ "$(n '^verifier')" = 1 ] && bad "tick ran under a held lock" || pass "lock: a tick under a held lock does nothing"
cleanup

bash "$DRV" --selftest >/dev/null && pass "--selftest" || bad "--selftest"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
