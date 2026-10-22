#!/usr/bin/env bash
# output-cap.sh gate: pipes hook JSON (with a fake transcript) into the hook,
# then EXECUTES the rewritten command with `bash -c` to prove behaviour end to
# end. Runs under a throwaway HOME; touches nothing real.
# shellcheck disable=SC2319  # check NAME $? deliberately reads the preceding test
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/output-cap.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
H="$tmp/home"; TD="$tmp/t"; tr="$tmp/transcript.jsonl"
mkdir -p "$H/.claude/state" "$TD"
: > "$tr"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1 ${2:-}"; }
check() { # name cond-rc [detail]
    if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

n=0
setscope() { printf '%s\n' "$1" > "$H/.claude/state/output-cap.enabled"; }
# model_for ID MODEL -> transcript line carrying tool_use id
model_for() {
    jq -nc --arg id "$1" --arg m "$2" \
        '{type:"assistant",message:{model:$m,content:[{type:"tool_use",id:$id,name:"Bash",input:{}}]}}' >> "$tr"
}
# mkinput CMD [bg] -> sets ID and INPUT (model fable unless MODEL set)
mkinput() {
    n=$((n + 1)); ID="toolu_oc_$n"
    model_for "$ID" "${MODEL:-claude-fable-5-1}"
    INPUT=$(jq -nc --arg c "$1" --arg id "$ID" --arg tr "$tr" --arg sid "${SID:-sess-oc-1}" --argjson bg "${2:-false}" \
        '{tool_name:"Bash",tool_input:{command:$c,description:"d",timeout:5000,run_in_background:$bg},session_id:$sid,transcript_path:$tr,tool_use_id:$id,cwd:"/home/jsy"}')
}
# hook [ENV=val ...] -> HOUT (stdout) and HRC
hook() {
    HRC=0
    HOUT=$(printf '%s' "$INPUT" | env -u WM_SEAT -u TMUX HOME="$H" TMPDIR="$TD" PROBE_GATE_HOSTNAME=carbon "$@" bash "$hook" 2>/dev/null) || HRC=$?
}
# wrapped -> W = rewritten command or empty
wrapped() { W=$(printf '%s' "$HOUT" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null); }
# runw -> executes W; OUTF/ERRF, RC
runw() {
    OUTF="$tmp/out.$n"; RC=0
    bash -c "$W" >"$OUTF" 2>"$tmp/err.$n" || RC=$?
}
# full CMD [env...] -> hook then run
full() { local c="$1"; shift; mkinput "$c"; hook "$@"; wrapped; [ -n "$W" ] && runw; }

# ---------------------------------------------------------------- scope/skip
setscope aide
mkinput 'echo hi'; hook; wrapped
[ -n "$W" ] && [ "$HRC" = 0 ]; check "aide-carbon-fable-wrapped" $?
shape=$(printf '%s' "$HOUT" | jq -r '[.hookSpecificOutput.hookEventName,.hookSpecificOutput.permissionDecision,(.hookSpecificOutput.updatedInput.timeout|tostring),.hookSpecificOutput.updatedInput.description,(.hookSpecificOutput.updatedInput.run_in_background|tostring)]|join("|")')
[ "$shape" = "PreToolUse|allow|5000|d|false" ]; check "output-shape-keeps-other-tool_input-keys" $? "$shape"

mkinput 'echo hi'; hook WM_SEAT=ctl; [ -z "$HOUT" ] && [ "$HRC" = 0 ]; check "aide-scope-WM_SEAT-not-wrapped" $?
mkinput 'echo hi'; hook TMUX=/tmp/x,1,0; [ -z "$HOUT" ]; check "aide-scope-TMUX-not-wrapped" $?
mkinput 'echo hi'; hook PROBE_GATE_HOSTNAME=redbaron; [ -z "$HOUT" ]; check "aide-scope-other-host-not-wrapped" $?
setscope all
mkinput 'echo hi'; hook WM_SEAT=ctl; wrapped; [ -n "$W" ]; check "all-scope-WM_SEAT-wrapped" $?
mkinput 'echo hi'; hook PROBE_GATE_HOSTNAME=redbaron; wrapped; [ -n "$W" ]; check "all-scope-other-host-wrapped" $?
setscope bogus; mkinput 'echo hi'; hook; [ -z "$HOUT" ]; check "enable-word-bogus-not-wrapped" $?
rm -f "$H/.claude/state/output-cap.enabled"; mkinput 'echo hi'; hook; [ -z "$HOUT" ] && [ "$HRC" = 0 ]; check "enable-file-missing-not-wrapped" $?
setscope aide

MODEL=claude-sonnet-5-5 mkinput 'echo hi'; hook; [ -z "$HOUT" ] && [ "$HRC" = 0 ]; check "model-sonnet-not-wrapped" $?
MODEL=claude-haiku-4 mkinput 'echo hi'; hook; [ -z "$HOUT" ]; check "model-haiku-not-wrapped" $?
MODEL=claude-opus-5-5 mkinput 'echo hi'; hook; wrapped; [ -n "$W" ]; check "model-opus-wrapped" $?
mkinput 'echo hi'; INPUT=$(printf '%s' "$INPUT" | jq -c '.tool_use_id="toolu_not_in_transcript"'); hook; [ -z "$HOUT" ] && [ "$HRC" = 0 ]; check "model-unknown-tool_use_id-not-wrapped" $?
mkinput 'echo hi'; INPUT=$(printf '%s' "$INPUT" | jq -c 'del(.tool_use_id)'); hook; [ -z "$HOUT" ]; check "no-tool_use_id-not-wrapped" $?

mkinput 'echo x > f.txt'; hook; [ -z "$HOUT" ]; check "existing-redirect-not-wrapped" $?
mkinput 'cat <<EOF >> f.txt
a
EOF'; hook; [ -z "$HOUT" ]; check "existing-append-not-wrapped" $?
mkinput 'sleep 1 &'; hook; [ -z "$HOUT" ]; check "trailing-amp-not-wrapped" $?
mkinput 'sleep 1 &  '; hook; [ -z "$HOUT" ]; check "trailing-amp-space-not-wrapped" $?
mkinput 'sleep 1 & ;'; hook; [ -z "$HOUT" ]; check "trailing-amp-semicolon-not-wrapped" $?
mkinput 'echo hi' true; hook; [ -z "$HOUT" ]; check "run_in_background-not-wrapped" $?
mkinput 'echo hi \'; hook; [ -z "$HOUT" ]; check "trailing-backslash-not-wrapped" $?
mkinput 'cat <<EOF'; hook; [ -z "$HOUT" ]; check "unterminated-heredoc-not-wrapped" $?
mkinput 'echo )'; hook; [ -z "$HOUT" ]; check "syntax-error-not-wrapped" $?
mkinput 'echo hi;'; hook; wrapped; [ -n "$W" ]; check "trailing-semicolon-still-wrapped" $?
printf '' | env HOME="$H" bash "$hook" >/dev/null 2>&1; check "empty-stdin-exit0" $?
HRC=0; HOUT=$(printf 'not json {{' | env -u WM_SEAT -u TMUX HOME="$H" PROBE_GATE_HOSTNAME=carbon bash "$hook" 2>/dev/null) || HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ]; check "malformed-json-exit0-no-output" $?
HRC=0; HOUT=$(printf '{"tool_name":"Edit","tool_input":{"command":"x"}}' | env -u WM_SEAT -u TMUX HOME="$H" PROBE_GATE_HOSTNAME=carbon bash "$hook" 2>/dev/null) || HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ]; check "non-Bash-tool-ignored" $?

