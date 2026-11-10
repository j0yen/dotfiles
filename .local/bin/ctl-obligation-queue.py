#!/usr/bin/env python3
"""ctl-obligation-queue: obligation-aware work selection (task A1289).

Reads the canonical open asks (wm-asks asks query --json --status open) and, if
available, wm-decide followups; classifies each obligation by priority class and
readiness; records start decisions in an append-only jsonl; observes discretionary
starts that bypassed actionable higher-priority work.

Priority class: 1 safety/security/data-integrity/prod/recovery or cross-task
unblocker; 2 authorized unblocked overdue commitment; 3 discretionary/other.
Readiness: ready | blocked (exact dependency + owner + evidence) | triage defect
(blocker language with no structured waits-on token: NOT runnable) | deferred
(explicit not-before in the future) | active (claim held; never duplicated).

Exit codes: 0 ok, 2 usage, 3 REFUSE, 4 canonical source unavailable (no fallback),
5 task already actively claimed.
"""
import argparse, datetime, json, os, re, subprocess, sys

EXIT_REFUSE, EXIT_SOURCE, EXIT_ACTIVE = 3, 4, 5
CLASS1 = re.compile(r"\b(security|secur\w*|leak\w*|credential\w*|data[- ]integrity|data[- ]loss|corrupt\w*|"
                    r"prod|production|outage|recovery|restore|backup|incident|rollback)\b", re.I)
DISCRETIONARY = re.compile(r"\b(discretionary|nice[- ]to[- ]have|optional|new idea)\b", re.I)
BLOCKER_WORDS = re.compile(r"\b(blocked|waiting (?:on|for)|waits? on|stuck|depends on)\b", re.I)
TOKEN = re.compile(r"waits-on=([A-Za-z0-9_]+):(\S+)")
CLAIM = re.compile(r"\bclaim=(\S+)")
NOTBEFORE = re.compile(r"not[-_]before=(\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2})?)")
CLASS_NAMES = {"safety": 1, "unblocker": 1, "overdue": 2, "discretionary": 3}


def norm_ts(s):
    if not s:
        return None
    s = str(s).replace(" ", "T")
    return s + "T00:00" if len(s) == 10 else s[:16]


def die_source(msg):
    print("canonical source unavailable: %s" % msg, file=sys.stderr)
    sys.exit(EXIT_SOURCE)


def load_source(args):
    """Return (asks, followups, now, source). No fallback of any kind."""
    now = norm_ts(args.now) or datetime.datetime.now().strftime("%Y-%m-%dT%H:%M")
    fx = os.environ.get("CTL_OQ_FIXTURE") if args.test else None
    if fx:
        try:
            d = json.load(open(fx))
        except Exception as e:
            die_source("fixture %s: %s" % (fx, e))
        return d["asks"], d.get("followups"), norm_ts(args.now) or d.get("now") or now, "fixture"
    cmd = (os.environ.get("CTL_OQ_WM_ASKS") if args.test else None) or "wm-asks"
    try:
        r = subprocess.run([cmd, "asks", "query", "--json", "--status", "open"],
                           capture_output=True, text=True, timeout=120)
    except Exception as e:
        die_source("%s: %s" % (cmd, e))
    if r.returncode != 0:
        die_source("%s exit %d: %s" % (cmd, r.returncode, r.stderr.strip()[:200]))
    try:
        asks = json.loads(r.stdout)
        assert isinstance(asks, list) and all(isinstance(a, dict) and "ask_id" in a for a in asks)
    except Exception as e:
        die_source("unparseable ledger output: %s" % e)
    fu = None
    try:
        f = subprocess.run(["wm-decide", "followups", "--json"], capture_output=True, text=True, timeout=120)
        if f.returncode == 0:
            fu = json.loads(f.stdout)
    except Exception:
        fu = None
    return asks, fu, now, "wm-asks"


