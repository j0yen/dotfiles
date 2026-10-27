#!/usr/bin/env bash
# tests/aide-verifier-gate-nodrift.test.sh: NON-hermetic guard for the AVL launch lints. The hermetic selftest runs against a STUB merge-gate tree, so it can pass
# against invented names; this test imports the REAL live tree (dirname(dirname(realpath(command -v wm-decide)))) and asserts (V5) every name aide-verifier.sh
# imports (`aide-verifier.sh --gate-names`) exists there, gen/merge-gate.json has a repo_tokens object, and the real g3_missing/_agent_token keep the contract the
# lint relies on; and (W4) every repo_tokens key has the owner/name form the L-KIND regex expects, and the one GATED/COMMIT grammar constant
# (`aide-verifier.sh --gate-grammar`) accepts `GATED <key>#53 COMMIT=<40 hex>` for each key and rejects #5, a 41-hex COMMIT and a prefix-glued GATED.
# Read-only (python -I -B, no row written). wm-decide absent and AIDE_VERIFIER_GATE_ROOT unset = explicit SKIP (exit 0). Run with PATH intact (HOME may be a throwaway): bash tests/aide-verifier-gate-nodrift.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../.local/bin/aide-verifier.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
# The live merge-gate tree is a real host install (swarm-decide), not part of this repo. Resolve it as the lint does: AIDE_VERIFIER_GATE_ROOT, else the tree of wm-decide
# on PATH. Where neither exists (RedBaron, CI, a throwaway HOME) the precondition cannot be faked without making the guard tautological, so this is an explicit SKIP
# (exit 0), never a silent pass; a host that has wm-decide still runs every assertion below and an absent mergegate.py/merge-gate.json there is still a FAIL.
if [ -n "${AIDE_VERIFIER_GATE_ROOT:-}" ]; then
  root="$AIDE_VERIFIER_GATE_ROOT"
elif wmd=$(command -v wm-decide); then
  root=$(dirname "$(dirname "$(readlink -f "$wmd")")")
else
  echo "SKIP: wm-decide is not on PATH and AIDE_VERIFIER_GATE_ROOT is unset; the live merge-gate tree is a host install that cannot be faked (set AIDE_VERIFIER_GATE_ROOT=<swarm-decide checkout> to run)"
  exit 0
fi
[ -f "$root/wm_decide/mergegate.py" ] && pass "live root $root has wm_decide/mergegate.py" || bad "live root $root has no wm_decide/mergegate.py"
[ -f "$root/gen/merge-gate.json" ] && pass "live root has gen/merge-gate.json" || bad "live root has no gen/merge-gate.json"
names=$(bash "$script" --gate-names)
[ -n "$names" ] && pass "aide-verifier.sh --gate-names lists: $names" || bad "--gate-names is empty"
grammar=$(bash "$script" --gate-grammar)
[ "$(printf '%s\n' "$grammar" | wc -l)" = 2 ] && pass "aide-verifier.sh --gate-grammar prints the two L-KIND constants" || bad "--gate-grammar did not print exactly two lines"
res=$(python3 -I -B -c '
import importlib, json, re, sys
root, names, gated_fmt, commit_tok = sys.argv[1], sys.argv[2].split(), sys.argv[3], sys.argv[4]
sys.path.insert(0, root)
mg = importlib.import_module("wm_decide.mergegate")
for n in names:
    o = mg
    for part in n.split(".")[2:]:
        o = getattr(o, part)
cfg = json.load(open(root + "/gen/merge-gate.json"))
repos = cfg["repo_tokens"]
assert isinstance(repos, dict) and repos, "repo_tokens is not a non-empty object"
att = {"trailer": {"HEAD": "a" * 40, "CMD": "x", "EXIT": "0", "DIRTY": "0"}, "body": [], "tail": [], "lines": 0}
toks = ["x EXIT=0", "y EXIT=0", "z delta=0"]
missing, problem = mg.g3_missing(toks, [att], "a" * 40)
assert problem is None and missing == ["y EXIT=0", "z delta=0"], (missing, problem)
assert mg._agent_token({"what": "agent=coder:q author=w"}, mg.AGENT_RE) == "coder:q"
assert mg._agent_token({"what": "agent=coder:q author=w"}, mg.AUTHOR_RE) == "w"
h = "0123456789abcdef" * 2 + "01234567"
for repo in repos:
    assert re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo), "repo_tokens key %r is not owner/name" % repo
    rx = gated_fmt % (re.escape(repo), "53")
    row = "GATED %s#53 COMMIT=%s agent=coder:x" % (repo, h)
    assert re.search(rx, row), "grammar rejects its own row for %s" % repo
    assert re.findall(commit_tok, row) == [h], "COMMIT token regex misreads %s" % repo
    assert not re.search(gated_fmt % (re.escape(repo), "5"), row), "grammar accepts #5 for a #53 row (%s)" % repo
    assert not re.search(rx, "x" + row), "grammar accepts a prefix-glued GATED (%s)" % repo
    assert re.findall(commit_tok, row + " COMMIT=" + h) == [h, h], "COMMIT token regex does not count two tokens"
print("ok %d names, %d repos" % (len(names), len(repos)))
' "$root" "$names" "$(printf '%s\n' "$grammar" | sed -n 1p)" "$(printf '%s\n' "$grammar" | sed -n 2p)" 2>&1) \
  && pass "real tree: every imported name exists, repo_tokens parses and every key is owner/name, g3_missing/_agent_token keep their contract, the GATED grammar round-trips ($res)" \
  || bad "real tree drifted from the lint: $(printf '%s' "$res" | tail -n 3)"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
