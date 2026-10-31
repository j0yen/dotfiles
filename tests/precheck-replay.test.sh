#!/usr/bin/env bash
# Shift-left WWHTBT mechanism 1, AC 1: precheck replay harness (fixture half).
# ALWAYS asserts: 12/12 fixtures parse, exactly one DESIGNED_MISS, 6 ALLOW, class mix of the legitimate launches, hindsight lint 12/12,
# 20/20 control lines with a valid class. THEN, if rb's prompt file or draft read list has not landed, prints
#   REPLAY=PENDING reason=rb-prompt-and-reads-not-landed
# and exits 0. When both exist it projects each fixture's facts onto the read keys (absent -> "unknown") and calls run_precheck_turn,
# a marked stub: no Opus call is made by this file yet.
# Usage: precheck-replay.test.sh [--summary]   (--summary prints one line per fixture and the union of fact keys, after the assertions)
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
FX="$here/tests/fixtures/precheck-20261030"
LINT="$here/tests/precheck-hindsight-lint.sh"
# rb owns both files; PRECHECK_READS / PRECHECK_PROMPT override the provisional locations
READS="${PRECHECK_READS:-$here/gen/precheck-reads.json}"
PROMPT="${PRECHECK_PROMPT:-$here/gen/precheck-prompt.md}"
fail=0
ok() { echo "ok - $1"; }
nok() { echo "NOT OK - $1"; fail=1; }

# --- shape assertions (python: one pass over the 12 fixtures and the controls file) ---
out="$(python3 -I - "$FX" "${1:-}" <<'PY'
import json, os, sys, re
fx, mode = sys.argv[1], sys.argv[2]
INC = ['362', '362f', '364', '503', '508full', 'oom']
LEG = ['legit-%d' % i for i in range(1, 7)]
CLS = {'leg', 'relaunch', 'redrive', 'merge', 'deploy', 'limit', 'other'}
CTL = {'none', 'leg', 'relaunch', 'merge', 'deploy', 'limit'}
errs, docs = [], {}
for n in INC + LEG:
    p = os.path.join(fx, n + '.json')
    try:
        d = json.load(open(p))
    except Exception as e:
        errs.append(f"{n}: parse: {e}")
        continue
    docs[n] = d
    for k in ('id', 'class', 'launch_ts', 'launch_ts_source', 'seat', 'cmd', 'cmd_source', 'row', 'facts', 'expected'):
        if k not in d:
            errs.append(f"{n}: missing {k}")
    if d.get('id') != n:
        errs.append(f"{n}: id {d.get('id')!r} != filename")
    if d.get('class') not in CLS:
        errs.append(f"{n}: class {d.get('class')!r} not in {sorted(CLS)}")
    r = d.get('row')
    if r is not None and not all(k in r for k in ('id', 'ts', 'what', 'why', 'evidence')):
        errs.append(f"{n}: row lacks id/ts/what/why/evidence")
    for i, f in enumerate(d.get('facts', [])):
        if not all(k in f for k in ('key', 'value', 'as_of', 'source')):
            errs.append(f"{n}: facts[{i}] lacks key/value/as_of/source")
print(f"FIXTURES={len(docs)}/12")
exp = [d.get('expected') for d in docs.values()]
if len(docs) == 12:
    if exp.count('DESIGNED_MISS') != 1 or docs['oom'].get('expected') != 'DESIGNED_MISS':
        errs.append(f"expected DESIGNED_MISS exactly once and on oom, got {exp.count('DESIGNED_MISS')}")
    if exp.count('ALLOW') != 6 or any(docs[n].get('expected') != 'ALLOW' for n in LEG):
        errs.append(f"expected 6 ALLOW on legit-1..6, got {exp.count('ALLOW')}")
    if sum(1 for n in INC if docs[n].get('expected') == 'BLOCK_OR_NEEDS_READ') != 5:
        errs.append('expected 5 BLOCK_OR_NEEDS_READ among the incidents')
    cl = [docs[n].get('class') for n in LEG]
    if cl.count('leg') < 2 or cl.count('relaunch') < 1:
        errs.append(f"legit class mix needs >=2 leg and >=1 relaunch, got {cl}")
    for n in LEG:
        if not docs[n].get('why_legit'):
            errs.append(f"{n}: why_legit missing")
    for n in INC:
        if 'why_legit' in docs[n]:
            errs.append(f"{n}: incident fixture must not carry why_legit")
cp = os.path.join(fx, 'cheap-controls.txt')
lines = open(cp, encoding='utf8').read().split('\n')
if lines and lines[-1] == '':
    lines.pop()
bad = [i + 1 for i, l in enumerate(lines) if l.count('\t') != 1 or l.split('\t')[1] not in CTL or not l.split('\t')[0].strip()]
print(f"CONTROLS={len(lines) - len(bad)}/20 lines={len(lines)}")
if len(lines) != 20 or bad:
    errs.append(f"cheap-controls.txt: need 20 'cmd<TAB>class' lines with class in {sorted(CTL)}; bad lines {bad}, count {len(lines)}")
