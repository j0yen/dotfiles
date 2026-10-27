#!/usr/bin/env bash
# seat-floor-probe.sh -- M9 mechanism 6 (decisions/2026-10-27-m9-seat-floor-cut-wwhtbt.md): measure the post-compaction context FLOOR of each operator seat.
# One row per `compact_boundary` of the seat's main-thread JSONL: floor = input + cache_read + cache_creation of the first assistant call after it, plus the
# per-source bytes of what the boundary re-sent (summary, hook stdout, re-attached files, instructions, skill listing) and the SessionStart hook_cancelled count.
# A byte-offset cursor per seat (<dir>/<seat>.cursor) means only NEW bytes are read; a first run reads at most SEAT_FLOOR_BACKFILL_BYTES (40 MB) of the tail,
# never the whole file. A boundary still waiting for its first assistant call stays behind the cursor.
# Outputs under SEAT_FLOOR_DIR (default ~/.cache/fleet-dash/seat-floor): seat-floor.tsv (rows) and seat-floor.json (per-seat floor_p50 of the last 5,
# floor_last, compact_hook_cancelled_24h, files_bytes_last, alarms) for fleet-dash collect.sh and the operator card.
# Seat set = ~/.claude/state/seats.tsv rows with a real sid (never a hand-copied list). Read-only on the JSONLs; no network, no ssh, no systemctl.
# Alarm thresholds: expected_p50 + 5000 per seat from ~/.config/claude-seat/floor-stage.json (SEAT_FLOOR_STAGE_FILE), fallback 45000.
# Env: SEATS_TSV, JSONL_DIR (default ~/.claude/projects/-home-jsy), SEAT_FLOOR_DIR, SEAT_FLOOR_STAGE_FILE, SEAT_FLOOR_BACKFILL_BYTES, SEAT_FLOOR_NOW (test clock).
set -u
export SEATS_TSV="${SEATS_TSV:-$HOME/.claude/state/seats.tsv}" JSONL_DIR="${JSONL_DIR:-$HOME/.claude/projects/-home-jsy}"
export SEAT_FLOOR_DIR="${SEAT_FLOOR_DIR:-$HOME/.cache/fleet-dash/seat-floor}"
export SEAT_FLOOR_STAGE_FILE="${SEAT_FLOOR_STAGE_FILE:-$HOME/.config/claude-seat/floor-stage.json}"
export SEAT_FLOOR_BACKFILL_BYTES="${SEAT_FLOOR_BACKFILL_BYTES:-40000000}"
mkdir -p "$SEAT_FLOOR_DIR" 2>/dev/null || { echo "seat-floor-probe: cannot create $SEAT_FLOOR_DIR" >&2; exit 1; }
exec python3 -I - "$@" <<'PY'
import calendar, json, os, re, sys, time

SEATS = os.environ["SEATS_TSV"]; JD = os.environ["JSONL_DIR"]; OUT = os.environ["SEAT_FLOOR_DIR"]
STAGE = os.environ["SEAT_FLOOR_STAGE_FILE"]; BACKFILL = int(os.environ["SEAT_FLOOR_BACKFILL_BYTES"])
NOW = int(os.environ.get("SEAT_FLOOR_NOW") or time.time())
COLS = ["ts", "seat", "trigger", "preTokens", "floor", "cache_read", "summary_bytes", "hook_bytes", "files_bytes", "files_n",
        "files_max_path", "instr_bytes", "skill_listing_bytes", "hook_cancelled"]
TSV = os.path.join(OUT, "seat-floor.tsv")


def seats():
    out = []
    try:
        for ln in open(SEATS):
            if ln.startswith("#") or not ln.strip():
                continue
            f = ln.rstrip("\n").split("\t")
            if len(f) >= 3 and f[2] not in ("-", ""):
                out.append((f[0], f[2]))
    except OSError:
        pass
    return out


def sz(x):
    if x is None:
        return 0
    return len(x) if isinstance(x, str) else len(json.dumps(x, ensure_ascii=False))


def blank(ts, trig, pre):
    return {"ts": ts, "trigger": trig, "preTokens": pre, "floor": "", "cache_read": 0, "summary_bytes": 0, "hook_bytes": 0,
            "files_bytes": 0, "files_n": 0, "files_max_path": "", "instr_bytes": 0, "skill_listing_bytes": 0, "hook_cancelled": 0}


