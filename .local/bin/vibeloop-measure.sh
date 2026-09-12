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
# Long-running evidence (minutes to an hour of writes) must never live inside
# $PRD_DIR while it's incomplete — claude-vibeloop-tick.sh's `git pull --rebase
# --autostash`, /build's lane-claim.sh `git reset --hard`, and interactive
# sessions all touch that checkout concurrently, and a directory caught
# mid-write there can vanish under a rebase/autostash cycle (2026-09-08
# 18:55Z: ledger.jsonl went missing mid-run, reappeared seconds later on
# autostash pop). Write to $WORK_EVD instead and land_evidence() the finished
# directory into $PRD_DIR only once, right before it's committed.
WORK_EVD="${VIBELOOP_WORK_EVD:-$HOME/.cache/vibeloop-evidence}"; mkdir -p "$WORK_EVD"
land_evidence() { # $1 = work dir, $2 = final dir inside $PRD_DIR
  mkdir -p "$(dirname "$2")"; rm -rf "$2"; mv "$1" "$2"; }
export WORK_EVD
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
# PRD-vibeloop-measure-self-authorized-redeploy: MEASURE_UNATTENDED_DEPLOY=off
# is the operator killswitch for the migrate flags/env var below (requirement
# 5); ROLLED_BACK_STATE is the "don't retry a rolled-back range until
# last_pass changes" pointer (requirement 8).
MEASURE_UNATTENDED_DEPLOY="${MEASURE_UNATTENDED_DEPLOY:-on}"
ROLLED_BACK_STATE="$(rolled_back_state_path)"
# PRD-build-worktree-targets-off-root: function-only (cargo_target_root,
# build_tag_worktree, cleanup_tag_worktree) — the release-tag build path
# below uses these so its ~52G CARGO_TARGET_DIR never sits on the root
# filesystem. tests/vibeloop-target-root.test.sh sources this file directly.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/vibeloop-target-root.sh"
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
git -C "$CRATE" fetch -q --tags origin >/dev/null 2>&1
deployed=$(probe_deployed_version)
[ -z "$deployed" ] && { log "skip: hub healthz unreachable"; bus "{\"event\":\"hub-unreachable\",\"ts\":\"$(ts)\"}"; exit 0; }
# PRD-vibeloop-measure-deploy-last-pass req 1: target selection comes from
# `mcphost-deploy doctor` — the canonical main/last_pass/deployed-sha/drift
# reckoning `mcphost-deploy-refuse-ungated` already computes for its own
# `redeploy --sha ... --skip-if-ungated` gate — instead of this script's own
# git-tag/HEAD heuristic (rel_tag/built/build_ref, removed here) and its own
# hand-rolled extend-gate/autobuilder gate check (removed below with the old
# GATE RED branch). Single source of truth for "is prod behind a green
# main?", per SKILL.md's shipping-contract doctrine: new shipping/gate
# responsibilities are added at their one authority, not re-enumerated here.
doctor_txt=$( cd "$DEPLOY" && timeout 30 uv run mcphost-deploy doctor --host "$HOST" 2>&1 )
doctor_rc=$?
if [ "$doctor_rc" -ne 0 ] || [ -z "$doctor_txt" ]; then
  log "skip: mcphost-deploy doctor unreachable/failed (rc=$doctor_rc): $(printf '%s' "$doctor_txt" | head -c 200)"
  # req 6/AC7: doctor-unreachable is a recorded deploy outcome now, not a
  # silent skip -- no last_pass was ever read, so deploy_range is empty.
  echo "$(ts) version=$deployed $(deploy_ledger_fields skipped doctor-unreachable "" "$deployed") sessions_spent=0" >> "$MLEDGER"
  git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: skip, doctor unreachable" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
  exit 0
fi
read -r doc_main doc_last_pass doc_deployed doc_drift <<< "$(doctor_parse <<< "$doctor_txt")"
DRIFT_FIELD=$(deploy_drift_field "$doc_drift")
[ -z "$doc_main" ] && { log "skip: doctor output unparseable: $(printf '%s' "$doctor_txt" | head -c 200)"; exit 0; }
# PRD-mcphost-baseline-anchor req 3/AC4: a candidate run is refused before
# any session opens (redeploy, harness probe, or truth-tier consume all sit
# below this) when the standing baseline names a version other than what's
# deployed now. A plain run is never refused here — it's the mechanism that
# re-anchors a stale baseline (below, once its own measurement completes).
if [ "$VIBELOOP_CANDIDATE" = 1 ]; then
  bv=$(baseline_version)
  if [ -n "$bv" ] && [ "$bv" != "$deployed" ]; then
    log "candidate run refused: baseline stale (baseline=$bv deployed=$deployed)"
    echo "$(ts) version=$deployed candidate_refused=1 baseline=baseline_stale baseline_version=$bv deployed_version=$deployed $DRIFT_FIELD sessions_spent=0" >> "$MLEDGER"
    git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: candidate refused, baseline stale ($bv != $deployed)" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
    bus "{\"event\":\"baseline-stale\",\"baseline_version\":\"$bv\",\"deployed_version\":\"$deployed\",\"ts\":\"$(ts)\"}"
    exit 0
  fi
