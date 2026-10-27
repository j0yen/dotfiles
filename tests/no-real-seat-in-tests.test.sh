#!/usr/bin/env bash
# no-real-seat-in-tests: a test or a selftest must never start a REAL seat's ask/event unit (ctl 49ab/1a7b, 10-25..10-26: seat-tick.sh --selftest 15c ran
# `seat-ask.sh r7 ...` with no dry flag -> real seat-ask-r7-* transient units, OnFailure=seat-tick-failed@r7 -> 6 false SEAT-TICK FAILED r7 alarms to ctl).
# THE MECHANISM OF RECORD is the runtime guard in .local/bin/seat-ask.sh (SEAT_ASK_TEST=1 or a non-default SEAT_ASK_TICK_BIN refuses a real seat, exit 65).
# This grep is a cheap TRIPWIRE for the other callers (seat-event.sh, ctl-ask.sh, raw systemd-run), not a proof: it is line-based and sees what it can resolve.
# Scope: every file under tests/, and every `selftest() { ... }` body in .local/bin/*.sh.
# Flagged: a command line that runs seat-ask.sh / seat-event.sh / ctl-ask.sh (or "$SELF" inside those scripts' own selftest) / `systemd-run ... --unit seat-(ask|tick|event)-<seat>`
# with a REAL seat as the seat argument (literal, or a $var resolved from a `var=..` assignment or `for var in ..` loop in the same scope), unless the same command line carries
# SEAT_ASK_DRY=1 | CTL_ASK_DRY=1 | SEAT_EVENT_DRY=1, an EARLIER `export ...DRY=1` of one of them sits in the same scope (selftest body / file), or the command is a stub (path under $T/$tmp/$D, or PATH=$T...).
# REAL seats = rb r7 ctl controller aide (hardcoded) UNION the first column of the repo table $ROOT/.claude/state/seats.tsv (read below); the test behaves the same with no seats.tsv.
# ALLOW-LIST: tests/no-real-seat-in-tests.allow, lines `<file>:<line><TAB><reason>`; empty when possible.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; ROOT="${NRS_ROOT:-$here}"
command -v python3 >/dev/null || { echo "SKIP no python3"; exit 0; }
out="$(python3 -I - "$ROOT" "$here/tests/no-real-seat-in-tests.allow" <<'PY'
import os, re, sys, glob
root, allowf = sys.argv[1], sys.argv[2]
real = {"rb", "r7", "ctl", "controller", "aide"}
tsv = os.path.join(root, ".claude/state/seats.tsv")
if os.path.exists(tsv):
    for l in open(tsv, errors="replace"):
        if l.strip() and not l.lstrip().startswith("#"): real.add(l.split("\t")[0].strip())
allow = {}
if os.path.exists(allowf):
    for l in open(allowf, errors="replace"):
        if l.strip() and not l.startswith("#"): allow[l.split("\t")[0].strip()] = l
DRY = re.compile(r"\b(SEAT_ASK_DRY|CTL_ASK_DRY|SEAT_EVENT_DRY)=1\b")
EXPORT_DRY = re.compile(r"^\s*(export|declare -x)\b.*\b(SEAT_ASK_DRY|CTL_ASK_DRY|SEAT_EVENT_DRY)=1\b")
CALL = re.compile(r'(?P<path>\S*?)(?P<tool>seat-ask\.sh|seat-event\.sh|ctl-ask\.sh)"?(?P<rest>.*)')
SELFCALL = re.compile(r'"\$SELF"(?P<rest>.*)')
UNIT = re.compile(r'--unit[= ]+"?seat-(ask|tick|event)-([A-Za-z0-9_]+|\$\{?\w+\}?)')
STUB = re.compile(r'^"?\$\{?(T|tmp|TMP|D|R|H|fakebin\w*|FB)\b')   # the script path itself lives under a scratch dir
PATHSTUB = re.compile(r'\bPATH="?\$\{?(T|tmp|TMP)\b')   # or the command line prepends a scratch dir to PATH
def logical(lines, base):
    out, cur, start = [], "", None
    for i, l in enumerate(lines, base):
        if start is None: start = i
        if l.rstrip().endswith("\\"): cur += l.rstrip()[:-1] + " "; continue
        out.append((start, cur + l)); cur, start = "", None
    return out
