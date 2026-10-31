#!/usr/bin/env bash
# Hindsight lint for one precheck replay fixture (shift-left WWHTBT mechanism 1, AC 1).
# A fixture holds only what existed at launch_ts. Exit 1 when:
#   - any facts[].as_of or row.ts is later than launch_ts
#   - a mandatory boring key is missing from facts (hostname unit cwd cmd head_sha launch_ts)
#   - cmd_source or launch_ts_source is not a leg-log path, a unit journal line or a decision row id
#   - any string field except why_legit (values, source strings, cmd, row text, note, keys) carries a timestamp later than launch_ts
# Timestamps scanned: ISO 8601 (with or without offset; no offset reads as local -07:00), Z-suffixed UTC,
# journalctl "Oct 30 13:54:02", compact YYYYMMDDTHHMMSS[Z] and YYYYMMDD-HHMMSS (log and row-id stamps), and bare HH:MM(:SS)?( ?[AP]M)?
# read against the launch date. The sonnet hindsight grade for selection bias is a separate step (it runs with the replay).
# Usage: precheck-hindsight-lint.sh <fixture.json>
set -u
[ "$#" = 1 ] && [ -f "$1" ] || { echo "usage: $0 <fixture.json>" >&2; exit 2; }
exec python3 -I - "$1" <<'PY'
import json, re, sys, datetime as dt

TZ = dt.timezone(dt.timedelta(hours=-7))
MON = {m: i for i, m in enumerate(['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'], 1)}
BORING = ['hostname', 'unit', 'cwd', 'cmd', 'head_sha', 'launch_ts']
errs = []


def fail(msg):
    errs.append(msg)


def parse_iso(s):
    s = s.strip()
    if s.endswith('Z'):
        s = s[:-1] + '+00:00'
    t = dt.datetime.fromisoformat(s)
    return t if t.tzinfo else t.replace(tzinfo=TZ)


path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    print(f"FAIL {path}: not valid JSON: {e}")
    sys.exit(1)

try:
    T = parse_iso(d['launch_ts'])
except Exception as e:
    print(f"FAIL {path}: launch_ts missing or unparseable: {e}")
    sys.exit(1)
fid = d.get('id', path)

ISO = re.compile(r'(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?(?:\.\d+)?(Z|[+-]\d\d:?\d\d)?')
JRN = re.compile(r'\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) {1,2}(\d{1,2}) (\d\d):(\d\d):(\d\d)\b')
CMP = re.compile(r'(?<!\d)(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)(Z?)(?!\d)')
CMD = re.compile(r'(?<!\d)(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)(?!\d)')
CLK = re.compile(r'(?<![\w:.\-/])(\d{1,2}):(\d\d)(?::(\d\d))?(?: ?([AP]M))?(?![\w:])')


def stamps(s):
    """yield (text, datetime) for every timestamp in s"""
    out = []

    def take(rx, conv):
        nonlocal s
        for m in list(rx.finditer(s)):
            try:
                out.append((m.group(0), conv(m)))
            except ValueError:
                pass
        s = rx.sub(lambda m: ' ' * len(m.group(0)), s)

    def iso(m):
        y, mo, da, h, mi, se, z = m.groups()
        if z and z != 'Z' and ':' not in z:
            z = z[:3] + ':' + z[3:]
        base = dt.datetime(int(y), int(mo), int(da), int(h), int(mi), int(se or 0))
        if z == 'Z':
            return base.replace(tzinfo=dt.timezone.utc)
        if z:
            sign = 1 if z[0] == '+' else -1
            return base.replace(tzinfo=dt.timezone(sign * dt.timedelta(hours=int(z[1:3]), minutes=int(z[4:6]))))
        return base.replace(tzinfo=TZ)

    take(ISO, iso)
    take(JRN, lambda m: dt.datetime(T.year, MON[m.group(1)], int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)), tzinfo=TZ))
    take(CMP, lambda m: dt.datetime(*[int(x) for x in m.groups()[:6]], tzinfo=dt.timezone.utc if m.group(7) else TZ))
    take(CMD, lambda m: dt.datetime(*[int(x) for x in m.groups()[:6]], tzinfo=TZ))

    def clk(m):
        h, mi, se, ap = m.groups()
        h = int(h)
        if ap:
            if h < 1 or h > 12:
                raise ValueError
            h = h % 12 + (12 if ap == 'PM' else 0)
        if h > 23 or int(mi) > 59:
            raise ValueError
        return T.replace(hour=h, minute=int(mi), second=int(se or 0))

    take(CLK, clk)
    return out


def walk(o, where):
    if isinstance(o, str):
        yield where, o
    elif isinstance(o, dict):
        for k, v in o.items():
            yield (where + '.' + str(k) + '<key>'), str(k)
            yield from walk(v, where + '.' + str(k))
    elif isinstance(o, list):
        for i, v in enumerate(o):
            yield from walk(v, f"{where}[{i}]")


# 1. as_of / row.ts
facts = d.get('facts')
if not isinstance(facts, list) or not facts:
    fail('facts missing or empty')
    facts = []
for i, f in enumerate(facts):
    for k in ('key', 'value', 'as_of', 'source'):
        if k not in f:
            fail(f"facts[{i}] missing {k}")
    try:
        if parse_iso(f['as_of']) > T:
            fail(f"facts[{i}] ({f.get('key')}) as_of {f['as_of']} is later than launch_ts")
    except Exception:
        fail(f"facts[{i}] ({f.get('key')}) as_of {f.get('as_of')!r} is not an ISO timestamp")
row = d.get('row')
if row is not None:
    try:
        if parse_iso(row['ts']) > T:
            fail(f"row.ts {row['ts']} is later than launch_ts")
    except Exception:
        fail('row.ts missing or unparseable')

# 2. mandatory boring keys
keys = {f.get('key') for f in facts}
for k in BORING:
    if k not in keys:
        fail(f"mandatory fact key missing: {k}")

# 3. cmd_source / launch_ts_source shape
ROWID = re.compile(r'\bd-\d{8}-\d{6}-[a-z0-9]+-[0-9a-f]{4}\b')
for fld in ('cmd_source', 'launch_ts_source'):
    v = d.get(fld)
    if not isinstance(v, str) or not (re.search(r'\.log\b', v) or re.search(r'\bjournal', v) or ROWID.search(v)):
        fail(f"{fld} is not a leg log path, unit journal line or row id: {v!r}")

# 4. no later timestamp in any string field except why_legit
for where, s in walk({k: v for k, v in d.items() if k != 'why_legit'}, '$'):
    for txt, t in stamps(s):
        if t > T:
            fail(f"{where}: timestamp {txt!r} is later than launch_ts")

if errs:
    for e in errs:
        print(f"FAIL {fid}: {e}")
    sys.exit(1)
print(f"PASS {fid}: {len(facts)} facts, launch_ts {d['launch_ts']}")
PY
