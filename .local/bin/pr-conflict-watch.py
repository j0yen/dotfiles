#!/usr/bin/env python3 -I
"""pr-conflict-watch: keep open PR branches mergeable against a moving main (Joe 11-01 12:1x AM "how can we minimize the number of merge conflicts?").

For every open PR of each fleet repo it runs `git merge-tree --write-tree` (no worktree) of base x head and classifies:
  clean        nothing to do
  generated    every conflicted path is a lockfile/changelog: with --apply, merge origin/<base> into the branch with a REAL merge commit
               (lockfiles taken from <base>, CHANGELOG union), push to the same branch (never force), log `auto-merged`
  code         a source conflict: bell the owning seat once per (pr, head, base) with the file list; the owner merges <base> in by hand
  skipped      draft, fork, or daemon land branch (wm-build/*)
State: ~/.cache/pr-conflict-watch/{state.json,log}; status line: `SUMMARY repo=<n> prs=<n> clean=<n> generated=<n> code=<n> auto_merged=<n> skipped=<n>`.
Modes: --dry-run (default) never pushes or bells.  --local <repo> --base <ref> --heads a,b  grades local branches (selftest).  --selftest builds a throwaway repo.
"""
import argparse, datetime as dt, json, os, re, shutil, subprocess, sys, tempfile

REPOS = ("j0yen/mcphost", "j0yen/synthorg", "j0yen/wm-build", "j0yen/dotfiles", "j0yen/swarm-decide", "j0yen/mcphost-deploy", "j0yen/build-skill", "j0yen/pybuild", "j0yen/fleet-sync", "j0yen/autobuilder")
OWNER = {"j0yen/synthorg": "r7", "j0yen/wm-build": "r7"}   # everything else: rb
LOCK = {"uv.lock", "Cargo.lock", "pnpm-lock.yaml", "package-lock.json", "yarn.lock", "poetry.lock"}
UNION = {"CHANGELOG.md", "CHANGELOG", "CHANGES.md"}
# Per-repo generated files (12:27 AM dry run: 30 of 50 conflicting PRs conflicted ONLY in these): MAIN = take main's copy, the leg regenerates it;
# UNION = line union (append-only lists). Cargo.toml / pyproject.toml are handled by version_only(): a conflict confined to the version line takes main's.
REPO_MAIN = {"j0yen/synthorg": {"tests/durations.json"}, "j0yen/mcphost": {"scripts/ci-suite-measured.json", "scripts/ci-suite-weights.json"}}
REPO_UNION = {"j0yen/synthorg": {"tests/flaky.yaml"}}
VERSION_FILES = {"Cargo.toml", "pyproject.toml"}
VERSION_RE = re.compile(r'^(\s*version\s*=\s*")[^"]*(")', re.M)
HOME = os.environ.get("PR_CONFLICT_WATCH_HOME") or os.path.expanduser("~")
STATE = os.path.join(HOME, ".cache", "pr-conflict-watch")


def sh(args, cwd=None, check=True, inp=None):
    p = subprocess.run(args, cwd=cwd, text=True, capture_output=True, input=inp)
    if check and p.returncode != 0:
        raise RuntimeError("%s -> rc=%d %s" % (" ".join(args[:4]), p.returncode, (p.stderr or p.stdout)[-400:]))
    return p


def merge_tree(git_dir, base, head):
    """-> (clean, conflicted_paths). merge-tree --write-tree --name-only: tree oid, conflicted names, blank, messages; rc 1 = conflicts."""
    p = sh(["git", "--git-dir", git_dir, "merge-tree", "--write-tree", "--name-only", base, head], check=False)
    if p.returncode not in (0, 1):
        raise RuntimeError("merge-tree rc=%d %s" % (p.returncode, p.stderr[-300:]))
    lines = p.stdout.splitlines()
    files = []
    for ln in lines[1:]:
        if ln == "":
            break
        files.append(ln)
    return p.returncode == 0, files


def kind(f, repo=None):
    """main | union | version | code for one conflicted path."""
    b = os.path.basename(f)
    if b in LOCK or f in REPO_MAIN.get(repo, ()):
        return "main"
    if b in UNION or f in REPO_UNION.get(repo, ()):
        return "union"
    if b in VERSION_FILES:
        return "version"
    return "code"