fi
cal=$(cat "$CAL"); reason=""; redeployed=0
target=$(lastpass_target "$doc_last_pass" "$doc_deployed")
# PRD-vibeloop-measure-self-authorized-redeploy: the deploy-outcome fields
# every ledger line from here on carries (Goals: "one deploy outcome per
# run with its cause"). Default is "nothing was due this cycle" -- the
# redeploy branch below overwrites all four the moment it decides otherwise.
deploy_outcome=not-due; deploy_cause=none; deploy_range=""; deployed_sha_field="$doc_deployed"
if [ "${target%% *}" = redeploy ]; then
  lp_sha="${target#redeploy }"
  # req 1/2: the authorization range is built from the SAME doctor read used
  # to pick this target -- $doc_deployed and $lp_sha are both this run's own
  # variables, never a cached file. $deployed is the healthz semantic version
  # (e.g. "0.43.0"), never a sha -- mcphost-deploy's authorize check compares
  # against its own sha-based deployed reckoning and refuses on a version-vs-
  # sha mismatch (observed live 2026-09-12T12:52Z: authorize
  # '0.43.0..0f24e14...' did not match 'bb5b466...0f24e14...'). doc_deployed
  # is the sha doctor_parse just read from the same doctor call.
  authorize_range=$(deploy_authorize_range "$doc_deployed" "$lp_sha")
  if rolled_back_pending "$ROLLED_BACK_STATE" "$lp_sha"; then
    # req 8/AC8: the same range already rolled back once -- do not retry it
    # every hour; wait for last_pass itself to move (a new green build).
    log "skip: rolled-back-pending-new-green for last_pass=$lp_sha (range $authorize_range)"
    deploy_outcome=skipped; deploy_cause=rolled-back-pending-new-green; deploy_range="$authorize_range"
  else
  # req 1: build exactly the sha doctor named as last_pass. `doctor` only
  # ever names a TAGGED sha (GitLog.last_pass_sha() reads the newest tag),
  # so the tag itself is the build_ref -- same worktree-off-root machinery
  # the old release-tag path used (PRD-build-worktree-targets-off-root).
  rel_tag=$(git -C "$CRATE" describe --tags --exact-match "$lp_sha" 2>/dev/null)
  if [ -z "$rel_tag" ]; then
    log "skip: doctor last_pass=$lp_sha has no matching tag in $CRATE — can't resolve a build target"
    deploy_outcome=skipped; deploy_cause=unresolvable-last-pass; deploy_range="$authorize_range"
    echo "$(ts) version=unknown redeploy=skipped cause=unresolvable-last-pass last_pass=$lp_sha $(deploy_ledger_fields "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field") $DRIFT_FIELD sessions_spent=0" >> "$MLEDGER"
    git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: last_pass $lp_sha unresolvable, redeploy skipped" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
    exit 0
  fi
  built="${rel_tag#v}"
  log "hub behind: last_pass $rel_tag ($lp_sha) ahead of deployed ($doc_deployed) — building the tag"
  # PRD-build-worktree-targets-off-root: CARGO_TARGET_DIR lives under
  # cargo_target_root() (off the root filesystem), not under the worktree
  # itself; build_tag_worktree cleans up both worktree and target dir on
  # its own failure.
  BUILT_BIN="$(build_tag_worktree "$CRATE" "$built" "$rel_tag" "$LOG")" || { log "build failed at $rel_tag"; exit 0; }
  bin_v=$("$BUILT_BIN" version 2>/dev/null | awk '{print $NF}')
  if [ "$bin_v" != "$built" ]; then
    log "skip: built binary reports $bin_v, manifest says $built"; cleanup_tag_worktree "$CRATE" "$built"; exit 0
  fi
  log "redeploying last_pass $lp_sha ($built) from $BUILT_BIN"
  # PRD-mcphost-deployed-head req 2/3/7, AC1/AC2/AC8: capture the tool's own
  # exit code (not just success/fail) and its stdout (the probe's
  # [ok]/[FAIL] check lines + compat_check verdict) so the ledger line below
  # can record from/to versions, `deploy_failed` with the numeric exit code,
  # and the probe result — not just a journal-only note. `--skip-if-ungated`
  # is redeploy_mod's OWN gate check (PRD-mcphost-deploy-refuse-ungated) —
  # doctor and this flag must agree, but the flag is authoritative: it's the
  # one enforced at the actual deploy boundary.
  #
  # PRD-vibeloop-measure-self-authorized-redeploy req 1/5: the authorized
  # path adds exactly two flags plus one env var on top of the existing
  # invocation -- MEASURE_UNATTENDED_DEPLOY=off is the only thing that
  # drops them, reverting to the old (always-refused-on-a-migration) call.
  hub_before="$deployed"
  redeploy_rc=0
  unattended=0; unattended_deploy_enabled && unattended=1
  redeploy_args=(redeploy --host "$HOST" --binary "$BUILT_BIN" --sha "$lp_sha" --skip-if-ungated)
  if [ "$unattended" = 1 ]; then
    while IFS= read -r f; do redeploy_args+=("$f"); done < <(redeploy_migrate_flags 1)
    redeploy_out=$( cd "$DEPLOY" && MCPHOST_DEPLOY_AUTHORIZE="$authorize_range" timeout 900 uv run mcphost-deploy "${redeploy_args[@]}" 2>&1 ) || redeploy_rc=$?
  else
    redeploy_out=$( cd "$DEPLOY" && timeout 900 uv run mcphost-deploy "${redeploy_args[@]}" 2>&1 ) || redeploy_rc=$?
  fi
  echo "$redeploy_out" >> "$LOG"
  # the detached worktree AND its cargo target-dir have served their
  # purpose — free both now, redeploy succeeded or failed (req 5).
  cleanup_tag_worktree "$CRATE" "$built"
  if [ "$redeploy_rc" -eq 0 ] && printf '%s' "$redeploy_out" | grep -q '^redeploy  skipped'; then
    # Defensive: doctor said last_pass was gated but the tool's own
    # (authoritative) check at deploy time disagreed -- e.g. a gate verdict
    # cache changed between the doctor read and this call. Never claim a
    # deploy happened; fall through to the req-2 clean-skip path below,
    # exactly as if target had been "measure".
    :
  else
    read -r deploy_outcome deploy_cause <<< "$(classify_deploy_outcome "$redeploy_rc" "$redeploy_out")"
    deploy_range="$authorize_range"
    # req 5/AC6: the killswitch names ITS OWN reason -- whatever cause the
    # tool's journal printed is a moot point when this step never even
    # tried to authorize the migration.
    [ "$unattended" != 1 ] && deploy_cause=disabled-by-step
    if [ "$deploy_outcome" = deployed ]; then
      deployed=$(probe_deployed_version)
      # deployed_sha (P0 req 3) is a sha, not the healthz semantic version --
      # the tool only ever returns 0 here after its own probe confirmed
      # $lp_sha is serving, so that's the post-run doctor-shaped truth
      # without a second live doctor round-trip.
      deployed_sha_field="$lp_sha"
      log "redeploy ok: hub now $deployed"; echo 2 > "$CAL"; cal=2; reason="new-version"; redeployed=1
      compat=$(echo "$redeploy_out" | grep -o 'compat_check: [a-z]*' | head -1 | awk '{print $2}'); compat=${compat:-unknown}
      # req 1/AC1: the redeploy event's own ledger + journal lines — from/to
      # versions, the last_pass sha it targeted, deploy_drift, and the probe
      # result. A successful `mcphost-deploy redeploy` only ever returns exit
      # 0 when its own probe already passed, so probe=pass is exact here.
      log "redeploy  target=last_pass sha=$lp_sha"
      echo "$(ts) version=$built redeploy=ok target=last_pass sha=$lp_sha from=$hub_before to=$deployed probe=pass compat_check=$compat $(deploy_ledger_fields "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field") $DRIFT_FIELD sessions_spent=0" >> "$MLEDGER"
      git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: redeploy $hub_before -> $deployed ok (last_pass $lp_sha), probe pass" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
      bus "{\"event\":\"redeploy-ok\",\"from\":\"$hub_before\",\"to\":\"$deployed\",\"ts\":\"$(ts)\"}"
      # a landed deploy proves the range is no longer stuck rolled-back.
      clear_rolled_back_pending "$ROLLED_BACK_STATE"
      # req 3/AC3/AC4: proxy gate runs immediately after a successful redeploy,
      # before the harness probe or any truth-tier session — a zero-bootstrap
      # result writes its own terminal ledger line and this script exits here.
      proxy_out="$PROXY_EVD/$deployed-$(date -u +%Y%m%dT%H%M%SZ)"
      run_proxy_gate "$deployed" "$URL" "$proxy_out" || exit 0
    else
      # req 4/AC3/AC4: a refused or rolled-back deploy is NOT an error for
      # this step — $deployed (the hub's serving version) is unchanged, the
      # outcome/cause are recorded, and the run falls through to measure
      # whatever is still deployed (no early `exit 0` here anymore) so the
      # loop stays green and measuring. deployed_sha stays $doc_deployed --
      # the sha this run's own doctor read said was serving before the
      # (failed) attempt; nothing changed it.
      deployed_sha_field="$doc_deployed"
      [ "$deploy_outcome" = rolled-back ] && record_rolled_back_pending "$ROLLED_BACK_STATE" "$lp_sha"
      # PRD-mcphost-deploy-incompatible-migration requirement 4: re-reading
      # `doctor` right after names how many consecutive cycles this streak
      # is now at, in this same run record, rather than only in the next
      # cycle's separately-timed doctor read.
      deploy_refused_field=""
      if [ "$redeploy_rc" -eq 5 ]; then
        refused_doctor_txt=$( cd "$DEPLOY" && timeout 30 uv run mcphost-deploy doctor --host "$HOST" 2>&1 )
        refused_n=$(echo "$refused_doctor_txt" | grep -oE 'deploy_refused_cycles=[0-9]+' | head -1 | cut -d= -f2)
        deploy_refused_field=" deploy_refused=${refused_n:-1}"
      fi
      log "redeploy $deploy_outcome rc=$redeploy_rc (hub still $deployed) cause=$deploy_cause — continuing to measure"
      echo "$(ts) version=$built deploy_failed=1 exit_code=$redeploy_rc redeploy=FAILED-rolled-back-to-$deployed measured=no $(deploy_ledger_fields "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field") $DRIFT_FIELD sessions_spent=0$deploy_refused_field" >> "$MLEDGER"
      git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: last_pass redeploy $lp_sha $deploy_outcome rc=$redeploy_rc (cause=$deploy_cause)" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
      bus "{\"event\":\"redeploy-$deploy_outcome\",\"version\":\"$built\",\"exit_code\":$redeploy_rc,\"cause\":\"$deploy_cause\",\"ts\":\"$(ts)\"}"
      # no `exit 0` here (req 4) — falls through to the measure tail below.
    fi
  fi
  fi
