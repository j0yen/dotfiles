#!/usr/bin/env bash
# W4 runner hardening: service-state unit must start alphanumeric (no option injection, `--` before the unit); named-test has no built-in kill timer
# (hang guard = explicit owner-set OBL_RUN_TIMEOUT_SEC, default none; Joe 11-01 #195). Sandbox: temp dirs and a stub systemctl, no live write.
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; R="$here/.local/bin/ctl-obligation-run.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
mkdir -p "$T/tests" "$T/bin"
printf '#!/bin/sh\necho "$@" > %s/argv\nexit 0\n' "$T" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
run(){ env PATH="$T/bin:$PATH" OBL_TESTS_DIR="$T/tests" "${@:3}" python3 -I "$R" run --dir "$T/d" --key "$1" --approval '#1' --action "$2"; }
rec(){ python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["status"],r["rc"])' "$T/d/$1.run.json"; }
run k1 '{"verb":"service-state","unit":"-Hevil@host.invalid.service"}'
ck "leading '-' unit refused rc 126" "$(rec k1)" "refused 126"
ck "leading '-' unit never reached systemctl" "$([ -e "$T/argv" ] && echo ran || echo clean)" clean
run k2 '{"verb":"service-state","unit":"ctl-event-bridge.service"}'
ck "good unit runs" "$(rec k2)" "ran 0"
ck "argv carries -- before the unit" "$(cat "$T/argv")" "--user is-active -- ctl-event-bridge.service"
printf '#!/bin/sh\nsleep 3\nexit 0\n' > "$T/tests/slow.test.sh"
run k3 '{"verb":"named-test","name":"slow"}'
ck "named-test with no owner-set guard runs to completion" "$(rec k3)" "ran 0"
run k4 '{"verb":"named-test","name":"slow"}' OBL_RUN_TIMEOUT_SEC=1
ck "owner-set OBL_RUN_TIMEOUT_SEC=1 is honoured (rc 124)" "$(rec k4)" "ran 124"
ck "no hard-coded 600 s kill in the runner" "$(grep -c 'timeout=600' "$R")" 0
rm -f "$T/argv"
run k5 '{"verb":"service-state","unit":"x.service\n"}'
ck "unit with trailing newline refused rc 126" "$(rec k5)" "refused 126"
ck "trailing-newline unit never reached systemctl" "$([ -e "$T/argv" ] && echo ran || echo clean)" clean
printf '#!/bin/sh\necho ran > %s/nl-ran\nexit 0\n' "$T" > "$T/tests/nl.test.sh"; cp "$T/tests/nl.test.sh" "$T/tests/"$'nl\n'".test.sh"
run k6 '{"verb":"named-test","name":"nl\n"}'
ck "name with trailing newline refused rc 126" "$(rec k6)" "refused 126"
ck "trailing-newline name never ran" "$([ -e "$T/nl-ran" ] && echo ran || echo clean)" clean

