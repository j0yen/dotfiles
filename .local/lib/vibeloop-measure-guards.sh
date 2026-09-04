#!/usr/bin/env bash
# vibeloop-measure-guards.sh — PRD-mcphost-measure-guards: the two guards
# vibeloop-measure.sh adds to the deploy->measure job (tenant cleanup, proxy
# gate). Split into a function-only, side-effect-free-at-source-time file so
# tests/vibeloop-measure-guards.test.sh can `source` it directly and exercise
# the decision logic (proxy_parse, proxy_should_skip, count_deleted,
# cleanup_field_from_counts) against fixture JSON without pulling in the
# rest of vibeloop-measure.sh's live systemctl/curl/git top-level checks.
#
# Callers (vibeloop-measure.sh) must define, before sourcing this file: ts(),
# log(), bus(), sum_session_cost(), ledger_cost() (all already in
# vibeloop-measure.sh), and the globals SYN, URL, LOG, ADMIN_KEY_FILE.
set -uo pipefail

# -- pure decision logic (fixture-testable, no network/filesystem I/O) ------

# Requirement 3: parse a `--tier proxy` measure.json's `bootstrap_by_segment`
# map into "k n" (segments that bootstrapped, total segments). A missing or
# unreadable file reads as "0 0" (an aborted proxy run bootstraps nothing).
proxy_parse() { # $1=path to measure.json -> "k n"
  python3 - "$1" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print("0 0")
    raise SystemExit
seg=d.get("bootstrap_by_segment") or {}
n=len(seg)
k=sum(1 for v in seg.values() if v.get("bootstrap_ok"))
print(f"{k} {n}")
PY
}

# Requirement 3: the skip rule — zero segments bootstrapped means the truth
# tier does not start this run. Exit status only (no output), so callers
# write: `if proxy_should_skip "$k"; then ... fi`.
proxy_should_skip() { # $1=k (bootstrapped count)
  [ "${1:-0}" -eq 0 ]
}

# Requirement 1: count how many tenants a `admin.tenant_delete_by_prefix
# dry_run=false` call actually removed, from its JSON result's `deleted`
# array. Malformed/empty input counts as 0 rather than erroring — a cleanup
# call whose response we can't parse should still be treated as "removed
# nothing known", not crash the run.
count_deleted() { # $1=JSON response body -> integer
  python3 -c '
import json,sys
try:
    d=json.loads(sys.argv[1])
    print(len(d.get("deleted") or []))
except Exception:
    print(0)
' "$1"
}

# Requirement 1: the ledger field cleanup accounting boils down to once the
# admin calls are done and /healthz has been re-read.
cleanup_field_from_counts() { # $1=removed $2=tenants_after -> "cleanup=<n> tenants_after=<m>"
  echo "cleanup=$1 tenants_after=${2:-unknown}"
}

# -- I/O helpers (network/process; not fixture-tested, kept thin) -----------

# /healthz's tenants_total, unauthenticated. Empty string on any failure.
healthz_tenants_total() {
  curl -s --max-time 10 "${URL%/mcp}/healthz" 2>/dev/null | python3 -c '
import json,sys
try:
    print(json.load(sys.stdin).get("tenants_total",""))
except Exception:
    print("")
' 2>/dev/null
}

# Calls an admin.* tool over the real streamable-HTTP MCP path with the
# admin key as a Bearer header — the same transport + `mcp` client library
# the harness probe already shells into synthorg's venv for (Technical
# considerations). Prints the tool's JSON result on stdout; any transport
# error, MCP tool error, or missing/empty admin key returns nonzero with
# nothing useful on stdout. Callers must check the exit code.
mcp_admin_call() { # $1=tool name  $2=JSON args object
  local tool="$1" args="$2" key
  key=$(tr -d '[:space:]' < "$ADMIN_KEY_FILE" 2>/dev/null)
  [ -n "$key" ] || return 1
  ( cd "$SYN" && timeout 30 uv run python3 - "$URL" "$key" "$tool" "$args" <<'PY'
import asyncio, json, sys
import httpx2
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

async def main() -> int:
    url, key, tool, args_json = sys.argv[1:5]
    args = json.loads(args_json)
    try:
        async with httpx2.AsyncClient(headers={"Authorization": f"Bearer {key}"}, timeout=20.0) as http_client:
            async with streamable_http_client(url, http_client=http_client) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    result = await session.call_tool(tool, args)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    text = "".join(getattr(c, "text", "") for c in result.content)
    if result.is_error:
        print(json.dumps({"error": text or "tool call failed"}), file=sys.stderr)
        return 1
    print(text)
    return 0

sys.exit(asyncio.run(main()))
PY
  )
}

