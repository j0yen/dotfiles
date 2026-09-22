#!/usr/bin/env bash
# grand-loop-lib.sh — function-only library for grand-loop-tick.sh (PRD-grand-loop-scaffold).
#
# Sourced by grand-loop-tick.sh and by tests/loop_*.test.sh directly, so the
# decision logic (family classification, ledger formatting, loop-note
# replace-same-day) is exercised without a fake `mcphost-deploy` on PATH or
# any network call — mirrors the vibeloop-measure-guards.sh pattern.
#
# NOT YET IMPLEMENTED (left for a follow-up tick, see PRD Status note):
#   - the P1 family-instruction table in grand-loop.env (instructions are
#     hardcoded in family_instruction() below for this pass)
#   - `grand-loop-status --json`
# The P1 daily section (AC13) IS implemented below (grand_loop_open_needs,
# daily_page_target, write_daily_section, update_daily_section).
#
# `distribution` (AC5, added iter-3): PREFLIGHT has no single-tick way to know
# "listings live for 14 days" — the artifact check only says live/not-live
# *this* tick. update_listings_state() persists the first-seen-live stamp in
# state.json (`listings_live_since`); classify_family() below reads it back
# plus scans the ledger's own history for the 14-day growth window, so no
# separate history file is needed.
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

# extract_listings_json <preflight_json> <out_listings_json> — pulls the
# "listings" object out of a `mcphost-deploy probe --json` payload (PREFLIGHT
# bullet: "the billing and listings artifact checks when present"). Writes
# "{}" to <out> when the key is absent or the payload is unparseable, so
# update_listings_state() below can tell "not live" from "no information".
extract_listings_json() {
  local preflight_json="$1" out="$2"
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
listings = d.get('listings')
json.dump(listings if isinstance(listings, dict) else {}, open(sys.argv[2], 'w'))
" "$preflight_json" "$out" 2>/dev/null || echo '{}' > "$out"
}

