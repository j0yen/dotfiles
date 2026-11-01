#!/usr/bin/env bash
# mcphost-stamp-gate.sh: PreToolUse Bash hook that warns (then, after DEPLOY_TS + 24 h, blocks) a KEYLESS WRITE to the
# mcphost hub, because the hub stamps a tenant synthetic at creation only when the request carries
# `x-mcphost-synthetic: <label>`. Also covers the premise-sandbox.sh stamp + one-time key migration (part A).
#
# KNOWN GAPS (the hook does NOT cover these; nothing here claims it does):
#   1. MCP-tool signups through Claude Code's mcp__mcphost__* tools (not a Bash command).
#   2. Scripts that read the hub URL from a file or env: the Bash command the hook sees never names the hub.
#   3. Non-Bash tools (WebFetch, Write of a script that is run later, python/node HTTP from inside a script, ...).
# Also: a `-d @file` that holds a tenant_key is treated as keyless (the body is hidden) and warns; that is a known
# false positive, resolved by adding the header.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/mcphost-stamp-gate.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

# the recorded switch time, read from the hook itself
deploy_ts=$(sed -n 's/^DEPLOY_TS="\(.*\)"$/\1/p' "$hook"); warn_h=$(sed -n 's/^WARN_HOURS=\(.*\)$/\1/p' "$hook")
deploy=$(date -d "$deploy_ts" +%s); block=$(( deploy + warn_h * 3600 ))
echo "info DEPLOY_TS=$deploy_ts WARN_HOURS=$warn_h BLOCK_AT=$(date -d "@$block" -Is)"

# run <name> <want_rc> <want_stderr_regex|-> <now_epoch> <command>
run() {
  local name="$1" want="$2" re="$3" now="$4" cmd="$5" rc=0 err
  err=$(jq -cn --arg c "$cmd" --arg d "$tmp/work" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | env HOME="$tmp" MCPHOST_STAMP_GATE_SELFTEST=1 MCPHOST_STAMP_GATE_NOW="$now" bash "$hook" 2>&1 >/dev/null) || rc=$?; err=$(printf "%s" "$err" | tr "\n" " ")
  if [ "$rc" != "$want" ]; then bad "$name (rc=$rc want $want)"; return; fi
  if [ "$re" != "-" ] && ! grep -qE "$re" <<<"$err"; then bad "$name (stderr lacks /$re/: $err)"; return; fi
  if [ "$re" = "-" ] && [ -n "$err" ]; then bad "$name (unexpected stderr: $err)"; return; fi
  ok "$name (rc=$rc)"
}
early=$(( deploy + 3600 )); late=$(( block + 60 ))
HDR='x-mcphost-synthetic: <label>'
RPC='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"signup","arguments":{"name":"x"}}}'

# --- pass fixtures (rc 0, silent) --------------------------------------------------------------------------------
run pass-get-healthz        0 - "$late" "curl -s https://mcphost.dev/healthz"
run pass-get-status         0 - "$late" "curl -s https://mcphost.dev/status.json | jq ."
run pass-head               0 - "$late" "curl -sI https://mcphost.dev/mcp"
run pass-wellknown-post     0 - "$late" "curl -s -X POST https://mcphost.dev/.well-known/x -d '{}'"
run pass-authorization      0 - "$late" "curl -s -X POST https://mcphost.dev/mcp -H 'Authorization: Bearer abc' -d '$RPC'"
run pass-synthetic-header   0 - "$late" "curl -s -X POST https://mcphost.dev/mcp -H 'x-mcphost-synthetic: harness:t' -d '$RPC'"
run pass-tenant-key-body    0 - "$late" "curl -s https://mcphost.dev/mcp -d '{\"arguments\":{\"tenant_key\":\"K\"}}'"
run pass-other-host         0 - "$late" "curl -s -X POST https://example.com/mcp -d '$RPC'"
run pass-not-http-client    0 - "$late" "echo mcphost.dev -d x"
run pass-fail-flag-get      0 - "$late" "curl -f https://mcphost.dev/mcp"

