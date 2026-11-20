#!/usr/bin/env bash
# A388: grader-jyenpm-run.sh selects the regrader's account from the NON-Fable lane and fails closed. Temp HOME/state/store, dummy credentials,
# a fake wm-decide that only records what it received; no provider call, no real fleet-token store or account-lane state is read or written.
# WRAP=<path> runs other wrapper bytes (the RED run against the carbon-live copy). AL_ROOT=<tree> takes account-lane.py/fleet-token-lib.sh from it.
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
W="${WRAP:-$D/.local/bin/grader-jyenpm-run.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

H="$T/home"; mkdir -p "$H/.local/lib" "$H/.config/fleet-token/store" "$T/state" "$T/run"
ln -s "$D/.local/lib/account-lane.py" "$H/.local/lib/account-lane.py"
ln -s "$D/.local/lib/fleet-token-lib.sh" "$H/.local/lib/fleet-token-lib.sh"
STORE="$H/.config/fleet-token/store"
for a in prim.one prim.two fab.only; do printf 'sk-ant-oat01-DUMMY-%s-0000\n' "${a//./}" > "$STORE/$a"; chmod 600 "$STORE/$a"; done
# fable lane names only fab.only (and prim.one second); nonfable primaries prim.one, prim.two; no reserve
printf '%s\n' '{"lanes": {"fable": {"order": ["fab.only", "prim.one"]}, "nonfable": {"primaries": ["prim.one", "prim.two"], "reserve": []}}}' > "$T/policy.json"
cat > "$T/wmd" <<'S'
#!/usr/bin/env bash
f="${WM_DECIDE_TOKEN_FILE:-}"
{ echo "args=$*"; echo "tokfile=$f"; [ -n "$f" ] && echo "mode=$(stat -c %a "$f")" && echo "tok=$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' "$f")"; } > "$FAKE_OUT"
exit "${FAKE_RC:-0}"
S
chmod +x "$T/wmd"

run() {  # run <label> [VAR=val ...] -- <wrapper args>
  local label="$1"; shift; local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  rm -f "$T/out"
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$H" XDG_RUNTIME_DIR="$T/run" ACCOUNT_LANE_POLICY="$T/policy.json" ACCOUNT_LANE_STATE="$T/state" \
    GJ_STORE="$STORE" GJ_WMD="$T/wmd" FAKE_OUT="$T/out" "${envs[@]}" bash "$W" "$@" > "$T/$label.stdout" 2> "$T/$label.stderr"
  echo $? > "$T/$label.rc"
}
rc() { cat "$T/$1.rc"; }
got() { sed -n "s/^$1=//p" "$T/out" 2>/dev/null; }
exhaust() {  # exhaust <acct|lane>...
  python3 -I - "$T/state/state.json" "$@" <<'P'
import json, sys, time
ex = {k: {"since": int(time.time()) - 60, "reset_at": None} for k in sys.argv[2:]}
json.dump({"version": 1, "exhausted": ex}, open(sys.argv[1], "w"))
P
}

# 1. normal selection: a nonfable primary, never the Fable-lane head, token passed by a 0600 file that is gone afterwards
run sel -- regrade --backlog --include-tooling --limit 50 --max-batches 40
acct_tok="$(got tok)"
if [ "$(rc sel)" = 0 ] && { [ "$acct_tok" = "sk-ant-oat01-DUMMY-primone-0000" ] || [ "$acct_tok" = "sk-ant-oat01-DUMMY-primtwo-0000" ]; }; then ok "1 nonfable primary selected"; else bad "1 nonfable primary selected (rc=$(rc sel) tok=$acct_tok stderr=$(cat "$T/sel.stderr"))"; fi
[ "$acct_tok" != "sk-ant-oat01-DUMMY-fabonly-0000" ] && ok "1b Fable-lane head fab.only not used" || bad "1b Fable-lane head fab.only used"
[ "$(got mode)" = 600 ] && ok "1c token file mode 600" || bad "1c token file mode $(got mode)"
tf="$(got tokfile)"; [ -n "$tf" ] && [ ! -e "$tf" ] && ok "1d token file removed on exit" || bad "1d token file left: $tf"
grep -q "DUMMY" "$T/sel.stdout" "$T/sel.stderr" && bad "1e token printed" || ok "1e token never printed"
grep -qi "non-Fable lane account" "$T/sel.stderr" && ! grep -qi "Fable lane account" <(grep -vi "non-Fable" "$T/sel.stderr") && ok "1f neutral account line" || bad "1f account line: $(cat "$T/sel.stderr")"
[ "$(got args)" = "regrade --backlog --include-tooling --limit 50 --max-batches 40" ] && ok "1g wm-decide args passed unchanged" || bad "1g args: $(got args)"

