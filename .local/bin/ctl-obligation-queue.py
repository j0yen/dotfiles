#!/usr/bin/env python3
"""ctl-obligation-queue: obligation-aware work selection (task A1289).

Reads ONE canonical snapshot of every ask (wm-asks asks query --json --status all:
open and closed rows, each with status, owner, rev and claim) and, if available,
wm-decide followups; classifies each OPEN obligation by priority class and readiness;
records start decisions in an append-only jsonl; observes claimed starts on open and
closed asks against those decisions. A row whose status is neither open nor closed is
an unknown schema: the source is refused (exit 4).

decide: the priority class is computed from the canonical row and its dependencies
(the same classifier as queue); --class is the caller's declaration, recorded as
class_label and never used as authority (class_supported says whether the row facts
support it). The higher-priority candidates are scoped by the task's canonical owner
(recorded as candidate_owner), never by the caller-declared --actor, which is recorded
as an unauthenticated label only. Every decision is recorded, including REFUSE and
REFUSE-ACTIVE, with an offset-aware ts, the row revision read (task_rev) and the
optional --worker that will claim the task. A task that is not open (closed or absent
from the ledger) is refused.

observe: the start evidence is the existing canonical claim, read through
`wm-asks asks query` (claim, rev) and `wm-asks asks events ID --json` (op=claim:
rev, ts, worker). The claim stamp is worker@YYYY-MM-DDTHH:MM (the worker token may
itself contain '@'). Each claimed ask, open or closed, is bound to the latest decision
recorded for the same task at the revision just before its claim event, at or before
the claim instant (both timestamps offset-aware; a ts without a UTC offset cannot be
ordered and stays UNKNOWN), and for the same worker when the decision named one. A
bound class-gated decision whose candidate scope is not the canonical owner is
re-checked: owner-scope-mismatch bypass when higher-priority work of the owner is ready
(computed at observe time), else UNKNOWN. Result per start:
allowed | valid-exception | dependency-repair (bound), bypass (unlogged-start: no
decision for the task; refused-then-started: the governing decision refused;
forged-class: a legacy allowed decision that trusted a declared class the row does
not support while higher-priority work was ready; owner-scope-mismatch), or unknown
(claim evidence cannot be bound: events unavailable/malformed, no or duplicate claim
event, non-canonical claim stamp, stamp mismatch, changed revision, unrelated worker,
decision after the claim, decision ts without UTC offset, legacy decision without
task_rev, candidate scope not the owner with no ready higher work, malformed decision
log). Valid exceptions and refusals are listed separately and are not bypasses; each
refusal states the claim state actually read (canonical claim present | no canonical
claim | UNKNOWN when the task is not in the ledger read). A claim is not proof of useful execution: worker
liveness and useful effect stay UNKNOWN (see MISSING_PRODUCER); a start without a
canonical claim is not observable here.

Priority class: 1 safety/security/data-integrity/prod/recovery or cross-task
unblocker; 2 authorized unblocked overdue commitment; 3 discretionary/other.
Readiness: ready | blocked (exact dependency + owner + evidence) | triage defect
(blocker language with no structured waits-on token: NOT runnable) | deferred
(explicit not-before in the future) | active (claim held; never duplicated).

Exit codes: 0 ok (observe: CLEAN), 2 usage, 3 REFUSE, 4 canonical source unavailable
(no fallback, nothing replayed), 5 task already actively claimed, 6 observe found a
bypass, 7 observe could not bind every claimed start (UNKNOWN).
"""
import argparse, datetime, json, os, re, subprocess, sys

EXIT_REFUSE, EXIT_SOURCE, EXIT_ACTIVE, EXIT_BYPASS, EXIT_UNKNOWN = 3, 4, 5, 6, 7
MISSING_PRODUCER = ("no supported canonical producer binds a running worker, its liveness or its useful effect to an ask "
                    "claim: wm-asks ask_events records op=claim (rev, ts, worker) and has no launch, heartbeat or release op; "
                    "a start without a canonical claim is not observable here")
