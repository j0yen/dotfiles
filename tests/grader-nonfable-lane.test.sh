#!/usr/bin/env bash
# A388: grader-jyenpm-run.sh runs the regrader only on the pinned grader binding (claude-opus-5-5, effort high, Fable refused, drain) and selects
# its account from the NON-Fable lane; every other case fails closed with no model call. Temp HOME/state/store, dummy credentials, a fake
# wm-decide that answers the binding preflight and records the real run; no provider call, no real fleet-token store or account-lane state.
# WRAP=<path> runs other wrapper bytes (RED). AL_ROOT=<tree> takes account-lane.py/fleet-token-lib.sh from it; AL_PY=<file> takes account-lane.py
# from that file (review 11c89fff F3: run against main's AND carbon's installed bytes). The fixture policy is version 1, mode 600 (the installed contract).
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
W="${WRAP:-$D/.local/bin/grader-jyenpm-run.sh}"
ALPY="${AL_PY:-$D/.local/lib/account-lane.py}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
umask 077

H="$T/home"; mkdir -p "$H/.local/lib" "$H/.config/fleet-token/store" "$T/state" "$T/run"
ln -s "$ALPY" "$H/.local/lib/account-lane.py"
ln -s "$D/.local/lib/fleet-token-lib.sh" "$H/.local/lib/fleet-token-lib.sh"
STORE="$H/.config/fleet-token/store"
for a in prim.one prim.two fab.only; do printf 'sk-ant-oat01-DUMMY-%s-0000\n' "${a//./}" > "$STORE/$a"; chmod 600 "$STORE/$a"; done
# fable lane names only fab.only (and prim.one second); nonfable primaries prim.one, prim.two; no reserve
printf '%s\n' '{"version": 1, "lanes": {"fable": {"order": ["fab.only", "prim.one"]}, "nonfable": {"primaries": ["prim.one", "prim.two"], "reserve": []}}}' > "$T/policy.json"
chmod 600 "$T/policy.json"
# fake engine: FAKE_ENGINE=new (default) answers like the A388 engine; old = no --binding (live-gs-931bed9); fablebind / xhigh / nodrain / badjson /
# extrakey = a wrong binding; noprobe = binding ok but a Fable dry-run is NOT refused; wrongmsg = refused with another message.
cat > "$T/wmd" <<'S'
#!/usr/bin/env bash
e="${FAKE_ENGINE:-new}"
echo "$*" >> "$FAKE_LOG"
if [ "$1 ${2:-}" = "regrade --binding" ]; then
  case "$e" in
    old) echo "usage: wm-decide [-h] ... error: unrecognized arguments: --binding" >&2; exit 2 ;;
    fablebind) echo '{"binding": 1, "drain": true, "effort": "high", "model": "claude-fable-5-1", "model_usage_equality": true, "refuses_fable": true}' ;;
    xhigh) echo '{"binding": 1, "drain": true, "effort": "xhigh", "model": "claude-opus-5-5", "model_usage_equality": true, "refuses_fable": true}' ;;
    nodrain) echo '{"binding": 1, "drain": false, "effort": "high", "model": "claude-opus-5-5", "model_usage_equality": true, "refuses_fable": true}' ;;
    badjson) echo '{"binding": 1, "model": "claude-opus-5-5"' ;;
    extrakey) echo '{"binding": 1, "drain": true, "effort": "high", "model": "claude-opus-5-5", "model_usage_equality": true, "refuses_fable": true, "fallback": "fable"}' ;;
    *) echo '{"binding": 1, "drain": true, "effort": "high", "model": "claude-opus-5-5", "model_usage_equality": true, "refuses_fable": true}' ;;
  esac
  exit 0
fi
case " $* " in *" --dry-run "*) case " $* " in *" --model claude-fable-5-1 "*)
  case "$e" in
    noprobe) echo "dry-run: model claude-fable-5-1, limit 100"; exit 0 ;;
    wrongmsg) echo "refused: something else" >&2; exit 2 ;;
    *) echo "refused: regrade refuses Fable model 'claude-fable-5-1': no Fable anywhere (Joe 2026-11-18); the grader model is claude-opus-5-5" >&2; exit 2 ;;
  esac ;; esac ;; esac
f="${WM_DECIDE_TOKEN_FILE:-}"
{ echo "args=$*"; echo "tokfile=$f"; [ -n "$f" ] && echo "mode=$(stat -c %a "$f")" && echo "tok=$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' "$f")"; } > "$FAKE_OUT"
exit "${FAKE_RC:-0}"
S
chmod 700 "$T/wmd"

