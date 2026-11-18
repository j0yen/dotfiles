#!/usr/bin/env python3
"""skill-route-resolve.py: the ONE resolver for adaptive skill routing (ledger A1300).

Input JSON (stdin, or `--file PATH`; never shell-interpolated):
  {task_id, skill, decision_class?, evidence_refs?, escalation?:{reason,evidence:[ref..]},
   requested?:{route?,model,effort}, review?:{reason,evidence:[ref..],snapshot?,replay?:{reason,evidence:[ref..],prior:[sid..]}}, permission_mode?}
A skill whose policy has `require_permission_mode` (non-empty string) is denied unless the request's permission_mode equals it.
Output JSON on stdout: {ok, governed, model_id, effort, route, reasons[], alternate_of?, review?, permission_mode? (echoed when the policy requires one)}
The review echo {model_id, effort, reason, replay?} is the skill's `review_route` (a route of that skill; an unknown name is a policy
error) or else the policy-global review.route. review.replay (A1300 FFDR R2) declares the failed/interrupted/unknown prior reviews a
re-review of the same frozen manifest replays: exactly {reason (>= 8 non-space chars), evidence (>= 1 ledger: ref), prior (unique
canonical lowercase UUIDs)}, only beside review.snapshot; it is echoed with prior sorted. The launcher compares prior with the blocking set.
Requestable alternates (A1300 E13 R1/R2/R4): a skill's `alternates` maps a Fable route of the skill to a non-empty list of its non-Fable
routes at the same effort. It is validated whatever the request, right after the skill lookup: a malformed list denies every request for
the skill, naming alternates. Let R be the route the request resolves to without `requested` (baseline, class or escalation). A
requested.route naming a member of alternates[R], with requested.model and requested.effort both equal to that member's, selects it: the
output's route, model_id and effort become the member's, reasons gain "requested alternate <alt> for <R>" and alternate_of = R. A
requested.route equal to R keeps today's check; any other requested.route, or one that is not a string, is denied for every governed skill.
Without requested.route nothing changes: a requested model and effort never select an alternate. With an alternate selected, the review
echo is the skill's review_route (denied when that route is Fable) or else the alternate's own model and effort.
Exit 0 = route resolved (or skill ungoverned); exit 2 = denied (fail closed, {ok:false,error,reasons}).
Policy: --policy PATH | $SKILL_ROUTE_POLICY | <repo>/.config/skill-routing/policy.json | ~/.config/skill-routing/policy.json.
Skills and phases are data in the policy; adding one needs no code change.
"""
import json, os, re, sys

HOME = os.path.expanduser("~")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")   # canonical lowercase session id (fullmatch)


class Deny(Exception):
    def __init__(self, msg, reasons=None):
        super().__init__(msg)
        self.reasons = reasons or [msg]


def find_policy(arg):
    here = os.path.dirname(os.path.realpath(__file__))
    if not arg and os.environ.get("SKILL_ROUTE_POLICY"):  # an explicitly named policy is the only candidate: no fall-through
        if os.path.isfile(os.environ["SKILL_ROUTE_POLICY"]):
            return os.environ["SKILL_ROUTE_POLICY"]
        raise Deny("policy-missing: SKILL_ROUTE_POLICY names no readable file")
    if arg:  # an explicit --policy is the only candidate too: a missing file never falls through to repo/home policy
        if os.path.isfile(arg):
            return arg
        raise Deny("policy-missing: --policy names no readable file")
    for c in (arg,
              os.path.join(here, "..", "..", ".config", "skill-routing", "policy.json"),
              os.path.join(HOME, ".config", "skill-routing", "policy.json")):
        if c and os.path.isfile(c):
            return c
    raise Deny("policy file not found")


def load_json(text, what):
    try:
        return json.loads(text)
    except Exception as e:
        raise Deny("malformed %s JSON: %s" % (what, type(e).__name__))


def check_route(pol, model, effort, exception=False):
    if not isinstance(model, str) or model not in pol["models"]:
        raise Deny("unknown model %r" % (model,))
    if not isinstance(effort, str) or (effort in pol.get("forbidden_efforts", []) and not exception):
        raise Deny("effort %r is forbidden" % (effort,))
    if effort not in pol["models"][model]["efforts"]:
        raise Deny("unknown or unsupported effort %r for %s" % (effort, model))


