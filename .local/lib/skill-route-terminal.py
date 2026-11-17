#!/usr/bin/env python3
"""skill-route-terminal.py: the one derived, read-only view of a routed session's launch provenance and terminal outcome (A1300 FFDR R3).

It joins (a) the `decision == "launch"` rows of the skill-routing decisions log, (b) account-lane sessions.json and (c) account-lane
events.jsonl, and never writes. fable-launch.sh reads account-lane state for its nested-dispatch and review-replay checks only through it.

Usage (stdlib only, run as `python3 -I`; --decisions may stand anywhere):
  skill-route-terminal.py [--decisions PATH] session <sid>
      -> one session object
  skill-route-terminal.py [--decisions PATH] task <task_id> --skill <skill> [--role review|author] [--scope-id <id>]
      -> [session object, ...] for every session with a matching launch row, ordered by its first launch row in the log
  skill-route-terminal.py [--decisions PATH] review-ancestor --pid <pid> [--self <sid>]
      -> {"review_session": <sid>|null, "pid": <ancestor pid>|null, "reason": "..."}

Inputs: --decisions PATH | $SKILL_ROUTING_DECISIONS | ~/.local/state/skill-routing/decisions.jsonl. Account-lane state is fixed to
~/.local/state/account-lanes; ACCOUNT_LANE_STATE is honoured only under FABLE_LAUNCH_TEST=1 and refused otherwise. No policy is read.
Every file is opened O_NOFOLLOW|O_NONBLOCK, must be a regular file, and is read in one pass.

Session object: {session, launch (the first launch row: ts, task_id, skill, role, scope_id, route, model, effort, account, resume; or
null), launch_rows (count), lane ({account, lane, model, state, unknown_effect, prev, claim_live} or null), terminal {outcome, rc,
reasons}, provenance {ok, reasons}}. "Latest" is always events.jsonl append (file) order, never ts. terminal.outcome is exactly one of:
  absent            no launch row
  running           state running and the claim pid is alive with its recorded start time
  interrupted       state running and the claim is not alive
  completed         state "clean", unknown_effect JSON false, and the latest session_end of the session has rc 0 and state clean
  never-dispatched  one run that a Fable usage limit refused before any model work (see never_dispatched)
  failed            state failed without that proof
  unknown           anything else: other states, no sessions.json entry, contradictions, absent/unreadable events.jsonl,
                    malformed sessions.json (every session), malformed or partial event lines (never completed/never-dispatched)
review-ancestor walks the parent chain of --pid (up to 32 levels). An ancestor is a review ancestor when its pid and /proc start time
equal the sessions.json claim of a session with a role-review launch row, or when its argv[0] basename is `claude` or it runs
`account-lane.py run` and its argv carries --session-id/--resume/-r (or the = forms) naming such a session. --self is never one.
Every other process's argv is ignored (tmux servers, driver scripts).
Exit 0 with output (unknown included); exit 2 on a usage error, an unreadable decisions log, a refused override or a non-regular
(or symlinked) state file.
"""
import errno, json, os, re, stat, sys

MAX_DEPTH = 32
ID_FLAGS = ("--session-id", "--resume", "-r")


class Fail(Exception):
    pass


