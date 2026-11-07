#!/usr/bin/env bash
# account-router.test.sh (A1221): fable-launch.sh round-robin account router, stub claude + stub store, never the real store.
# FABLE_LAUNCH_TEST=1 is the only way the knobs are honored; a production run with any knob set is refused (checked below).
set -u
L="$(cd "$(dirname "$0")/.." && pwd)/.local/bin/fable-launch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: want '$3' got '$2'"; fi; }
mkdir -p "$T/store"; for a in josephsyen jyen.tech jyen.pm; do echo "fake-$a" > "$T/store/$a"; done
printf '#!/usr/bin/env bash\necho "ACCT=$FABLE_LAUNCH_ACCOUNT MODEL=$FABLE_LAUNCH_MODEL ARGS=$*"\n' > "$T/claude"; chmod +x "$T/claude"
run(){ # run <rrdir> args...
  local rr="$1"; shift
  FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" FABLE_RR_DIR="$rr" bash "$L" "$@" 2>/dev/null
}
acct(){ sed -n 's/^ACCT=\([^ ]*\).*/\1/p'; }

# 1 sequential allocations alternate
rr="$T/rr1"; seq=""
for k in 1 2 3 4; do seq="$seq $(run "$rr" --model sonnet -p x | acct)"; done
ok "sequential alternate" "$seq" " josephsyen jyen.tech josephsyen jyen.tech"

# 2 eight concurrent allocations split 4/4
rr="$T/rr2"; mkdir -p "$T/out"
for k in 1 2 3 4 5 6 7 8; do run "$rr" --model haiku -p x | acct > "$T/out/$k" & done; wait
ok "concurrent 4 josephsyen" "$(cat "$T"/out/* | grep -c '^josephsyen$')" 4
ok "concurrent 4 jyen.tech" "$(cat "$T"/out/* | grep -c '^jyen.tech$')" 4

# 3 resume pinned (survives counter movement)
rr="$T/rr3"; S1=11111111-1111-1111-1111-111111111111; S2=22222222-2222-2222-2222-222222222222
a1="$(run "$rr" --model sonnet --session-id $S1 | acct)"; a2="$(run "$rr" --model sonnet --session-id $S2 | acct)"
run "$rr" --model sonnet -p x >/dev/null; run "$rr" --model sonnet -p x >/dev/null
ok "S1 first!=S2 first" "$([ "$a1" != "$a2" ] && echo y)" y
ok "resume S1 pinned" "$(run "$rr" --model sonnet --resume $S1 | acct)" "$a1"
ok "resume S2 pinned" "$(run "$rr" --model sonnet --resume $S2 | acct)" "$a2"
ok "resume does not advance counter" "$(cat "$rr/counter")" 4

# 4 Fable -> jyen.pm, xhigh; never touches the counter
rr="$T/rr4"
o="$(run "$rr" --model claude-fable-5-1 -p x)"
ok "fable acct" "$(printf '%s' "$o" | acct)" jyen.pm
ok "fable xhigh" "$(printf '%s' "$o" | grep -c -- '--effort xhigh')" 1
ok "fable no counter" "$([ -e "$rr/counter" ] && echo y || echo n)" n
ok "fable max refused" "$(FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" FABLE_RR_DIR="$rr" bash "$L" --model fable --effort max -p x >/dev/null 2>&1; echo $?)" 64

# 5 non-Fable never jyen.pm, never fable pool across many models
rr="$T/rr5"; bad=0
for m in sonnet haiku opus claude-sonnet-5-5 claude-opus-5-5 claude-haiku-5-5; do for k in 1 2 3; do
  a="$(run "$rr" --model $m -p x | acct)"; case "$a" in josephsyen|jyen.tech) ;; *) bad=$((bad+1));; esac; done; done
ok "non-fable never jyen.pm" "$bad" 0

# 6 missing jyen.tech credential fails closed: exit 66, no fallback, no output from claude
rm "$T/store/jyen.tech"; rr="$T/rr6"
o="$(run "$rr" --model sonnet -p x; echo "rc=$?")"
ok "first alloc (josephsyen) ok" "$(printf '%s' "$o" | head -1 | acct)" josephsyen
o="$(run "$rr" --model sonnet -p x; echo "rc=$?")"
ok "missing jyen.tech exit 66" "$o" "rc=66"
o="$(run "$rr" --model sonnet -p x; echo "rc=$?")"
ok "still 66 (no skip to josephsyen)" "$o" "rc=66"
S3=33333333-3333-3333-3333-333333333333
printf '%s jyen.tech\n' $S3 >> "$rr/sid-map"
o="$(run "$rr" --model sonnet --resume $S3; echo "rc=$?")"
ok "pinned resume to missing account fails closed" "$o" "rc=66"
echo fake-jyen.tech > "$T/store/jyen.tech"

# 7 production refuses overrides; pinned non-pool account refused
ok "prod refuses FABLE_RR_DIR" "$(FABLE_RR_DIR=$T/x bash "$L" --model sonnet -p x >/dev/null 2>&1; echo $?)" 64
ok "prod refuses FABLE_TOKEN_STORE" "$(FABLE_TOKEN_STORE=$T/store bash "$L" --model sonnet -p x >/dev/null 2>&1; echo $?)" 64
rr="$T/rr7"; mkdir -p "$rr"; S4=44444444-4444-4444-4444-444444444444; printf '%s jyen.pm\n' $S4 > "$rr/sid-map"
ok "sid pinned to jyen.pm refused for non-fable" "$(run "$rr" --model sonnet --resume $S4 >/dev/null; echo $?)" 65

# 8 duplicate --resume refused while a process for the SID is alive
S5=55555555-5555-5555-5555-555555555555
sleep 30 & sp=$!; ( exec -a "claude --resume $S5" sleep 30 ) & dp=$!; sleep 0.3
ok "duplicate resume refused" "$(run "$T/rr8" --model sonnet --resume $S5 >/dev/null; echo $?)" 73
kill $sp $dp 2>/dev/null

echo "account-router: $pass passed, $fail failed"
[ "$fail" = 0 ]