# ----------------------------------------------------------- idempotent
mkinput 'echo hi'; hook; wrapped; first="$W"
mkinput "$first"; hook; [ -z "$HOUT" ]; check "idempotent-no-double-wrap" $?

# ----------------------------------------------------------- behaviour (executed)
# small passthrough, byte-identical to the unwrapped command's merged output
cmd='printf "hello\nworld\n"; echo err >&2; printf "tail-no-newline"'
full "$cmd"
bash -c "$cmd" > "$tmp/direct" 2>&1
cmp -s "$OUTF" "$tmp/direct"; check "small-passthrough-byte-identical" $?

# > 2 KB -> head 15 + marker + tail 15
full 'seq 1 1000'
total=$(seq 1 1000 | wc -c)
f=$(grep -o 'full output: [^]]*' "$OUTF" | sed 's/full output: //')
{ head -n 15 "$OUTF" | diff -q - <(seq 1 15) >/dev/null \
  && grep -q "output-cap: $total bytes, 1000 lines; full output: " "$OUTF" \
  && tail -n 15 "$OUTF" | diff -q - <(seq 986 1000) >/dev/null \
  && [ -f "$f" ] && [ "$(stat -c %s "$f")" = "$total" ] && [ "$RC" = 0 ]; }
check "over-2KB-head15-marker-tail15-and-full-file" $? "$(head -c 200 "$OUTF")"

