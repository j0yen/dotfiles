#!/usr/bin/env bash
# memory-tone-lint.sh: keep every memory system in neutral language (A54, Joe 10-30 7:2x PM, rule: CLAUDE.md § Output NEUTRAL LANGUAGE IN EVERY MEMORY).
# Walks ~/.claude/CLAUDE.md, ~/.claude/projects/*/memory, ~/.claude/recall, ~/.claude/scratch/learning-candidates, ~/Notes/wiki (missing paths skipped).
# Prints `file:line: <text>` per hit, exit 1 on any hit, 0 on none. --json prints {"hits":[{file,line,tier}],"count":N}. Also writes
# $TONE_LINT_OUT (default ~/.cache/fleet-dash/memory-tone.json) {"host","hits","ts"} for the dash collector's memory_tone.hits alarm (> 0).
# Tier 1 = always a hit. Tier 2 = NEVER|STOP|DON'T + CAPS word, skipped inside code fences or when the caps word is a label ending in a colon.
# Env: TONE_LINT_HOME (default $HOME), TONE_LINT_OUT.
set -u
JSON=0
case "${1:-}" in
  --json) JSON=1; shift ;;
  "") ;;
  *) echo "usage: memory-tone-lint.sh [--json]" >&2; exit 64 ;;
esac
[ $# -eq 0 ] || { echo "usage: memory-tone-lint.sh [--json]" >&2; exit 64; }
H=${TONE_LINT_HOME:-$HOME}
OUT=${TONE_LINT_OUT:-$H/.cache/fleet-dash/memory-tone.json}
mkdir -p "$(dirname "$OUT")" 2>/dev/null
exec python3 -I - "$H" "$OUT" "$JSON" "$(hostname -s)" <<'PY'
import glob, json, os, re, sys, time

home, out, as_json, host = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
roots = [os.path.join(home, ".claude/CLAUDE.md")]
for pat in (".claude/projects/*/memory", ".claude/recall", ".claude/scratch/learning-candidates", "Notes/wiki"):
    roots += sorted(glob.glob(os.path.join(home, pat)))
files = []
SKIP = ("/Notes/wiki/sources/", "/.claude/recall/memories.pre-sync-")  # ingested external material and a frozen archive are not the fleet's own wording (A54, 11-02)
for r in roots:
    if os.path.isfile(r):
        files.append(r)
    elif os.path.isdir(r):
        for d, _, fs in os.walk(r):
            files += [os.path.join(d, f) for f in fs if f.endswith(".md") and not any(k in os.path.join(d, f) for k in SKIP)]

T1_CI = re.compile(r"fuck|shit|bitch|stupid|dumb|lazy|useless|garbage|disaster|dont be a|don.t be a|terrible|furious|angry|disapoint|disappoint|annoy", re.I)
T1_CS = re.compile(r"MY DEFECT|SEARED|NEVER EVER|NEVER FUCKING|NEVER ASK ME|STOP WASTING")
T2 = re.compile(r"\b(?:NEVER|STOP|DON.T) ([A-Z]{3,})")
ALLOW = re.compile(r"lazy import|lazy init|garbage-collect|garbage collector|worst case|lazygit|doc_lazy_continuation|useless_format|lazy ts parse|very disappointed", re.I)  # identifiers (tool, clippy lint and commit-message names) and the Sean Ellis term of art are facts, not tone (A54, 11-02)

hits = []
for f in files:
    fence = False
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        s = ALLOW.sub("", line)
        tier = 0
        if T1_CI.search(s) or T1_CS.search(s):
            tier = 1
        elif not fence:
            for m in T2.finditer(s):
                if s[m.end():m.end() + 1] != ":":
                    tier = 2
                    break
        if tier:
            hits.append({"file": f, "line": n, "tier": tier, "text": line.strip()})

try:
    with open(out, "w") as fh:
        json.dump({"host": host, "hits": len(hits), "ts": int(time.time())}, fh)
except OSError:
    pass
if as_json:
    print(json.dumps({"hits": [{k: h[k] for k in ("file", "line", "tier")} for h in hits], "count": len(hits)}))
else:
    for h in hits:
        print("%s:%d: %s" % (h["file"], h["line"], h["text"]))
sys.exit(1 if hits else 0)
PY