run() {  # run <label> [VAR=val ...] -- <wrapper args>
  local label="$1"; shift; local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  rm -f "$T/out" "$T/log"
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$H" XDG_RUNTIME_DIR="$T/run" ACCOUNT_LANE_POLICY="$T/policy.json" ACCOUNT_LANE_STATE="$T/state" \
    GJ_STORE="$STORE" GJ_WMD="$T/wmd" FAKE_OUT="$T/out" FAKE_LOG="$T/log" "${envs[@]}" bash "$W" "$@" > "$T/$label.stdout" 2> "$T/$label.stderr"
  echo $? > "$T/$label.rc"
}
rc() { cat "$T/$1.rc"; }
got() { sed -n "s/^$1=//p" "$T/out" 2>/dev/null; }
lanestate() { ls -A "$T/state" 2>/dev/null | tr '\n' ' '; }
exhaust() {  # exhaust <acct|lane>...
  python3 -I - "$T/state/state.json" "$@" <<'P'
import json, os, sys, time
ex = {k: {"since": int(time.time()) - 60, "reset_at": None} for k in sys.argv[2:]}
json.dump({"version": 1, "exhausted": ex}, open(sys.argv[1], "w"))
os.chmod(sys.argv[1], 0o600)
P
}
GOOD=(regrade --backlog --include-tooling --limit 50 --drain)

# 1. normal selection: a nonfable primary, never the Fable-lane head, token passed by a 0600 file that is gone afterwards
run sel -- "${GOOD[@]}"
acct_tok="$(got tok)"
if [ "$(rc sel)" = 0 ] && { [ "$acct_tok" = "sk-ant-oat01-DUMMY-primone-0000" ] || [ "$acct_tok" = "sk-ant-oat01-DUMMY-primtwo-0000" ]; }; then ok "1 nonfable primary selected"; else bad "1 nonfable primary selected (rc=$(rc sel) tok=$acct_tok stderr=$(cat "$T/sel.stderr"))"; fi
[ "$acct_tok" != "sk-ant-oat01-DUMMY-fabonly-0000" ] && ok "1b Fable-lane head fab.only not used" || bad "1b Fable-lane head fab.only used"
[ "$(got mode)" = 600 ] && ok "1c token file mode 600" || bad "1c token file mode $(got mode)"
tf="$(got tokfile)"; [ -n "$tf" ] && [ ! -e "$tf" ] && ok "1d token file removed on exit" || bad "1d token file left: $tf"
grep -q "DUMMY" "$T/sel.stdout" "$T/sel.stderr" && bad "1e token printed" || ok "1e token never printed"
grep -qi "non-Fable lane account" "$T/sel.stderr" && ! grep -qi "Fable lane account" <(grep -vi "non-Fable" "$T/sel.stderr") && ok "1f neutral account line" || bad "1f account line: $(cat "$T/sel.stderr")"
[ "$(got args)" = "regrade --backlog --include-tooling --limit 50 --drain --model claude-opus-5-5" ] && ok "1g args passed unchanged plus the explicit binding model" || bad "1g args: $(got args)"
[ "$(sed -n 1p "$T/log")" = "regrade --binding" ] && [ "$(sed -n 2p "$T/log")" = "regrade --model claude-fable-5-1 --dry-run" ] && [ "$(wc -l < "$T/log")" = 3 ] \
  && ok "1h preflight order: --binding, then the Fable refusal probe, then one real run" || bad "1h engine calls: $(tr '\n' '|' < "$T/log")"

# 2. wm-decide's rc is returned
run rcpass FAKE_RC=3 -- "${GOOD[@]}"
[ "$(rc rcpass)" = 3 ] && ok "2 wm-decide rc returned" || bad "2 rc=$(rc rcpass)"

# 3. every nonfable primary exhausted, no reserve: refuse 75, wm-decide never runs, no fallback to the Fable-lane account
exhaust "prim.one|nonfable" "prim.two|nonfable"
run exh -- "${GOOD[@]}"
[ "$(rc exh)" = 75 ] && [ ! -e "$T/out" ] && ok "3 lane exhausted -> 75, no call" || bad "3 rc=$(rc exh) out=$( [ -e "$T/out" ] && cat "$T/out") $(cat "$T/exh.stderr")"
# 3b. one primary exhausted: the other one is used
exhaust "prim.one|nonfable"
run one -- "${GOOD[@]}"
[ "$(rc one)" = 0 ] && [ "$(got tok)" = "sk-ant-oat01-DUMMY-primtwo-0000" ] && ok "3b exhausted primary skipped" || bad "3b rc=$(rc one) tok=$(got tok) $(cat "$T/one.stderr")"
# 3c. Fable-lane exhaustion of an account does not touch its non-Fable allowance
exhaust "prim.one|fable" "prim.two|fable" "fab.only|fable"
run fx -- "${GOOD[@]}"
[ "$(rc fx)" = 0 ] && ok "3c Fable-lane exhaustion ignored for the nonfable lane" || bad "3c rc=$(rc fx) $(cat "$T/fx.stderr")"
rm -f "$T/state/state.json"

