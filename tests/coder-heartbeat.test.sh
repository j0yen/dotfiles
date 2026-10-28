#!/usr/bin/env bash
# coder-heartbeat hook (503 MECH1a): no var = no file; exact contract keys; no secrets in `what`; ticker proof of
# life (ticks, post stops them, kill -9 of the coder stops them, no orphan); drift vs the vendored contract;
# deadline rules; timing. Each case runs with a mktemp dir as HOME/TMPDIR.
# CODER_HB_TICK_S / CODER_HB_PID are the hook's test-only overrides.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/coder-heartbeat.sh"
vend="$here/.claude/hooks/heartbeat-contract.json"
V1=/home/jsy/.cache/rb-seat/coders/heartbeat-contract.v1.json
V1_SHA=3981f6972240eebc0b0fa34692decbb2640874764a683a00ea0409fba45fd1db
fail=0; pass=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1${2:+ ($2)}"; fail=$((fail+1)); }
check() { if [ "$2" = 1 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

tmp=$(mktemp -d); pids=()
cleanup() {
    for p in "${pids[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
    for f in "$tmp"/*/coder-hb-*.pid; do [ -r "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
    sleep 0.2; rm -rf "$tmp"
}
trap cleanup EXIT
n=0
newenv() { n=$((n+1)); D="$tmp/$n"; mkdir -p "$D"; P="$D/p.jsonl"; }
hk() { # mode json [env...]
    local m=$1 j=$2; shift 2
    printf '%s' "$j" | env -u WM_BUILD_PROGRESS -u RB_CODER_ID HOME="$D" TMPDIR="$D" "$@" bash "$hook" "$m"
}
pre() { printf '{"tool_name":"Bash","tool_input":%s,"tool_use_id":"%s","session_id":"sess1"}' "$1" "$2"; }
lines() { [ -f "$P" ] && wc -l < "$P" || echo 0; }

# (a) no var: no file, rc 0
newenv
hk pre "$(pre '{"command":"ls"}' c1)"; rc=$?
nf=$(find "$D" -type f | wc -l)
check "a-no-var-no-file-rc0" "$([ $rc = 0 ] && [ "$nf" = 0 ] && echo 1)" "rc=$rc files=$nf"

# (b) secrets: one line, exact keys, what=Bash:curl, token absent
newenv
hk pre "$(pre '{"command":"TOK=SECRETX curl -H \"Authorization: Bearer SECRETX\" https://x"}' cb)" WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=100 CODER_HB_PID=$$; rc=$?
keys=$(jq -c 'keys_unsorted' "$P" 2>/dev/null | head -1)
want=$(jq -c '.keys' "$vend")
check "b-one-line" "$([ "$(lines)" = 1 ] && echo 1)" "lines=$(lines)"
check "b-exact-keys" "$([ "$keys" = "$want" ] && echo 1)" "$keys"
check "b-what-first-token" "$([ "$(jq -r .what "$P" | head -1)" = Bash:curl ] && echo 1)"
check "b-no-secret" "$(grep -rq SECRETX "$D" 2>/dev/null && echo 0 || echo 1)"
hk post "$(pre '{"command":"x"}' cb)" WM_BUILD_PROGRESS="$P"

# (c) ticker: >=2 ticks in 3 s; post stops them; no orphan
newenv
sleep 60 & fake=$!; pids+=("$fake")
hk pre "$(pre '{"command":"sleep 20"}' cc)" WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=1 CODER_HB_PID=$fake
sleep 3.2
ticks=$(grep -c 'heartbeat tick' "$P")
check "c-ticks-within-3s" "$([ "$ticks" -ge 2 ] && echo 1)" "ticks=$ticks"
tp=$(cat "$D/coder-hb-cc.pid" 2>/dev/null)
hk post "$(pre '{"command":"sleep 20"}' cc)" WM_BUILD_PROGRESS="$P"
sleep 0.3; before=$(grep -c 'heartbeat tick' "$P"); sleep 2
after=$(grep -c 'heartbeat tick' "$P")
check "c-post-stops-ticks" "$([ "$before" = "$after" ] && echo 1)" "$before->$after"
check "c-no-orphan-ticker" "$(kill -0 "$tp" 2>/dev/null && echo 0 || echo 1)" "pid=$tp"
check "c-pidfile-removed" "$([ ! -e "$D/coder-hb-cc.pid" ] && echo 1)"
check "c-ts-and-since-stable" "$([ "$(jq -s '[.[]|select(.msg|test("tick"))|.since]|unique|length' "$P")" = 1 ] && echo 1)"

# (d) kill -9 the coder mid-call: ticks stop within 2 ticks
newenv
sleep 60 & fake=$!; pids+=("$fake")
hk pre "$(pre '{"command":"sleep 20"}' cd)" WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=1 CODER_HB_PID=$fake
sleep 1.5; kill -9 "$fake"; wait "$fake" 2>/dev/null
sleep 2.2; a=$(grep -c 'heartbeat tick' "$P"); sleep 2.2; b=$(grep -c 'heartbeat tick' "$P")
check "d-kill9-stops-ticks" "$([ "$a" = "$b" ] && echo 1)" "$a->$b"
tp=$(cat "$D/coder-hb-cd.pid" 2>/dev/null)
dead=1; [ -n "$tp" ] && kill -0 "$tp" 2>/dev/null && dead=0
check "d-ticker-exited" "$([ $dead = 1 ] && echo 1)"

# stop ends every ticker of the session
newenv
sleep 60 & fake=$!; pids+=("$fake")
hk pre "$(pre '{"command":"a"}' s1)" WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=5 CODER_HB_PID=$fake
hk pre "$(pre '{"command":"b"}' s2)" WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=5 CODER_HB_PID=$fake
sleep 0.3; t1=$(cat "$D/coder-hb-s1.pid"); t2=$(cat "$D/coder-hb-s2.pid")
hk stop '{"session_id":"sess1"}' WM_BUILD_PROGRESS="$P"
sleep 0.3
alive=0; kill -0 "$t1" 2>/dev/null && alive=1; kill -0 "$t2" 2>/dev/null && alive=1
check "stop-ends-all-tickers" "$([ $alive = 0 ] && echo 1)"
check "stop-line-written" "$(tail -1 "$P" | jq -e '.msg=="heartbeat stop"' >/dev/null 2>&1 && echo 1)"

# (e) garbage stdin: rc 0, no file
newenv
hk pre 'not json {{{' WM_BUILD_PROGRESS="$P"; rc1=$?
hk post '[1,2]' WM_BUILD_PROGRESS="$P"; rc2=$?
check "e-garbage-rc0-no-file" "$([ $rc1 = 0 ] && [ $rc2 = 0 ] && [ ! -e "$P" ] && echo 1)"

# (f) drift: emitted keys == vendored keys; vendored == v1 apart from source; v1 sha pinned
newenv
hk pre "$(pre '{"command":"ls"}' cf)" WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=100 CODER_HB_PID=$$
hk post "$(pre '{"command":"ls"}' cf)" WM_BUILD_PROGRESS="$P"
emitted=$(jq -c 'keys|sort' "$P" | sort -u)
check "f-emitted-keys-equal-contract" "$([ "$emitted" = "$(jq -c '.keys|sort' "$vend")" ] && echo 1)" "$emitted"
if [ -r "$V1" ]; then
    check "f-v1-sha-pinned" "$([ "$(sha256sum "$V1" | cut -d' ' -f1)" = "$V1_SHA" ] && echo 1)"
    check "f-vendored-equals-v1-except-source" "$([ "$(jq -S 'del(.source)' "$vend")" = "$(jq -S 'del(.source)' "$V1")" ] && echo 1)"
else
    echo "SKIP f-v1-compare (v1 source absent on this host)"
fi
check "f-vendored-has-source" "$(jq -e '.source|startswith("j0yen/wm-build docs/heartbeat-contract.json @ ")' "$vend" >/dev/null && echo 1)"

# (g) deadlines
newenv
hk pre "$(pre '{"command":"cargo nextest run","timeout":3600000}' g1)" WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=100 CODER_HB_PID=$$
hk pre "$(pre '{"command":"ls -la"}' g2)" WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=100 CODER_HB_PID=$$
hk pre '{"tool_name":"Agent","tool_input":{"prompt":"x"},"tool_use_id":"g3","session_id":"sess1"}' WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=100 CODER_HB_PID=$$
d1=$(jq -s '.[0]|.deadline-.since' "$P"); d2=$(jq -s '.[1]|.deadline-.since' "$P"); d3=$(jq -s '.[2]|.deadline-.since' "$P")
check "g-nextest-1500" "$([ "$d1" = 1500 ] && echo 1)" "$d1"
check "g-plain-bash-120" "$([ "$d2" = 120 ] && echo 1)" "$d2"
check "g-agent-clamp-3600" "$([ "$d3" = 3600 ] && echo 1)" "$d3"
for c in g1 g2 g3; do hk post "$(pre '{"command":"x"}' $c)" WM_BUILD_PROGRESS="$P"; done

# (h) timing: pre wall time < 200 ms
newenv
s=$(date +%s%N)
hk pre "$(pre '{"command":"ls"}' ch)" WM_BUILD_PROGRESS="$P" CODER_HB_TICK_S=100 CODER_HB_PID=$$
ms=$(( ($(date +%s%N) - s) / 1000000 ))
check "h-pre-under-200ms" "$([ "$ms" -lt 200 ] && echo 1)" "${ms}ms"
hk post "$(pre '{"command":"ls"}' ch)" WM_BUILD_PROGRESS="$P"

# settings wiring
for ev in PreToolUse PostToolUse PostToolUseFailure Stop; do
    check "settings-wires-$ev" "$(jq -e --arg e "$ev" '[.hooks[$e][].hooks[].command]|any(test("coder-heartbeat.sh"))' "$here/.claude/settings.json" >/dev/null && echo 1)"
done

if [ $fail = 0 ]; then echo "PASS coder-heartbeat ($pass checks)"; else echo "FAIL coder-heartbeat ($fail failed, $pass passed)"; fi
exit $((fail != 0))