# update_listings_state <state.json> <listings_json> — tracks the first
# stamp PREFLIGHT observed `listings.live: true` in state.json's
# `listings_live_since` field, so classify_family()'s `distribution` check
# (AC5) can measure "listings live for N days" across ticks without a
# separate history file. `listings.live: false` resets the stamp (the
# listing came down, the 14-day clock restarts); an absent/unparseable
# listings object (the artifact check did not run this tick, or ran before
# any listings existed) leaves the existing stamp untouched — "no
# information" is not "not live".
update_listings_state() {
  local state="$1" listings_json="$2"
  python3 - "$state" "$listings_json" <<'PY'
import json, os, sys
from datetime import datetime, timezone

state_path, listings_path = sys.argv[1:3]
try:
    with open(state_path) as f:
        d = json.load(f)
except Exception:
    d = {}

listings = {}
if listings_path and os.path.isfile(listings_path):
    try:
        with open(listings_path) as f:
            listings = json.load(f) or {}
    except Exception:
        listings = {}

if "live" in listings:
    if listings.get("live") is True:
        if not d.get("listings_live_since"):
            d["listings_live_since"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        d["listings_live_since"] = None

tmp = state_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.replace(tmp, state_path)
PY
}

# listings_live_days <state.json> — days since listings_live_since, or ""
# when unset. Used by grand-loop-status; classify_family() re-derives this
# itself rather than shelling out, to keep the whole decision in one process.
listings_live_days() {
  local state="$1"
  [ -f "$state" ] || { echo ""; return 0; }
  python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
since = d.get('listings_live_since')
if not since:
    print('')
    sys.exit()
try:
    dt = datetime.strptime(since, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
except Exception:
    print('')
    sys.exit()
print((datetime.now(timezone.utc) - dt).days)
" "$state"
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

# classify_family <measure.json> <tenants.jsonl|""> <candidates.yaml|""> <healthz.json|""> <ledger.md> [state.json|""]
# Prints "<family>|<one-clause reason>". Evaluated in the PRD's stated order.
# The 6th arg (state.json) is optional so old call sites keep working; without
# it, `distribution` is simply never selected (no listings_live_since to read).
classify_family() {
  python3 - "$1" "$2" "$3" "$4" "$5" "${6:-}" <<'PY'
import json, os, re, sys
from datetime import datetime, timezone

measure_path, tenants_path, candidates_path, healthz_path, ledger_path = sys.argv[1:6]
state_path = sys.argv[6] if len(sys.argv) > 6 else ""

def load_json(p):
    if not p or not os.path.isfile(p):
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return None

m = load_json(measure_path) or {}
new_real = m.get("new_real_tenants")
wow_rate = m.get("real_wow_rate")

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

# distribution (AC5): listings live (state.json's PREFLIGHT-tracked stamp)
# for >= 14 days, and no real growth anywhere in the ledger's own 14-day
# window (every reached-MEASURE, non-instrument line's new_real_tenants is
# 0/absent) AND this tick's own measure agrees (new_real_tenants == 0).
state = load_json(state_path) or {}
listings_since = state.get("listings_live_since")
if listings_since and new_real is not None and new_real == 0:
    try:
        since_dt = datetime.strptime(listings_since, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        live_days = (datetime.now(timezone.utc) - since_dt).days
    except Exception:
        live_days = 0
    if live_days >= 14:
        cutoff = datetime.now(timezone.utc).timestamp() - 14 * 86400
        window_clean = True
        if ledger_path and os.path.isfile(ledger_path):
            with open(ledger_path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    mo_ts = re.match(r"^(\S+)\s", line)
                    if not mo_ts:
                        continue
                    try:
                        ts = datetime.strptime(mo_ts.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
                    except Exception:
                        continue
                    if ts < cutoff:
                        continue
                    if "reached_measure=1" not in line or "family=instrument" in line:
                        continue
                    mo = re.search(r"new_real_tenants=(\S+)", line)
                    if mo and mo.group(1) not in ("0", "-", "None", "null"):
                        window_clean = False
                        break
        if window_clean:
            print(f"distribution|listings live {live_days} days, new_real_tenants 0 over the last 14 days")
            sys.exit()

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

# write_ledger_line <ledger.md> <measure.json|""> <family> <reason> <reached_measure 0|1> [stderr_tail_escaped]
# Appends the one required line per the DIGEST bullet: stamp, deployed
# version, billing_mode, real_tenants, new_real_tenants, real_wow_rate,
# paying_tenants, paid_mrr_usd, gross_churn, exclusions, family, reason.
# The optional 6th arg (PRD-grand-loop-liveness-contract Requirement 4) is
# the failing command's stderr tail, already newline-escaped by
# bl_escape_newlines — folded in as a trailing `stderr_tail="..."` field
# when non-empty.
write_ledger_line() {
  local ledger="$1" measure_json="$2" family="$3" reason="$4" reached="$5" stderr_tail="${6:-}"
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
  if [ -n "$stderr_tail" ]; then
    line="$line stderr_tail=\"$stderr_tail\""
  fi
  mkdir -p "$(dirname "$ledger")"
  echo "$(ts) $line" >> "$ledger"
}

# finish_instrument_line <ledger.md> <reason> <reached_measure 0|1> [stderr_tail_escaped]
# the no-measure.json paths (STOP skip, preflight failure, measure failure /
# unvalidated exit 3) share this blank-fields shape.
finish_instrument_line() {
  local ledger="$1" reason="$2" reached="$3" stderr_tail="${4:-}"
  write_ledger_line "$ledger" "" "instrument" "$reason" "$reached" "$stderr_tail"
}

# finish_instrument <state.json> <ledger.md> <profile.md> <prd_dir> <out_dir|""> <reason> <reached_measure 0|1> [stderr_file]
# One call for every instrument-family exit path (preflight failure, measure
# failure, exit-3 unvalidated, missing measure.json): writes the ledger line,
# folds the reason into the loop note's "next" text so AC4's "the loop note
# says how many labels are missing" holds without a reason field the fixed
# template doesn't otherwise carry, commits, and marks DIGEST/IDLE in
# state.json. Does not exit — the caller does that, right after.
#
# The optional 8th arg (PRD-grand-loop-liveness-contract Requirement 4) is a
# path to the failing command's captured stderr: when it exists and is
# non-empty, its last 20 lines are written verbatim to
# <loop_dir>/state/last-failure.txt and (newline-escaped) into the ledger
# row's stderr_tail= field, so the on-call reader of ledger.md sees why
# PREFLIGHT/MEASURE failed without opening a log.
finish_instrument() {
  local state="$1" ledger="$2" profile="$3" prd_dir="$4" out_dir="$5" reason="$6" reached="$7" stderr_file="${8:-}"
  local today loop_dir daily_target stderr_tail="" stderr_tail_escaped=""
  today="$(date -u +%F)"
  loop_dir="$(dirname "$ledger")"
  if [ -n "$stderr_file" ] && [ -s "$stderr_file" ]; then
    stderr_tail="$(tail -n 20 "$stderr_file")"
    mkdir -p "$loop_dir/state"
    printf '%s\n' "$stderr_tail" > "$loop_dir/state/last-failure.txt"
    stderr_tail_escaped="$(bl_escape_newlines "$stderr_tail")"
  fi
  finish_instrument_line "$ledger" "$reason" "$reached" "$stderr_tail_escaped"
  write_loop_note "$profile" "$today" instrument "" "$(family_instruction instrument) ($reason)"
  daily_target="$(update_daily_section "$prd_dir" "$loop_dir" "$ledger" "$today")"
  commit_prd_repo "$prd_dir" "$out_dir" "$ledger" "$state" "$profile" "$daily_target"
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

# ---- P1 daily section (PRD-grand-loop-scaffold, AC13) --------------------

# grand_loop_open_needs <ledger.md> <date> <publish_ok_path> [loop_dir] —
# one open-need line per condition that applies today (labels missing,
# billing off, PUBLISH-OK absent, instrument stale — Requirement 8/AC10),
# or "none" when none do. Prints one need per line. The optional 4th arg
# (loop_dir) is where state.json and state/last-success.json live; when
# given and bl_liveness reports anything but ok, a
# "instrument stale since <ts>" need is added — <ts> is the PREFLIGHT
# stamp for stuck, the last success's own ts for stale, or the literal
# "never" when no success row exists yet (bl_liveness_since).
grand_loop_open_needs() {
  local ledger="$1" date="$2" publish_ok="$3" loop_dir="${4:-}"
  local needs=() labels_reason labels_detail last_today bm verdict since

  labels_reason="$(awk -v d="$date" '$0 ~ "^"d && /family=instrument/' "$ledger" 2>/dev/null \
    | grep -o 'reason="[^"]*label[^"]*"' | tail -1)"
  if [ -n "$labels_reason" ]; then
    labels_detail="$(printf '%s' "$labels_reason" | sed -e 's/^reason="//' -e 's/"$//')"
    needs+=("labels missing: $labels_detail")
  fi

  last_today="$(awk -v d="$date" '$0 ~ "^"d && /reached_measure=1/ {line=$0} END{print line}' "$ledger" 2>/dev/null)"
  if [ -n "$last_today" ]; then
    bm="$(ledger_field "$last_today" billing_mode)"
    [ -n "$bm" ] && [ "$bm" != "live" ] && [ "$bm" != "-" ] && needs+=("billing off (billing_mode=$bm)")
  fi

  [ -f "$publish_ok" ] || needs+=("PUBLISH-OK absent")

  if [ -n "$loop_dir" ]; then
    verdict="$(bl_liveness "$loop_dir/state.json" "$loop_dir/state/last-success.json" 2>/dev/null)"
    if [ "$verdict" != "ok" ]; then
      since="$(bl_liveness_since "$loop_dir/state.json" "$loop_dir/state/last-success.json")"
      needs+=("instrument stale since $since")
    fi
  fi

  if [ "${#needs[@]}" -eq 0 ]; then
    echo "none"
  else
    printf '%s\n' "${needs[@]}"
  fi
}

# daily_page_target <prd_dir> <loop_dir> <date> — the file the P1 daily
# section is written into: today's vibeloop daily-digest page
# (`vibeloop/digest/<date>.md`, the "daily page" visions/buildloop-operations.md
# describes) when vibeloop-daily-digest already wrote one for today, else the
# standalone `<loop_dir>/daily/<date>.md`, created with a one-line header on
# first use so write_daily_section always has a file to edit.
daily_page_target() {
  local prd_dir="$1" loop_dir="$2" date="$3" vibeloop_page standalone
  vibeloop_page="$prd_dir/vibeloop/digest/$date.md"
  if [ -f "$vibeloop_page" ]; then
    echo "$vibeloop_page"
    return 0
  fi
  standalone="$loop_dir/daily/$date.md"
  mkdir -p "$(dirname "$standalone")"
  [ -f "$standalone" ] || printf '# grand-loop daily — %s\n' "$date" > "$standalone"
  echo "$standalone"
}

# write_daily_section <target.md> <ledger.md> <date> <open_needs (one per line)>
# Replaces the whole `## grand-loop` section in <target.md> with today's
# ledger lines and the open needs, or appends one if the header isn't there
# yet — so a day with several ticks (up to the daily cap) ends with exactly
# one such section, not one per tick (AC13: "appended once").
write_daily_section() {
  local target="$1" ledger="$2" date="$3" open_needs="$4" day_lines
  mkdir -p "$(dirname "$target")"
  [ -f "$target" ] || printf '# grand-loop daily — %s\n' "$date" > "$target"
  day_lines="$(awk -v d="$date" '$0 ~ "^"d' "$ledger" 2>/dev/null)"
  DAILY_TARGET="$target" DAILY_DATE="$date" DAILY_OPEN_NEEDS="$open_needs" DAILY_LEDGER_LINES="$day_lines" \
    python3 <<'PY'
import os

target = os.environ["DAILY_TARGET"]
date = os.environ["DAILY_DATE"]
open_needs = os.environ.get("DAILY_OPEN_NEEDS", "") or "none"
ledger_lines = os.environ.get("DAILY_LEDGER_LINES", "")

section = ["## grand-loop", "", f"Day's ledger lines ({date}):", ""]
day_rows = [l for l in ledger_lines.splitlines() if l.strip()]
if day_rows:
    section += [f"- {l}" for l in day_rows]
else:
    section.append("- (no ticks yet today)")
section += ["", "Open needs:", ""]
needs_rows = [n for n in open_needs.splitlines() if n.strip()] or ["none"]
section += [f"- {n}" for n in needs_rows]

with open(target, encoding="utf-8") as f:
    lines = f.read().splitlines()

header = "## grand-loop"
try:
    hi = next(i for i, l in enumerate(lines) if l.strip() == header)
except StopIteration:
    if lines and lines[-1].strip():
        lines.append("")
    lines.extend(section)
    with open(target, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    raise SystemExit

end = len(lines)
for j in range(hi + 1, len(lines)):
    if lines[j].startswith("## "):
        end = j
        break
lines[hi:end] = section
with open(target, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY
}

# update_daily_section <prd_dir> <loop_dir> <ledger.md> <date> — computes the
# target file and open needs and writes the section (AC13); echoes the target
# path so the caller (grand-loop-tick.sh, finish_instrument) can fold it into
# the same commit_prd_repo call as the ledger/state/profile.
update_daily_section() {
  local prd_dir="$1" loop_dir="$2" ledger="$3" date="$4" target open_needs
  target="$(daily_page_target "$prd_dir" "$loop_dir" "$date")"
  open_needs="$(grand_loop_open_needs "$ledger" "$date" "$loop_dir/PUBLISH-OK" "$loop_dir")"
  write_daily_section "$target" "$ledger" "$date" "$open_needs"
  echo "$target"
}

# commit_prd_repo <prd_dir> <out_dir|""> <ledger.md> <state.json> <profile.md> [daily_page|""]
# "commits the ledger, state, measure directory, and profile line to the PRDs
# repo with git pull --rebase first and a push; a push failure is a warning
# in the ledger line, never a failed tick." Best-effort throughout — this is
# never the reason a tick fails. The optional 6th arg is the P1 daily-section
# target (AC13) — the vibeloop digest page for today, or grand-loop's own
# standalone daily/<date>.md — folded into the same commit when it changed.
commit_prd_repo() {
  local prd_dir="$1" out_dir="$2" ledger="$3" state="$4" profile="$5" daily="${6:-}"
  [ -d "$prd_dir/.git" ] || return 0
  git -C "$prd_dir" pull -q --rebase >/dev/null 2>&1
  local paths=("$ledger" "$state" "$profile")
  [ -n "$out_dir" ] && [ -d "$out_dir" ] && paths+=("$out_dir")
  [ -n "$daily" ] && [ -f "$daily" ] && paths+=("$daily")
  git -C "$prd_dir" add -- "${paths[@]}" >/dev/null 2>&1
  if ! git -C "$prd_dir" diff --cached --quiet -- "${paths[@]}" 2>/dev/null; then
    git -C "$prd_dir" commit -q -m "grand-loop: tick $(ts)" -- "${paths[@]}" >/dev/null 2>&1
    if ! git -C "$prd_dir" push -q >/dev/null 2>&1; then
      log "warning: grand-loop push failed (non-fatal)"
    fi
  fi
}

# ---- grand-loop-status helpers (PRD-grand-loop-scaffold, AC12) ------------

# last_ledger_line <ledger.md> — the most recent ledger line, or "" if the
# ledger doesn't exist yet (a status run before the first tick).
last_ledger_line() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  tail -n1 "$ledger" 2>/dev/null
}

# last_live_ledger_line <ledger.md> — the most recent line that reached
# MEASURE and isn't itself an instrument failure, i.e. the same "last live
# measure" a fresh classify_family call would compare paid_mrr_usd against.
# Prints "" when no such line exists yet.
last_live_ledger_line() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  awk '/reached_measure=1/ && !/family=instrument/ {line=$0} END{if (line) print line}' "$ledger"
}

# newest_loop_note <profile.md> — the last (most recent) line under the
# "## Loop notes" header, or "" when the section is absent or empty.
newest_loop_note() {
  local profile="$1"
  [ -f "$profile" ] || return 0
  awk '
    /^## Loop notes/ { insection=1; next }
    /^## / { insection=0 }
    insection && /^- / { line=$0 }
    END { if (line) print line }
  ' "$profile"
}

# ledger_field <ledger line> <field name> — pulls one "key=value" token out
# of a ledger line written by write_ledger_line (space-separated fields;
# the "reason" field's value is quoted and double-word-safe, everything
# else is a single token so a plain awk/split is enough).
ledger_field() {
  local line="$1" field="$2"
  printf '%s\n' "$line" | grep -o "${field}=[^ ]*" | head -1 | cut -d= -f2-
}

# ---- liveness (PRD-grand-loop-liveness-contract) --------------------------
#
# The grand loop is the only reader of paid_mrr_usd; nothing else notices
# when it stops writing rows. bl_liveness gives every reader (bl_liveness
# itself, grand-loop-banner.sh, grand-loop-status) one answer, computed the
# same way: ok | stale | never | stuck.

# bl_liveness <state.json> <last-success.json> — prints ok|stale|never|stuck
# and exits 0 for ok, 2 otherwise. A PREFLIGHT still `running` in state.json
# older than GRAND_LOOP_PHASE_MAX_WALL (default 30m) is "stuck" regardless
# of how fresh the last success row is — a hung tick is its own failure
# mode. Otherwise: no last-success.json (or one with no `ts`) is "never"
# (migration note: existing installs read this way until their first
# success under this contract); older than GRAND_LOOP_MAX_AGE (default 26h)
# is "stale"; anything else is "ok".
bl_liveness() {
  local state="$1" success="$2"
  local max_age="${GRAND_LOOP_MAX_AGE:-26h}"
  local phase_wall="${GRAND_LOOP_PHASE_MAX_WALL:-30m}"
  python3 - "$state" "$success" "$max_age" "$phase_wall" <<'PY'
import json, os, re, sys
from datetime import datetime, timezone

state_path, success_path, max_age_s, phase_wall_s = sys.argv[1:5]

def parse_duration(v):
    m = re.match(r'^(\d+)([smhd]?)$', v.strip())
    if not m:
        return 0
    n, unit = int(m.group(1)), m.group(2) or 's'
    return n * {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}[unit]

def parse_ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

def load(p):
    if not p or not os.path.isfile(p):
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return None

max_age = parse_duration(max_age_s)
phase_wall = parse_duration(phase_wall_s)
now = datetime.now(timezone.utc)

state = load(state_path) or {}
preflight = (state.get("phases") or {}).get("PREFLIGHT") or {}
if state.get("phase") == "PREFLIGHT" and preflight.get("status") == "running" and preflight.get("stamp"):
    try:
        age = (now - parse_ts(preflight["stamp"])).total_seconds()
    except Exception:
        age = None
    if age is not None and age > phase_wall:
        print("stuck")
        sys.exit(2)

success = load(success_path)
if not success or not success.get("ts"):
    print("never")
    sys.exit(2)

try:
    age = (now - parse_ts(success["ts"])).total_seconds()
except Exception:
    print("never")
    sys.exit(2)

if age > max_age:
    print("stale")
    sys.exit(2)

print("ok")
sys.exit(0)
PY
}

# bl_liveness_since <state.json> <last-success.json> — the timestamp behind
# whatever bl_liveness just decided: the PREFLIGHT stamp for stuck, the last
# success's own ts for ok/stale, or the literal "never" when no success row
# exists yet. Used by the daily-note "Open needs" line (AC10) so it names a
# concrete moment, not just the verdict word.
bl_liveness_since() {
  local state="$1" success="$2" verdict
  verdict="$(bl_liveness "$state" "$success" 2>/dev/null)"
  case "$verdict" in
    stuck)
      python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print((d.get('phases') or {}).get('PREFLIGHT', {}).get('stamp', 'unknown'))
" "$state" 2>/dev/null || echo unknown
      ;;
    ok|stale)
      python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(d.get('ts', 'unknown'))
" "$success" 2>/dev/null || echo unknown
      ;;
    *)
      echo never
      ;;
  esac
}

# bl_age_human <ISO ts> — best-effort "N min" / "N h" age string for banner
# text; "?" when the timestamp is missing or unparseable.
bl_age_human() {
  local iso="$1"
  python3 -c "
import sys
from datetime import datetime, timezone
try:
    dt = datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
except Exception:
    print('?')
    sys.exit()
secs = (datetime.now(timezone.utc) - dt).total_seconds()
if secs < 3600:
    print(f'{int(secs // 60)} min')
else:
    print(f'{secs / 3600:.0f} h')
" "$iso"
}

# bl_success_stamp <last-success.json> <phase> <version> — Requirement 2:
# stamps a fresh success row (ts, phase, version) so bl_liveness has
# something to measure age against. Called once DIGEST reaches ok.
bl_success_stamp() {
  local success_file="$1" phase="$2" version="$3"
  mkdir -p "$(dirname "$success_file")"
  python3 - "$success_file" "$phase" "$version" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path, phase, version = sys.argv[1:4]
d = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "phase": phase,
    "version": version,
}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# bl_escape_newlines <raw text> -> stdout: backslashes/quotes escaped and
# real newlines replaced with the two-char sequence \n, so the result is
# safe to embed as one ledger field's quoted value (Requirement 4). Takes
# the text as an argument, not stdin: `python3 -` already reads the script
# body itself from stdin via the heredoc below, so stdin isn't free to
# carry the caller's text too.
bl_escape_newlines() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1]
s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
sys.stdout.write(s)
PY
}

# bl_deliver_stale_alert <loop_dir> <verdict> <detail> — Requirement 6
# (AC8): delivers one alert per UTC day through the build loop's existing
# alert-deliver.sh, PATH-resolved and best-effort like commit_prd_repo's
# push — grand-loop never depends on it being installed. The dedupe marker
# is written whether or not alert-deliver.sh is even present, so a missing
# binary can't turn into a retry-every-SessionStart loop either.
bl_deliver_stale_alert() {
  local loop_dir="$1" verdict="$2" detail="$3" marker today
  today="$(date -u +%F)"
  marker="$loop_dir/state/last-alert-date.txt"
  mkdir -p "$(dirname "$marker")"
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$today" ]; then
    return 0
  fi
  if command -v alert-deliver.sh >/dev/null 2>&1; then
    alert-deliver.sh "grand-loop: $verdict — $detail" >/dev/null 2>&1 || true
  fi
  printf '%s' "$today" > "$marker"
}
