#!/usr/bin/env bash
# tests/vibeloop-ctl-claim.test.sh — PRD-vibeloop-operator-claim P0 requirements 1-4, 6, P1 req 6:
# exercises vibeloop-ctl claim/release/who and the claim_gate control-command guard against an
# isolated fixture PRD_DIR (a throwaway git repo, no remote), so pushes fail closed (harmless
# stderr warnings) and the real ~/Documents/PRDs is never touched. Plain bash, no network. Run:
#   bash tests/vibeloop-ctl-claim.test.sh
# from the repo root. Exits nonzero (and prints every failure) if any assertion fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$here/../.local/bin/vibeloop-ctl"

fail=0
assert_eq() { # $1=actual $2=expected $3=case description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=case description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
repo="$work/prds"
git init -q "$repo"
git -C "$repo" config user.email test@test.com
git -C "$repo" config user.name test
mkdir -p "$repo/vibeloop" "$repo/build-queue" "$repo/parked" "$repo/projects"
: > "$repo/vibeloop/ledger.md"
: > "$repo/vibeloop/intent.md"
git -C "$repo" add -A && git -C "$repo" commit -q -m init

export DREAM_PRD_DIR="$repo"
run() { bash "$CTL" "$@" 2>/dev/null; }          # stdout only — pull/push warnings are expected noise
runrc() { bash "$CTL" "$@" >/dev/null 2>&1; echo $?; }

# -- req 1: claim writes operator.json + commits; status shows it first --------------------
out=$(run claim "fixing the gate" --for 2h)
assert_contains "$out" "claimed by" "claim: prints confirmation"
[ -f "$repo/vibeloop/operator.json" ] && echo "ok - claim: operator.json written" || { echo "NOT OK - claim: operator.json missing"; fail=1; }
host=$(python3 -c "import json;print(json.load(open('$repo/vibeloop/operator.json'))['host'])")
assert_eq "$host" "$(hostname)" "claim: operator.json host is this host"
assert_eq "$(git -C "$repo" log -1 --format=%s)" "vibeloop: claim by $(hostname) — fixing the gate" "claim: commit lands"
status=$(run status)
first_line=$(echo "$status" | head -1)
assert_contains "$first_line" "claim:" "status: claim line is first"
assert_contains "$first_line" "fixing the gate" "status: claim line shows the note"

# -- req 2/AC2: a control command from the SAME host proceeds unblocked --------------------
rc=$(runrc goal "same host goal")
assert_eq "$rc" "0" "goal: same-host claim does not block"

# -- simulate another host's claim, then re-check gating ------------------------------------
python3 - "$repo/vibeloop/operator.json" <<'PY'
import json,datetime,sys
now=datetime.datetime.now(datetime.UTC)
d={"host":"carbon","user":"jsy","session_hint":"carbon-x","note":"fixing the gate, 2h",
   "claimed_at":now.strftime("%Y-%m-%dT%H:%M:%SZ"),
   "expires_at":(now+datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")}
json.dump(d, open(sys.argv[1], "w"))
PY
git -C "$repo" add -A && git -C "$repo" commit -q -m "sim: carbon claim"

# -- req 2/AC2: blocked control command exits 3 and changes nothing ------------------------
before_head=$(git -C "$repo" rev-parse HEAD)
rc=$(runrc goal "hostile change")
assert_eq "$rc" "3" "goal: exits 3 under another host's active claim"
after_head=$(git -C "$repo" rev-parse HEAD)
assert_eq "$after_head" "$before_head" "goal: blocked attempt commits nothing"

# -- req 2/AC3: --force proceeds and appends forced-by=<host> ------------------------------
rc=$(runrc goal "forced change" --force)
assert_eq "$rc" "0" "goal --force: proceeds despite another host's claim"
assert_eq "$(git -C "$repo" log -1 --format=%s)" "vibeloop: goal — forced change forced-by=$(hostname)" "goal --force: commit carries forced-by=<host>"

# -- req 3/AC6: read commands are never gated, even under an active foreign claim ----------
rc=$(runrc status)
assert_eq "$rc" "0" "status: unaffected by another host's claim"
rc=$(runrc ledger)
assert_eq "$rc" "0" "ledger: unaffected by another host's claim"

# -- req 1/AC4: an expired claim behaves as unclaimed (unforced proceed) -------------------
python3 - <<PY
import json,datetime
now=datetime.datetime.now(datetime.UTC)
d={"host":"carbon","user":"jsy","session_hint":"carbon-x","note":"stale",
   "claimed_at":(now-datetime.timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ"),
   "expires_at":(now-datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ")}
json.dump(d, open("$repo/vibeloop/operator.json","w"))
PY
git -C "$repo" add -A && git -C "$repo" commit -q -m "sim: expired claim"
rc=$(runrc goal "after expiry unforced")
assert_eq "$rc" "0" "goal: expired claim proceeds unforced"

# -- req 1: release removes the claim; status/who then read 'none' ------------------------
out=$(run release)
assert_contains "$out" "released" "release: confirms"
[ -f "$repo/vibeloop/operator.json" ] && { echo "NOT OK - release: operator.json still present"; fail=1; } || echo "ok - release: operator.json removed"
status=$(run status)
assert_contains "$(echo "$status" | head -1)" "claim: none" "status: no claim after release"

# -- P1 req 6: who prints the claim state + recent operator-attributed commits -------------
who=$(run who)
assert_contains "$who" "claim: none" "who: prints current claim state"
assert_contains "$who" "vibeloop: release claim by $(hostname)" "who: lists the release commit"
assert_contains "$who" "vibeloop: goal — forced change forced-by=$(hostname)" "who: lists the forced goal commit"

# -- operator-summary primitive: operator=<host|none> controls=<8-char digest> ------------
out=$(run operator-summary)
assert_contains "$out" "operator=none" "operator-summary: no active claim reads operator=none"
echo "$out" | grep -qE 'controls=[0-9a-f]{8}$' && echo "ok - operator-summary: controls=<8-char hex digest>" || { echo "NOT OK - operator-summary: bad controls= field: $out"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "all vibeloop-ctl-claim tests passed"
else
  echo "vibeloop-ctl-claim tests FAILED"
fi
exit "$fail"
