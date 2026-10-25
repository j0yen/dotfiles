#!/usr/bin/env bash
# hand-pr-land-driver.sh: the unattended driver for HAND PRs (j0yen/synthorg, mcphost, wm-build PRs the daemon does not land).
# Source: five-whys page ~/Notes/wiki/answers/2026-10-24-wo16-3of7-after-34h-five-whys-rhyme.md, Mechanism 1 + Amendments 10 (twin of ~/.cache/rb-seat/manual-train.py;
# the plain-session hand run of #414/#416 took master-merge -> MERGED in 22 min, after #414 waited 27 h for a re-verify nobody issued).
#
# One TICK (timer, 10 min, carbon) walks every OPEN PR (headRefName not wm-build/*) of the three repos that has a `GATED <repo>#<pr>` row with exactly one COMMIT=<40 hex>
# (latest such row wins) and takes AT MOST ONE action per PR:
#   (e) live head != the GATED row's COMMIT      -> ring the owning seat ONCE (key moved), never verify
#   (b) a verifier unit for that head is finished  -> lint its verdict through the LIVE gate code (mergegate.check, read-only), then `aide-verifier.sh finish`
#   (c) a MERGE-OK verdict row whose COMMIT prefixes the live head (not voided by a CORRECT* row) -> `rb-merge.sh <verdict> <pr> <repo>` (gate, trailer check, squash merge)
#   (a) no current verdict, no active verifier unit for the PR -> ROOM check (carbon-room.sh 1024 --reserve-MB 3072), then `aide-verifier.sh launch` (fast CI tier by default;
#       `TIER=full` in the GATED row -> full pytest + --timeout 5400). Only synthorg has an unattended suite on carbon (cargo never fits); the other repos ring the owner once.
# and, once per merged PR (merge-events.jsonl pr-merged, last HPLD_POSTMERGE_WINDOW_H h):
#   (d) merged >= 15 min ago, no r7 `START` row naming the PR since the merge -> `seat-ask.sh r7 '<repo>#<pr> merged <sha>; run post-merge suite'` ONCE.
# Every action writes a ledger row (kind=observe, what `HPLD <ACTION> <repo>#<pr> k=<key> ...`). The wm-decide agent enum has no `hand-pr-land-driver`, so the row's agent is
# `coder:hand-pr-land-driver` (the enum's per-job pattern) and via=hand-pr-land-driver. The `k=<key>` token is the idempotency key: a key already in the ledger is never acted on again;
# rings write their row BEFORE the ring. A flock keeps two ticks from overlapping. Launch refusals that are transient (ROOM no, ceiling, 429 breaker, not head-of-line) write no row and retry next tick.
# NEVER: merge without a gate PASS (rb-merge.sh is the only merge path), force, touch a hold, kill by pattern, print a token.
#   --dry-run   print the planned actions (PLAN lines), change nothing (no lock, no row, no launch, no ring, no ROOM call)
#   --selftest  pure-function checks (GATED grammar, keys, owner map, suite shape); tests/hand-pr-land-driver.test.sh runs the stubbed end-to-end cases
# Env (tests): HPLD_STATE_DIR HPLD_WMD HPLD_GH HPLD_VERIFIER HPLD_RBMERGE HPLD_SEATASK HPLD_ROOM HPLD_SYSTEMCTL HPLD_VDIR HPLD_EVENTS HPLD_SINCE HPLD_REPOS HPLD_TOKEN HPLD_LINT_CMD HPLD_NOW HPLD_POSTMERGE_WINDOW_H
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
STATE_DIR="${HPLD_STATE_DIR:-$HOME/.local/state/hand-pr-land-driver}"
MODE=run
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --selftest) MODE=selftest ;;
  "") ;;
  *) echo "usage: hand-pr-land-driver.sh [--dry-run|--selftest]" >&2; exit 64 ;;
esac
if [ "$MODE" = run ]; then
  mkdir -p "$STATE_DIR" || exit 1
  exec 9>"$STATE_DIR/tick.lock"
  flock -n 9 || { echo "hand-pr-land-driver: another tick holds the lock; exiting"; exit 0; }
fi
export HPLD_MODE="$MODE"
exec python3 -I -c "$(sed -n '/^#PY-BEGIN$/,/^#PY-END$/p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed '1d;$d')"
#PY-BEGIN
import datetime as dt, json, os, re, shlex, subprocess, sys, time