for e in errs:
    print("ERR " + e)
if mode == '--summary':
    union = set()
    for n in INC + LEG:
        d = docs.get(n)
        if not d:
            continue
        fs = d['facts']
        unk = sum(1 for f in fs if str(f['value']).startswith('unknown'))
        union.update(f['key'] for f in fs)
        thin = ' THIN' if fs and unk * 2 > len(fs) else ''
        print(f"SUMMARY {n} class={d['class']} launch_ts={d['launch_ts']} row={(d['row'] or {}).get('id', 'null')} facts={len(fs)} unknown={unk}{thin} cmd_source={d['cmd_source']}")
    print(f"FACT_KEYS_UNION={len(union)}")
sys.exit(1 if errs else 0)
PY
)"
rc=$?
echo "$out" | grep -E '^(ERR|SUMMARY|FACT_KEYS_UNION)' || true
if [ "$rc" = 0 ]; then ok "12/12 fixtures parse; one DESIGNED_MISS, 6 ALLOW, class mix holds"; else nok "fixture shape (see ERR lines)"; fi
ctl="$(echo "$out" | sed -n 's/^CONTROLS=\([0-9]*\)\/20.*/\1/p')"
if [ "${ctl:-0}" = 20 ]; then ok "cheap-controls.txt 20/20 lines with a valid class"; else nok "cheap-controls.txt ${ctl:-0}/20"; fi

# --- hindsight lint on all 12 ---
pass=0
for f in "$FX"/*.json; do
  if bash "$LINT" "$f" >/dev/null 2>&1; then pass=$((pass + 1)); else bash "$LINT" "$f" | head -5; fi
done
if [ "$pass" = 12 ]; then ok "hindsight lint 12/12"; else nok "hindsight lint $pass/12"; fi

# the lint must also be able to fail: a fact dated after launch and a boring key removed
tmp="$(mktemp -d "${TMPDIR:-/tmp}/precheck-replay.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
python3 -I - "$FX/362.json" "$tmp" <<'PY'
import json, sys, copy
d = json.load(open(sys.argv[1]))
a = copy.deepcopy(d); a['facts'].append({'key': 'x', 'value': 'v', 'as_of': '2026-10-30T09:00:00-07:00', 'source': 's'})
b = copy.deepcopy(d); b['facts'] = [f for f in b['facts'] if f['key'] != 'cwd']
c = copy.deepcopy(d); c['facts'][4]['value'] = 'ended at 7:41 AM'
e = copy.deepcopy(d); e['cmd_source'] = 'my memory'
for n, x in zip('abce', (a, b, c, e)):
    json.dump(x, open(f"{sys.argv[2]}/neg-{n}.json", 'w'))
PY
neg=0
for n in a b c e; do bash "$LINT" "$tmp/neg-$n.json" >/dev/null 2>&1 && neg=$((neg + 1)); done
if [ "$neg" = 0 ]; then ok "lint rejects late as_of, missing boring key, late timestamp in text, bad cmd_source"; else nok "lint accepted $neg of 4 poisoned fixtures"; fi

[ "$fail" = 0 ] || { echo "ASSERTIONS=FAIL"; exit 1; }
echo "ASSERTIONS=PASS"

# --- replay half: waits on rb ---
if [ ! -s "$READS" ] || [ ! -s "$PROMPT" ]; then
  echo "REPLAY=PENDING reason=rb-prompt-and-reads-not-landed"
  exit 0
fi

# project(): facts -> the read keys (absent -> "unknown"). Only launch-time inputs go out: cmd, class, row, projected facts.
# expected, why_legit and note are never read here.
project() {
  python3 -I - "$1" "$READS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = json.load(open(sys.argv[2]))
keys = r if isinstance(r, list) else (r.get('reads') or r.get('keys') or list(r))
keys = [k['key'] if isinstance(k, dict) else k for k in keys]
have = {f['key']: f['value'] for f in d['facts']}
print(json.dumps({'id': d['id'], 'class': d['class'], 'launch_ts': d['launch_ts'], 'cmd': d['cmd'], 'row': d['row'],
                  'reads': {k: have.get(k, 'unknown') for k in keys}}, indent=1))
PY
}

# STUB (not implemented): one-turn Opus pre-check. rb's prompt text is $PROMPT; no model call is made from this file yet.
run_precheck_turn() {
  echo "run_precheck_turn: not implemented (stub; waits on swarm-decide #85 and the replay runner)" >&2
  return 2
}

for f in "$FX"/*.json; do
  p="$(project "$f")" || { echo "NOT OK - projection failed for $f"; exit 1; }
  run_precheck_turn "$PROMPT" "$p"
  exit $?
done
