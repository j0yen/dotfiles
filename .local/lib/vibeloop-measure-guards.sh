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
#
# PRD-mcphost-seed-noise-floor adds `run_noise_floor_sweep` (called at the
# bottom of this file) for the same reason, needing the globals PRD_DIR,
# MLEDGER, WORK_EVD, PROXY_EVD, BRIEF, COMPOSITION, NOISE_FLOOR,
# MAX_MEASURES_PER_DAY, runs24, SYNTHORG_MODEL_SMALL/NOISE_FLOOR_SEED_2/3
# (all already defined in vibeloop-measure.sh by the time it's called) —
# its pure helpers (noise_floor_seeds, noise_floor_budget_ok,
# noise_floor_compute, noise_floor_spread_field, noise_floor_ledger_line)
# need none of that and are exercised directly by
# tests/noisefloor_ac*.test.sh.
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

# -- PRD-vibeloop-measure-self-authorized-redeploy: the measure step's own
# authorization for `redeploy --migrate-incompatible` -- (test_prefix:
# selfauth) range construction, migrate-flag decision, outcome classification
# from the tool's own exit code + printed journal line, and the rolled-back
# "don't retry the same range" state. All pure/fixture-testable; the actual
# `uv run mcphost-deploy redeploy` shell-out itself stays in
# vibeloop-measure.sh, same split as lastpass_target/doctor_parse above.

# Requirement 1/2: MCPHOST_DEPLOY_AUTHORIZE's exact range string -- always
# <currently-deployed>..<last_pass>, built from the same doctor/healthz read
# used to pick the target (the caller never passes a cached value in).
deploy_authorize_range() { # $1=deployed(from) $2=last_pass(to) -> "<from>..<to>"
  echo "${1:-unknown}..${2:-unknown}"
}

# Requirement 5: MEASURE_UNATTENDED_DEPLOY=off is the one operator killswitch
# for the migrate flags/env var; any other value (including unset) leaves
# self-authorization on.
unattended_deploy_enabled() { # $MEASURE_UNATTENDED_DEPLOY -> exit 0 if enabled
  [ "${MEASURE_UNATTENDED_DEPLOY:-on}" != "off" ]
}

# Requirement 1/5: the two migrate flags, one per line so a caller can splice
# them into an argv array with a `while read` loop; no output at all when
# unattended deploy is disabled (the caller then sends the plain
# `--skip-if-ungated` call requirement 5 describes).
redeploy_migrate_flags() { # $1="1" when unattended_deploy_enabled held, else "0"
  [ "${1:-0}" = "1" ] && printf '%s\n' --migrate-incompatible --authorized-by vibeloop-measure
  return 0
}

# Requirement 4: classify a redeploy call's own exit code + printed
# stdout+stderr into one of deployed|rolled-back|refused, plus the cause
# token off the tool's own `redeploy  <verb>  (cause=<x> ...)` journal line
# (the newest one printed, tail -1) -- "none" when the call printed no cause
# at all (rc=0, a clean deploy with nothing gated in the way).
classify_deploy_outcome() { # $1=rc $2=output text -> "<outcome> <cause>"
  local rc="$1" out="$2" cause
  cause=$(printf '%s' "$out" | grep -oE 'cause=[^[:space:])]+' | tail -1 | cut -d= -f2)
  if [ "$rc" -eq 0 ]; then
    echo "deployed ${cause:-none}"
  elif printf '%s' "$out" | grep -q 'rolled-back'; then
    echo "rolled-back ${cause:-none}"
  else
    echo "refused ${cause:-none}"
  fi
}

# Requirement 8: where the "don't retry a rolled-back range until last_pass
# changes" pointer lives -- $XDG_STATE_HOME/vibeloop/ per the requirement,
# holding just the last_pass sha that was rolled back (last_pass, not the
# full range, is what "changes" means for the retry rule).
rolled_back_state_path() {
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/vibeloop/rolled-back-last-pass"
}

