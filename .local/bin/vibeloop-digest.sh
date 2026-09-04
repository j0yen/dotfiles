#!/usr/bin/env bash
# vibeloop-digest.sh — one templated (no model) page a day for an operator following the
# mcphost-buildloop from days away: what shipped, what cycles did, what was spent, hub
# health, measurement results, and what needs a human, first. See PRD-vibeloop-daily-digest.
#
#   vibeloop-digest.sh [date] [--no-commit]
#     date         UTC calendar date, YYYY-MM-DD (default: today, UTC — ledger timestamps
#                  are UTC Z, so the digest day is a UTC day)
#     --no-commit  write the file but do not git add/commit/push (used by
#                  `vibeloop-ctl digest --today`); NATS/ntfy still fire
#
# Reads (missing ones render "not available" in the digest, never abort it):
#   vibeloop/ledger.md, vibeloop/measure-ledger.md, vibeloop/cost-ledger.jsonl, vibeloop/STOP,
#   vibeloop/MEASURE-STOP, build-queue/*.md, built-prds/*.md, evidence/mcp-host/measure/LATEST,
#   evidence/mcp-host/baseline.json, ~/brain/journal/vibeloop-auto.log (RedBaron-only),
#   ~/brain/journal/vibeloop-measure.log (RedBaron-only), the hub /healthz.
# Writes: vibeloop/digest/<date>.md (and, on a Monday date, vibeloop/digest/<date>-weekly.md).
#
# Env: DREAM_PRD_DIR (default ~/Documents/PRDs, same var vibeloop-ctl uses), NATS_URL,
#   NTFY_TOPIC / MAX_COST_USD_PER_DAY / MAX_COST_USD_PER_WEEK (sourced from
#   ~/.config/vibeloop/limits if present — same file the loop itself reads).
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
PRD_DIR="${DREAM_PRD_DIR:-$HOME/Documents/PRDs}"
LOOP="$PRD_DIR/vibeloop"
DIGEST_DIR="$LOOP/digest"
LOG_AUTO="$HOME/brain/journal/vibeloop-auto.log"
LOG_MEASURE="$HOME/brain/journal/vibeloop-measure.log"
HUB_HEALTHZ_URL="${HUB_HEALTHZ_URL:-https://178-105-64-66.sslip.io/healthz}"
NATS_URL="${NATS_URL:-nats://127.0.0.1:4222}"
LIMITS="$HOME/.config/vibeloop/limits"
# shellcheck disable=SC1090
[ -f "$LIMITS" ] && . "$LIMITS"   # may set MAX_COST_USD_PER_DAY, MAX_COST_USD_PER_WEEK, NTFY_TOPIC

commit=1
date_arg=""
for a in "$@"; do
  case "$a" in
    --no-commit) commit=0 ;;
    *) date_arg="$a" ;;
  esac
done
DATE="${date_arg:-$(date -u +%F)}"

mkdir -p "$DIGEST_DIR"
OUT="$DIGEST_DIR/$DATE.md"

# Best-effort hub health (5s timeout; digest must still generate if the hub is unreachable).
HEALTHZ_JSON="$(curl -s --max-time 5 "$HUB_HEALTHZ_URL" 2>/dev/null || true)"

DIGEST_MD="$(
  PRD_DIR="$PRD_DIR" DATE="$DATE" HEALTHZ_JSON="$HEALTHZ_JSON" \
  LOG_AUTO="$LOG_AUTO" LOG_MEASURE="$LOG_MEASURE" \
  MAX_COST_USD_PER_DAY="${MAX_COST_USD_PER_DAY:-}" MAX_COST_USD_PER_WEEK="${MAX_COST_USD_PER_WEEK:-}" \
  python3 - <<'PY'
import collections, datetime, json, os, re, sys, time, calendar

PRD_DIR = os.environ["PRD_DIR"]
DATE = os.environ["DATE"]
LOOP = os.path.join(PRD_DIR, "vibeloop")

