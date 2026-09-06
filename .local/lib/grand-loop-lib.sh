#!/usr/bin/env bash
# grand-loop-lib.sh — function-only library for grand-loop-tick.sh (PRD-grand-loop-scaffold).
#
# Sourced by grand-loop-tick.sh and by tests/loop_*.test.sh directly, so the
# decision logic (family classification, ledger formatting, loop-note
# replace-same-day) is exercised without a fake `mcphost-deploy` on PATH or
# any network call — mirrors the vibeloop-measure-guards.sh pattern.
#
# NOT YET IMPLEMENTED (left for a follow-up tick, see PRD Status note):
#   - the `distribution` family (needs a multi-tick "listings live N days"
#     history the scaffold does not track yet)
#   - the P1 family-instruction table in grand-loop.env (instructions are
#     hardcoded in family_instruction() below for this pass)
#   - grand-loop-status, the systemd units, and the P1 daily section
set -uo pipefail

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() { # $1=message; writes to $GRAND_LOOP_LOG if set, else stderr only
  local msg="$1"
  echo "$(ts) $msg" >&2
  [ -n "${GRAND_LOOP_LOG:-}" ] && echo "$(ts) $msg" >> "$GRAND_LOOP_LOG" 2>/dev/null
}

# bl_phase <state.json> <phase> <status> — stamps one phase transition into
# state.json (created if absent). Keeps every phase's last stamp+status plus
# the current overall .phase, so a run's state.json shows PREFLIGHT, MEASURE,
# DIGEST, IDLE each with a stamp (AC1).
bl_phase() {
  local state_file="$1" phase="$2" status="${3:-}" now
  now="$(ts)"
  python3 - "$state_file" "$phase" "$status" "$now" <<'PY'
import json, os, sys
path, phase, status, now = sys.argv[1:5]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
d.setdefault("phases", {})
d["phase"] = phase
d["phases"][phase] = {"stamp": now, "status": status}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# count_reached_measure_today <ledger.md> <YYYY-MM-DD> — the budget cap counts
# ledger lines that reached MEASURE, never log lines, and never STOP/lock/cap
# skip lines that never got there (PRD "Budget" bullet).
count_reached_measure_today() {
  local ledger="$1" date="$2"
  [ -f "$ledger" ] || { echo 0; return 0; }
  awk -v d="$date" '$0 ~ "^"d && /reached_measure=1/ {c++} END{print c+0}' "$ledger"
}

# family_instruction <family> — the standing next-step text carried verbatim
# onto the loop note. P1 moves this table into grand-loop.env for Joe to
# edit; hardcoded here for this pass.
family_instruction() {
  case "$1" in
    instrument) echo "fix the instrument before trusting any number" ;;
    distribution) echo "draft a listings or channel PRD, not a feature" ;;
    activation) echo "investigate the activation funnel, not features" ;;
    monetization) echo "wire billing before building more product" ;;
    retention) echo "investigate churn causes before adding features" ;;
    discovery) echo "run synthorg candidates or draft a discovery PRD" ;;
    growing) echo "keep doing what's working" ;;
    flat) echo "look for the next lever; nothing moved" ;;
    *) echo "unclassified — investigate the loop itself" ;;
  esac
}

# classify_family <measure.json> <tenants.jsonl|""> <candidates.yaml|""> <healthz.json|""> <ledger.md>
# Prints "<family>|<one-clause reason>". Evaluated in the PRD's stated order;
# `distribution` is skipped this pass (see file header).
classify_family() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, os, re, sys

measure_path, tenants_path, candidates_path, healthz_path, ledger_path = sys.argv[1:6]

def load_json(p):
    if not p or not os.path.isfile(p):
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return None

m = load_json(measure_path) or {}

# instrument: preflight/healthz tenant accounting mismatch against this measure.
hz = load_json(healthz_path)
if hz:
    t_total = hz.get("tenants_total")
    t_probe = hz.get("tenants_probe")
    real_tenants = m.get("real_tenants")
    harness_excl = (m.get("exclusions") or {}).get("harness_prefix")
    if None not in (t_total, t_probe, real_tenants, harness_excl):
        if (t_total - t_probe) != (real_tenants + harness_excl):
            print("instrument|tenant accounting mismatch")
            sys.exit()

# distribution: NOT IMPLEMENTED — needs a tracked "listings live since" stamp
# across ticks that this scaffold slice does not persist yet.

new_real = m.get("new_real_tenants")
wow_rate = m.get("real_wow_rate")
if new_real is not None and wow_rate is not None and new_real >= 5 and wow_rate < 0.3:
    print(f"activation|new_real_tenants={new_real}, real_wow_rate={wow_rate} under 0.3")
    sys.exit()