# --- warn fixtures (before 24 h: rc 0 + stderr naming the header) -------------------------------------------------
run warn-inline-body        0 "WARN.*x-mcphost-synthetic: <label>" "$early" "curl -s -X POST https://mcphost.dev/mcp -H 'Content-Type: application/json' -d '$RPC'"
printf '%s' "$RPC" > "$tmp/body.json"
run warn-data-at-file       0 "WARN.*x-mcphost-synthetic: <label>" "$early" "curl -s https://mcphost.dev/mcp --data @$tmp/body.json"
run warn-short-d-at-file    0 "WARN" "$early" "curl -s https://mcphost.dev/mcp -d@$tmp/body.json"
run warn-env-url            0 "WARN" "$early" "curl -s \"\$MCPHOST_URL\" -d @$tmp/body.json"
run warn-ssh-wrapped        0 "WARN" "$early" "ssh orch \"curl -s -X POST https://mcphost.dev/mcp -d '$RPC'\""

# --- block fixtures (after 24 h: rc 2) ----------------------------------------------------------------------------
run block-inline-body       2 "BLOCKED.*x-mcphost-synthetic: <label>" "$late" "curl -s -X POST https://mcphost.dev/mcp -H 'Content-Type: application/json' -d '$RPC'"
run block-data-at-file      2 "BLOCKED" "$late" "curl -s https://mcphost.dev/mcp --data @$tmp/body.json"
run block-www-host          2 "BLOCKED" "$late" "curl -s --json '$RPC' https://www.mcphost.dev/mcp"