# 4. selected account has no credential in the store: refuse 66, no call
mv "$STORE/prim.one" "$T/prim.one.saved"; mv "$STORE/prim.two" "$T/prim.two.saved"
run nocred -- "${GOOD[@]}"
[ "$(rc nocred)" = 66 ] && [ ! -e "$T/out" ] && ok "4 missing credential -> 66, no call" || bad "4 rc=$(rc nocred)"
mv "$T/prim.one.saved" "$STORE/prim.one"; mv "$T/prim.two.saved" "$STORE/prim.two"

# 5. unreadable policy: refuse 75, no call, no guess
run nopol ACCOUNT_LANE_POLICY="$T/missing.json" -- "${GOOD[@]}"
[ "$(rc nopol)" = 75 ] && [ ! -e "$T/out" ] && ok "5 unreadable policy -> 75, no call" || bad "5 rc=$(rc nopol)"

# 6. GJ_ACCOUNT pin: permitted nonfable account used; Fable-only account refused 77; exhausted account refused 77
run pin GJ_ACCOUNT=prim.two -- "${GOOD[@]}"
[ "$(rc pin)" = 0 ] && [ "$(got tok)" = "sk-ant-oat01-DUMMY-primtwo-0000" ] && ok "6 permitted pin used" || bad "6 rc=$(rc pin) tok=$(got tok) $(cat "$T/pin.stderr")"
run pinf GJ_ACCOUNT=fab.only -- "${GOOD[@]}"
[ "$(rc pinf)" = 77 ] && [ ! -e "$T/out" ] && ok "6b Fable-only account pin refused" || bad "6b rc=$(rc pinf)"
exhaust "prim.two|nonfable"
run pine GJ_ACCOUNT=prim.two -- "${GOOD[@]}"
[ "$(rc pine)" = 77 ] && [ ! -e "$T/out" ] && ok "6c exhausted account pin refused" || bad "6c rc=$(rc pine)"
rm -f "$T/state/state.json"

# 7. a Fable argument is refused before any engine call, account read or run (review F1: any case-insensitive substring)
for m in claude-fable-5-1 Fable --model=claude-fable-5-1 fable-5-2 "Fable 5.1" us.anthropic.claude-fable-5-1 anthropic/claude-fable-5-1; do
  run fab -- regrade --model "$m" --limit 50
  [ "$(rc fab)" = 64 ] && [ ! -e "$T/out" ] && [ ! -s "$T/log" ] && ok "7 Fable argument '$m' refused before any engine call" || bad "7 '$m' rc=$(rc fab)"
done

# 8. the runtime dir holds no leftover token file
[ -z "$(ls -A "$T/run" 2>/dev/null)" ] && ok "8 no token file left in the runtime dir" || bad "8 runtime dir: $(ls -A "$T/run")"

# 9. (Hermes 2026-11-20) --max-batches is an agent-imposed overall ceiling: the wrapper refuses it, before any engine call
for a in "--max-batches 40" "--max-batches=40"; do
  run mb -- regrade --backlog --include-tooling --limit 50 $a
  [ "$(rc mb)" = 64 ] && [ ! -e "$T/out" ] && [ ! -s "$T/log" ] && grep -q "drain" "$T/mb.stderr" && ok "9 '$a' refused (64), no engine call" || bad "9 '$a' rc=$(rc mb) $(cat "$T/mb.stderr")"
done

# 10. the wrapper owns the model binding: a caller --model (even the approved id) is refused, before any engine call
for a in "--model claude-opus-5-5" "--model=claude-sonnet-5-5" "--model opus"; do
  run cm -- regrade --limit 50 $a
  [ "$(rc cm)" = 64 ] && [ ! -e "$T/out" ] && [ ! -s "$T/log" ] && ok "10 caller '$a' refused (64)" || bad "10 '$a' rc=$(rc cm)"
done