def check_evidence(pol, refs, what):
    ev = pol["evidence"]
    if not isinstance(refs, list) or len(refs) < ev["min_refs"]:
        raise Deny("%s needs at least %d evidence reference(s)" % (what, ev["min_refs"]))
    pat = re.compile(ev["ref_pattern"])
    for r in refs:
        if not isinstance(r, str) or not pat.match(r) or r.split(":", 1)[1].lower() in ev["placeholders"]:
            raise Deny("%s evidence ref %r is not a real reference (kind:value with kind in ledger|file|pr|run|commit|page)" % (what, r))
        kind, val = r.split(":", 1)
        if kind == "file" and not os.path.exists(os.path.expanduser(val)):
            raise Deny("%s evidence file %r does not exist" % (what, val))
        if kind == "ledger":
            if not ledger_has(val):
                raise Deny("%s evidence ledger id %r not found in the ledger" % (what, val))


def is_nonfable(pol, model):
    """A1300 E13 R2: a policy model whose entry has a string family other than fable and whose id names no fable (any case)."""
    m = pol["models"].get(model) if isinstance(model, str) else None
    return isinstance(m, dict) and isinstance(m.get("family"), str) and m["family"] != "fable" and "fable" not in model.lower()


def check_alternates(pol, skill, spol):
    """A1300 E13 R2: the skill's `alternates` ({fable route: [non-Fable routes at its effort]}), or {} when the key is absent.
    Any malformed entry is a policy error that denies the request whatever it asks (fail closed), naming alternates."""
    if "alternates" not in spol:
        return {}
    alts, routes = spol["alternates"], spol["routes"]
    def bad(why):
        raise Deny("%s: policy alternates %s (policy error, fail closed)" % (skill, why))
    def plain(n):  # a route of this skill that is neither deterministic code nor a recorded exception
        return isinstance(n, str) and isinstance(routes.get(n), dict) and not routes[n].get("deterministic") and not routes[n].get("exception")
    if not isinstance(alts, dict):
        bad("must be an object mapping a route of the skill to a list of its routes (got %s)" % type(alts).__name__)
    for key, mem in alts.items():
        if not plain(key):
            bad("key %r is not a route of this skill, or is a deterministic or exception route" % key)
        kr = routes[key]
        km = pol["models"].get(kr.get("model")) if isinstance(kr.get("model"), str) else None
        if not isinstance(km, dict) or km.get("family") != "fable":
            bad("key %r is not a route whose model's family is fable" % key)
        if not isinstance(mem, list) or not mem or not all(isinstance(n, str) for n in mem) or len(set(mem)) != len(mem):
            bad("value of %r must be a non-empty list of unique route names" % key)
        for n in mem:
            if n == key:
                bad("member %r equals its key" % n)
            if n not in routes:
                bad("member %r of %r is not a route of this skill" % (n, key))
            if not plain(n):
                bad("member %r of %r is a deterministic or exception route" % (n, key))
            r = routes[n]
            if not is_nonfable(pol, r.get("model")):
                bad("member %r of %r needs a model entry with a string family other than fable and an id naming no fable (got %r)"
                    % (n, key, r.get("model")))
            eff = r.get("effort")
            if not isinstance(eff, str) or eff in pol.get("forbidden_efforts", []) or eff not in pol["models"][r["model"]].get("efforts", []):
                bad("member %r of %r has a forbidden or unsupported effort %r" % (n, key, eff))
            if eff != kr.get("effort"):
                bad("member %r of %r has effort %r but its key has %r (an alternate never changes the effort)" % (n, key, eff, kr.get("effort")))
    return alts