def classify(asks, now):
    open_ids = set()
    for a in asks:
        open_ids.add(a["ask_id"])
        if a.get("row_id"):
            open_ids.add(a["row_id"])
    # per-row dependencies
    deps = {}
    for a in asks:
        seg = (a.get("what") or "").split(" | ")[0]
        toks = []  # (kind, value, source)
        for t in a.get("waits_on") or []:
            if ":" in t:
                k, v = t.split(":", 1)
                toks.append((k, v, "structured"))
            else:
                toks.append(("row", t, "structured"))
        for k, v in TOKEN.findall(seg):
            toks.append((k, v.rstrip(".,;)"), "text"))
        deps[a["ask_id"]] = (seg, toks)
    unblockers = {}  # open dep id -> dependents
    for aid, (seg, toks) in deps.items():
        for k, v, _ in toks:
            if k == "row" and v in open_ids and v != aid:
                unblockers.setdefault(v, []).append(aid)

    out = {"queue": [], "blocked": [], "active": [], "deferred": [], "triage_defects": [],
           "evidence_free_blockers": []}
    for a in asks:
        aid = a["ask_id"]
        seg, toks = deps[aid]
        base = {"ask_id": aid, "row_id": a.get("row_id"), "owner": a.get("owner"), "due": a.get("due"),
                "summary": seg[:160]}
        due = norm_ts(a.get("due"))
        overdue = bool(due and due <= now)
        if aid in unblockers or (a.get("row_id") in unblockers):
            cls, why = 1, "cross-task unblocker of " + ",".join(unblockers.get(aid) or unblockers.get(a.get("row_id")))
        elif CLASS1.search(seg + " " + (a.get("key") or "")) and not DISCRETIONARY.search(seg):
            cls, why = 1, "safety/security/data/prod/recovery keyword"
        elif DISCRETIONARY.search(seg):
            cls, why = 3, "discretionary marker"
        elif overdue:
            cls, why = 2, "authorized overdue commitment (due %s)" % a.get("due")
        else:
            cls, why = 3, "not overdue, no priority marker"
        base.update({"class": cls, "class_reason": why, "overdue": overdue})
        cm = CLAIM.search(seg)
        claim = a.get("claim") or (cm.group(1) if cm else None)
        if claim:
            out["active"].append(dict(base, claim=claim))
            continue
        nb = norm_ts(a.get("not_before"))
        m = NOTBEFORE.search(seg)
        if m:
            nb = norm_ts(m.group(1))
        if nb and nb > now:
            out["deferred"].append(dict(base, not_before=nb))
            continue
        blocker = None
        for k, v, src in toks:
            if k == "row":
                if v in open_ids and v != aid:
                    blocker = {"dependency": "row:" + v, "dependency_owner": next(
                        (x.get("owner") for x in asks if x["ask_id"] == v or x.get("row_id") == v), None),
                        "evidence": "row %s is still open" % v}
                    break
            else:
                tail = seg.split("waits-on=%s:%s" % (k, v), 1)[-1].strip(" :;,.-") if src == "text" else ""
                blocker = {"dependency": "%s:%s" % (k, v), "dependency_owner": v.rstrip(".,;)"),
                           "evidence": tail[:200]}
                break
        if blocker:
            out["blocked"].append(dict(base, **blocker))
            if blocker["dependency"].split(":")[0] != "row" and len(blocker["evidence"]) < 15:
                out["evidence_free_blockers"].append(dict(base, dependency=blocker["dependency"]))
            continue
        if BLOCKER_WORDS.search(seg):
            out["triage_defects"].append(dict(base, defect="blocker language without structured waits-on token"))
            continue
        out["queue"].append(base)
    out["queue"].sort(key=lambda x: (x["class"], x["due"] or "9999", x["ask_id"]))
    out["_unblockers"] = {k: v for k, v in unblockers.items()}
    return out


def state_dir(args):
    if args.test and os.environ.get("CTL_OQ_STATE"):
        return os.environ["CTL_OQ_STATE"]
    return os.path.expanduser("~/.local/state/ctl-obligation")


