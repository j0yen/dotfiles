#!/usr/bin/env bash
# Fixture test for .local/bin/ctl-nonpr-verifier.sh: stub wm-asks / wm-decide / systemd-run / fable-launch, temp dirs only, no network, no live ledger.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; S="$HERE/.local/bin/ctl-nonpr-verifier.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; n=0
ok() { n=$((n+1)); echo "ok $n - $1"; }
bad() { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }

# ---- stubs ----
cat > "$T/wm-asks" <<'X'
#!/usr/bin/env bash
[ "$1 $2" = "asks query" ] || exit 2
cat "$FX/asks.json"
X
cat > "$T/wm-decide" <<'X'
#!/usr/bin/env bash
[ "$1" = list ] || exit 2
cat "$FX/rows.json"
X
cat > "$T/systemd-run" <<'X'
#!/usr/bin/env bash
while [ $# -gt 0 ] && [ "$1" != "$FABLE_LAUNCH" ]; do shift; done
exec "$@"
X
cat > "$T/fable-launch" <<'X'
#!/usr/bin/env bash
# stub claude: no network. Reads the prompt (arg after -p), writes the row the session would record, and the result line.
touch "$FX/session-ran"
p=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && { p="$2"; break; }; shift; done
R="$(printf '%s\n' "$p" | sed -n 's/^5\. Write one line to \(.*\): VERDICT=.*/\1/p')"
agent="$(printf '%s\n' "$p" | sed -n 's/.*record --agent \([^ ]*\) --via.*/\1/p' | head -1)"
label="$(printf '%s\n' "$p" | sed -n 's/.*agent=verifier:\([^ ]*\) recorded_by.*/\1/p' | head -1)"
sha="$(printf '%s\n' "$p" | sed -n 's/^CHECK SHA: //p')"
word="${STUB_WORD:-CONFIRM}"; kind=verdict; [ "$word" = CONFIRM ] || kind=other
via=ctl-nonpr-verifier; [ -z "${STUB_VIA:-}" ] || via="$STUB_VIA"
python3 -I - "$FX/rows.json" "d-test-0001" "$agent" "$word" "$kind" "$label" "$sha" "$via" <<'PY'
import json, sys
f, i, a, w, k, label, sha, via = sys.argv[1:9]
rows = json.load(open(f))
rows.append({"id": i, "agent": a, "via": via, "kind": k, "first_verdict": None,
  "what": "%s A9 check-sha=%s COMMIT=0123456789abcdef agent=verifier:%s recorded_by=unit:%s scope=non-pr" % (w, sha, label, label)})
json.dump(rows, open(f, "w"))
PY
printf 'VERDICT=%s ROW=d-test-0001\n' "$word" > "$R"
X
chmod +x "$T/wm-asks" "$T/wm-decide" "$T/systemd-run" "$T/fable-launch"

export CTL_NONPR_TEST=1 WMA="$T/wm-asks" WMD="$T/wm-decide" SD_RUN="$T/systemd-run" FABLE_LAUNCH="$T/fable-launch" FX="$T/fx"
export LEASE_DIR="$T/leases" RUN_DIR="$T/runs" NOW=1800000000

newfx() {  # $1 = owner, $2 = check text
  rm -rf "$FX" "$LEASE_DIR" "$RUN_DIR"; mkdir -p "$FX"; echo '[]' > "$FX/rows.json"; unset STUB_WORD STUB_VIA
  python3 -I - "$FX/asks.json" "$1" "$2" <<'PY'
import json, sys
json.dump([{"ask_id": "A9", "owner": sys.argv[2], "status": "open", "row_id": "d-20261107-000000-rb-aaaa", "rev": 4, "check": sys.argv[3]}], open(sys.argv[1], "w"))
PY
}
rowcount() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$FX/rows.json"; }
CHK='bash tests/foo.test.sh at head 0123456789abcdef prints PASS'

# 1. positive
newfx rb "$CHK"
out="$("$S" launch A9 --target-check 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "positive: exit 0" || bad "positive: exit $rc: $out"
case "$out" in *"VERDICT-ROW d-test-0001"*) ok "positive: prints verdict row id" ;; *) bad "positive: no row id: $out" ;; esac
case "$out" in *"--verdict-row d-test-0001"*) ok "positive: prints resolve line for ctl" ;; *) bad "positive: no resolve line" ;; esac
case "$out" in *"coder:ctl-nonpr-A9-"*) ok "positive: independent verdict agent" ;; *) bad "positive: agent label" ;; esac
[ -s "$RUN_DIR"/ctl-nonpr-A9-*/prompt.txt ] && grep -q "$CHK" "$RUN_DIR"/ctl-nonpr-A9-*/prompt.txt && ok "positive: prompt scoped to the done-check" || bad "positive: prompt scope"

