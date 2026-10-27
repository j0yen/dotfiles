#!/usr/bin/env bash
# seat-floor-cut-sources.sh -- M9 step 1, the weakest-link falsifier (decisions/2026-10-27-m9-seat-floor-cut-wwhtbt.md, Amendment 2). OFFLINE and read-only: no live change, no network, no ssh.
# Lists the exact line-sets the M9 stages cut and greps DAYS (default 7) of main-thread seat turns, segment by segment (a segment = one compact_boundary to the next), for ACTIONS
# (assistant tool_use inputs and text) that contain a distinctive token whose ONLY source is a cut line: the token is absent from CLAUDE.md, AGENTS.md, goal.md § Stage, that segment's
# summary and everything else that segment already carried (earlier messages, tool results, attachments, the 40 lines preserved across the boundary). The SessionStart
# stdout of seat-context-start.sh and the MEMORY.md copy inside `instructions` do NOT count as carried: they are what the cut removes.
#   cut line-sets   playbook   every line of fleet-operations.md (compact/resume keep a pointer, never the body)                         [stage 1]
#                   memory     every MEMORY.md line outside the kept set (kept = LIVE TRAPS section + any line naming a handoff file)    [stage 4]
#                   skills     user skills not in the seat's invoked set (JSONL Skill tool_use / invoked_skills / /name prompts) + the always-on set  [stage 3]
# Every HIT names a line the compact payload or the seat memory index must keep. Zero hits clears stages 1-4.
# Token = >= 8 chars of [A-Za-z0-9_./~:-] containing one of - _ . / or a digit (paths, ids, script and file names), lower-cased.
# Usage: seat-floor-cut-sources.sh [--days N] [--seat NAME]... [--fail-on-hit] [--max-hits N]     Exit 0 (report) unless --fail-on-hit and hits > 0.
# Env: SEATS_TSV, JSONL_DIR, MEMORY_MD, PLAYBOOK, GOAL, CLAUDE_MD, AGENTS_MD, SKILLS_DIR, SEAT_FLOOR_NOW (test clock). Seat set = seats.tsv rows with a real sid.
set -u
export SEATS_TSV="${SEATS_TSV:-$HOME/.claude/state/seats.tsv}" JSONL_DIR="${JSONL_DIR:-$HOME/.claude/projects/-home-jsy}"
export MEMORY_MD="${MEMORY_MD:-$JSONL_DIR/memory/MEMORY.md}" PLAYBOOK="${PLAYBOOK:-$HOME/Notes/wiki/playbooks/fleet-operations.md}" GOAL="${GOAL:-$HOME/Notes/wiki/goal.md}"
export CLAUDE_MD="${CLAUDE_MD:-$HOME/.claude/CLAUDE.md}" AGENTS_MD="${AGENTS_MD:-$HOME/AGENTS.md}" SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
exec python3 -I - "$@" <<'PY'
import argparse, calendar, json, os, re, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--days", type=int, default=7); ap.add_argument("--seat", action="append", default=[])
ap.add_argument("--fail-on-hit", action="store_true"); ap.add_argument("--max-hits", type=int, default=400)
a = ap.parse_args()
E = os.environ
NOW = int(E.get("SEAT_FLOOR_NOW") or time.time()); CUT = NOW - a.days * 86400
TOK = re.compile(r"[A-Za-z0-9_./~:-]{8,}")
STRIP = ".:/-~"
ALWAYS_ON = ["goal", "dream", "5whysandrhyme", "wwhtbt"]


def toks(text):
    out = set()
    for m in TOK.findall(text):
        m = m.strip(STRIP).lower()
        if len(m) >= 8 and re.search(r"[-_./0-9]", m):
            out.add(m)
    return out