# 60 KB single line, no newline -> one line cut to 400, marker with bytes
full 'head -c 60000 /dev/zero | tr "\0" x'
longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$OUTF")
{ [ "$longest" -le 400 ] && grep -q 'output-cap: 60000 bytes' "$OUTF" && [ "$(stat -c %s "$OUTF")" -lt 1000 ]; }
check "60KB-single-line-cut-to-400" $? "longest=$longest size=$(stat -c %s "$OUTF")"

# many long lines: each line cut to 400
full 'for i in $(seq 1 40); do head -c 1000 /dev/zero | tr "\0" y; echo; done'
longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$OUTF")
[ "$longest" -le 410 ] && [ "$(wc -l < "$OUTF")" -le 40 ]; check "40-long-lines-each-cut" $? "longest=$longest"

# exit codes
full '(exit 0)'; [ "$RC" = 0 ]; check "rc-0-preserved" $?
full 'echo out; (exit 3)'; [ "$RC" = 3 ] && grep -qx out "$OUTF"; check "rc-3-preserved-with-output" $?
full 'echo before; exit 7; echo after'; { [ "$RC" = 7 ] && grep -qx before "$OUTF" && ! grep -q after "$OUTF"; }
check "exit-7-inside-emits-output-returns-7" $?
full 'seq 1 1000; exit 9'; { [ "$RC" = 9 ] && grep -q 'output-cap: ' "$OUTF"; }; check "exit-9-inside-big-output-marker-and-rc" $?
full 'set -e; echo before; false; echo after'; { [ "$RC" != 0 ] && grep -qx before "$OUTF" && ! grep -q after "$OUTF"; }
check "set-e-false-nonzero-no-after-output-still-emitted" $? "rc=$RC"
full 'echo gone; exec true'; { [ "$RC" = 0 ] && grep -qx gone "$OUTF"; }; check "exec-inside-still-emits" $?

# shape variants
full "cat <<'EOF'
line one )
} brace
EOF
# trailing comment"
printf 'line one )\n} brace\n' | cmp -s - "$OUTF"; check "heredoc-with-trailing-comment" $?
full 'echo a && echo b | tr b B; echo c'; printf 'a\nB\nc\n' | cmp -s - "$OUTF"; check "and-pipe-semicolon" $?
full $'echo "}" \')\' "("'; printf '} ) (\n' | cmp -s - "$OUTF"; check "braces-and-parens-in-quotes" $?
full 'echo out1; echo err1 >&2; echo out2'; printf 'out1\nerr1\nout2\n' | cmp -s - "$OUTF"; check "stderr-interleaved-in-order" $?
full 'true'; { [ ! -s "$OUTF" ] && [ "$RC" = 0 ]; }; check "zero-byte-output-empty-passthrough" $?
full 'echo x 2>/dev/null; echo y 2>&1'; printf 'x\ny\n' | cmp -s - "$OUTF"; check "2>&1-and-2>/dev/null-allowed" $?
full 'echo $((1+2))'; printf '3\n' | cmp -s - "$OUTF"; check "dollar-expansion-evaluated-once" $?
cmdq="echo 'it'\"'\"'s'"
full "$cmdq"; printf "it's\n" | cmp -s - "$OUTF"; check "single-quotes-in-command" $?