MODE = os.environ["HPLD_MODE"]
HOME = os.path.expanduser("~")
WMD = os.environ.get("HPLD_WMD", "wm-decide")
GH = os.environ.get("HPLD_GH", "gh")
VERIFIER = os.environ.get("HPLD_VERIFIER", "aide-verifier.sh")
RBMERGE = os.environ.get("HPLD_RBMERGE", "rb-merge.sh")
SEATASK = os.environ.get("HPLD_SEATASK", "seat-ask.sh")
ROOM = os.environ.get("HPLD_ROOM", "carbon-room.sh")
SYSCTL = os.environ.get("HPLD_SYSTEMCTL", "systemctl")
VDIR = os.environ.get("HPLD_VDIR", os.path.join(HOME, ".local/state/aide-verifier"))
EVENTS = os.environ.get("HPLD_EVENTS", os.path.join(HOME, ".local/state/swarm-decide/merge-events.jsonl"))
SINCE = os.environ.get("HPLD_SINCE", "7d")
REPOS = os.environ.get("HPLD_REPOS", "j0yen/synthorg j0yen/mcphost j0yen/wm-build").split()
PM_WINDOW_H = float(os.environ.get("HPLD_POSTMERGE_WINDOW_H", "3"))
PM_WAIT_S = 15 * 60
MAX_LAUNCHES, MAX_LAUNCH_FAILS = 2, 3
AGENT, VIA = "coder:hand-pr-land-driver", "hand-pr-land-driver"
SUITE_REPOS = {"j0yen/synthorg"}   # repos with a suite that fits on carbon; cargo repos never do
HEX40 = re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{40}(?![0-9a-fA-F])")
COMMIT_RE = re.compile(r"COMMIT=([0-9a-fA-F]{7,40})")
KEY_RE = re.compile(r" k=(\S+)")
SEAT_OF = {"rb": "rb", "r7": "r7", "controller": "ctl", "ctl": "ctl"}   # anything else (aide, joe, coder:*) -> r7, the hand-PR consumer


def now():
    return float(os.environ["HPLD_NOW"]) if os.environ.get("HPLD_NOW") else time.time()


def ts_epoch(s):
    try:
        return dt.datetime.fromisoformat(s).timestamp()
    except (ValueError, TypeError):
        return 0.0


def sh(argv, timeout=900):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


def log(msg):
    print(msg, flush=True)


def gated_re(repo, pr):
    return re.compile(r"(?<![A-Za-z0-9_.-])GATED\s+%s#%s(?![0-9])" % (re.escape(repo), pr))


def gated_commit(what, repo, pr):
    """The row's one COMMIT=<40 hex> (lowercased), or None when the row is not a GATED row for repo#pr or carries 0 / >1 / a short commit."""
    if not what or not gated_re(repo, pr).search(what):
        return None
    cs = {m.group(1).lower() for m in COMMIT_RE.finditer(what)}
    if len(cs) != 1:
        return None
    c = next(iter(cs))
    return c if len(c) == 40 else None


def owner_seat(agent):
    return SEAT_OF.get(agent or "", "r7")


def suite_for(repo, tier, own_tests):
    pre = "uv sync -q --frozen && uv run ruff check . && uv run mypy src && uv run synthorg promise lint"
    own = ""
    if own_tests:
        own = " && uv run pytest -q -p no:cacheprovider " + " ".join(shlex.quote(t) for t in own_tests)
    sel = "" if tier == "full" else ' -m "not flaky and not slow"'
    return "%s%s && uv run pytest -q -p no:cacheprovider%s -n 4" % (pre, own, sel)


def short(repo):
    return {"j0yen/synthorg": "syn", "j0yen/mcphost": "mcp", "j0yen/wm-build": "wmb"}.get(repo, re.sub(r"[^a-z0-9]", "", repo.split("/")[-1].lower())[:4])