record_rolled_back_pending() { # $1=state path $2=last_pass sha
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

clear_rolled_back_pending() { # $1=state path
  rm -f "$1"
}

# Requirement 8/AC8: still pending exactly when the state file names THIS
# last_pass -- a changed last_pass (new green) always clears the hold, no
# separate "clear" call required for that case.
rolled_back_pending() { # $1=state path $2=current last_pass sha -> exit 0 if pending
  [ -f "$1" ] && [ "$(cat "$1" 2>/dev/null)" = "${2:-}" ]
}

# Requirement 3/AC2/AC3: the four measure.json/ledger fields plus one
# digest-legible summary token -- "<outcome> <range>", the literal phrase
# the digest line is required to contain (User story 4) -- for one run's
# deploy decision. Callers append this string onto whatever measure-ledger
# line they're already writing.
deploy_ledger_fields() { # $1=outcome $2=cause $3=range $4=deployed_sha -> key=value string
  printf 'deploy_outcome=%s deploy_cause=%s deploy_range=%s deployed_sha=%s deploy_summary="%s %s"' \
    "$1" "$2" "$3" "$4" "$1" "$3"
}

# Requirement 3: fold the four structured fields (not deploy_summary --
# that one is ledger-line-only, not part of the JSON schema) into an
# existing measure.json. Existing keys are left alone; a run whose
# measure.json doesn't exist yet is the caller's problem to create first --
# this never creates the file, only patches one that's already there.
merge_deploy_fields_json() { # $1=path $2=outcome $3=cause $4=range $5=deployed_sha
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
path, outcome, cause, rng, sha = sys.argv[1:6]
with open(path) as f:
    d = json.load(f)
d["deploy_outcome"] = outcome
d["deploy_cause"] = cause
d["deploy_range"] = rng
d["deployed_sha"] = sha
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
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

# -- PRD-mcphost-seed-noise-floor: the post-redeploy three-seed proxy-tier
# sweep (test_prefix: noisefloor) -- pure/fixture-testable pieces first,
# the impure orchestration (`run_noise_floor_sweep`, shells into `uv run
# synthorg` exactly like `run_proxy_gate` above) last. Per Requirement 1's
# "the truth tier keeps its single fixed seed" and Technical
# considerations' "this PRD adds invocations, not a new tier": the proxy
# gate `run_proxy_gate` already ran IS leg one of this sweep — this file
# never re-runs it, only adds two more legs at two more pinned seeds.

# Requirement 1: the pinned three-seed set's env contract. Seed one is
# whatever seed the gate leg (leg one) already ran at — passed in, never
# re-derived — so this function has nothing to do with SYNTHORG_SEED as a
# global; seeds two/three are NOISE_FLOOR_SEED_2/3, named constants
# (default 17/42), overridable only via env, never `date +%s` (the
# cycle-19 randomized-seed defect this whole PRD exists to bury). Prints
# "seed1 seed2 seed3".
noise_floor_seeds() { # $1=leg-one seed
  echo "${1:-0} ${NOISE_FLOOR_SEED_2:-17} ${NOISE_FLOOR_SEED_3:-42}"
}

# Requirement 3/AC2: budget honesty -- the sweep's two extra legs must
# count against the SAME daily cap `MAX_MEASURES_PER_DAY` already
# enforces (sessions, never log lines -- the cycle-19 rule). `leg_sessions`
# is leg one's own observed session count (same composition/segments, so
# the two floor legs are expected to spend about the same amount); a cap
# of 0 or less means uncapped, mirroring vibeloop-measure.sh's own
# `budget_hit` convention for `MAX_MEASURES_PER_DAY<=0`. Exit 0 means the
# remaining budget covers both extra legs.
noise_floor_budget_ok() { # $1=runs24 (sessions already spent today) $2=MAX_MEASURES_PER_DAY $3=leg_sessions (one leg's own session count)
  local runs24="${1:-0}" max="${2:-0}" leg="${3:-0}" need
  [ "$max" -le 0 ] && return 0
  need=$(( leg * 2 ))
  [ $(( runs24 + need )) -le "$max" ]
}

# Requirement 2, AC1: builds `noise-floor.json` from whichever legs
# actually produced a `measure.json` -- version, the seed set, per-segment
# and overall satisfaction/wow values per seed, and the spread (max-min +
# population stddev) per segment and overall. A segment value that isn't
# numeric (the proxy tier's tiny bootstrap panel commonly reads
# `"n/a (n=1<3)"` below `PANEL_MIN_PER_SEGMENT` -- see synthorg's
# `_segment_value`) is carried as `null`, never coerced into the spread
# math -- "absent, not zero", the same convention synthorg's own
# `measure.json` uses elsewhere. Fewer than 2 numeric values for a given
# metric makes that spread `null` (unmeasurable), not a fake 0.0. Pure
# file I/O on the paths it's given -- no network, fixture-testable.
noise_floor_compute() { # $1=version $2=out_json_path $3=failed_seeds_csv ("" if none) $4...=seed:measure_json_path pairs (succeeded legs only)
  local version="$1" outpath="$2" failed="$3"; shift 3
  python3 - "$version" "$outpath" "$failed" "$@" <<'PY'
import json, statistics, sys

version, outpath, failed_csv, *pairs = sys.argv[1:]
failed_seeds = sorted(int(s) for s in failed_csv.split(",") if s)

per_seed = {}
for pair in pairs:
    seed_s, path = pair.split(":", 1)
    try:
        per_seed[int(seed_s)] = json.load(open(path))
    except Exception:
        pass


def numeric(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def spread(values):
    nums = [v for v in values if numeric(v)]
    if len(nums) < 2:
        return {"max_min": None, "stddev": None, "n": len(nums)}
    return {"max_min": max(nums) - min(nums), "stddev": statistics.pstdev(nums), "n": len(nums)}


overall_sat, overall_wow = {}, {}
seg_sat, seg_wow = {}, {}
segments = set()
for seed, d in sorted(per_seed.items()):
    sat = d.get("satisfaction") or {}
    wow = d.get("wow_rate") or {}
    overall_sat[str(seed)] = sat.get("overall", 0.0)
    overall_wow[str(seed)] = wow.get("overall", 0.0)
    for seg, val in (sat.get("by_segment") or {}).items():
        segments.add(seg)
        seg_sat.setdefault(seg, {})[str(seed)] = val if numeric(val) else None
    for seg, val in (wow.get("by_segment") or {}).items():
        segments.add(seg)
        seg_wow.setdefault(seg, {})[str(seed)] = val if numeric(val) else None

by_segment = {}
for seg in sorted(segments):
    sat_vals = seg_sat.get(seg, {})
    wow_vals = seg_wow.get(seg, {})
    by_segment[seg] = {
        "satisfaction": sat_vals,
        "wow_rate": wow_vals,
        "spread": {
            "satisfaction": spread(list(sat_vals.values())),
            "wow_rate": spread(list(wow_vals.values())),
        },
    }

out = {
    "version": version,
    "seeds": sorted(per_seed.keys()),
    "failed_seeds": failed_seeds,
    "complete": len(failed_seeds) == 0,
    "by_segment": by_segment,
    "overall": {
        "satisfaction": overall_sat,
        "wow_rate": overall_wow,
        "spread": {
            "satisfaction": spread(list(overall_sat.values())),
            "wow_rate": spread(list(overall_wow.values())),
        },
    },
}
with open(outpath, "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
PY
}

# Requirement 2/5: the `noise-floor.json`-derived fragment of the ledger
# line -- just the overall spread, formatted `<max_min>/<stddev>` or
# `n/a` when unmeasurable (fewer than 2 numeric legs). Pure file read,
# fixture-testable with a noise-floor.json built by noise_floor_compute
# (or a hand-written one).
noise_floor_spread_field() { # $1=noise_floor_json_path
  python3 - "$1" <<'PY'
import json, sys

d = json.load(open(sys.argv[1]))
sat = d["overall"]["spread"]["satisfaction"]
wow = d["overall"]["spread"]["wow_rate"]


def fmt(s):
    mm, sd = s.get("max_min"), s.get("stddev")
    return f"{mm:.4f}/{sd:.4f}" if mm is not None else "n/a"


print(f"overall_satisfaction_spread={fmt(sat)} overall_wow_spread={fmt(wow)}")
PY
}

# Requirement 2/5, AC2/AC3/AC5: the one ledger-line body this sweep
# contributes -- version, the pinned seed set, and (mode-dependent) the
# budget-skip marker, the incomplete marker + failed seed(s), or the
# overall spread. Pure -- the caller (`run_noise_floor_sweep`) prepends
# "$(ts) " and appends the line to $MLEDGER; this function never touches
# the filesystem except to read $6 (the already-written noise-floor.json)
# on the `ok`/`incomplete` modes.
noise_floor_ledger_line() { # $1=mode(ok|incomplete|skip-budget) $2=version $3=seed1 $4=seed2 $5=seed3 $6=noise_floor_json_path (ok|incomplete only) $7=failed_seeds_csv (incomplete only)
  local mode="$1" ver="$2" s1="$3" s2="$4" s3="$5" nf="${6:-}" failed="${7:-}"
  case "$mode" in
    skip-budget)
      printf 'version=%s noise-floor="skip: budget" seeds=%s,%s,%s\n' "$ver" "$s1" "$s2" "$s3"
      ;;
    ok)
      printf 'version=%s noise-floor=ok seeds=%s,%s,%s %s file=vibeloop/noise-floor.json\n' \
        "$ver" "$s1" "$s2" "$s3" "$(noise_floor_spread_field "$nf")"
      ;;
    incomplete)
      printf 'version=%s noise-floor=incomplete failed_seeds=%s seeds=%s,%s,%s %s file=vibeloop/noise-floor.json\n' \
        "$ver" "$failed" "$s1" "$s2" "$s3" "$(noise_floor_spread_field "$nf")"
      ;;
    *)
      printf 'version=%s noise-floor=error:unknown-mode:%s seeds=%s,%s,%s\n' "$ver" "$mode" "$s1" "$s2" "$s3"
      ;;
  esac
}