def version_only(git_dir, base, head, f):
    """True when base and head differ in f only on the version line (a release bump on each side), so main's copy is the resolution."""
    try:
        mb = sh(["git", "--git-dir", git_dir, "merge-base", base, head]).stdout.strip()
        a, b, c = (sh(["git", "--git-dir", git_dir, "show", "%s:%s" % (r, f)], check=False).stdout for r in (mb, base, head))
    except RuntimeError:
        return False
    strip = lambda t: VERSION_RE.sub(r'\1X\2', t)
    # the branch may change other lines; a version-only conflict means base's non-version content equals the ancestor's (only main bumped) or head's
    return strip(b) == strip(a) or strip(b) == strip(c)


def classify(files, repo=None, git_dir=None, base=None, head=None):
    if not files:
        return "clean"
    for f in files:
        k = kind(f, repo)
        if k == "code":
            return "code"
        if k == "version" and not (git_dir and version_only(git_dir, base, head, f)):
            return "code"
    return "generated"


def auto_merge(mirror, base_ref, head_sha, branch, files, remote, dry, repo=None):
    """Real merge of base into the branch in a throwaway clone; lockfiles from base, changelog union. Returns the new head or None (dry)."""
    os.makedirs(os.path.join(HOME, ".cache"), exist_ok=True)
    os.makedirs(os.path.join(HOME, ".cache"), exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="pcw-", dir=os.path.join(HOME, ".cache"))
    try:
        sh(["git", "clone", "-q", "--no-checkout", mirror, tmp])
        sh(["git", "-c", "advice.detachedHead=false", "checkout", "-q", head_sha], cwd=tmp)
        sh(["git", "config", "user.name", "pr-conflict-watch"], cwd=tmp)
        sh(["git", "config", "user.email", os.environ.get("GIT_AUTHOR_EMAIL") or sh(["git", "config", "--global", "user.email"], check=False).stdout.strip() or "pr-conflict-watch@carbon"], cwd=tmp)
        base_sha = sh(["git", "rev-parse", base_ref], cwd=tmp).stdout.strip()
        p = sh(["git", "merge", "--no-ff", "--no-commit", base_sha], cwd=tmp, check=False)
        if p.returncode != 0:
            conflicted = sh(["git", "diff", "--name-only", "--diff-filter=U"], cwd=tmp).stdout.split()
            for f in conflicted:
                k = kind(f, repo)
                if k == "main" or k == "version":
                    if k == "version":   # keep the branch's non-version edits: take ours, then set the version line to base's
                        ours = sh(["git", "show", ":2:" + f], cwd=tmp).stdout
                        theirs = sh(["git", "show", ":3:" + f], cwd=tmp).stdout
                        m = VERSION_RE.search(theirs)
                        with open(os.path.join(tmp, f), "w") as fh:
                            fh.write(VERSION_RE.sub(lambda mm: mm.group(1) + m.group(0).split('"')[1] + mm.group(2), ours, count=1) if m else theirs)
                    else:
                        sh(["git", "checkout", "--theirs", "--", f], cwd=tmp)          # theirs = base (merged in)
                elif k == "union":
                    ours = sh(["git", "show", ":2:" + f], cwd=tmp).stdout
                    theirs = sh(["git", "show", ":3:" + f], cwd=tmp).stdout
                    anc = sh(["git", "show", ":1:" + f], cwd=tmp, check=False).stdout
                    with open(os.path.join(tmp, f), "w") as fh:
                        fh.write(union(anc, ours, theirs, tmp))
                else:
                    raise RuntimeError("unexpected code conflict in %s" % f)
                sh(["git", "add", "--", f], cwd=tmp)
        bn = base_ref.split("/")[-1]
        msg = "Merge %s into %s (pr-conflict-watch: %s)" % (bn, branch, ", ".join("%s %s" % (f, {"main": "from " + bn, "version": "version from " + bn, "union": "union"}[kind(f, repo)]) for f in files))
        sh(["git", "commit", "-q", "--no-verify", "-m", msg], cwd=tmp)
        new = sh(["git", "rev-parse", "HEAD"], cwd=tmp).stdout.strip()
        if dry:
            return new + " (dry-run, not pushed)"
        p = sh(["git", "push", "-q", remote, "HEAD:refs/heads/" + branch], cwd=tmp, check=False)   # plain push: a moved branch refuses, never --force
        if p.returncode != 0:
            # 12:32 AM first apply run: 24 pushes landed yet git exited non-zero with a stale-info line; the remote tip is the truth
            tip = sh(["git", "ls-remote", remote, "refs/heads/" + branch], check=False).stdout.split()
            if not tip or tip[0] != new:
                raise RuntimeError("push refused: %s" % (p.stderr or p.stdout)[-300:])
        return new
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def union(anc, ours, theirs, cwd):
    d = tempfile.mkdtemp(dir=cwd)
    pa, po, pt = (os.path.join(d, n) for n in ("a", "o", "t"))
    for pth, s in ((pa, anc), (po, ours), (pt, theirs)):
        open(pth, "w").write(s)
    p = sh(["git", "merge-file", "--union", "-p", po, pa, pt], check=False)
    return p.stdout