def read_file(path):
    """-> ("absent", None) | ("unreadable", why) | ("ok", bytes). A symlink or a non-regular file raises Fail (exit 2)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0))
    except FileNotFoundError:
        return "absent", None
    except OSError as e:
        if e.errno == errno.ELOOP:
            raise Fail("%s is a symlink; refusing (state files are opened O_NOFOLLOW)" % path)
        return "unreadable", "%s unreadable (%s)" % (path, errno.errorcode.get(e.errno, e.errno))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Fail("%s is not a regular file; refusing" % path)
        buf = []
        while True:
            b = os.read(fd, 1 << 20)
            if not b:
                break
            buf.append(b)
        return "ok", b"".join(buf)
    except OSError as e:
        return "unreadable", "%s unreadable (%s)" % (path, errno.errorcode.get(e.errno, e.errno))
    finally:
        os.close(fd)


def parse_lines(data):
    """-> (JSON objects in file order, malformed count). A line that is not a JSON object (a partial last line included) is malformed."""
    rows, bad = [], 0
    for line in data.decode("utf-8", "replace").split("\n"):
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except ValueError:
            bad += 1
            continue
        if isinstance(o, dict):
            rows.append(o)
        else:
            bad += 1
    return rows, bad


def lane_dir():
    d = os.environ.get("ACCOUNT_LANE_STATE", "")
    if d:
        if os.environ.get("FABLE_LAUNCH_TEST") != "1":
            raise Fail("ACCOUNT_LANE_STATE override refused outside FABLE_LAUNCH_TEST=1 (account-lane state is fixed)")
        return d
    return os.path.expanduser("~/.local/state/account-lanes")


def load_decisions(path):
    """-> ({sid: [launch rows in log order]}, [sids by first launch row], malformed count). An unreadable log is a Fail."""
    st, data = read_file(path)
    if st == "absent":
        return {}, [], 0
    if st == "unreadable":
        raise Fail("decisions log %s" % data)
    rows, bad = parse_lines(data)
    by, order = {}, []
    for r in rows:
        s = r.get("session")
        if r.get("decision") != "launch" or not isinstance(s, str) or not s:
            continue
        if s not in by:
            by[s] = []
            order.append(s)
        by[s].append(r)
    return by, order, bad


def load_sessions(d):
    """-> (sessions dict, None) | (None, why). Absent = no entries; unreadable or malformed = every session unknown."""
    st, data = read_file(os.path.join(d, "sessions.json"))
    if st == "absent":
        return {}, None
    if st == "unreadable":
        return None, "lane state unreadable"
    try:
        o = json.loads(data.decode("utf-8"))
        if not isinstance(o, dict) or o.get("version") != 1 or not isinstance(o.get("sessions"), dict):
            raise ValueError("shape")
        return o["sessions"], None
    except Exception:
        return None, "lane state malformed"


def load_events(d):
    """-> (events in file order | None, malformed count, why). None = absent or unreadable."""
    st, data = read_file(os.path.join(d, "events.jsonl"))
    if st == "absent":
        return None, 0, "events.jsonl absent"
    if st == "unreadable":
        return None, 0, "events.jsonl unreadable"
    rows, bad = parse_lines(data)
    return rows, bad, None


def lane_of(model):
    """account-lane.py lane_of: `fable` or `claude-fable-<suffix>` (any case) is the fable lane, every other model nonfable."""
    m = model.lower() if isinstance(model, str) else ""
    return "fable" if (m == "fable" or m.startswith("claude-fable-")) else "nonfable"


def role_of(row):
    return "review" if row.get("role") == "review" else "author"


def proc_stat(pid):
    """-> (ppid, start time) of a live pid, or None."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return int(fields[1]), int(fields[19])
    except Exception:
        return None