# --- segment scoping (PR #72 replay: 94 of 129 flags were incidental) ---------------------------------------------------
# incidental text in OTHER segments / quoted text must not warn (these WARNed before the per-segment rewrite)
run seg-awk-F-pipe          0 - "$late" "curl -s https://mcphost.dev/ | awk -F'|' '{print \$1}'"
run seg-paste-sd            0 - "$late" "curl https://mcphost.dev/changelog | paste -sd' '"
run seg-git-log-F           0 - "$late" "curl -s https://mcphost.dev/healthz; git log -F --oneline"
run seg-git-commit-text     0 - "$late" "git commit -m \"fix curl https://mcphost.dev signup\""
run seg-git-commit-text-x   0 - "$late" "git commit -m \"docs: curl -X POST https://mcphost.dev/mcp -d tools/call signup\""
run seg-echo-text           0 - "$late" "echo 'curl -X POST https://mcphost.dev/mcp tools/call'"
run seg-heredoc-text        0 - "$late" $'cat <<EOF\ncurl -X POST https://mcphost.dev/mcp -d \'{"method":"tools/call"}\'\nEOF'
run seg-comment-text        0 - "$late" "ls # curl -X POST https://mcphost.dev/mcp -d signup"
run seg-get-with-other-d    0 - "$late" "curl -s https://mcphost.dev/mcp && cut -d: -f1 /etc/passwd"
run seg-header-value-d      0 - "$late" "curl -s -H 'X-Note: -d' https://mcphost.dev/mcp"
run seg-write-flag-elsewhere 0 - "$late" "curl -s https://mcphost.dev/mcp; curl -s -d x https://example.com/y"
run seg-wget-get            0 - "$late" "wget -qO- https://mcphost.dev/mcp; sort -F x"
# body policy: keyless initialize / tools/list / ping create no tenant, so they do not warn; signup / tools/call / unreadable do
run policy-initialize-ok    0 - "$late" "curl -s -X POST https://mcphost.dev/mcp -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}'"
run policy-tools-list-ok    0 - "$late" "curl -s https://mcphost.dev/mcp --json '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}'"
run policy-ping-ok          0 - "$late" "curl -s https://mcphost.dev/mcp -sd '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}'"
run policy-post-no-body-ok  0 - "$late" "curl -s -X POST https://mcphost.dev/mcp"
run policy-signup-url       2 "BLOCKED" "$late" "curl -s -X POST https://mcphost.dev/signup"
run policy-var-body-probe-ok 0 - "$late" "for m in initialize ping; do curl -s https://mcphost.dev/mcp -d \"{\\\"method\\\":\\\"\$m\\\"}\"; done"
run policy-var-body-tools-call 2 "BLOCKED" "$late" "B='$RPC'; curl -s https://mcphost.dev/mcp -d \"\$B\""
run policy-var-body-with-key-ok 0 - "$late" "B=\$(jq -cn --arg k \"\$K\" '{params:{arguments:{tenant_key:\$k}},method:\"tools/call\"}'); curl -s https://mcphost.dev/mcp -d \"\$B\""
run policy-file-body-with-key-ok 0 - "$late" "echo '{\"tenant_key\":\"K\"}' > b.json; curl -s https://mcphost.dev/mcp -d @b.json"
run policy-stdin-body       2 "BLOCKED" "$late" "cat x.json | curl -s https://mcphost.dev/mcp -d @-"
run policy-upload-file      2 "BLOCKED" "$late" "curl -s -T x.json https://mcphost.dev/mcp"
# true positives: write-flag spellings on the curl segment itself
run tp-keyless-post-tools-call 2 "BLOCKED" "$late" "curl -X POST https://mcphost.dev/mcp -d '$RPC'"
run tp-cluster-sd           2 "BLOCKED" "$late" "curl -sd '$RPC' https://mcphost.dev/mcp"
run tp-cluster-sSXPOST      2 "BLOCKED" "$late" "curl -sSXPOST https://mcphost.dev/mcp --data-raw '$RPC'"
run tp-attached-d-file      2 "BLOCKED" "$late" "curl -s https://mcphost.dev/mcp -d@$tmp/body.json"
run tp-form                 2 "BLOCKED" "$late" "curl -s -F 'x=signup' https://mcphost.dev/mcp"
run tp-after-pipe           2 "BLOCKED" "$late" "echo go | curl -s -X POST https://mcphost.dev/mcp -d '$RPC'"
run tp-after-and            2 "BLOCKED" "$late" "cd /tmp && curl -s -X PUT https://mcphost.dev/mcp -d '$RPC' | jq ."
run tp-env-prefix-sudo      2 "BLOCKED" "$late" "FOO=1 sudo timeout 5 curl -s https://mcphost.dev/mcp -d '$RPC'"
run tp-var-assigned-hub     2 "BLOCKED" "$late" "U=https://mcphost.dev/mcp; curl -s \"\$U\" -d '$RPC'"
run tp-env-MCPHOST_HUB      2 "BLOCKED" "$late" "curl -s \"\$MCPHOST_HUB/mcp\" -d '$RPC'"
run tp-ssh-single-quoted    2 "BLOCKED" "$late" "ssh orch 'curl -s -X POST https://mcphost.dev/mcp -d @$tmp/body.json'"
run tp-ssh-var-assigned     2 "BLOCKED" "$late" "U=https://mcphost.dev/mcp; ssh orch 'curl \"\$U\" -d \"{\\\"name\\\":\\\"signup\\\"}\"'"
run tp-ssh-env-url-remote   2 "BLOCKED" "$late" "ssh -o ConnectTimeout=5 orch 'curl \"\$MCPHOST_URL\" -d @/tmp/b.json'"
run tp-ssh-nested           2 "BLOCKED" "$late" "ssh orch 'ssh mcphost-1 \"curl -s https://mcphost.dev/mcp --json @b.json\"'"
run tp-bash-c               2 "BLOCKED" "$late" "bash -c \"curl -s https://mcphost.dev/mcp -d '$RPC'\""
run tp-cmd-subst            2 "BLOCKED" "$late" "out=\$(curl -s https://mcphost.dev/mcp -d '$RPC'); echo \$out"
run tp-wget-post-data       2 "BLOCKED" "$late" "wget -qO- --post-data='$RPC' https://mcphost.dev/mcp"
run tp-wget-method          2 "BLOCKED" "$late" "wget -qO- --method=POST --body-file=b.json https://mcphost.dev/mcp"
run tp-httpie-item          2 "BLOCKED" "$late" "http POST https://mcphost.dev/mcp method=tools/call"
run tp-xh-json-item         2 "BLOCKED" "$late" "xh https://mcphost.dev/mcp name:=\"signup\""
# auth / stamp exemptions are per segment
run auth-this-segment       0 - "$late" "curl -s -H 'Authorization: Bearer abc' https://mcphost.dev/mcp -d '$RPC'"
run auth-user-flag          0 - "$late" "curl -s -u a:b https://mcphost.dev/mcp -d '$RPC'"
run auth-other-segment-no   2 "BLOCKED" "$late" "curl -s -H 'Authorization: Bearer abc' https://example.com/x; curl -s https://mcphost.dev/mcp -d '$RPC'"
run synthetic-in-ssh        0 - "$late" "ssh orch 'curl -s https://mcphost.dev/mcp -H \"x-mcphost-synthetic: harness:t\" -d @b.json'"
run readonly-G-with-d       0 - "$late" "curl -sG https://mcphost.dev/mcp -d 'q=signup'"
# parser-hostile input (unterminated quote / parens) fails open
run failopen-unterminated   0 - "$late" "echo \"curl https://mcphost.dev -d '\$(("

