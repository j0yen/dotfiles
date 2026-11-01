#!/usr/bin/env bash
# analysis-spec-age.sh: count the five-whys mechanisms still SPEC after 7 days (1071 mechanism M6, approvals #125/#110).
# Scans <vault>/*five-whys*.md, section `# Mechanisms`, one numbered item per mechanism ("N. title — ⚙ paths — owner X — state S").
# State is DERIVED from truth on this host, not from the written word (pages are not edited after filing): the local ⚙ paths (~/... or $HOME/...)
#   all present  -> LIVE (counts nothing)
#   some absent, written state SPEC -> SPEC, counted per owner when the page `date:` is more than 7 days before the clock
#   some absent, written state LIVE/MERGED/CONFIRMED -> live_path_missing [page, path]
#   no local path (PR numbers, other-host or repo-relative paths) -> unchecked (never SPEC, never missing)
# Writes ~/.cache/fleet-dash/spec-age.json {spec_older_7d: {owner: n}, live_path_missing: [[page, path]], unchecked: n, ts}.
# Read-only over the vault. Env: SPEC_AGE_NOW (epoch clock), SPEC_AGE_VAULT (default ~/Notes/wiki/answers), SPEC_AGE_OUT, SPEC_AGE_DAYS (default 7).
set -u
[ $# -eq 0 ] || { echo "usage: analysis-spec-age.sh (env: SPEC_AGE_NOW SPEC_AGE_VAULT SPEC_AGE_OUT)" >&2; exit 64; }
VAULT=${SPEC_AGE_VAULT:-$HOME/Notes/wiki/answers}
OUT=${SPEC_AGE_OUT:-$HOME/.cache/fleet-dash/spec-age.json}
NOW=${SPEC_AGE_NOW:-$(date +%s)}
mkdir -p "$(dirname "$OUT")" || exit 2
exec python3 -I - "$VAULT" "$OUT" "$NOW" "${SPEC_AGE_DAYS:-7}" "$HOME" <<'PY'
import calendar, glob, json, os, re, sys, time

vault, out, now, days, home = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
WRITTEN_LIVE = {"LIVE", "MERGED", "CONFIRMED"}
PATH_RE = re.compile(r"(?:~|\$HOME)/[^\s`'\",;()<>]+")
ITEM_RE = re.compile(r"^\s*\d+\.\s")

def page_epoch(text):
    m = re.search(r"^date:\s*(\d{4})-(\d{2})-(\d{2})", text, re.M)
    if not m:
        return None
    return calendar.timegm((int(m.group(1)), int(m.group(2)), int(m.group(3)), 0, 0, 0))

def mechanisms(text):
    items, cur, inside = [], None, False
    for line in text.splitlines():
        h = re.match(r"^(#+)\s+(.*)$", line)
        if h:
            if inside and cur is not None:
                items.append(" ".join(cur)); cur = None
            inside = h.group(2).strip().lower().startswith("mechanisms")
            continue
        if not inside:
            continue
        if ITEM_RE.match(line):
            if cur is not None:
                items.append(" ".join(cur))
            cur = [line.strip()]
        elif cur is not None and line.strip():
            cur.append(line.strip())
    if inside and cur is not None:
        items.append(" ".join(cur))
    return items

def local_paths(item):
    if "⚙" not in item:
        return []
    seg = item.split("⚙", 1)[1]
    seg = re.split(r"\s[—-]+\s*owner\b", seg, 1)[0]
    res = []
    for p in PATH_RE.findall(seg):
        p = re.sub(r":\d[\d,\-:]*$", "", p).rstrip(".")
        if p not in res:
            res.append(p)
    return res

def expand(p):
    return os.path.join(home, p.split("/", 1)[1])

spec = {"rb": 0, "r7": 0, "aide": 0}
missing, unchecked = [], 0
for page in sorted(glob.glob(os.path.join(vault, "*five-whys*.md"))):
    try:
        text = open(page, encoding="utf-8").read()
    except OSError:
        continue
    born = page_epoch(text)
    name = os.path.basename(page)
    for item in mechanisms(text):
        sm = re.findall(r"[—-]+\s*state\s+([A-Za-z]+)", item)
        state = sm[-1].upper() if sm else ""
        if state != "SPEC" and state not in WRITTEN_LIVE:
            continue
        paths = local_paths(item)
        if not paths:
            unchecked += 1
            continue
        absent = [p for p in paths if not os.path.exists(expand(p))]
        if state in WRITTEN_LIVE:
            for p in absent:
                missing.append([name, p])
        elif absent and born is not None and now - born > days * 86400:
            om = re.findall(r"owner\s+([A-Za-z0-9_-]+)", item)
            owner = om[-1].lower() if om else "unowned"
            spec[owner] = spec.get(owner, 0) + 1

doc = {"spec_older_7d": spec, "live_path_missing": missing, "unchecked": unchecked, "ts": now}
tmp = out + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f:
    f.write(json.dumps(doc, indent=2) + "\n")
os.replace(tmp, out)
print("analysis-spec-age: spec_older_7d=%s live_path_missing=%d unchecked=%d" % (json.dumps(spec), len(missing), unchecked))
PY
