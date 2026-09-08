#!/usr/bin/env bash
# vibeloop-measure — the mcphost-buildloop's deploy→measure step (event-driven, not clock-driven).
# Runs hourly from claude-vibeloop-measure.timer. It measures ONLY when:
#   - a newer mcphost than the one on the hub has been built (then: redeploy w/ rollback, then measure), or
#   - calibration runs remain for the deployed version (repeat runs to size the noise floor).
# Guards: skip if MEASURE-STOP present (plain STOP no longer halts measurement — req 10),
#         a cycle is running (bounded after 3 consecutive skips — req 11), the loop was
#         quota-limited in the last hour, or MAX_MEASURES_PER_DAY (3) sessions_spent already
#         ran in 24h (line count no longer counts — req 2/4). Results land in the PRDs repo:
#   evidence/mcp-host/measure/<version>-<ts>/{measure.json,ledger.jsonl}, evidence/mcp-host/measure/LATEST,
#   vibeloop/measure-ledger.md (one line per run) — dream reads LATEST; carbon reads via vibeloop-ctl measure.
#
# PRD-mcphost-measure-guards adds two more, in .local/lib/vibeloop-measure-guards.sh
# (sourced below, function-only so tests/vibeloop-measure-guards.test.sh can exercise
# the decision logic against fixture JSON with no network/systemctl calls — run it with
# `bash tests/vibeloop-measure-guards.test.sh` from the repo root):
#   - proxy gate: immediately after a successful redeploy, before the harness probe or
#     any truth-tier session, run `synthorg consume --tier proxy`; zero bootstraps writes
#     `proxy=0/<n> truth=skipped`, publishes `proxy-failed`, and skips the truth tier.
#   - cleanup: after the truth or proxy tier finishes, delete every `panel_`/`probe-`
#     tenant via `admin.tenant_delete_by_prefix` (dry_run=false) and record
#     `cleanup=<n> tenants_after=<n>` on the run's ledger line. VIBELOOP_KEEP_TENANTS=1
#     skips the delete for debugging (`cleanup=kept`).
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
PRD_DIR="${DREAM_PRD_DIR:-$HOME/Documents/PRDs}"; LOG="$HOME/brain/journal/vibeloop-measure.log"
CRATE="$HOME/wintermute/mcphost"; DEPLOY="$HOME/repos/mcphost-deploy"; SYN="$HOME/repos/synthorg"
BRIEF="$HOME/Documents/Notes/mcp-host-project.md"; URL="${MCPHOST_PUBLIC_URL:-https://mcphost.dev/mcp}"; HOST=mcphost-1
MLEDGER="$PRD_DIR/vibeloop/measure-ledger.md"; EVD="$PRD_DIR/evidence/mcp-host/measure"; CAL="$HOME/.config/vibeloop/calibration-remaining"
PROXY_EVD="$PRD_DIR/evidence/mcp-host/proxy"; ADMIN_KEY_FILE="$HOME/.config/mcphost/admin-key"
# Anonymous /healthz is `{"ok":true}` only (PRD-mcphost-healthz-minimal); the
# version is served only with the admin bearer, the same header the deploy
# prober sends (PRD-mcphost-deploy-healthz-auth). Without it every tick from
# 2026-09-06T21:50Z on read an empty version and exited as "hub unreachable".
probe_deployed_version() {
  local hdr=()
  [ -s "$ADMIN_KEY_FILE" ] && hdr=(-H "Authorization: Bearer $(cat "$ADMIN_KEY_FILE")")
  curl -s --max-time 10 "${hdr[@]}" "${URL%/mcp}/healthz" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}