def relpath(p):
    # Repo-relative when the source is under PRD_DIR (the common case); ~-relative for
    # RedBaron-only journal logs that live outside the repo (~/brain/journal/*.log) rather
    # than the ugly ../../home/... os.path.relpath would otherwise produce.
    ap = os.path.abspath(p)
    prd = os.path.abspath(PRD_DIR)
    if ap == prd or ap.startswith(prd + os.sep):
        return os.path.relpath(ap, prd)
    home = os.path.expanduser("~")
    if ap.startswith(home + os.sep):
        return "~" + ap[len(home):]
    return ap

def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return None

def lines_for_date(path, date):
    lines = read_lines(path)
    if lines is None:
        return None
    return [l for l in lines if l[:10] == date]

def na(path, why="not found"):
    return f"not available ({relpath(path)}: {why})"

out = []
def sec(title):
    out.append(f"\n## {title}\n")

# ---------------------------------------------------------------- ledger.md (cycles) ----
ledger_path = os.path.join(LOOP, "ledger.md")
ledger_all = read_lines(ledger_path)
ledger_today = lines_for_date(ledger_path, DATE) if ledger_all is not None else None

def field(line, name, stop):
    m = re.search(re.escape(name) + r"=\[(.*?)\]\s*" + stop, line)
    return m.group(1) if m else None

def verdict_of(line):
    # Free-text notes sometimes contain a literal "verdict=..." of their own (e.g. quoting a
    # gate's "verdict=pass);" from CI output), and not every line has a trailing note="..."
    # field to anchor on. The real field's value is always an uppercase token (IDLE,
    # PROGRESS, PLATEAU, ABORTED, WATCHDOG, ...); quoted free text is never all-caps like
    # that, so restrict the match to that shape.
    m = re.search(r"verdict=([A-Z][A-Z_]*)\b", line)
    return m.group(1) if m else "?"

# --------------------------------------------------------------------- build-queue/* ----
def prd_frontmatter(path):
    fm = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for l in f:
                m = re.match(r"^- (\w[\w /]*): (.*)$", l.rstrip("\n"))
                if m:
                    fm[m.group(1)] = m.group(2)
    except FileNotFoundError:
        pass
    return fm

def glob_md(dirname):
    d = os.path.join(PRD_DIR, dirname)
    try:
        return sorted(f for f in os.listdir(d) if f.startswith("PRD-") and f.endswith(".md"))
    except FileNotFoundError:
        return []

# ============================================================ Needs you ================
needs_you_lines = []

stop_path = os.path.join(LOOP, "STOP")
if os.path.isfile(stop_path):
    with open(stop_path, encoding="utf-8", errors="replace") as f:
        first = f.readline().strip()
    needs_you_lines.append(f"- **STOP present**: {first}  ({relpath(stop_path)})")
else:
    needs_you_lines.append(f"- STOP: absent  ({relpath(stop_path)})")

mstop_path = os.path.join(LOOP, "MEASURE-STOP")
if os.path.isfile(mstop_path):
    with open(mstop_path, encoding="utf-8", errors="replace") as f:
        first = f.readline().strip()
    needs_you_lines.append(f"- **MEASURE-STOP present**: {first}  ({relpath(mstop_path)})")
else:
    needs_you_lines.append(f"- MEASURE-STOP: absent  ({relpath(mstop_path)})")

