#!/usr/bin/env bash
# A388 round 3 (review 11c89fff F2): no wrapper/engine pairing ever launches a Fable model. Runs the REAL swarm-decide engines with the swarm-decide
# fake model (tests/fake_claude.py of SD_HEAD) and private state/HOME/store/account-lane state; no provider call.
#   SD_BASE  = a swarm-decide tree WITHOUT the A388 binding (931bed91 = carbon live-gs-931bed9 = the rollback target)
#   SD_HEAD  = a swarm-decide tree WITH it
#   OLD_WRAP = (optional) the pre-A388 wrapper bytes (carbon 7384f63b) for the partial-install pairings
# Without SD_BASE/SD_HEAD the test prints SKIP and exits 0 (dotfiles CI has no swarm-decide tree).
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
W="$D/.local/bin/grader-jyenpm-run.sh"
if [ -z "${SD_BASE:-}" ] || [ -z "${SD_HEAD:-}" ]; then echo "SKIP grader-engine-pairing: set SD_BASE and SD_HEAD to swarm-decide trees"; exit 0; fi
FAKE="$SD_HEAD/tests/fake_claude.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
umask 077
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

H="$T/home"; mkdir -p "$H/.local/lib" "$H/.config/fleet-token/store" "$T/lanes" "$T/run"
ln -s "${AL_PY:-$D/.local/lib/account-lane.py}" "$H/.local/lib/account-lane.py"
ln -s "$D/.local/lib/fleet-token-lib.sh" "$H/.local/lib/fleet-token-lib.sh"
STORE="$H/.config/fleet-token/store"
for a in prim.one prim.two fab.only; do printf 'sk-ant-oat01-DUMMY-%s-0000\n' "${a//./}" > "$STORE/$a"; chmod 600 "$STORE/$a"; done
printf '%s\n' '{"version": 1, "lanes": {"fable": {"order": ["fab.only", "prim.one"]}, "nonfable": {"primaries": ["prim.one", "prim.two"], "reserve": []}}}' > "$T/policy.json"
chmod 600 "$T/policy.json"