CLASS1 = re.compile(r"\b(security|secur\w*|leak\w*|credential\w*|data[- ]integrity|data[- ]loss|corrupt\w*|"
                    r"prod|production|outage|recovery|restore|backup|incident|rollback)\b", re.I)
DISCRETIONARY = re.compile(r"\b(discretionary|nice[- ]to[- ]have|optional|new idea)\b", re.I)
BLOCKER_WORDS = re.compile(r"\b(blocked|waiting (?:on|for)|waits? on|stuck|depends on)\b", re.I)
TOKEN = re.compile(r"waits-on=([A-Za-z0-9_]+):(\S+)")
CLAIM = re.compile(r"\bclaim=(\S+)")
STAMP = re.compile(r"^(?P<worker>[^\s|]+)@(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2})$")   # asks.claim(): worker@YYYY-MM-DDTHH:MM
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
            assert isinstance(d, dict) and isinstance(d["asks"], list)
        except Exception as e:
            die_source("fixture %s: %s" % (fx, e))
        args._fixture = d
        return checked_rows(d["asks"]), d.get("followups"), norm_ts(args.now) or d.get("now") or now, "fixture"
    cmd = (os.environ.get("CTL_OQ_WM_ASKS") if args.test else None) or "wm-asks"
    args._wm_asks = cmd
    try:
        r = subprocess.run([cmd, "asks", "query", "--json", "--status", "all"],
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
    asks = checked_rows(asks)
    fu = None
    try:
        f = subprocess.run(["wm-decide", "followups", "--json"], capture_output=True, text=True, timeout=120)
        if f.returncode == 0:
            fu = json.loads(f.stdout)
    except Exception:
        fu = None
    return asks, fu, now, "wm-asks"


def checked_rows(rows):
    """Every canonical row must state status open|closed (asks._public); anything else is an unknown schema: refuse."""
    bad = sorted({str(a.get("status")) for a in rows if a.get("status") not in ("open", "closed")})
    if bad:
        die_source("ledger row status %s is neither open nor closed (unknown schema)" % ",".join(bad))
    return rows


def classify(rows, now):
    asks = [a for a in rows if a["status"] == "open"]       # only open asks are scheduled
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
                "rev": a.get("rev"), "summary": seg[:160]}
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
    # closed asks: never scheduled; a claimed one is still a start to assess (claims are not released on close)
    out["_closed_claimed"], out["_ledger_ids"] = [], {a["ask_id"]: a["status"] for a in rows}
    for a in rows:
        if a["status"] == "closed":
            cm = CLAIM.search((a.get("what") or "").split(" | ")[0])
            claim = a.get("claim") or (cm.group(1) if cm else None)
            if claim:
                out["_closed_claimed"].append({"ask_id": a["ask_id"], "row_id": a.get("row_id"), "owner": a.get("owner"),
                                               "rev": a.get("rev"), "claim": claim})
    return out


def state_dir(args):
    if args.test and os.environ.get("CTL_OQ_STATE"):
        return os.environ["CTL_OQ_STATE"]
    return os.path.expanduser("~/.local/state/ctl-obligation")


def read_decisions(args, with_malformed=False):
    p = os.path.join(state_dir(args), "decisions.jsonl")
    rows, bad = [], 0
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if line:
                try:
                    r = json.loads(line)
                except ValueError:
                    r = None
                if isinstance(r, dict) and r.get("task_id") and r.get("outcome"):
                    rows.append(r)
                else:
                    bad += 1
    return (rows, bad) if with_malformed else rows


def aware(s):
    """offset-aware datetime, or None when the ts is missing, unparseable or has no UTC offset."""
    try:
        t = datetime.datetime.fromisoformat(str(s).replace(" ", "T"))
    except (TypeError, ValueError):
        return None
    return t if t.utcoffset() is not None else None


