#!/usr/bin/env bash
# analysis-route_lib.sh: shared harness for tests/analysis-route_ac0N_*.test.sh (A1300 E13, PRD analysis-skills-nonfable-route).
# D = this checkout (fixtures, launcher harness); R = the tree under test (AR_ROOT=<tree> reruns a test on another checkout's bytes,
# e.g. f9066716 for the red-at-base runs or a mutant). Each test names which of its files come from R. Private HOME, decisions log,
# ledger-id file, lane state, token store and spy CLI; no provider call, no real decisions log, lane state or credential.
set -u
unset SKILL_ROUTE_ROLE SKILL_ROUTE_SESSION SKILL_ROUTE_SCOPE_ID SKILL_ROUTE_TASK_ID SKILL_ROUTE_SKILL SKILL_ROUTE_ROUTE SKILL_ROUTE_EFFORT \
  SKILL_ROUTE_TERMINAL SKILL_ROUTE_RESOLVER SKILL_ROUTE_POLICY SKILL_ROUTE_LEDGER_IDS SKILL_ROUTE_LIB SKILL_POLICY_LIB SKILL_ROUTING_DECISIONS \
  FABLE_LAUNCH_ACCOUNT FABLE_LAUNCH_MODEL FABLE_LAUNCH_ACK_UNKNOWN_EFFECT FABLE_LAUNCH_EFFORT_REASON ANALYSIS_WIKI_DIR SKILL_MARKER_DIR SKILL_TTL_MIN
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; R="${AR_ROOT:-$D}"; R="$(cd "$R" && pwd)"
AF="$D/tests/fixtures/analysis-route"
T="$(mktemp -d)"; AR_BG=()
ar_cleanup(){ local q; for q in "${AR_BG[@]}"; do kill "$q" 2>/dev/null; done; wait 2>/dev/null; chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap ar_cleanup EXIT
export HOME="$T/home"; mkdir -p "$HOME"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; return 1; fi; }
ar_end(){ echo "pass=$p fail=$f (tree under test: $R)"; [ "$f" = 0 ] && echo ALL PASS; [ "$f" = 0 ]; }
uuid(){ cat /proc/sys/kernel/random/uuid; }
printf 'A1300\n' >"$T/ids.txt"; echo evidence >"$T/ev.md"
EVJ='["ledger:A1300","file:'"$T"'/ev.md"]'
OPUS=claude-opus-5-5; FABLE=claude-fable-5-1; SONNET=claude-sonnet-5-5

# The vendored f9066716 fixtures: present and byte-exact, or the calling check FAILS (never a skip).
AR_SHA_RES=088dd2ec89627541dda79ff08bc03d72b99d2a609a24aa62629fa487cb46d055
AR_SHA_POL=a5b27682b5787d4b12edc77e0e228e26d2cb2255d5c429a0345be859836bd388
AR_SHA_GATE=f11751ecf35a1d9b5ba106aa099a48ccb626bfc10d625b933eb3f5c8448d8a6a
BRES="$AF/f9066716-skill-route-resolve.py"; BPOL="$AF/f9066716-policy.json"; BGATE="$AF/f9066716-analysis-page-gate.sh"
ar_sha(){ [ -f "$1" ] && [ "$(sha256sum <"$1" | cut -c1-64)" = "$2" ]; }
ar_fixtures_ok(){ ar_sha "$BRES" "$AR_SHA_RES" && ar_sha "$BPOL" "$AR_SHA_POL" && ar_sha "$BGATE" "$AR_SHA_GATE"; }

# ar_res POLICY RESOLVER JSON: resolve with a private HOME and ledger-id file; output in $T/res.out, exit code in AR_RC.
ar_res(){ printf '%s' "$3" | env -u SKILL_ROUTE_POLICY HOME="$T/home" SKILL_ROUTE_LEDGER_IDS="$T/ids.txt" python3 -I "$2" --policy "$1" >"$T/res.out" 2>/dev/null; AR_RC=$?; }
# ar_q NAME WANT_RC JSON JQ_ASSERT [POLICY [RESOLVER]]: one resolver check (default: the tree under test).
ar_q(){ local q_want="$2" q_as="$4"; ar_res "${5:-$R/.config/skill-routing/policy.json}" "${6:-$R/.local/lib/skill-route-resolve.py}" "$3"
  ck "$1" '[ "$AR_RC" = "$q_want" ] && { [ -z "$q_as" ] || jq -e "$q_as" "$T/res.out" >/dev/null 2>&1; }' || echo "  rc=$AR_RC out=$(head -c 400 "$T/res.out")"; }

# Launcher harness (the skill-launch-route / fable-launch-review seams): ar_launcher_env ROOT selects ROOT's launcher, resolver, policy.
ar_launcher_env(){
  AR_L="$1/.local/bin/fable-launch.sh"
  mkdir -p "$T/store"; printf 'TOKEN-JOSEPH-xxxxxxxx' >"$T/store/josephsyen"; printf 'TOKEN-TECH-zzzzzzzz' >"$T/store/jyen.tech"
  printf 'TOKEN-PM-yyyyyyyy' >"$T/store/jyen.pm"; printf 'TOKEN-MCP-wwwwwwww' >"$T/store/mcphost.dev"; chmod 600 "$T/store"/*
  cat >"$T/claude" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; TOKEN-MCP-*) a=mcphost.dev;; *) a=none;; esac
echo "spy acct=$a task=${SKILL_ROUTE_TASK_ID:-} args=$*" >>"$SPYLOG"
S
  chmod +x "$T/claude"
  export FABLE_RR_DIR="$T/rr" FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log"
  export ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
  export SKILL_ROUTE_POLICY="$1/.config/skill-routing/policy.json" SKILL_ROUTING_DECISIONS="$T/launch.jsonl" SKILL_ROUTE_LEDGER_IDS="$T/ids.txt"
}
# ar_launch NAME REQUEST_JSON args...: write the request, run the launcher; rc in $T/rc.NAME, stderr $T/err.NAME, spy $T/spy.NAME,
# the rows it appended in $T/new.NAME.
ar_launch(){
  local n="$1" before; printf '%s' "$2" >"$T/req.$n.json"; shift 2
  before="$(cat "$SKILL_ROUTING_DECISIONS" 2>/dev/null | wc -l)"; : >"$T/spy.$n"
  SPYLOG="$T/spy.$n" "$AR_L" --route-request "$T/req.$n.json" "$@" 2>"$T/err.$n"; echo $? >"$T/rc.$n"
  tail -n +"$((before+1))" "$SKILL_ROUTING_DECISIONS" 2>/dev/null >"$T/new.$n"
}
AR_FIELDS='["ts","decision","task_id","skill","route","model","effort","account","session","resume","reasons","role","scope","scope_id"]'
# nonfable / fable lane accounts of the test lane policy
ar_nf(){ jq -r --argjson n "$1" '.lanes.nonfable.primaries | .[$n % length]' "$ACCOUNT_LANE_POLICY"; }
ar_fl(){ jq -r '.lanes.fable.order[0]' "$ACCOUNT_LANE_POLICY"; }
