#!/usr/bin/env bash
# grand-loop-demand-lib.sh — function-only library for grand-loop-demand.sh
# (PRD-grand-loop-demand-cadence). Sourced by the runner and by
# tests/demandcadence_*.test.sh directly, so the decision logic (clone
# self-heal, row building, alarm streak, real_tenants-diff detection) is
# exercised with a fixture `mcphost-deploy`/`agorabus` and a local bare git
# repo standing in for origin — no network, no real PRDs clone touched.
# Mirrors the grand-loop-lib.sh / vibeloop-measure-guards.sh convention:
# no top-level side effects at source time.
set -uo pipefail

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ts() { ts; }

# demand_today — the run's "today". GRAND_LOOP_DEMAND_TODAY is a test-only
# override (unset in production) so tests can drive the once-a-day logic
# across simulated days without waiting on the clock.
demand_today() { echo "${GRAND_LOOP_DEMAND_TODAY:-$(date -u +%F)}"; }

log_line() { # $1=logfile $2=message
  local logfile="$1" msg="$2"
  mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
  echo "$(ts) $msg" >> "$logfile"
}

bus_publish() { # $1=topic $2=json_payload — best-effort, never fails the caller
  command -v agorabus >/dev/null 2>&1 && \
    timeout 5 agorabus publish "$1" "$2" --session-id grand-loop-demand >/dev/null 2>&1
  return 0
}

# ---- dedicated clone (self-healing: absent -> clone; diverged -> reset) ---
#
# "Diverged" here means origin holds history local doesn't have (a normal
# behind, or a genuine rewrite) — reset --hard brings local into line, and
# the PRD's row notes it. Local sitting AHEAD of origin (this runner's own
# not-yet-pushed commit from a prior push failure, req 6) is never reset —
# that data would be lost, and the whole point of the push-failure row is
# that the next successful run pushes it through.
ensure_git_identity() { # $1=dir
  git -C "$1" config user.email >/dev/null 2>&1 || git -C "$1" config user.email jyen.tech@gmail.com
  git -C "$1" config user.name  >/dev/null 2>&1 || git -C "$1" config user.name  "Joe Yen"
}

ensure_demand_clone() { # $1=dir $2=origin $3=branch -> prints state word; 0 ok, 1 fail
  local dir="$1" origin="$2" branch="${3:-main}"
  if [ ! -d "$dir/.git" ]; then
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    if git clone -q --branch "$branch" "$origin" "$dir" >/dev/null 2>&1; then
      ensure_git_identity "$dir"
      echo "cloned"; return 0
    fi
    echo "fail-clone"; return 1
  fi
  ensure_git_identity "$dir"
  if ! git -C "$dir" fetch -q origin "$branch" >/dev/null 2>&1; then
    echo "fail-fetch"; return 1
  fi
  local local_head remote_head
  local_head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || { echo "fail-local-head"; return 1; }
  remote_head="$(git -C "$dir" rev-parse "origin/$branch" 2>/dev/null)" || { echo "fail-remote-head"; return 1; }
  if [ "$local_head" = "$remote_head" ]; then
    echo "clean"; return 0
  fi
  if git -C "$dir" merge-base --is-ancestor "$remote_head" "$local_head" 2>/dev/null; then
    echo "ahead"; return 0
  fi
  if git -C "$dir" reset -q --hard "$remote_head" >/dev/null 2>&1; then
    echo "reset"; return 0
  fi
  echo "fail-reset"; return 1
}

commit_and_push() { # $1=dir $2=branch $3=msg -> prints state word; 0 ok/nochange, 1 push-failed, 2 commit-failed
  local dir="$1" branch="$2" msg="$3"
  git -C "$dir" add -A >/dev/null 2>&1
  if git -C "$dir" diff --cached --quiet 2>/dev/null; then
    echo "nochange"; return 0
  fi
  if ! git -C "$dir" commit -q -m "$msg" >/dev/null 2>&1; then
    echo "fail-commit"; return 2
  fi
  if git -C "$dir" push -q origin "HEAD:$branch" >/dev/null 2>&1; then
    echo "pushed"; return 0
  fi
  echo "push-failed"; return 1
}

# mark_push_failed <ledger> — rewrites the ledger's LAST line to add
# "push":"failed", then leaves it to the caller to commit that edit. A
# permanent, factual record ("this row's push failed at the time") — never
# cleared retroactively once a later run's push succeeds.
mark_push_failed() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
if not lines or not lines[-1].strip():
    sys.exit(0)
try:
    r = json.loads(lines[-1])
except Exception:
    sys.exit(0)
r["push"] = "failed"
lines[-1] = json.dumps(r, sort_keys=True, separators=(",", ":")) + "\n"
with open(path, "w") as f:
    f.writelines(lines)
PY
}

