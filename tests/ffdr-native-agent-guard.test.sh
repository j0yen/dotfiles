#!/usr/bin/env bash
# ffdr-native-agent-guard.test.sh: A1300 FFDR spec r2 (test T6, R5). The native agent guard takes the parent's lane from launch provenance:
# FABLE_LAUNCH_MODEL decides it (account-lane lane_of grammar: `fable` or `claude-fable-<suffix>`, any case), never the account's current
# lane membership. A Fable parent denies a non-Fable or omitted-model native child and allows a Fable child at high; any other parent allows
# non-Fable children and denies a Fable child; a worker fable-launch.sh started keeps the verdict of its launch model after the lane policy
# moves its account to the other lane, and an account listed in both lanes follows the model; FABLE_LAUNCH_ACCOUNT set with
# FABLE_LAUNCH_MODEL empty denies every Agent call (fail closed); neither set keeps today's behaviour; no deny text and no header line names
# an account; the guard reads no policy (the same verdicts under an absent, a contradicting and an every-account-in-both-lanes policy).
# Hermetic: spy CLI, private HOME, lane state and lane policy (fable-launch-review_lib.sh), dummy tokens; no provider call.
# Run alone: bash tests/ffdr-native-agent-guard.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
G="$D/.claude/hooks/fable-native-agent-guard.sh"; AL="$D/.local/lib/account-lane.py"
ACCTS='josephsyen|jyen[.]tech|jyen[.]pm|mcphost[.]dev'
mkdir -p "$T/h0" "$T/h1/.config/account-lanes" "$T/h2/.config/account-lanes"
lp(){ jq -nc --argjson f "$1" --argjson p "$2" '{version:1,lanes:{fable:{order:$f},nonfable:{primaries:$p,reserve:[]}}}'; }
lp '["jyen.tech"]' '["josephsyen"]' >"$T/p1.json"      # P1: jyen.tech serves Fable, josephsyen non-Fable
lp '["josephsyen"]' '["jyen.tech"]' >"$T/p2.json"      # P2: the two accounts swapped lanes
lp '["mcphost.dev"]' '["mcphost.dev"]' >"$T/p3.json"   # P3: one account listed in both lanes
lp '["josephsyen","jyen.tech","jyen.pm","mcphost.dev"]' '["josephsyen","jyen.tech","jyen.pm","mcphost.dev"]' >"$T/both.json"
# pol FILE: install FILE as the lane policy everywhere a policy reader looks (ACCOUNT_LANE_POLICY and the private HOME the guard runs under)
pol(){ cp "$1" "$T/lane-policy.json"; cp "$1" "$T/h1/.config/account-lanes/policy.json"; }
export ACCOUNT_LANE_POLICY="$T/lane-policy.json"; pol "$T/p1.json"; cp "$T/both.json" "$T/h2/.config/account-lanes/policy.json"

# --- the guard alone. pay CHILD EFFORT: an Agent payload ("@" = no model key). gd ACCOUNT MODEL CHILD [EFFORT]: one call, "-" leaves the
# variable unset; prints the hook's output (empty = allowed) and keeps it in $T/all-out. GENV is the environment variant (policy readers).
pay(){ if [ "$1" = @ ]; then jq -nc --arg e "$2" '{tool_name:"Agent",tool_input:{effort:$e,subagent_type:"triage",prompt:"x"}}'
       else jq -nc --arg m "$1" --arg e "$2" '{tool_name:"Agent",tool_input:{model:$m,effort:$e,subagent_type:"coder",prompt:"x"}}'; fi; }
GENV=(HOME="$T/h0")
gd(){ local e=(env -u FABLE_LAUNCH_ACCOUNT -u FABLE_LAUNCH_MODEL -u ACCOUNT_LANE_POLICY "${GENV[@]}")
  [ "$1" = - ] || e+=(FABLE_LAUNCH_ACCOUNT="$1"); [ "$2" = - ] || e+=(FABLE_LAUNCH_MODEL="$2")
  pay "$3" "${4-high}" | "${e[@]}" "$G" | tee -a "$T/all-out"; }
dn(){ grep -q '"permissionDecision":"deny"' <<<"$1"; }
# all VERDICT ACCOUNT MODEL CHILD...: every listed child (at high) gets VERDICT (deny|allow)
all(){ local v="$1" a="$2" m="$3" c o; shift 3; for c in "$@"; do o="$(gd "$a" "$m" "$c")"
  case "$v" in deny) dn "$o" || { echo "  not denied: $a $m $c"; return 1; } ;; allow) [ -z "$o" ] || { echo "  not allowed: $a $m $c: $o"; return 1; } ;; esac; done; }
NF="sonnet haiku opus claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5"

