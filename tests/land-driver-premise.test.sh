#!/usr/bin/env bash
# tests/land-driver-premise.test.sh: the gate-set premise of .local/bin/hand-pr-land-driver.sh (asks A13 rb / A47 r7).
# Each tick dry-runs its merge candidates through the gate evaluator; the evaluator command is HPLD_LINT_CMD (the driver's existing override, = mergegate.check in production),
# stubbed here. Cases: (a) 3 refused ticks -> `PREMISE FAIL gate-set` + disarm marker + one ring, no merge, no verdict-level rb-merge call;
# (b) 2 refused then a pass -> counter 0, no disarm, merge happens; (c) a merge resets the counter (and the refusal rules/PR are logged one line per PR).
# Hermetic: stubs for gh, wm-decide, aide-verifier.sh, rb-merge.sh, seat-ask.sh, systemctl; HOME and state dir are temp. Run: bash tests/land-driver-premise.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
DRV="$here/../.local/bin/hand-pr-land-driver.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
H1=$(printf 'a%.0s' $(seq 40)); REPO=j0yen/synthorg

setup() {
  T=$(mktemp -d); mkdir -p "$T/bin" "$T/state" "$T/vdir" "$T/home"; export T
  : >"$T/calls.log"; : >"$T/events.jsonl"; echo 2 >"$T/lint.rc"
  python3 - "$T" "$REPO" "$H1" <<'PYE'
import json, sys, datetime
T, repo, h = sys.argv[1:4]
now = datetime.datetime.now().astimezone()
ts = lambda m: (now - datetime.timedelta(minutes=m)).isoformat(timespec="seconds")
json.dump([{"id": "g1", "ts": ts(600), "agent": "r7", "kind": "design", "what": "GATED %s#41 COMMIT=%s" % (repo, h), "gates": None},
           {"id": "v1", "ts": ts(500), "agent": "aide", "kind": "verdict", "what": "MERGE-OK %s#41 COMMIT=%s" % (repo, h), "gates": "g1"}], open(T + "/rows.json", "w"))
json.dump([{"number": 41, "headRefOid": h, "headRefName": "hand/x", "isDraft": False, "body": ""}], open(T + "/prs.json", "w"))
PYE
  cat >"$T/bin/wm-decide" <<'E'
#!/usr/bin/env bash
case "$1" in list) cat "$T/rows.json" ;; record) echo "record $*" >>"$T/calls.log" ;; esac
E
  cat >"$T/bin/gh" <<'E'
