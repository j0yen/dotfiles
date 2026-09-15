#!/usr/bin/env bash
# summa-hooks-selftest.sh — selftest for the summa hook trio
# (summa-lookup-inject.sh / summa-answer-candidate.sh /
# summa-candidates-start.sh) and settings.json wiring.
#
# Not wired into any hook. Run directly: bash summa-hooks-selftest.sh

set -uo pipefail

SCRIPTS_DIR="$HOME/dotfiles/.claude/scripts"
LOOKUP="$SCRIPTS_DIR/summa-lookup-inject.sh"
CANDIDATE="$SCRIPTS_DIR/summa-answer-candidate.sh"
SYNC="$SCRIPTS_DIR/summa-vault-sync.sh"

OK=0
FAIL=0
fail_names=()

ok() { OK=$((OK + 1)); echo "ok"; }
fail() { FAIL=$((FAIL + 1)); fail_names+=("$1"); echo "FAIL $1"; }

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# ---- Fixture vault -------------------------------------------------------
mkdir -p "$tmp/vault/wiki/answers" "$tmp/vault/wiki/entities"

cat > "$tmp/vault/wiki/answers/2026-09-01-casper-burst-provisioning.md" <<'EOF'
---
summa: answer
question: "How does casper burst provisioning work end to end?"
asked: 2026-09-01T00:00:00Z
cites: []
---

body text.
EOF

cat > "$tmp/vault/wiki/answers/2026-09-02-wintermute-hub-decision.md" <<'EOF'
---
summa: answer
question: "What did we decide about the Wintermute Hub downsize?"
asked: 2026-09-02T00:00:00Z
cites: []
---

body text.
EOF

touch "$tmp/vault/wiki/entities/Wintermute Hub.md"
touch "$tmp/vault/wiki/entities/Hub.md"
touch "$tmp/vault/wiki/entities/Casper.md"

LEDGER="$tmp/ledger.jsonl"

run_lookup() {
    local prompt="$1" sid="$2"
    printf '{"prompt":%s,"session_id":%s}' "$(jq -Rn --arg p "$prompt" '$p')" "$(jq -Rn --arg s "$sid" '$s')" \
        | SUMMA_VAULT="$tmp/vault" SUMMA_LEDGER="$LEDGER" bash "$LOOKUP"
}

# ---- Case 1: answer keyword hit -----------------------------------------
out="$(run_lookup "how does casper burst provisioning work end to end" "c1")"
if printf '%s' "$out" | grep -q 'answer  wiki/answers/' \
    && grep -q '"sid":"c1".*"result":"hit"' "$LEDGER"; then
    ok
else
    fail "case1_answer_hit"
fi

# ---- Case 2: entity whole-word hit, short name excluded -----------------
out="$(run_lookup "what did we decide about the Wintermute Hub downsize" "c2")"
if printf '%s' "$out" | grep -qF 'entity  wiki/entities/Wintermute Hub.md' \
    && ! printf '%s' "$out" | grep -qF 'wiki/entities/Hub.md'; then
    ok
else
    fail "case2_entity_hit"
fi

# ---- Case 3: miss ---------------------------------------------------------
out="$(run_lookup "completely unrelated banana question right now" "c3")"
if [ -z "$out" ] && grep -q '"sid":"c3".*"result":"miss"' "$LEDGER"; then
    ok
else
    fail "case3_miss"
fi

# ---- Case 4: prompt <12 chars ---------------------------------------------
before_lines=$(wc -l < "$LEDGER")
out="$(run_lookup "short" "c4")"
after_lines=$(wc -l < "$LEDGER")
if [ -z "$out" ] && [ "$before_lines" -eq "$after_lines" ]; then
    ok
else
    fail "case4_short_prompt"
fi

# ---- Case 5: /slash prompt -------------------------------------------------
before_lines=$(wc -l < "$LEDGER")
out="$(run_lookup "/summa ask something long enough here" "c5")"
after_lines=$(wc -l < "$LEDGER")
if [ -z "$out" ] && [ "$before_lines" -eq "$after_lines" ]; then
    ok
