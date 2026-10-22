# r7-journal-parse.py -- the r7-mon-journal parser. Reads wm-build journal.jsonl rows on stdin (or `--follow PATH` tails PATH itself) and prints
#   CAND<TAB>what<TAB>run[/slug]<TAB>values      one line per bell candidate (the carbon side dedups, budgets and rings the bell)
#   HB                                           every 30 s in --follow mode (liveness + EPIPE detection so a dead ssh never leaves a tail behind)
# Read-only: no writes anywhere. Python 3, stdlib only. R7_IDLE_S overrides the idle-slot wait (selftest only; default 600).
import sys, os, json, re, time, select, subprocess

QUOTA = re.compile(r'\b429\b|\b403\b|quota|rate.?limit|org.?disabled', re.I)
MSG_ALWAYS = ('error', 'err', 'message', 'stderr')          # message/error fields: scanned on every table
MSG_ALARM = ('cause', 'summary', 'detail')                  # alarm text fields: scanned on the alarms table only
NOT_ELIGIBLE = re.compile(r'^(dir:|parked|status:|depends-unresolved|claimed-by|prefix-denied|cap=max_runs)')
IDLE_S = float(os.environ.get('R7_IDLE_S', '600'))
LAND_FAIL = {'land-precheck-failed', 'push-refused', 'version-head-not-above-tag', 'regen-failed', 'generated-regen-moved-head'}
STOPPED = {'unit-stopped', 'operator-stop', 'run-finalized', 'claim-reaped', 'orphan-released'}

idle_since = None
idle_fired = False

def clip(x, n=120):
    return re.sub(r'\s+', '_', str(x))[:n]

def out(what, run, vals=''):
    print('CAND\t%s\t%s\t%s' % (what, run or '-', vals), flush=True)

def runref(r):
    rid = r.get('run_id', r.get('run', r.get('id')))
    slug = r.get('slug')
    if rid is None:
        return slug or '-'
    return '%s/%s' % (rid, slug) if slug else str(rid)

def handle(d, now):
    global idle_since, idle_fired
    t, op, r = d.get('table'), d.get('op') or '', d.get('row') or {}
    if not isinstance(r, dict):
        r = {}
    seen = set()
    def emit(what, run, vals=''):
        if what in seen:
            return
        seen.add(what); out(what, run, vals)
    ref = runref(r)
    # --- run ended / killed / paused
    if t == 'runs' and op == 'update' and r.get('outcome'):
        emit('run-ended-' + re.sub(r'[^a-z0-9]+', '-', str(r['outcome']).lower()).strip('-'), ref, 'outcome=%s' % clip(r['outcome']))
    if t == 'runs' and op == 'run-ended' and r.get('cause'):
        emit('run-ended-red-leg', ref, 'by=%s cause=%s' % (clip(r.get('by', '-'), 20), clip(r['cause'], 140)))
    if op in STOPPED:
        emit('run-stopped', ref, 'op=%s %s' % (op, clip(r.get('reason') or r.get('unit') or '', 60)))
    if t == 'runs' and op == 'run-paused':
        emit('run-paused', ref, 'cause=%s' % clip(r.get('cause', ''), 100))
    # --- land ended / held
    if t == 'land' and op == 'pr-merged':
        emit('land-merged', ref, 'sha=%s' % clip(str(r.get('sha', ''))[:12]))
    if op in LAND_FAIL or (t == 'daemon' and op == 'readmit-from-land-failed'):
        emit('land-failed', ref, 'op=%s %s' % (op, clip(r.get('check') or r.get('cause') or '', 80)))
    if t == 'land' and op == 'ci-red-classified':
        emit('land-ci-red', ref, 'kind=%s main=%s check=%s' % (clip(r.get('kind', '-'), 20), clip(r.get('main_state', '-'), 20), clip(r.get('check', ''), 60)))
    if t == 'land' and op == 'land-held':
        emit('land-held', ref, 'reason=%s hold_minutes=%s' % (clip(r.get('reason', '-'), 40), r.get('hold_minutes', '-')))
    if 'work-lost' in op and '-skipped-' not in op:
        emit('work-lost', ref, 'op=%s' % op)
    # --- alarms / limits
    if t == 'alarms' and op == 'insert':
        ch = str(r.get('channel', '-'))
        emit('quota-429' if ch == 'quota' else 'alarm-opened', str(r.get('ref') or r.get('id') or '-'), 'channel=%s cause=%s' % (clip(ch, 20), clip(r.get('cause', ''), 60)))
    if t == 'operator' and op == 'limits-drift' and r.get('action') != 'reverted':
        emit('limits-drift', str(r.get('key', '-')), 'live=%s lock=%s action=%s' % (r.get('live'), r.get('lock'), r.get('action')))
    # --- quota / 429 / 403 / org-disabled, anchored to message/error fields (never the whole line: run ids and shas contain 429/403)
    fields = list(MSG_ALWAYS) + (list(MSG_ALARM) if t == 'alarms' else [])
    hit = None
    if QUOTA.search(op):
        hit = op
    for f in fields:
        v = r.get(f)
        if hit is None and isinstance(v, str) and QUOTA.search(v):
            hit = '%s:%s' % (f, v)
    if hit is not None:
        emit('quota-429', ref, 'match=%s' % clip(hit, 120))
    # --- idle slot: slots.counted < slots.max_runs with >= 1 eligible queued PRD in the tick's skipped list for > IDLE_S
    if t == 'daemon' and op == 'tick':
        sl = r.get('slots') or {}
        try:
            n = len(sl.get('counted') or []); mx = int(sl.get('max_runs') or 0)
        except Exception:
            n, mx = 0, 0
        reasons = {}
        for s in r.get('skipped') or []:
            rs = str(s.get('reason', ''))
            if not NOT_ELIGIBLE.match(rs):
                k = rs.split(':')[0] if rs.startswith('prefix-cap') else rs.split('=')[0].split(':')[0]
                reasons[k] = reasons.get(k, 0) + 1
        elig = sum(reasons.values())
        if mx > 0 and n < mx and elig > 0 and not r.get('admitted'):
            if idle_since is None:
                idle_since = now
            if now - idle_since >= IDLE_S and not idle_fired:
                idle_fired = True
                emit('idle-slot', '-', 'slots.counted=%d<slots.max_runs=%d eligible(skipped.reason)=%d %s' % (n, mx, elig, ','.join('%s=%d' % kv for kv in sorted(reasons.items()))))
        else:
            idle_since, idle_fired = None, False

def feed(lines):
    for line in lines:
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        handle(d, time.time())

def follow(path):
    p = subprocess.Popen(['tail', '-n0', '-F', path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    fd, buf = p.stdout.fileno(), b''
    try:
        while True:
            r, _, _ = select.select([fd], [], [], 30)
            if not r:
                print('HB', flush=True)          # EPIPE here when the ssh is gone -> we exit and the finally kills tail
                continue
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                return
            buf += chunk
            *lines, buf = buf.split(b'\n')
            feed(l.decode('utf-8', 'replace') for l in lines)
    finally:
        p.kill()

if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--follow':
        follow(sys.argv[2])
    else:
        feed(sys.stdin)