# Requirement 1/2/3/4, AC1-AC5: orchestrates the two extra proxy-tier legs
# against the live endpoint and lands `noise-floor.json` + the ledger
# line. Never blocks or reddens the gate verdict (AC4): every exit path
# here is 0, and the caller in vibeloop-measure.sh does not guard this
# call with `|| exit` -- a failure here only ever shows up as
# `noise-floor: incomplete` or `skip: budget` in the ledger, never as a
# changed gate/truth-tier outcome. Deliberately NOT unit-tested directly
# -- same reason `run_proxy_gate` above isn't: it shells into `uv run
# synthorg`. The pure pieces above (noise_floor_seeds,
# noise_floor_budget_ok, noise_floor_compute, noise_floor_spread_field,
# noise_floor_ledger_line) carry the fixture tests
# (tests/noisefloor_ac*.test.sh); this function is smoke-tested by hand
# and validated operationally the same way run_proxy_gate always has
# been. Does NOT commit/push -- same convention run_proxy_gate's PASS
# path already follows: it only writes files the caller's own downstream
# commits (harness-probe-fail, final catch-all) already thread through
# vibeloop-measure.sh's $NOISE_FLOOR conditional-pathspec guard.
run_noise_floor_sweep() { # $1=version $2=endpoint url $3=leg-one measure.json path (already landed) $4=leg-one seed
  local ver="$1" url="$2" leg1_json="$3" seed1 seed2 seed3 leg1_sessions failed_seeds="" legs seed work landed leg_usd leg_known
  read -r seed1 seed2 seed3 <<< "$(noise_floor_seeds "${4:-0}")"
  if [ ! -f "$leg1_json" ]; then
    log "noise-floor: skip: no leg-one measure.json at $leg1_json -- cannot anchor the sweep"
    return 0
  fi
  leg1_sessions=$(python3 -c "import json;print(json.load(open('$leg1_json')).get('sessions',0))" 2>/dev/null)
  leg1_sessions="${leg1_sessions:-0}"
  if ! noise_floor_budget_ok "${runs24:-0}" "${MAX_MEASURES_PER_DAY:-0}" "$leg1_sessions"; then
    log "noise-floor: skip: budget (runs24=${runs24:-0} max=${MAX_MEASURES_PER_DAY:-0} leg_sessions=$leg1_sessions)"
    echo "$(ts) $(noise_floor_ledger_line skip-budget "$ver" "$seed1" "$seed2" "$seed3")" >> "$MLEDGER"
    return 0
  fi
  legs=("$seed1:$leg1_json")
  for seed in "$seed2" "$seed3"; do
    work="$WORK_EVD/noise-floor/$ver-seed$seed-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$work"
    rm -rf "$SYN/runs/mcp-host-project-consume"
    log "noise-floor: running synthorg consume --tier proxy seed=$seed for $ver"
    ( cd "$SYN" && SYNTHORG_LLM_MODE=record SYNTHORG_LLM_BACKEND=cli \
        ANTHROPIC_MODEL="${SYNTHORG_MODEL_SMALL:-claude-haiku-4-5}" \
        timeout 400 uv run synthorg consume "$BRIEF" --endpoint "$url" --out "$work" \
          --seed "$seed" --composition "$COMPOSITION" --tier proxy \
    ) >> "$LOG" 2>&1
    read -r leg_usd leg_known <<< "$(sum_session_cost "$work/ledger.jsonl")"
    ledger_cost noise-floor "$leg_usd" "$ver" "$leg_known"
    if [ -f "$work/measure.json" ]; then
      landed="$PROXY_EVD/$ver-noisefloor-seed$seed-$(date -u +%Y%m%dT%H%M%SZ)"
      land_evidence "$work" "$landed"
      legs+=("$seed:$landed/measure.json")
    else
      log "noise-floor: leg seed=$seed FAILED (no measure.json)"
      failed_seeds="${failed_seeds:+$failed_seeds,}$seed"
      rm -rf "$work"
    fi
  done
  noise_floor_compute "$ver" "$NOISE_FLOOR" "$failed_seeds" "${legs[@]}"
  if [ -n "$failed_seeds" ]; then
    log "noise-floor: incomplete -- failed seed(s) $failed_seeds"
    echo "$(ts) $(noise_floor_ledger_line incomplete "$ver" "$seed1" "$seed2" "$seed3" "$NOISE_FLOOR" "$failed_seeds")" >> "$MLEDGER"
  else
    log "noise-floor: ok -- $(noise_floor_spread_field "$NOISE_FLOOR")"
    echo "$(ts) $(noise_floor_ledger_line ok "$ver" "$seed1" "$seed2" "$seed3" "$NOISE_FLOOR")" >> "$MLEDGER"
  fi
  bus "{\"event\":\"noise-floor\",\"version\":\"$ver\",\"complete\":$([ -z "$failed_seeds" ] && echo true || echo false),\"ts\":\"$(ts)\"}"
  return 0
}