# monetization: real tenants with wow:true >= 5, paying_tenants 0, billing live.
wow_count = None
if tenants_path and os.path.isfile(tenants_path):
    try:
        n = 0
        with open(tenants_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                if json.loads(line).get("wow") is True:
                    n += 1
        wow_count = n
    except Exception:
        wow_count = None
if wow_count is None and m.get("real_tenants") is not None and wow_rate is not None:
    wow_count = round(wow_rate * m.get("real_tenants"))
paying = m.get("paying_tenants")
billing_mode = m.get("billing_mode")
if wow_count is not None and wow_count >= 5 and paying == 0 and billing_mode == "live":
    print(f"monetization|{wow_count} wow tenants, 0 paying, billing_mode live")
    sys.exit()

# retention: gross churn at or above 0.1.
churn = m.get("gross_churn")
if churn is not None and churn >= 0.1:
    print(f"retention|gross_churn={churn}")
    sys.exit()

# discovery: candidates.yaml absent, or every non-comment row mentions "held".
if not candidates_path or not os.path.isfile(candidates_path):
    print("discovery|candidates.yaml absent")
    sys.exit()
rows = [l for l in open(candidates_path) if l.strip() and not l.strip().startswith("#")]
if rows and all("held" in l for l in rows):
    print("discovery|every candidate held")
    sys.exit()

# otherwise: growing if paid_mrr_usd rose since the last live (non-instrument,
# reached_measure=1) ledger line, else flat.
paid = m.get("paid_mrr_usd")
last_live = None
if ledger_path and os.path.isfile(ledger_path):
    with open(ledger_path) as f:
        for line in reversed(f.readlines()):
            if "reached_measure=1" not in line or "family=instrument" in line:
                continue
            mo = re.search(r"paid_mrr_usd=([0-9.]+)\b", line)
            if mo:
                last_live = float(mo.group(1))
                break
if paid is not None and last_live is not None and paid > last_live:
    print(f"growing|paid_mrr_usd {last_live} -> {paid}")
else:
    print("flat|paid_mrr_usd unchanged or no prior live measure")
PY
}

# write_ledger_line <ledger.md> <measure.json|""> <family> <reason> <reached_measure 0|1> [exclusions_summary]
# Appends the one required line per the DIGEST bullet: stamp, deployed
# version, billing_mode, real_tenants, new_real_tenants, real_wow_rate,
# paying_tenants, paid_mrr_usd, gross_churn, exclusions, family, reason.
write_ledger_line() {
  local ledger="$1" measure_json="$2" family="$3" reason="$4" reached="$5"
  local line
  line="$(python3 - "$measure_json" "$family" "$reason" "$reached" <<'PY'
import json, os, sys
measure_path, family, reason, reached = sys.argv[1:5]
m = {}
if measure_path and os.path.isfile(measure_path):
    try:
        with open(measure_path) as f:
            m = json.load(f)
    except Exception:
        m = {}
def g(k, default="-"):
    v = m.get(k)
    return default if v is None else v
excl = m.get("exclusions") or {}
excl_s = ",".join(f"{k}={v}" for k, v in excl.items()) or "-"
fields = [
    f"version={g('deployed_version')}",
    f"billing_mode={g('billing_mode')}",
    f"real_tenants={g('real_tenants')}",
    f"new_real_tenants={g('new_real_tenants')}",
    f"real_wow_rate={g('real_wow_rate')}",
    f"paying_tenants={g('paying_tenants')}",
    f"paid_mrr_usd={g('paid_mrr_usd')}",
    f"gross_churn={g('gross_churn')}",
    f"exclusions={excl_s}",
    f"family={family}",
    f'reason="{reason}"',
    f"reached_measure={reached}",
]
print(" ".join(fields))
PY
)"
  mkdir -p "$(dirname "$ledger")"
  echo "$(ts) $line" >> "$ledger"
}

# finish_instrument_line <ledger.md> <reason> <reached_measure 0|1> — the
# no-measure.json paths (STOP skip, preflight failure, measure failure /
# unvalidated exit 3) share this blank-fields shape.
finish_instrument_line() {
  local ledger="$1" reason="$2" reached="$3"
  write_ledger_line "$ledger" "" "instrument" "$reason" "$reached"
}

