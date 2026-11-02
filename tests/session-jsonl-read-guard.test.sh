#!/usr/bin/env bash
# shellcheck disable=SC2088,SC2319  # tilde is fixture text; check NAME $? deliberately reads the preceding test
# session-jsonl-read-guard.sh: raw reads of truth-tier session JSONL are refused (exit 2); session-read.sh, listings and
# unrelated paths are allowed (exit 0). Hook-JSON fixture strings only: no real session file is ever touched; the mutation
# and everything else lives under this test's own mktemp -d.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
gate="$here/.claude/hooks/session-jsonl-read-guard.sh"
S="$here/.claude/settings.json"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }
D=/home/jsy/.local/state/synthorg/oneshot-root-X/truth-tier-a/sessions
rc_of() { # rc_of <gate> <json>
    local rc=0; printf '%s' "$2" | bash "$1" >/dev/null 2>"$tmp/err" || rc=$?; echo "$rc"
}
bash_json() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},session_id:"s"}'; }
want() { # want <rc> <name> <command>
    local got; got=$(rc_of "$gate" "$(bash_json "$3")")
    [ "$got" = "$1" ]; check "$2 (rc=$got want $1)" $?
    if [ "$1" = 2 ]; then grep -q 'session-read.sh' "$tmp/err"; check "$2 stderr names session-read.sh" $?; fi
}
# ---- refused: the brief's fixtures
want 2 ssh-cat           "ssh orch \"cat $D/s.jsonl\""
want 2 grep-key          "grep key $D/s.jsonl"
want 2 python-no-marker  "python3 -c 'import sys; print(open(\"$D/s.jsonl\").read())'"
want 2 python-counts-marker "python3 -c '# counts-only
print(len(open(\"$D/s.jsonl\").readlines()))'"
# ---- refused: bypass fixtures
want 2 chain-after-allowed "~/.claude/hooks/session-read.sh $D/x.jsonl; cat $D/s.jsonl"
want 2 find-exec-cat     "find $D -name '*.jsonl' -exec cat {} +"
want 2 ls-xargs-cat      "ls $D/*.jsonl | xargs cat"
want 2 ssh-cd-cat        "ssh orch 'cd /home/jsy/.local/state/synthorg/oneshot-root-X/truth-tier-a && cat sessions/s.jsonl'"
want 2 rsync             "rsync orch:$D/ /tmp/s/"
want 2 ssh-tar           "ssh orch 'tar cz $D' | tar xz"
want 2 python-env-p      "p=$D/s.jsonl; python3 -c 'import os;print(open(os.environ[\"p\"]).read())'"
want 2 python-env-prefix "p=$D/s.jsonl python3 -c 'import os;print(open(os.environ[\"p\"]).read())'"
want 2 relative-script   "./session-read.sh $D/s.jsonl"
want 2 basename-script   "session-read.sh $D/s.jsonl"
want 2 lookalike-path    "/tmp/evil/session-read.sh $D/s.jsonl"
want 2 var-glob          'd=/home/jsy/.local/state/synthorg; cat $d/*/truth-tier-*/sessions/*.jsonl'
want 2 heredoc-python    "python3 - <<EOF
print(open('$D/s.jsonl').read()); x = 1
EOF"
want 2 ls-while-cat      "ls $D/*.jsonl | while read f; do cat \$f; done"
want 2 ls-pipe-sh        "ls $D/*.jsonl | sh"
want 2 cmdsub-arg        "~/.claude/hooks/session-read.sh \$(cat $D/s.jsonl)"
want 2 backtick-arg      "ls \`cat $D/s.jsonl\`"
want 2 redirect-in       "head -3 < $D/s.jsonl"
want 2 awk               "awk '{print}' $D/s.jsonl"
want 2 sqlite3           "sqlite3 :memory: '.import $D/s.jsonl t'"
want 2 perl              "perl -ne print $D/s.jsonl"
want 2 jsonl-gz          "zcat /x/sessions/s.jsonl.gz"
want 2 truth-tier-only   "cd /x/truth-tier-b"
want 2 ls-process-subst  "ls $D <(cat $D/s.jsonl)"
want 2 ssh-opts-cat      "ssh -o ConnectTimeout=15 -i /k orch cat $D/s.jsonl"
# ---- refused: Read / Grep
read_json() { jq -cn --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p}}'; }
grep_json() { jq -cn --arg p "$1" --arg g "$2" '{tool_name:"Grep",tool_input:{pattern:"key",path:$p,glob:$g}}'; }
[ "$(rc_of "$gate" "$(read_json "$D/s.jsonl")")" = 2 ]; check "read-session-path" $?
[ "$(rc_of "$gate" "$(read_json "$D/s.jsonl.gz")")" = 2 ]; check "read-session-path-gz" $?
[ "$(rc_of "$gate" "$(grep_json "$D" "")")" = 2 ]; check "grep-truth-tier-path" $?
[ "$(rc_of "$gate" "$(grep_json "/home/jsy/.local/state/synthorg" "*.jsonl")")" = 2 ]; check "grep-synthorg-state-jsonl-glob" $?
[ "$(rc_of "$gate" "$(grep_json "/home/jsy" "**/truth-tier-*/sessions/*.jsonl")")" = 2 ]; check "grep-glob-truth-tier" $?
# ---- allowed
want 0 session-read-old-path   "~/.cache/r7-seat/session-read.sh $D/s.jsonl"
want 0 session-read-new-path   "~/.claude/hooks/session-read.sh $D/s.jsonl"
want 0 session-read-counts     "\$HOME/.claude/hooks/session-read.sh --counts $D/a.jsonl $D/b.jsonl"
want 0 session-read-abs-home   "$HOME/.claude/hooks/session-read.sh --counts $D/a.jsonl 2>&1 | head -5"
want 0 session-read-over-ssh   "ssh orch '~/.claude/hooks/session-read.sh $D/s.jsonl'"
want 0 ls-dir                  "ls $D/"
want 0 ls-ssh                  "ssh orch ls $D/"
want 0 wc-l-glob               "wc -l $D/*.jsonl"
want 0 wc-l-redirect           "wc -l < $D/s.jsonl"
want 0 find-name               "find $D -name '*.jsonl'"
want 0 unrelated-cat-jsonl     "cat ~/x.jsonl"
want 0 unrelated-git           "git status --short"
want 0 unrelated-sessions-dir  "ls ~/sessions/ && cat ~/sessions/notes.md"
[ "$(rc_of "$gate" '{"tool_name":"Edit","tool_input":{"file_path":"/x/truth-tier-a/sessions/s.jsonl"}}')" = 0 ]; check "other-tool-edit-allowed" $?
[ "$(rc_of "$gate" "$(read_json /home/jsy/x.jsonl)")" = 0 ]; check "read-unrelated" $?
[ "$(rc_of "$gate" "$(grep_json /home/jsy/synthorg/src "*.rs")")" = 0 ]; check "grep-bare-synthorg-checkout-allowed" $?
[ "$(rc_of "$gate" 'not json')" = 0 ]; check "garbage-input-fail-open" $?
# ---- mutation: the allow branch removed from a copy must refuse the allowed fixture (executed negative test)
mut="$tmp/mut"; mkdir -p "$mut"
sed '/^    "\$allow1"|/,/;;$/d' "$gate" > "$mut/guard.sh"
! cmp -s "$gate" "$mut/guard.sh"; check "mutation-applied (allow branch removed)" $?
[ "$(rc_of "$mut/guard.sh" "$(bash_json "~/.cache/r7-seat/session-read.sh $D/s.jsonl")")" = 2 ]; check "mutation-red: allowed session-read fixture now exits 2" $?
[ "$(rc_of "$gate" "$(bash_json "~/.cache/r7-seat/session-read.sh $D/s.jsonl")")" = 0 ]; check "unmutated-green: same fixture exits 0" $?
# ---- wiring
jq -e . "$S" >/dev/null; check "settings-parses" $?
jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command] | any(endswith("/probe-gate.sh")) and any(endswith("/session-jsonl-read-guard.sh"))' "$S" >/dev/null; check "bash-group-has-probe-gate-and-guard" $?
jq -e '[.hooks.PreToolUse[] | select(.matcher=="Read|Grep") | .hooks[] | select(.command=="/home/jsy/.claude/hooks/session-jsonl-read-guard.sh" and .timeout==5)] | length==1' "$S" >/dev/null; check "read-grep-group-registered" $?
jq -e '[.hooks[][].hooks[].command | select(test("session-jsonl-read-guard[.]sh"))] | length==2' "$S" >/dev/null; check "registered-twice-overall" $?
[ -x "$gate" ] && [ -x "$here/.claude/hooks/session-read.sh" ]; check "hooks-executable" $?
"$here/.claude/hooks/session-read.sh" --selftest | grep -q 'SELFTEST OK'; check "session-read-selftest (filter + --counts)" $?
# ---- timing: 100 runs of a matched, allowed command; median under 50 ms
fx=$(bash_json "~/.claude/hooks/session-read.sh --counts $D/a.jsonl $D/b.jsonl")
ts=()
for _ in $(seq 100); do a=$EPOCHREALTIME; printf '%s' "$fx" | bash "$gate" >/dev/null 2>&1; b=$EPOCHREALTIME; ts+=($(( (${b/./} - ${a/./}) )) ); done
med=$(printf '%s\n' "${ts[@]}" | sort -n | sed -n 50p)
echo "timing median ${med} us over 100 runs"
[ "$med" -lt 50000 ]; check "median-under-50ms" $?
echo "session-jsonl-read-guard.test: $pass passed, $fail failed"
[ "$fail" = 0 ]