def at_or_before(a, b):
    """True/False when both instants are offset-aware; None when the order cannot be established."""
    x, y = aware(a), aware(b)
    return None if x is None or y is None else x <= y


def now_ts():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def load_claim_events(args, aid):
    """-> (claim events, None) or (None, reason). Canonical source: `wm-asks asks events ID --json`."""
    fx = getattr(args, "_fixture", None)
    if fx is not None:
        if not isinstance(fx.get("events"), dict):
            return None, "canonical events unavailable (fixture has no events)"
        ev = fx["events"].get(aid, [])
    else:
        cmd = getattr(args, "_wm_asks", None) or "wm-asks"
        try:
            r = subprocess.run([cmd, "asks", "events", aid, "--json"], capture_output=True, text=True, timeout=120)
        except Exception as e:
            return None, "canonical events unavailable: %s" % e
        if r.returncode != 0:
            return None, "canonical events unavailable: exit %d %s" % (r.returncode, r.stderr.strip()[:120])
        try:
            ev = json.loads(r.stdout)
        except ValueError as e:
            return None, "malformed canonical events: %s" % e
    out = []
    if not isinstance(ev, list):
        return None, "malformed canonical events: not a list"
    for e in ev:
        if not isinstance(e, dict) or "op" not in e:
            return None, "malformed canonical events: row without op"
        if e["op"] != "claim":
            continue
        det = e.get("detail")
        try:
            det = json.loads(det) if isinstance(det, str) else det
            assert isinstance(det, dict) and isinstance(e.get("rev"), int) and e.get("ts")
        except Exception:
            return None, "malformed canonical claim event"
        out.append({"rev": e["rev"], "ts": e["ts"], "worker": det.get("worker"), "claim": det.get("claim")})
    return out, None


def task_index(c):
    return {x["ask_id"]: x for k in ("queue", "blocked", "active", "deferred", "triage_defects") for x in c[k]}


def is_dependency_repair(c, tid):
    return tid in c["_unblockers"] or any(
        x.get("row_id") == tid for x in c["queue"] + c["blocked"] if x["row_id"] in c["_unblockers"])


def higher_candidates(c, tid, owner, any_owner=False):
    """ready class-1/2 asks other than tid; scoped to the canonical owner of tid (callers pass the row's owner, never --actor)."""
    return [x["ask_id"] for x in c["queue"] if x["class"] < 3 and x["ask_id"] != tid and (any_owner or x["owner"] == owner)]


