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

# land_evidence is normally defined by vibeloop-measure.sh before this file is
# sourced (line ~30, well before the source at line ~149) — but
# tests/vibeloop-measure-guards.test.sh sources this file standalone, so
# define it here too, guarded, rather than assume source order.
if ! declare -F land_evidence >/dev/null; then
  land_evidence() { # $1 = work dir, $2 = final dir inside $PRD_DIR
    mkdir -p "$(dirname "$2")"; rm -rf "$2"; mv "$1" "$2"; }
fi

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

# -- PRD-vibeloop-measure-deploy-last-pass: target-selection decision logic -
# (test_prefix: lastpass) -- deploy the newest GATED commit, not HEAD, and
# never treat a red HEAD as a failed redeploy.

# Requirement 1: parse `mcphost-deploy doctor`'s rendered first line
# ("main=<sha> last_pass=<sha|none> deployed=<sha|none> drift=<n|unknown>")
# into "main last_pass deployed drift". Reads stdin so callers never have to
# fight bash quoting on a multi-line value (doctor's second line is an
# optional "warn: ..." the caller doesn't need here). Any field doctor didn't
# print at all reads back as an empty string, same as an absent key anywhere
# else in this file.
doctor_parse() { # stdin=doctor's rendered text -> "main last_pass deployed drift"
  python3 -c '
import sys
line = sys.stdin.readline()
fields = {}
for kv in line.split():
    if "=" in kv:
        k, v = kv.split("=", 1)
        fields[k] = v
print(fields.get("main", ""), fields.get("last_pass", ""), fields.get("deployed", ""), fields.get("drift", ""))
'
}

# Requirement 1/2: the target-selection decision itself. "none" (doctor's
# literal token for "nothing resolvable") and an empty string both count as
# "no last_pass to deploy" -- never treated as something to build and ship.
# Prints "redeploy <sha>" when last_pass is known and ahead of deployed,
# "measure" otherwise (last_pass == deployed, or last_pass unknown).
lastpass_target() { # $1=last_pass $2=deployed -> "redeploy <sha>" | "measure"
  local lp="${1:-}" dep="${2:-}"
  if [ -n "$lp" ] && [ "$lp" != "none" ] && [ "$lp" != "$dep" ]; then
    echo "redeploy $lp"
  else
    echo "measure"
  fi
}

# Requirement 3: normalize doctor's `drift` field for a ledger line -- an
# empty or "unknown" reading (doctor couldn't resolve one side) prints
# literally as "deploy_drift=unknown" rather than a blank field a ledger-line
# parser would choke on (same convention as cleanup_field_from_counts above).
deploy_drift_field() { # $1=drift value from doctor -> "deploy_drift=<n|unknown>"
  case "${1:-}" in
    ''|unknown) echo "deploy_drift=unknown" ;;
    *) echo "deploy_drift=$1" ;;
  esac
}

# Requirement 3: "a drift above 0 for more than two cycles raises a digest
# warning" -- true when the most recent 3+ cycles (oldest first, as recorded
# in the measure ledger) are ALL present, numeric, and > 0. Fewer than 3
# recorded cycles, or any "unknown"/unparseable reading among the last 3,
# never warns -- not enough clean history to call it sustained drift rather
# than a transient doctor hiccup.
drift_sustained() { # $@=drift values, oldest first -> exit 0 if sustained
  local n=$# vals i
  [ "$n" -ge 3 ] || return 1
  vals=("$@")
  for ((i = n - 3; i < n; i++)); do
    case "${vals[$i]}" in
      ''|unknown) return 1 ;;
      *[!0-9]*) return 1 ;;
      0) return 1 ;;
      *) : ;;
    esac
  done
  return 0
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
run_proxy_gate() { # $1=version  $2=endpoint url  $3=out-dir (final path inside $PRD_DIR)
  local ver="$1" url="$2" out="$3" work k n ns
  # $out is the final, git-tracked destination — do the actual (minutes-long)
  # write under $WORK_EVD instead, and land_evidence it into $out only once
  # everything is finished and about to be committed (see vibeloop-measure.sh
  # for why: the PRD checkout is rebased/reset/autostashed concurrently).
  work="$WORK_EVD/proxy/$(basename "$out")"
  mkdir -p "$work"
  # synthorg derives its run_id from the brief's filename alone (`<slug>-consume`),
  # the same "$SYN/runs/mcp-host-project-consume" cache dir the harness probe and
  # the truth tier below also use regardless of --tier — clear it first so a proxy
  # run never inherits stale session state from whatever ran here before it.
  rm -rf "$SYN/runs/mcp-host-project-consume"
  log "proxy gate: running synthorg consume --tier proxy for $ver"
  ( cd "$SYN" && SYNTHORG_LLM_MODE=record SYNTHORG_LLM_BACKEND=cli \
      ANTHROPIC_MODEL="${SYNTHORG_MODEL_SMALL:-claude-haiku-4-5}" \
      timeout 400 uv run synthorg consume "$BRIEF" --endpoint "$url" --out "$work" \
        --seed "$SYNTHORG_SEED" --composition "$COMPOSITION" --tier proxy \
  ) >> "$LOG" 2>&1
  if [ -f "$work/measure.json" ]; then
    read -r k n <<< "$(proxy_parse "$work/measure.json")"
  else
    k=0; n=0
  fi
  ns=0; [ -f "$work/ledger.jsonl" ] && ns=$(wc -l < "$work/ledger.jsonl" 2>/dev/null || echo 0)
  read -r px_usd px_known <<< "$(sum_session_cost "$work/ledger.jsonl")"
  ledger_cost proxy "$px_usd" "$ver" "$px_known"
  if proxy_should_skip "$k"; then
    log "proxy gate FAIL 0/$n bootstrapped for $ver — skipping the truth tier"
    local cleanup_field; cleanup_field=$(cleanup_tenants)
    echo "$(ts) version=$ver proxy=$k/$n truth=skipped ${DRIFT_FIELD:-deploy_drift=unknown} sessions_spent=$ns $cleanup_field" >> "$MLEDGER"
    land_evidence "$work" "$out"
    git -C "$PRD_DIR" add "$out" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" commit -q -m "measure: proxy gate failed on $ver ($k/$n)" -- "$out" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" push -q 2>/dev/null
    bus "{\"event\":\"proxy-failed\",\"version\":\"$ver\",\"proxy\":\"$k/$n\",\"ts\":\"$(ts)\"}"
    return 1
  fi
  log "proxy gate ok: $k/$n bootstrapped for $ver — continuing to the harness probe/truth tier"
  # $out is landed here too: the caller never lands proxy dirs itself, and
  # every later commit that names $PROXY_EVD (harness-probe-fail, and the
  # script's final catch-all) must find this run already sitting inside it.
  land_evidence "$work" "$out"
  PROXY_FIELD=" proxy=$k/$n"
  return 0
}
