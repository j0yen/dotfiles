#!/usr/bin/env python3
"""mech-registry: registry of promised mechanisms and whether each is LIVE where it was promised.

Reads (read-only): `# Mechanisms` numbered lines in $WIKI/answers/*five-whys* and $WIKI/decisions/*,
the SPEC/pending ⚙ pointers in $CLAUDE_MD, and docs/mechanisms.md of each path in $MECH_EXTRA (colon list; a file or a repo dir).
Line shape: `<n>. <mechanism> — ⚙ <artifact> — owner <seat> — state <X>` (docs/mechanisms.md may use `- ` and an optional `— since YYYY-MM-DD`).
Probes the INSTALLED artifact only (path at its live location, timer active, hook registered in live settings.json),
on the host the artifact segment names (redbaron/rb, ryzen7/r7, orch; default carbon). A merged PR is never LIVE.

  mech-registry.py            write $OUT (default ~/.cache/fleet-dash/mechanisms.json)
  mech-registry.py --fields   print the status.json fields + alarms from $OUT (what fleet-dash merges)
  mech-registry.py --line     print the FLEET STATUS follow-ups line
Env: WIKI, CLAUDE_MD, MECH_EXTRA, OUT, MECH_NOW (ISO date, tests), PROBE_CMD (runner: `$PROBE_CMD <host> <cmd>`, exit 0 = pass,
tests only), WM_DECIDE (command for `followups --json`, default wm-decide).
"""
import datetime, glob, json, os, re, subprocess, sys

HOME = os.path.expanduser("~")
HOSTS = {"redbaron": "redbaron", "rb": "redbaron", "ryzen7": "ryzen7", "r7": "ryzen7", "orch": "orch"}
RETIRED = {"DROPPED", "CANCELLED", "SUPERSEDED", "WONTFIX", "RETIRED"}
LIVE_DIRS = [".local/bin", ".claude/hooks", ".claude/scripts", ".claude", ".config/claude-seat", ".config/systemd/user", ".config/wm-decide"]
PATH_RE = re.compile(r"[A-Za-z0-9_./@~+-]+\.(?:sh|py|service|timer|json|toml|rs|md)\b")
PR_RE = re.compile(r"\bPR\b|\bpull\b|#\d+|/pull/", re.I)
URL_RE = re.compile(r"https?://\S+")


def now():
    v = os.environ.get("MECH_NOW")
    return datetime.datetime.fromisoformat(v) if v else datetime.datetime.now()


def host_of(artifact):
    for w in re.findall(r"[A-Za-z0-9]+", artifact.lower()):
        if w in HOSTS:
            return HOSTS[w]
    return "carbon"


def parse_line(text):
    """-> dict or None. Needs owner and state segments."""
    m = re.match(r"\s*(?:\d+\.|-)\s+(.*)$", text)
    if not m:
        return None
    segs = [s.strip() for s in m.group(1).split(" — ")]
    art = owner = state = since = None
    for s in segs[1:]:
        if s.startswith("⚙"):
            art = s[1:].strip()
        elif re.match(r"owner\s+\S+", s):
            owner = s.split()[1].rstrip(".,;")
        elif re.match(r"state\s+\S+", s):
            state = re.sub(r"[^A-Za-z-].*$", "", s.split()[1]).upper()
        elif re.match(r"since\s+\d{4}-\d{2}-\d{2}", s):
            since = s.split()[1][:10]
    if owner is None or state is None:
        return None
    return {"mechanism": segs[0][:120], "artifact": art or "", "owner": owner, "state_as_written": state, "since": since}


def page_entries(path, root):
    fn = os.path.basename(path)
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    gear = sum(1 for l in lines if "⚙" in l)
    out, inside, parsed_gear = [], False, 0
    for i, l in enumerate(lines, 1):
        if re.match(r"#\s+Mechanisms\s*$", l):
            inside = True
            continue
        if inside and re.match(r"#\s", l):
            inside = False
        if inside and re.match(r"\s*\d+\.\s", l):
            p = parse_line(l)
            if p:
                if "⚙" in l:
                    parsed_gear += 1
                dm = re.match(r"(\d{4}-\d{2}-\d{2})", fn)
                p.update(page=os.path.relpath(path, root) if root else fn, line=i, first_seen=dm.group(1) if dm else str(now().date()))
                out.append(p)
    return out, gear, parsed_gear