# cwd persistence is NOT preserved (documented limitation): cd happens in the subshell
mkdir -p "$tmp/elsewhere"; start=$(pwd)
mkinput "cd $tmp/elsewhere"; hook; wrapped; after=$(bash -c "$W; pwd")
[ "$after" = "$start" ]; check "cwd-persistence-NOT-claimed-cd-stays-in-subshell" $? "$after"

# ----------------------------------------------------------- ledger
led="$H/.cache/token-ledger/output-cap.jsonl"
full 'seq 1 1000'
id="$ID"
w=$(grep "\"tool_use_id\":\"$id\"" "$led" | grep '"phase":"wrap"' | head -1)
d=$(grep "\"tool_use_id\":\"$id\"" "$led" | grep '"phase":"done"' | head -1)
{ [ "$(jq -r '[.session_id,.scope,.model,.cmd_head]|join("|")' <<<"$w")" = "sess-oc-1|aide|claude-fable-5-1|seq 1 1000" ] \
  && jq -e '.ts|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' <<<"$w" >/dev/null; }
check "ledger-wrap-row-fields" $? "$w"
total=$(seq 1 1000 | wc -c)
[ "$(jq -r '[.rc,.bytes,.lines,.capped]|map(tostring)|join("|")' <<<"$d")" = "0|$total|1000|true" ]; check "ledger-done-row-capped-true" $? "$d"
full 'echo small; (exit 4)'; id="$ID"
d=$(grep "\"tool_use_id\":\"$id\"" "$led" | grep '"phase":"done"' | head -1)
[ "$(jq -r '[.rc,.bytes,.lines,.capped]|map(tostring)|join("|")' <<<"$d")" = "4|6|1|false" ]; check "ledger-done-row-capped-false-rc4" $? "$d"
mkinput "$(printf 'echo %0100d' 0)"; hook; l=$(tail -1 "$led" | jq -r '.cmd_head|length'); [ "$l" = 80 ]; check "ledger-cmd_head-80-chars" $?

# ----------------------------------------------------------- scratch dir + reaper
SID=0123abcd-0000-0000-0000-000000000001
sp="$TD/claude-$(id -u)/-home-jsy/$SID/scratchpad"; mkdir -p "$sp"
SID=$SID full 'echo scratch'; ls "$sp"/oc-toolu_oc_*.out >/dev/null 2>&1; check "scratchpad-dir-used-when-derivable" $?
SID=0123abcd-0000-0000-0000-00000000dead full 'echo fb'; [ -f "$H/.cache/output-cap/oc-$ID.out" ]; check "fallback-dir-when-no-scratchpad" $?
touch -d '3 days ago' "$H/.cache/output-cap/oc-old.out"; touch "$H/.cache/output-cap/oc-new.out"; touch -d '3 days ago' "$H/.cache/output-cap/keep.txt"
SID=0123abcd-0000-0000-0000-00000000dead full 'echo fb2'
{ [ ! -e "$H/.cache/output-cap/oc-old.out" ] && [ -e "$H/.cache/output-cap/oc-new.out" ] && [ -e "$H/.cache/output-cap/keep.txt" ]; }
check "reaper-deletes-only-old-oc-files" $?

# ----------------------------------------------------------- stanza / lint / symlink
st=$(bash "$hook" --stanza)
[ "$(jq -r '[.matcher,.hooks[0].type,.hooks[0].command,(.hooks[0].timeout|tostring)]|join("|")' <<<"$st")" = "Bash|command|/home/jsy/.claude/hooks/output-cap.sh|10" ]
check "stanza-valid-json" $? "$st"
bash -n "$hook" && bash -n "$0"; check "bash-n-clean" $?
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$hook" "$0" >/dev/null 2>&1; check "shellcheck-warning-clean" $?
else
    echo "SKIP shellcheck (not installed)"
fi
[ -x "$hook" ]; check "hook-executable" $?

echo "output-cap.test: $pass passed, $fail failed"
[ "$fail" = 0 ]