# ---- UNKNOWN-intent (W4 repair): a dead owner's started record with no receipt is UNKNOWN (rc 75), never a blind takeover. Direct-runner level, scratch dirs only.
# Reconcile uses ONLY the runner's allow-listed typed recipes (stub systemctl), never a caller-supplied command; approvals are read from a scratch approvals.log (mode 600).
KEY="obl1.1.0123456789ab"; OKEY="obl2.1.ba9876543210"
APPR="$T/approvals.log"
printf '#7 | 2026-11-09 10:00 AM PST | sess | Joe: "ok" | re: reconcile %s\n#8 | 2026-11-09 10:01 AM PST | sess | Joe: "ok" | re: reconcile some-other-key\n#9 | 2026-11-09 10:02 AM PST | sess | Joe: "ok" | re: idempotent %s\n' "$KEY" "$KEY" > "$APPR"; chmod 600 "$APPR"
printf '#!/bin/sh\nexit "${STUB_SYSTEMCTL_RC:-0}"\n' > "$T/bin/systemctl"
ENVV=(env PATH="$T/bin:$PATH" OBL_TESTS_DIR="$T/tests" APPROVALS_FILE="$APPR" OBL_APPROVAL_BIN="$here/.local/bin/approval-check.sh" W="$T")
cnt(){ grep -c "$1" "$2" 2>/dev/null || true; }
ACT='{"verb":"named-test","name":"zz-eff"}'
kill_after_effect(){ printf '#!/bin/bash\necho effect >> "$W/effects"\nkill -9 $PPID\nexit 0\n' > "$T/tests/zz-eff.test.sh"; }
# runner under test = $1 (path); d = scratch dir $2; echoes "rc"
urun(){ ( "${ENVV[@]}" timeout 20 python3 -I "$1" run --dir "$2" --key "${3:-$KEY}" --approval '#1' --action "${4:-$ACT}" >"$T/last.out" 2>&1; echo $? ) 2>/dev/null; }
# scenarios 1+2 as one function so the SAME body runs against HEAD (must pass) and the base version (must fail)
unknown_suite(){ # runner label -> sets UF (number of failed unknown-intent expectations)
  local R="$1" d="$T/d-$2" a b c e1 e2; rm -rf "$d" "$T/effects"; UF=0
  kill_after_effect
  a=$(urun "$R" "$d"); e1=$(cnt effect "$T/effects")
  [ "$e1" = 1 ] || UF=$((UF+1))                                     # the first run did the effect, then its owner died before the receipt
  for i in 1 2 3; do b=$(urun "$R" "$d"); [ "$b" = 75 ] || UF=$((UF+1)); done   # (1) three reruns: UNKNOWN, rc 75
  [ "$(cnt effect "$T/effects")" = 1 ] || UF=$((UF+1))              # (1) effect count stays 1
  [ -e "$d/$KEY.run.json" ] && UF=$((UF+1))
  # (2) same with the child gone: owner killed from outside while the child (gate) lives, child then exits
  local d2="$T/d2-$2"; rm -rf "$d2" "$T/effects" "$T/gate"
  printf '#!/bin/bash\necho effect >> "$W/effects"\nwhile [ ! -e "$W/gate" ]; do sleep 0.1; done\nexit 0\n' > "$T/tests/zz-eff.test.sh"
  { "${ENVV[@]}" setsid python3 -I "$R" run --dir "$d2" --key "$KEY" --approval '#1' --action "$ACT" >/dev/null 2>&1 </dev/null & } 2>/dev/null
  for i in $(seq 1 60); do [ -s "$T/effects" ] && break; sleep 0.1; done
  local op; op=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$d2/$KEY.inflight" 2>/dev/null || echo 0)
  kill -9 "$op" 2>/dev/null; sleep 0.3
  c=$(urun "$R" "$d2"); [ "$c" = 75 ] || UF=$((UF+1))               # child alive: 75
  touch "$T/gate"; sleep 1.2                                         # child exits; no receipt exists anywhere
  for i in 1 2 3; do c=$(urun "$R" "$d2"); [ "$c" = 75 ] || UF=$((UF+1)); done   # child gone: still UNKNOWN
  [ "$(cnt effect "$T/effects")" = 1 ] || UF=$((UF+1))
  [ -e "$d2/$KEY.run.json" ] && UF=$((UF+1))
  rm -f "$T/gate"
}
unknown_suite "$R" head
ck "(1)(2) dead owner after effect, before receipt: 3 reruns rc 75 and effects stay 1 (child live, then child gone)" "$UF" 0
ck "(1) UNKNOWN is reported once: one unknown marker, status unknown-started" "$(ls "$T/d-head" | grep -c '\.unknown\.json$')/$(grep -c unknown-started "$T/last.out")" 1/1
ck "(1) no takeover file written" "$(ls "$T/d-head" | grep -c '\.stale-')" 0
# (5) negative control: the identical suite against the pre-fix runner from origin/main must FAIL
BASE="$T/base-run.py"; BREF="${W4_BASE_REF:-origin/main}"
if git -C "$here" show "$BREF:.local/bin/ctl-obligation-run.py" > "$BASE" 2>/dev/null && ! grep -q 'unknown-started' "$BASE"; then
  unknown_suite "$BASE" base; echo "base runner: $UF unknown-intent expectation(s) failed"; ck "(5) negative control: the same suite against $BREF's runner FAILS (blind takeover re-runs the effect)" "$([ "$UF" -gt 0 ] && echo fails || echo passes)" fails
else echo "SKIP (5) negative control: $BREF has no pre-fix runner to compare (already carries the fix, or no git history)"; fi