for pm in claude-fable-5-1 fable FABLE Claude-Fable-5-1 'claude-fable-5-1[1m]'; do
  ck "Fable parent by model ($pm, on jyen.tech): every non-Fable child, an empty model and a missing model key are denied" 'all deny jyen.tech "$pm" $NF "" @'
done
ck "Fable parent by model: a Fable child at explicit high is allowed (fable, claude-fable-5-1, Claude-Fable-5-1)" 'all allow jyen.tech claude-fable-5-1 fable claude-fable-5-1 Claude-Fable-5-1'
ck "Fable parent by model: a Fable child at xhigh, max, low or without effort is still denied (unchanged)" '( for e in xhigh max low ""; do dn "$(gd jyen.tech claude-fable-5-1 fable "$e")" || exit 1; done )'
ck "Fable parent: the omitted-model deny names the launcher helper, not an account" 'o="$(gd jyen.tech claude-fable-5-1 "")"; grep -q "needs an explicit Fable model" <<<"$o" && grep -q "fable-launch.sh --helper" <<<"$o"'
ck "Fable parent: the non-Fable deny says a non-Fable account chosen by the launcher" 'grep -q "a non-Fable account chosen by the launcher" <<<"$(gd jyen.tech claude-fable-5-1 sonnet)"'
for pm in claude-opus-5-5 sonnet opus claude-sonnet-5-5; do
  ck "non-Fable parent by model ($pm, on mcphost.dev): non-Fable children, an empty model and a missing model key are allowed" 'all allow mcphost.dev "$pm" $NF "" @'
  ck "non-Fable parent by model ($pm, on mcphost.dev): a Fable child is denied at every effort" 'all deny mcphost.dev "$pm" fable claude-fable-5-1 FABLE && dn "$(gd mcphost.dev "$pm" claude-fable-5-1 xhigh)" && dn "$(gd mcphost.dev "$pm" fable "")"'
done
ck "non-Fable parent: the Fable-child deny points at the launcher and names no account" 'o="$(gd mcphost.dev claude-opus-5-5 claude-fable-5-1)"; grep -q "was not launched on the Fable lane" <<<"$o" && grep -q "fable-launch.sh --model claude-fable-5-1 --effort high" <<<"$o"'