# budget ladder state (rolling 24h/7d spend vs ceilings in ~/.config/vibeloop/limits)
cl_path = os.path.join(LOOP, "cost-ledger.jsonl")
def cost_window(path, win_secs):
    now = time.time()
    tot = 0.0
    lines = read_lines(path)
    if lines is None:
        return None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        try:
            t = calendar.timegm(time.strptime(r.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ"))
        except Exception:
            continue
        if now - t <= win_secs:
            tot += float(r.get("usd") or 0)
    return tot

max_day = os.environ.get("MAX_COST_USD_PER_DAY") or ""
max_week = os.environ.get("MAX_COST_USD_PER_WEEK") or ""
spend_24h = cost_window(cl_path, 86400)
spend_7d = cost_window(cl_path, 7 * 86400)

def ladder_line(spend, ceiling_s, label):
    if spend is None:
        return f"- budget ladder ({label}): {na(cl_path)}"
    try:
        ceiling = float(ceiling_s)
    except (TypeError, ValueError):
        return f"- budget ladder ({label}): spend ${spend:.2f}, ceiling not set  ({relpath(cl_path)})"
    if ceiling <= 0:
        return f"- budget ladder ({label}): spend ${spend:.2f}, ceiling not set  ({relpath(cl_path)})"
    pct = 100.0 * spend / ceiling
    flag = " — **near ceiling**" if pct >= 90 else ""
    return f"- budget ladder ({label}): ${spend:.2f} of ${ceiling:.2f} ({pct:.0f}%){flag}  ({relpath(cl_path)})"

needs_you_lines.append(ladder_line(spend_24h, max_day, "24h vs day ceiling"))
needs_you_lines.append(ladder_line(spend_7d, max_week, "7d vs week ceiling"))

# open questions flagged by cycles today (ledger notes with human-facing phrasing)
human_re = re.compile(
    r"needs (a )?human|worth your attention|needs your action|only you can|joe to|"
    r"human .*(decide|provision|confirm)", re.I
)
flagged = []
if ledger_today is not None:
    for l in ledger_today:
        m = re.search(r'note="(.*)"$', l)
        note = m.group(1) if m else ""
        if human_re.search(note):
            cyc = re.search(r"cycle=(\d+)", l)
            flagged.append(f"  - cycle={cyc.group(1) if cyc else '?'}: {note[:200]}")
if flagged:
    needs_you_lines.append(f"- open questions flagged by cycles today  ({relpath(ledger_path)}):")
    needs_you_lines.extend(flagged)
elif ledger_today is None:
    needs_you_lines.append(f"- open questions flagged by cycles: {na(ledger_path)}")
else:
    needs_you_lines.append(f"- open questions flagged by cycles today: none  ({relpath(ledger_path)})")

# PRDs blocked with "needs human" in their Blocked: reason
blocked_human = []
for dirname in ("build-queue", "parked"):
    for fn in glob_md(dirname):
        p = os.path.join(PRD_DIR, dirname, fn)
        fm = prd_frontmatter(p)
        reason = fm.get("Blocked", "")
        if reason and re.search(r"needs human", reason, re.I):
            blocked_human.append(f"  - {dirname}/{fn}: {reason[:200]}  ({relpath(p)})")
if blocked_human:
    needs_you_lines.append("- PRDs blocked on a human:")
    needs_you_lines.extend(blocked_human)
else:
    needs_you_lines.append("- PRDs blocked on a human: none")

# deploy rollbacks mentioned in today's RedBaron logs
rollback_hits = []
auto_today = lines_for_date(os.environ["LOG_AUTO"], DATE)
if auto_today:
    for l in auto_today:
        if re.search(r"rollback", l, re.I):
            rollback_hits.append(f"  - {l[:220]}")
if rollback_hits:
    needs_you_lines.append(f"- deploy rollbacks today  ({relpath(os.environ['LOG_AUTO'])}):")
    needs_you_lines.extend(rollback_hits)
elif auto_today is None:
    needs_you_lines.append(f"- deploy rollbacks: not available ({relpath(os.environ['LOG_AUTO'])}: RedBaron-only log not present on this host)")
else:
    needs_you_lines.append(f"- deploy rollbacks today: none  ({relpath(os.environ['LOG_AUTO'])})")

sec("Needs you")
out.extend(needs_you_lines)

# ============================================================== Shipped =================
sec("Shipped")
shipped = []
for fn in glob_md("built-prds"):
    p = os.path.join(PRD_DIR, "built-prds", fn)
    fm = prd_frontmatter(p)
    if fm.get("Built") == DATE:
        cost = fm.get("Cost", "cost not recorded")
        shipped.append(f"- {fn}: {cost}  ({relpath(p)})")
if shipped:
    out.extend(shipped)
else:
    out.append(f"- none shipped {DATE}  ({relpath(os.path.join(PRD_DIR, 'built-prds'))})")

# ============================================================== Drafted =================
sec("Drafted")
drafted = []
for dirname in ("build-queue", "parked"):
    for fn in glob_md(dirname):
        p = os.path.join(PRD_DIR, dirname, fn)
        fm = prd_frontmatter(p)
        if fm.get("Drafted") == DATE:
            drafted.append(f"- {fn}  ({relpath(p)})")
if drafted:
    out.extend(drafted)
else:
    out.append(f"- none drafted {DATE}  ({relpath(os.path.join(PRD_DIR, 'build-queue'))})")

# ============================================================== Cycles ==================
sec("Cycles")
if ledger_today is None:
    out.append(na(ledger_path))
else:
    n = len(ledger_today)
    verdicts = collections.Counter(verdict_of(l) for l in ledger_today)
    out.append(f"- {n} cycles  ({relpath(ledger_path)})")
    if verdicts:
        breakdown = ", ".join(f"{v}={c}" for v, c in sorted(verdicts.items()))
        out.append(f"- verdicts: {breakdown}  ({relpath(ledger_path)})")
    notable = [l for l in ledger_today if verdict_of(l) in ("ABORTED", "WATCHDOG") or "WATCHDOG" in l]
    if notable:
        out.append(f"- ABORTED/WATCHDOG lines  ({relpath(ledger_path)}):")
        for l in notable:
            out.append(f"  - {l[:220]}")
    else:
        out.append("- ABORTED/WATCHDOG lines: none")
    auto_today = lines_for_date(os.environ["LOG_AUTO"], DATE)
    if auto_today:
        durs = []
        for l in auto_today:
            m = re.search(r"duration_s=(\d+)", l)
            if m:
                durs.append((int(m.group(1)), l))
        if durs:
            longest = max(durs, key=lambda t: t[0])
            out.append(f"- longest cycle: {longest[0]}s  ({relpath(os.environ['LOG_AUTO'])})")
        else:
            out.append(f"- longest cycle: not available (no duration_s in today's log, {relpath(os.environ['LOG_AUTO'])})")
    else:
        out.append(f"- longest cycle: not available ({relpath(os.environ['LOG_AUTO'])}: RedBaron-only log not present on this host)")

# ============================================================== Spend ===================
sec("Spend")
def spend_breakdown(win_secs, label):
    now = time.time()
    tot = collections.defaultdict(float)
    lines = read_lines(cl_path)
    if lines is None:
        return None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        try:
            t = calendar.timegm(time.strptime(r.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ"))
        except Exception:
            continue
        if now - t <= win_secs:
            tot[r.get("kind", "?")] += float(r.get("usd") or 0)
    return tot

b24 = spend_breakdown(86400, "24h")
if b24 is None:
    out.append(na(cl_path))
else:
    total24 = sum(b24.values())
    ceiling_s = f" of ${float(max_day):.2f}" if max_day else " (ceiling not set)"
    out.append(f"- 24h total: ${total24:.2f}{ceiling_s}  ({relpath(cl_path)})")
    if b24:
        out.append("- 24h by kind: " + ", ".join(f"{k}=${v:.2f}" for k, v in sorted(b24.items())) + f"  ({relpath(cl_path)})")
    day_lines = lines_for_date(cl_path, DATE) or []
    day_tot = collections.defaultdict(float)
    for line in day_lines:
        try:
            r = json.loads(line)
        except Exception:
            continue
        day_tot[r.get("kind", "?")] += float(r.get("usd") or 0)
    out.append(f"- day ({DATE}) total: ${sum(day_tot.values()):.2f}  ({relpath(cl_path)})")
    if day_tot:
        out.append("- day by kind: " + ", ".join(f"{k}=${v:.2f}" for k, v in sorted(day_tot.items())) + f"  ({relpath(cl_path)})")

# ============================================================== Hub =====================
sec("Hub")
hz_raw = os.environ.get("HEALTHZ_JSON", "")
try:
    hz = json.loads(hz_raw) if hz_raw else None
except Exception:
    hz = None
if hz:
    out.append(f"- version: {hz.get('version', '?')}  (live /healthz)")
    out.append(f"- tenants: {hz.get('tenants_total', '?')}, tools: {hz.get('tools_total', '?')}  (live /healthz)")
else:
    out.append("- hub /healthz: not available (unreachable or non-JSON at generation time)")

ml_path = os.path.join(LOOP, "measure-ledger.md")
ml_all = read_lines(ml_path)
last_probe = None
if ml_all:
    for l in reversed(ml_all):
        if "harness-probe=" in l:
            last_probe = l
            break
if last_probe:
    out.append(f"- last probe: {last_probe[:200]}  ({relpath(ml_path)})")
else:
    out.append(f"- last probe: {na(ml_path, 'no harness-probe line')}")

out.append("- last backup: not available (no backup subsystem shipped yet — see PRD-mdcollab-backup)")

# ============================================================== Measurement =============
sec("Measurement")
ml_today = lines_for_date(ml_path, DATE) if ml_all is not None else None
if ml_today is None:
    out.append(na(ml_path))
else:
    out.append(f"- {len(ml_today)} runs today  ({relpath(ml_path)})")
    for l in ml_today[-5:]:
        out.append(f"  - {l[:220]}")

evd = os.path.join(PRD_DIR, "evidence", "mcp-host", "measure")
latest_path = os.path.join(evd, "LATEST")
if os.path.isfile(latest_path):
    with open(latest_path, encoding="utf-8", errors="replace") as f:
        latest = f.read().strip()
    mj_path = os.path.join(evd, latest, "measure.json")
    try:
        with open(mj_path, encoding="utf-8", errors="replace") as f:
            m = json.load(f)
        out.append(f"- proxy/latest results: satisfaction={m.get('satisfaction')} wow_rate={m.get('wow_rate')} sessions={m.get('sessions')} failures={m.get('failures')}  ({relpath(mj_path)})")
        segs = m.get("by_segment") or {}
        if segs:
            out.append(f"- decisions per segment  ({relpath(mj_path)}):")
            for seg, v in segs.items():
                out.append(f"  - {seg}: sat={v.get('satisfaction')} wow={v.get('wow_rate')} n={v.get('n')}")
        else:
            out.append("- decisions per segment: none recorded")
    except Exception as e:
        out.append(f"- proxy/latest results: not available ({relpath(mj_path)}: {e})")
else:
    out.append(f"- proxy/latest results: {na(latest_path)}")

baseline_path = os.path.join(evd, "baseline.json")
if not os.path.isfile(baseline_path):
    baseline_path = os.path.join(PRD_DIR, "evidence", "mcp-host", "baseline.json")
if os.path.isfile(baseline_path):
    out.append(f"- baseline pointer: {relpath(baseline_path)}")
else:
    out.append(f"- baseline pointer: not available ({relpath(baseline_path)}: PRD-mcphost-baseline-anchor not yet built)")

# ============================================================== Errors ==================
sec("Errors")
# Deliberately NOT a bare "error"/"Error" match: fields like "is_error=False" contain that
# substring without being a failure. Require an actual error/failure marker.
fail_re = re.compile(r"ABORTED|WATCHDOG|is_error=True|error:|\bfailed\b|\bcrashed\b|\bFAIL\b|\bFAILED\b", re.I)
seen = set()
err_lines = []
for logpath in (os.environ["LOG_AUTO"], os.environ["LOG_MEASURE"]):
    today = lines_for_date(logpath, DATE)
    if not today:
        continue
    for l in today:
        if fail_re.search(l):
            key = re.sub(r"^\S+\s", "", l)[:80]  # dedupe on message shape, timestamp stripped
            if key in seen:
                continue
            seen.add(key)
            err_lines.append(f"- {l[:200]}  ({relpath(logpath)})")
if err_lines:
    out.extend(err_lines[:20])
else:
    any_log = any(os.path.isfile(p) for p in (os.environ["LOG_AUTO"], os.environ["LOG_MEASURE"]))
    if any_log:
        out.append("- none today")
    else:
        out.append("- not available (RedBaron-only journal logs not present on this host)")

header = f"# vibeloop daily digest — {DATE}\n\nGenerated by `.local/bin/vibeloop-digest.sh` from ledgers under `{relpath(LOOP)}`. Templated, no model calls."
print(header + "\n" + "\n".join(out) + "\n")
PY
)"

printf '%s\n' "$DIGEST_MD" > "$OUT"

# Weekly roll-up on Mondays (P1 req 6): shipped, spend, decisions, still-open questions.
dow="$(date -u -d "$DATE" +%u 2>/dev/null || date -u -jf %F "$DATE" +%u 2>/dev/null)"
if [ "$dow" = "1" ]; then
  WEEKLY="$DIGEST_DIR/$DATE-weekly.md"
  {
    echo "# vibeloop weekly roll-up — week ending $DATE"
    echo
    echo "Shipped this week (from built-prds/*.md, Built: within 7 days of $DATE):"
    since="$(date -u -d "$DATE -6 days" +%F 2>/dev/null || date -u -v-6d -jf %F "$DATE" +%F)"
    for f in "$PRD_DIR"/built-prds/PRD-*.md; do
      [ -f "$f" ] || continue
      b="$(grep -m1 '^- Built: ' "$f" | cut -d' ' -f3)"
      [ -n "$b" ] && [ "$b" \> "$since" ] 2>/dev/null && [ "$b" \< "$(date -u -d "$DATE +1 day" +%F 2>/dev/null || echo "$DATE~")" ] 2>/dev/null && \
        echo "- $(basename "$f"): $(grep -m1 '^- Cost: ' "$f" || echo 'cost not recorded')  ($(realpath --relative-to="$PRD_DIR" "$f" 2>/dev/null || basename "$f"))"
    done
    echo
    echo "Total spend this week (7d rolling, from vibeloop/cost-ledger.jsonl):"
    python3 - "$PRD_DIR/vibeloop/cost-ledger.jsonl" <<'PY2'
import json, sys, time, calendar
path = sys.argv[1]
now = time.time(); tot = 0.0
try:
    for line in open(path):
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except Exception: continue
        try: t = calendar.timegm(time.strptime(r.get("ts",""), "%Y-%m-%dT%H:%M:%SZ"))
        except Exception: continue
        if now - t <= 7*86400: tot += float(r.get("usd") or 0)
except FileNotFoundError:
    pass
print(f"- ${tot:.2f}  (vibeloop/cost-ledger.jsonl)")
PY2
    echo
    echo "Still-open questions (vibeloop/ledger.md notes flagged for a human, last 7 days):"
    tail -n 200 "$PRD_DIR/vibeloop/ledger.md" 2>/dev/null | grep -iE 'needs (a )?human|worth your attention|needs your action|only you can' | tail -n 10 | cut -c1-220 | sed 's/^/- /' || true
  } > "$WEEKLY"
fi

if [ "$commit" = "1" ]; then
  paths=("$OUT")
  [ -f "${WEEKLY:-}" ] && paths+=("$WEEKLY")
  git -C "$PRD_DIR" add -- "${paths[@]}" 2>/dev/null
  if ! git -C "$PRD_DIR" diff --cached --quiet -- "${paths[@]}" 2>/dev/null; then
    git -C "$PRD_DIR" commit -q -m "vibeloop: digest $DATE" -- "${paths[@]}" 2>/dev/null
    git -C "$PRD_DIR" push -q 2>/dev/null || echo "warn: digest push failed" >&2
  fi
fi

# --- notify: NATS (always, best-effort) + ntfy (opt-in via NTFY_TOPIC) -------------------
NEEDS_YOU="$(awk '/^## Needs you/{p=1;next} /^## /{p=0} p' "$OUT")"
if command -v nats >/dev/null 2>&1; then
  timeout 5 nats --server "$NATS_URL" pub wm.vibeloop.digest "$NEEDS_YOU" >/dev/null 2>&1 || true
fi
if [ -n "${NTFY_TOPIC:-}" ]; then
  curl -s --max-time 8 -H "Title: vibeloop $DATE" -d "$NEEDS_YOU" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
fi

echo "$OUT"
