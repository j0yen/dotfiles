#!/usr/bin/env bash
# merge-gate-guard.sh — PreToolUse (Bash): a SEATBELT, not the gate (branch protection is the gate,
# a later step). A `gh pr merge` on a merge-gate repo runs only through the merge gate.
#
# Plan: ~/Notes/wiki/decisions/2026-10-24-dotfiles-vibecode-kit-decisions-graded-wwhtbt.md § Mechanisms 1.
# Leaf 1 failed three times as prose ("&& on a d- id"): 10-21 mcphost-deploy #70 (`;` chain), 10-22 #73
# (`| tail` hid rc=2), 10-24 dotfiles #83 #91 #92 #93 #95 (bare `gh pr merge` from the carbon session).
#
# DENIED (exit 2), for a repo in the swarm-decide contract's merge-gate repo_tokens:
#   * `gh pr merge …` (repo = --repo/-R, a PR URL, GH_REPO=, else the cwd's origin remote, following a
#     leading `cd DIR &&`) unless it is chained `wm-decide merge-gate … &&` (every link back to the gate
#     is `&&`; `;`  `||`  `|` break the chain) or the chain starts from rb-merge.sh. rb-merge.sh itself
#     is a command word that is not `gh`, so it never trips this hook.
#   * `gh api -X PUT|--method PUT repos/<listed>/pulls/<N>/merge`, always.
# The repo list is read at run time from the live swarm-decide pin's gen/merge-gate.json (never copied
# here): $MERGE_GATE_CONTRACT, else the dir that `readlink -f wm-decide` points into.
# Unknown or unparseable input, a missing contract, no origin remote → allow (exit 0).

set -uo pipefail

INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HOOK_INPUT="$INPUT" exec python3 -I -c '
import json, os, re, shlex, subprocess, sys

def allow():
    sys.exit(0)

try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))
    if data.get("tool_name") != "Bash":
        allow()
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not isinstance(cmd, str) or not cmd.strip():
        allow()
    cwd0 = data.get("cwd") or os.getcwd()
except Exception:
    allow()

# cheap pre-filter: nothing to look at
if not re.search(r"gh\b.*\b(pr\s+merge|api)\b", cmd, re.S):
    allow()

# ---------------------------------------------------------------- contract (never hardcode the repo list)
def contract_path():
    p = os.environ.get("MERGE_GATE_CONTRACT")
    if p:
        return p
    for cand in (os.path.expanduser("~/.local/bin/wm-decide"),):
        if os.path.exists(cand):
            real = os.path.realpath(cand)          # <pin>/bin/wm-decide
            return os.path.join(os.path.dirname(os.path.dirname(real)), "gen", "merge-gate.json")
    from shutil import which
    w = which("wm-decide")
    if w:
        real = os.path.realpath(w)
        return os.path.join(os.path.dirname(os.path.dirname(real)), "gen", "merge-gate.json")
    return None

try:
    with open(contract_path(), encoding="utf-8") as f:
        REPOS = {r.lower() for r in json.load(f)["repo_tokens"]}
    if not REPOS:
        allow()
except Exception:
    allow()

# ---------------------------------------------------------------- split into chain segments
def strip_heredocs(text):
    out, pending = [], None
    for line in text.split("\n"):
        if pending is not None:
            if line.strip() == pending:
                pending = None
            continue
        out.append(line)
        m = re.search(r"(?<!<)<<-?\s*([\x27\"]?)([A-Za-z_][A-Za-z_0-9]*)\1", line)
        if m:
            pending = m.group(2)
    return "\n".join(out)

def split_chain(text):
    """-> [(sep_before, segment_text)], quote-aware; sep is one of "", "&&", "||", ";", "|", "&"."""
    segs, cur, sep = [], [], ""
    i, n, q = 0, len(text), None
    while i < n:
        c = text[i]
        if q:
            cur.append(c)
            if c == "\\" and q == "\"" and i + 1 < n:
                cur.append(text[i + 1]); i += 1
            elif c == q:
                q = None
        elif c == "\\" and i + 1 < n:
            cur.append(c); cur.append(text[i + 1]); i += 1
        elif c in "\x27\"":
            q = c; cur.append(c)
        elif text.startswith("&&", i) or text.startswith("||", i):
            segs.append((sep, "".join(cur))); cur, sep = [], text[i:i + 2]; i += 1
        elif c in ";|\n" or (c == "&" and text[i - 1:i] not in (">", "<") and text[i + 1:i + 2] != ">"):
            segs.append((sep, "".join(cur))); cur, sep = [], (";" if c == "\n" else c)
        else:
            cur.append(c)
        i += 1
    segs.append((sep, "".join(cur)))
    if q:
        raise ValueError("unbalanced quote")
    return [(s, t) for s, t in segs if t.strip()]

WRAP = {"env", "command", "sudo", "time", "exec", "nohup", "nice", "stdbuf", "builtin"}

def words(seg):
    """-> (leading env assignments dict, command words list) or ([],[])"""
    toks = shlex.split(seg, comments=False, posix=True)
    env = {}
    while toks:
        t = toks[0]
        if re.match(r"^[A-Za-z_][A-Za-z_0-9]*=", t):
            k, v = t.split("=", 1); env[k] = v; toks.pop(0)
        elif os.path.basename(t) in WRAP:
            toks.pop(0)
            while toks and toks[0].startswith("-"):
                toks.pop(0)
        else:
            break
    return env, toks

def base(t):
    return os.path.basename(t)