def selftest():
    bad = []

    def chk(name, ok):
        print(("PASS " if ok else "FAIL ") + name)
        if not ok:
            bad.append(name)
    h = "a" * 40
    chk("GATED row with one COMMIT=40hex", gated_commit("GATED j0yen/synthorg#414 COMMIT=%s x" % h, "j0yen/synthorg", 414) == h)
    chk("#41 does not match GATED #414", gated_commit("GATED j0yen/synthorg#414 COMMIT=%s" % h, "j0yen/synthorg", 41) is None)
    chk("two different COMMITs refused", gated_commit("GATED j0yen/synthorg#4 COMMIT=%s COMMIT=%s" % (h, "b" * 40), "j0yen/synthorg", 4) is None)
    chk("short COMMIT refused", gated_commit("GATED j0yen/synthorg#4 COMMIT=abcdef1", "j0yen/synthorg", 4) is None)
    chk("prefix-glued GATED refused", gated_commit("NOGATED j0yen/synthorg#4 COMMIT=%s" % h, "j0yen/synthorg", 4) is None)
    chk("owner map", owner_seat("rb") == "rb" and owner_seat("controller") == "ctl" and owner_seat("aide") == "r7")
    chk("fast suite carries the marker filter, full does not", '-m "not flaky and not slow"' in suite_for("j0yen/synthorg", "fast", []) and "-m " not in suite_for("j0yen/synthorg", "full", []))
    chk("own tests quoted", "tests/a_test.py" in suite_for("j0yen/synthorg", "fast", ["tests/a_test.py"]))
    chk("unit name charset", re.fullmatch(r"[a-z0-9-]+", "hpl-%s-%d-%s-%d" % (short("j0yen/synthorg"), 4, "abcdef0", 1)) is not None)
    print("SELFTEST " + ("FAIL" if bad else "PASS"))
    return 1 if bad else 0


if MODE == "selftest":
    sys.exit(selftest())

# ---------------------------------------------------------------- read side (read-only; also runs in --dry-run)
rc, out, err = sh([WMD, "list", "--since", SINCE, "--json"], 300)
if rc != 0:
    log("hand-pr-land-driver: wm-decide list failed rc=%d: %s" % (rc, err.strip()[:200]))
    sys.exit(1)
rows = sorted(json.loads(out), key=lambda r: r.get("ts") or "")
by_id = {r["id"]: r for r in rows}
hp_keys = set()
for r in rows:
    w = r.get("what") or ""
    if w.startswith("HPLD "):
        m = KEY_RE.search(w)
        if m:
            hp_keys.add(m.group(1))


def count_keys(prefix):
    return sum(1 for k in hp_keys if k.startswith(prefix))


def verifier_units():
    """[{name, repo, pr, head, gated, agent, active, finished(text|None), has_result}] from the unit dirs."""
    res = []
    try:
        names = sorted(os.listdir(VDIR))
    except OSError:
        return res
    for n in names:
        d = os.path.join(VDIR, n)
        try:
            meta = dict(l.rstrip("\n").split("=", 1) for l in open(os.path.join(d, "meta")) if "=" in l)
        except OSError:
            continue
        agent = meta.get("agent") or "aide"
        unit = "%s-verifier-%s.service" % (agent, n)
        rc_, o_, _ = sh([SYSCTL, "--user", "is-active", unit], 30)
        fin = None
        try:
            fin = open(os.path.join(d, "finished")).read().strip()
        except OSError:
            pass
        res.append({"name": n, "repo": meta.get("repo"), "pr": meta.get("pr"), "head": (meta.get("head") or "").lower(), "gated": meta.get("gated"),
                    "agent": agent, "active": o_.strip() in ("active", "activating"), "finished": fin,
                    "has_result": os.path.getsize(os.path.join(d, "result.json")) > 0 if os.path.exists(os.path.join(d, "result.json")) else False})
    return res


units = verifier_units()
actions = []   # planned, in order; ONE per PR


def own_tests(repo, pr):
    rc_, o_, _ = sh([GH, "api", "repos/%s/pulls/%s/files" % (repo, pr), "--paginate", "-q", '.[] | select(.status != "removed") | .filename'], 120)
    if rc_ != 0:
        return []
    return [f for f in o_.split() if re.fullmatch(r"tests/[A-Za-z0-9_./-]+\.py", f)][:10]


def verdict_id_of_unit(u):
    try:
        res = json.load(open(os.path.join(VDIR, u["name"], "result.json")))
    except (OSError, ValueError):
        return None
    text = res.get("result") or ""
    ids = [i for i in re.findall(r"d-[0-9]{8}-[0-9]{6}-%s-[0-9a-f]{4}" % re.escape(u["agent"]), text) if i != u["gated"]]
    return ids[-1] if ids else None