BASELINE="$PRD_DIR/vibeloop/baseline.json"  # PRD-mcphost-baseline-anchor: the standing baseline pointer; written only below (baseline_set/baseline_reanchored)
[ -f "$HOME/.config/vibeloop/limits" ] && . "$HOME/.config/vibeloop/limits"
MAX_MEASURES_PER_DAY="${MAX_MEASURES_PER_DAY:-3}"
VIBELOOP_KEEP_TENANTS="${VIBELOOP_KEEP_TENANTS:-0}"  # P1 req 7: debug switch, keeps a run's tenants on the hub
# PRD-mcphost-baseline-anchor: set by a future candidate-run trigger — no invocation path in
# this script sets it yet (every run today is a "plain" comparable run against the deployed
# head), but the staleness refusal and the baseline-write guard below both key off it so that
# whichever PRD wires an actual candidate build/measure path in gets the policy for free.
VIBELOOP_CANDIDATE="${VIBELOOP_CANDIDATE:-0}"
PROXY_FIELD=""  # set by run_proxy_gate on a proxy pass; carried onto the truth-tier ledger line (AC5)
CL="$PRD_DIR/vibeloop/cost-ledger.jsonl"
cost_sum() { # $1=window_secs
  python3 - "$CL" "$1" <<'PY'
import json,sys,time,calendar
path,win=sys.argv[1],float(sys.argv[2]); now=time.time(); total=0.0
try:
    for line in open(path):
        line=line.strip()
        if not line: continue
        try: r=json.loads(line)
        except Exception: continue
        try: t=calendar.timegm(time.strptime(r.get("ts",""),"%Y-%m-%dT%H:%M:%SZ"))
        except Exception: continue
        if now - t <= win: total += float(r.get("usd") or 0)
except FileNotFoundError:
    pass
print(f"{total:.4f}")
PY
}
ledger_cost() { # $1=kind $2=usd $3=ref $4=cost_known(true/false)
  python3 - "$CL" "$1" "$2" "$3" "$4" <<'PY'
import json,sys,datetime
path,kind,usd,ref,known=sys.argv[1:6]
row={"ts":datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),"kind":kind,"usd":round(float(usd),6),"ref":ref,"cost_known":known=="true"}
with open(path,"a") as f: f.write(json.dumps(row)+"\n")
PY
}
sum_session_cost() { # $1=ledger.jsonl path -> "usd known(true/false)"
  python3 - "$1" <<'PY'
import json,sys
path=sys.argv[1]; total=0.0; known=True; n=0
try:
    for line in open(path):
        line=line.strip()
        if not line: continue
        try: r=json.loads(line)
        except Exception: continue
        n+=1
        c=r.get("cost_usd")
        if c is None: known=False
        else: total+=float(c)
except FileNotFoundError:
    known=False
print(f"{total:.6f} {'true' if (known and n>0) else 'false'}")
PY
}
budget_hit() { # $1=sum $2=max $3=frac -> 1/0
  awk -v s="$1" -v m="$2" -v f="$3" 'BEGIN{print (m>0 && s>=f*m)?1:0}'
}
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) $*" >> "$LOG"; }
bus() { command -v nats >/dev/null 2>&1 && timeout 5 nats --server "${NATS_URL:-nats://127.0.0.1:4222}" pub wm.vibeloop.measure "$1" >/dev/null 2>&1; return 0; }
# PRD-mcphost-baseline-anchor: standing-baseline helpers. `baseline_version`
# reads the field vibeloop-ctl and the staleness guard both need; the other
# two read/write the whole 7-field pointer file.
baseline_version() { [ -f "$BASELINE" ] && python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('version',''))" "$BASELINE" 2>/dev/null; }
baseline_run_dir() { [ -f "$BASELINE" ] && python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('run_dir',''))" "$BASELINE" 2>/dev/null; }
# Eligibility per the Baseline policy / AC5: pinned seed, pinned composition,
# strict (unfiltered) segments, truth tier — a measure.json missing any of
# these predates comparability (wall-clock seed, no composition fingerprint)
# and must never be selectable as a baseline. Prints "eligible <seed>
# <corpus_fp> <composition_fp> <sessions>" or "ineligible".
measure_comparability() { # $1=measure.json path
  python3 - "$1" <<'PY'
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("ineligible"); sys.exit()
tier = d.get("tier", "truth")
seed = d.get("seed")
corpus_fp = (d.get("corpus") or {}).get("fingerprint")
comp_fp = (d.get("composition") or {}).get("fingerprint")
segfilt = d.get("segments_filter")
sessions = d.get("sessions")
if tier != "truth" or seed is None or not corpus_fp or not comp_fp or segfilt is not None:
    print("ineligible")
else:
    print(f"eligible {seed} {corpus_fp} {comp_fp} {sessions}")
PY
}
# Requirement 1: write the 7-field pointer on baseline set/re-anchor only.
write_baseline() { # $1=run_dir $2=version $3=seed $4=corpus_fp $5=composition_fp $6=sessions
  python3 - "$BASELINE" "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json,sys,datetime
path, run_dir, version, seed, corpus_fp, composition_fp, sessions = sys.argv[1:8]
d = {
    "run_dir": run_dir, "version": version, "seed": int(seed),
    "corpus_fingerprint": corpus_fp, "composition_fingerprint": composition_fp,
    "sessions": int(sessions),
    "created_at": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(path, "w") as f:
    json.dump(d, f, indent=2); f.write("\n")
PY
}
# PRD-mcphost-measure-guards: function-only, sourced after ts/log/bus/sum_session_cost/
# ledger_cost exist (it calls them) and before any guard runs (it's called from both the
# redeploy branch and the harness-probe/measure tail below).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/vibeloop-measure-guards.sh"
mkdir -p "$EVD" "$PROXY_EVD" "$(dirname "$CAL")"; [ -f "$CAL" ] || echo 2 > "$CAL"
VIBELOOP_WATCHDOG_SECS="${VIBELOOP_WATCHDOG_SECS:-1200}"
SYNTHORG_SEED="${SYNTHORG_SEED:-0}"                                          # PRD-mcphost-measure-comparable req 5: fixed, never wall-clock.
COMPOSITION="${SYNTHORG_COMPOSITION:-corpora/mcphost/panel-composition.yaml}" # req 6: pinned, relative to $SYN.
CYCLE_SKIPS="$HOME/.config/vibeloop/measure-cycle-skips"
# req 10: STOP (written by vibeloop itself on plateau) no longer halts
# measurement — the plateau is a statement about PRDs, not an instruction to
# stop observing the endpoint. Only a human-deleted MEASURE-STOP does.
[ -f "$PRD_DIR/vibeloop/MEASURE-STOP" ] && { log "skip: MEASURE-STOP present: $(head -c 200 "$PRD_DIR/vibeloop/MEASURE-STOP" 2>/dev/null)"; exit 0; }
# req 11: an hourly timer racing cycles that run over an hour can starve this
# job forever on "skip: cycle running" alone — after three consecutive skips
# for that reason, wait for the cycle (bounded) instead of skipping a fourth.
if systemctl --user is-active --quiet claude-vibeloop-work.service; then
  skips=$(cat "$CYCLE_SKIPS" 2>/dev/null || echo 0); skips=${skips:-0}
  if [ "$skips" -ge 3 ]; then
    log "cycle running after $skips consecutive skips; waiting up to ${VIBELOOP_WATCHDOG_SECS}s"
    waited=0
    while systemctl --user is-active --quiet claude-vibeloop-work.service && [ "$waited" -lt "$VIBELOOP_WATCHDOG_SECS" ]; do
      sleep 10; waited=$((waited+10))
    done
    echo 0 > "$CYCLE_SKIPS"
    systemctl --user is-active --quiet claude-vibeloop-work.service && log "cycle still running after ${waited}s wait; proceeding anyway"
  else
    echo $((skips+1)) > "$CYCLE_SKIPS"; log "skip: cycle running"; exit 0
  fi
else
  echo 0 > "$CYCLE_SKIPS"
fi
since=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
awk -v s="$since" '$1 > s' "$HOME/brain/journal/vibeloop-auto.log" 2>/dev/null | grep -q 'quota-limited' && { log "skip: quota-limited in the last hour"; exit 0; }
since24=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
# req 2/4: sum sessions_spent (a missing field reads as 0), not lines — a
# refusal or a skip that opens no session must not bind the daily cap.
runs24=$(awk -v s="$since24" '$1 > s' "$MLEDGER" 2>/dev/null | grep -o 'sessions_spent=[0-9]*' | awk -F= '{sum+=$2} END{print sum+0}')
[ "$runs24" -ge "$MAX_MEASURES_PER_DAY" ] && { log "skip: daily cap ($runs24/$MAX_MEASURES_PER_DAY)"; exit 0; }
git -C "$PRD_DIR" pull -q --ff-only >/dev/null 2>&1
# --- what is built vs what is deployed ---
git -C "$CRATE" pull -q --ff-only >/dev/null 2>&1
# Compare versions BEFORE building. What "built" means (2026-09-08): the newest
# release tag reachable from main, not HEAD. ship-tag.sh only tags a commit
# whose gate passed, so a `v*` tag is a shipped release by construction —
# while HEAD is whatever the build lanes landed since (untagged, mid-flight,
# and legitimately gate-red on rollback-plan's head-untagged rule). Gating
# HEAD here let an in-flight PRD block a finished release for hours
# (0.27.0, 2026-09-08 13:50Z–14:55Z). No tag at all ⇒ the old HEAD path.
git -C "$CRATE" fetch -q --tags origin >/dev/null 2>&1
rel_tag=$(git -C "$CRATE" describe --tags --abbrev=0 --match 'v[0-9]*' origin/main 2>/dev/null || git -C "$CRATE" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)
if [ -n "$rel_tag" ]; then
  built="${rel_tag#v}"; build_ref="$rel_tag"
else
  built=$(git -C "$CRATE" show HEAD:Cargo.toml 2>/dev/null | awk -F'"' '/^version *=/{print $2; exit}'); build_ref=HEAD
fi
deployed=$(probe_deployed_version)
[ -z "$deployed" ] && { log "skip: hub healthz unreachable"; bus "{\"event\":\"hub-unreachable\",\"ts\":\"$(ts)\"}"; exit 0; }
[ -z "$built" ] && { log "skip: could not read crate version at HEAD"; exit 0; }
# PRD-mcphost-baseline-anchor req 3/AC4: a candidate run is refused before
# any session opens (redeploy, harness probe, or truth-tier consume all sit
# below this) when the standing baseline names a version other than what's
# deployed now. A plain run is never refused here — it's the mechanism that
# re-anchors a stale baseline (below, once its own measurement completes).
if [ "$VIBELOOP_CANDIDATE" = 1 ]; then
  bv=$(baseline_version)
  if [ -n "$bv" ] && [ "$bv" != "$deployed" ]; then
    log "candidate run refused: baseline stale (baseline=$bv deployed=$deployed)"
    echo "$(ts) version=$deployed candidate_refused=1 baseline=baseline_stale baseline_version=$bv deployed_version=$deployed sessions_spent=0" >> "$MLEDGER"
    git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: candidate refused, baseline stale ($bv != $deployed)" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
    bus "{\"event\":\"baseline-stale\",\"baseline_version\":\"$bv\",\"deployed_version\":\"$deployed\",\"ts\":\"$(ts)\"}"
    exit 0
  fi
fi
cal=$(cat "$CAL"); reason=""
if [ "$built" != "$deployed" ]; then
  if [ "$build_ref" != HEAD ]; then
    # Release-tag path: the tag is gate-green by ship-tag's contract, so no
    # gate run here (that was also the 7-minute fresh-gate cost that let a
    # leaked producer sandbox outlive the tick). Build the tag's tree in a
    # detached worktree so the lanes' main checkout is never touched.
    tag_sha=$(git -C "$CRATE" rev-parse --short "$build_ref")
    log "hub behind: release $build_ref ($tag_sha) says $built, hub runs $deployed — building the tag (HEAD $(git -C "$CRATE" rev-parse --short HEAD) may be mid-flight)"
    wt="$HOME/.cache/vibeloop-build/mcphost-$built"
    git -C "$CRATE" worktree remove --force "$wt" >/dev/null 2>&1 || true
    git -C "$CRATE" worktree add --detach -f "$wt" "$build_ref" >> "$LOG" 2>&1 || { log "worktree add failed for $build_ref"; exit 0; }
    ( cd "$wt" && CARGO_TARGET_DIR="$wt/target" cargo build --release -q ) >> "$LOG" 2>&1 || { log "build failed at $build_ref"; git -C "$CRATE" worktree remove --force "$wt" >/dev/null 2>&1; exit 0; }
    BUILT_BIN="$wt/target/release/mcphost"
  else
    log "hub behind: HEAD says $built, hub runs $deployed — checking the gate before building"
    # The fleet ships on extend-gate's verdict (pass OR delta-pass against the
    # committed agent/gate-baseline.json, PRD-build-gate-delta-baseline) — raw
    # `autobuilder gate` alone reads a baselined inherit as red and would never
    # redeploy a crate carrying one. extend-gate replays its verdict cache when
    # HEAD and the script are unchanged, so this is cheap on a quiet HEAD.
    EXTEND_GATE="$HOME/.claude/skills/build/scripts/extend-gate.sh"
    if [ -x "$EXTEND_GATE" ]; then
      gate_ok=true; ( cd "$CRATE" && bash "$EXTEND_GATE" "$CRATE" --head "$(git rev-parse HEAD)" ) >/dev/null 2>&1 || gate_ok=false
    else
      gate_ok=true; ( cd "$CRATE" && autobuilder gate --project . ) >/dev/null 2>&1 || gate_ok=false
    fi
    if [ "$gate_ok" != true ]; then
      blocks=$( cd "$CRATE" && autobuilder gate --project . 2>&1 | grep -E '✗' | cut -c1-90 | tr '\n' ';' )
      log "GATE RED at $(git -C "$CRATE" rev-parse --short HEAD): not redeploying $built. $blocks"
      echo "$(ts) version=$built gate=RED redeploy=skipped hub=$deployed blocks=\"$blocks\" sessions_spent=0" >> "$MLEDGER"
      git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: gate red at $built, redeploy skipped" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
      bus "{\"event\":\"gate-red\",\"version\":\"$built\",\"ts\":\"$(ts)\"}"; exit 0
    fi
    ( cd "$CRATE" && cargo build --release -q ) >> "$LOG" 2>&1 || { log "build failed at $(git -C "$CRATE" rev-parse --short HEAD)"; exit 0; }
    BUILT_BIN="$CRATE/target/release/mcphost"
  fi
  bin_v=$("$BUILT_BIN" version 2>/dev/null | awk '{print $NF}')
  [ "$bin_v" = "$built" ] || { log "skip: built binary reports $bin_v, manifest says $built"; exit 0; }
  log "redeploying $built from $BUILT_BIN"
  # PRD-mcphost-deployed-head req 2/3/7, AC1/AC2/AC8: capture the tool's own
  # exit code (not just success/fail) and its stdout (the probe's
  # [ok]/[FAIL] check lines + compat_check verdict) so the ledger line below
  # can record from/to versions, `deploy_failed` with the numeric exit code,
  # and the probe result — not just a journal-only note.
  hub_before="$deployed"
  redeploy_rc=0
  redeploy_out=$( cd "$DEPLOY" && timeout 900 uv run mcphost-deploy redeploy --host $HOST --binary "$BUILT_BIN" 2>&1 ) || redeploy_rc=$?
  echo "$redeploy_out" >> "$LOG"
  # release-tag path: the detached worktree has served its purpose
  [ "$build_ref" != HEAD ] && git -C "$CRATE" worktree remove --force "$HOME/.cache/vibeloop-build/mcphost-$built" >/dev/null 2>&1
  if [ "$redeploy_rc" -eq 0 ]; then
    deployed=$(probe_deployed_version)
    log "redeploy ok: hub now $deployed"; echo 2 > "$CAL"; cal=2; reason="new-version"
    compat=$(echo "$redeploy_out" | grep -o 'compat_check: [a-z]*' | head -1 | awk '{print $2}'); compat=${compat:-unknown}
    # AC1/AC8: the redeploy event's own ledger line — from/to versions,
    # sessions_spent=0 (no session opened yet), and the probe result. A
    # successful `mcphost-deploy redeploy` only ever returns exit 0 when its
    # own probe already passed (redeploy_mod.redeploy returns EXIT_ROLLBACK
    # on a failed probe), so probe=pass is exact here, not assumed.
    echo "$(ts) version=$built redeploy=ok from=$hub_before to=$deployed probe=pass compat_check=$compat sessions_spent=0" >> "$MLEDGER"
    git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: redeploy $hub_before -> $deployed ok, probe pass" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
    bus "{\"event\":\"redeploy-ok\",\"from\":\"$hub_before\",\"to\":\"$deployed\",\"ts\":\"$(ts)\"}"
    # req 3/AC3/AC4: proxy gate runs immediately after a successful redeploy,
    # before the harness probe or any truth-tier session — a zero-bootstrap
    # result writes its own terminal ledger line and this script exits here.
    proxy_out="$PROXY_EVD/$deployed-$(date -u +%Y%m%dT%H%M%SZ)"
    run_proxy_gate "$deployed" "$URL" "$proxy_out" || exit 0
  else
    # AC2/AC4: any non-zero exit (probe-failed rollback, refused-incompatible,
    # or a remote/ELF error before the switch ever took effect) leaves
    # $deployed — the hub's serving version — unchanged; `deploy_failed`
    # plus the numeric exit code is the literal token AC2 asks for.
    log "redeploy FAILED rc=$redeploy_rc (hub still $deployed) — not measuring"
    echo "$(ts) version=$built deploy_failed=1 exit_code=$redeploy_rc redeploy=FAILED-rolled-back-to-$deployed measured=no sessions_spent=0" >> "$MLEDGER"
    git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: redeploy $built failed rc=$redeploy_rc, rolled back" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
    bus "{\"event\":\"redeploy-failed\",\"version\":\"$built\",\"exit_code\":$redeploy_rc,\"ts\":\"$(ts)\"}"; exit 0
  fi
elif [ "$cal" -gt 0 ]; then reason="calibration($cal left)"
else log "skip: $deployed already measured, no calibration runs left"; exit 0; fi
# --- harness gate: measure only once a live session has completed signup -> publish -> call ---
VER="$HOME/.config/vibeloop/harness-verified"; PROBE_LAST="$HOME/.config/vibeloop/harness-probe-last"; PROBE_EVERY="${HARNESS_PROBE_SECS:-21600}"
if [ ! -f "$VER" ]; then
  now=$(date +%s); last=$(cat "$PROBE_LAST" 2>/dev/null | cut -d' ' -f1); last=${last:-0}
  last_head=$(cat "$PROBE_LAST" 2>/dev/null | cut -d' ' -f2); syn_head=$(git -C "$SYN" rev-parse --short HEAD 2>/dev/null)
  # The backoff only applies while the harness is unchanged: a new synthorg commit re-probes at once
  # (2026-09-04: a scorer fix shipped at 04:16Z and the probe sat on its 6 h backoff until 08:45Z).
  if [ "$last_head" = "$syn_head" ] && [ $((now-last)) -lt "$PROBE_EVERY" ]; then log "skip: harness unverified; next probe in $(( (PROBE_EVERY-(now-last))/60 )) min (synthorg $syn_head unchanged)"; exit 0; fi
  echo "$now $syn_head" > "$PROBE_LAST"; pd="$HOME/.cache/vibeloop/harness-probe"; rm -rf "$pd" "$SYN/runs/mcp-host-project-consume"; mkdir -p "$pd"
  log "harness probe: one live session (signup -> publish -> call?)"
  ( cd "$SYN" && SYNTHORG_LLM_MODE=record SYNTHORG_LLM_BACKEND=cli ANTHROPIC_MODEL="${SYNTHORG_MODEL_MID:-claude-sonnet-4-6}" timeout 900 uv run synthorg consume "$BRIEF" --endpoint "$URL" --out "$pd" --seed "$SYNTHORG_SEED" --composition "$COMPOSITION" --segments rapid_prototyper --panel 1 --deployed-version "$deployed" ) >> "$LOG" 2>&1
  verdict=$(python3 - "$pd/ledger.jsonl" <<'PY2'
import json,sys
try: rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception: print("no-ledger"); sys.exit()
r=rows[-1] if rows else {}
ok = r.get("t_first_own_call") is not None and (r.get("accuracy") or 0) > 0
print("pass" if ok else f"fail t_first_publish={r.get('t_first_publish')} t_first_own_call={r.get('t_first_own_call')} accuracy={r.get('accuracy')} family={r.get('failure_family')} cost={r.get('cost_usd')}")
PY2
)
  read -r probe_usd probe_known <<< "$(sum_session_cost "$pd/ledger.jsonl")"
  ledger_cost probe "$probe_usd" "$deployed" "$probe_known"
  if [ "$verdict" = "pass" ]; then
    date -u +%FT%TZ > "$VER"; log "harness probe PASS — measurement enabled from now on"
    # req 1: a probe that ran spends one session — the day's cap must see it.
    echo "$(ts) version=$deployed harness-probe=PASS sessions_spent=1" >> "$MLEDGER"
    git -C "$PRD_DIR" add vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" commit -q -m "measure: harness probe passed on $deployed" -- vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" push -q 2>/dev/null
    bus "{\"event\":\"harness-verified\",\"ts\":\"$(ts)\"}"
  else
    log "harness probe FAIL ($verdict) — not measuring; will re-probe in $((PROBE_EVERY/3600))h"
    cleanup_field=$(cleanup_tenants)
    echo "$(ts) version=$deployed harness-probe=FAIL $verdict sessions_spent=1${PROXY_FIELD} $cleanup_field" >> "$MLEDGER"
    git -C "$PRD_DIR" add "$PROXY_EVD" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" commit -q -m "measure: harness probe failed on $deployed" -- "$PROXY_EVD" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" push -q 2>/dev/null
    exit 0
  fi
fi
# --- measure ---
out="$EVD/$deployed-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$out"; rm -rf "$SYN/runs/mcp-host-project-consume"
log "measure start version=$deployed reason=$reason out=$out"
# req 5/6/7: fixed seed + pinned composition + fail-before-any-call on a
# panel the corpus can't serve, instead of a wall-clock seed and a
# re-derived-per-run panel that check_comparable/attribution can't use.
# SYNTHORG_JUDGE_PROVIDER (PRD-cross-model-judge): when set in limits, consume
# re-judges every session on the second provider and fills
# measure.json.judge_agreement (advisory; degrades silently if codex is
# unauthenticated). VIBELOOP_COMPARE_INCUMBENT=1 adds the incumbent-compare leg
# (switch verdicts per segment) to every truth-tier measure — roughly doubles
# the run's sessions. Both are operator decisions of 2026-09-08.
( cd "$SYN" && SYNTHORG_LLM_MODE=record SYNTHORG_LLM_BACKEND=cli SYNTHORG_LLM_CONCURRENCY="${SYNTHORG_LLM_CONCURRENCY:-4}" ANTHROPIC_MODEL="${SYNTHORG_MODEL_MID:-claude-sonnet-4-6}" SYNTHORG_JUDGE_PROVIDER="${SYNTHORG_JUDGE_PROVIDER:-}" timeout 5400 uv run synthorg consume "$BRIEF" --endpoint "$URL" --out "$out" --seed "$SYNTHORG_SEED" --composition "$COMPOSITION" --strict-segments --deployed-version "$deployed" ${VIBELOOP_COMPARE_INCUMBENT:+--compare-incumbent} ) >> "$LOG" 2>&1; rc=$?
# req 1: the truth tier just finished (success or failure) — clean up now,
# before either branch below writes the run's terminal ledger line.
cleanup_field=$(cleanup_tenants)
if [ ! -f "$out/measure.json" ]; then
  # req 1: no measure.json means no observably-completed session to count —
  # ledger.jsonl is only ever written once, at the end of a successful
  # consume run, so a killed/failed run leaves nothing on disk to sum from.
  ns=0; [ -f "$out/ledger.jsonl" ] && ns=$(wc -l < "$out/ledger.jsonl" 2>/dev/null || echo 0)
  log "measure FAILED rc=$rc (no measure.json) sessions_spent=$ns"
  echo "$(ts) version=$deployed reason=$reason measured=FAILED rc=$rc sessions_spent=$ns${PROXY_FIELD} $cleanup_field" >> "$MLEDGER"
  if [ "$ns" -gt 0 ]; then
    read -r fail_usd fail_known <<< "$(sum_session_cost "$out/ledger.jsonl")"
    ledger_cost measure "$fail_usd" "$deployed" "$fail_known"
  fi
  rmdir "$out" 2>/dev/null
else
  summary=$(python3 - "$out/measure.json" <<'PY'
import json,sys;d=json.load(open(sys.argv[1]))
seg=d.get('by_segment') or {}
print(f"satisfaction={d.get('satisfaction')} wow_rate={d.get('wow_rate')} sessions={d.get('sessions')} failures={json.dumps(d.get('failures'))} segments={len(seg)}")
PY
)
  ns=$(python3 -c "import json;print(json.load(open('$out/measure.json')).get('sessions',0))" 2>/dev/null || echo 0)
  read -r meas_usd meas_known <<< "$(sum_session_cost "$out/ledger.jsonl")"
  ledger_cost measure "$meas_usd" "$deployed" "$meas_known"
  # PRD-mcphost-baseline-anchor req 2: the prior-run-of-the-same-version
  # comparison this used to be (req 9) is superseded, not kept alongside —
  # lift now runs against whatever run.baseline.json names, read before this
  # run has any chance to become the new baseline itself (below), so a
  # run's own baseline write never turns it into a self-comparison.
  lift_field=""
  base_dir=$(baseline_run_dir)
  if [ -n "$base_dir" ] && [ -d "$base_dir" ]; then
    if lift_txt=$(cd "$SYN" && uv run synthorg lift --baseline "$base_dir" --candidate "$out" --out "$out/lift.json" 2>&1); then
      lift_field=" lift=\"$(echo "$lift_txt" | tr '\n' ' ' | tr -d '"')\""
    else
      lift_field=" lift_error=\"$(echo "$lift_txt" | tr '\n' ' ' | tr -d '"')\""
    fi
    # PRD-mcphost-harness-sample-size req 3 (operator decision 2026-09-08):
    # after the first lift, extend ONLY the segments lift left `undecided`,
    # VIBELOOP_EXTEND_ROUNDS rounds of VIBELOOP_EXTEND_ADD sessions each
    # (limits: 1 × 3 → at most 6 per segment; lift's own
    # --max-sessions-per-segment stays the ceiling), re-lifting after each
    # round. `--extend` refuses baseline-role runs and moved endpoints itself,
    # so a baseline is never grown here. A failed round logs and stops; the
    # first lift's result stands.
    if [ -f "$out/lift.json" ] && [ "${VIBELOOP_EXTEND_ROUNDS:-0}" -gt 0 ]; then
      for round in $(seq 1 "${VIBELOOP_EXTEND_ROUNDS}"); do
        # lift.json's per-segment list is `segments` (an array of {segment, decision:{decision,n,...}, satisfaction:{...}});
        # `by_segment` is accepted as a fallback for older lift outputs. Reading the wrong key silently
        # yields "nothing undecided" — which is exactly what happened on the first 0.27.0 candidate (2026-09-08 16:03Z).
        und=$(python3 -c "import json;d=json.load(open('$out/lift.json'));segs=d.get('segments') or d.get('by_segment') or [];print(','.join(s['segment'] for s in segs if (s.get('decision') or {}).get('decision')=='undecided'))" 2>/dev/null)
        [ -n "$und" ] || { log "extend: every segment decided after round $((round-1))"; break; }
        log "extend round $round: undecided=$und add=${VIBELOOP_EXTEND_ADD:-3}"
        ext_rc=0
        ( cd "$SYN" && SYNTHORG_LLM_MODE=record SYNTHORG_LLM_BACKEND=cli SYNTHORG_LLM_CONCURRENCY="${SYNTHORG_LLM_CONCURRENCY:-4}" ANTHROPIC_MODEL="${SYNTHORG_MODEL_MID:-claude-sonnet-4-6}" SYNTHORG_JUDGE_PROVIDER="${SYNTHORG_JUDGE_PROVIDER:-}" timeout 3600 uv run synthorg consume "$BRIEF" --extend "$out" --segments "$und" --add "${VIBELOOP_EXTEND_ADD:-3}" --out "$out" --endpoint "$URL" --deployed-version "$deployed" ) >> "$LOG" 2>&1 || ext_rc=$?
        if [ "$ext_rc" -ne 0 ]; then log "extend round $round failed rc=$ext_rc — keeping the pre-extend lift"; break; fi
        if lift_txt=$(cd "$SYN" && uv run synthorg lift --baseline "$base_dir" --candidate "$out" --out "$out/lift.json" 2>&1); then
          lift_field=" lift=\"$(echo "$lift_txt" | tr '\n' ' ' | tr -d '"')\" extend_rounds=$round"
        else
          lift_field=" lift_error=\"$(echo "$lift_txt" | tr '\n' ' ' | tr -d '"')\" extend_rounds=$round"
        fi
      done
      # session count and cost now include the extension rounds
      ns=$(python3 -c "import json;print(json.load(open('$out/measure.json')).get('sessions',0))" 2>/dev/null || echo "$ns")
    fi
  fi
  # req 1/3/4/AC1/AC3/AC5: a plain (non-candidate) comparable run sets the
  # baseline when none stands yet, or re-anchors it when the standing one
  # names a version other than what's deployed now. A candidate run, or a
  # run that predates comparability, never touches baseline.json.
  baseline_field=""
  if [ "$VIBELOOP_CANDIDATE" != 1 ]; then
    read -r elig elig_seed elig_corpus_fp elig_comp_fp elig_sessions <<< "$(measure_comparability "$out/measure.json")"
    if [ "$elig" = "eligible" ]; then
      cur_bv=$(baseline_version)
      if [ -z "$cur_bv" ]; then
        write_baseline "$out" "$deployed" "$elig_seed" "$elig_corpus_fp" "$elig_comp_fp" "$elig_sessions"
        baseline_field=" baseline=baseline_set"
        log "baseline_set: $out ($deployed)"
        git -C "$PRD_DIR" add vibeloop/baseline.json && git -C "$PRD_DIR" commit -q -m "measure: baseline_set at $deployed ($(basename "$out"))" -- vibeloop/baseline.json && git -C "$PRD_DIR" push -q 2>/dev/null
        bus "{\"event\":\"baseline-set\",\"version\":\"$deployed\",\"run_dir\":\"$out\",\"ts\":\"$(ts)\"}"
      elif [ "$cur_bv" != "$deployed" ]; then
        write_baseline "$out" "$deployed" "$elig_seed" "$elig_corpus_fp" "$elig_comp_fp" "$elig_sessions"
        baseline_field=" baseline=baseline_reanchored"
        log "baseline_reanchored: $out ($cur_bv -> $deployed)"
        git -C "$PRD_DIR" add vibeloop/baseline.json && git -C "$PRD_DIR" commit -q -m "measure: baseline_reanchored $cur_bv -> $deployed ($(basename "$out"))" -- vibeloop/baseline.json && git -C "$PRD_DIR" push -q 2>/dev/null
        bus "{\"event\":\"baseline-reanchored\",\"from\":\"$cur_bv\",\"to\":\"$deployed\",\"run_dir\":\"$out\",\"ts\":\"$(ts)\"}"
      fi
    fi
  fi
  echo "$(basename "$out")" > "$EVD/LATEST"; [ "$reason" != "new-version" ] && echo $((cal-1)) > "$CAL"
  echo "$(ts) version=$deployed reason=$reason $summary dir=$(basename "$out") sessions_spent=$ns$lift_field$baseline_field${PROXY_FIELD} $cleanup_field" >> "$MLEDGER"
  log "measure ok: $summary sessions_spent=$ns$lift_field$baseline_field${PROXY_FIELD} $cleanup_field"
fi
git -C "$PRD_DIR" add "$EVD" "$PROXY_EVD" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" commit -q -m "measure: $deployed ($reason) — $(tail -n1 "$MLEDGER" | cut -c21-120)" -- "$EVD" "$PROXY_EVD" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" push -q 2>/dev/null
bus "{\"event\":\"measured\",\"version\":\"$deployed\",\"reason\":\"$reason\",\"line\":$(tail -n1 "$MLEDGER" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))'),\"ts\":\"$(ts)\"}"
