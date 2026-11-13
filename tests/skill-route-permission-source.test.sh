#!/usr/bin/env bash
# skill-route-permission-source.test.sh: A1300 cont3 edit 2 — one permission_mode source (resolver echo -> launcher --permission-mode).
# Harmless fakes only: temp dirs, fake claude spy, fake token store; no real claude, credential or network.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
p=0; f=0
ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
POL="$R/.config/skill-routing/policy.json"
mkdir -p "$T/h"
# edit 2: one permission_mode source (resolver echo -> launcher --permission-mode)
printf '{"task_id":"t-1","skill":"maxspeed","permission_mode":"plan"}' | env -i PATH="$PATH" HOME="$T/h" SKILL_ROUTE_POLICY="$POL" python3 -I "$R/.local/lib/skill-route-resolve.py" >"$T/ro" 2>&1; rc=$?
ck "edit2 resolver echoes permission_mode" '[ $rc = 0 ] && [ "$(jq -r .permission_mode "$T/ro")" = plan ]'
printf '{"task_id":"t-1","skill":"wwhtbt"}' | env -i PATH="$PATH" HOME="$T/h" SKILL_ROUTE_POLICY="$POL" python3 -I "$R/.local/lib/skill-route-resolve.py" >"$T/ro" 2>&1
ck "edit2 resolver has no permission_mode for a skill without one" '[ "$(jq -r "has(\"permission_mode\")" "$T/ro")" = false ]'
mkdir -p "$T/store"; printf 'TOKEN-JOSEPH-xxxxxxxx' >"$T/store/josephsyen"; printf 'TOKEN-TECH-zzzzzzzz' >"$T/store/jyen.tech"; printf 'TOKEN-PM-yyyyyyyy' >"$T/store/jyen.pm"; chmod 600 "$T/store"/*
printf '#!/usr/bin/env bash\necho "spy args=$*" >>"$SPYLOG"\n' >"$T/claude"; chmod +x "$T/claude"
lrun(){ : >"$T/spy.log"; env FABLE_RR_DIR="$T/rr" FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log" \
  ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$R/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000 \
  SKILL_ROUTE_POLICY="$POL" SKILL_ROUTING_DECISIONS="$T/dec.jsonl" "$R/.local/bin/fable-launch.sh" --route-request "$T/req.json" "$@" 2>"$T/err"; echo $? >"$T/rc"; }
printf '{"task_id":"t-1","skill":"maxspeed","permission_mode":"plan"}' >"$T/req.json"; lrun -p hello
ck "edit2 launcher passes --permission-mode plan from the resolver echo" 'grep -q -- "--permission-mode plan" "$T/spy.log" && [ "$(grep -o -- "--permission-mode" "$T/spy.log" | wc -l)" = 1 ]'
lrun -p hello --permission-mode acceptEdits
ck "edit2 conflicting --permission-mode refused, nothing started" '[ "$(cat "$T/rc")" = 64 ] && [ ! -s "$T/spy.log" ] && grep -q "permission-mode" "$T/err"'
lrun -p hello --permission-mode plan
ck "edit2 matching --permission-mode is not duplicated" '[ "$(cat "$T/rc")" = 0 ] && [ "$(grep -o -- "--permission-mode" "$T/spy.log" | wc -l)" = 1 ]'
printf '{"task_id":"t-2","skill":"wwhtbt"}' >"$T/req.json"; lrun -p hello
ck "edit2 skill without permission_mode gets no --permission-mode flag" '[ "$(cat "$T/rc")" = 0 ] && ! grep -q -- "--permission-mode" "$T/spy.log"'
echo "p=$p f=$f"; [ "$f" = 0 ] && echo "ALL PASS" || exit 1