# 2. wm-decide's rc is returned
run rcpass FAKE_RC=3 -- regrade --limit 50
[ "$(rc rcpass)" = 3 ] && ok "2 wm-decide rc returned" || bad "2 rc=$(rc rcpass)"

# 3. every nonfable primary exhausted, no reserve: refuse 75, wm-decide never runs, no fallback to the Fable-lane account
exhaust "prim.one|nonfable" "prim.two|nonfable"
run exh -- regrade --limit 50
[ "$(rc exh)" = 75 ] && [ ! -e "$T/out" ] && ok "3 lane exhausted -> 75, no call" || bad "3 rc=$(rc exh) out=$( [ -e "$T/out" ] && cat "$T/out")"
# 3b. one primary exhausted: the other one is used
exhaust "prim.one|nonfable"
run one -- regrade --limit 50
[ "$(rc one)" = 0 ] && [ "$(got tok)" = "sk-ant-oat01-DUMMY-primtwo-0000" ] && ok "3b exhausted primary skipped" || bad "3b rc=$(rc one) tok=$(got tok)"
# 3c. Fable-lane exhaustion of an account does not touch its non-Fable allowance
exhaust "prim.one|fable" "prim.two|fable" "fab.only|fable"
run fx -- regrade --limit 50
[ "$(rc fx)" = 0 ] && ok "3c Fable-lane exhaustion ignored for the nonfable lane" || bad "3c rc=$(rc fx) $(cat "$T/fx.stderr")"
rm -f "$T/state/state.json"

# 4. selected account has no credential in the store: refuse 66, no call
mv "$STORE/prim.one" "$T/prim.one.saved"; mv "$STORE/prim.two" "$T/prim.two.saved"
run nocred -- regrade --limit 50
[ "$(rc nocred)" = 66 ] && [ ! -e "$T/out" ] && ok "4 missing credential -> 66, no call" || bad "4 rc=$(rc nocred)"
mv "$T/prim.one.saved" "$STORE/prim.one"; mv "$T/prim.two.saved" "$STORE/prim.two"

# 5. unreadable policy: refuse 75, no call, no guess
run nopol ACCOUNT_LANE_POLICY="$T/missing.json" -- regrade --limit 50
[ "$(rc nopol)" = 75 ] && [ ! -e "$T/out" ] && ok "5 unreadable policy -> 75, no call" || bad "5 rc=$(rc nopol)"

# 6. GJ_ACCOUNT pin: permitted nonfable account used; Fable-only account refused 77; exhausted account refused 77
run pin GJ_ACCOUNT=prim.two -- regrade --limit 50
[ "$(rc pin)" = 0 ] && [ "$(got tok)" = "sk-ant-oat01-DUMMY-primtwo-0000" ] && ok "6 permitted pin used" || bad "6 rc=$(rc pin) tok=$(got tok)"
run pinf GJ_ACCOUNT=fab.only -- regrade --limit 50
[ "$(rc pinf)" = 77 ] && [ ! -e "$T/out" ] && ok "6b Fable-only account pin refused" || bad "6b rc=$(rc pinf)"
exhaust "prim.two|nonfable"
run pine GJ_ACCOUNT=prim.two -- regrade --limit 50
[ "$(rc pine)" = 77 ] && [ ! -e "$T/out" ] && ok "6c exhausted account pin refused" || bad "6c rc=$(rc pine)"
rm -f "$T/state/state.json"

# 7. a Fable argument is refused before any account read or call
for m in claude-fable-5-1 Fable --model=claude-fable-5-1; do
  run fab -- regrade --model "$m" --limit 50
  [ "$(rc fab)" = 64 ] && [ ! -e "$T/out" ] && ok "7 Fable argument '$m' refused" || bad "7 '$m' rc=$(rc fab)"
done

# 8. the real account-lane state dir is never touched (tests point ACCOUNT_LANE_STATE at the temp dir)
[ -z "$(ls -A "$T/run" 2>/dev/null)" ] && ok "8 no token file left in the runtime dir" || bad "8 runtime dir: $(ls -A "$T/run")"

echo "COUNTS: pass=$pass fail=$fail"
[ "$fail" = 0 ]