# ---- mcphost-deploy resolution (never bare PATH luck under systemd) -------
#
# Caches the absolute path `command -v mcphost-deploy` resolves to (found
# via PATH once, at resolution time) so the unit's own restricted PATH never
# has to find it again — the recorded trap: ~/.local/bin shadows
# ~/.cargo/bin in systemd units on RedBaron. Falls back to `uv run` against
# the source repo when no installed binary is found on PATH at all (the
# tool has no global install yet, e.g. day-one on a fresh host).
resolve_mcphost_deploy() { # $1=cache_file $2=repo_dir -> prints "bin <path>" | "uvrun <repo>" | "none <repo>"
  local cache="$1" repo="${2:-$HOME/repos/mcphost-deploy}"
  if [ -n "${GRAND_LOOP_DEMAND_MD_BIN:-}" ] && [ -x "${GRAND_LOOP_DEMAND_MD_BIN:-}" ]; then
    printf 'bin %s\n' "$GRAND_LOOP_DEMAND_MD_BIN"; return 0
  fi
  if [ -s "$cache" ]; then
    local cached; cached="$(cat "$cache" 2>/dev/null)"
    if [ -n "$cached" ] && [ -x "$cached" ]; then
      printf 'bin %s\n' "$cached"; return 0
    fi
  fi
  local found; found="$(command -v mcphost-deploy 2>/dev/null || true)"
  if [ -n "$found" ]; then
    local abs; abs="$(readlink -f "$found" 2>/dev/null || echo "$found")"
    mkdir -p "$(dirname "$cache")" 2>/dev/null || true
    printf '%s' "$abs" > "$cache"
    printf 'bin %s\n' "$abs"; return 0
  fi
  if [ -d "$repo" ] && command -v uv >/dev/null 2>&1; then
    printf 'uvrun %s\n' "$repo"; return 0
  fi
  printf 'none %s\n' "$repo"; return 0
}

# ---- ledger row construction ----------------------------------------------

append_row() { # $1=ledger_path $2=json_line
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >> "$1"
}

already_ran_today() { # $1=ledger $2=date -> exit 0 if a row for that date exists
  [ -f "$1" ] || return 1
  grep -qF "\"date\":\"$2\"" "$1"
}

build_success_row() { # $1=measure_json $2=date $3=ts $4=exit_code $5=out_dir_rel $6=clone_state $7=real_tenants_prev
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import json, sys
measure_path, date, ts, exit_code, out_dir, clone_state, prev = sys.argv[1:8]
try:
    with open(measure_path) as f:
        m = json.load(f)
except Exception:
    m = {}
demand = m.get("demand")
row = {
    "date": date,
    "ts": ts,
    "paid_mrr_usd": m.get("paid_mrr_usd"),
    "paying_tenants": m.get("paying_tenants"),
    "real_tenants": m.get("real_tenants"),
    "real_wow_rate": m.get("real_wow_rate"),
    "gross_churn": m.get("gross_churn"),
    "validated": m.get("validated", False),
    "exit_code": int(exit_code),
    "out_dir": out_dir,
    "clone_state": clone_state,
    "demand": demand if isinstance(demand, dict) else "absent",
}
try:
    prev_i = int(prev)
except Exception:
    prev_i = 0
cur = row.get("real_tenants")
try:
    cur_i = int(cur)
except Exception:
    cur_i = None
row["real_tenants_prev"] = prev_i
row["real_tenants_changed"] = bool(cur_i is not None and cur_i != prev_i)
print(json.dumps(row, sort_keys=True, separators=(",", ":")))
PY
}

build_alarm_row() { # $1=date $2=ts $3=exit_code $4=stderr_tail_rel $5=out_dir_rel $6=clone_state
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, sys
date, ts, exit_code, stderr_tail, out_dir, clone_state = sys.argv[1:7]
row = {
    "date": date,
    "ts": ts,
    "alarm": True,
    "exit_code": int(exit_code),
    "stderr_tail": stderr_tail or None,
    "out_dir": out_dir or None,
    "clone_state": clone_state,
}
print(json.dumps(row, sort_keys=True, separators=(",", ":")))
PY
}

# last_success_row_field <ledger> <field> — most recent non-alarm row's
# field value, or empty when none exists yet (a genuinely first-ever run).
last_success_row_field() {
  local ledger="$1" field="$2"
  [ -f "$ledger" ] || { echo ""; return 0; }
  python3 - "$ledger" "$field" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        lines = [l for l in f if l.strip()]
except FileNotFoundError:
    lines = []
for line in reversed(lines):
    try:
        r = json.loads(line)
    except Exception:
        continue
    if r.get("alarm"):
        continue
    v = r.get(field)
    print(v if v is not None else "")
    break
else:
    print("")
PY
}

# consecutive_alarm_count <ledger> — trailing run of alarm:true rows.
consecutive_alarm_count() {
  local ledger="$1"
  [ -f "$ledger" ] || { echo 0; return 0; }
  python3 - "$ledger" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    lines = [l for l in f if l.strip()]
count = 0
for line in reversed(lines):
    try:
        r = json.loads(line)
    except Exception:
        break
    if r.get("alarm"):
        count += 1
    else:
        break
print(count)
PY
}