def resolve(tok, scope_text):
    tok = tok.strip("\"'")
    m = re.fullmatch(r"\$\{?(\w+)\}?", tok)
    if not m: return [tok]
    v = m.group(1); vals = []
    for a in re.finditer(r"(?:^|[\s;])(?:local\s+|export\s+)?%s=([\"']?)([A-Za-z0-9_ -]*?)\1(?=[\s;]|$)" % v, scope_text, re.M): vals.append(a.group(2))
    for a in re.finditer(r"for\s+%s\s+in\s+([^;\n]+)" % v, scope_text): vals += a.group(1).split()
    return [x.strip("\"'") for x in vals]
def scan(path, lines, base, own_tool):
    scope_text = "\n".join(lines); fails = []; exported = False
    for ln, l in logical(lines, base):
        s = l.strip()
        if not s or s.startswith("#"): continue
        if s.startswith(("[[", "[ ")) or " chk " in s or s.startswith("chk "): continue   # assertions on text, not commands
        if EXPORT_DRY.match(l): exported = True
        calls = []
        m = CALL.search(s)
        if m and not s.lstrip().startswith(("printf", "grep", "cat ")) and "chk " not in s.split(m.group(0))[0][-1:]:
            calls.append((m.group("path"), m.group("tool"), m.group("rest")))
        elif own_tool and SELFCALL.search(s) and not s.startswith(("printf", "grep")):
            calls.append(("$SELF", own_tool, SELFCALL.search(s).group("rest")))
        for path, tool, rest in calls:
            if tool == "ctl-ask.sh": seats = ["ctl"]
            else:
                toks = rest.split()
                if not toks or toks[0].startswith("-"): continue
                seats = resolve(toks[0], scope_text)
            if any(x in real for x in seats) and not (DRY.search(s) or exported or STUB.search(path) or PATHSTUB.search(s)):
                bad = [x for x in seats if x in real][0]
                fails.append((path_rel(path_of[0]), ln, bad, s))
        for u in UNIT.finditer(s):
            seats = resolve(u.group(2), scope_text)
            if any(x in real for x in seats) and not (DRY.search(s) or exported or PATHSTUB.search(s)):
                fails.append((path_rel(path_of[0]), ln, [x for x in seats if x in real][0], s))
    return fails
def path_rel(p): return os.path.relpath(p, root)
path_of = [""]
fails = []
for f in sorted(glob.glob(os.path.join(root, "tests", "**", "*"), recursive=True)):
    if os.path.isfile(f) and not f.endswith((".allow", ".md", ".json", ".tsv")) and os.path.basename(f) != "no-real-seat-in-tests.test.sh":
        try: lines = open(f, errors="replace").read().split("\n")
        except Exception: continue
        path_of[0] = f; fails += scan(f, lines, 1, None)
for f in sorted(glob.glob(os.path.join(root, ".local/bin", "*.sh"))):
    lines = open(f, errors="replace").read().split("\n")
    st = next((i for i, l in enumerate(lines) if re.match(r"selftest\s*\(\)\s*\{", l)), None)
    if st is None: continue
    en = next((i for i in range(st + 1, len(lines)) if lines[i].startswith("}")), len(lines) - 1)
    own = os.path.basename(f) if os.path.basename(f) in ("seat-ask.sh", "seat-event.sh") else None
    path_of[0] = f; fails += scan(f, lines[st:en + 1], st + 1, own)
n = 0
for f, ln, seat, txt in fails:
    key = "%s:%d" % (f, ln)
    if key in allow: print("ALLOWED %s (%s)" % (key, allow[key].split("\t", 1)[-1].strip())); continue
    n += 1; print("FAIL %s: real seat '%s' in a test/selftest without SEAT_ASK_DRY=1|CTL_ASK_DRY=1|SEAT_EVENT_DRY=1 or a stub bin: %s" % (key, seat, txt[:160]))
print("SCANNED real_seats=%s violations=%d" % (",".join(sorted(real)), n))
PY
)"
printf '%s\n' "$out" | tail -n 30
bad="$(printf '%s\n' "$out" | grep -c '^FAIL ')"
[ "$bad" = 0 ] && echo "PASS no-real-seat-in-tests" || { echo "FAIL no-real-seat-in-tests ($bad violation(s))"; exit 1; }