def read_decisions(args):
    p = os.path.join(state_dir(args), "decisions.jsonl")
    if not os.path.exists(p):
        return []
    rows = []
    for line in open(p):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return rows


def fu_summary(fu):
    if isinstance(fu, dict):
        return {"available": True, "count": len(fu.get("ids") or []), "escalated": fu.get("escalated")}
    if isinstance(fu, list):
        return {"available": True, "count": len(fu), "escalated": None}
    return {"available": False, "count": None, "escalated": None}


def snapshot(args):
    asks, fu, now, source = load_source(args)
    c = classify(asks, now)
    c.update({"now": now, "source": source, "open_total": len(asks),
              "overdue_total": sum(1 for a in asks if norm_ts(a.get("due")) and norm_ts(a.get("due")) <= now),
              "followups": fu_summary(fu)})
    return c


def cmd_queue(args):
    c = snapshot(args)
    pub = {k: v for k, v in c.items() if not k.startswith("_")}
    if args.json:
        print(json.dumps(pub, indent=1))
    else:
        print(render_md(pub, read_decisions(args), args.top))
    return 0


def render_md(c, decisions, top):
    L = ["# Obligation queue", "",
         "Generated %s from %s. Open rows %d, overdue %d, ready %d, blocked %d, active %d, deferred (not-before) %d, "
         "triage defects %d. Followups (wm-decide): %s (escalated %s)." % (
             c["now"], c["source"], c["open_total"], c["overdue_total"], len(c["queue"]), len(c["blocked"]),
             len(c["active"]), len(c["deferred"]), len(c["triage_defects"]),
             c["followups"]["count"] if c["followups"]["available"] else "unavailable",
             c["followups"]["escalated"]), "",
         "Counts are not a disposition; no row here is closed, re-dated or imported by this report.", "",
         "## Top %d executable queue" % top, "", "| # | id | class | owner | due | why | summary |", "|---|---|---|---|---|---|---|"]
    for i, x in enumerate(c["queue"][:top], 1):
        L.append("| %d | %s | %d | %s | %s | %s | %s |" % (i, x["ask_id"], x["class"], x["owner"], x["due"],
                                                         x["class_reason"], x["summary"].replace("|", "/")[:110]))
    L += ["", "## Blocked dependencies (dependency + owner + evidence)", ""]
    for x in c["blocked"]:
        L.append("- %s (class %d, owner %s) blocked on %s, dependency owner %s; evidence: %s" % (
            x["ask_id"], x["class"], x["owner"], x["dependency"], x["dependency_owner"],
            (x["evidence"] or "none")[:100].replace("\n", " ")))
    L += ["", "## Blockers without evidence (owned triage defects; ids only, not edited)", ""]
    ids = [x["ask_id"] for x in c["evidence_free_blockers"]] + [x["ask_id"] for x in c["triage_defects"]]
    L.append(", ".join(ids) if ids else "none")
    L += ["", "## Active claims (not duplicated)", ""]
    for x in c["active"]:
        L.append("- %s owner %s claim %s" % (x["ask_id"], x["owner"], x["claim"]))
    if not c["active"]:
        L.append("none")
    L += ["", "## Deferred by explicit not-before", ""]
    for x in c["deferred"]:
        L.append("- %s not-before %s" % (x["ask_id"], x["not_before"]))
    if not c["deferred"]:
        L.append("none")
    L += ["", "## Justified exceptions (decisions.jsonl)", ""]
    ex = [d for d in decisions if d.get("exception") and d.get("outcome") == "allowed"]
    for d in ex:
        e = d["exception"]
        L.append("- %s %s: %s; owner %s; approval %s; review trigger %s" % (
            d["ts"], d["task_id"], e["reason"], e["owner"], e["source_approval"], e["review_trigger"]))
    if not ex:
        L.append("none recorded")
    return "\n".join(L)