# 11. (review F2) engine preflight: every engine that is not the pinned binding fails closed with 78, before any account read, with no real run
rm -rf "$T/state"; mkdir -p "$T/state"
for e in old fablebind xhigh nodrain badjson extrakey noprobe wrongmsg; do
  run pf FAKE_ENGINE=$e -- "${GOOD[@]}"
  [ "$(rc pf)" = 78 ] && [ ! -e "$T/out" ] && [ -z "$(lanestate)" ] && ! grep -q "DUMMY" "$T/pf.stdout" "$T/pf.stderr" \
    && ok "11 engine '$e' refused (78): no run, no account-lane state touched" || bad "11 '$e' rc=$(rc pf) out=$([ -e "$T/out" ] && cat "$T/out") state=$(lanestate) $(cat "$T/pf.stderr")"
  [ "$e" = old ] && { [ "$(wc -l < "$T/log")" = 1 ] && ok "11b old engine: only the --binding preflight ran" || bad "11b old engine calls: $(tr '\n' '|' < "$T/log")"; }
done

# 12. (review b0e9b031 F4/N3) the engine's argparse accepts unambiguous prefixes (--max -> --max-batches, --mo -> --model): the wrapper passes only
# the exact approved invocation. Every abbreviated or hostile form, with and without --drain, is refused (64) before any engine run or account read.
rm -rf "$T/state"; mkdir -p "$T/state"
for a in "--max 2" "--max-b=2" "--max-batch 2" "--max-bat 2" "--max-ba=3" "--ma 2" "--m 2" "--max-batches 2" "--max-batches=2" \
         "--mo claude-haiku-5-5" "--mod=claude-opus-5-5" "--drai" "--backlog=1" "--include-tooling=yes" "--dry-run" "--since 2026-01-01" \
         "--reset-breaker" "--binding" "--bind" "-h" "--class seat" "--limit abc" "--limit 0" "--limit 050" "--limit" "--limit --max" "--limit=" "-- --max-batches 2" "--"; do
  for d in with without; do
    if [ "$d" = with ]; then run hz -- regrade --backlog --include-tooling --drain $a; else run hz -- regrade --backlog --include-tooling $a; fi
    [ "$(rc hz)" = 64 ] && [ ! -e "$T/out" ] && [ ! -s "$T/log" ] && [ -z "$(lanestate)" ] && ! grep -q "lane account" "$T/hz.stderr" \
      && ok "12 '$a' ($d --drain) refused (64): no engine run, no account read" || bad "12 '$a' ($d --drain) rc=$(rc hz) log=$(tr '\n' '|' < "$T/log" 2>/dev/null) state=$(lanestate) $(cat "$T/hz.stderr")"
  done
done
run he -- regrade --drain ""
[ "$(rc he)" = 64 ] && [ ! -e "$T/out" ] && [ ! -s "$T/log" ] && [ -z "$(lanestate)" ] && ok "12 an empty argument refused (64)" || bad "12 empty argument rc=$(rc he)"
for args in "list --json" "regrade" "regrade --backlog --include-tooling --limit 50" "regrade regrade --drain" "-- regrade --drain" "verdict --drain" "--drain regrade"; do
  run hs -- $args
  [ "$(rc hs)" = 64 ] && [ ! -e "$T/out" ] && [ ! -s "$T/log" ] && [ -z "$(lanestate)" ] && ok "12b '$args' refused (64): no engine run, no account read" || bad "12b '$args' rc=$(rc hs) $(cat "$T/hs.stderr")"
done

# 13. the exact approved forms still pass, with the explicit binding model appended last; the 99z ExecStart arguments are read from the drop-in itself
z99="$D/.config/systemd/user/swarm-decide-regrade.service.d/99z-grader-release-f8fe.conf"
zargs="$(sed -n 's|^ExecStart=%h/.local/bin/grader-jyenpm-run.sh ||p' "$z99")"
[ -n "$zargs" ] && ok "13 99z ExecStart arguments read from the drop-in: $zargs" || bad "13 no ExecStart arguments in $z99"
for args in "regrade --drain" "regrade --backlog --include-tooling --limit 50 --drain" "regrade --drain --limit=50 --backlog" "$zargs"; do
  run al -- $args
  [ "$(rc al)" = 0 ] && [ "$(got args)" = "$args --model claude-opus-5-5" ] && ok "13 '$args' accepted, run as given plus --model claude-opus-5-5" || bad "13 '$args' rc=$(rc al) args=$(got args) $(cat "$T/al.stderr")"
done

echo "COUNTS: pass=$pass fail=$fail"
[ "$fail" = 0 ]