def assess_starts(c, args, decisions, malformed):
    """Bind every claimed open ask to the decisions log through its canonical claim event."""
    idx, starts = task_index(c), []
    stamps = {}
    claimed = [dict(x, ask_status="open") for x in c["active"]] + [dict(x, ask_status="closed") for x in c.get("_closed_claimed", [])]
    for x in claimed:
        stamps.setdefault(x["claim"], []).append(x["ask_id"])
    for x in claimed:
        aid, claim = x["ask_id"], x["claim"]
        sm = STAMP.match(str(claim))
        worker = sm.group("worker") if sm else None
        st = {"ask_id": aid, "ask_status": x["ask_status"], "owner": x["owner"], "claim": claim, "worker": worker, "row_rev": x.get("rev"),
              "claim_rev": None, "claim_ts": None, "authorization": None, "kind": None, "reason": None,
              "decision_ts": None, "decision_task_rev": None, "worker_liveness": "UNKNOWN", "useful_effect": "UNKNOWN"}
        starts.append(st)
        problem = None
        ev, why = load_claim_events(args, aid)
        if ev is None:
            problem = why
        elif not sm:
            problem = "claim stamp %r is not the canonical worker@YYYY-MM-DDTHH:MM" % claim
        elif not ev:
            problem = "no canonical claim event for claim %s" % claim
        elif len(ev) > 1:
            problem = "duplicate start identity: %d claim events" % len(ev)
        elif ev[0]["claim"] != claim or ev[0]["worker"] != worker:
            problem = "claim event %s does not match the current claim %s" % (ev[0]["claim"], claim)
        elif aware(ev[0]["ts"]) is None:
            problem = "claim event ts %r has no UTC offset; its order against decisions cannot be established" % ev[0]["ts"]
        else:
            st["claim_rev"], st["claim_ts"] = ev[0]["rev"], ev[0]["ts"]
        if not problem and len(stamps[claim]) > 1:
            problem = "duplicate start identity: claim %s also on %s" % (claim, ",".join(i for i in stamps[claim] if i != aid))
        decs = [d for d in decisions if d.get("task_id") == aid]
        allowed = [d for d in decs if d.get("outcome") == "allowed"]
        refused = [d for d in decs if d.get("outcome") == "refused"]

        def verdict(auth, why_, kind=None, d=None):
            st.update(authorization=auth, reason=why_, kind=kind)
            if d:
                st.update(decision_ts=d.get("ts"), decision_task_rev=d.get("task_rev"))

        if not allowed and malformed:
            verdict("unknown", "no well-formed allowing decision for %s, and decisions.jsonl has %d malformed line(s)" % (aid, malformed))
        elif not allowed and refused:
            verdict("bypass", "every decision recorded for %s refused it; the task was claimed anyway" % aid, "refused-then-started", refused[-1])
        elif not allowed:
            verdict("bypass", "claimed with no start decision recorded for %s" % aid, "unlogged-start")
        elif problem:
            verdict("unknown", problem)
        else:
            same = [d for d in decs if d.get("outcome") in ("allowed", "refused") and d.get("task_rev") is not None
                    and d["task_rev"] == st["claim_rev"] - 1]
            unordered = [d for d in same if at_or_before(d.get("ts"), st["claim_ts"]) is None]
            gov = [d for d in same if at_or_before(d.get("ts"), st["claim_ts"]) is True]
            if unordered:
                verdict("unknown", "decision ts %r has no UTC offset; its order against the claim cannot be established" % unordered[-1].get("ts"),
                        d=unordered[-1])
            elif gov:
                d = gov[-1]
                if d["outcome"] == "refused":
                    verdict("bypass", "the decision at rev %s refused %s; claimed at rev %s" % (d["task_rev"], aid, st["claim_rev"]),
                            "refused-then-started", d)
                elif d.get("worker") and d["worker"] != worker:
                    verdict("unknown", "decision named worker %s; claim is by %s (unrelated worker)" % (d["worker"], worker), d=d)
                elif d.get("exception_valid") and d.get("higher_priority_candidates"):
                    verdict("valid-exception", "bound to a valid recorded priority exception", d=d)
                elif d.get("dependency_repair"):
                    verdict("dependency-repair", "bound to an allowed dependency-repair decision", d=d)
                elif d.get("computed_priority_class") == 3 and d.get("candidate_owner", d.get("actor")) not in ("*", st["owner"]):
                    scope = d.get("candidate_owner", d.get("actor"))
                    t = idx.get(aid)
                    now_c = higher_candidates(c, aid, st["owner"]) if t and t["class"] == 3 and not is_dependency_repair(c, aid) else []
                    if now_c:
                        verdict("bypass", "decision scoped higher-priority candidates to %r, not the canonical owner %r; ready higher-priority "
                                "work of %s now (computed at observe time): %s" % (scope, st["owner"], st["owner"], ",".join(now_c[:15])),
                                "owner-scope-mismatch", d)
                    else:
                        verdict("unknown", "decision scoped higher-priority candidates to %r, not the canonical owner %r; it cannot "
                                "certify the start" % (scope, st["owner"]), d=d)
                else:
                    verdict("allowed", "bound to an allowed decision with no actionable higher-priority candidate", d=d)
            else:
                legacy = [d for d in allowed if d.get("task_rev") is None and "computed_priority_class" not in d
                          and at_or_before(d.get("ts"), st["claim_ts"]) is not False]
                t = idx.get(aid)
                forged = [d for d in legacy if d.get("class_label") != "discretionary" and not d.get("dependency_repair")]
                if forged and t and t["class"] == 3 and not is_dependency_repair(c, aid) and \
                        higher_candidates(c, aid, st["owner"]):
                    verdict("bypass", "legacy decision trusted declared class %s; the row computes class 3 and higher-priority "
                            "work is ready now (computed at observe time)" % forged[-1].get("class_label"), "forged-class", forged[-1])
                elif legacy:
                    verdict("unknown", "legacy decision without task_rev cannot be bound to the claim", d=legacy[-1])
                elif any(d.get("task_rev") is None for d in allowed):
                    d = [d for d in allowed if d.get("task_rev") is None][-1]
                    verdict("unknown", "decision has no task_rev (the ledger row carried no rev); it cannot be bound to the claim", d=d)
                elif any(d.get("task_rev") is not None and d["task_rev"] != st["claim_rev"] - 1 for d in allowed):
                    d = allowed[-1]
                    verdict("unknown", "revision changed: decision read rev %s, claim event is rev %s" % (d.get("task_rev"), st["claim_rev"]), d=d)
                else:
                    verdict("unknown", "every allowing decision for %s was recorded after the claim" % aid, d=allowed[-1])
    return starts


