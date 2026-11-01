#!/usr/bin/env bash
# agent-spawn-spec-lint.sh gate: pipes Agent hook JSON into the hook with temp
# spec fixtures. Real rb stub shape = tests/fixtures/agent-spawn-spec-lint-
# qpa-fleetdash.spec.md (a copy; the live path is never referenced).
# shellcheck disable=SC2319  # check NAME $? deliberately reads the preceding test
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/agent-spawn-spec-lint.sh"
stub="$here/tests/fixtures/agent-spawn-spec-lint-qpa-fleetdash.spec.md"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
H="$tmp/home"; mkdir -p "$H" "$tmp/coders"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1 ${2:-}"; }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# run TOOL PROMPT -> HOUT, HERR, HRC
run() {
    local in; in=$(jq -nc --arg t "$1" --arg p "$2" \
        '{tool_name:$t,tool_input:{description:"d",prompt:$p,model:"sonnet"},session_id:"s",cwd:"/nonexistent"}')
    HRC=0
    HOUT=$(printf '%s' "$in" | env HOME="$H" bash "$hook" 2>"$tmp/err") || HRC=$?
    HERR=$(cat "$tmp/err")
}
denied() { [ "$(printf '%s' "$HOUT" | jq -r '.hookSpecificOutput.permissionDecision // empty')" = deny ]; }
reason() { printf '%s' "$HOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

cp "$stub" "$tmp/coders/qpa-fleetdash.spec.md"
S="$tmp/coders/qpa-fleetdash.spec.md"

# (1) real stub + prompt without STEP 0 -> refused, names path + count
run Agent "Implement the spec at $S then report."
denied; check "1-refused" $? "$HOUT"
r=$(reason)
case "$r" in *"$S"*) ok "1-reason-names-path" ;; *) bad "1-reason-names-path" "$r" ;; esac
case "$r" in *"3 PREMISE-UNVERIFIED"*) ok "1-reason-count-3" ;; *) bad "1-reason-count-3" "$r" ;; esac
case "$r" in *"STEP 0"*"verifies or escalates"*) ok "1-reason-fix" ;; *) bad "1-reason-fix" "$r" ;; esac
[ "$HRC" = 0 ]; check "1-exit-0" $?
printf '%s' "$HOUT" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null; check "1-event-name" $?

# (2) same spec + STEP 0 variants -> allowed
for v in "STEP 0: verify the premises." "step-0 verify" "Step 0: x" "do this (STEP 0) first"; do
    run Agent "Implement $S. $v"
    [ -z "$HOUT" ] && [ "$HRC" = 0 ]; check "2-allowed [$v]" $? "$HOUT"
done
run Agent "Implement $S. STEP 01 is unrelated."
denied; check "2-step01-is-not-step0" $?

# (3) spec without the marker -> allowed
printf '# spec\n- a verified premise\n' > "$tmp/coders/clean.spec.md"
run Agent "Implement $tmp/coders/clean.spec.md"
[ -z "$HOUT" ]; check "3-no-marker-allowed" $? "$HOUT"

# (4) no spec cited -> allowed (also a non-spec .md outside coders/)
run Agent "Fix the bug in foo.rs and read $tmp/README.md"
[ -z "$HOUT" ] && [ -z "$HERR" ]; check "4-no-spec-allowed" $? "$HOUT$HERR"

# (5) tool_name Bash -> untouched
run Bash "Implement $S"
[ -z "$HOUT" ] && [ -z "$HERR" ] && [ "$HRC" = 0 ]; check "5-bash-untouched" $? "$HOUT"

# (6) cited path missing -> allowed + NOTE on stderr
run Agent "Implement $tmp/coders/missing.spec.md"
[ -z "$HOUT" ] && [ "$HRC" = 0 ]; check "6-missing-allowed" $? "$HOUT"
case "$HERR" in *NOTE*"$tmp/coders/missing.spec.md"*) ok "6-note-on-stderr" ;; *) bad "6-note-on-stderr" "$HERR" ;; esac

# (7) marker count with exactly 3 bullets (and one line without)
printf '# s\n- a: PREMISE-UNVERIFIED (x)\n- b ok\n- c: PREMISE-UNVERIFIED\n- d: PREMISE-UNVERIFIED\n' > "$tmp/coders/three.spec.md"
run Agent "Do $tmp/coders/three.spec.md"
case "$(reason)" in *"(3 PREMISE-UNVERIFIED line(s))"*) ok "7-count-3" ;; *) bad "7-count-3" "$(reason)" ;; esac

# extras: ~ resolution, /coders/ non-spec .md, prompt never echoed, runtime
mkdir -p "$H/.cache/x/coders"; cp "$S" "$H/.cache/x/coders/note.md"
run Agent "Read ~/.cache/x/coders/note.md and act."
denied; check "x-tilde-and-coders-md" $? "$HOUT"
run Agent "SECRETWORD in prompt, spec $S"
case "$HOUT$HERR" in *SECRETWORD*) bad "x-prompt-not-echoed" ;; *) ok "x-prompt-not-echoed" ;; esac
run Agent "Spec $S and $tmp/coders/clean.spec.md"
denied; check "x-multi-cite-one-offender" $?
start=$(date +%s%N); run Agent "Implement $S"; ms=$(( ($(date +%s%N) - start) / 1000000 ))
echo "runtime: ${ms} ms (incl. test harness jq)"
[ "$ms" -lt 200 ]; check "x-under-200ms" $? "${ms}ms"

# stanza / lint
st=$(bash "$hook" --stanza)
[ "$(jq -r '[.matcher,.hooks[0].command,(.hooks[0].timeout|tostring)]|join("|")' <<<"$st")" = "Agent|/home/jsy/.claude/hooks/agent-spawn-spec-lint.sh|10" ]
check "stanza" $? "$st"
bash -n "$hook" && bash -n "$0"; check "bash-n-clean" $?
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$hook" "$0" >/dev/null 2>&1; check "shellcheck-warning-clean" $?
else echo "SKIP shellcheck (not installed)"; fi
[ -x "$hook" ]; check "hook-executable" $?

echo "agent-spawn-spec-lint.test: $pass passed, $fail failed"
[ "$fail" = 0 ]