def claude_md_entries(path):
    out = []
    if not os.path.isfile(path):
        return out
    year = now().year
    for i, l in enumerate(open(path, encoding="utf-8", errors="replace").read().split("\n"), 1):
        if "⚙" not in l or not re.search(r"\bSPEC\b|\bpending\b", l):
            continue
        art = re.split(r"[;)]", l.split("⚙", 1)[1], maxsplit=1)[0].strip()
        d = re.search(r"\b(\d{2})-(\d{2})\b", l)
        try:
            fs = str(datetime.date(year, int(d.group(1)), int(d.group(2)))) if d else str(now().date())
        except ValueError:
            fs = str(now().date())
        st = "SPEC" if re.search(r"\bSPEC\b", l) else "PENDING"
        out.append({"page": os.path.basename(path), "line": i, "mechanism": l.strip()[:120], "artifact": art, "owner": "claude-md",
                    "state_as_written": st, "first_seen": fs})
    return out


def extra_entries(spec):
    out = []
    for p in [x for x in spec.split(":") if x]:
        f = os.path.join(p, "docs", "mechanisms.md") if os.path.isdir(p) else p
        if not os.path.isfile(f):
            continue
        for i, l in enumerate(open(f, encoding="utf-8", errors="replace").read().split("\n"), 1):
            e = parse_line(l)
            if e:
                since = e.pop("since")
                e.update(page=f, line=i, first_seen=since or str(now().date()))
                out.append(e)
    return out


def tokens_of(artifact):
    return [t for t in PATH_RE.findall(URL_RE.sub(" ", artifact)) if not t.startswith("..")]


def build_probe(artifact):
    """-> (cmd, reason). cmd is a read-only shell command (None when nothing is probeable); reason names why."""
    toks = tokens_of(artifact)
    if not toks:
        return None, ("pr-only" if PR_RE.search(artifact) else "no-artifact")
    parts = []
    for t in toks:
        t = re.sub(r"^(~|/home/[^/]+)/", "", t)
        base = os.path.basename(t)
        if base.endswith(".timer"):
            parts.append(f"systemctl --user is-active --quiet {base}")
            continue
        cands = ([t] if t.startswith("/") else [f"$HOME/{t}"]) + [f"$HOME/{d}/{base}" for d in LIVE_DIRS]
        test = "(" + " || ".join(f"test -e {c}" for c in dict.fromkeys(cands)) + ")"
        if "/hooks/" in t:
            test += f" && grep -qs {base} $HOME/.claude/settings.json $HOME/.config/claude-seat/settings.json"
        parts.append(test)
    return " && ".join(f"({p})" for p in parts), None


def run_probe(host, cmd):
    runner = os.environ.get("PROBE_CMD")
    try:
        if runner:
            return subprocess.run([runner, host, cmd], timeout=10, capture_output=True).returncode == 0
        argv = ["bash", "-c", cmd] if host == "carbon" else ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, cmd]
        return subprocess.run(["timeout", "10"] + argv, capture_output=True).returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def probe(e):
    e["host"] = host_of(e["artifact"])
    if e["state_as_written"] in RETIRED:
        e["state_probed"], e["reason"] = "n/a", "retired"
        return
    cmd, why = build_probe(e["artifact"])
    if cmd is None:
        e["state_probed"], e["reason"] = "NOT-LIVE", why
    elif run_probe(e["host"], cmd):
        e["state_probed"], e["reason"] = "LIVE", ""
    else:
        e["state_probed"], e["reason"] = "NOT-LIVE", "probe-failed"


def ident(e):
    return f"{os.path.basename(e['page'])}#{e['line']}"


def brief(e):
    return {"id": ident(e), "page": e["page"], "line": e["line"], "artifact": e["artifact"], "first_seen": e["first_seen"]}


def summarize(entries, mismatches):
    n = now()
    old = lambda e: (n - datetime.datetime.fromisoformat(e["first_seen"])) > datetime.timedelta(hours=48)
    nl = sorted((e for e in entries if e["state_probed"] == "NOT-LIVE"), key=lambda e: e["first_seen"])
    over = [e for e in nl if old(e)]
    fields = {
        "mechanisms_not_live": {"count": len(nl), "oldest": [brief(e) for e in nl[:5]]},
        "mechanisms_spec_over_48h": {"count": len(over), "oldest": [brief(e) for e in over[:5]]},
        "mechanisms_parse_mismatch": {"count": sum(m["missing"] for m in mismatches), "pages": [m["page"] for m in mismatches]},
    }
    return fields, alarms_of(fields)