def read(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def epoch(ts):
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return 0


def stage_text(goal):
    out, on = [], False
    for ln in goal.splitlines():
        if ln.startswith("## Stage"):
            on = True
        elif on and ln.startswith("## "):
            break
        if on:
            out.append(ln)
    return "\n".join(out)


# ---- cut line-sets -> token -> [(set, line number, line)]
cutmap, cutlines = {}, {"playbook": 0, "memory": 0}
def add(setname, lineno, line):
    for t in toks(line):
        cutmap.setdefault(t, []).append((setname, lineno, line.strip()[:200]))
for i, ln in enumerate(read(E["PLAYBOOK"]).splitlines(), 1):
    if ln.strip():
        add("playbook", i, ln); cutlines["playbook"] += 1
in_traps = False
for i, ln in enumerate(read(E["MEMORY_MD"]).splitlines(), 1):
    if ln.startswith("LIVE TRAPS"):
        in_traps = True
    elif ln.startswith("ARCHIVES"):
        in_traps = False
    kept = in_traps or ("handoff" in ln.lower()) or ln.startswith("LIVE TRAPS")
    if ln.strip() and not kept:
        add("memory", i, ln); cutlines["memory"] += 1
allowed_static = toks(read(E["CLAUDE_MD"])) | toks(read(E["AGENTS_MD"])) | toks(stage_text(read(E["GOAL"])))
user_skills = sorted(d for d in os.listdir(E["SKILLS_DIR"])) if os.path.isdir(E["SKILLS_DIR"]) else []

seats = []
for ln in read(E["SEATS_TSV"]).splitlines():
    f = ln.split("\t")
    if ln.startswith("#") or len(f) < 3 or f[2] in ("-", ""):
        continue
    if not a.seat or f[0] in a.seat:
        seats.append((f[0], f[2]))

TS = re.compile(rb'"timestamp":"([^"]+)"')
CMDNAME = re.compile(r"<command-name>/?([A-Za-z0-9:_-]+)</command-name>")
hits, hit_lines, seg_n, act_n = [], {}, 0, 0
skill_sets, seat_stats = {}, {}


def action_texts(d):
    """-> [(tool, text)] for one assistant line."""
    out = []
    for b in ((d.get("message") or {}).get("content") or []):
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            out.append(("text", b.get("text", "")))
        elif b.get("type") == "tool_use":
            inp = b.get("input")
            vals = []
            def walk(x):
                if isinstance(x, str): vals.append(x)
                elif isinstance(x, dict): [walk(v) for v in x.values()]
                elif isinstance(x, list): [walk(v) for v in x]
            walk(inp)
            out.append((b.get("name", "tool"), "\n".join(vals)))
    return out


def flat(d):
    """every string in a line, minus the parts the cut removes."""
    at = (d.get("attachment") or {})
    if at.get("type") == "hook_success" and "seat-context-start" in str(at.get("command", "")):
        return ""
    if at.get("type") == "instructions":
        return ""
    buf = []
    def walk(x):
        if isinstance(x, str): buf.append(x)
        elif isinstance(x, dict): [walk(v) for v in x.values()]
        elif isinstance(x, list): [walk(v) for v in x]
    walk(d.get("attachment") if "attachment" in d else d.get("message", d.get("content")))
    return "\n".join(buf)


for seat, sid in seats:
    path = os.path.join(E["JSONL_DIR"], sid + ".jsonl")
    invoked, nseg, nact = set(ALWAYS_ON), 0, 0
    if not os.path.exists(path):
        seat_stats[seat] = "no jsonl"; continue
    seen = None; ring = []   # seen = token set of the current segment (None before the first boundary in the window)
    with open(path, "rb") as f:
        for raw in f:
            m = TS.search(raw)
            if not m or epoch(m.group(1).decode("ascii", "replace")) < CUT:
                continue
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            if d.get("isSidechain"):
                continue
            t = d.get("type")
            if t == "system" and d.get("subtype") == "compact_boundary":
                seen = set(allowed_static)
                for r in ring[-40:]:
                    seen |= r
                nseg += 1; ring = []
                continue
            text = flat(d) if t in ("user", "attachment", "assistant") else ""
            tk = toks(text) if text else set()
            if t == "user":
                for cn in CMDNAME.findall(text):
                    invoked.add(cn.split(":")[-1])
            if t == "attachment" and (d.get("attachment") or {}).get("type") == "invoked_skills":
                for s in ((d.get("attachment") or {}).get("skills") or []):
                    if isinstance(s, dict) and s.get("name"):
                        invoked.add(str(s["name"]).split(":")[-1])
            if t == "assistant":
                for tool, body in action_texts(d):
                    if tool == "Skill" and body.strip():
                        invoked.add(body.split("\n")[0].strip().split(":")[-1])
                    if seen is None:
                        continue
                    nact += 1
                    for tok in toks(body):
                        if tok not in seen and tok in cutmap:
                            src = cutmap[tok][0]
                            hits.append((seat, d.get("timestamp", ""), tool, tok, src))
                            hit_lines.setdefault((src[0], src[1], src[2]), []).append((seat, tok))
                    seen |= toks(body)
            if seen is not None:
                seen |= tk
            ring.append(tk)
            if len(ring) > 80:
                ring = ring[-80:]
    skill_sets[seat] = sorted(s for s in invoked if s)
    seat_stats[seat] = "%d segments, %d actions scanned" % (nseg, nact)
    seg_n += nseg; act_n += nact

print("seat-floor-cut-sources: %d day(s), seats %s; cut lines: playbook %d, memory %d (outside LIVE TRAPS + handoff pointers); user skills on disk %d" % (
    a.days, ",".join(s for s, _ in seats) or "-", cutlines["playbook"], cutlines["memory"], len(user_skills)))
for s, v in seat_stats.items():
    print("  %s: %s" % (s, v))
for s, names in skill_sets.items():
    off = [u for u in user_skills if u not in names]
    print("skills %s: seat set %d (%s); off %d of %d user skills" % (s, len(names), " ".join(names), len(off), len(user_skills)))
for h in hits[: a.max_hits]:
    print("HIT %s %s %s token=%s <- %s:%d %s" % (h[0], h[1], h[2], h[3], h[4][0], h[4][1], h[4][2][:120]))
if len(hits) > a.max_hits:
    print("... %d more hit(s) not listed" % (len(hits) - a.max_hits))
print("KEEP (every cut line a seat action depended on; the payload or seat index must keep these):")
for (setname, ln, text), who in sorted(hit_lines.items(), key=lambda kv: (kv[0][0], kv[0][1])):
    toks_s = sorted({w[1] for w in who})
    print("  %s:%d seats=%s tokens=%s | %s" % (setname, ln, ",".join(sorted({w[0] for w in who})), ",".join(toks_s[:4]), text[:140]))
print("HITS=%d UNIQUE_LINES=%d SEGMENTS=%d ACTIONS=%d" % (len(hits), len(hit_lines), seg_n, act_n))
sys.exit(1 if (a.fail_on_hit and hits) else 0)
PY