def scan(seat, path):
    cur_f = os.path.join(OUT, seat + ".cursor")
    size = os.path.getsize(path)
    try:
        off = int(open(cur_f).read().strip())
    except (OSError, ValueError):
        off = max(0, size - BACKFILL)
        first = True
    else:
        first = False
    if off > size:  # truncated or rotated file
        off = 0
    rows, pend, pend_start, fmax = [], None, None, 0
    with open(path, "rb") as f:
        f.seek(off)
        if first and off > 0:
            f.readline()  # drop the partial line
        pos = f.tell()
        cursor = pos
        while True:
            line = f.readline()
            if not line:
                break
            start, pos = pos, pos + len(line)
            if not line.endswith(b"\n"):
                pos = start  # incomplete trailing line: leave it for the next run
                break
            if pend is None and b'"compact_boundary"' not in line:
                cursor = pos
                continue
            try:
                d = json.loads(line)
            except ValueError:
                if pend is None:
                    cursor = pos
                continue
            t, st = d.get("type"), d.get("subtype")
            if t == "system" and st == "compact_boundary":
                if pend is not None:  # boundary with no assistant call before the next one
                    rows.append(pend)
                m = d.get("compactMetadata") or {}
                pend = blank(d.get("timestamp", ""), m.get("trigger", ""), m.get("preTokens", ""))
                pend_start, fmax = start, 0
                continue
            if pend is None:
                cursor = pos
                continue
            if t == "attachment":
                a = d.get("attachment") or {}
                at = a.get("type")
                if at == "hook_success":
                    pend["hook_bytes"] += sz(a.get("content") or a.get("stdout"))
                elif at == "hook_cancelled" and str(a.get("hookEvent", "")) == "SessionStart":
                    pend["hook_cancelled"] += 1
                elif at == "file":
                    c = a.get("content") or {}
                    fl = (c.get("file") or {}) if isinstance(c, dict) else {}
                    n = sz(fl.get("content") if fl else c)
                    pend["files_bytes"] += n; pend["files_n"] += 1
                    if n >= fmax:
                        fmax, pend["files_max_path"] = n, str(fl.get("filePath") or a.get("filename") or "")
                elif at == "instructions":
                    pend["instr_bytes"] += sum(sz(x.get("content")) for x in (a.get("files") or []) if isinstance(x, dict))
                elif at == "skill_listing":
                    pend["skill_listing_bytes"] += sz(a.get("content"))
            elif t == "user" and d.get("isCompactSummary"):
                pend["summary_bytes"] += sz((d.get("message") or {}).get("content"))
            elif t == "assistant" and not d.get("isSidechain"):
                u = (d.get("message") or {}).get("usage") or {}
                cr = u.get("cache_read_input_tokens", 0) or 0
                pend["floor"] = (u.get("input_tokens", 0) or 0) + cr + (u.get("cache_creation_input_tokens", 0) or 0)
                pend["cache_read"] = cr
                rows.append(pend); pend = None; cursor = pos
    if pend is not None:
        cursor = pend_start  # wait for the first assistant call
    return rows, cursor, cur_f


def load_rows():
    out = []
    try:
        for ln in open(TSV):
            f = ln.rstrip("\n").split("\t")
            if f[0] == "ts" or len(f) != len(COLS):
                continue
            out.append(dict(zip(COLS, f)))
    except OSError:
        pass
    return out


def epoch(ts):
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return 0


def p50(v):
    v = sorted(v)
    return v[len(v) // 2] if v else None


new = []
for seat, sid in seats():
    path = os.path.join(JD, sid + ".jsonl")
    if not os.path.exists(path):
        continue
    try:
        rows, cursor, cur_f = scan(seat, path)
    except OSError as e:
        print("seat-floor-probe: %s: %s" % (seat, e), file=sys.stderr)
        continue
    for r in rows:
        r["seat"] = seat
        new.append(r)
    tmp = cur_f + ".tmp"
    open(tmp, "w").write(str(cursor)); os.replace(tmp, cur_f)

if new:
    exists = os.path.exists(TSV) and os.path.getsize(TSV) > 0
    with open(TSV, "a") as f:
        if not exists:
            f.write("\t".join(COLS) + "\n")
        for r in new:
            f.write("\t".join(str(r.get(c, "")).replace("\t", " ").replace("\n", " ") for c in COLS) + "\n")

allrows = load_rows()
try:
    stage = json.load(open(STAGE))
except (OSError, ValueError):
    stage = {}
exp = (stage.get("expected_p50") or {})
summary = {"ts": NOW, "stage": stage.get("stage", 0), "seats": {}, "alarms": []}
for seat, _ in seats():
    mine = [r for r in allrows if r["seat"] == seat]
    fl = [int(r["floor"]) for r in mine if str(r["floor"]).isdigit()]
    last5 = mine[-5:]
    last5f = [int(r["floor"]) for r in last5 if str(r["floor"]).isdigit()]
    canc = sum(int(r["hook_cancelled"] or 0) for r in mine if NOW - epoch(r["ts"]) <= 86400)
    s = {"n": len(mine), "floor_p50": p50(last5f), "floor_last": fl[-1] if fl else None, "compact_hook_cancelled_24h": canc,
         "files_bytes_last": int(last5[-1]["files_bytes"]) if last5 else None,
         "files_max_path_last": last5[-1]["files_max_path"] if last5 else None}
    summary["seats"][seat] = s
    limit = int(exp.get(seat, 40000)) + 5000 if seat in exp else 45000
    if len(last5f) >= 3 and s["floor_p50"] > limit:
        summary["alarms"].append({"alarm": "seat-floor-high", "seat": seat, "text": "seat-floor-high: %s floor_p50 %d > %d" % (seat, s["floor_p50"], limit)})
    if canc > 0:
        summary["alarms"].append({"alarm": "seat-compact-hook-cancelled", "seat": seat, "text": "seat-compact-hook-cancelled: %s %d in 24 h" % (seat, canc)})
    big = [r for r in last5 if int(r["files_bytes"] or 0) > 15000]
    if len(big) >= 3:
        summary["alarms"].append({"alarm": "seat-reattach-high", "seat": seat, "text": "seat-reattach-high: %s files > 15 KB on %d of the last %d boundaries, largest %s" % (seat, len(big), len(last5), big[-1]["files_max_path"])})
tmp = os.path.join(OUT, "seat-floor.json.tmp")
open(tmp, "w").write(json.dumps(summary, sort_keys=True))
os.replace(tmp, os.path.join(OUT, "seat-floor.json"))
print("seat-floor-probe: %d new row(s); %s" % (len(new), " ".join("%s p50=%s" % (k, v["floor_p50"]) for k, v in summary["seats"].items())))
PY