for repo in REPOS:
    rc, out, err = sh([GH, "pr", "list", "--repo", repo, "--state", "open", "--limit", "100", "--json", "number,headRefOid,headRefName"], 120)
    if rc != 0:
        log("hand-pr-land-driver: gh pr list %s failed rc=%d: %s" % (repo, rc, err.strip()[:200]))
        continue
    for pr_o in json.loads(out):
        pr, live, branch = int(pr_o["number"]), pr_o["headRefOid"].lower(), pr_o.get("headRefName") or ""
        if branch.startswith("wm-build/"):
            continue   # a daemon land, not a hand PR
        grows = [r for r in rows if r.get("kind") != "verdict" and gated_commit(r.get("what"), repo, pr)]
        if not grows:
            continue
        g = grows[-1]
        gc = gated_commit(g["what"], repo, pr)
        tier = "full" if re.search(r"(?i)(?<![A-Za-z0-9])TIER=full\b", g["what"]) else "fast"
        owner = owner_seat(g.get("agent"))
        tag = "%s#%d" % (repo, pr)
        base = {"repo": repo, "pr": pr, "head": live, "gated": g["id"], "owner": owner, "tag": tag}
        if gc != live:
            k = "moved:%s:%s:%s" % (tag, g["id"], live[:12])
            if k not in hp_keys:
                actions.append(dict(base, act="ring-moved", key=k, msg="%s: head moved since GATED %s (%s -> %s); re-GATE the new head, the hand-pr-land-driver verifies only a GATED head" % (tag, g["id"], gc[:12], live[:12])))
            continue
        pr_units = [u for u in units if u["repo"] == repo and str(u["pr"]) == str(pr)]
        if any(u["active"] for u in pr_units):
            continue
        head_units = [u for u in pr_units if u["head"] == live]
        # (b) a finished unit with no finish yet
        pend = [u for u in head_units if not u["finished"] and u["has_result"] and "finish:%s" % u["name"] not in hp_keys and "finishlint:%s" % u["name"] not in hp_keys]
        if pend:
            u = pend[-1]
            actions.append(dict(base, act="finish", key="finish:%s" % u["name"], unit=u["name"], verdict=verdict_id_of_unit(u)))
            continue
        # (c) a current MERGE-OK verdict for the live head
        vs = []
        pr_ref = re.compile(r"(?<![A-Za-z0-9_.-])(?:%s|%s)#%d(?![0-9])" % (re.escape(repo), re.escape(repo.split("/")[-1]), pr))
        for r in rows:
            w = r.get("what") or ""
            if r.get("kind") != "verdict" or not w.startswith("MERGE-OK") or not pr_ref.search(w):
                continue
            m = COMMIT_RE.search(w)
            if not m or not live.startswith(m.group(1).lower()) or (r["ts"] or "") <= (g["ts"] or ""):
                continue
            if any(x.get("gates") == r["id"] and re.match(r"(?i)\s*CORRECT", x.get("what") or "") for x in rows):
                continue   # voided by a CORRECT / CORRECT-SCOPE row
            vs.append(r)
        if vs:
            v = vs[-1]
            if "merge:%s" % v["id"] not in hp_keys:
                actions.append(dict(base, act="merge", key="merge:%s" % v["id"], verdict=v["id"]))
            continue
        # (a) verify the live head
        pfx = "%s:%s:" % (tag, live[:12])
        launches, fails = count_keys("launch:" + pfx), count_keys("launchfail:" + pfx)
        if any("finishlint:%s" % u["name"] in hp_keys for u in head_units):
            continue   # the lint refusal already rang the owner; a hand look decides, no relaunch
        gate_failed = any("FAIL" in (u["finished"] or "") for u in head_units)
        if repo not in SUITE_REPOS:
            k = "nosuite:%s" % pfx
            if k not in hp_keys:
                actions.append(dict(base, act="ring-nosuite", key=k, msg="%s: GATED head %s has no unattended suite on carbon (cargo repo); verify it by hand on its build host" % (tag, live[:12])))
            continue
        if gate_failed or launches >= MAX_LAUNCHES or fails >= MAX_LAUNCH_FAILS:
            k = "stuck:%s" % pfx
            if k not in hp_keys:
                actions.append(dict(base, act="ring-stuck", key=k, msg="%s: driver gave up on head %s (launches=%d, launch-fails=%d, gate-failed=%s); needs a hand look" % (tag, live[:12], launches, fails, gate_failed)))
            continue
        n = launches + 1
        name = "hpl-%s-%d-%s-%d" % (short(repo), pr, live[:7], n)
        actions.append(dict(base, act="launch", key="launch:%s%d" % (pfx, n), fkey="launchfail:%s%d" % (pfx, fails + 1), name=name, tier=tier,
                            suite=suite_for(repo, tier, own_tests(repo, pr))))