# finish_instrument <state.json> <ledger.md> <profile.md> <prd_dir> <out_dir|""> <reason> <reached_measure 0|1>
# One call for every instrument-family exit path (preflight failure, measure
# failure, exit-3 unvalidated, missing measure.json): writes the ledger line,
# folds the reason into the loop note's "next" text so AC4's "the loop note
# says how many labels are missing" holds without a reason field the fixed
# template doesn't otherwise carry, commits, and marks DIGEST/IDLE in
# state.json. Does not exit — the caller does that, right after.
finish_instrument() {
  local state="$1" ledger="$2" profile="$3" prd_dir="$4" out_dir="$5" reason="$6" reached="$7" today
  today="$(date -u +%F)"
  finish_instrument_line "$ledger" "$reason" "$reached"
  write_loop_note "$profile" "$today" instrument "" "$(family_instruction instrument) ($reason)"
  commit_prd_repo "$prd_dir" "$out_dir" "$ledger" "$state" "$profile"
  bl_phase "$state" IDLE ok
}

# skip_stop_line <ledger.md> — AC3's literal "skip: STOP" ledger line.
skip_stop_line() {
  local ledger="$1"
  write_ledger_line "$ledger" "" "n/a" "skip: STOP" 0
}

# write_loop_note <profile.md> <YYYY-MM-DD> <family> <measure.json|""> <instruction>
# Replaces the newest dated `## Loop notes` line rather than growing one line
# per tick (PRD DIGEST bullet + AC10): at most one line per day.
write_loop_note() {
  local profile="$1" date="$2" family="$3" measure_json="$4" instruction="$5"
  mkdir -p "$(dirname "$profile")"
  [ -f "$profile" ] || printf '# Project profile: grand-loop\n' > "$profile"
  python3 - "$profile" "$date" "$family" "$measure_json" "$instruction" <<'PY'
import json, os, re, sys

path, date, family, measure_path, instruction = sys.argv[1:6]

m = {}
if measure_path and os.path.isfile(measure_path):
    try:
        with open(measure_path) as f:
            m = json.load(f)
    except Exception:
        m = {}

def g(k, default="-"):
    v = m.get(k)
    return default if v is None else v

new_line = (
    f"- {date} (grand-loop): family={family}; "
    f"paid_mrr_usd={g('paid_mrr_usd')} ({g('billing_mode')}); "
    f"real_tenants={g('real_tenants')}; wow={g('real_wow_rate')}; "
    f"paying={g('paying_tenants')}; next: {instruction}"
)

with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()

header = "## Loop notes"
try:
    hi = next(i for i, l in enumerate(lines) if l.strip() == header)
except StopIteration:
    # No section yet: append one, with a blank line before it if the file is non-empty.
    if lines and lines[-1].strip():
        lines.append("")
    lines.append(header)
    lines.append("")
    lines.append(new_line)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    sys.exit()

# Section body runs from hi+1 until the next "## " header or EOF.
end = len(lines)
for j in range(hi + 1, len(lines)):
    if lines[j].startswith("## "):
        end = j
        break

today_prefix = f"- {date} "
replaced = False
for j in range(hi + 1, end):
    if lines[j].startswith(today_prefix):
        lines[j] = new_line
        replaced = True
        break

if not replaced:
    # Insert right after the header (skip a single blank line if present).
    insert_at = hi + 1
    if insert_at < end and lines[insert_at].strip() == "":
        insert_at += 1
    lines.insert(insert_at, new_line)

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY
}

# commit_prd_repo <prd_dir> <out_dir|""> <ledger.md> <state.json> <profile.md>
# "commits the ledger, state, measure directory, and profile line to the PRDs
# repo with git pull --rebase first and a push; a push failure is a warning
# in the ledger line, never a failed tick." Best-effort throughout — this is
# never the reason a tick fails.
commit_prd_repo() {
  local prd_dir="$1" out_dir="$2" ledger="$3" state="$4" profile="$5"
  [ -d "$prd_dir/.git" ] || return 0
  git -C "$prd_dir" pull -q --rebase >/dev/null 2>&1
  local paths=("$ledger" "$state" "$profile")
  [ -n "$out_dir" ] && [ -d "$out_dir" ] && paths+=("$out_dir")
  git -C "$prd_dir" add -- "${paths[@]}" >/dev/null 2>&1
  if ! git -C "$prd_dir" diff --cached --quiet -- "${paths[@]}" 2>/dev/null; then
    git -C "$prd_dir" commit -q -m "grand-loop: tick $(ts)" -- "${paths[@]}" >/dev/null 2>&1
    if ! git -C "$prd_dir" push -q >/dev/null 2>&1; then
      log "warning: grand-loop push failed (non-fatal)"
    fi
  fi
}