def parse(text, depth=0):
    """-> list of dicts: {i, sep, kind in (merge, api, gate, rbmerge, cd, other), env, toks}"""
    out = []
    for i, (sep, seg) in enumerate(split_chain(strip_heredocs(text))):
        try:
            env, toks = words(seg.strip().lstrip("({ ").rstrip(") }"))
        except ValueError:
            continue
        kind = "other"
        if toks:
            b = base(toks[0])
            if b == "gh" and len(toks) >= 3 and toks[1] == "pr" and toks[2] == "merge":
                kind = "merge"
            elif b == "gh" and len(toks) >= 2 and toks[1] == "api":
                kind = "api"
            elif b == "wm-decide" and len(toks) >= 2 and toks[1] == "merge-gate":
                kind = "gate"
            elif b == "rb-merge.sh":
                kind = "rbmerge"
            elif toks[0] == "cd" and len(toks) >= 2:
                kind = "cd"
            elif b in ("bash", "sh", "zsh") and "-c" in toks and depth < 2:
                k = toks.index("-c")
                if k + 1 < len(toks):
                    for s in parse(toks[k + 1], depth + 1):
                        s["sep"] = sep if s["sep"] == "" else s["sep"]
                        out.append(dict(s, i=len(out)))
                    continue
        out.append({"i": len(out), "sep": sep, "kind": kind, "env": env, "toks": toks})
    return out

try:
    segs = parse(cmd)
except Exception:
    allow()

# ---------------------------------------------------------------- repo of a merge
def norm_repo(s):
    s = s.strip().rstrip("/")
    s = re.sub(r"\.git$", "", s)
    m = re.search(r"([^/:\s]+)/([^/:\s]+)$", s)
    return (m.group(1) + "/" + m.group(2)).lower() if m else None

def opt(toks, longs, shorts):
    for k, t in enumerate(toks):
        for l in longs:
            if t == l and k + 1 < len(toks):
                return toks[k + 1]
            if t.startswith(l + "="):
                return t.split("=", 1)[1]
        for s in shorts:
            if t == s and k + 1 < len(toks):
                return toks[k + 1]
    return None

def origin_repo(d):
    try:
        p = subprocess.run(["git", "-C", d, "remote", "get-url", "origin"], capture_output=True, text=True, timeout=2)
        return norm_repo(p.stdout) if p.returncode == 0 and p.stdout.strip() else None
    except Exception:
        return None

def merge_info(seg_i):
    """-> (repo or None, pr number string or None)"""
    s = segs[seg_i]
    toks = s["toks"][3:]
    r = opt(toks, ["--repo"], ["-R"])
    pr = None
    for t in toks:
        if re.fullmatch(r"\d+", t):
            pr = t; break
        m = re.search(r"github\.com/([^/]+/[^/]+)/pull/(\d+)", t)
        if m:
            r = r or m.group(1); pr = m.group(2); break
    if r is None and s["env"].get("GH_REPO"):
        r = s["env"]["GH_REPO"]
    if r is not None:
        return norm_repo(r), pr
    cwd = cwd0
    for p in segs[:seg_i]:                      # a leading `cd DIR` in the same command
        if p["kind"] == "cd":
            d = os.path.expanduser(p["toks"][1])
            cwd = d if os.path.isabs(d) else os.path.join(cwd, d)
    return origin_repo(cwd), pr

def gated(k):
    """every link back to a merge-gate / rb-merge.sh segment is `&&`"""
    j = k
    while j > 0 and segs[j]["sep"] == "&&":
        if segs[j - 1]["kind"] in ("gate", "rbmerge"):
            return True
        j -= 1
    return False

def deny(repo, pr, what):
    r = repo or "<owner/repo>"
    n = pr or "<N>"
    sys.stderr.write(
        "merge-gate-guard: %s on %s is denied outside the merge gate (seatbelt; branch protection is the gate, a later step).\n"
        "Leaf 1 of decisions/2026-10-24-dotfiles-vibecode-kit-decisions-graded-wwhtbt.md: a merge needs its verdict row first.\n"
        "Allowed line (only && counts; a ; or || or | before the merge does not):\n"
        "  wm-decide merge-gate <verdict-id> --pr %s --repo %s && gh pr merge %s --repo %s --squash --delete-branch\n"
        "or, for seats:  rb-merge.sh <verdict-id> %s %s\n"
        "The verdict row: wm-decide record --kind verdict --gates <the d-id of your DECISION row> --agent <you> ...  (wm-decide merge-gate --help)\n"
        % (what, r, n, r, n, r, n, r))
    sys.exit(2)

for k, s in enumerate(segs):
    if s["kind"] == "merge":
        repo, pr = merge_info(k)
        if repo and repo in REPOS and not gated(k):
            deny(repo, pr, "gh pr merge")
    elif s["kind"] == "api":
        toks = s["toks"]
        meth = None
        for a, t in enumerate(toks):
            if t in ("-X", "--method") and a + 1 < len(toks):
                meth = toks[a + 1]
            elif t.startswith("--method="):
                meth = t.split("=", 1)[1]
            elif t.startswith("-X") and len(t) > 2:
                meth = t[2:].lstrip("=")
        if (meth or "").upper() != "PUT":
            continue
        for t in toks[2:]:
            m = re.search(r"repos/([^/\s]+/[^/\s]+)/pulls/(\d+)/merge/?$", t)
            if m and m.group(1).lower() in REPOS:
                deny(m.group(1), m.group(2), "gh api PUT pulls/%s/merge" % m.group(2))
allow()
'