# Requirement 1/2/7: after the truth or proxy tier finishes, delete every
# `panel_`/`probe-` tenant this box's harness could have created and record
# what happened. Never fails the run — a cleanup failure is logged/published
# and the ledger just says `cleanup=failed` (AC2).
cleanup_tenants() { # -> prints "cleanup=<n|failed|kept>[ tenants_after=<n>]"
  if [ "${VIBELOOP_KEEP_TENANTS:-0}" = "1" ]; then
    log "VIBELOOP_KEEP_TENANTS=1 — tenant cleanup SKIPPED; tenants left on the hub for inspection"
    echo "cleanup=kept"
    return 0
  fi
  local before after removed=0 p resp n ok=1
  before=$(healthz_tenants_total)
  for p in panel_ probe-; do
    resp=$(mcp_admin_call admin.tenant_delete_by_prefix "{\"prefix\":\"$p\",\"dry_run\":false}") || { ok=0; break; }
    n=$(count_deleted "$resp")
    removed=$((removed + n))
  done
  if [ "$ok" -ne 1 ]; then
    log "cleanup: admin.tenant_delete_by_prefix failed (missing/invalid admin key at $ADMIN_KEY_FILE, or the call errored — hub before=$before)"
    bus "{\"event\":\"cleanup-failed\",\"ts\":\"$(ts)\"}"
    echo "cleanup=failed"
    return 0
  fi
  after=$(healthz_tenants_total)
  cleanup_field_from_counts "$removed" "$after"
}

# Requirement 3/4: run `synthorg consume --tier proxy` against the deployed
# endpoint immediately after a successful redeploy, before the harness probe
# or any truth-tier session. On zero bootstraps, writes the terminal ledger
# line itself (cleanup included), publishes `proxy-failed`, and returns 1 so
# the caller skips straight to `exit 0` without starting the truth tier. On
# at least one bootstrap, sets global PROXY_FIELD (" proxy=<k>/<n>") for the
# caller to carry onto the truth-tier run's own ledger line (AC5) and
# returns 0 to continue.
run_proxy_gate() { # $1=version  $2=endpoint url  $3=out-dir
  local ver="$1" url="$2" out="$3" k n ns
  mkdir -p "$out"
  # synthorg derives its run_id from the brief's filename alone (`<slug>-consume`),
  # the same "$SYN/runs/mcp-host-project-consume" cache dir the harness probe and
  # the truth tier below also use regardless of --tier — clear it first so a proxy
  # run never inherits stale session state from whatever ran here before it.
  rm -rf "$SYN/runs/mcp-host-project-consume"
  log "proxy gate: running synthorg consume --tier proxy for $ver"
  ( cd "$SYN" && SYNTHORG_LLM_MODE=record SYNTHORG_LLM_BACKEND=cli \
      ANTHROPIC_MODEL="${SYNTHORG_MODEL_SMALL:-claude-haiku-4-5}" \
      timeout 400 uv run synthorg consume "$BRIEF" --endpoint "$url" --out "$out" \
        --seed "$SYNTHORG_SEED" --composition "$COMPOSITION" --tier proxy \
  ) >> "$LOG" 2>&1
  if [ -f "$out/measure.json" ]; then
    read -r k n <<< "$(proxy_parse "$out/measure.json")"
  else
    k=0; n=0
  fi
  ns=0; [ -f "$out/ledger.jsonl" ] && ns=$(wc -l < "$out/ledger.jsonl" 2>/dev/null || echo 0)
  read -r px_usd px_known <<< "$(sum_session_cost "$out/ledger.jsonl")"
  ledger_cost proxy "$px_usd" "$ver" "$px_known"
  if proxy_should_skip "$k"; then
    log "proxy gate FAIL 0/$n bootstrapped for $ver — skipping the truth tier"
    local cleanup_field; cleanup_field=$(cleanup_tenants)
    echo "$(ts) version=$ver proxy=$k/$n truth=skipped sessions_spent=$ns $cleanup_field" >> "$MLEDGER"
    git -C "$PRD_DIR" add "$out" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" commit -q -m "measure: proxy gate failed on $ver ($k/$n)" -- "$out" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" push -q 2>/dev/null
    bus "{\"event\":\"proxy-failed\",\"version\":\"$ver\",\"proxy\":\"$k/$n\",\"ts\":\"$(ts)\"}"
    return 1
  fi
  log "proxy gate ok: $k/$n bootstrapped for $ver — continuing to the harness probe/truth tier"
  PROXY_FIELD=" proxy=$k/$n"
  return 0
}
