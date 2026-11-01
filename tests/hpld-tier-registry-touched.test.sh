#!/usr/bin/env bash
# tests/hpld-tier-registry-touched.test.sh: a PR touching the test-registry source set always verifies at the full tier (five-whys 2026-10-27-synthorg-441, mechanism 3),
# and the tier choice is logged on the HPLD LAUNCH row. Stubs gh (PATH-independent via HPLD_GH), wm-decide, aide-verifier.sh, seat-ask.sh, carbon-room.sh, systemctl.
# Cases: registry file beats a GATED row without TIER and one saying TIER=fast, src-only stays fast, GATED TIER=full, gh failure / empty list = files-unknown (full),
# *_support.py glob (nested too), end-to-end suite string + --timeout, ROOM-starved ring, runtime drift ring, malformed contract, the no-drift check against the live contract.
set -u
here=$(cd "$(dirname "$0")" && pwd)
DRV="${DRV:-$here/../.local/bin/hand-pr-land-driver.sh}"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
H1=$(printf 'a%.0s' $(seq 40)); REPO=j0yen/synthorg

setup() {
  T=$(mktemp -d); mkdir -p "$T/bin" "$T/vdir" "$T/state"
  echo '[]' >"$T/rows.json"; : >"$T/events.jsonl"; : >"$T/calls.log"; : >"$T/records.log"; echo 0 >"$T/room.rc"; echo 0 >"$T/gh.rc"; printf 'modified\tsrc/x.py\n' >"$T/files.txt"
  cat >"$T/bin/wm-decide" <<'E'
#!/usr/bin/env python3
import json, os, sys
T = os.environ["T"]; a = sys.argv[1:]
if a[0] == "list":
    sys.stdout.write(open(T + "/rows.json").read())
elif a[0] == "record":
    d = {a[i][2:]: a[i + 1] for i in range(1, len(a) - 1, 2) if a[i].startswith("--")}
    open(T + "/records.log", "a").write(d["what"] + "\n")
    rows = json.load(open(T + "/rows.json"))
    rows.append({"id": "d-rec-%d" % len(rows), "ts": "2099-01-01T00:00:00+00:00", "agent": d["agent"], "kind": d["kind"], "what": d["what"], "gates": None})
    json.dump(rows, open(T + "/rows.json", "w"))
E
  cat >"$T/bin/gh" <<'E'
#!/usr/bin/env bash
echo "gh $*" >>"$T/calls.log"
case "$1 $2" in
  "pr list") cat "$T/prs.json" ;;
  "api repos/"*) rc=$(cat "$T/gh.rc"); [ "$rc" = 0 ] && cat "$T/files.txt"; exit "$rc" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 9 ;;
esac
E
  cat >"$T/bin/aide-verifier.sh" <<'E'