fi
if [ "$redeployed" -ne 1 ]; then
  # req 2: nothing new gated to ship (target=measure), or the tool's own
  # gate check disagreed with doctor's read and skipped defensively above --
  # either way this is the clean-skip path: journal it once, never a
  # failed-redeploy/rollback line, and still measure whatever is running.
  if [ -n "$doc_main" ] && [ "$doc_main" != "$doc_last_pass" ]; then
    log "redeploy  skipped  (cause=ungated sha=$doc_main deployed=$doc_deployed)"
    echo "$(ts) version=$deployed redeploy=skipped cause=ungated head=$doc_main $(deploy_ledger_fields "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field") $DRIFT_FIELD sessions_spent=0" >> "$MLEDGER"
    git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: redeploy skipped, head ungated (last_pass already deployed)" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
  fi
  if [ "$cal" -gt 0 ]; then reason="calibration($cal left)"
  else
    log "skip: $deployed already measured, no calibration runs left"
    echo "$(ts) version=$deployed $(deploy_ledger_fields "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field") sessions_spent=0" >> "$MLEDGER"
    git -C "$PRD_DIR" add vibeloop/measure-ledger.md && git -C "$PRD_DIR" commit -q -m "measure: skip, no calibration left ($deployed)" -- vibeloop/measure-ledger.md && git -C "$PRD_DIR" push -q 2>/dev/null
    exit 0
  fi
