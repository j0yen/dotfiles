#!/usr/bin/env bash
# premise-sandbox: the ONLY write path a premise verifier may use. One throwaway tenant on
# prod per check, key kept in a 0600 file the verifier never reads, offboarded at the end.
#   premise-sandbox.sh new <label>          -> signs up (handoff) + redeems; prints tenant name only
#   premise-sandbox.sh call <tool> [json]   -> tools/call with tenant_key injected; prints redacted result
#   premise-sandbox.sh cleanup              -> removes tools named premise_* ; keeps the ONE persistent tenant (default end step)
#   premise-sandbox.sh offboard             -> retires the persistent tenant (host.self.offboard); only by hand
# Env: PREMISE_SANDBOX_DIR (key file dir, default $PWD), MCPHOST_URL (default https://mcphost.dev)
# Synthetic stamp: every request carries `x-mcphost-synthetic: harness:premise-<label>` (label sanitized to the hub's
# ^[a-z0-9][a-z0-9:_-]{0,63}$) so the hub marks the tenant synthetic at creation (signup, explicit or implicit).
set -euo pipefail
URL="${MCPHOST_URL:-https://mcphost.dev}/mcp"
DIR="${PREMISE_SANDBOX_DIR:-$PWD}"
PERSIST="${PREMISE_SANDBOX_KEY:-$HOME/.config/premise-check/tenant.key}"   # ONE long-lived sandbox tenant (signup is 5/IP/h on prod)
KEYF="$DIR/.tenant_key"
STAMPED="$(dirname "$PERSIST")/stamped-v1"   # one-time migration marker (see `new`)
synth_label() { # <label> -> x-mcphost-synthetic value: harness:premise-<label>, lowercased, [^a-z0-9:_-] -> '-', <= 64 chars
  local l; l="$(printf 'harness:premise-%s' "${1:-premise}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9:_\n-' '-' | tr -d '\n')"
  printf '%s' "${l:0:64}"
}
SYNTH="$(synth_label premise)"
ALLOW='^(signup|host\.redeem|host\.whoami|host\.quickstart|host\.help\.search|host\.tool[._](publish|call|test|list|remove|run|logs|spec_shared|share|unshare)|host\.tool_(publish|call|test|share)|host\.state[._](get|set|list)|host\.msg\.(send|reply|wait|inbox|thread)|host\.task\.(post|claim|complete|get|dead_letters)|host\.docs\.(put|get|list)|host\.(export|import)|host\.self\.offboard|host\.self_offboard|host\.key\.rotate|host\.key_rotate)$'

rpc() { # tool json-args  -> the JSON-RPC response object (plain JSON or the id:1 frame of an SSE body)
  local tool="$1" args="$2" body
  body="$(curl -s --max-time 30 -X POST "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "x-mcphost-synthetic: $SYNTH" \
    -d "$(jq -cn --arg t "$tool" --argjson a "$args" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$t,arguments:$a}}')")"
  case "$body" in
    data:*|event:*) printf '%s\n' "$body" | sed -n 's/^data: //p' | jq -c 'select(.id==1)' | head -1 ;;
    *) printf '%s' "$body" ;;
  esac
}
payload() { # raw body -> the tool's own result object (structuredContent, else parsed text, else error)
  jq -c 'if .error then {error:.error} elif .result.structuredContent then .result.structuredContent elif (.result.content[0].text|type)=="string" then (.result.content[0].text | try fromjson catch {text:.}) else .result end'
}
redact() { jq -c 'walk(if type=="object" then with_entries(if (.key|test("key|token|secret|authorization";"i")) and (.value|type)=="string" then .value="<redacted>" else . end) else . end)'; }