#!/usr/bin/env bash
# supports --timeout (premise grep)
echo "verifier $*" >>"$T/calls.log"
exit 0
E
  printf '#!/usr/bin/env bash\necho "seat-ask $1 $2" >>"$T/calls.log"\n' >"$T/bin/seat-ask.sh"
  printf '#!/usr/bin/env bash\necho room >>"$T/calls.log"; exit "$(cat "$T/room.rc")"\n' >"$T/bin/carbon-room.sh"
  printf '#!/usr/bin/env bash\necho inactive; exit 3\n' >"$T/bin/systemctl"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/rb-merge.sh"
  chmod +x "$T"/bin/*
  python3 - "$T/rows.json" "$1" <<'E'
import json, sys
json.dump([{"id": "g1", "ts": "2026-10-27T01:00:00+00:00", "agent": "r7", "kind": "design", "what": sys.argv[2], "gates": None}], open(sys.argv[1], "w"))
E
  printf '[{"number":41,"headRefOid":"%s","headRefName":"hand/x","isDraft":false,"body":""}]' "$H1" >"$T/prs.json"
}
tick() {   # tick [extra env assignments via MG=<contract path>]
  T="$T" HPLD_STATE_DIR="$T/state" HPLD_VDIR="$T/vdir" HPLD_EVENTS="$T/events.jsonl" HPLD_WMD="$T/bin/wm-decide" HPLD_GH="$T/bin/gh" \
  HPLD_VERIFIER="$T/bin/aide-verifier.sh" HPLD_RBMERGE="$T/bin/rb-merge.sh" HPLD_SEATASK="$T/bin/seat-ask.sh" HPLD_ROOM="$T/bin/carbon-room.sh" \
  HPLD_SYSTEMCTL="$T/bin/systemctl" HPLD_REPOS="$REPO" HPLD_PREMISE_IMPORT_CMD=true HPLD_MERGE_GATE="${MG:-$T/none.json}" HPLD_NOW="${NOW:-}" bash "$DRV" >"$T/out" 2>&1; }
files() { printf "$1" >"$T/files.txt"; }
export T
L() { grep '^verifier launch' "$T/calls.log"; }
FAST='-m "not flaky and not slow"'

# registry file, GATED row without TIER -> full, reason in the record
setup "GATED $REPO#41 COMMIT=$H1 fix"; files 'modified\tsrc/x.py\nmodified\ttests/flaky.yaml\n'; tick
[[ "$(L)" != *"$FAST"* ]] && [[ "$(L)" == *"--timeout 5400"* ]] && grep -q 'HPLD LAUNCH .*tier=full tier_reason=registry:tests/flaky.yaml files=2 ' "$T/records.log" && grep -q 'LAUNCH .*tier_reason=registry:tests/flaky.yaml' "$T/out" && pass "flaky.yaml + GATED without TIER: full suite, --timeout 5400, tier_reason=registry:tests/flaky.yaml, files=2" || bad "flaky.yaml case ($(L); $(cat "$T/records.log"))"
rm -rf "$T"
# e2e: the forced-full launch's suite string has the unfiltered pytest and the PR's own tests
setup "GATED $REPO#41 COMMIT=$H1"; files 'modified\ttests/conftest.py\nmodified\ttests/test_a.py\nremoved\ttests/test_gone.py\n'; tick
[[ "$(L)" == *"uv run pytest -q -p no:cacheprovider tests/conftest.py tests/test_a.py && uv run pytest -q -p no:cacheprovider -n 2"* ]] && [[ "$(L)" != *test_gone* ]] && [[ "$(L)" != *"-m \"not"* ]] && pass "e2e: suite string unfiltered, own tests listed, removed test dropped" || bad "e2e suite ($(L))"
rm -rf "$T"
# precedence: GATED says TIER=fast, registry touched -> full
setup "GATED $REPO#41 COMMIT=$H1 TIER=fast"; files 'modified\tpyproject.toml\n'; tick
[[ "$(L)" != *"$FAST"* ]] && grep -q 'tier_reason=registry:pyproject.toml' "$T/records.log" && pass "GATED TIER=fast + registry touched: full, reason registry" || bad "precedence"
rm -rf "$T"
# src only -> fast/default
setup "GATED $REPO#41 COMMIT=$H1"; tick
[[ "$(L)" == *"$FAST"* ]] && [[ "$(L)" != *--timeout* ]] && grep -q 'tier=fast tier_reason=default files=1 ' "$T/records.log" && pass "src/x.py only: fast, tier_reason=default" || bad "fast default ($(L); $(cat "$T/records.log"))"
rm -rf "$T"
# GATED TIER=full
setup "GATED $REPO#41 COMMIT=$H1 TIER=full"; tick
[[ "$(L)" != *"$FAST"* ]] && grep -q 'tier=full tier_reason=gated ' "$T/records.log" && pass "GATED TIER=full: full, tier_reason=gated" || bad "gated full"
rm -rf "$T"
# gh failure -> full files-unknown; exit-0 empty list too
setup "GATED $REPO#41 COMMIT=$H1"; echo 1 >"$T/gh.rc"; tick
[[ "$(L)" != *"$FAST"* ]] && [[ "$(L)" == *"--timeout 5400"* ]] && grep -q 'tier=full tier_reason=files-unknown files=0 ' "$T/records.log" && pass "gh failure: full, files-unknown" || bad "gh failure ($(L))"
rm -rf "$T"
setup "GATED $REPO#41 COMMIT=$H1"; : >"$T/files.txt"; tick
grep -q 'tier=full tier_reason=files-unknown' "$T/records.log" && pass "exit-0 empty file list: full, files-unknown" || bad "empty list"
rm -rf "$T"
# glob, nested
setup "GATED $REPO#41 COMMIT=$H1"; files 'added\ttests/foo_support.py\n'; tick
grep -q 'tier_reason=registry:tests/foo_support.py' "$T/records.log" && pass "tests/foo_support.py matches the glob" || bad "support glob"
rm -rf "$T"
setup "GATED $REPO#41 COMMIT=$H1"; files 'added\ttests/sub/bar_support.py\n'; tick
grep -q 'tier_reason=registry:tests/sub/bar_support.py' "$T/records.log" && pass "nested *_support.py matches (over-inclusive on purpose)" || bad "nested glob"
rm -rf "$T"
# contract adds a pattern: union
setup "GATED $REPO#41 COMMIT=$H1"; files 'modified\ttests/extra.cfg\n'
printf '{"required_source_set":{"j0yen/synthorg":["tests/flaky.yaml","tests/durations.json","tests/conftest.py","pyproject.toml","tests/*_support.py","tests/extra.cfg"]}}' >"$T/mg.json"; MG="$T/mg.json" tick
grep -q 'tier_reason=registry:tests/extra.cfg' "$T/records.log" && grep -q 'srcset_drift=1' "$T/records.log" && pass "contract-only pattern is honoured (union); launch row carries srcset_drift=1" || bad "union"
[ "$(grep -c '^seat-ask aide' "$T/calls.log")" = 1 ] && MG="$T/mg.json" tick && [ "$(grep -c '^seat-ask aide' "$T/calls.log")" = 1 ] && pass "drift rings aide once per day (second tick silent)" || bad "drift ring"
rm -rf "$T"
# equal contract: no drift, no ring
setup "GATED $REPO#41 COMMIT=$H1"
printf '{"required_source_set":{"j0yen/synthorg":["tests/*_support.py","pyproject.toml","tests/conftest.py","tests/durations.json","tests/flaky.yaml"]}}' >"$T/mg.json"; MG="$T/mg.json" tick
! grep -q 'srcset_drift' "$T/records.log" && ! grep -q '^seat-ask aide' "$T/calls.log" && pass "equal contract: no drift flag, no ring" || bad "equal contract"
rm -rf "$T"
# malformed contract: constant only, logged, no crash
setup "GATED $REPO#41 COMMIT=$H1"; files 'modified\ttests/flaky.yaml\n'; echo '{not json' >"$T/mg.json"; MG="$T/mg.json" tick
grep -q 'merge-gate contract malformed' "$T/out" && grep -q 'tier_reason=registry:tests/flaky.yaml' "$T/records.log" && pass "malformed contract: logged, constant set still forces full, no crash" || bad "malformed contract"
rm -rf "$T"
# ROOM starvation of a forced-full launch: first NO starts the clock, > 30 min later rings the owner once; a fast launch never rings
setup "GATED $REPO#41 COMMIT=$H1"; files 'modified\ttests/flaky.yaml\n'; echo 3 >"$T/room.rc"
NOW=1790000000 tick; NOW=1790000600 tick
[ "$(grep -c '^seat-ask' "$T/calls.log")" = 0 ] && pass "ROOM-starved forced-full: no ring inside 30 min" || bad "early room ring"
NOW=1790002000 tick; NOW=1790004000 tick
[ "$(grep -c '^seat-ask r7' "$T/calls.log")" = 1 ] && [ -z "$(L)" ] && pass "ROOM-starved forced-full > 30 min: owner rung once, no launch" || bad "room ring ($(grep '^seat-ask' "$T/calls.log"))"
rm -rf "$T"
setup "GATED $REPO#41 COMMIT=$H1"; echo 3 >"$T/room.rc"; NOW=1790000000 tick; NOW=1790009000 tick
[ "$(grep -c '^seat-ask' "$T/calls.log")" = 0 ] && pass "ROOM-starved fast launch: no ring" || bad "fast room ring"
rm -rf "$T"
# the HPLD LAUNCH row is the only reader surface: nothing in dotfiles parses it, but the old fields stay in place
setup "GATED $REPO#41 COMMIT=$H1"; tick
grep -Eq '^HPLD LAUNCH j0yen/synthorg#41 k=launch:[^ ]+ name=hpl-syn-41-aaaaaaa-1 tier=fast tier_reason=default files=1 gated=g1$' "$T/records.log" && pass "launch row keeps name/tier/gated and appends tier_reason/files" || bad "row shape ($(cat "$T/records.log"))"
rm -rf "$T"

# ---- no-drift: the live swarm-decide contract equals the driver's constant (skipped, saying so, when absent)
LIVE="${HPLD_LIVE_CONTRACT:-$(dirname "$(dirname "$(readlink -f "$(command -v wm-decide 2>/dev/null)" 2>/dev/null)")" 2>/dev/null)/gen/merge-gate.json}"
if [ -f "$LIVE" ] && python3 -I -c 'import json,sys; sys.exit(0 if "required_source_set" in json.load(open(sys.argv[1])) else 1)' "$LIVE" 2>/dev/null; then
  CONST=$(sed -n 's/^SRC_SET = \(.*\)$/\1/p' "$DRV" | head -1)
  python3 -I - "$LIVE" "$CONST" <<'PYE' && pass "no drift: live contract required_source_set == SRC_SET ($LIVE)" || bad "DRIFT: live contract required_source_set differs from SRC_SET in the driver"
import json, sys
live = json.load(open(sys.argv[1]))["required_source_set"]
const = eval(sys.argv[2], {"__builtins__": {}})
sys.exit(0 if {k: sorted(v) for k, v in live.items() if k in const} == {k: sorted(v) for k, v in const.items()} else 1)
PYE
else
  echo "SKIP: no-drift check (no live required_source_set contract at ${LIVE:-<none>}; key arrives with swarm-decide #33)"
fi
# the drift check itself: equal passes, different fails (tmp contracts)
D=$(mktemp -d); CONST=$(sed -n 's/^SRC_SET = \(.*\)$/\1/p' "$DRV" | head -1)
cmp_() { python3 -I - "$1" "$CONST" <<'PYE'
import json, sys
live = json.load(open(sys.argv[1]))["required_source_set"]
const = eval(sys.argv[2], {"__builtins__": {}})
sys.exit(0 if {k: sorted(v) for k, v in live.items() if k in const} == {k: sorted(v) for k, v in const.items()} else 1)
PYE
}
python3 -I -c 'import json,sys; c=eval(sys.argv[1],{"__builtins__":{}}); json.dump({"required_source_set":c}, open(sys.argv[2],"w"))' "$CONST" "$D/eq.json"
python3 -I -c 'import json,sys; c=eval(sys.argv[1],{"__builtins__":{}}); c["j0yen/synthorg"]=c["j0yen/synthorg"][:-1]; json.dump({"required_source_set":c}, open(sys.argv[2],"w"))' "$CONST" "$D/ne.json"
cmp_ "$D/eq.json" && ! cmp_ "$D/ne.json" && pass "no-drift check: equal passes, different fails" || bad "no-drift check logic"
rm -rf "$D"

[ "$fail" = 0 ] && echo ALL PASS || { echo SOME FAIL; exit 1; }
