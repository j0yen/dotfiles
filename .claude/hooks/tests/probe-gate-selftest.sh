#!/usr/bin/env bash
# probe-gate-selftest.sh — feeds synthetic PreToolUse hook JSON (with a fake
# transcript file supplying the triggering assistant turn's model, keyed by
# tool_use_id) through probe-gate.sh and checks exit code.
# Run: ~/.claude/hooks/tests/probe-gate-selftest.sh

set -uo pipefail

HOOK="${HOME}/.claude/hooks/probe-gate.sh"
JQ=$(command -v jq) || { echo "probe-gate-selftest: jq not found"; exit 1; }

WORKDIR=$(mktemp -d /tmp/probe-gate-selftest.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

FAIL=0
PASS=0

# add_line TRANSCRIPT MODEL TOOL_USE_ID SIDECHAIN(true|false)
add_line() {
    local path="$1" model="$2" id="$3" side="$4"
    "$JQ" -nc --arg model "$model" --arg id "$id" --argjson side "$side" \
        '{type:"assistant", isSidechain:$side, message:{model:$model, content:[{type:"tool_use", id:$id, name:"Bash"}]}}' \
        >> "$path"
}

# run_case NAME CMD TOOL_USE_ID WANT_EXIT [TRANSCRIPT_NAME]
# (transcript file must already exist at $WORKDIR/${TRANSCRIPT_NAME:-NAME}.jsonl)
run_case() {
    local name="$1" cmd="$2" tool_use_id="$3" want_exit="$4" transcript_name="${5:-$1}"
    local transcript="$WORKDIR/${transcript_name}.jsonl"

    local input
    input=$("$JQ" -nc \
        --arg tool "Bash" \
        --arg cmd "$cmd" \
        --arg sid "selftest-${name}" \
        --arg tp "$transcript" \
        --arg tid "$tool_use_id" \
        '{tool_name:$tool, tool_input:{command:$cmd}, session_id:$sid, transcript_path:$tp, tool_use_id:$tid}')

    local out got_exit
    out=$(printf '%s' "$input" | "$HOOK" 2>&1)
    got_exit=$?

    if [ "$got_exit" -eq "$want_exit" ]; then
        PASS=$((PASS+1))
        echo "PASS  $name (exit=$got_exit)"
    else
        FAIL=$((FAIL+1))
        echo "FAIL  $name (want exit=$want_exit got=$got_exit) :: $out"
    fi
}

# 1. fable + ssh probe -> deny
add_line "$WORKDIR/fable_ssh_df.jsonl" "claude-fable-5-1" "toolu_1" false
run_case "fable_ssh_df" 'ssh orch "df -h"' "toolu_1" 2

# 2. fable + heredoc append into memory dir -> allow
add_line "$WORKDIR/fable_memory_heredoc.jsonl" "claude-fable-5-1" "toolu_2" false
run_case "fable_memory_heredoc" "cat >> ~/.claude/projects/x/memory/a.md <<'EOF'" "toolu_2" 0

# 3. fable + git pull chained with git log probe -> deny
add_line "$WORKDIR/fable_git_log_probe.jsonl" "claude-fable-5-1" "toolu_3" false
run_case "fable_git_log_probe" 'git -C ~/Documents/PRDs pull -q --rebase && git log --oneline -1' "toolu_3" 2

# 4. sonnet + ssh -> allow (gate doesn't apply outside fable/opus)
add_line "$WORKDIR/sonnet_ssh.jsonl" "claude-sonnet-5" "toolu_4" false
run_case "sonnet_ssh" "ssh orch df" "toolu_4" 0

# 5. fable + override flag -> allow once, flag consumed
OVERRIDE_FLAG="${HOME}/.claude/.allow-fable-bash"
add_line "$WORKDIR/fable_override.jsonl" "claude-fable-5-1" "toolu_5" false
touch "$OVERRIDE_FLAG"
run_case "fable_override" 'ssh orch "df -h"' "toolu_5" 0
if [ -f "$OVERRIDE_FLAG" ]; then
    FAIL=$((FAIL+1))
    echo "FAIL  fable_override_flag_consumed (flag still present)"
    rm -f "$OVERRIDE_FLAG"
else
    PASS=$((PASS+1))
    echo "PASS  fable_override_flag_consumed"
fi

# 6. fable + bare grep probe -> deny
add_line "$WORKDIR/fable_grep_probe.jsonl" "claude-fable-5-1" "toolu_6" false
run_case "fable_grep_probe" "grep -c x MEMORY.md" "toolu_6" 2

# 7. haiku SIDECHAIN (subagent) line sharing a transcript that also has a
#    fable main-line -> the subagent's own call must resolve to haiku and
#    allow, even though the same file also carries a fable line (this is
#    the exact 2026-09-20 incident shape: parent fable + child haiku runner
#    sharing one transcript_path).
add_line "$WORKDIR/mixed_sidechain.jsonl" "claude-fable-5-1" "toolu_parent" false
add_line "$WORKDIR/mixed_sidechain.jsonl" "claude-haiku-4-5" "toolu_child" true
run_case "haiku_sidechain_ssh" "ssh orch df" "toolu_child" 0 "mixed_sidechain"

# 8. fable MAIN line in that same shared transcript -> still denied
run_case "fable_main_in_shared_transcript_ssh" "ssh orch df" "toolu_parent" 2 "mixed_sidechain"

# 9. tool_use_id not present anywhere in the transcript -> unknown -> allow
add_line "$WORKDIR/not_found.jsonl" "claude-fable-5-1" "toolu_9" false
run_case "tool_use_id_not_found" "ssh orch df" "toolu_missing" 0

# 10. touch/rm of an allow-* flag is allowed under every model (escape
#     hatch can never itself be trapped), even without a matching
#     tool_use_id or transcript.
add_line "$WORKDIR/flag_escape.jsonl" "claude-fable-5-1" "toolu_10" false
run_case "touch_allow_flag_always_allowed" "touch ~/.claude/.allow-fable-bash" "toolu_missing" 0

echo "probe-gate-selftest: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