def proc_argv(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            parts = f.read().split(b"\0")
    except Exception:
        return []
    if parts and parts[-1] == b"":
        parts.pop()
    return [a.decode("utf-8", "replace") for a in parts]


def alive(c):
    """account-lane.py alive(): the claim pid runs with its recorded start time."""
    if not isinstance(c, dict) or type(c.get("pid")) is not int or c["pid"] <= 0:
        return False
    st = proc_stat(c["pid"])
    return st is not None and st[1] == c.get("start")


def never_dispatched(sid, entry, rows, E, ebad):
    """-> (proof, why not). One run, refused at start by the observed native Fable limit: entry lane fable, state failed and prev null;
    exactly one launch row (resume false) and one session_claim; a native_fable_limit for this very id (sid_correlation `matches...`,
    the entry's account and lane) after that claim and before the latest session_end, which has rc != 0 and state failed."""
    if entry.get("lane") != "fable":
        return False, "lane %r is not fable" % (entry.get("lane"),)
    if "prev" not in entry or entry["prev"] is not None:
        return False, "sessions.json prev is not null (a resumed or re-claimed session)"
    if len(rows) != 1 or rows[0].get("resume") is not False:
        return False, "not exactly one launch row with resume false (%d launch rows)" % len(rows)
    if ebad:
        return False, "events.jsonl has %d malformed or partial line(s)" % ebad
    claims = [i for i, e in enumerate(E) if e.get("event") == "session_claim" and e.get("session") == sid]
    if len(claims) != 1:
        return False, "%d session_claim events, not exactly one" % len(claims)
    ends = [i for i, e in enumerate(E) if e.get("event") == "session_end" and e.get("session") == sid]
    if not ends:
        return False, "no session_end event"
    end = E[ends[-1]]
    if type(end.get("rc")) is not int or end["rc"] == 0 or end.get("state") != "failed":
        return False, "the latest session_end is not rc != 0 with state failed"
    for i in range(claims[0] + 1, ends[-1]):
        e = E[i]
        if (e.get("event") == "native_fable_limit" and e.get("claimed_session") == sid and e.get("native_session_id") == sid
                and isinstance(e.get("sid_correlation"), str) and e["sid_correlation"].startswith("matches")
                and e.get("account") == entry.get("account") and e.get("lane") == entry.get("lane")):
            return True, ""
    return False, "no native_fable_limit for this session (matching id, account and lane) between its claim and its latest session_end"


def terminal(sid, rows, S, serr, E, ebad, eerr, dbad):
    reasons = []
    if dbad:
        reasons.append("decisions log: %d malformed line(s) skipped" % dbad)
    if ebad:
        reasons.append("events.jsonl: %d malformed or partial line(s) skipped" % ebad)
    ends = [e for e in (E or []) if e.get("event") == "session_end" and e.get("session") == sid]
    rc = ends[-1].get("rc") if ends and type(ends[-1].get("rc")) is int else None
    entry = S.get(sid) if S is not None else None
    if not rows:
        return "absent", rc, reasons + ["no launch row"]
    if S is None:
        return "unknown", rc, reasons + [serr]
    if entry is None:
        return "unknown", rc, reasons + ["launch row but no account-lane sessions.json entry"]
    if not isinstance(entry, dict):
        return "unknown", rc, reasons + ["account-lane sessions.json entry is not an object"]
    state = entry.get("state")
    if state == "running":
        if alive(entry.get("claim")):
            return "running", rc, reasons
        return "interrupted", rc, reasons + ["state running but the claim pid is not alive with its recorded start time"]
    if E is None:
        return "unknown", rc, reasons + ["%s (never completed or never-dispatched)" % eerr]
    if state == "clean":
        if ebad:
            return "unknown", rc, reasons + ["completed not provable with malformed or partial event lines"]
        if entry.get("unknown_effect") is not False:
            return "unknown", rc, reasons + ["state clean but unknown_effect is %s, not false" % json.dumps(entry.get("unknown_effect"))]
        if not ends:
            return "unknown", rc, reasons + ["state clean but no session_end event"]
        last_claim = max([i for i, e in enumerate(E) if e.get("event") == "session_claim" and e.get("session") == sid] or [-1])
        last_end = max(i for i, e in enumerate(E) if e.get("event") == "session_end" and e.get("session") == sid)
        if last_claim > last_end:
            return "unknown", rc, reasons + ["contradiction: a session_claim after the latest session_end"]
        if rc == 0 and ends[-1].get("state") == "clean":
            return "completed", rc, reasons
        return "unknown", rc, reasons + ["contradiction: state clean but the latest session_end has rc %s, state %s" %
                                         (json.dumps(ends[-1].get("rc")), json.dumps(ends[-1].get("state")))]
    if state == "failed":
        ok, why = never_dispatched(sid, entry, rows, E, ebad)
        if ok:
            return "never-dispatched", rc, reasons
        return "failed", rc, reasons + ["not never-dispatched: " + why]
    return "unknown", rc, reasons + ["account-lane state %s" % json.dumps(state)]


def provenance(sid, rows, S, serr, E, ebad, eerr):
    r = []
    if not rows:
        return False, ["no launch row"]
    if rows[0].get("resume") is not False:
        r.append("the first launch row is a resume (resume %s)" % json.dumps(rows[0].get("resume")))
    for k, get in (("task_id", lambda x: x.get("task_id")), ("role", role_of), ("scope_id", lambda x: x.get("scope_id") or ""),
                   ("model", lambda x: x.get("model")), ("effort", lambda x: x.get("effort")), ("account", lambda x: x.get("account"))):
        vals = sorted({json.dumps(get(x)) for x in rows})
        if len(vals) > 1:
            r.append("launch rows disagree on %s (%s)" % (k, ", ".join(vals)))
    entry = S.get(sid) if S is not None else None
    if S is None:
        r.append(serr)
    elif not isinstance(entry, dict):
        r.append("no account-lane sessions.json entry")
    else:
        for a in sorted({json.dumps(x.get("account")) for x in rows}):
            if json.loads(a) != entry.get("account"):
                r.append("launch-row account %s != lane account %s" % (a, json.dumps(entry.get("account"))))
        for ln in sorted({lane_of(x.get("model")) for x in rows}):
            if ln != entry.get("lane"):
                r.append("launch model lane %s != lane entry lane %s" % (ln, json.dumps(entry.get("lane"))))
        for m in sorted({json.dumps(x.get("model")) for x in rows}):
            if json.loads(m) != entry.get("model"):
                r.append("lane entry model %s != launch-row model %s" % (json.dumps(entry.get("model")), m))
    if E is None:
        r.append("%s: session_claim count not checked" % eerr)
    else:
        if ebad:
            r.append("events.jsonl: %d malformed or partial line(s): session_claim count not provable" % ebad)
        net, open_claim = 0, False
        for e in E:
            if e.get("session") != sid:
                continue
            if e.get("event") == "session_claim":
                net += 1; open_claim = True
            elif e.get("event") == "session_abort" and open_claim:
                net -= 1; open_claim = False
        if net > len(rows):
            r.append("unrouted run: %d session_claim event(s) net of aborts > %d launch row(s)" % (net, len(rows)))
    return not r, r


def view(sid, by, S, serr, E, ebad, eerr, dbad):
    rows = by.get(sid, [])
    entry = S.get(sid) if S is not None else None
    first = rows[0] if rows else None
    out = {"session": sid,
           "launch": None if first is None else {
               "ts": first.get("ts"), "task_id": first.get("task_id"), "skill": first.get("skill"), "role": role_of(first),
               "scope_id": first.get("scope_id") or "", "route": first.get("route"), "model": first.get("model"),
               "effort": first.get("effort"), "account": first.get("account"), "resume": first.get("resume")},
           "launch_rows": len(rows),
           "lane": None if not isinstance(entry, dict) else {
               "account": entry.get("account"), "lane": entry.get("lane"), "model": entry.get("model"), "state": entry.get("state"),
               "unknown_effect": entry.get("unknown_effect"), "prev": entry.get("prev"), "claim_live": alive(entry.get("claim"))}}
    outcome, rc, treasons = terminal(sid, rows, S, serr, E, ebad, eerr, dbad)
    out["terminal"] = {"outcome": outcome, "rc": rc, "reasons": treasons}
    ok, preasons = provenance(sid, rows, S, serr, E, ebad, eerr)
    out["provenance"] = {"ok": ok, "reasons": preasons}
    return out


def argv_ids(argv):
    for i, a in enumerate(argv):
        if a in ID_FLAGS and i + 1 < len(argv):
            yield argv[i + 1]
        for fl in ("--session-id=", "--resume="):
            if a.startswith(fl):
                yield a[len(fl):]


def cli_kind(argv):
    """`claude` (argv[0] basename) or `account-lane.py run` (an element whose basename is account-lane.py followed by run), else None."""
    if argv and os.path.basename(argv[0]) == "claude":
        return "claude"
    for i, a in enumerate(argv[:-1]):
        if os.path.basename(a) == "account-lane.py" and argv[i + 1] == "run":
            return "account-lane.py run"
    return None


def review_ancestor(pid, self_sid, by, S):
    reviews = {s for s, rows in by.items() if any(x.get("role") == "review" for x in rows)}
    claims = {}
    for s in reviews:
        e = S.get(s) if S is not None else None
        c = e.get("claim") if isinstance(e, dict) else None
        if isinstance(c, dict) and type(c.get("pid")) is int and type(c.get("start")) is int:
            claims[(c["pid"], c["start"])] = s
    me = proc_stat(pid)
    if me is None:
        raise Fail("no such process: --pid %d" % pid)
    p, depth = me[0], 0
    while p > 1 and depth < MAX_DEPTH:
        depth += 1
        st = proc_stat(p)
        if st is None:
            break
        s = claims.get((p, st[1]))
        if s is not None and s != self_sid:
            return {"review_session": s, "pid": p,
                    "reason": "ancestor pid %d holds the account-lane claim (pid and start time) of review session %s" % (p, s)}
        argv = proc_argv(p)
        kind = cli_kind(argv)
        if kind:
            for c in argv_ids(argv):
                if c in reviews and c != self_sid:
                    return {"review_session": c, "pid": p, "reason": "ancestor pid %d (%s) carries review session %s" % (p, kind, c)}
        p = st[0]
    return {"review_session": None, "pid": None, "reason": "no review ancestor in %d ancestor level(s)" % depth}


USAGE = ("usage: skill-route-terminal.py [--decisions PATH] session <sid> | task <task_id> --skill <skill> [--role review|author] "
         "[--scope-id <id>] | review-ancestor --pid <pid> [--self <sid>]")


def opts(args, allowed):
    """--name value pairs -> dict; anything else is a usage error."""
    o, i = {}, 0
    while i < len(args):
        a = args[i]
        if a not in allowed or i + 1 >= len(args) or a in o:
            raise Fail(USAGE)
        o[a] = args[i + 1]
        i += 2
    return o


def main(argv):
    dec, rest, i = None, [], 0
    while i < len(argv):
        if argv[i] == "--decisions":
            if i + 1 >= len(argv):
                raise Fail(USAGE)
            dec = argv[i + 1]; i += 2
        elif argv[i].startswith("--decisions="):
            dec = argv[i][len("--decisions="):]; i += 1
        else:
            rest.append(argv[i]); i += 1
    if not rest or rest[0] not in ("session", "task", "review-ancestor"):
        raise Fail(USAGE)
    cmd = rest[0]
    if cmd == "session":
        if len(rest) != 2 or not rest[1]:
            raise Fail(USAGE)
    elif cmd == "task":
        if len(rest) < 2 or not rest[1] or rest[1].startswith("--"):
            raise Fail(USAGE)
        o = opts(rest[2:], ("--skill", "--role", "--scope-id"))
        if "--skill" not in o or o.get("--role", "review") not in ("review", "author"):
            raise Fail(USAGE)
    else:
        o = opts(rest[1:], ("--pid", "--self"))
        if not o.get("--pid", "").isdigit():
            raise Fail(USAGE)
    d = lane_dir()
    path = dec or os.environ.get("SKILL_ROUTING_DECISIONS") or os.path.expanduser("~/.local/state/skill-routing/decisions.jsonl")
    by, order, dbad = load_decisions(path)
    S, serr = load_sessions(d)
    if cmd == "review-ancestor":
        return review_ancestor(int(o["--pid"]), o.get("--self"), by, S)
    E, ebad, eerr = load_events(d)
    if cmd == "session":
        return view(rest[1], by, S, serr, E, ebad, eerr, dbad)
    out = []
    for s in order:
        if any(x.get("task_id") == rest[1] and x.get("skill") == o["--skill"]
               and ("--role" not in o or role_of(x) == o["--role"])
               and ("--scope-id" not in o or (x.get("scope_id") or "") == o["--scope-id"]) for x in by[s]):
            out.append(view(s, by, S, serr, E, ebad, eerr, dbad))
    return out


if __name__ == "__main__":
    try:
        print(json.dumps(main(sys.argv[1:])))
        sys.exit(0)
    except Fail as e:
        sys.stderr.write("skill-route-terminal: %s\n" % e)
        sys.exit(2)
    except Exception as e:  # fail closed: any unexpected shape is an error, never an outcome
        sys.stderr.write("skill-route-terminal: internal error %s\n" % type(e).__name__)
        sys.exit(2)