fi
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
    echo "$(ts) version=$deployed harness-probe=PASS $(deploy_ledger_fields "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field") $DRIFT_FIELD sessions_spent=1" >> "$MLEDGER"
    git -C "$PRD_DIR" add vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" commit -q -m "measure: harness probe passed on $deployed" -- vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" push -q 2>/dev/null
    bus "{\"event\":\"harness-verified\",\"ts\":\"$(ts)\"}"
  else
    log "harness probe FAIL ($verdict) — not measuring; will re-probe in $((PROBE_EVERY/3600))h"
    cleanup_field=$(cleanup_tenants)
    echo "$(ts) version=$deployed harness-probe=FAIL $verdict $(deploy_ledger_fields "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field") $DRIFT_FIELD sessions_spent=1${PROXY_FIELD} $cleanup_field" >> "$MLEDGER"
    git -C "$PRD_DIR" add "$PROXY_EVD" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" commit -q -m "measure: harness probe failed on $deployed" -- "$PROXY_EVD" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" push -q 2>/dev/null
    exit 0
  fi
fi
# --- measure ---
final_out="$EVD/$deployed-$(date -u +%Y%m%dT%H%M%SZ)"; out="$WORK_EVD/measure/$(basename "$final_out")"; mkdir -p "$out"; rm -rf "$SYN/runs/mcp-host-project-consume"
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
  echo "$(ts) version=$deployed reason=$reason measured=FAILED rc=$rc $(deploy_ledger_fields "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field") $DRIFT_FIELD sessions_spent=$ns${PROXY_FIELD} $cleanup_field" >> "$MLEDGER"
  if [ "$ns" -gt 0 ]; then
    read -r fail_usd fail_known <<< "$(sum_session_cost "$out/ledger.jsonl")"
    ledger_cost measure "$fail_usd" "$deployed" "$fail_known"
  fi
  rmdir "$out" 2>/dev/null
  # land whatever's left (usually nothing, rmdir already cleaned the empty
  # case) so the final catch-all `git add "$EVD"` below can see it.
  [ -d "$out" ] && land_evidence "$out" "$final_out"
  out="$final_out"
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
  # req 3: fold this run's deploy decision into measure.json itself, not
  # just the ledger line — a later reader of the evidence directory alone
  # (no ledger context) still sees what the deploy step did this cycle.
  merge_deploy_fields_json "$out/measure.json" "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field"
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
        # req 8 (2026-09-08T22:05Z re-lift refusal): an extend round that ran in non-compare
        # mode against a compare-mode truth run left measure.json without compare_incumbent,
        # and synthorg lift refused with "compare mode mismatch (baseline='compare',
        # candidate='non-compare')" — extension sessions must run in the same mode as the
        # run they extend, so this carries the identical conditional flag forward.
        ( cd "$SYN" && SYNTHORG_LLM_MODE=record SYNTHORG_LLM_BACKEND=cli SYNTHORG_LLM_CONCURRENCY="${SYNTHORG_LLM_CONCURRENCY:-4}" ANTHROPIC_MODEL="${SYNTHORG_MODEL_MID:-claude-sonnet-4-6}" SYNTHORG_JUDGE_PROVIDER="${SYNTHORG_JUDGE_PROVIDER:-}" timeout 3600 uv run synthorg consume "$BRIEF" --extend "$SYN/runs/mcp-host-project-consume" --segments "$und" --add "${VIBELOOP_EXTEND_ADD:-3}" --out "$out" --endpoint "$URL" --deployed-version "$deployed" ${VIBELOOP_COMPARE_INCUMBENT:+--compare-incumbent} ) >> "$LOG" 2>&1 || ext_rc=$?
        # (--extend names synthorg's own run directory — the one holding config.yaml/traces that the
        #  truth-tier consume just wrote — while --out stays the evidence dir; passing the evidence
        #  dir to --extend fails with FileNotFoundError config.yaml, seen 2026-09-08T17:04Z)
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
  # land the finished run into the PRD checkout now — this is the last point
  # anything reads/writes it as a work-in-progress. Everything from here on
  # (baseline.json's run_dir, EVD/LATEST, the ledger's dir= field, and the
  # final git add) must name the landed, committed path, not the work dir.
  land_evidence "$out" "$final_out"; out="$final_out"
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
  echo "$(ts) version=$deployed reason=$reason $summary dir=$(basename "$out") $(deploy_ledger_fields "$deploy_outcome" "$deploy_cause" "$deploy_range" "$deployed_sha_field") $DRIFT_FIELD sessions_spent=$ns$lift_field$baseline_field${PROXY_FIELD} $cleanup_field" >> "$MLEDGER"
  log "measure ok: $summary sessions_spent=$ns$lift_field$baseline_field${PROXY_FIELD} $cleanup_field"
fi
git -C "$PRD_DIR" add "$EVD" "$PROXY_EVD" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" commit -q -m "measure: $deployed ($reason) — $(tail -n1 "$MLEDGER" | cut -c21-120)" -- "$EVD" "$PROXY_EVD" vibeloop/measure-ledger.md "$CL" && git -C "$PRD_DIR" push -q 2>/dev/null
bus "{\"event\":\"measured\",\"version\":\"$deployed\",\"reason\":\"$reason\",\"line\":$(tail -n1 "$MLEDGER" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))'),\"ts\":\"$(ts)\"}"