def bell(owner, text, dry):
    if dry:
        return "dry-run bell " + owner + ": " + text[:120]
    exe = shutil.which("seat-event.sh")
    if not exe:
        return "no seat-event.sh"
    subprocess.run([exe, owner, text], text=True, capture_output=True, timeout=120)
    return "belled " + owner


def load_state():
    try:
        return json.load(open(os.path.join(STATE, "state.json")))
    except (OSError, ValueError):
        return {"prs": {}}


def save_state(st):
    os.makedirs(STATE, exist_ok=True)
    tmp = os.path.join(STATE, "state.json.tmp")
    json.dump(st, open(tmp, "w"), indent=1, sort_keys=True)
    os.replace(tmp, os.path.join(STATE, "state.json"))


def log(line):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "log"), "a") as f:
        f.write(dt.datetime.now().isoformat(timespec="seconds") + " " + line + "\n")
    print(line)


def run_repo(repo, apply, st, counts, include_daemon):
    mirror = os.path.join(STATE, "mirrors", repo.replace("/", "__") + ".git")
    url = "https://github.com/%s.git" % repo
    if not os.path.isdir(mirror):
        sh(["git", "clone", "-q", "--mirror", url, mirror])
    sh(["git", "--git-dir", mirror, "fetch", "-q", "--prune", "origin", "+refs/heads/*:refs/heads/*", "+refs/pull/*/head:refs/pull/*/head"])
    p = sh(["gh", "pr", "list", "--repo", repo, "--state", "open", "--limit", "200", "--json",
            "number,headRefName,headRefOid,baseRefName,isDraft,isCrossRepository,mergeable"])
    prs = json.loads(p.stdout)
    base_shas = {}
    for pr in prs:
        n, head, branch, base = pr["number"], pr["headRefOid"], pr["headRefName"], pr["baseRefName"]
        key = "%s#%d" % (repo, n)
        counts["prs"] += 1
        if pr["isDraft"] or pr["isCrossRepository"] or (branch.startswith("wm-build/") and not include_daemon):
            counts["skipped"] += 1
            st["prs"][key] = {"class": "skipped", "head": head}
            continue
        if base not in base_shas:
            base_shas[base] = sh(["git", "--git-dir", mirror, "rev-parse", "refs/heads/" + base]).stdout.strip()
        bsha = base_shas[base]
        clean, files = merge_tree(mirror, bsha, head)
        cls = classify(files, repo, mirror, bsha, head)
        counts[cls] += 1
        prev = st["prs"].get(key, {})
        rec = {"class": cls, "head": head, "base": bsha, "files": files, "gh_mergeable": pr["mergeable"], "ts": dt.datetime.now().isoformat(timespec="seconds")}
        if cls == "generated":
            try:
                new = auto_merge(mirror, "refs/heads/" + base, head, branch, files, url, dry=not apply, repo=repo)
                rec["auto_merged"] = new
                counts["auto_merged"] += 1
                log("%s auto-merged %s into %s -> %s files=%s" % (key, base, branch, new, ",".join(files)))
            except RuntimeError as e:
                rec["error"] = str(e)[-300:]
                log("%s auto-merge FAILED: %s" % (key, str(e)[-200:]))
        elif cls == "code":
            same = prev.get("class") == "code" and prev.get("head") == head and prev.get("base") == bsha and prev.get("belled")
            if not same:
                owner = OWNER.get(repo, "rb")
                txt = ("pr-conflict-watch %s: %s head %s conflicts with %s %s in %s. Merge origin/%s into the branch with a real merge commit (no force push), push, re-run the leg, re-file CONFIRM. waits-on=%s"
                       % (dt.datetime.now().strftime("%I:%M %p").lstrip("0"), key, head[:8], base, bsha[:8], ", ".join(files[:12]), base, owner))
                rec["belled"] = bell(owner, txt, dry=not apply)
                log("%s code-conflict files=%s %s" % (key, ",".join(files[:12]), rec["belled"]))
            else:
                rec["belled"] = prev["belled"]
        st["prs"][key] = rec
    # forget closed PRs
    live = {"%s#%d" % (repo, pr["number"]) for pr in prs}
    for k in [k for k in st["prs"] if k.startswith(repo + "#") and k not in live]:
        del st["prs"][k]