#!/usr/bin/env bash
case "$1 $2" in "pr list") cat "$T/prs.json" ;; "api repos/"*) printf "modified\ttests/foo_test.py\n" ;; *) exit 9 ;; esac
E
  printf '#!/usr/bin/env bash\n# supports --timeout\nexit 0\n' >"$T/bin/aide-verifier.sh"
  printf '#!/usr/bin/env bash\necho "rb-merge $*" >>"$T/calls.log"\nrc=$(cat "$T/lint.rc"); [ "$rc" = 0 ] || { echo "G3 refused (stub: rb-merge applies the same gate)" >&2; exit "$rc"; }\necho "PASS stub oid=%s"\n' "$H1" >"$T/bin/rb-merge.sh"
  printf '#!/usr/bin/env bash\necho "seat-ask $1" >>"$T/calls.log"\n' >"$T/bin/seat-ask.sh"
  printf '#!/usr/bin/env bash\nexit 3\n' >"$T/bin/systemctl"
  printf '#!/usr/bin/env bash\necho "lint $*" >>"$T/calls.log"\nrc=$(cat "$T/lint.rc"); [ "$rc" = 0 ] || printf "G3: no token\\nG6: no agent=\\n"; exit "$rc"\n' >"$T/bin/lint"
  chmod +x "$T"/bin/*
}
tick() {
  env HOME="$T/home" T="$T" HPLD_EXPIRES="2099-01-01 00:00" HPLD_STATE_DIR="$T/state" HPLD_VDIR="$T/vdir" HPLD_EVENTS="$T/events.jsonl" HPLD_WMD="$T/bin/wm-decide" HPLD_GH="$T/bin/gh" \
    HPLD_VERIFIER="$T/bin/aide-verifier.sh" HPLD_RBMERGE="$T/bin/rb-merge.sh" HPLD_SEATASK="$T/bin/seat-ask.sh" HPLD_SYSTEMCTL="$T/bin/systemctl" HPLD_LINT_CMD="$T/bin/lint" \
    HPLD_REPOS="$REPO" HPLD_PREMISE_IMPORT_CMD=true bash "$DRV" >>"$T/out" 2>&1
}
n() { grep -c "$1" "$T/calls.log"; }
counter() { cat "$T/state/gate-set-refused" 2>/dev/null || echo none; }

# (a) three refused ticks
setup; : >"$T/out"; tick; tick
[ "$(counter)" = 2 ] && ! grep -q 'PREMISE FAIL' "$T/out" && [ ! -e "$T/state/rang-gate-set" ] && pass "(a) 2 refused ticks: counter 2, no disarm yet" || bad "(a) after 2 ticks (counter $(counter))"
tick
grep -q '^PREMISE FAIL gate-set rules=G3,G6 prs=1$' "$T/out" && [ -e "$T/state/rang-gate-set" ] && [ "$(n '^seat-ask ctl')" = 1 ] && [ "$(n '^rb-merge')" = 2 ] && pass "(a) tick 3: PREMISE FAIL gate-set line, disarm marker, one ring to ctl, no merge (the 2 earlier rb-merge refusals only)" || bad "(a) tick 3 ($(cat "$T/out"))"
[ "$(grep -c '^GATE-SET REFUSED j0yen/synthorg#41 verdict=v1 rules=G3,G6' "$T/out")" = 3 ] && pass "(a) one refusal line per PR per tick with rule ids" || bad "(a) refusal lines"
grep -q '^RING ' "$T/out" && grep -q 'premise-failed' "$T/out" && pass "(a) alarm goes through disarm() (premise-failed ring)" || bad "(a) disarm output"
tick; [ "$(n '^seat-ask ctl')" = 1 ] && pass "(a) a 4th refused tick does not re-ring" || bad "(a) re-rang"
rm -rf "$T"

# (b) 2 refused, then a pass
setup; : >"$T/out"; tick; tick
echo 0 >"$T/lint.rc"; tick
[ "$(counter)" = 0 ] && [ ! -e "$T/state/rang-gate-set" ] && ! grep -q 'PREMISE FAIL' "$T/out" && [ "$(n '^seat-ask ctl')" = 0 ] && pass "(b) pass after 2 refusals: counter 0, no disarm, no ring" || bad "(b) counter $(counter)"
grep -q '^MERGED j0yen/synthorg#41' "$T/out" && pass "(b) the passing candidate merged through rb-merge.sh" || bad "(b) no merge"
rm -rf "$T"

# (c) a merge resets the counter even when the pre-check already counted: 2 refused, then pass+merge, then 2 refused again does not disarm
setup; : >"$T/out"; tick; tick
echo 0 >"$T/lint.rc"; tick
[ "$(counter)" = 0 ] && pass "(c) merge tick leaves counter 0" || bad "(c) counter $(counter)"
echo 2 >"$T/lint.rc"; python3 - "$T" <<'PYE'
import json, sys
T = sys.argv[1]; r = json.load(open(T + "/rows.json")); r.append({k: v for k, v in r[1].items() if k != "id"} | {"id": "v2", "ts": "2099-01-01T00:00:00+00:00"}); json.dump(r, open(T + "/rows.json", "w"))
PYE
tick; tick
[ "$(counter)" = 2 ] && ! grep -q 'PREMISE FAIL' "$T/out" && pass "(c) after the reset it takes 3 fresh refused ticks to disarm" || bad "(c) post-reset counter $(counter)"
rm -rf "$T"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
