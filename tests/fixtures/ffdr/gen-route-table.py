#!/usr/bin/env python3
"""gen-route-table.py: the skill-routing resolution table (A1300 FFDR Phase 1, T1). Stdlib only; run with python3 -I. Writes nothing
outside its own temporary directory.

Usage: gen-route-table.py --policy POLICY --resolver RESOLVER [--source TEXT]   (the table goes to stdout)

Every row is one request run through `python3 -I RESOLVER --policy POLICY` (request on stdin) with a private HOME and a private
ledger-id file holding only A1300 (SKILL_ROUTE_LEDGER_IDS), so the resolver never calls wm-asks and every evidence ref is ledger:A1300.
Rows are built from POLICY alone, in this order:
  route rows, per governed skill (sorted):
    <skill>|baseline          no decision_class
    <skill>|class:<C>         per class (sorted); evidence_refs when the class has evidence:true; an exception record {reason,
                              evidence:[ledger:A1300]} when the class route is an exception route (the recorded max exception)
    <skill>|escalation:<R>    per escalation reason (sorted), escalation {reason, evidence:[ledger:A1300]}, no decision_class
    a skill with require_permission_mode carries that permission_mode on every request.
  review rows, per governed skill and per review reason (policy order):
    <skill>|review:<reason>@<selector>   the request of the skill's first route row (order above) that resolved to a model route,
                                         plus review {reason, evidence:[ledger:A1300]}
Each row records the request, the resolver exit code and its output JSON. Denied rows are kept: the table is data, not a judgment.
"""
import hashlib, json, os, subprocess, sys, tempfile

TASK = "FFDR-T1"
EV = "ledger:A1300"


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def resolve(resolver, policy, env, req):
    p = subprocess.run([sys.executable, "-I", resolver, "--policy", policy], input=json.dumps(req, sort_keys=True),
                       capture_output=True, text=True, env=env, timeout=60)
    try:
        out = json.loads(p.stdout)
    except ValueError:
        out = {"unparsable_stdout": p.stdout[:500]}
    return p.returncode, out


def rows_for(pol, resolver, policy, env):
    rows = []
    skills = pol.get("skills") or {}
    for skill in sorted(skills):
        spol = skills[skill]
        base = {"task_id": TASK, "skill": skill}
        pm = spol.get("require_permission_mode")
        if isinstance(pm, str) and pm:
            base["permission_mode"] = pm
        reqs = [("baseline", dict(base))]
        for cls in sorted(spol.get("classes") or {}):
            cpol = spol["classes"][cls]
            r = dict(base, decision_class=cls)
            if cpol.get("evidence"):
                r["evidence_refs"] = [EV]
            if (spol.get("routes") or {}).get(cpol.get("route"), {}).get("exception"):
                r["exception"] = {"reason": "recorded exception (FFDR route table)", "evidence": [EV]}
            reqs.append(("class:" + cls, r))
        for reason in sorted(spol.get("escalation_reasons") or {}):
            reqs.append(("escalation:" + reason, dict(base, escalation={"reason": reason, "evidence": [EV]})))
        rep = None
        for sel, req in reqs:
            rc, out = resolve(resolver, policy, env, req)
            rows.append({"id": "%s|%s" % (skill, sel), "request": req, "rc": rc, "out": out})
            if rep is None and rc == 0 and isinstance(out, dict) and out.get("model_id"):
                rep = (sel, req)
        if rep is None:
            continue
        for reason in (pol.get("review") or {}).get("reasons") or []:
            req = dict(rep[1], review={"reason": reason, "evidence": [EV]})
            rc, out = resolve(resolver, policy, env, req)
            rows.append({"id": "%s|review:%s@%s" % (skill, reason, rep[0]), "request": req, "rc": rc, "out": out})
    return rows


def main(argv):
    args = {"--policy": None, "--resolver": None, "--source": None}
    i = 0
    while i < len(argv):
        if argv[i] in args and i + 1 < len(argv):
            args[argv[i]] = argv[i + 1]; i += 2
        else:
            sys.stderr.write("usage: gen-route-table.py --policy POLICY --resolver RESOLVER [--source TEXT]\n"); return 2
    policy, resolver = args["--policy"], args["--resolver"]
    if not policy or not resolver or not os.path.isfile(policy) or not os.path.isfile(resolver):
        sys.stderr.write("gen-route-table: --policy and --resolver must name readable files\n"); return 2
    with open(policy) as f:
        pol = json.load(f)
    with tempfile.TemporaryDirectory() as tmp:
        ids = os.path.join(tmp, "ledger-ids.txt")
        with open(ids, "w") as f:
            f.write("A1300\n")
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": tmp, "LC_ALL": "C", "SKILL_ROUTE_LEDGER_IDS": ids}
        rows = rows_for(pol, resolver, policy, env)
    head = {"source": args["--source"], "policy_sha256": sha256(policy), "resolver_sha256": sha256(resolver), "row_count": len(rows)}
    lines = ["{"] + [' %s: %s,' % (json.dumps(k), json.dumps(head[k])) for k in sorted(head)] + [' "table": [']
    lines += ["  " + json.dumps(r, sort_keys=True, separators=(",", ":")) + ("," if n + 1 < len(rows) else "") for n, r in enumerate(rows)]
    lines += [" ]", "}"]
    sys.stdout.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
