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
run block-www-host          2 "BLOCKED" "$late" "curl -s --json '{}' https://www.mcphost.dev/mcp"

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
run log-redaction 0 "WARN" "$early" "curl -s -X POST https://mcphost.dev/mcp -H 'X-Token: Bearer $secret' -d x # $secret"
[ -s "$log" ] && ok "warn.log written" || bad "warn.log missing"
grep -q "$secret" "$log" && bad "warn.log leaks a key-shaped token" || ok "warn.log redacts key-shaped tokens"
awk -F'\t' 'NF!=4 || length($4)>80 {bad=1} END{exit bad}' "$log" && ok "warn.log rows: 4 fields, command <= 80 chars" || bad "warn.log row shape"
grep -q "$tmp/work" "$log" && ok "warn.log records cwd" || bad "warn.log cwd"
# no seat/model exemption: a seat env changes nothing
rc=0; jq -cn --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}' | env HOME="$tmp" WM_SEAT=aide MCPHOST_STAMP_GATE_SELFTEST=1 MCPHOST_STAMP_GATE_NOW="$late" bash "$hook" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "no-seat-exemption (WM_SEAT=aide still blocked)" || bad "no-seat-exemption (rc=$rc)"

# --- registration ----------------------------------------------------------------------------------------------
S="$here/.claude/settings.json"
[ -x "$hook" ] && ok "hook executable" || bad "hook not executable"
jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command=="/home/jsy/.claude/hooks/mcphost-stamp-gate.sh")] | length == 1' "$S" >/dev/null \
  && ok "registered once under PreToolUse Bash" || bad "settings registration"

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