def fu_summary(fu):
    if isinstance(fu, dict):
        return {"available": True, "count": len(fu.get("ids") or []), "escalated": fu.get("escalated")}
    if isinstance(fu, list):
        return {"available": True, "count": len(fu), "escalated": None}
    return {"available": False, "count": None, "escalated": None}


def snapshot(args):
    asks, fu, now, source = load_source(args)
    c = classify(asks, now)
    op = [a for a in asks if a["status"] == "open"]
    c.update({"now": now, "source": source, "open_total": len(op), "closed_total": len(asks) - len(op),
              "overdue_total": sum(1 for a in op if norm_ts(a.get("due")) and norm_ts(a.get("due")) <= now),
              "followups": fu_summary(fu)})
    return c


def cmd_queue(args):
    c = snapshot(args)
    decisions, bad = read_decisions(args, with_malformed=True)
    sx = {s["ask_id"]: s for s in assess_starts(c, args, decisions, bad)}
    for x in c["active"]:
        s = sx[x["ask_id"]]
        x["start_check"] = s["authorization"] + (":" + s["kind"] if s["kind"] else "")
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
        L.append("- %s owner %s claim %s; start check %s" % (x["ask_id"], x["owner"], x["claim"], x.get("start_check")))
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
    declared = CLASS_NAMES[args.cls]
    t = task_index(c).get(tid)
    cls = t["class"] if t else None
    owner = t and t["owner"]
    base = {"ts": now_ts(), "task_id": tid, "actor": actor, "candidate_owner": ("*" if args.any_owner else owner) if t else None,
            "priority_class": cls, "class_label": args.cls, "declared_priority_class": declared,
            "computed_priority_class": cls, "computed_class_reason": t and t["class_reason"],
            "class_supported": bool(t) and declared >= cls, "rationale": args.rationale,
            "task_rev": t and t.get("rev"), "worker": args.worker}

    def record(rec):
        d = state_dir(args)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "decisions.jsonl"), "a") as f:
            f.write(json.dumps(rec) + "\n")

    if t is None:
        why = "%s is not an open row in the canonical ledger (%s); its priority cannot be computed" % (
            tid, "closed" if c["_ledger_ids"].get(tid) == "closed" else "absent: no ask with this id in the ledger read")
        record(dict(base, higher_priority_candidates=[], dependency_repair=False, exception=None, exception_valid=False,
                    outcome="refused", decision_reason=why, source=c["source"], ledger_now=c["now"]))
        print("REFUSE: %s" % why)
        return EXIT_REFUSE
    if any(x["ask_id"] == tid for x in c["active"]):
        record(dict(base, higher_priority_candidates=[], dependency_repair=False, exception=None, exception_valid=False,
                    outcome="refused-active", existing_claim=t["claim"],
                    decision_reason="task already holds an active claim; not duplicated", source=c["source"], ledger_now=c["now"]))
        print("REFUSE-ACTIVE: %s already holds an active claim; not duplicated" % tid)
        return EXIT_ACTIVE
    is_unblocker = is_dependency_repair(c, tid)
    cands = []
    if cls == 3 and not is_unblocker:
        cands = higher_candidates(c, tid, owner, args.any_owner)
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
    if outcome == "refused" and not base["class_supported"]:
        why += "; declared class %s is not supported by the row (computed class %d: %s)" % (args.cls, cls, t["class_reason"])
    record(dict(base, higher_priority_candidates=cands, dependency_repair=is_unblocker, exception=exc,
                exception_valid=exc_valid, outcome=outcome, decision_reason=why, source=c["source"], ledger_now=c["now"]))
    if outcome == "refused":
        print("REFUSE: %s; candidates: %s" % (why, ", ".join(cands[:15]) + (" ..." if len(cands) > 15 else "")))
        return EXIT_REFUSE
    print("ALLOW: %s (%s)" % (tid, why))
    return 0