def ledger_has(ask_id):
    """Read-only lookup. Tests point SKILL_ROUTE_LEDGER_IDS at a file of ids; otherwise `wm-asks asks query` (argv list, no shell)."""
    ids = os.environ.get("SKILL_ROUTE_LEDGER_IDS")
    if ids:
        with open(ids, errors="replace") as f:
            return ask_id in f.read().split()
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", ask_id):
        return False
    import subprocess
    try:
        p = subprocess.run(["wm-asks", "asks", "query", "--ids", ask_id, "--status", "all", "--json"],
                           capture_output=True, text=True, timeout=15)
        return p.returncode == 0 and len(json.loads(p.stdout)) > 0
    except Exception:
        raise Deny("ledger lookup unavailable; cannot verify ledger:%s (fail closed)" % ask_id)


def check_replay(pol, rev):
    """review.replay (A1300 FFDR R2.1-R2.3) -> its echo, prior sorted. Denied, naming the field, unless exactly {reason, evidence, prior}
    beside a review.snapshot."""
    rp = rev["replay"]
    if not isinstance(rp, dict) or set(rp) != {"reason", "evidence", "prior"}:
        raise Deny("review.replay must be an object with exactly reason, evidence and prior (got %s)" %
                   (",".join(sorted(rp)) if isinstance(rp, dict) else type(rp).__name__))
    if not isinstance(rev.get("snapshot"), str) or not rev["snapshot"]:
        raise Deny("review.replay needs review.snapshot (a replay re-reviews a frozen manifest)")
    if not isinstance(rp["reason"], str) or len(re.sub(r"\s", "", rp["reason"])) < 8:
        raise Deny("review.replay.reason must be a string of at least 8 non-space characters")
    check_evidence(pol, rp["evidence"], "review.replay.evidence")
    if not any(isinstance(e, str) and e.startswith("ledger:") for e in rp["evidence"]):
        raise Deny("review.replay.evidence needs a ledger: reference")
    pr = rp["prior"]
    if not isinstance(pr, list) or not pr or not all(isinstance(s, str) and UUID_RE.fullmatch(s) for s in pr) or len(set(pr)) != len(pr):
        raise Deny("review.replay.prior must be a non-empty list of unique canonical lowercase session UUIDs")
    return {"reason": rp["reason"], "evidence": list(rp["evidence"]), "prior": sorted(pr)}


