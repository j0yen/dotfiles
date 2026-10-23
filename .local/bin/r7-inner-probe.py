# r7-inner-probe.py -- run ON ryzen7 by r7-mon-inner-stall (python3 -I - [--selftest] < this file). READ-ONLY: state.db via mode=ro, systemctl show/list, stat.
# Prints  PROBE<TAB>what<TAB>run/slug<TAB>active(0|1)<TAB>values   for every open run / active inner unit each pass (active=0 lets the carbon side clear the edge).
#   what = inner-stall      ONLY while the unit's cgroup holds a `claude -p` process: newest coder session JSONL under ~/.claude/projects/<wt path, every non-alnum -> '-'> older than 15 min AND the unit active > 15 min
#          inner-post-coder-long  no claude in the cgroup but pybuilder/pytest present = phase post-coder (timeout 5400s pybuilder refresh -> uv run pytest; writes no session JSONL, so a
#                          stale JSONL means nothing there); bell only when that phase has run > 5400 s + 600 s (oldest pybuilder/pytest process age)
#          inner-no-session unit active > 15 min, the dir has zero JSONLs and the phase is not post-coder
#          stage-stale      no progress for > 4 h (newest of run.started, steps.started/ended, land.updated); the values carry the run state (paused / daemon hold / unit)
# coder.stream.log is 0 bytes until exit and progress.jsonl sits at "inner: starting" the whole coder phase: NEVER read as a stall.
import sqlite3, os, re, subprocess, time, glob, datetime, sys
HOME = os.path.expanduser('~')
DB = 'file:%s/.local/state/wm-build/state.db?mode=ro' % HOME
STALL_S, STALE_S = 900, 4 * 3600

def iso(s):
    if not s: return 0.0
    s = re.sub(r'(\.\d{6})\d+', r'\1', str(s))
    try: return datetime.datetime.fromisoformat(s).timestamp()
    except Exception: return 0.0

def enc(wt): return os.path.join(HOME, '.claude', 'projects', re.sub(r'[^A-Za-z0-9]', '-', wt))

def jsonls(d):
    fs = glob.glob(os.path.join(d, '*.jsonl')) + glob.glob(os.path.join(d, '*', '*.jsonl'))
    return [(os.stat(f).st_mtime, f) for f in fs]

CG = '/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice'
POST_CODER_LONG_S = 5400 + 600

def cg_procs(unit):
    # read-only: every pid in the unit's cgroup tree -> (argv list, age seconds)
    out = []
    up = float(open('/proc/uptime').read().split()[0])
    tck = os.sysconf('SC_CLK_TCK')
    for root, _, files in os.walk(os.path.join(CG, unit)):
        if 'cgroup.procs' not in files: continue
        for pid in open(os.path.join(root, 'cgroup.procs')).read().split():
            try:
                argv = open('/proc/%s/cmdline' % pid, 'rb').read().decode('utf-8', 'replace').split('\0')
                st = int(open('/proc/%s/stat' % pid).read().rsplit(')', 1)[1].split()[19])
            except Exception: continue
            out.append((argv, up - st / tck))
    return out

def is_claude(argv):   # the coder: argv0 is `claude` and `-p` is passed. Shell snapshots/agorabus helpers that merely mention claude do not match.
    return bool(argv) and os.path.basename(argv[0]) == 'claude' and '-p' in argv[1:]

def is_post(argv):     # pybuilder refresh / pytest, directly or under timeout/uv/python
    for i, a in enumerate(argv[:6]):
        b = os.path.basename(a)
        if b in ('pybuilder', 'pytest'): return True
        if b == '-m' or a == '-m':
            if i + 1 < len(argv) and argv[i + 1] == 'pytest': return True
    return False

def phase_of(procs):
    # -> (phase, post_age_s); phase = coder | post-coder | none
    if any(is_claude(a) for a, _ in procs): return 'coder', 0.0
    ages = [age for a, age in procs if is_post(a)]
    if ages: return 'post-coder', max(ages)
    return 'none', 0.0

def unit_lines(ref, name, uage, stage, state, nfs, jage, procs):
    ph, page = phase_of(procs)
    eff = min(jage, uage) if jage is not None else uage
    L = []
    L.append('PROBE\tinner-no-session\t%s\t%d\tunit=%s unit_age=%.0fm jsonls=%d phase=%s stage=%s' % (ref, 1 if (not nfs and uage > STALL_S and ph != 'post-coder') else 0, name, uage / 60, nfs, ph, stage))
    L.append('PROBE\tinner-stall\t%s\t%d\tunit=%s phase=%s newest_jsonl_age=%s unit_age=%.0fm stage=%s state=%s' % (ref, 1 if (ph == 'coder' and nfs and eff > STALL_S) else 0, name, ph, ('%.0fm' % (jage / 60)) if jage is not None else '-', uage / 60, stage, state))
    L.append('PROBE\tinner-post-coder-long\t%s\t%d\tunit=%s phase=%s post_coder_age=%.0fm limit=%.0fm stage=%s' % (ref, 1 if (ph == 'post-coder' and page > POST_CODER_LONG_S) else 0, name, ph, page / 60, POST_CODER_LONG_S / 60, stage))
    return L