# --- expiry boundary: 1 s before = warn, exactly at = block --------------------------------------------------------
c="curl -s -X POST https://mcphost.dev/mcp -d '$RPC'"
run expiry-1s-before-warns  0 "WARN"    "$(( block - 1 ))" "$c"
run expiry-at-24h-blocks    2 "BLOCKED" "$block"           "$c"
run expiry-before-deploy    0 "WARN"    "$(( deploy - 60 ))" "$c"

# --- the real clock is used unless SELFTEST=1 (a stray NOW env must not weaken the gate) ---------------------------
rc=0; jq -cn --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}' | env HOME="$tmp" MCPHOST_STAMP_GATE_NOW="$early" bash "$hook" >/dev/null 2>&1 || rc=$?
if [ "$(date +%s)" -ge "$block" ]; then want=2; else want=0; fi
[ "$rc" = "$want" ] && ok "clock-override-ignored-without-selftest (rc=$rc)" || bad "clock-override-ignored-without-selftest (rc=$rc want $want)"

# --- fail-open on junk input -----------------------------------------------------------------------------------
printf 'not json' | env HOME="$tmp" bash "$hook" >/dev/null 2>&1 && ok "fail-open-malformed-input" || bad "fail-open-malformed-input"
jq -cn '{tool_name:"Write",tool_input:{command:"curl -d x https://mcphost.dev/mcp"}}' | env HOME="$tmp" bash "$hook" >/dev/null 2>&1 && ok "non-bash-tool-ignored (known gap 3)" || bad "non-bash-tool-ignored"

# --- warn.log: one row per hit, redacted, <= 80 chars of command ------------------------------------------------
log="$tmp/.local/state/mcphost-stamp-gate/warn.log"
secret='key_abcdefghijklmnop1234567890XYZ'
run log-redaction 0 "WARN" "$early" "curl -s -X POST https://mcphost.dev/mcp -H 'X-Token: Bearer $secret' -d '$RPC'"
[ -s "$log" ] && ok "warn.log written" || bad "warn.log missing"
grep -q '<redacted>' "$log" && ok "warn.log shows <redacted> in place of the token" || bad "warn.log has no <redacted> marker"
grep -q "$secret" "$log" && bad "warn.log leaks a key-shaped token" || ok "warn.log redacts key-shaped tokens"
awk -F'\t' 'NF!=4 || length($4)>80 {bad=1} END{exit bad}' "$log" && ok "warn.log rows: 4 fields, command <= 80 chars" || bad "warn.log row shape"
grep -q "$tmp/work" "$log" && ok "warn.log records cwd" || bad "warn.log cwd"
# no seat/model exemption: a seat env changes nothing
rc=0; jq -cn --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}' | env HOME="$tmp" WM_SEAT=aide MCPHOST_STAMP_GATE_SELFTEST=1 MCPHOST_STAMP_GATE_NOW="$late" bash "$hook" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "no-seat-exemption (WM_SEAT=aide still blocked)" || bad "no-seat-exemption (rc=$rc)"

