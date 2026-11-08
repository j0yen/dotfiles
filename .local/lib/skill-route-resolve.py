#!/usr/bin/env python3
"""skill-route-resolve.py: the ONE resolver for adaptive skill routing (ledger A1300).

Input JSON (stdin, or `--file PATH`; never shell-interpolated):
  {task_id, skill, decision_class?, evidence_refs?, escalation?:{reason,evidence:[ref..]},
   requested?:{model,effort}, review?:{reason,evidence:[ref..]}}
Output JSON on stdout: {ok, governed, model_id, effort, route, reasons[], review?}
Exit 0 = route resolved (or skill ungoverned); exit 2 = denied (fail closed, {ok:false,error,reasons}).
Policy: --policy PATH | $SKILL_ROUTE_POLICY | <repo>/.config/skill-routing/policy.json | ~/.config/skill-routing/policy.json.
Skills and phases are data in the policy; adding one needs no code change.
"""
import json, os, re, sys

HOME = os.path.expanduser("~")


class Deny(Exception):
    def __init__(self, msg, reasons=None):
        super().__init__(msg)
        self.reasons = reasons or [msg]


def find_policy(arg):
    here = os.path.dirname(os.path.realpath(__file__))
    for c in (arg, os.environ.get("SKILL_ROUTE_POLICY"),
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


def check_route(pol, model, effort):
    if not isinstance(model, str) or model not in pol["models"]:
        raise Deny("unknown model %r" % (model,))
    if not isinstance(effort, str) or effort in pol.get("forbidden_efforts", []):
        raise Deny("effort %r is forbidden" % (effort,))
    if effort not in pol["models"][model]["efforts"]:
        raise Deny("unknown or unsupported effort %r for %s" % (effort, model))


def check_evidence(pol, refs, what):
    ev = pol["evidence"]
    if not isinstance(refs, list) or len(refs) < ev["min_refs"]:
        raise Deny("%s needs at least %d evidence reference(s)" % (what, ev["min_refs"]))
    pat = re.compile(ev["ref_pattern"])
    ledger = os.environ.get("SKILL_ROUTE_LEDGER_TSV", os.path.join(HOME, ".cache", "aide", "open-asks.tsv"))
    for r in refs:
        if not isinstance(r, str) or not pat.match(r) or r.split(":", 1)[1].lower() in ev["placeholders"]:
            raise Deny("%s evidence ref %r is not a real reference (kind:value with kind in ledger|file|pr|run|commit|page)" % (what, r))
        kind, val = r.split(":", 1)
        if kind == "file" and not os.path.exists(os.path.expanduser(val)):
            raise Deny("%s evidence file %r does not exist" % (what, val))
        if kind == "ledger" and os.path.isfile(ledger):
            with open(ledger, errors="replace") as f:
                if val not in f.read():
                    raise Deny("%s evidence ledger id %r not found in the ledger" % (what, val))


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
    tid = req.get("task_id")
    if not isinstance(tid, str) or not re.match(r"^[A-Za-z0-9][A-Za-z0-9._:-]{1,79}$", tid):
        raise Deny("task_id is required (^[A-Za-z0-9][A-Za-z0-9._:-]{1,79}$)")
    reasons = []
    cls = req.get("decision_class")
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
    check_route(pol, r["model"], r["effort"])
    reqd = req.get("requested")
    if reqd is not None:
        if not isinstance(reqd, dict):
            raise Deny("requested must be an object {model,effort}")
        check_route(pol, reqd.get("model"), reqd.get("effort"))
        if (reqd["model"], reqd["effort"]) != (r["model"], r["effort"]):
            raise Deny("requested %s/%s does not match the resolved route %s/%s" %
                       (reqd["model"], reqd["effort"], r["model"], r["effort"]))
    out = {"ok": True, "governed": True, "model_id": r["model"], "effort": r["effort"],
           "route": route, "task_id": tid, "skill": skill, "reasons": reasons}
    rev = req.get("review")
    if rev is not None:
        rp = pol["review"]
        if not isinstance(rev, dict) or rev.get("reason") not in rp["reasons"]:
            raise Deny("second review denied: reason must be one of %s (no automatic second review)" % ", ".join(rp["reasons"]))
        if rp.get("evidence"):
            check_evidence(pol, rev.get("evidence"), "review")
        check_route(pol, rp["route"]["model"], rp["route"]["effort"])
        out["review"] = {"model_id": rp["route"]["model"], "effort": rp["route"]["effort"], "reason": rev["reason"]}
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