def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, timeout=20).stdout

def units():
    u = {}
    for l in sh('systemctl', '--user', 'list-units', 'wm-build-inner*', '--state=active', '--no-legend', '--plain', '--type=service').splitlines():
        n = l.split()[0] if l.split() else ''
        m = re.match(r'wm-build-inner(\d+)-', n)
        if m:
            mono = sh('systemctl', '--user', 'show', n, '-p', 'ActiveEnterTimestampMonotonic', '--value').strip()
            up = float(open('/proc/uptime').read().split()[0])
            u[int(m.group(1))] = (n, up - int(mono or 0) / 1e6)
    return u

if len(sys.argv) > 2 and sys.argv[1] == '--synthetic':
    # pure data, touches nothing: <case> -> the PROBE lines the real code path would emit for that cgroup listing
    claude = (['claude', '-p', '--model', 'sonnet'], 3000.0)
    post = lambda age: [(['timeout', '-k', '5', '5400s', 'pybuilder', 'refresh'], age), (['/x/bin/python', '/x/bin/pybuilder', 'refresh'], age - 1), (['uv', 'run', 'pytest', '-m', 'not flaky'], age - 2)]
    other = [(['wm-build', 'drive', '--run', '9'], 4000.0), (['bash', '-c', 'source /home/x/.claude/shell-snapshots/claude-snap.sh'], 100.0)]
    cases = {'post-coder': (post(2400.0) + other, 960.0), 'coder-stalled': ([claude] + other, 1200.0),
             'coder-fresh': ([claude] + other, 60.0), 'post-coder-long': (post(6100.0) + other, 960.0), 'post-coder-short': (post(3000.0) + other, 960.0)}
    procs, jage = cases[sys.argv[2]]
    print('\n'.join(unit_lines('9/synthetic-%s' % sys.argv[2], 'wm-build-inner9-a.service', 7200.0, 'inner', 'unit-active', 4, jage, procs)))
    print('PROBE-END'); sys.exit(0)

db = sqlite3.connect(DB, uri=True, timeout=5)
now = time.time()
if len(sys.argv) > 1 and sys.argv[1] == '--selftest':
    rows = db.execute('select id,slug,worktree from runs where ended is null and worktree is not null order by id desc').fetchall()
    kind = 'open run'
    if not rows:
        rows = db.execute('select id,slug,worktree from runs where worktree is not null order by id desc limit 200').fetchall(); kind = 'recent run (no open run)'
    for rid, slug, wt in rows:
        d = enc(wt)
        if os.path.isdir(d):
            print('SELFTEST db=ro units=%d encoded dir resolves for %s %s -> .../%s (%d JSONLs)' % (len(units()), kind, rid, os.path.basename(d)[-40:], len(jsonls(d))))
            sys.exit(0)
    print('SELFTEST FAIL no run whose encoded ~/.claude/projects dir exists'); sys.exit(1)

un = units()
for rid, slug, stage, wt, pat, pcause, hold, started in db.execute('select id,slug,stage,worktree,paused_at,paused_cause,train_hold_reason,started from runs where ended is null'):
    ref = '%s/%s' % (rid, slug)
    last_step = db.execute('select kind,max(coalesce(ended,started)) from steps where run_id=?', (rid,)).fetchone() or (None, None)
    land = db.execute('select stage,updated,detail from land where run_id=? order by updated desc limit 1', (str(rid),)).fetchone()
    prog = max(iso(started), iso(last_step[1]), iso(land[1]) if land else 0.0)
    state = 'paused(%s)' % re.sub(r'\s+', '_', str(pcause))[:40] if pat else ('daemon-hold(%s)' % hold if hold else ('unit-active' if rid in un else 'no-unit'))
    if land: state += ' land=%s' % re.sub(r'\s+', '_', str(land[0]))[:20]
    idle = now - prog
    print('PROBE\tstage-stale\t%s\t%d\tstage=%s state=%s idle=%.1fh last_step=%s' % (ref, 1 if idle > STALE_S else 0, stage, state, idle / 3600, last_step[0]))
    if rid in un:
        name, uage = un[rid]
        fs = jsonls(enc(wt)) if wt else []
        newest = max([m for m, _ in fs], default=0)
        jage = now - newest if newest else None
        print('\n'.join(unit_lines(ref, name, uage, stage, state, len(fs), jage, cg_procs(name))))
print('PROBE-END')
