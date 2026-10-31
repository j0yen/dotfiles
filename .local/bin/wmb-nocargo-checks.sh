#!/usr/bin/env bash
# wmb-nocargo-checks.sh <wm-build-repo-dir> | --selftest
# Cargo-free mirror of wm-build's lib test actor::tests::act_every_journal_op_is_classified
# (src/actor.rs): every `journal("<table>", "<op>"` literal under src/**/*.rs (actor.rs and
# its tests included, no dirs skipped) is in exactly one of OPERATOR_OPS / NON_OPERATOR_OPS,
# no op is listed twice, every OPERATOR_OPS entry still has a literal. Pure text, < 1 s.
# Exit 0 green, 1 red, 2 error (a missing file or list is never green: zero measurement).
# NOCARGO_MIN_LITERALS (default 500) is the test's `found.len() > 500` floor, overridable for fixtures.
set -u
self="$(readlink -f "$0")"

if [ "${1:-}" = "--selftest" ]; then
  t="$(mktemp -d)" || exit 2
  trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/src"
  cat > "$t/src/actor.rs" <<'RS'
pub const OPERATOR_OPS: &[&str] = &[
    "op-a",
];
pub const NON_OPERATOR_OPS: &[&str] = &[
    "tick-b", "tick-c",
];
RS
  cat > "$t/src/other.rs" <<'RS'
fn f(s: &State) {
    s.journal("t", "op-a", x);
    s.journal(
        "t",
        "tick-b",
    );
    xjournal("t", "not-a-call");
}
RS
  export NOCARGO_MIN_LITERALS=1
  rc=0
  out="$(bash "$self" "$t")" || rc=$?
  [ "$rc" = 0 ] && case "$out" in *"journal-ops green literals=2 operator=1 non_operator=2"*) ;; *) rc=9;; esac
  [ "$rc" = 0 ] || { echo "SELFTEST FAIL green"; exit 1; }
  printf 'fn g(s: &State) { s.journal("t", "planted-op", x); }\n' > "$t/src/planted.rs"
  out="$(bash "$self" "$t")"; rc=$?
  { [ "$rc" = 1 ] && case "$out" in *"UNCLASSIFIED planted-op src/planted.rs:1"*) true;; *) false;; esac; } \
    || { echo "SELFTEST FAIL unclassified"; exit 1; }
  rm "$t/src/planted.rs"
  sed -i 's/"tick-c",/"tick-c", "op-a",/' "$t/src/actor.rs"
  out="$(bash "$self" "$t")"; rc=$?
  { [ "$rc" = 1 ] && case "$out" in *"BOTH-LISTS op-a"*) true;; *) false;; esac; } || { echo "SELFTEST FAIL both-lists"; exit 1; }
  sed -i 's/"tick-c", "op-a",/"tick-c", "tick-c",/' "$t/src/actor.rs"
  out="$(bash "$self" "$t")"; rc=$?
  { [ "$rc" = 1 ] && case "$out" in *"DUPLICATE NON_OPERATOR_OPS tick-c"*) true;; *) false;; esac; } || { echo "SELFTEST FAIL duplicate"; exit 1; }
  sed -i 's/"tick-c", "tick-c",/"tick-c",/' "$t/src/actor.rs"
  cp "$t/src/actor.rs" "$t/actor.keep"
  sed -i 's/"op-a",//' "$t/src/actor.rs"
  out="$(bash "$self" "$t")"; rc=$?
  { [ "$rc" = 2 ] && case "$out" in *"NOCARGO ERROR"*"0 entries"*) true;; *) false;; esac; } || { echo "SELFTEST FAIL empty-list"; exit 1; }
  cp "$t/actor.keep" "$t/src/actor.rs"
  printf 'fn h() {}\n' > "$t/src/other.rs"
  out="$(bash "$self" "$t")"; rc=$?
  { [ "$rc" = 2 ] && case "$out" in *"NOCARGO ERROR"*"0 journal literals"*) true;; *) false;; esac; } || { echo "SELFTEST FAIL zero-literals"; exit 1; }
  printf 'pub const OPERATOR_OPS: &[&str] = &[ "x" ];\n' > "$t/src/actor.rs"
  out="$(bash "$self" "$t")"; rc=$?
  { [ "$rc" = 2 ] && case "$out" in *"NOCARGO ERROR"*) true;; *) false;; esac; } || { echo "SELFTEST FAIL removed-list"; exit 1; }
  echo "SELFTEST PASS"; exit 0
fi

repo="${1:-}"
[ -n "$repo" ] || { echo "NOCARGO ERROR usage: wmb-nocargo-checks.sh <wm-build-repo-dir> | --selftest"; exit 2; }
exec python3 -I - "$repo" "${NOCARGO_MIN_LITERALS:-500}" <<'PY'
import os, re, sys
repo, floor = sys.argv[1], int(sys.argv[2])

def err(msg):
    print("NOCARGO ERROR " + msg)
    sys.exit(2)

src = os.path.join(repo, "src")
actor = os.path.join(src, "actor.rs")
if not os.path.isfile(actor):
    err("src/actor.rs not found under " + repo)
text = open(actor, encoding="utf-8", errors="replace").read()

def parse_list(name):
    m = re.search(r"pub\s+const\s+" + name + r"\s*:\s*&\[\s*&str\s*\]\s*=\s*&\[(.*?)\];", text, re.S)
    if not m:
        err("list literal " + name + " not found in src/actor.rs")
    body = re.sub(r"//[^\n]*", "", m.group(1))
    ops = re.findall(r'"([^"]*)"', body)
    if not ops:
        err("list " + name + " parsed to 0 entries")
    return ops

operator = parse_list("OPERATOR_OPS")
non_operator = parse_list("NON_OPERATOR_OPS")

# the test's walk: every *.rs under src/, recursive, nothing skipped
files = []
for d, _, fs in os.walk(src):
    files += [os.path.join(d, f) for f in fs if f.endswith(".rs")]
files.sort()
rx = re.compile(r'\bjournal\s*\(\s*"[^"]*"\s*,\s*"([^"]*)"')
found = []  # (op, relfile, line)
for f in files:
    t = open(f, encoding="utf-8", errors="replace").read()
    rel = os.path.relpath(f, repo)
    for m in rx.finditer(t):
        found.append((m.group(1), rel, t.count("\n", 0, m.start(1)) + 1))
if not found:
    err("0 journal literals found under src/")

red = 0
oset, nset = set(operator), set(non_operator)
for op in operator:
    if op in nset:
        print("BOTH-LISTS " + op); red += 1
seen = set()
for name, lst in (("OPERATOR_OPS", operator), ("NON_OPERATOR_OPS", non_operator)):
    for op in lst:
        if op in seen and not (name == "NON_OPERATOR_OPS" and op in oset):
            print("DUPLICATE %s %s" % (name, op)); red += 1
        seen.add(op)
if len(found) <= floor:
    print("TOO-FEW-LITERALS %d (floor %d)" % (len(found), floor)); red += 1
done = set()
for op, rel, line in sorted(found, key=lambda x: (x[0], x[1], x[2])):
    if op not in seen and (op, rel) not in done:
        done.add((op, rel)); print("UNCLASSIFIED %s %s:%d" % (op, rel, line)); red += 1
lit_ops = {o for o, _, _ in found}
for op in operator:
    if op not in lit_ops:
        print("STALE-OPERATOR " + op); red += 1
if red:
    print("NOCARGO journal-ops red n=%d" % red); sys.exit(1)
print("NOCARGO journal-ops green literals=%d operator=%d non_operator=%d" % (len(found), len(operator), len(non_operator)))
PY