def resolve(pol, req):
    if not isinstance(req, dict):
        raise Deny("input must be a JSON object")
    skill = req.get("skill")
    if not isinstance(skill, str) or not skill:
        raise Deny("skill is required")
    spol = pol["skills"].get(skill)
    if spol is None:
        return {"ok": True, "governed": False, "model_id": None, "effort": None, "route": None,
                "reasons": ["skill %s is not governed by skill-routing policy" % skill]}
    alts = check_alternates(pol, skill, spol)   # A1300 E13 R2: before everything else the skill asks, so a bad list denies every request
    pmode = None
    if "require_permission_mode" in spol:  # checked before route and class
        want = spol["require_permission_mode"]
        if not isinstance(want, str) or not want:
            raise Deny("%s: policy require_permission_mode must be a non-empty string (fail closed)" % skill)
        have = req.get("permission_mode")
        if not isinstance(have, str) or have != want:
            raise Deny("%s requires permission_mode %r (policy require_permission_mode); request carried %r" % (skill, want, have))
        pmode = have
    rv_route = None   # A1300 FFDR R2.4: the skill's own second-review route, validated whatever the request (a bad name is a policy error)
    if "review_route" in spol:
        rv_route = spol["routes"].get(spol["review_route"]) if isinstance(spol["review_route"], str) else None
        if not isinstance(rv_route, dict) or not isinstance(rv_route.get("model"), str) or not isinstance(rv_route.get("effort"), str):
            raise Deny("%s: policy review_route %r is not a route of this skill with a model and effort (policy error, fail closed)" %
                       (skill, spol["review_route"]))
    tid = req.get("task_id")
    if not isinstance(tid, str) or not re.match(r"^[A-Za-z0-9][A-Za-z0-9._:-]{1,79}$", tid):
        raise Deny("task_id is required (^[A-Za-z0-9][A-Za-z0-9._:-]{1,79}$)")
    reasons = []
    cls = req.get("decision_class")
    if cls in (None, "") and spol.get("require_class"):
        raise Deny("%s has no baseline: decision_class (the phase) is required (known: %s)" % (skill, ", ".join(sorted(spol["classes"]))))
    esc = req.get("escalation")
    route = spol["baseline"]
    if cls in (None, ""):
        reasons.append("no decision_class: baseline %s" % route)
        cls_pol = None
    elif not isinstance(cls, str) or cls not in spol["classes"]:
        raise Deny("unknown decision_class %r for %s (known: %s)" % (cls, skill, ", ".join(sorted(spol["classes"]))))
    else:
        cls_pol = spol["classes"][cls]
        route = cls_pol["route"]
        reasons.append("decision_class %s -> %s" % (cls, route))
    if esc is not None:
        if not isinstance(esc, dict):
            raise Deny("escalation must be an object {reason,evidence}")
        reason = esc.get("reason")
        if not isinstance(reason, str) or reason not in spol["escalation_reasons"]:
            raise Deny("escalation reason %r is not allowed for %s (allowed: %s)" %
                       (reason, skill, ", ".join(sorted(spol["escalation_reasons"]))))
        check_evidence(pol, esc.get("evidence"), "escalation")
        target = spol["escalation_reasons"][reason]
        if cls_pol is not None and cls not in ("baseline", "straightforward_reversible") and cls != reason:
            raise Deny("escalation reason %r conflicts with decision_class %r" % (reason, cls))
        route = target
        reasons.append("escalation %s with %d evidence ref(s) -> %s" % (reason, len(esc["evidence"]), route))
    elif cls_pol is not None and cls_pol.get("evidence"):
        check_evidence(pol, req.get("evidence_refs"), "decision_class %s" % cls)
        reasons.append("class %s evidence verified" % cls)
    if req.get("evidence_refs") not in (None, []):
        check_evidence(pol, req["evidence_refs"], "evidence_refs")
    r = spol["routes"][route]
    exc = None
    if r.get("exception"):
        exc = req.get("exception")
        if not isinstance(exc, dict) or not isinstance(exc.get("reason"), str) or not exc["reason"]:
            raise Deny("route %s is a recorded exception: exception {reason,evidence} is required" % route)
        check_evidence(pol, exc.get("evidence"), "exception")
        if not any(isinstance(e, str) and e.startswith("ledger:") for e in exc["evidence"]):
            raise Deny("route %s needs a ledger reference recorded first (exception evidence has no ledger: ref)" % route)
        reasons.append("recorded exception %s -> %s" % (exc["reason"], route))
    elif req.get("exception") is not None:
        raise Deny("exception is only valid for an exception route")
    if r.get("deterministic"):
        if req.get("requested") is not None:
            raise Deny("phase %s is deterministic code: no model or effort can be requested" % route)
        return {"ok": True, "governed": True, "deterministic": True, "model_id": None, "effort": None,
                "route": route, "task_id": tid, "skill": skill, "reasons": reasons + ["deterministic code, no model launch"]}
    check_route(pol, r["model"], r["effort"], exception=bool(exc))
    reqd = req.get("requested")
    alt = None   # A1300 E13 R1: the listed alternate the request selected, if any
    if reqd is not None:
        if not isinstance(reqd, dict):
            raise Deny("requested must be an object {model,effort}")
        if "model" in reqd and (not isinstance(reqd["model"], str) or reqd["model"] not in pol["models"]):
            raise Deny("unknown model %r" % (reqd["model"],))
        if "effort" in reqd and (not isinstance(reqd["effort"], str) or reqd["effort"] in pol.get("forbidden_efforts", [])
                                 or not any(reqd["effort"] in m["efforts"] for m in pol["models"].values())):
            raise Deny("unknown or forbidden effort %r" % (reqd["effort"],))
        if "route" in reqd:   # A1300 E13 R1: requested.route is the only selector of an alternate; absent = the rule below, unchanged
            want, listed = reqd["route"], alts.get(route, [])
            if not isinstance(want, str):
                raise Deny("requested.route must be a string naming the resolved route %s or one of its listed alternates (alternates[%s]: %s); got %s"
                           % (route, route, ", ".join(listed) or "none", json.dumps(want)))
            if want != route:
                if want not in listed:
                    raise Deny("requested.route %r is neither the resolved route %s nor one of its listed alternates (alternates[%s]: %s)"
                               % (want, route, route, ", ".join(listed) or "none"))
                a = spol["routes"][want]
                for k in ("model", "effort"):
                    if k not in reqd:
                        raise Deny("requested.route %s (an alternate of %s) needs requested.%s %s as well: an alternate is asked by route, model and effort together"
                                   % (want, route, k, a[k]))
                off = [k for k in ("model", "effort") if reqd[k] != a[k]]
                if off:
                    raise Deny("%s does not match the requested alternate %s (%s/%s)"
                               % (" and ".join("requested.%s %s" % (k, reqd[k]) for k in off), want, a["model"], a["effort"]))
                check_route(pol, a["model"], a["effort"])
                alt = want
        if alt is None and (reqd.get("model", r["model"]) != r["model"] or reqd.get("effort", r["effort"]) != r["effort"]):
            raise Deny("requested %s/%s does not match the resolved route %s/%s" %
                       (reqd.get("model", "-"), reqd.get("effort", "-"), r["model"], r["effort"]))
    alt_of = None
    if alt is not None:
        if rv_route is not None and not is_nonfable(pol, rv_route["model"]):   # A1300 E13 F37: no Fable label on a non-Fable run
            raise Deny("%s: requested alternate %s is not Fable, but the skill's review_route %r names Fable model %s; its review echo would label this run Fable (policy conflict, fail closed)"
                       % (skill, alt, spol["review_route"], rv_route["model"]))
        reasons.append("requested alternate %s for %s" % (alt, route))
        alt_of, route, r = route, alt, spol["routes"][alt]
    out = {"ok": True, "governed": True, "model_id": r["model"], "effort": r["effort"],
           "route": route, "task_id": tid, "skill": skill, "reasons": reasons}
    if alt_of is not None:
        out["alternate_of"] = alt_of
    if pmode is not None:  # the one permission_mode source: the launcher passes exactly this value as --permission-mode
        out["permission_mode"] = pmode
    if exc:
        out["exception"] = True
    rev = req.get("review")
    if rev is not None:
        rp = pol["review"]
        if not isinstance(rev, dict) or rev.get("reason") not in rp["reasons"]:
            raise Deny("second review denied: reason must be one of %s (no automatic second review)" % ", ".join(rp["reasons"]))
        if rp.get("evidence"):
            check_evidence(pol, rev.get("evidence"), "review")
        if alt_of is not None and rv_route is None:   # A1300 E13 R4: an alternate run is reviewed on its own model and effort
            rr = {"model": r["model"], "effort": r["effort"]}
        else:
            rr = rv_route if rv_route is not None else rp["route"]
        check_route(pol, rr["model"], rr["effort"])
        out["review"] = {"model_id": rr["model"], "effort": rr["effort"], "reason": rev["reason"]}
        if "replay" in rev:
            out["review"]["replay"] = check_replay(pol, rev)
    return out