def alarms_of(f):
    a = []
    if f["mechanisms_spec_over_48h"]["count"] > 0:
        a.append(f"mechanisms-spec-over-48h: {f['mechanisms_spec_over_48h']['count']} not live > 48 h, oldest {f['mechanisms_spec_over_48h']['oldest'][0]['id']}")
    if f["mechanisms_parse_mismatch"]["count"] > 0:
        a.append(f"mechanisms-parse-mismatch: {f['mechanisms_parse_mismatch']['count']} ⚙ lines unparsed on {len(f['mechanisms_parse_mismatch']['pages'])} pages")
    return a


def collect():
    wiki = os.environ.get("WIKI", os.path.join(HOME, "Notes/wiki"))
    entries, mism = [], []
    pages = sorted(glob.glob(os.path.join(wiki, "answers", "*five-whys*")) + glob.glob(os.path.join(wiki, "decisions", "*")))
    for p in pages:
        if not os.path.isfile(p):
            continue
        es, gear, pg = page_entries(p, wiki)
        entries += es
        if gear > pg and (es or gear):
            mism.append({"page": os.path.relpath(p, wiki), "gear_lines": gear, "parsed": pg, "missing": gear - pg})
    entries += claude_md_entries(os.environ.get("CLAUDE_MD", os.path.join(HOME, ".claude/CLAUDE.md")))
    entries += extra_entries(os.environ.get("MECH_EXTRA", ""))
    for e in entries:
        probe(e)
    return entries, mism


def out_path():
    return os.environ.get("OUT", os.path.join(HOME, ".cache/fleet-dash/mechanisms.json"))


def followups_line(fields):
    nl = fields["mechanisms_not_live"]
    owed = overdue = oldest = None
    try:
        r = subprocess.run([*os.environ.get("WM_DECIDE", "wm-decide").split(), "followups", "--json"], capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            j = json.loads(r.stdout)
            owed, overdue, oldest = j["owed"], j["overdue"], j.get("oldest")
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
        pass
    if oldest is None and nl["oldest"]:
        oldest = nl["oldest"][0]["id"]
    c = f"owed {owed} (overdue {overdue})" if owed is not None else "owed unmeasured"
    return f"follow-ups: corrections {c}, mechanisms not live {nl['count']} (>48h {fields['mechanisms_spec_over_48h']['count']}), oldest {oldest or 'none'}"


def main(argv):
    if "--fields" in argv or "--line" in argv:
        d = json.load(open(out_path()))
        if "--line" in argv:
            print(followups_line(d["status_fields"]))
        else:
            print(json.dumps({"fields": d["status_fields"], "alarms": d["alarms"]}, indent=1))
        return 0
    entries, mism = collect()
    prev = {}
    try:
        for e in json.load(open(out_path()))["mechanisms"]:
            prev[(e["page"], e["line"], e["artifact"])] = e["first_seen"]
    except (OSError, ValueError, KeyError):
        pass
    for e in entries:
        k = (e["page"], e["line"], e["artifact"])
        if e["owner"] == "claude-md" and k in prev:
            e["first_seen"] = prev[k]
    fields, alarms = summarize(entries, mism)
    doc = {"generated": now().isoformat(timespec="seconds"), "total": len(entries), "mechanisms": [
        {k: e.get(k, "") for k in ("page", "line", "artifact", "host", "owner", "state_as_written", "state_probed", "reason", "first_seen")} for e in entries],
        "parse_mismatch": {"count": fields["mechanisms_parse_mismatch"]["count"], "pages": mism}, "status_fields": fields, "alarms": alarms}
    p = out_path()
    os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
    tmp = p + ".tmp"
    json.dump(doc, open(tmp, "w"), indent=1)
    os.replace(tmp, p)
    print(f"mech-registry: {len(entries)} mechanisms, not-live {fields['mechanisms_not_live']['count']}, >48h {fields['mechanisms_spec_over_48h']['count']}, parse-mismatch {fields['mechanisms_parse_mismatch']['count']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