# --- registration ----------------------------------------------------------------------------------------------
S="$here/.claude/settings.json"
[ -x "$hook" ] && ok "hook executable" || bad "hook not executable"
jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command | contains("mcphost-stamp-gate.sh"))] | length == 1' "$S" >/dev/null \
  && ok "registered once under PreToolUse Bash" || bad "settings registration"
# fail-open guard: the entry is the same `[ -x ... ] && exec ...; exit 0` idiom as cargo-slot-gate, so a not-yet-linked hook is a no-op
jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command | contains("mcphost-stamp-gate.sh")) | .command] | .[0] | startswith("sh -c '"'"'[ -x \"$HOME/.claude/hooks/mcphost-stamp-gate.sh\" ] && exec ") and endswith("; exit 0'"'"'")' "$S" >/dev/null \
  && ok "registration is fail-open when the hook file is not linked" || bad "registration lacks the [ -x ] guard"
guard=$(jq -r '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command | contains("mcphost-stamp-gate.sh")) | .command] | .[0]' "$S")
ghome=$(mktemp -d "$tmp/ghome.XXXX"); rc=0; printf '%s' "$(jq -cn --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}')" | env HOME="$ghome" sh -c "$guard" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "missing hook file: guard exits 0" || bad "missing hook file: guard rc=$rc"

# --- part A: premise-sandbox.sh ----------------------------------------------------------------------------------
sb="$here/.local/bin/premise-sandbox.sh"
mkdir -p "$tmp/bin" "$tmp/cfg/premise-check"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [[ "$*" == *'"name":"signup"'* ]]; then echo '{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"handoff_token":"HT"}}}'
elif [[ "$*" == *'"name":"host.redeem"'* ]]; then echo '{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"tenant_key":"NEWKEY"}}}'
else echo '{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"ok":true}}}'; fi
STUB
chmod +x "$tmp/bin/curl"
printf 'OLDKEY' > "$tmp/cfg/premise-check/tenant.key"
sbrun() { env PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/stub.log" PREMISE_SANDBOX_DIR="$tmp/wd" PREMISE_SANDBOX_KEY="$tmp/cfg/premise-check/tenant.key" bash "$sb" "$@"; }
mkdir -p "$tmp/wd"
out=$(sbrun new "My Label/X" 2>&1); 
[ -e "$tmp/cfg/premise-check/stamped-v1" ] && ok "sandbox: marker created" || bad "sandbox: marker missing"
[ "$(cat "$tmp/cfg/premise-check/tenant.key.pre-stamp-20261023" 2>/dev/null)" = OLDKEY ] && ok "sandbox: old key moved aside" || bad "sandbox: old key not moved aside"
grep -q 'OLDKEY' <<<"$out" && bad "sandbox: printed the old key" || ok "sandbox: old key not printed"
grep -c 'signup' "$tmp/stub.log" | grep -qx 1 && ok "sandbox: signed up again after migration" || bad "sandbox: no re-signup"
grep -q 'x-mcphost-synthetic: harness:premise-my-label-x' "$tmp/stub.log" && ok "sandbox: signup carries sanitized x-mcphost-synthetic" || { bad "sandbox: header missing/unsanitized"; cat "$tmp/stub.log"; }
hv=$(grep -o 'x-mcphost-synthetic: [^ ]*' "$tmp/stub.log" | head -1 | sed 's/.*: //')
[[ "$hv" =~ ^[a-z0-9][a-z0-9:_-]{0,63}$ ]] && ok "sandbox: header value matches the hub regex ($hv)" || bad "sandbox: header value invalid ($hv)"
[ "$(cat "$tmp/cfg/premise-check/tenant.key")" = NEWKEY ] && ok "sandbox: new key cached" || bad "sandbox: new key not cached"
: > "$tmp/stub.log"; sbrun new again >/dev/null 2>&1
grep -q 'signup' "$tmp/stub.log" && bad "sandbox: re-signed up although a key is cached and marker set" || ok "sandbox: second run reuses the cached tenant (no signup)"
[ "$(cat "$tmp/cfg/premise-check/tenant.key.pre-stamp-20261023")" = OLDKEY ] && ok "sandbox: aside copy untouched by 2nd run" || bad "sandbox: aside copy clobbered"
exit $fail