# --- the lane grammar is account-lane's lane_of: the guard's verdict on a sonnet child (deny = Fable parent) matches lane_of for each id
IDS=(fable FABLE Fable claude-fable-5-1 CLAUDE-FABLE-5-1 'claude-fable-5-1[1m]' claude-fable- claude-fable claude-fable5 fablex xfable 'fable ' ' claude-fable-5-1' claude-opus-5-5 sonnet opus)
python3 -I -c 'import importlib.util as u, sys
s = u.spec_from_file_location("al", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
print("\n".join(m.lane_of(x) for x in sys.argv[2:]))' "$AL" "${IDS[@]}" >"$T/lane-of.txt"
: >"$T/guard-lane.txt"; for x in "${IDS[@]}"; do if dn "$(gd jyen.tech "$x" sonnet)"; then echo fable; else echo nonfable; fi >>"$T/guard-lane.txt"; done
ck "lane grammar parity: for ${#IDS[@]} model ids the guard's parent lane equals account-lane lane_of ($(grep -cx fable "$T/lane-of.txt") fable, $(grep -cx nonfable "$T/lane-of.txt") nonfable)" \
  'cmp -s "$T/lane-of.txt" "$T/guard-lane.txt" && grep -qx fable "$T/lane-of.txt" && grep -qx nonfable "$T/lane-of.txt"'

# --- workers fable-launch.sh started (plain launches, spy CLI): the guard runs inside each worker with the environment the launcher exported.
# The spy records FABLE_LAUNCH_ACCOUNT/MODEL, optionally waits for the test to move the lane policy, then asks the guard about a sonnet child
# and a Fable child at high (outputs in $T/spy.NAME.<child>).
cat >"$T/claude6" <<'S'
#!/usr/bin/env bash
echo "spy fla=${FABLE_LAUNCH_ACCOUNT-<unset>} flm=${FABLE_LAUNCH_MODEL-<unset>}" >>"$SPYLOG"
if [ -n "${T6_WAIT:-}" ]; then : >"$T6_DIR/up.$T6_WAIT"; i=0; while [ ! -e "$T6_DIR/go.$T6_WAIT" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done; fi
for c in sonnet claude-fable-5-1; do printf '{"tool_name":"Agent","tool_input":{"model":"%s","effort":"high","subagent_type":"coder","prompt":"x"}}' "$c" | HOME="$T6_DIR/h1" "$T6_G" >"$SPYLOG.$c"; done
exit 0
S
chmod +x "$T/claude6"; export FABLE_CLAUDE_BIN="$T/claude6" T6_DIR="$T" T6_G="$G"
# lw NAME MODEL [WAIT]: one plain launch at high (rc in $T/rc.NAME); wup NAME: wait until that worker is up
lw(){ SPYLOG="$T/spy.$1" T6_WAIT="${3:-}" "$L" --model "$2" --effort high -p x >/dev/null 2>"$T/err.$1"; echo $? >"$T/rc.$1"; }
wup(){ local i=0; while [ ! -e "$T/up.$1" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done; [ -e "$T/up.$1" ]; }
vd(){ if dn "$(cat "$T/spy.$1.$2")"; then echo deny; elif [ -s "$T/spy.$1.$2" ]; then echo other; else echo allow; fi; }
started(){ [ "$(cat "$T/rc.$1")" = 0 ] && grep -qx "spy fla=$2 flm=$3" "$T/spy.$1" && [ "$(jq -r --arg a "$2" '[.sessions[] | select(.account==$a and .model=="'"$3"'")] | length' "$ACCOUNT_LANE_STATE/sessions.json")" -ge 1 ]; }
flr_begin
( lw e1 claude-fable-5-1 e1 ) & E1=$!; FLR_BG+=("$E1"); ( lw e2 claude-opus-5-5 e2 ) & E2=$!; FLR_BG+=("$E2")
wup e1; u1=$?; wup e2; u2=$?
pol "$T/p2.json"; : >"$T/go.e1"; : >"$T/go.e2"; wait "$E1" "$E2"
ck "under P1 the launcher put the Fable worker on jyen.tech (fable lane) and the Opus worker on josephsyen (nonfable lane), both up before the policy moved" \
  '[ "$u1$u2" = 00 ] && started e1 jyen.tech claude-fable-5-1 && started e2 josephsyen claude-opus-5-5 && [ "$(jq -r ".sessions[] | select(.account==\"jyen.tech\") | .lane" "$ACCOUNT_LANE_STATE/sessions.json")" = fable ]'
ck "pinned worker, account now in the other lane (P2 moved jyen.tech to nonfable while it ran): its launch model still decides, sonnet child denied, Fable child at high allowed" \
  '[ "$(vd e1 sonnet) $(vd e1 claude-fable-5-1)" = "deny allow" ]'
ck "pinned worker, account now in the other lane (P2 moved josephsyen to the fable lane while it ran): sonnet child allowed, Fable child denied" \
  '[ "$(vd e2 sonnet) $(vd e2 claude-fable-5-1)" = "allow deny" ]'
lw e3 claude-fable-5-1; lw e4 claude-opus-5-5
ck "the move is real for the lane layer: fresh launches under P2 put Fable on josephsyen and Opus on jyen.tech, and the guard again follows each launch model" \
  'started e3 josephsyen claude-fable-5-1 && started e4 jyen.tech claude-opus-5-5 && [ "$(vd e3 sonnet) $(vd e3 claude-fable-5-1) $(vd e4 sonnet) $(vd e4 claude-fable-5-1)" = "deny allow allow deny" ]'
pol "$T/p3.json"; lw e5 claude-fable-5-1; lw e6 claude-opus-5-5
ck "an account listed in both lanes (P3: mcphost.dev) follows the model: the Fable worker denies sonnet and allows Fable, the Opus worker the reverse" \
  'started e5 mcphost.dev claude-fable-5-1 && started e6 mcphost.dev claude-opus-5-5 && [ "$(vd e5 sonnet) $(vd e5 claude-fable-5-1) $(vd e6 sonnet) $(vd e6 claude-fable-5-1)" = "deny allow allow deny" ]'

# --- incomplete provenance and no provenance
PROV="FABLE_LAUNCH_ACCOUNT is set but FABLE_LAUNCH_MODEL is empty"
ck "account set, model unset: every Agent call is denied with the provenance reason (sonnet, Fable high, empty model, no model key)" \
  '( for c in sonnet claude-fable-5-1 "" @; do o="$(gd jyen.pm - "$c")"; dn "$o" && grep -qF "$PROV" <<<"$o" || exit 1; done )'
ck "account set, model set but empty: the same deny" 'o="$(gd mcphost.dev "" haiku)"; dn "$o" && grep -qF "$PROV" <<<"$o"'
ck "account set, model empty: malformed input fails closed" 'dn "$(printf "not json" | env -u FABLE_LAUNCH_MODEL HOME="$T/h0" FABLE_LAUNCH_ACCOUNT=josephsyen "$G")"'
ck "account set, model empty: jq missing fails closed" 'dn "$(pay sonnet high | env -u FABLE_LAUNCH_MODEL HOME="$T/h0" FABLE_LAUNCH_ACCOUNT=josephsyen PATH="$T/no-such-dir" "$BASH" "$G")"'
ck "account set, model empty: a non-Agent tool is not this guard's business" '[ -z "$(printf "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"x\"}}" | env -u FABLE_LAUNCH_MODEL HOME="$T/h0" FABLE_LAUNCH_ACCOUNT=jyen.pm "$G")" ]'
ck "model set without an account: the model still decides (Fable denies sonnet, allows Fable high; Opus allows sonnet, denies Fable)" \
  'dn "$(gd - claude-fable-5-1 sonnet)" && [ -z "$(gd - claude-fable-5-1 fable)" ] && [ -z "$(gd - claude-opus-5-5 sonnet)" ] && dn "$(gd - claude-opus-5-5 fable)"'
ck "neither set (a session fable-launch.sh did not start): today's behaviour, non-Fable children and an omitted model allowed" 'all allow - - $NF "" @'
ck "neither set: a Fable child is denied and pointed at fable-launch.sh" 'o="$(gd - - fable)"; dn "$o" && grep -q "fable-launch.sh" <<<"$o" && dn "$(gd - - claude-fable-5-1 high)"'
ck "neither set: malformed input and a missing jq fail open (declared residual, unchanged)" '[ -z "$(printf "not json" | env -u FABLE_LAUNCH_ACCOUNT -u FABLE_LAUNCH_MODEL HOME="$T/h0" "$G")" ] && [ -z "$(pay fable high | env -u FABLE_LAUNCH_ACCOUNT -u FABLE_LAUNCH_MODEL HOME="$T/h0" PATH="$T/no-such-dir" "$BASH" "$G")" ]'
ck "Fable parent: malformed input and a missing jq fail closed (unchanged)" 'dn "$(printf "not json" | env HOME="$T/h0" FABLE_LAUNCH_ACCOUNT=jyen.tech FABLE_LAUNCH_MODEL=claude-fable-5-1 "$G")" && dn "$(pay fable high | env HOME="$T/h0" FABLE_LAUNCH_ACCOUNT=jyen.tech FABLE_LAUNCH_MODEL=claude-fable-5-1 PATH="$T/no-such-dir" "$BASH" "$G")"'

# --- no policy read: the same verdict bytes for a grid of parents and children under no policy, a policy that swaps every lane, and a policy
# with every account in both lanes (each set at ACCOUNT_LANE_POLICY and at the private HOME's ~/.config/account-lanes/policy.json)
grid(){ local a m c; for a in jyen.pm jyen.tech josephsyen mcphost.dev -; do for m in claude-fable-5-1 claude-opus-5-5 -; do for c in sonnet claude-fable-5-1 @; do
  printf '%s %s %s\t%s\n' "$a" "$m" "$c" "$(gd "$a" "$m" "$c")"; done; done; done; }
GENV=(HOME="$T/h0"); grid >"$T/grid0"
pol "$T/p2.json"; GENV=(HOME="$T/h1" ACCOUNT_LANE_POLICY="$T/p2.json"); grid >"$T/grid1"
GENV=(HOME="$T/h2" ACCOUNT_LANE_POLICY="$T/both.json"); grid >"$T/grid2"; GENV=(HOME="$T/h0")
ck "no policy read: 45 parent/child verdicts are byte-identical with no policy, a lane-swapping policy and an every-account-in-both-lanes policy" \
  '[ "$(wc -l <"$T/grid0")" = 45 ] && cmp -s "$T/grid0" "$T/grid1" && cmp -s "$T/grid0" "$T/grid2" && grep -q deny "$T/grid0" && grep -qP "\t$" "$T/grid0"'
ck "no policy read (static): the guard's code lines name no policy, lane state, account-lane, HOME, .config or python" '! grep -v "^[[:space:]]*#" "$G" | grep -qE "policy|ACCOUNT_LANE|account-lane|HOME|[.]config|python"'

# --- no account named anywhere
ck "no deny text names an account ($(grep -c deny "$T/all-out") deny outputs collected, from this file's calls and the grids)" '[ "$(grep -c deny "$T/all-out")" -ge 60 ] && ! grep -qE "$ACCTS" "$T/all-out" && ! cat "$T"/grid* "$T"/spy.e*.* | grep -qE "\"permissionDecisionReason\":\"[^\"]*($ACCTS)"'
ck "the guard file (header and code) names no account and documents the provenance rule" '! grep -qE "$ACCTS" "$G" && grep -q "the parent.s lane comes from launch provenance" "$G" && grep -q "FABLE_LAUNCH_ACCOUNT set with FABLE_LAUNCH_MODEL empty" "$G"'
ck "no token in stderr, spy output or any guard output" '! grep -q TOKEN- "$T"/err.* "$T"/spy.* "$T/all-out"'
flr_end