# (d) post-merge suite ring
try:
    events = [json.loads(l) for l in open(EVENTS) if l.strip()]
except OSError:
    events = []
for e in events:
    if e.get("event") != "pr-merged" or e.get("repo") not in REPOS:
        continue
    t = ts_epoch(e.get("ts"))
    if now() - t < PM_WAIT_S or now() - t > PM_WINDOW_H * 3600:
        continue
    repo, pr, oid = e["repo"], e["pr"], e.get("oid") or ""
    tag = "%s#%s" % (repo, pr)
    k = "postmerge:%s:%s" % (tag, oid[:12])
    if k in hp_keys:
        continue
    pat = re.compile(r"(?<![0-9])%s(?![0-9])" % re.escape(str(pr)))
    if any(r.get("agent") == "r7" and (r.get("what") or "").startswith("START") and ts_epoch(r.get("ts")) >= t and pat.search(r["what"]) for r in rows):
        continue
    actions.append({"act": "ring-postmerge", "repo": repo, "pr": pr, "head": oid, "owner": "r7", "tag": tag, "key": k,
                    "msg": "%s merged %s; run post-merge suite" % (tag, oid)})

# ---------------------------------------------------------------- act side
if MODE == "dry":
    if not actions:
        log("PLAN none")
    for a in actions:
        extra = {x: a[x] for x in ("unit", "verdict", "name", "tier", "msg") if x in a}
        if a["act"] == "launch":
            extra["suite"] = a["suite"]
            extra["room"] = "would run: %s 1024 --reserve-MB 3072" % ROOM
        log("PLAN %s %s k=%s %s" % (a["act"], a["tag"], a["key"], json.dumps(extra)))
    sys.exit(0)


def record(act, a, tail, key=None):
    what = "HPLD %s %s k=%s %s" % (act.upper(), a["tag"], key or a["key"], tail)
    rc_, o_, e_ = sh([WMD, "record", "--agent", AGENT, "--via", VIA, "--kind", "observe", "--what", what[:1500],
                      "--why", "hand-pr-land-driver (five-whys 2026-10-24-wo16-3of7 mechanism 1): a hand PR must not wait for a keystroke",
                      "--evidence", "tick %s; head %s" % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now())), a.get("head", "")),
                      "--reverse-text", "none (observation row)"], 120)
    if rc_ != 0:
        log("hand-pr-land-driver: LEDGER ROW FAILED rc=%d: %s" % (rc_, e_.strip()[:200]))
    return rc_ == 0


def ring(a, seat):
    rc_, o_, e_ = sh([SEATASK, seat, a["msg"]], 120)
    log("RING %s -> %s rc=%d" % (a["tag"], seat, rc_))
    return rc_


def lint(verdict, repo, pr):
    """The LIVE gate code, read-only (mergegate.check): rc 0 clean, 2 refused (lines say why), 3 unusable (fail closed)."""
    cmd = os.environ.get("HPLD_LINT_CMD")
    if cmd:
        rc_, o_, e_ = sh(shlex.split(cmd) + [verdict, str(pr), repo], 120)
        return rc_, (o_ + e_).strip()
    p = sh(["bash", "-c", "command -v " + shlex.quote(WMD)], 10)[1].strip()
    if not p:
        return 3, "wm-decide not on PATH"
    root = os.path.dirname(os.path.dirname(os.path.realpath(p)))
    code = ("import sys; sys.path.insert(0, sys.argv[1])\n"
            "from wm_decide import store, mergegate\n"
            "db = store.connect(); f, w, i = mergegate.check(db, sys.argv[2], sys.argv[3], int(sys.argv[4]))\n"
            "[print(r + ': ' + m) for r, m in sorted(f.items())]\nsys.exit(2 if f else 0)\n")
    rc_, o_, e_ = sh(["python3", "-I", "-c", code, root, verdict, repo, str(pr)], 120)
    return (rc_ if rc_ in (0, 2) else 3), (o_ + e_).strip()[-400:]