def cmd_decide(args):
    c = snapshot(args)
    tid = args.task_id
    actor = args.actor or os.environ.get("WM_SEAT") or "ctl"
    cls = CLASS_NAMES[args.cls]
    if any(x["ask_id"] == tid for x in c["active"]):
        print("REFUSE-ACTIVE: %s already holds an active claim; not duplicated" % tid)
        return EXIT_ACTIVE
    is_unblocker = tid in c["_unblockers"] or any(
        x.get("row_id") == tid for x in c["queue"] + c["blocked"] if x["row_id"] in c["_unblockers"])
    cands = []
    if cls == 3 and not is_unblocker:
        cands = [x["ask_id"] for x in c["queue"] if x["class"] < 3 and x["ask_id"] != tid
                 and (args.any_owner or x["owner"] == actor)]
    exc = None
    fields = [args.exception_reason, args.exception_owner, args.exception_approval, args.exception_review_trigger]
    if any(fields):
        exc = {"reason": args.exception_reason, "owner": args.exception_owner,
               "source_approval": args.exception_approval, "review_trigger": args.exception_review_trigger}
    exc_valid = bool(exc and all(fields))
    outcome = "allowed"
    why = "dependency repair" if is_unblocker else ("no actionable higher-priority candidate" if not cands else "")
    if cands and not exc_valid:
        outcome = "refused"
        why = "discretionary start bypasses actionable higher-priority candidates without a valid exception"
    elif cands:
        why = "valid priority exception"
    rec = {"ts": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"), "task_id": tid, "actor": actor,
           "priority_class": cls, "class_label": args.cls, "rationale": args.rationale,
           "higher_priority_candidates": cands, "dependency_repair": is_unblocker,
           "exception": exc, "exception_valid": exc_valid, "outcome": outcome, "decision_reason": why,
           "source": c["source"], "ledger_now": c["now"]}
    d = state_dir(args)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "decisions.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")
    if outcome == "refused":
        print("REFUSE: %s; candidates: %s" % (why, ", ".join(cands[:15]) + (" ..." if len(cands) > 15 else "")))
        return EXIT_REFUSE
    print("ALLOW: %s (%s)" % (tid, why))
    return 0


def cmd_observe(args):
    rows = [d for d in read_decisions(args) if d.get("class_label") == "discretionary"
            and d.get("outcome") == "allowed" and d.get("higher_priority_candidates")]
    if args.json:
        print(json.dumps({"bypasses": rows}, indent=1))
    else:
        for d in rows:
            print("%s %s bypassed %d higher-priority candidates (exception valid: %s)" % (
                d["ts"], d["task_id"], len(d["higher_priority_candidates"]), d["exception_valid"]))
        if not rows:
            print("no discretionary start bypassed actionable higher-priority work")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--test", action="store_true", help="honour CTL_OQ_FIXTURE / CTL_OQ_STATE / CTL_OQ_WM_ASKS")
    ap.add_argument("--now")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for n in ("queue", "report"):
        p = sub.add_parser(n)
        p.add_argument("--json", action="store_true")
        p.add_argument("--top", type=int, default=15)
        p.set_defaults(fn=cmd_queue)
    sub.choices["report"].set_defaults(fn=cmd_queue, json=False)
    d = sub.add_parser("decide")
    d.add_argument("task_id")
    d.add_argument("--class", dest="cls", required=True, choices=sorted(CLASS_NAMES))
    d.add_argument("--rationale", default="")
    d.add_argument("--actor")
    d.add_argument("--any-owner", action="store_true")
    d.add_argument("--exception-reason")
    d.add_argument("--exception-owner")
    d.add_argument("--exception-approval")
    d.add_argument("--exception-review-trigger")
    d.set_defaults(fn=cmd_decide)
    o = sub.add_parser("observe")
    o.add_argument("--json", action="store_true")
    o.set_defaults(fn=cmd_observe)
    a = ap.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