def cmd_observe(args):
    c = snapshot(args)                       # canonical source required: outage exits 4, nothing is replayed
    decisions, bad = read_decisions(args, with_malformed=True)
    starts = assess_starts(c, args, decisions, bad)
    claimed = {s["ask_id"] for s in starts}
    out = {"result": None, "result_scope": "claim-evidenced starts on open and closed asks only", "source": c["source"], "now": c["now"],
           "starts": starts,
           "bypasses": [s for s in starts if s["authorization"] == "bypass"],
           "unknown": [s for s in starts if s["authorization"] == "unknown"],
           "valid_exceptions": [d for d in decisions if d.get("outcome") == "allowed" and d.get("exception_valid")
                                and d.get("higher_priority_candidates")],
           "refusals": [dict(d, start_evidence="canonical claim present" if d["task_id"] in claimed else
                             ("no canonical claim (a start without a claim is not observable)" if d["task_id"] in c["_ledger_ids"] else
                              "UNKNOWN: %s is not in the canonical ledger read; its claim state is not established" % d["task_id"]))
                        for d in decisions if d.get("outcome") in ("refused", "refused-active")],
           "decision_log": {"rows": len(decisions), "malformed": bad},
           "missing_producer": MISSING_PRODUCER}
    out["result"] = "BYPASS" if out["bypasses"] else ("UNKNOWN" if out["unknown"] else "CLEAN")
    if args.json:
        print(json.dumps(out, indent=1))
    else:
        print("observe: %s (%s); %d claimed start(s), %d bypass, %d unknown, %d valid exception(s), %d refusal(s)" % (
            out["result"], out["result_scope"], len(starts), len(out["bypasses"]), len(out["unknown"]),
            len(out["valid_exceptions"]), len(out["refusals"])))
        for s in starts:
            print("- %s claim %s rev %s: %s%s; %s" % (s["ask_id"], s["claim"], s["claim_rev"], s["authorization"],
                                                      ":" + s["kind"] if s["kind"] else "", s["reason"]))
        print("worker liveness and useful effect: UNKNOWN; " + MISSING_PRODUCER)
    return {"BYPASS": EXIT_BYPASS, "UNKNOWN": EXIT_UNKNOWN}.get(out["result"], 0)


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
    d.add_argument("--worker", help="the worker id that will claim the task (wm-asks asks claim --worker); observe requires the claim to match")
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