def one_line(s, n=300):
    return " | ".join(l.strip() for l in s.strip().splitlines()[-4:])[:n]


for a in actions:
    act = a["act"]
    if act.startswith("ring-"):
        if record(act, a, "seat=%s %s" % (a["owner"], a["msg"][:300])):   # row first: a failed ring never repeats
            ring(a, a["owner"])
    elif act == "launch":
        room_rc, room_o, room_e = sh([ROOM, "1024", "--reserve-MB", "3072"], 60)
        if room_rc != 0:
            log("ROOM NO %s (carbon-room rc=%d): no launch this tick" % (a["tag"], room_rc))
            continue
        argv = [VERIFIER, "launch", a["name"], "--repo", a["repo"], "--pr", str(a["pr"]), "--head", a["head"], "--gated", a["gated"],
                "--token", os.environ.get("HPLD_TOKEN") or "pytest EXIT=0", "--suite", a["suite"]]
        if a["tier"] == "full":
            argv += ["--timeout", "5400"]
        rc_, o_, e_ = sh(argv, 600)
        txt = (o_ + e_)
        if rc_ == 0:
            log("LAUNCH %s %s" % (a["tag"], a["name"]))
            record("launch", a, "name=%s tier=%s gated=%s" % (a["name"], a["tier"], a["gated"]))
        elif rc_ in (3, 10, 11, 6) or (rc_ == 2 and re.search(r"(?i)ceiling|slot", txt)):
            log("LAUNCH DEFERRED %s rc=%d (transient): %s" % (a["tag"], rc_, one_line(txt)))
        else:
            log("LAUNCH FAILED %s rc=%d: %s" % (a["tag"], rc_, one_line(txt)))
            record("launchfail", a, "rc=%d %s" % (rc_, one_line(txt)), key=a["fkey"])
    elif act == "finish":
        if a.get("verdict"):
            lrc, ltxt = lint(a["verdict"], a["repo"], a["pr"])
            if lrc != 0:
                log("FINISH LINT %s verdict=%s rc=%d: %s" % (a["tag"], a["verdict"], lrc, one_line(ltxt)))
                if record("finish-lint-fail", a, "verdict=%s rc=%d %s" % (a["verdict"], lrc, one_line(ltxt)), key="finishlint:%s" % a["unit"]):
                    a["msg"] = "%s: verifier %s verdict %s fails the live gate lint (%s); not finished" % (a["tag"], a["unit"], a["verdict"], one_line(ltxt, 200))
                    ring(a, a["owner"])
                continue
        rc_, o_, e_ = sh([VERIFIER, "finish", a["unit"], "--pr", str(a["pr"]), "--repo", a["repo"]], 600)
        log("FINISH %s %s rc=%d" % (a["tag"], a["unit"], rc_))
        record("finish", a, "unit=%s rc=%d %s" % (a["unit"], rc_, one_line(o_ + e_, 200)))
    elif act == "merge":
        rc_, o_, e_ = sh([RBMERGE, a["verdict"], str(a["pr"]), a["repo"]], 900)
        m = re.search(r"oid=([0-9a-f]{40})", o_)
        sha = m.group(1) if m else ""
        if rc_ == 0:
            log("MERGED %s %s" % (a["tag"], sha))
            record("merged", a, "verdict=%s sha=%s" % (a["verdict"], sha))
        else:
            log("MERGE REFUSED %s rc=%d: %s" % (a["tag"], rc_, one_line(e_ + o_)))
            if record("merge-refused", a, "verdict=%s rc=%d %s" % (a["verdict"], rc_, one_line(e_ + o_, 250))):
                a["msg"] = "%s: rb-merge.sh %s refused rc=%d: %s" % (a["tag"], a["verdict"], rc_, one_line(e_ + o_, 200))
                ring(a, a["owner"])
sys.exit(0)
#PY-END