def main(argv):
    pol_arg = None
    fpath = None
    i = 0
    while i < len(argv):
        if argv[i] == "--policy" and i + 1 < len(argv):
            pol_arg = argv[i + 1]; i += 2
        elif argv[i] == "--file" and i + 1 < len(argv):
            fpath = argv[i + 1]; i += 2
        else:
            raise Deny("usage: skill-route-resolve.py [--policy P] [--file F | < stdin]")
    try:
        pol = load_json(open(find_policy(pol_arg)).read(), "policy")
        text = open(fpath).read() if fpath else sys.stdin.read()
    except OSError as e:
        raise Deny("cannot read input: %s" % type(e).__name__)
    if not isinstance(pol, dict) or "skills" not in pol or "models" not in pol:
        raise Deny("policy is malformed")
    return resolve(pol, load_json(text, "request"))


if __name__ == "__main__":
    try:
        res = main(sys.argv[1:])
        print(json.dumps(res)); sys.exit(0)
    except Deny as d:
        print(json.dumps({"ok": False, "error": str(d), "reasons": d.reasons})); sys.exit(2)
    except Exception as e:  # fail closed on any unexpected shape
        print(json.dumps({"ok": False, "error": "internal: %s" % type(e).__name__, "reasons": []})); sys.exit(2)
