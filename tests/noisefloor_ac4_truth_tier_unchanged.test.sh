#!/usr/bin/env bash
# tests/noisefloor_ac4_truth_tier_unchanged.test.sh — PRD-mcphost-seed-noise-floor
# AC4: "Given the truth-tier measure fires after this ships, When its
# command line is captured, Then it is byte-identical to the pre-ship
# invocation (seed, composition, flags unchanged)."
#
# A live end-to-end capture needs a deployed hub; this is the offline half
# (Technical considerations: "fixture test on the constructed command
# line") — it asserts the exact truth-tier `synthorg consume` invocation
# line in .local/bin/vibeloop-measure.sh is still present, byte-for-byte,
# as it was before this PRD landed, and that the new sweep call site never
# touches it (added strictly between the proxy gate and the harness
# probe/truth tier, using its own --tier proxy / Haiku-model flags only).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../.local/bin/vibeloop-measure.sh"

fail=0
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: file does not contain expected text: $2"; fail=1 ;; esac
}
assert_not_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "NOT OK - $3: file unexpectedly contains: $2"; fail=1 ;; *) echo "ok - $3" ;; esac
}

src="$(cat "$script")"

# The truth-tier invocation, copied verbatim from the pre-this-PRD source
# (PRD-mcphost-measure-comparable's req 5/6: fixed seed, pinned
# composition, --strict-segments, --deployed-version, and the optional
# --compare-incumbent flag) — byte-identical seed/composition/flags.
truth_tier_invocation='( cd "$SYN" && SYNTHORG_LLM_MODE=record SYNTHORG_LLM_BACKEND=cli SYNTHORG_LLM_CONCURRENCY="${SYNTHORG_LLM_CONCURRENCY:-4}" ANTHROPIC_MODEL="${SYNTHORG_MODEL_MID:-claude-sonnet-4-6}" SYNTHORG_JUDGE_PROVIDER="${SYNTHORG_JUDGE_PROVIDER:-}" timeout 5400 uv run synthorg consume "$BRIEF" --endpoint "$URL" --out "$out" --seed "$SYNTHORG_SEED" --composition "$COMPOSITION" --strict-segments --deployed-version "$deployed" ${VIBELOOP_COMPARE_INCUMBENT:+--compare-incumbent} ) >> "$LOG" 2>&1; rc=$?'
assert_contains "$src" "$truth_tier_invocation" \
  "truth-tier synthorg consume invocation is byte-identical to the pre-ship line"

# The noise-floor sweep call site must sit strictly between the proxy gate
# call and the harness-probe/truth-tier section, never inside the truth-tier
# invocation itself, and never pass $SYNTHORG_SEED (the truth tier's own
# fixed seed) to the extra legs.
proxy_gate_line='run_proxy_gate "$deployed" "$URL" "$proxy_out" || exit 0'
sweep_call_line='run_noise_floor_sweep "$deployed" "$URL" "$proxy_out/measure.json" "$SYNTHORG_SEED"'
assert_contains "$src" "$proxy_gate_line" "proxy gate call site is unchanged"
assert_contains "$src" "$sweep_call_line" "noise-floor sweep call site is present, right after the proxy gate"

# ordering: the sweep call must come AFTER the proxy gate call and BEFORE
# the truth-tier invocation, never the reverse.
sweep_idx="$(awk -v s="$sweep_call_line" 'index($0,s){print NR; exit}' "$script")"
proxy_line_no="$(awk -v s="$proxy_gate_line" 'index($0,s){print NR; exit}' "$script")"
truth_line_no="$(grep -nF 'timeout 5400 uv run synthorg consume' "$script" | head -1 | cut -d: -f1)"
if [ -n "$proxy_line_no" ] && [ -n "$sweep_idx" ] && [ -n "$truth_line_no" ] \
   && [ "$sweep_idx" -gt "$proxy_line_no" ] && [ "$sweep_idx" -lt "$truth_line_no" ]; then
  echo "ok - sweep call site is strictly between the proxy gate and the truth-tier invocation"
else
  echo "NOT OK - sweep call site ordering is wrong (proxy=$proxy_line_no sweep=$sweep_idx truth=$truth_line_no)"
  fail=1
fi

# the sweep's own synthorg invocation (inside vibeloop-measure-guards.sh)
# must use --tier proxy and the small/Haiku model, never the truth tier's
# mid-tier model or its --strict-segments/--compare-incumbent flags.
guards="$(cat "$here/../.local/lib/vibeloop-measure-guards.sh")"
assert_contains "$guards" '--tier proxy' "noise-floor sweep legs use --tier proxy, same as the gate leg"
assert_contains "$guards" 'SYNTHORG_MODEL_SMALL:-claude-haiku-4-5' \
  "noise-floor sweep legs use the small/Haiku model, never the truth tier's mid-tier model"
assert_not_contains "$guards" '--strict-segments' \
  "noise-floor sweep never passes the truth tier's --strict-segments flag"
assert_not_contains "$guards" '--compare-incumbent' \
  "noise-floor sweep never passes the truth tier's --compare-incumbent flag"

if [ "$fail" -eq 0 ]; then
  echo "all noisefloor_ac4 tests passed"
else
  echo "noisefloor_ac4 tests FAILED"
fi
exit "$fail"