else
    fail "case5_slash_prompt"
fi

# ---- Case 6: stopwords/short-tokens only -----------------------------------
before_lines=$(wc -l < "$LEDGER")
out="$(run_lookup "what this that with from when where" "c6")"
after_lines=$(wc -l < "$LEDGER")
if [ -z "$out" ] && [ "$before_lines" -eq "$after_lines" ]; then
    ok
else
    fail "case6_stopwords_only"
fi

# ---- Case 7: wall time + hit on the REAL vault -----------------------------
real_ledger="$tmp/real_ledger.jsonl"
t0=$(date +%s%N)
out="$(printf '{"prompt":"what did we decide about the Wintermute Hub downsize","session_id":"c7"}' \
    | SUMMA_VAULT="$HOME/Notes" SUMMA_LEDGER="$real_ledger" bash "$LOOKUP")"
t1=$(date +%s%N)
elapsed_ms=$(( (t1 - t0) / 1000000 ))
if [ "$elapsed_ms" -lt 300 ] && printf '%s' "$out" | grep -qF 'Wintermute Hub.md'; then
    ok
else
    fail "case7_real_vault_wall_time (elapsed_ms=$elapsed_ms)"
fi
echo "case7 elapsed_ms=$elapsed_ms"

# ---- Case 8: Stop hook emits a draft ---------------------------------------
projdir="$HOME/.claude/projects/-home-jsy"
mkdir -p "$projdir"
sid8="selftest-summa-c8-$$"
sess8="$projdir/$sid8.jsonl"
long_answer="$(python3 -c "print('This is a detailed answer about casper burst provisioning. ' * 10)" 2>/dev/null || printf 'This is a detailed answer about casper burst provisioning. %.0s' {1..10})"
python3 - "$sess8" "$long_answer" <<'PYEOF' 2>/dev/null
import json, sys
sess_file, answer = sys.argv[1], sys.argv[2]
recs = [
  {"type": "user", "message": {"role": "user", "content": "How does casper burst provisioning work end to end for the fleet?"}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": answer}]}},
]
with open(sess_file, "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PYEOF

cand_dir8="$tmp/candidates8"
run_candidate() {
    local sid="$1" ledger="$2" dir="$3"
    printf '{"session_id":"%s"}' "$sid" \
        | SUMMA_LEDGER="$ledger" SUMMA_ANSWER_CANDIDATES_DIR="$dir" bash "$CANDIDATE"
}

run_candidate "$sid8" "$tmp/ledger8.jsonl" "$cand_dir8"
if [ -f "$cand_dir8/$sid8.md" ] && grep -q 'summa: answer-draft' "$cand_dir8/$sid8.md"; then
    ok
else
    fail "case8_stop_emit"
fi

# ---- Case 9: same sid again -> duplicate, no second file ------------------
before_count=$(find "$cand_dir8" -maxdepth 1 -name '*.md' | wc -l)
run_candidate "$sid8" "$tmp/ledger8.jsonl" "$cand_dir8"
after_count=$(find "$cand_dir8" -maxdepth 1 -name '*.md' | wc -l)
if [ "$before_count" -eq "$after_count" ] && grep -q "session=$sid8 decision=duplicate" "$cand_dir8/.audit.log"; then
    ok
else
    fail "case9_duplicate"
fi

# ---- Case 10: no question-shaped prompt -> below_threshold, no file -------
sid10="selftest-summa-c10-$$"
sess10="$projdir/$sid10.jsonl"
python3 - "$sess10" "$long_answer" <<'PYEOF' 2>/dev/null
import json, sys
sess_file, answer = sys.argv[1], sys.argv[2]
recs = [
  {"type": "user", "message": {"role": "user", "content": "Please just go fix the burst provisioning script right now for me."}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": answer}]}},
]
with open(sess_file, "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PYEOF

cand_dir10="$tmp/candidates10"
run_candidate "$sid10" "$tmp/ledger8.jsonl" "$cand_dir10"
if [ ! -f "$cand_dir10/$sid10.md" ] && grep -q "session=$sid10 decision=below_threshold" "$cand_dir10/.audit.log"; then
    ok
else
    fail "case10_no_question_shaped"
fi

# ---- Case 11: ledger already has a hit for this prompt+sid ----------------
sid11="selftest-summa-c11-$$"
sess11="$projdir/$sid11.jsonl"
prompt11="How does casper burst provisioning work end to end for the fleet?"
python3 - "$sess11" "$long_answer" "$prompt11" <<'PYEOF' 2>/dev/null
import json, sys
sess_file, answer, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
recs = [
  {"type": "user", "message": {"role": "user", "content": prompt}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": answer}]}},
]
with open(sess_file, "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PYEOF

sha11="$(printf '%s' "$prompt11" | sha256sum | cut -c1-12)"
ledger11="$tmp/ledger11.jsonl"
printf '{"ts":"2026-09-15T00:00:00Z","sid":"%s","prompt_sha":"%s","keywords":[],"answers":1,"entities":0,"result":"hit","pages":[]}\n' \
    "$sid11" "$sha11" > "$ledger11"

cand_dir11="$tmp/candidates11"
run_candidate "$sid11" "$ledger11" "$cand_dir11"
if [ ! -f "$cand_dir11/$sid11.md" ] && grep -q "session=$sid11 decision=below_threshold" "$cand_dir11/.audit.log"; then
    ok
else
    fail "case11_ledger_hit_suppresses"
fi

rm -f "$sess8" "$sess10" "$sess11"

# ---- Case 12: settings.json wiring -----------------------------------------
settings="$HOME/.claude/settings.json"
if jq empty "$settings" >/dev/null 2>&1 \
    && jq -e '.hooks.UserPromptSubmit[].hooks[]?.command | select(endswith("summa-lookup-inject.sh"))' "$settings" >/dev/null 2>&1 \
    && jq -e '.hooks.Stop[].hooks[]?.command | select(endswith("summa-answer-candidate.sh"))' "$settings" >/dev/null 2>&1 \
    && jq -e '.hooks.SessionStart[].hooks[]?.command | select(endswith("summa-candidates-start.sh"))' "$settings" >/dev/null 2>&1 \
    && jq -e '.hooks.SessionStart[].hooks[]?.command | select(endswith("summa-vault-sync.sh"))' "$settings" >/dev/null 2>&1; then
    ok
else
    fail "case12_settings_wiring"
fi

# ---- Case 13: entity match is case-insensitive but prints ORIGINAL case ---
out="$(run_lookup "we need to talk about wintermute hub capacity today" "c13")"
if printf '%s' "$out" | grep -qF 'entity  wiki/entities/Wintermute Hub.md' \
    && ! printf '%s' "$out" | grep -qF 'wiki/entities/wintermute hub.md'; then
    ok
else
    fail "case13_entity_case_preserved"
fi

# ---- Case 14: harness-injected prompt (system-reminder) is skipped --------
before_lines=$(wc -l < "$LEDGER")
out="$(printf '{"prompt":%s,"session_id":%s}' \
        "$(jq -Rn --arg p $'<system-reminder>\n[SYSTEM NOTIFICATION - NOT USER INPUT] casper burst provisioning downsize' '$p')" \
        "$(jq -Rn --arg s "c14" '$s')" \
    | SUMMA_VAULT="$tmp/vault" SUMMA_LEDGER="$LEDGER" bash "$LOOKUP")"
after_lines=$(wc -l < "$LEDGER")
if [ -z "$out" ] && [ "$before_lines" -eq "$after_lines" ]; then
    ok
else
    fail "case14_injected_prompt_skipped"
fi

# ---- Case 15: answer-candidate skips <cross-session-message content -------
sid15="selftest-summa-c15-$$"
sess15="$projdir/$sid15.jsonl"
python3 - "$sess15" "$long_answer" <<'PYEOF' 2>/dev/null
import json, sys
sess_file, answer = sys.argv[1], sys.argv[2]
recs = [
  {"type": "user", "message": {"role": "user", "content": '<cross-session-message from="other">How does casper burst provisioning work end to end for the fleet?</cross-session-message>'}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": answer}]}},
]
with open(sess_file, "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PYEOF

cand_dir15="$tmp/candidates15"
run_candidate "$sid15" "$tmp/ledger8.jsonl" "$cand_dir15"
if [ ! -f "$cand_dir15/$sid15.md" ] && grep -q "session=$sid15 decision=below_threshold" "$cand_dir15/.audit.log"; then
    ok
else
    fail "case15_cross_session_message_skipped"
fi
rm -f "$sess15"

# ---- Case 16: hermes-mode hit -> {"context":...} with the wiki path -------
hermes_payload() {
    local msg="$1" sid="$2"
    jq -n --arg m "$msg" --arg s "$sid" \
        '{hook_event_name:"pre_llm_call",tool_name:null,tool_input:null,session_id:$s,cwd:"/home/jsy",extra:{user_message:$m,turn_id:"t1",task_id:1,is_first_turn:true,conversation_history:[]}}'
}

hermes_ledger="$tmp/hermes_ledger.jsonl"
out="$(hermes_payload "what did we decide about the wintermute hub downsize" "h16" \
    | SUMMA_VAULT="$tmp/vault" SUMMA_LEDGER="$hermes_ledger" bash "$LOOKUP")"
ctx="$(printf '%s' "$out" | jq -r '.context // empty' 2>/dev/null)"
if printf '%s' "$out" | jq empty >/dev/null 2>&1 \
    && printf '%s' "$ctx" | grep -qF 'wiki/entities/Wintermute Hub.md'; then
    ok
else
    fail "case16_hermes_hit"
fi

# ---- Case 17: hermes-mode second call, same sid+prompt -> no output/ledger
before_lines=$(wc -l < "$hermes_ledger")
out2="$(hermes_payload "what did we decide about the wintermute hub downsize" "h16" \
    | SUMMA_VAULT="$tmp/vault" SUMMA_LEDGER="$hermes_ledger" bash "$LOOKUP")"
after_lines=$(wc -l < "$hermes_ledger")
if [ -z "$out2" ] && [ "$before_lines" -eq "$after_lines" ]; then
    ok
else
    fail "case17_hermes_dedupe_per_turn"
fi

# ---- Case 18: hermes-mode miss -> empty stdout (not {}), ledger miss line -
out3="$(hermes_payload "completely unrelated banana question right now" "h18" \
    | SUMMA_VAULT="$tmp/vault" SUMMA_LEDGER="$hermes_ledger" bash "$LOOKUP")"
last_line="$(tail -n1 "$hermes_ledger")"
if [ -z "$out3" ] && [ "$out3" != "{}" ] \
    && printf '%s' "$last_line" | jq -e '.sid=="h18" and .result=="miss" and .mode=="hermes"' >/dev/null 2>&1; then
    ok
else
    fail "case18_hermes_miss"
fi

# ---- summa-vault-sync.sh fixtures ------------------------------------------
sync_tmp="$tmp/sync"
mkdir -p "$sync_tmp"
bare="$sync_tmp/bare.git"
git init --quiet --bare -b main "$bare" >/dev/null 2>&1

seed="$sync_tmp/seed"
git clone --quiet "$bare" "$seed" >/dev/null 2>&1
git -C "$seed" config user.email test@test.com
git -C "$seed" config user.name Test
mkdir -p "$seed/wiki"
echo "seed" > "$seed/wiki/log.md"
git -C "$seed" add wiki/log.md
git -C "$seed" commit --quiet -m seed
git -C "$seed" push --quiet -u origin main >/dev/null 2>&1

# ---- Case 19: clone-if-absent -----------------------------------------------
vault19="$sync_tmp/vault19"
sync_log19="$sync_tmp/sync19.log"
out="$(SUMMA_VAULT="$vault19" SUMMA_VAULT_REMOTE="$bare" SYNC_LOG="$sync_log19" bash "$SYNC")"
if [ -z "$out" ] && [ -d "$vault19/.git" ] && grep -q ' clone ok$' "$sync_log19"; then
    ok
else
    fail "case19_vault_sync_clone_if_absent"
fi

# ---- Case 20: pull with a local untracked file preserved (no divergence) --
vault20="$sync_tmp/vault20"
git clone --quiet "$bare" "$vault20" >/dev/null 2>&1
git -C "$vault20" config user.email test@test.com
git -C "$vault20" config user.name Test
echo "untracked" > "$vault20/scratch-untracked.txt"
echo "remote-only update" > "$seed/wiki/case20.md"
git -C "$seed" add wiki/case20.md
git -C "$seed" commit --quiet -m "case20 remote update"
git -C "$seed" push --quiet >/dev/null 2>&1

sync_log20="$sync_tmp/sync20.log"
out="$(SUMMA_VAULT="$vault20" SYNC_LOG="$sync_log20" bash "$SYNC")"
if [ -z "$out" ] && [ -f "$vault20/scratch-untracked.txt" ] \
    && [ -f "$vault20/wiki/case20.md" ] && grep -q ' pull ok$' "$sync_log20"; then
    ok
else
    fail "case20_vault_sync_pull_preserves_untracked"
fi

# ---- Case 21: diverged local commit — autostash + rebase succeeds --------
vault21="$sync_tmp/vault21"
git clone --quiet "$bare" "$vault21" >/dev/null 2>&1
git -C "$vault21" config user.email test@test.com
git -C "$vault21" config user.name Test
echo "another untracked" > "$vault21/scratch-untracked.txt"
echo "local entity" > "$vault21/wiki/case21-local.md"
git -C "$vault21" add wiki/case21-local.md
git -C "$vault21" commit --quiet -m "case21 local divergent commit"
echo "remote entity" > "$seed/wiki/case21-remote.md"
git -C "$seed" add wiki/case21-remote.md
git -C "$seed" commit --quiet -m "case21 remote update"
git -C "$seed" push --quiet >/dev/null 2>&1

sync_log21="$sync_tmp/sync21.log"
out="$(SUMMA_VAULT="$vault21" SYNC_LOG="$sync_log21" bash "$SYNC")"
if [ -z "$out" ] && [ -f "$vault21/scratch-untracked.txt" ] \
    && [ -f "$vault21/wiki/case21-local.md" ] && [ -f "$vault21/wiki/case21-remote.md" ] \
    && git -C "$vault21" log --oneline | grep -q "case21 local divergent commit" \
    && grep -q ' pull ok$' "$sync_log21"; then
    ok
else
    fail "case21_vault_sync_diverged_rebase_succeeds"
fi

# ---- Case 22: remote unreachable -> logs fail, exits 0, within timeout ----
vault22="$sync_tmp/vault22"
mkdir -p "$vault22/wiki"
git init --quiet "$vault22" >/dev/null 2>&1
git -C "$vault22" config user.email test@test.com
git -C "$vault22" config user.name Test
git -C "$vault22" remote add origin "https://127.0.0.1:1/no-such-repo.git"
echo x > "$vault22/wiki/log.md"
git -C "$vault22" add wiki/log.md
git -C "$vault22" commit --quiet -m x

sync_log22="$sync_tmp/sync22.log"
t0=$(date +%s)
out="$(timeout 50 env SUMMA_VAULT="$vault22" SYNC_LOG="$sync_log22" bash "$SYNC")"
rc=$?
t1=$(date +%s)
elapsed=$((t1 - t0))
if [ -z "$out" ] && [ "$rc" -eq 0 ] && [ "$elapsed" -lt 50 ] && grep -q ' pull fail ' "$sync_log22"; then
    ok
else
    fail "case22_vault_sync_remote_unreachable (rc=$rc elapsed=${elapsed}s)"
fi

echo "$OK ok, $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %s\n' "${fail_names[*]}"
    exit 1
fi
exit 0