newstate() {  # newstate <dir> <n rows>: a private engine state with n pending, gradable rows (seeded through the HEAD tree's store module)
  mkdir -p "$1"; : > "$1/ledger.md"
  WM_DECIDE_STATE="$1/state" WM_DECIDE_LEDGER="$1/ledger.md" HOME="$H" PYTHONDONTWRITEBYTECODE=1 python3 -I - "$SD_HEAD" "$2" <<'P'
import datetime as dt, sys
sys.path.insert(0, sys.argv[1])
from wm_decide import store
db = store.connect(); t0 = dt.datetime.fromisoformat("2026-10-30T08:00:00-07:00")
for i in range(int(sys.argv[2])):
    t = t0 + dt.timedelta(minutes=i); ts = t.isoformat()
    store._insert(db, {"id": "d-20261030-%s-r7-%04x" % (t.strftime("%H%M%S"), i * 7919 % 65536), "ts": ts, "agent": "r7", "via": "r7", "model": "claude-opus-5-5",
        "kind": "other", "target": {"host": "synthorg"}, "what": "stub gated row", "why": "w", "evidence": "e", "reverse": "r", "rule_ids": None,
        "first_verdict": {"by": "controller", "verdict": "CONFIRM", "note": "n", "ts": ts}, "regrade": None, "regrade_attempts": 0,
        "correction": {"required": False}, "tags": [], "outcome": None, "expect_by": None, "gates": None, "session": None, "graded_at": None, "grader": None})
db.commit()
P
}
listing() { (cd "$1" && find . -type f -printf '%p %s %T@\n' | sort); }
calls() { [ -f "$1/state/fake-calls.jsonl" ] && wc -l < "$1/state/fake-calls.jsonl" || echo 0; }
models_called() { [ -f "$1/state/fake-calls.jsonl" ] && python3 -I -c 'import json,sys
print(" ".join(sorted({json.loads(l)["argv"][json.loads(l)["argv"].index("--model")+1] for l in open(sys.argv[1])})))' "$1/state/fake-calls.jsonl"; }
stamps() { WM_DECIDE_STATE="$1/state" WM_DECIDE_LEDGER="$1/ledger.md" HOME="$H" PYTHONDONTWRITEBYTECODE=1 python3 -I - "$SD_HEAD" <<'P'
import sys
sys.path.insert(0, sys.argv[1])
from wm_decide import store
print(" ".join(sorted({"%s/%s" % ((d["regrade"] or {}).get("by"), (d["regrade"] or {}).get("model")) for d in store.list_rows(store.connect())})))
P
}
wrap() {  # wrap <wrapper> <engine tree> <state dir> <label> -- args
  local wr="$1" tree="$2" st="$3" label="$4"; shift 5
  env -i PYTHONDONTWRITEBYTECODE=1 PATH=/usr/local/bin:/usr/bin:/bin HOME="$H" XDG_RUNTIME_DIR="$T/run" ACCOUNT_LANE_POLICY="$T/policy.json" ACCOUNT_LANE_STATE="$T/lanes" \
    GJ_STORE="$STORE" GJ_WMD="$tree/bin/wm-decide" WM_DECIDE_STATE="$st/state" WM_DECIDE_LEDGER="$st/ledger.md" WM_DECIDE_CLAUDE="$FAKE" \
    bash "$wr" "$@" > "$T/$label.out" 2> "$T/$label.err"
  echo $? > "$T/$label.rc"
}
rc() { cat "$T/$1.rc"; }
GOOD=(regrade --backlog --include-tooling --limit 1 --drain)

# P1. new wrapper + base engine (live-gs-931bed9, or a swarm-decide-only rollback): refused 78 before any call or state change
newstate "$T/p1" 3; before="$(listing "$T/p1")"
wrap "$W" "$SD_BASE" "$T/p1" p1 -- "${GOOD[@]}"
[ "$(rc p1)" = 78 ] && [ "$(calls "$T/p1")" = 0 ] && [ "$(listing "$T/p1")" = "$before" ] \
  && ok "P1 new wrapper + base engine: 78, no model call, engine state byte-identical" || bad "P1 rc=$(rc p1) calls=$(calls "$T/p1") $(cat "$T/p1.err")"

# P1b. the review's F2 reproduction: args the base engine fully understands (no --drain). The pre-round-3 wrapper let this request claude-fable-5-1.
# Since review b0e9b031 F4 the wrapper's exact allow-list refuses a call without --drain (64) before the engine preflight even runs.
newstate "$T/p1b" 2; before="$(listing "$T/p1b")"
wrap "$W" "$SD_BASE" "$T/p1b" p1b -- regrade --backlog --include-tooling --limit 1
[ "$(rc p1b)" = 64 ] && [ "$(calls "$T/p1b")" = 0 ] && [ "$(listing "$T/p1b")" = "$before" ] \
  && ok "P1b new wrapper + base engine, legacy args: refused (64), no model call (models requested: none)" || bad "P1b rc=$(rc p1b) calls=$(calls "$T/p1b") models=$(models_called "$T/p1b")"

# P2. new wrapper + base engine + an explicit Fable argument: 64 before the engine is touched
wrap "$W" "$SD_BASE" "$T/p1" p2 -- regrade --model claude-fable-5-1 --backlog
[ "$(rc p2)" = 64 ] && [ "$(calls "$T/p1")" = 0 ] && ok "P2 explicit Fable argument through the new wrapper: 64, no call" || bad "P2 rc=$(rc p2)"

# P3. new wrapper + head engine: drains to empty on the binding model only, rows stamped regrader
newstate "$T/p3" 3
wrap "$W" "$SD_HEAD" "$T/p3" p3 -- "${GOOD[@]}"
[ "$(rc p3)" = 0 ] && [ "$(calls "$T/p3")" = 3 ] && [ "$(models_called "$T/p3")" = claude-opus-5-5 ] && [ "$(stamps "$T/p3")" = "regrader/claude-opus-5-5" ] \
  && ok "P3 new wrapper + head engine: 3 calls on claude-opus-5-5 only, all rows regrader/claude-opus-5-5" || bad "P3 rc=$(rc p3) calls=$(calls "$T/p3") models=$(models_called "$T/p3") stamps=$(stamps "$T/p3") $(tail -3 "$T/p3.err")"

# P4. rollback: the same state, the engine swapped back to base: 78, no call, P3's grades untouched
newrows_before="$(listing "$T/p3")"
WM_DECIDE_STATE="$T/p3/state" WM_DECIDE_LEDGER="$T/p3/ledger.md" HOME="$H" PYTHONDONTWRITEBYTECODE=1 python3 -I - "$SD_HEAD" <<'P' >/dev/null
import sys, datetime as dt
sys.path.insert(0, sys.argv[1])
from wm_decide import store
db = store.connect(); ts = "2026-10-31T09:00:00-07:00"
store._insert(db, {"id": "d-20261031-090000-r7-beef", "ts": ts, "agent": "r7", "via": "r7", "model": "claude-opus-5-5", "kind": "other", "target": {"host": "synthorg"},
    "what": "stub", "why": "w", "evidence": "e", "reverse": "r", "rule_ids": None, "first_verdict": {"by": "controller", "verdict": "CONFIRM", "note": "n", "ts": ts},
    "regrade": None, "regrade_attempts": 0, "correction": {"required": False}, "tags": [], "outcome": None, "expect_by": None, "gates": None, "session": None,
    "graded_at": None, "grader": None})
db.commit()
P
before4="$(listing "$T/p3")"
wrap "$W" "$SD_BASE" "$T/p3" p4 -- "${GOOD[@]}"
[ "$(rc p4)" = 78 ] && [ "$(calls "$T/p3")" = 3 ] && [ "$(listing "$T/p3")" = "$before4" ] \
  && ok "P4 rollback to the base engine with a new pending row: 78, no call, state byte-identical (rollback = stop grading)" || bad "P4 rc=$(rc p4) calls=$(calls "$T/p3")"

# P5. dry-run: the head engine names the binding model with no call; through the wrapper a dry-run is not the approved invocation (F4 allow-list: 64)
newstate "$T/p5" 2
env -i PYTHONDONTWRITEBYTECODE=1 PATH=/usr/local/bin:/usr/bin:/bin HOME="$H" WM_DECIDE_STATE="$T/p5/state" WM_DECIDE_LEDGER="$T/p5/ledger.md" WM_DECIDE_CLAUDE="$FAKE" \
  "$SD_HEAD/bin/wm-decide" regrade --dry-run --backlog --include-tooling --limit 50 > "$T/p5d.out" 2>&1
wrap "$W" "$SD_HEAD" "$T/p5" p5 -- regrade --dry-run --backlog --include-tooling --limit 50
grep -q "^dry-run: model claude-opus-5-5," "$T/p5d.out" && [ "$(rc p5)" = 64 ] && [ "$(calls "$T/p5")" = 0 ] && ! grep -q "lane account" "$T/p5.err" \
  && ok "P5 head engine dry-run: model claude-opus-5-5, no call; the same dry-run through the wrapper: refused (64) before any account read" || bad "P5 rc=$(rc p5) $(head -2 "$T/p5d.out") $(cat "$T/p5.err")"

# P6. the head engine refuses the drain ceiling combination and a non-binding model directly (wrapper bypassed)
newstate "$T/p6" 2
env -i PYTHONDONTWRITEBYTECODE=1 PATH=/usr/local/bin:/usr/bin:/bin HOME="$H" WM_DECIDE_STATE="$T/p6/state" WM_DECIDE_LEDGER="$T/p6/ledger.md" WM_DECIDE_CLAUDE="$FAKE" \
  "$SD_HEAD/bin/wm-decide" regrade --backlog --drain --max-batches 40 > /dev/null 2> "$T/p6.err"; r6=$?
env -i PYTHONDONTWRITEBYTECODE=1 PATH=/usr/local/bin:/usr/bin:/bin HOME="$H" WM_DECIDE_STATE="$T/p6/state" WM_DECIDE_LEDGER="$T/p6/ledger.md" WM_DECIDE_CLAUDE="$FAKE" \
  "$SD_HEAD/bin/wm-decide" regrade --backlog --model "us.anthropic.claude-fable-5-1" > /dev/null 2> "$T/p6b.err"; r6b=$?
[ "$r6:$r6b:$(calls "$T/p6")" = "2:2:0" ] && ok "P6 head engine direct: --drain+--max-batches and a provider-form Fable id refused (rc 2), no call" || bad "P6 $r6:$r6b:$(calls "$T/p6")"

# P9. (review b0e9b031 F4/N3) real wrapper + head engine: every form argparse maps to --max-batches or --model, and every other hostile form, with and
# without --drain, is refused (64) before any engine run, account read or select, state or provider call. The approved 99z form still drains.
lanes() { (cd "$T/lanes" && find . -printf '%p %s %T@\n' | sort | sha256sum); }
newstate "$T/p9" 5
for a in "--max 2" "--max-b=2" "--max-batch 2" "--max-bat 2" "--max-batches 2" "--max-batches=2" "--ma 2" "--mo claude-haiku-5-5" "--mod=claude-opus-5-5" \
         "-- --max-batches 2" "--dry-run" "--drai" "--limit 01"; do
  for d in with without; do
    l0="$(lanes)"; s0="$(listing "$T/p9")"
    if [ "$d" = with ]; then wrap "$W" "$SD_HEAD" "$T/p9" p9 -- regrade --backlog --include-tooling --limit 1 --drain $a; else wrap "$W" "$SD_HEAD" "$T/p9" p9 -- regrade --backlog --include-tooling --limit 1 $a; fi
    [ "$(rc p9)" = 64 ] && [ "$(calls "$T/p9")" = 0 ] && [ "$(lanes)" = "$l0" ] && [ "$(listing "$T/p9")" = "$s0" ] && ! grep -q "lane account" "$T/p9.err" \
      && ok "P9 '$a' ($d --drain) through wrapper + head engine: 64, no call, no account read/select, state unchanged" || bad "P9 '$a' ($d --drain) rc=$(rc p9) calls=$(calls "$T/p9") $(cat "$T/p9.err")"
  done
done
for args in "list --json" "regrade regrade --drain" "verdict --drain"; do
  l0="$(lanes)"; wrap "$W" "$SD_HEAD" "$T/p9" p9b -- $args
  [ "$(rc p9b)" = 64 ] && [ "$(calls "$T/p9")" = 0 ] && [ "$(lanes)" = "$l0" ] && ok "P9b '$args': 64 before any account read" || bad "P9b '$args' rc=$(rc p9b) $(cat "$T/p9b.err")"
done
wrap "$W" "$SD_HEAD" "$T/p9" p9c -- regrade --backlog --include-tooling --limit 1 --drain
[ "$(rc p9c)" = 0 ] && [ "$(calls "$T/p9")" = 5 ] && [ "$(models_called "$T/p9")" = claude-opus-5-5 ] && ok "P9c the approved form drains the same 5 rows (5 calls, claude-opus-5-5 only)" || bad "P9c rc=$(rc p9c) calls=$(calls "$T/p9") $(tail -3 "$T/p9c.err")"

if [ -n "${OLD_WRAP:-}" ]; then
  # P7. partial install, engine first: OLD wrapper + head engine with the old 99z args: never Fable (the engine binds Opus), legacy finite batches
  newstate "$T/p7" 3
  wrap "$OLD_WRAP" "$SD_HEAD" "$T/p7" p7 -- regrade --backlog --include-tooling --limit 1 --max-batches 40
  [ "$(rc p7)" = 0 ] && [ "$(models_called "$T/p7")" = claude-opus-5-5 ] && [ "$(stamps "$T/p7")" = "regrader/claude-opus-5-5" ] \
    && ok "P7 old wrapper + head engine (engine-first window): no Fable call, regrader/claude-opus-5-5; account came from the old Fable-lane selection ($(grep -o 'account [a-z.]*' "$T/p7.err"))" \
    || bad "P7 rc=$(rc p7) models=$(models_called "$T/p7") $(cat "$T/p7.err")"
  # P8. KNOWN-BAD control: today's installed pair (old wrapper + base engine) would call Fable; this is why the unit stays stopped until the new pair is installed
  newstate "$T/p8" 1
  wrap "$OLD_WRAP" "$SD_BASE" "$T/p8" p8 -- regrade --backlog --include-tooling --limit 1
  [ "$(models_called "$T/p8")" = claude-fable-5-1 ] && ok "P8 known-bad control detected: old wrapper + base engine requests claude-fable-5-1 (fake model; the live unit stays stopped)" \
    || bad "P8 known-bad control not detected: models=$(models_called "$T/p8") rc=$(rc p8)"
else
  echo "NOTE P7/P8 not run: OLD_WRAP unset"
fi

echo "COUNTS: pass=$pass fail=$fail"
[ "$fail" = 0 ]