case "${1:-}" in
  new)
    label="${2:-premise}"; SYNTH="$(synth_label "$label")"
    # one-time migration: a tenant cached before the stamp existed is unstamped -> set its key aside (never printed) and
    # sign up again with the header; the old tenant is labeled by a separate backfill
    if [ ! -e "$STAMPED" ]; then
      umask 077; mkdir -p "$(dirname "$PERSIST")"
      [ ! -e "$PERSIST" ] || mv -n "$PERSIST" "$PERSIST.pre-stamp-20261023"
      : > "$STAMPED"
    fi
    if [ -r "$PERSIST" ]; then umask 077; cp "$PERSIST" "$KEYF"; k="$(cat "$KEYF")"
      rpc host.whoami "$(jq -cn --arg k "$k" '{tenant_key:$k}')" | payload | redact; exit 0; fi
    r="$(rpc signup "$(jq -cn --arg n "premise-$label-$(date -u +%H%M%S)" '{name:$n,handoff:true}')" | payload)"
    if jq -e '.error.data.code=="rate_limited" or (.error.message|tostring|test("rate"))' <<<"$r" >/dev/null 2>&1; then
      # carbon is not a fleet IP: sign up from orch (fleet-exempt) and bring the handoff token home over ssh
      r="$(ssh orch "curl -s --max-time 30 -X POST '$URL' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H 'x-mcphost-synthetic: $SYNTH' -d '$(jq -cn --arg n "premise-$label-$(date -u +%H%M%S)" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"signup",arguments:{name:$n,handoff:true}}}')'" | sed -n 's/^data: //p;/^{/p' | jq -c 'select(.id==1)' | head -1 | payload)"
    fi
    tok="$(jq -r '.handoff_token // empty' <<<"$r")"
    if [ -z "$tok" ]; then echo "sandbox: signup gave no handoff_token: $(redact <<<"$r")" >&2; exit 3; fi
    k="$(rpc host.redeem "$(jq -cn --arg t "$tok" '{handoff_token:$t}')" | payload | jq -r '.tenant_key // .key // empty')"
    [ -n "$k" ] || { echo "sandbox: redeem gave no key" >&2; exit 3; }
    umask 077; mkdir -p "$(dirname "$PERSIST")"; printf '%s' "$k" > "$PERSIST"; cp "$PERSIST" "$KEYF"
    rpc host.whoami "$(jq -cn --arg k "$k" '{tenant_key:$k}')" | payload | redact
    ;;
  call)
    tool="${2:?tool}"; args="${3:-{\}}"; [[ "$tool" =~ $ALLOW ]] || { echo "sandbox: tool not allowed: $tool" >&2; exit 4; }
    [ -r "$KEYF" ] || { echo "sandbox: no tenant (run: premise-sandbox.sh new <label>)" >&2; exit 2; }
    k="$(cat "$KEYF")"
    r="$(rpc "$tool" "$(jq -c --arg k "$k" '. + {tenant_key:$k}' <<<"$args")" | payload)"
    if [[ "$tool" =~ ^host\.key[._]rotate$ ]]; then nk="$(jq -r '.tenant_key // .key // .new_key // empty' <<<"$r")"; [ -n "$nk" ] && { umask 077; printf '%s' "$nk" > "$KEYF"; printf '%s' "$nk" > "$PERSIST"; }; fi
    redact <<<"$r"
    ;;
  cleanup)
    # end of a check: remove tools this check published (names starting premise_), keep the tenant
    [ -r "$KEYF" ] || { echo "sandbox: nothing to clean"; exit 0; }
    k="$(cat "$KEYF")"
    for t in $(rpc host.tool.list "$(jq -cn --arg k "$k" '{tenant_key:$k}')" | payload | jq -r '.. | objects | select(has("name")) | .name' 2>/dev/null | grep -E '^premise_' | sort -u); do
      rpc host.tool.remove "$(jq -cn --arg k "$k" --arg n "$t" '{tenant_key:$k,name:$n}')" >/dev/null 2>&1 && echo "sandbox: removed tool $t"; done
    rm -f "$KEYF"; echo "sandbox: cleaned"
    ;;
  offboard)
    [ -r "$KEYF" ] || { echo "sandbox: nothing to offboard"; exit 0; }
    k="$(cat "$KEYF")"
    rpc host.self.offboard "$(jq -cn --arg k "$k" '{tenant_key:$k}')" | payload | redact || true
    rm -f "$KEYF" "$PERSIST"; echo "sandbox: offboarded (persistent sandbox tenant retired)"
    ;;
  *) sed -n '2,7p' "$0" >&2; exit 64 ;;
esac
