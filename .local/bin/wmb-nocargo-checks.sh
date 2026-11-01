#!/usr/bin/env bash
# wmb-nocargo-checks.sh <wm-build-repo-dir> | --selftest
# Cargo-free mirror of the wm-build test `act_every_journal_op_is_classified`
# (src/actor.rs) so a --no-cargo RedBaron coder sees that red before publishing.
# Mirrors the test, nothing more, nothing less:
#   * scan: every *.rs under <repo>/src (recursive, no file or test-code
#     exclusions, actor.rs itself included); a literal is `journal` not preceded
#     by [A-Za-z0-9_], optional ws, `(`, "table", ws, `,`, ws, "op" (no escapes).
#   * UNCLASSIFIED <op> <file>:<line>  op in neither OPERATOR_OPS nor NON_OPERATOR_OPS
#   * BOTH-LISTS <op>                  test asserts !NON_OPERATOR_OPS.contains
#   * DUPLICATE <list> <op>            test asserts each listed op is unique
#   * STALE-OPERATOR <op>              OPERATOR_OPS op with no literal in src/
#   * TOO-FEW-LITERALS <n>             test asserts found.len() > 500
#                                      (n must exceed NOCARGO_MIN_LITERALS, default 500)
# Exit 0 + `NOCARGO green ops=<n>` clean; 1 on any finding; 2 on usage error or
# missing src/actor.rs / either list.
set -uo pipefail

check() {
    NOCARGO_MIN_LITERALS="${NOCARGO_MIN_LITERALS:-500}" python3 -I - "$1" <<'PY'
import os, re, sys
repo = sys.argv[1]
src = os.path.join(repo, "src")
actor = os.path.join(src, "actor.rs")
if not os.path.isfile(actor):
    print("ERROR missing src/actor.rs"); sys.exit(2)
text = open(actor, encoding="utf-8").read()

def strings_of(name):
    m = re.search(r"\b" + name + r"\s*:\s*&\[\s*&str\s*\]\s*=\s*&\[", text)
    if not m:
        return None
    i, out = m.end(), []
    while i < len(text):
        c = text[i]
        if c == "]":
            return out
        if text.startswith("//", i):
            j = text.find("\n", i); i = len(text) if j < 0 else j; continue
        if c == '"':
            j = text.find('"', i + 1)
            if j < 0: return None
            out.append(text[i + 1:j]); i = j + 1; continue
        i += 1
    return None

lists = {n: strings_of(n) for n in ("OPERATOR_OPS", "NON_OPERATOR_OPS")}
for n, v in lists.items():
    if v is None:
        print("ERROR list not found: " + n); sys.exit(2)

pat = re.compile(r'(?<![A-Za-z0-9_])journal\s*\(\s*"[^"]*"\s*,\s*"([^"]*)"')
found = []
for d, _, fs in os.walk(src):
    for f in sorted(fs):
        if not f.endswith(".rs"): continue
        p = os.path.join(d, f)
        t = open(p, encoding="utf-8").read()
        for m in pat.finditer(t):
            found.append((m.group(1), "%s:%d" % (os.path.relpath(p, repo), t.count("\n", 0, m.start(1)) + 1)))

op, non = lists["OPERATOR_OPS"], lists["NON_OPERATOR_OPS"]
out = []
for o in op:
    if o in non: out.append("BOTH-LISTS " + o)
seen = set()
for n in ("OPERATOR_OPS", "NON_OPERATOR_OPS"):
    for o in lists[n]:
        if o in seen: out.append("DUPLICATE %s %s" % (n, o))
        seen.add(o)
floor = int(os.environ["NOCARGO_MIN_LITERALS"])
if len(found) <= floor:
    out.append("TOO-FEW-LITERALS %d" % len(found))
first = {}
for o, loc in sorted(found, key=lambda x: (x[0], x[1])):
    if o not in seen and o not in first: first[o] = loc
for o, loc in first.items(): out.append("UNCLASSIFIED %s %s" % (o, loc))
fo = {o for o, _ in found}
for o in op:
    if o not in fo: out.append("STALE-OPERATOR " + o)
if out:
    print("\n".join(out)); sys.exit(1)
print("NOCARGO green ops=%d" % len(seen))
PY
}

selftest() {
    local t rc out; t=$(mktemp -d) || return 1
    trap 'rm -rf "$t"' RETURN
    mkdir -p "$t/src/daemon"
    cat > "$t/src/actor.rs" <<'RS'
pub const OPERATOR_OPS: &[&str] = &[
    "run-paused", // pause
];
pub const NON_OPERATOR_OPS: &[&str] = &[
    "tick",
];
fn t() { state.journal("daemon", "tick", &x); }
RS
    printf '%s\n' 'fn a() { s.journal("runs", "run-paused", &j); }' > "$t/src/daemon/a.rs"
    out=$(NOCARGO_MIN_LITERALS=0 check "$t"); rc=$?
    [ "$rc" = 0 ] || { echo "SELFTEST fail: clean tree rc=$rc: $out"; return 1; }
    printf '%s\n' 'fn b() { s.journal("runs", "planted-op", &j); }' > "$t/src/daemon/b.rs"
    out=$(NOCARGO_MIN_LITERALS=0 check "$t"); rc=$?
    [ "$rc" = 1 ] && [ "$(printf '%s\n' "$out" | sed 's/ src.*//')" = "UNCLASSIFIED planted-op" ] \
        || { echo "SELFTEST fail: planted rc=$rc: $out"; return 1; }
    echo "SELFTEST ok"
}

case "${1:-}" in
    --selftest) selftest; exit $? ;;
    ""|-*) echo "usage: wmb-nocargo-checks.sh <wm-build-repo-dir> | --selftest" >&2; exit 2 ;;
esac
[ $# = 1 ] && [ -d "$1" ] || { echo "usage: wmb-nocargo-checks.sh <wm-build-repo-dir> | --selftest" >&2; exit 2; }
check "$1"