# 2. self verdict (closer ctl, owner, aide, hermes)
for a in coder:ctl aide:ctl coder:rb coder:controller aide:aide verifier:ctl; do
  newfx rb "$CHK"
  "$S" launch A9 --target-check --verdict-agent "$a" >/dev/null 2>&1; rc=$?
  { [ "$rc" = 7 ] && [ "$(rowcount)" = 0 ] && [ ! -e "$FX/session-ran" ]; } && ok "self verdict $a refused (exit 7, no row, no session)" || bad "self verdict $a: rc=$rc rows=$(rowcount)"
done
newfx ctl "$CHK"   # owner is ctl itself: the default independent agent is fine, an owner-named one is not
"$S" launch A9 --target-check --verdict-agent coder:ctl >/dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && ok "owner ctl: self verdict refused" || bad "owner ctl rc=$rc"

# 3. incorrect target
newfx rb "$CHK"
"$S" launch A9 --target-check --check-sha deadbeefdeadbeef >/dev/null 2>&1; rc=$?
{ [ "$rc" = 5 ] && [ ! -e "$FX/session-ran" ] && [ "$(rowcount)" = 0 ]; } && ok "launch check sha differs from the ask's current check: refused (5)" || bad "wrong sha rc=$rc"
newfx rb "$CHK"; "$S" issue A9 >/dev/null 2>&1
python3 -I - "$FX/asks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d[0]["check"] = "a different done-check"; json.dump(d, open(sys.argv[1], "w"))
PY
"$S" launch A9 --target-check >/dev/null 2>&1; rc=$?
{ [ "$rc" = 5 ] && [ ! -e "$FX/session-ran" ] && [ "$(rowcount)" = 0 ]; } && ok "check changed after the lease: refused (5)" || bad "changed check rc=$rc"
newfx rb "$CHK"; "$S" issue A9 >/dev/null 2>&1; sed -i 's/^ask=A9/ask=A8/' "$LEASE_DIR/A9.lease"
"$S" launch A9 --target-check >/dev/null 2>&1; rc=$?
[ "$rc" = 5 ] && [ ! -e "$FX/session-ran" ] && ok "lease for another ask id: refused (5)" || bad "other ask lease rc=$rc"

# 4. lease expiry
newfx rb "$CHK"; "$S" issue A9 >/dev/null 2>&1
NOW=$((1800000000 + 1801)) "$S" launch A9 --target-check >/dev/null 2>&1; rc=$?
{ [ "$rc" = 6 ] && [ ! -e "$FX/session-ran" ] && [ "$(rowcount)" = 0 ]; } && ok "lease 1801 s old: refused (6)" || bad "expired rc=$rc"
NOW=$((1800000000 + 1800)) "$S" launch A9 --target-check >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "lease exactly 1800 s old: still valid" || bad "boundary rc=$rc"
newfx rb "$CHK"; "$S" issue A9 >/dev/null 2>&1; sed 's/^ts=.*/ts=1/' "$LEASE_DIR/A9.lease" > "$T/old.lease"
"$S" launch A9 --target-check --lease "$T/old.lease" >/dev/null 2>&1; rc=$?
[ "$rc" = 6 ] && [ ! -e "$FX/session-ran" ] && ok "explicit stale lease file refused (6)" || bad "stale lease rc=$rc"

# 5. no real done-check
for c in "-" "" "none"; do
  newfx rb "$c"
  "$S" launch A9 --target-check >/dev/null 2>&1; rc=$?
  { [ "$rc" = 4 ] && [ ! -e "$FX/session-ran" ] && [ "$(rowcount)" = 0 ]; } && ok "done-check '$c': refused (4)" || bad "no check '$c' rc=$rc"
done

# 6. failing check: CORRECT row, no resolvable id printed
newfx rb "$CHK"; export STUB_WORD=CORRECT
out="$("$S" launch A9 --target-check 2>/dev/null)"; rc=$?
{ [ "$rc" = 9 ] && ! printf '%s' "$out" | grep -q "VERDICT-ROW\|--verdict-row"; } && ok "CORRECT outcome: exit 9, nothing printed to resolve with" || bad "CORRECT rc=$rc out=$out"
# 7. forged via label
newfx rb "$CHK"; export STUB_VIA=verifier
"$S" launch A9 --target-check >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "forged via=verifier row: refused (8)" || bad "forged via rc=$rc"
# 8. overrides refused outside test mode
rc=0; env -u CTL_NONPR_TEST "$S" launch A9 --target-check >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] && ok "env overrides refused without CTL_NONPR_TEST" || bad "override rc=$rc"
# 9. launch without --target-check
"$S" launch A9 >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "launch without --target-check: usage (2)" || bad "usage rc=$rc"

echo "$n checks, $fail failed"; [ "$fail" = 0 ]