# reconcile / idempotent scenarios start from the UNKNOWN state of scenario (1)
dg(){ python3 -I -c 'import hashlib,json,sys;print(hashlib.sha256(json.dumps(json.loads(sys.argv[1]),sort_keys=True,separators=(",",":")).encode()).hexdigest())' "$1"; }
mkunknown(){ d="$T/r-$1"; rm -rf "$d" "$T/effects"; kill_after_effect; urun "$R" "$d" "$KEY" "${2:-$ACT}" >/dev/null; }
rec_n(){ python3 -I -c 'import json,sys;r=json.load(open(sys.argv[1]));print(r["status"],r["rc"])' "$d/$KEY.run.json"; }   # sets d; effects=1, marker kept, no receipt
ev(){ python3 -I -c 'import json,sys;print(json.dumps({"key":sys.argv[1],"action_digest":sys.argv[2],"approval":sys.argv[3],"proves":sys.argv[4],"recipe":json.loads(sys.argv[5])}))' "$@"; }
recon(){ "${ENVV[@]}" timeout 30 python3 -I "$R" reconcile --dir "$d" --key "${KEYV:-$KEY}" --approval "${APV:-#7}" --action "$ACT" "$@" >"$T/last.out" 2>&1; echo $?; }
GOOD='{"verb":"service-state","unit":"effect-witness.service"}'
still_unknown(){ [ -e "$d/$KEY.inflight" ] && [ ! -e "$d/$KEY.run.json" ] && [ "$(cnt effect "$T/effects")" = 1 ] && [ "$(urun "$R" "$d")" = 75 ] && [ "$(cnt effect "$T/effects")" = 1 ] && echo held || echo released; }
mkunknown n1; DG=$(dg "$ACT")
ck "(3-neg missing) reconcile with no evidence: rc 75, still UNKNOWN" "$(recon)/$(still_unknown)" 75/held
ck "(3-neg wrong) evidence whose typed recipe fails (rc 3): rc 75, still UNKNOWN" "$(STUB_SYSTEMCTL_RC=3 recon --evidence "$(ev $KEY $DG '#7' done "$GOOD")")/$(still_unknown)" 75/held
ck "(3-neg stale) evidence bound to another revision of the action: rc 75, still UNKNOWN" "$(recon --evidence "$(ev $KEY $(dg '{"verb":"named-test","name":"other"}') '#7' done "$GOOD")")/$(still_unknown)" 75/held
ck "(3-neg stale) evidence naming another key: rc 75, still UNKNOWN" "$(recon --evidence "$(ev $OKEY $DG '#7' done "$GOOD")")/$(still_unknown)" 75/held
ck "(3-neg unapproved) approval record names a different key: rc 75, still UNKNOWN" "$(APV='#8' recon --evidence "$(ev $KEY $DG '#8' done "$GOOD")")/$(still_unknown)" 75/held
ck "(3-neg unapproved) approval absent from the record: rc 75, still UNKNOWN" "$(APV='#99' recon --evidence "$(ev $KEY $DG '#99' done "$GOOD")")/$(still_unknown)" 75/held
ck "(3-neg unapproved) evidence approval differs from the passed approval: rc 75, still UNKNOWN" "$(APV='#7' recon --evidence "$(ev $KEY $DG '#9' done "$GOOD")")/$(still_unknown)" 75/held
rm -f "$T/pwned"
ck "(3-neg arbitrary) a caller-supplied command is never executed" "$(recon --evidence "$(ev $KEY $DG '#7' done '{"verb":"bash","cmd":"touch '"$T"'/pwned"}')")/$([ -e "$T/pwned" ] && echo ran || echo clean)/$(still_unknown)" 75/clean/held
ck "(3-neg arbitrary) a recipe identical to the action (not independent) is refused" "$(recon --evidence "$(ev $KEY $DG '#7' done "$ACT")")/$(still_unknown)" 75/held
ck "(3) evidence-bound release, proves done: rc 0, receipt reconciled-done, effect NOT re-run" "$(recon --evidence "$(ev $KEY $DG '#7' done "$GOOD")")/$(rec_n)/$(cnt effect "$T/effects")/$(urun "$R" "$d")/$(cnt effect "$T/effects")" "0/reconciled-done 0/1/0/1"
mkunknown n2
ck "(3) evidence-bound release, proves not-done: rc 0, record retired, then ONE rerun executes" "$(recon --evidence "$(ev $KEY $DG '#7' not-done "$GOOD")")/$(ls "$d" | grep -c '\.released-')/$(printf '#!/bin/bash\necho effect >> "$W/effects"\nexit 0\n' > "$T/tests/zz-eff.test.sh"; urun "$R" "$d")/$(cnt effect "$T/effects")" 0/1/0/2

# (4) idempotent action: rerun ONLY on an approved, key- and digest-bound idempotency record; a bare key/flag never reruns
IACT='{"verb":"named-test","name":"zz-eff","idempotent":"#9"}'
mkunknown i1 "$IACT"
ck "(4) approved idempotent action (#9 names the key): dead owner released, rerun executes once" "$(printf '#!/bin/bash\necho effect >> "$W/effects"\nexit 0\n' > "$T/tests/zz-eff.test.sh"; urun "$R" "$d" "$KEY" "$IACT")/$(cnt effect "$T/effects")/$(ls "$d" | grep -c '\.stale-')" 0/2/1
I8='{"verb":"named-test","name":"zz-eff","idempotent":"#8"}'; I99='{"verb":"named-test","name":"zz-eff","idempotent":"#99"}'
mkunknown i2 "$I8"
ck "(4-neg) idempotent declared but its approval names another key (#8): rc 75, no rerun" "$(urun "$R" "$d" "$KEY" "$I8")/$(cnt effect "$T/effects")" 75/1
mkunknown i3 "$I99"
ck "(4-neg) idempotent declared with no approval record (#99): rc 75, no rerun" "$(urun "$R" "$d" "$KEY" "$I99")/$(cnt effect "$T/effects")" 75/1
mkunknown i4
ck "(4-neg) a bare idempotency key in the spec is refused (receipt refused 126), never runs, never reruns" "$(urun "$R" "$d" "$KEY" '{"verb":"named-test","name":"zz-eff","idempotency_key":"k1"}')/$(rec_n)/$(cnt effect "$T/effects")" "0/refused 126/1"
mkunknown i5 "$IACT"
ck "(4-neg) idempotent approval for a different revision of the action (digest mismatch): rc 75, no rerun" "$(python3 -I - "$d/$KEY.inflight" <<'PY'
import json,sys
p=sys.argv[1]; o=json.load(open(p)); o["action_digest"]="0"*64; json.dump(o,open(p,"w"))
PY
urun "$R" "$d" "$KEY" "$IACT")/$(cnt effect "$T/effects")" 75/1

echo "pass=$p fail=$f"; [ "$f" = 0 ]