def run_local(path, base, heads):
    git_dir = sh(["git", "-C", path, "rev-parse", "--git-dir"]).stdout.strip()
    git_dir = git_dir if os.path.isabs(git_dir) else os.path.join(path, git_dir)
    bsha = sh(["git", "-C", path, "rev-parse", base]).stdout.strip()
    out = {}
    for h in heads:
        hsha = sh(["git", "-C", path, "rev-parse", h]).stdout.strip()
        clean, files = merge_tree(git_dir, bsha, hsha)
        out[h] = {"class": classify(files, None, git_dir, bsha, hsha), "files": files}
        print("%s %s %s" % (h, out[h]["class"], ",".join(files)))
    return out


def selftest():
    global HOME, STATE
    d = tempfile.mkdtemp(prefix="pcw-selftest-", dir=os.path.join(os.path.expanduser("~"), ".cache"))
    HOME = d; STATE = os.path.join(d, "state")
    repo = os.path.join(d, "repo"); os.makedirs(repo)
    g = lambda *a, **k: sh(["git", "-C", repo] + list(a), **k)
    g("init", "-q", "-b", "main"); g("config", "user.email", "t@t"); g("config", "user.name", "t")
    w = lambda f, s: open(os.path.join(repo, f), "w").write(s)
    w("uv.lock", "v1\n"); w("CHANGELOG.md", "# log\n- a\n"); w("app.py", "x = 1\n"); g("add", "-A"); g("commit", "-qm", "base")
    g("checkout", "-qb", "lockonly"); w("uv.lock", "v1-branch\n"); w("CHANGELOG.md", "# log\n- a\n- branch\n"); w("new.py", "y\n"); g("add", "-A"); g("commit", "-qm", "lockonly")
    g("checkout", "-q", "main"); g("checkout", "-qb", "codeconf"); w("app.py", "x = 3\n"); g("add", "-A"); g("commit", "-qm", "codeconf")
    g("checkout", "-q", "main"); g("checkout", "-qb", "clean"); w("other.py", "z\n"); g("add", "-A"); g("commit", "-qm", "clean")
    g("checkout", "-q", "main"); w("Cargo.toml", '[package]\nname = "x"\nversion = "0.1.0"\n'); g("add", "-A"); g("commit", "-qm", "cargo on main")
    g("checkout", "-qb", "verbump"); w("Cargo.toml", '[package]\nname = "x"\nversion = "0.2.0"\n[dependencies]\nserde = "1"\n'); g("add", "-A"); g("commit", "-qm", "verbump")
    g("checkout", "-q", "main"); w("Cargo.toml", '[package]\nname = "x"\nversion = "0.3.0"\n'); g("add", "-A"); g("commit", "-qm", "main bumps")
    g("checkout", "-q", "main"); w("uv.lock", "v2\n"); w("CHANGELOG.md", "# log\n- a\n- main\n"); w("app.py", "x = 2\n"); g("add", "-A"); g("commit", "-qm", "main moves")
    res = run_local(repo, "main", ["lockonly", "codeconf", "clean", "verbump"])
    chk0 = res["verbump"]["class"]
    ok = True
    def chk(c, msg):
        nonlocal ok
        print(("PASS " if c else "FAIL ") + msg); ok = ok and c
    chk(res["clean"]["class"] == "clean", "clean branch classified clean")
    chk(chk0 == "generated" and res["verbump"]["files"] == ["Cargo.toml"], "version-line-only Cargo.toml conflict classified generated")
    chk(res["codeconf"]["class"] == "code" and res["codeconf"]["files"] == ["app.py"], "code conflict names app.py")
    chk(res["lockonly"]["class"] == "generated" and sorted(res["lockonly"]["files"]) == ["CHANGELOG.md", "uv.lock"], "lockfile+changelog conflict classified generated")
    # auto-merge into a bare mirror with a real push (local remote = same bare repo)
    mirror = os.path.join(d, "mirror.git"); sh(["git", "clone", "-q", "--mirror", repo, mirror])
    head = g("rev-parse", "lockonly").stdout.strip()
    new = auto_merge(mirror, "refs/heads/main", head, "lockonly", ["uv.lock", "CHANGELOG.md"], mirror, dry=False)
    tip = sh(["git", "--git-dir", mirror, "rev-parse", "refs/heads/lockonly"]).stdout.strip()
    chk(tip == new, "pushed branch tip is the merge commit (no force)")
    parents = sh(["git", "--git-dir", mirror, "rev-list", "--parents", "-n1", new]).stdout.split()
    chk(len(parents) == 3 and head in parents, "real merge commit with the old head as a parent")
    lock = sh(["git", "--git-dir", mirror, "show", new + ":uv.lock"]).stdout
    chk(lock == "v2\n", "lockfile taken from main")
    cl = sh(["git", "--git-dir", mirror, "show", new + ":CHANGELOG.md"]).stdout
    chk("- branch" in cl and "- main" in cl, "changelog union keeps both lines")
    chk(sh(["git", "--git-dir", mirror, "show", new + ":new.py"]).stdout == "y\n", "branch file kept")
    clean2, files2 = merge_tree(mirror, sh(["git", "--git-dir", mirror, "rev-parse", "refs/heads/main"]).stdout.strip(), new)
    chk(clean2, "merged branch is clean against main")
    try:
        auto_merge(mirror, "refs/heads/main", g("rev-parse", "codeconf").stdout.strip(), "codeconf", ["app.py"], mirror, dry=False)
        chk(False, "code conflict refused by auto_merge")
    except RuntimeError as e:
        chk("unexpected code conflict" in str(e), "code conflict refused by auto_merge")
    chk(sh(["git", "--git-dir", mirror, "rev-parse", "refs/heads/codeconf"]).stdout.strip() == g("rev-parse", "codeconf").stdout.strip(), "refused merge left codeconf untouched")
    newv = auto_merge(mirror, "refs/heads/main", g("rev-parse", "verbump").stdout.strip(), "verbump", ["Cargo.toml"], mirror, dry=False)
    ct = sh(["git", "--git-dir", mirror, "show", newv + ":Cargo.toml"]).stdout
    chk('version = "0.3.0"' in ct and 'serde = "1"' in ct, "version conflict: main's version kept, branch's dependency edit kept")
    shutil.rmtree(d, ignore_errors=True)
    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="push auto-merges and bell owners (default: dry-run)")
    ap.add_argument("--repos", default=",".join(REPOS))
    ap.add_argument("--include-daemon", action="store_true")
    ap.add_argument("--local"); ap.add_argument("--base", default="main"); ap.add_argument("--heads", default="")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.local:
        run_local(a.local, a.base, [h for h in a.heads.split(",") if h]); return 0
    st = load_state()
    counts = {"prs": 0, "clean": 0, "generated": 0, "code": 0, "auto_merged": 0, "skipped": 0}
    repos = [r for r in a.repos.split(",") if r]
    for repo in repos:
        try:
            run_repo(repo, a.apply, st, counts, a.include_daemon)
        except Exception as e:  # one repo's failure never hides the others
            log("%s ERROR %s" % (repo, str(e)[-300:]))
    st["summary"] = dict(counts, repos=len(repos), ts=dt.datetime.now().isoformat(timespec="seconds"), mode="apply" if a.apply else "dry-run")
    save_state(st)
    log("SUMMARY " + " ".join("%s=%s" % kv for kv in st["summary"].items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
