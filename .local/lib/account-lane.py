#!/usr/bin/env python3
"""account-lane.py -- per-account / per-model-lane exhaustion state and launch selection (A1300/A1301).

Lanes: `fable` (Fable models) and `nonfable` (everything else). An account's lanes are tracked independently:
jyen.pm Fable exhaustion does not touch jyen.pm's non-Fable allowance.
Policy data: policy.json (fable.order; nonfable.primaries then nonfable.reserve only when ALL primaries are exhausted).
State: $ACCOUNT_LANE_STATE (default ~/.local/state/account-lanes): state.json (exhaustion), sessions.json (session map),
events.jsonl (append-only audit). One flock, atomic tmp+fsync+rename writes. Malformed state fails visibly (exit 76), never "empty".

Only an explicit usage-limit message establishes exhaustion. Auth, network, transient 429/overload, paid-overage prompts and
unrecognised output are classified and DO NOT change state or accounts. No credential value is read, stored or printed here.

Exit codes: 0 ok | 4 unknown evidence | 64 usage | 75 blocked (structured JSON on stdout) | 76 state/policy invalid | 77 unknown-effect resume needs ack
Test-only knobs (ignored unless ACCOUNT_LANE_TEST=1): ACCOUNT_LANE_NOW (epoch).
"""
import argparse, fcntl, json, os, re, subprocess, sys, tempfile, threading, time
from contextlib import contextmanager

MAX_RESET_HORIZON = 35 * 86400
ACCT_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SID_RE = re.compile(r"^[0-9a-f-]{36}$")


def now():
    if os.environ.get("ACCOUNT_LANE_TEST") == "1" and os.environ.get("ACCOUNT_LANE_NOW", "").isdigit():
        return int(os.environ["ACCOUNT_LANE_NOW"])
    return int(time.time())


class Invalid(Exception):
    pass


def state_dir():
    d = os.environ.get("ACCOUNT_LANE_STATE") or os.path.expanduser("~/.local/state/account-lanes")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def policy_path():
    p = os.environ.get("ACCOUNT_LANE_POLICY")
    if p:
        return p
    here = os.path.dirname(os.path.realpath(__file__))
    for c in (os.path.join(here, "..", "..", ".config", "account-lanes", "policy.json"),
              os.path.expanduser("~/.config/account-lanes/policy.json")):
        if os.path.isfile(c):
            return c
    return os.path.expanduser("~/.config/account-lanes/policy.json")


def load_policy():
    try:
        with open(policy_path()) as f:
            p = json.load(f)
        fo = p["lanes"]["fable"]["order"]; nf = p["lanes"]["nonfable"]
        lists = [fo, nf["primaries"], nf.get("reserve", [])]
        for l in lists:
            if not isinstance(l, list) or not all(isinstance(a, str) and ACCT_RE.match(a) for a in l):
                raise Invalid("policy lists must be arrays of account names")
        if not fo or not nf["primaries"]:
            raise Invalid("policy needs fable.order and nonfable.primaries")
        return {"fable": list(fo), "primaries": list(nf["primaries"]), "reserve": list(nf.get("reserve", []))}
    except Invalid:
        raise
    except Exception as e:
        raise Invalid("policy unreadable/malformed (%s)" % type(e).__name__)


@contextmanager
def locked():
    fd = os.open(os.path.join(state_dir(), "lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _read(name, key):
    path = os.path.join(state_dir(), name)
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            d = json.load(f)
        if not isinstance(d, dict) or d.get("version") != 1 or not isinstance(d.get(key), dict):
            raise ValueError("shape")
        return d[key]
    except Exception:
        raise Invalid("%s is malformed; refusing to guess (repair or remove it after review)" % name)


def _write(name, key, val):
    path = os.path.join(state_dir(), name)
    fd, tmp = tempfile.mkstemp(dir=state_dir(), prefix=name + ".")
    with os.fdopen(fd, "w") as f:
        json.dump({"version": 1, key: val}, f, sort_keys=True)
        f.flush(); os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def audit(event, **kw):
    kw.update(ts=now(), event=event)
    with open(os.path.join(state_dir(), "events.jsonl"), "a") as f:
        f.write(json.dumps(kw, sort_keys=True) + "\n")


def lane_of(model):
    m = (model or "").lower()
    return "fable" if (m == "fable" or m.startswith("claude-fable-")) else "nonfable"


def lane_key(acct, lane):
    return "%s|%s" % (acct, lane)


def validate_exhaustion(ex):
    for k, e in ex.items():
        a, _, l = k.partition("|")
        if not ACCT_RE.match(a) or l not in ("fable", "nonfable") or not isinstance(e, dict) \
                or not isinstance(e.get("since"), int) or not (e.get("reset_at") is None or isinstance(e.get("reset_at"), int)):
            raise Invalid("state.json entry %r is malformed; refusing to guess" % k)


def live_exhaustion(ex, t, expire_audit=True):
    """Return {key: entry} still exhausted at t. Entries with a reliable reset_at <= t are expired (audited by caller)."""
    live, gone = {}, []
    for k, e in ex.items():
        if e["reset_at"] is not None and e["reset_at"] <= t:
            gone.append(k)
        else:
            live[k] = e
    return live, gone


def load_exhaustion_expiring(persist):
    ex = _read("state.json", "exhausted"); validate_exhaustion(ex)
    live, gone = live_exhaustion(ex, now())
    if gone and persist:
        _write("state.json", "exhausted", live)
        for k in gone:
            audit("reset_expired", key=k, reset_at=ex[k]["reset_at"])
    return live


# ---- classification -----------------------------------------------------------------------------------------------
# Contract (R1): a quota exhaustion is the CLI's terminal usage-limit message "hit your (session|usage|weekly) limit" (optionally
# "· resets ..."; bare "429 usage_limit_reached" is the same event). Wording seen in operator notes (secondhand, not captured here):
#   "You've hit your session limit · resets 5pm" / "You've hit your weekly limit · resets Nov 6, 1pm (America/Los_Angeles)".
# Everything else that mentions a limit (rate limit, context limit, spend/paid cap, "reached the maximum ...") is NOT exhaustion.
# Message text is untrusted: stream-json input is judged only by its LAST terminal {"type":"result","is_error":true} event (tool output,
# user text and assistant text never count); plain text is judged only when it is a short failure line (<= 400 chars, <= 3 lines).
QUOTA = re.compile(r"\bhit your (session|usage|weekly) limit\b")
AUTH = re.compile(r"\b40[13]\b|unauthorized|invalid[_ ]api[_ ]key|invalid (oauth )?token|token (has )?expired|authentication[_ ]error|/login|not logged in")
NET = re.compile(r"econnrefused|econnreset|etimedout|enotfound|eai_again|connection (error|refused|reset|timed out)|network|socket hang up|timed out|\bdns\b")
TRANSIENT = re.compile(r"rate[_ ]limit|overloaded|try again|temporarily|\b(529|503)\b")
TRANSIENT_BARE = re.compile(r"\b429\b")
PAID = re.compile(r"extra usage|overage|credit balance|billing|purchase more|spend limit|spending limit|monthly limit|budget")
CONTEXT = re.compile(r"context (window|length|limit)|maximum context|too many tokens|prompt is too long|max(imum)? (output )?tokens")
PLAIN_MAX = 400
# OBSERVED (tests/fixtures/account-lanes/observed-quota.jsonl, saved CLI transcripts): the whole message is exactly
#   "You've hit your session limit · resets 8:20am (America/Los_Angeles)" / "... weekly limit · resets Nov 2, 8pm (America/Los_Angeles)".
# A quota line is trusted only as a WHOLE message (nothing before or after it); an embedded/quoted phrase is never exhaustion.
ANCHOR = re.compile(r"^(?:you(?:'|\u2019)ve )?hit your (session|usage|weekly) limit(?: [\u00b7\u2219] resets [^\n]{1,80})?$")


def extract_message(text):
    """-> (kind, message). kind: message | no_terminal_error | too_long | empty.
    Structured (JSON) input is trusted only as a clean event stream: EVERY non-empty line is a JSON object and the LAST one is the terminal
    {"type":"result", error} event. A corrupt/truncated/mixed stream or a result-looking event that is not last yields nothing."""
    raw = (text or "").strip()
    if not raw:
        return "empty", ""
    lines = [l for l in raw.splitlines() if l.strip()]
    if any(l.lstrip().startswith("{") for l in lines):
        objs = []
        for l in lines:
            try:
                o = json.loads(l)
            except ValueError:
                return "no_terminal_error", ""
            if not isinstance(o, dict):
                return "no_terminal_error", ""
            objs.append(o)
        r = objs[-1]
        if r.get("type") != "result":
            return "no_terminal_error", ""
        if r.get("is_error") is not True and not str(r.get("subtype", "")).startswith("error"):
            return "no_terminal_error", ""
        m = r.get("result") if isinstance(r.get("result"), str) else r.get("error") if isinstance(r.get("error"), str) else ""
        return ("message", m[:2000]) if m else ("empty", "")
    if len(raw) > PLAIN_MAX or len(lines) > 3:
        return "too_long", ""
    return "message", raw


def classify(text):
    kind, msg = extract_message(text)
    if kind != "message":
        return "unknown", "no trusted terminal failure message (%s)" % kind
    t = msg.lower()
    quota = bool(QUOTA.search(t))
    if CONTEXT.search(t) and not quota:
        return "context", "context/token limit"
    if quota:
        if not ANCHOR.match(t.strip()):
            return "unknown", "usage-limit phrase is embedded in other text (not a whole trusted message)"
        if AUTH.search(t) or NET.search(t) or TRANSIENT.search(t) or CONTEXT.search(t):
            return "unknown", "usage-limit phrase mixed with other failure evidence"
        return "exhaustion", "usage-limit message"
    if PAID.search(t):
        return "paid_required", "paid/spend/overage cap (never a fallback, never exhaustion)"
    if AUTH.search(t):
        return "auth", "authentication failure"
    if NET.search(t):
        return "network", "network failure"
    if TRANSIENT.search(t) or TRANSIENT_BARE.search(t):
        return "transient", "transient rate limit/overload"
    return "unknown", "unrecognised output"


def valid_reset(ep, t):
    return isinstance(ep, int) and not isinstance(ep, bool) and t < ep <= t + MAX_RESET_HORIZON


def parse_reset(text, t):
    """Reset epoch from 'resets <Mon D, H[:MM]am>' or 'resets H[:MM]am' (LA time). None unless reliable (future, <= 35 d)."""
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo
    la = ZoneInfo("America/Los_Angeles")
    s = (text or "").lower()
    m = re.search(r"resets?\s+(?:([a-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap])m", s)
    if not m:
        return None
    mon, day, h, mi, ap = m.groups()
    h = int(h); mi = int(mi or 0)
    if not (1 <= h <= 12 and mi < 60):
        return None
    h = h % 12 + (12 if ap == "p" else 0)
    nowdt = datetime.fromtimestamp(t, la)
    try:
        if mon:
            mo = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].index(mon) + 1
            cand = datetime(nowdt.year, mo, int(day), h, mi, tzinfo=la)
            if cand.timestamp() < t - 86400:
                cand = cand.replace(year=nowdt.year + 1)
        else:
            cand = nowdt.replace(hour=h, minute=mi, second=0, microsecond=0)
            if cand.timestamp() <= t:
                cand += timedelta(days=1)
    except (ValueError, IndexError):
        return None
    ep = int(cand.timestamp())
    return ep if t < ep <= t + MAX_RESET_HORIZON else None


# ---- selection -----------------------------------------------------------------------------------------------------
def block(code, detail, **kw):
    out = {"ok": False, "blocked": True, "code": code, "detail": detail}
    out.update(kw)
    print(json.dumps(out, sort_keys=True))
    return 75


def rr_get():
    d = _read("rr.json", "rr")
    n = d.get("nonfable", 0)
    if not isinstance(n, int) or isinstance(n, bool) or n < 0:
        raise Invalid("rr.json is malformed; refusing to guess (repair or remove it after review)")
    return n


def select(lane, live, pol, rr=0):
    """Fable: first non-exhausted of the order. Non-Fable: the installed round-robin (A1221) over the primaries, starting at slot rr % len(primaries)
    and skipping exhausted primaries; the reserve only when ALL primaries are exhausted."""
    ex = lambda a: lane_key(a, lane) in live
    if lane == "fable":
        for a in pol["fable"]:
            if not ex(a):
                return a, ["fable lane: first non-exhausted of %s" % ",".join(pol["fable"])]
        return None, ["fable lane exhausted on every permitted account (%s)" % ",".join(pol["fable"])]
    prim = pol["primaries"]; k = rr % len(prim)
    for a in prim[k:] + prim[:k]:
        if not ex(a):
            return a, ["nonfable lane: primary %s (round-robin slot %d, skipped exhausted primaries)" % (a, rr)]
    for a in pol["reserve"]:
        if not ex(a):
            return a, ["nonfable lane: all primaries exhausted, reserve %s non-Fable allowance available" % a]
    return None, ["nonfable lane exhausted on primaries and reserve"]


def permitted(lane, pol):
    return pol["fable"] if lane == "fable" else pol["primaries"] + pol["reserve"]


# ---- sessions ------------------------------------------------------------------------------------------------------
def starttime(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            return int(f.read().rsplit(")", 1)[1].split()[19])
    except Exception:
        return None


def alive(c):
    return isinstance(c, dict) and isinstance(c.get("pid"), int) and starttime(c["pid"]) is not None and starttime(c["pid"]) == c.get("start")


def cmd_select(a):
    pol = load_policy()
    with locked():
        live = load_exhaustion_expiring(persist=True)
    lane = a.lane if a.lane else lane_of(a.model)
    with locked():
        rr = rr_get()
    acct, why = select(lane, live, pol, rr)
    if acct is None:
        return block("lane_exhausted", why[0], lane=lane)
    print(json.dumps({"ok": True, "account": acct, "lane": lane, "reasons": why}, sort_keys=True))
    return 0


def cmd_check(a):
    pol = load_policy()
    lane = a.lane or lane_of(a.model)
    if a.account not in permitted(lane, pol):
        return block("account_not_permitted", "%s is not permitted in the %s lane" % (a.account, lane), lane=lane, account=a.account)
    with locked():
        live = load_exhaustion_expiring(persist=True)
    if lane_key(a.account, lane) in live:
        return block("lane_exhausted", "%s %s lane is exhausted" % (a.account, lane), lane=lane, account=a.account)
    print(json.dumps({"ok": True, "account": a.account, "lane": lane}, sort_keys=True))
    return 0


def cmd_classify(a):
    c, d = classify(sys.stdin.read()[-16384:])
    print(json.dumps({"class": c, "detail": d}, sort_keys=True))
    return 0 if c != "unknown" else 4


def record_evidence(acct, lane, text, source, session="", reset_epoch=None):
    """Lane is TRUSTED metadata from the caller (selected model/account); message text never changes it."""
    pol = load_policy()
    if lane not in ("fable", "nonfable"):
        raise Invalid("lane must come from trusted launch metadata")
    c, d = classify(text)
    if c != "exhaustion":
        with locked():
            audit("evidence_ignored", account=acct, lane=lane, cls=c, source=source)
        return c, False
    if acct not in permitted(lane, pol):
        raise Invalid("%s not permitted in %s lane" % (acct, lane))
    t = now()
    # Reset: a strict future epoch from a trusted caller, else the "resets <time>" text form; anything else stays unknown.
    reset = reset_epoch if valid_reset(reset_epoch, t) else parse_reset(text, t)
    return _write_exhaustion(acct, lane, reset, source, session), True


def _write_exhaustion(acct, lane, reset, source, session):
    t = now()
    with locked():
        ex = _read("state.json", "exhausted"); validate_exhaustion(ex)
        k = lane_key(acct, lane); old = ex.get(k)
        if old and old["reset_at"] is not None and (reset is None or reset < old["reset_at"]):
            reset = old["reset_at"]          # never shorten or drop a known reset (no oscillation)
        ex[k] = {"since": old["since"] if old else t, "reset_at": reset, "source": source}
        _write("state.json", "exhausted", ex)
        audit("exhausted", key=k, reset_at=reset, source=source, session=session)
        if session and SID_RE.match(session):
            ss = _read("sessions.json", "sessions")
            if session in ss:
                ss[session]["unknown_effect"] = True; _write("sessions.json", "sessions", ss)
    return "exhaustion"


STRUCTURED_SOURCES = ("seat-tick-quota-wait",)


def cmd_record(a):
    if not ACCT_RE.match(a.account):
        return 64
    lane = a.lane or (lane_of(a.model) if a.model else "")
    if not lane:
        print(json.dumps({"ok": False, "code": "lane_required", "detail": "pass --lane or --model (trusted metadata; text never picks the lane)"})); return 64
    c, rec = record_evidence(a.account, lane, sys.stdin.read()[-16384:], a.source, a.session or "", a.reset_epoch)
    print(json.dumps({"class": c, "recorded": rec}, sort_keys=True))
    return 0 if (rec or c != "unknown") else 4


def cmd_record_structured(a):
    """Trusted structured evidence (seat-tick quota_wait_until observed by the watcher). Source allowlisted; no free text."""
    if not ACCT_RE.match(a.account) or a.source not in STRUCTURED_SOURCES:
        return block("structured_source_refused", "source must be one of %s" % ",".join(STRUCTURED_SOURCES))
    pol = load_policy()
    if a.account not in permitted(a.lane, pol):
        return block("account_not_permitted", "%s not permitted in %s lane" % (a.account, a.lane))
    t = now(); reset = a.reset_epoch if valid_reset(a.reset_epoch, t) else None
    _write_exhaustion(a.account, a.lane, reset, a.source, "")
    print(json.dumps({"recorded": True, "reset_at": reset}, sort_keys=True)); return 0


def cmd_clear(a):
    if len(a.reason) < 8 or not a.by:
        return block("audit_required", "clear needs --by and a --reason of at least 8 chars")
    with locked():
        ex = _read("state.json", "exhausted"); validate_exhaustion(ex)
        k = lane_key(a.account, a.lane)
        if k not in ex:
            print(json.dumps({"ok": True, "cleared": False})); return 0
        del ex[k]; _write("state.json", "exhausted", ex)
        audit("cleared_by_hand", key=k, by=a.by, reason=a.reason)
    print(json.dumps({"ok": True, "cleared": True})); return 0


def cmd_status(a):
    pol = load_policy()
    with locked():
        live = load_exhaustion_expiring(persist=False)
        ss = _read("sessions.json", "sessions")
    print(json.dumps({"exhausted": live, "sessions": len(ss), "policy": pol}, sort_keys=True)); return 0


def cmd_session_claim(a):
    """Atomically select (for a fresh session) or validate (for a resume) the account and claim SID for PID. Prints JSON.
    Selection happens INSIDE the lock, so an exhaustion record cannot slip between select and claim (R6)."""
    pol = load_policy()
    lane = a.lane or lane_of(a.model)
    if not SID_RE.match(a.session):
        return block("bad_session_id", "session id is not a UUID")
    with locked():
        live = load_exhaustion_expiring(persist=True)
        ss = _read("sessions.json", "sessions")
        old = ss.get(a.session)
        pinned = False; rr_adv = None
        if old is None and a.resume:
            if not a.adopt_account:
                return block("session_unmapped", "this session has no recorded account; resuming it on a policy-selected account would be a silent transfer. "
                             "Start a new session with a handoff summary, or adopt explicitly with a verified prior account and an audited reason.",
                             session=a.session, safe_boundary=True)
            if not (len(a.adopt_reason) >= 8 and a.adopt_by) or a.adopt_account not in permitted(lane, pol) or not _verified_prior(a.evidence_log, a.session, a.adopt_account):
                return block("adopt_unverified", "adoption needs --adopt-by, --adopt-reason (>=8 chars), an account permitted in the lane, and a prior launch row naming this session and account in the evidence log",
                             session=a.session, safe_boundary=True)
            old = {"account": a.adopt_account, "lane": lane, "state": "adopted", "unknown_effect": True, "claim": None}
            audit("session_adopted", session=a.session, account=a.adopt_account, by=a.adopt_by, reason=a.adopt_reason)
        if old is not None and not a.resume:
            return block("session_exists", "session id already mapped; fresh launches need a new id", session=a.session)
        if old is None:
            rr = rr_get()
            acct, why = select(lane, live, pol, rr)
            if acct is None:
                return block("lane_exhausted", why[0], lane=lane)
            if lane == "nonfable" and acct in pol["primaries"]:
                rr_adv = rr; _write("rr.json", "rr", {"nonfable": rr + 1})   # counter advances only with a claimed allocation (abort restores it)
            if a.account and a.account != acct:
                audit("selection_changed", session=a.session, hint=a.account, selected=acct)
        else:
            if not isinstance(old, dict) or old.get("lane") not in ("fable", "nonfable") or not ACCT_RE.match(str(old.get("account", ""))):
                raise Invalid("sessions.json entry for %s is malformed" % a.session)
            if alive(old.get("claim")):
                return block("duplicate_live_session", "session %s is held by a live process" % a.session, session=a.session)
            if old["lane"] != lane:
                return block("model_switch_unsupported", "native in-session Fable<->non-Fable switching is unsupported; start a new session with a handoff summary",
                             session=a.session, recorded_lane=old["lane"], requested_lane=lane)
            r = old["account"]
            if r in permitted(lane, pol) and lane_key(r, lane) not in live:
                acct = r; pinned = True       # resume stays on the recorded account while it is usable
            else:
                sel, _ = select(lane, live, pol, rr_get())
                return block("account_transfer_unsupported", "native session account transfer is not proven supported; start a new session on %s with a handoff summary" % (sel or "an available account"),
                             session=a.session, from_account=r, policy_account=sel, safe_boundary=True)
            if old.get("state") != "clean" or old.get("unknown_effect"):
                if not a.ack_unknown_effect:
                    print(json.dumps({"ok": False, "blocked": True, "code": "unknown_effect", "session": a.session, "state": old.get("state"),
                                      "detail": "previous run did not end with an observed clean completion (failure, kill, stale/interrupted claim, or exhaustion); effects of any in-flight mutation are unknown; "
                                                "mutating tasks are never replayed automatically. Inspect, then ack explicitly."}, sort_keys=True))
                    return 77
        prev = None
        if old is not None:
            prev = {k: v for k, v in old.items() if k != "prev"}
        ss[a.session] = {"account": acct, "lane": lane, "model": a.model or "", "ts": now(), "state": "running", "unknown_effect": False,
                         "claim": {"pid": a.pid, "start": starttime(a.pid)}, "prev": prev}
        if rr_adv is not None:
            ss[a.session]["rr_adv"] = rr_adv
        _write("sessions.json", "sessions", ss)
        audit("session_claim", session=a.session, account=acct, lane=lane, resume=bool(a.resume), pinned=pinned, ack_unknown_effect=bool(a.ack_unknown_effect))
    print(json.dumps({"ok": True, "account": acct, "lane": lane, "resume": bool(a.resume), "pinned": pinned}, sort_keys=True))
    return 0


def cmd_session_abort(a):
    """Undo a claim for a launch that never started (e.g. missing credential): restore the previous entry or drop the fresh one."""
    with locked():
        ss = _read("sessions.json", "sessions")
        e = ss.get(a.session)
        if isinstance(e, dict) and "prev" in e:
            if isinstance(e.get("rr_adv"), int) and rr_get() == e["rr_adv"] + 1:
                _write("rr.json", "rr", {"nonfable": e["rr_adv"]})   # the allocation never started: give the slot back (a missing credential must not rotate)
            if e["prev"] is None:
                del ss[a.session]
            else:
                ss[a.session] = e["prev"]
            _write("sessions.json", "sessions", ss); audit("session_abort", session=a.session)
    return 0


def _verified_prior(path, sid, acct):
    try:
        with open(path) as f:
            for l in f:
                try:
                    r = json.loads(l)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("session") == sid and r.get("account") == acct and r.get("decision") == "launch":
                    return True
    except Exception:
        return False
    return False


def _mark_session(sid, rc):
    """End-of-run record. rc 0 marks the session clean ONLY if nothing independently flagged it unknown_effect while it ran
    (exhaustion evidence tagged with the session, `session-mark-unknown`); a successful exit never erases that signal."""
    try:
        with locked():
            ss = _read("sessions.json", "sessions")
            e = ss.get(sid)
            if isinstance(e, dict):
                mine = isinstance(e.get("claim"), dict) and e["claim"].get("pid") == os.getpid()
                if not mine:
                    audit("session_end_skipped", session=sid, rc=rc, why="claim superseded")
                    return
                if rc == 0 and not e.get("unknown_effect"):
                    e["state"] = "clean"
                else:
                    e["state"] = "failed" if rc != 0 else "unknown"; e["unknown_effect"] = True
                _write("sessions.json", "sessions", ss)
                audit("session_end", session=sid, rc=rc, state=e["state"])
    except Invalid as ex:
        sys.stderr.write("account-lane: session end not recorded: %s\n" % ex)


def cmd_session_mark_unknown(a):
    if len(a.reason) < 8 or not a.by:
        return block("audit_required", "mark-unknown needs --by and a --reason of at least 8 chars")
    with locked():
        ss = _read("sessions.json", "sessions")
        if a.session not in ss:
            return block("session_unmapped", "no such session", session=a.session)
        ss[a.session]["unknown_effect"] = True; _write("sessions.json", "sessions", ss)
        audit("session_marked_unknown", session=a.session, by=a.by, reason=a.reason)
    print(json.dumps({"ok": True})); return 0


SI_KERNEL = 0x80


def _supervise(p, session):
    """Wait for p while turning signals sent to THIS process into forwarded signals. A terminal ^C is delivered to the whole foreground process
    group (SI_KERNEL), so the child already has it and it is not forwarded again; an explicit kill -INT/-TERM/-HUP/-QUIT of the supervisor
    (SI_USER) is forwarded. Unsupported (declared): SIGSTOP/SIGTSTP/SIGCONT sent to the supervisor alone."""
    import signal
    sigs = [signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT]
    while p.poll() is None:
        info = signal.sigtimedwait(sigs, 0.2)
        if info is None:
            continue
        if info.si_signo == signal.SIGINT and info.si_code == SI_KERNEL:
            continue
        try:
            p.send_signal(info.si_signo)
        except ProcessLookupError:
            pass
        try:
            with locked():
                audit("signal_forwarded", signal=info.si_signo, session=session or "", si_code=info.si_code)
        except Exception:
            pass
    return p.wait()


def max_event_line():
    """Per-event-line cap for stream observation (bytes). Production 8 MiB; ACCOUNT_LANE_MAX_EVENT_LINE only with ACCOUNT_LANE_TEST=1."""
    v = os.environ.get("ACCOUNT_LANE_MAX_EVENT_LINE", "")
    if os.environ.get("ACCOUNT_LANE_TEST") == "1" and v.isdigit() and int(v) > 0:
        return int(v)
    return 8 * 1024 * 1024


RETAINED_KEYS = ("type", "subtype", "is_error", "result", "error", "terminal_reason", "api_error_status", "api_error", "session_id", "modelUsage")


class StreamObserver:
    """Incremental validation of a stream-json stdout (explicitly selected by the CLI's --output-format). Every complete line is parsed as it
    arrives; memory is bounded by ONE event line (cap), never by the stream length. Retained: only the last complete event (type/subtype/is_error/
    result/error), plus flags. NOTHING is inferred from a raw byte tail: a corrupt, non-JSON, non-object or oversized (unverifiable) line anywhere
    in the stream makes the whole stream unusable with a recorded reason (fail closed). The terminal-event rule stays in extract_message:
    the LAST event must be {"type":"result", error}. Partial final line without newline is validated like any other line when the stream ends."""
    def __init__(self, cap=None):
        self.cap = cap or max_event_line()
        self.buf = bytearray(); self.skipping = False
        self.bad = ""; self.last = None; self.n = 0

    def _line(self, b):
        if b.endswith(b"\r"):
            b = b[:-1]
        if not b.strip():
            return
        self.n += 1
        if len(b) > self.cap:
            self.bad = self.bad or "event line %d exceeds the %d-byte cap (cannot be validated)" % (self.n, self.cap); return
        try:
            o = json.loads(b.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self.bad = self.bad or "corrupt event line %d (not valid JSON)" % self.n; return
        except Exception as e:                     # e.g. RecursionError on a deeply nested line: untrusted, never raised into the pump
            self.bad = self.bad or "event line %d could not be parsed (%s)" % (self.n, type(e).__name__); return
        if not isinstance(o, dict):
            self.bad = self.bad or "corrupt event line %d (not a JSON object)" % self.n; return
        self.last = {k: o[k] for k in RETAINED_KEYS if k in o}

    def feed(self, chunk):
        """Never raises Exception: an observer failure makes the stream sticky-untrusted (class name only in the reason, no event text) and the
        caller keeps draining/forwarding. BaseException (KeyboardInterrupt, SystemExit) is deliberately not caught."""
        try:
            if os.environ.get("ACCOUNT_LANE_TEST") == "1" and os.environ.get("ACCOUNT_LANE_INJECT") == "feed":
                raise RuntimeError("injected")
            self._feed(chunk)
        except Exception as e:
            self.bad = self.bad or "observer failure in feed (%s)" % type(e).__name__
            self.buf = bytearray(); self.last = None; self.skipping = False

    def _feed(self, chunk):
        while chunk:
            i = chunk.find(b"\n")
            if self.skipping:                      # discarding the rest of an oversized line (already recorded as unusable)
                if i < 0:
                    return
                self.skipping = False; chunk = chunk[i + 1:]; continue
            part = chunk if i < 0 else chunk[:i]
            if len(self.buf) + len(part) > self.cap + 1:
                self.n += 1
                self.bad = self.bad or "event line %d exceeds the %d-byte cap (cannot be validated)" % (self.n, self.cap)
                self.buf = bytearray(); self.last = None
                if i < 0:
                    self.skipping = True; return
                chunk = chunk[i + 1:]; continue
            self.buf += part
            if i < 0:
                return
            line = bytes(self.buf); self.buf = bytearray(); self._line(line); chunk = chunk[i + 1:]

    def finish(self):
        try:
            if os.environ.get("ACCOUNT_LANE_TEST") == "1" and os.environ.get("ACCOUNT_LANE_INJECT") == "finish":
                raise RuntimeError("injected")
            return self._finish()
        except Exception as e:
            return "", self.bad or "observer failure in finish (%s)" % type(e).__name__

    def _finish(self):
        """-> (text, reason). text = the terminal event re-serialised for extract_message ('' when unusable); reason explains an unusable stream."""
        if self.buf:
            line = bytes(self.buf); self.buf = bytearray(); self._line(line)
        if self.skipping and not self.bad:
            self.bad = "oversized event line"
        if self.bad:
            return "", self.bad
        if self.last is None:
            return "", ""
        return json.dumps(self.last), ""


class JsonEnvelopeObserver:
    """--output-format json: stdout is ONE JSON result object written by the CLI. Bounded (one cap-sized buffer); never raises Exception.
    finish() -> (retained dict | None, reason). Anything but a single JSON object (extra text, truncation, over cap, bad UTF-8) is untrusted."""
    def __init__(self, cap=None):
        self.cap = cap or max_event_line()
        self.buf = bytearray(); self.bad = ""

    def feed(self, chunk):
        try:
            if os.environ.get("ACCOUNT_LANE_TEST") == "1" and os.environ.get("ACCOUNT_LANE_INJECT") == "jsonfeed":
                raise RuntimeError("injected")
            if self.bad:
                return
            if len(self.buf) + len(chunk) > self.cap:
                self.bad = "json result exceeds the %d-byte cap (cannot be validated)" % self.cap; self.buf = bytearray(); return
            self.buf += chunk
        except Exception as e:
            self.bad = self.bad or "observer failure in feed (%s)" % type(e).__name__; self.buf = bytearray()

    def finish(self):
        try:
            if self.bad:
                return None, self.bad
            if not self.buf.strip():
                return None, ""
            o = json.loads(bytes(self.buf).decode("utf-8"))
            if not isinstance(o, dict):
                return None, "json result is not a single object"
            return {k: o[k] for k in RETAINED_KEYS if k in o}, ""
        except Exception as e:
            return None, "json result could not be parsed (%s)" % type(e).__name__


# OBSERVED native Fable-limit contract (saved native output of a real ctl-fable-escalate run, evidence 1794340620-alarm-b09a; NOT synthetic):
# a terminal result with is_error=true, terminal_reason=api_error, api_error_status=429, api_error=model_requires_usage_credits, empty modelUsage
# and the result text below. Authority comes ONLY from the trusted launch metadata (lane=fable from the selected model, a permitted account)
# plus this exact terminal envelope read from the CLI's own --output-format json / stream-json channel. 429 alone, other api_error values,
# generic credit/spend/overage text, other models/lanes, a non-terminal or model-authored event never qualify.
NATIVE_FABLE_LIMIT_TEXT = ("You've reached your Fable limit. Switch to another model, or manage usage credits at "
                           "https://claude.ai/settings/usage?from=cc_cli_limit_message, to continue.")


def native_fable_limit(obj, lane, native_sid, rc):
    """-> (ok, reason). Pure check of a retained terminal object against the observed contract and trusted launch metadata."""
    if lane != "fable":
        return False, "native Fable-limit message is only authority for the fable lane (selected lane %s)" % lane
    if rc <= 0 or rc == 124 or rc > 128:
        return False, "run did not end with a plain non-zero exit (rc %s)" % rc
    if not isinstance(obj, dict) or obj.get("type") != "result" or obj.get("is_error") is not True:
        return False, "no terminal error result"
    st = obj.get("api_error_status")
    if isinstance(st, bool) or st != 429 or obj.get("api_error") != "model_requires_usage_credits" or obj.get("terminal_reason") != "api_error":
        return False, "terminal error is not the observed model_requires_usage_credits / api_error / 429 shape"
    if obj.get("modelUsage"):
        return False, "a model produced usage; not the observed refusal shape"
    if obj.get("result") != NATIVE_FABLE_LIMIT_TEXT:
        return False, "result text is not the exact observed Fable-limit message"
    # A session id WAS handed to the CLI: the result must carry exactly that id. Missing, null, non-string, empty or different = fail closed.
    ok, why = _sid_rule(obj, native_sid)
    if not ok:
        return False, why
    return True, "observed native Fable-limit contract"


def _sid_rule(obj, native_sid):
    """-> (ok, reason). Same explicit-SID binding for every native terminal envelope: a passed id needs the exact id back."""
    sid = obj.get("session_id")
    if native_sid:
        if not isinstance(sid, str) or not sid:
            return False, "a session id was passed to the CLI but the result carries no usable session_id (safe block, not adopted)"
        if sid != native_sid:
            return False, "native session_id does not match the session id passed to the CLI (safe block, not adopted)"
    return True, ""


def nonfable_limit_envelope(obj, lane, native_sid, rc):
    """OBSERVED non-Fable terminal envelope (real Sonnet 5.5 headless json run, sanitized copy tests/fixtures/account-lanes/native-nonfable-429-observed.json):
    type=result, is_error=true, terminal_reason=api_error, api_error_status=429, result = the anchored "You've hit your session|usage|weekly limit [· resets ...]".
    -> (ok, reason, text): text is the minimal anchored envelope handed to the ordinary classifier (reset parsing, auth/network/spend/mixed rejection stay there).
    Authority: trusted nonfable launch metadata + the CLI's own --output-format channel (the caller only passes json/stream-json terminals here)."""
    if lane != "nonfable":
        return False, "observed non-Fable envelope is only authority for the nonfable lane (selected lane %s)" % lane, ""
    if rc <= 0 or rc == 124 or rc > 128:
        return False, "run did not end with a plain non-zero exit (rc %s)" % rc, ""
    if not isinstance(obj, dict) or obj.get("type") != "result" or obj.get("is_error") is not True:
        return False, "no terminal error result", ""
    st = obj.get("api_error_status")
    if isinstance(st, bool) or not isinstance(st, int) or st != 429 or obj.get("terminal_reason") != "api_error":
        return False, "terminal error is not the observed api_error / numeric 429 shape", ""
    msg = obj.get("result")
    if not isinstance(msg, str) or not ANCHOR.match(msg.lower().strip()):
        return False, "result is not an anchored whole session/usage/weekly limit message", ""
    ok, why = _sid_rule(obj, native_sid)
    if not ok:
        return False, why, ""
    return True, "observed non-Fable 429 envelope", json.dumps({"type": "result", "is_error": True, "result": msg})


def record_native_fable_limit(acct, lane, session, native_sid, obj, source):
    """Retire acct's Fable lane (no reset known: stays until audited clear). Records the SID discrepancy honestly; never adopts or clears sessions."""
    pol = load_policy()
    if acct not in permitted(lane, pol):
        raise Invalid("%s not permitted in %s lane" % (acct, lane))
    r = _write_exhaustion(acct, lane, None, source, session)
    nsid = obj.get("session_id") if isinstance(obj.get("session_id"), str) else ""
    corr = "matches the session id passed to the CLI" if (native_sid and nsid == native_sid) else \
        ("none: no session id was passed to the CLI (unpinned run); evidence is the supervisor-owned child's own output, native session_id differs from the claimed supervisor key and is NOT correlated" if nsid else "none: no session id was passed to the CLI (unpinned run) and the result carries no session_id")
    with locked():
        audit("native_fable_limit", account=acct, lane=lane, claimed_session=session, native_session_id=nsid, sid_correlation=corr)
    return r


def plain_failure_message(so, se, rc):
    """The single plain-text message we are willing to judge: the CLI's STDERR when it is exactly one line.
    STDOUT is never judged as plain text: it is the model-output channel, and no real plain `claude -p` quota failure has been observed
    on stdout or stderr (tests/fixtures/account-lanes/README.md), so a quoted OR bare-exact phrase on stdout cannot retire an account, even
    with a non-zero rc. Plain stdout quota detection stays unsupported until that channel is observed. A killed/timed-out run
    (rc<0, 124, >128) yields nothing."""
    if rc < 0 or rc == 124 or rc > 128:
        return ""
    sl = [l for l in se.splitlines() if l.strip()]
    return sl[0].strip() if len(sl) == 1 else ""


def cmd_run(a):
    """Supervise a launch (never exec'd, so the claim pid stays live). Headless: stdout/stderr pass through, tails kept for classification.
    --tty: inherited stdio. Any non-zero/signalled exit marks the session unknown_effect; rc 0 marks it clean unless something independent
    flagged it. Exhaustion is classified only from headless output (an interactive TUI is not observable: declared unsupported)."""
    import signal
    tails = {"e": b""}; obs = None
    sigs = [signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT]
    # A launcher started from a non-interactive `&`/nohup inherits SIGINT/SIGQUIT as IGNORED, and an ignored signal is discarded before it can be
    # collected. Install a no-op handler so the signal stays pending for sigtimedwait, and give the child back the disposition it would have had.
    orig = {sg: signal.getsignal(sg) for sg in sigs}
    for sg in sigs:
        signal.signal(sg, lambda *_a: None)
    old = signal.pthread_sigmask(signal.SIG_BLOCK, sigs)

    def unblock():
        for sg in sigs:
            signal.signal(sg, signal.SIG_IGN if orig[sg] == signal.SIG_IGN else signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_SETMASK, [])
    try:
        if a.tty:
            p = subprocess.Popen(a.cmd, preexec_fn=unblock)
            rc = _supervise(p, a.session)
        else:
            p = subprocess.Popen(a.cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=unblock)

            obs = StreamObserver() if a.output_format == "stream-json" else JsonEnvelopeObserver() if a.output_format == "json" else None

            def pump(src, dst, k):
                for chunk in iter(lambda: src.read1(4096), b""):
                    dst.buffer.write(chunk); dst.buffer.flush()
                    if k == "o":
                        if obs is not None:
                            obs.feed(chunk)       # stdout is judged only as a validated stream-json stream / single json envelope, never from a byte tail
                    else:
                        tails[k] = (tails[k] + chunk)[-16384:]   # stderr: only an exactly-one-line message is judged, a tail is enough
            th = [threading.Thread(target=pump, args=(p.stdout, sys.stdout, "o")), threading.Thread(target=pump, args=(p.stderr, sys.stderr, "e"))]
            [x.start() for x in th]
            rc = _supervise(p, a.session)
            [x.join() for x in th]
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old)
        for sg in sigs:
            signal.signal(sg, orig[sg])
    if not a.tty and rc != 0:
        se = tails["e"].decode("utf-8", "replace")
        # stream-json: judge the validated stdout stream (terminal result only). Plain text: only a whole trusted single message on a trusted channel.
        # The parsing mode comes from the CLI's own --output-format (carried by the launcher), NEVER from what stdout looks like.
        # Only an explicitly selected stream-json may use structured terminal evidence; text/json/plain stdout is model content.
        text = plain_failure_message("", se, rc)
        term = None; reported = False
        if isinstance(obs, JsonEnvelopeObserver) and not (rc < 0 or rc == 124 or rc > 128):
            term, why = obs.finish()
            if why:
                sys.stderr.write("account-lane: json evidence: %s; not trusted (no state change from stdout)\n" % why)
        if isinstance(obs, StreamObserver) and not (rc < 0 or rc == 124 or rc > 128):
            stext, why = obs.finish()
            if not why:
                term = obs.last
            if why:
                sys.stderr.write("account-lane: stream evidence: %s; stream not trusted (no state change from stdout)\n" % why)
                if not text:
                    text = "{"           # unusable stream: classifies unknown (never falls back to a byte tail)
            elif stext and a.lane != "nonfable":
                text = stext   # structured judgement (clean stream, last event = terminal error result); anything else classifies as unknown
            # NONFABLE stream-json has no weaker fallback: only the observed-shape gate below (status/terminal_reason/type/is_error/anchored text/exact SID/exit)
            # may record from stdout; a refused terminal stays unknown. Only the trusted one-line stderr message can still apply (text above).
        # (a plain/text/json run, and a stream-json run with empty stdout, fall back to the trusted stderr whole-line message above)
        try:
            if term is not None:
                ok, nwhy = native_fable_limit(term, a.lane, a.native_sid, rc)
                if ok:
                    record_native_fable_limit(a.account, a.lane, a.session or "", a.native_sid, term, "headless-native-fable-limit")
                    sys.stderr.write("account-lane: failure classified exhaustion via the observed native Fable-limit contract (lane exhaustion recorded; native session id %s; no automatic account switch of this run)\n"
                                     % ("matches" if a.native_sid and term.get("session_id") == a.native_sid else "not correlated with the claimed session"))
                    text = None; reported = True
                elif a.lane == "nonfable":
                    ok2, why2, etext = nonfable_limit_envelope(term, a.lane, a.native_sid, rc)
                    if ok2:
                        c, rec = record_evidence(a.account, a.lane, etext, "headless-native-envelope", a.session or "")
                        if rec:
                            nsid = term.get("session_id") if isinstance(term.get("session_id"), str) else ""
                            with locked():
                                audit("native_envelope_limit", account=a.account, lane=a.lane, claimed_session=a.session or "", native_session_id=nsid,
                                      sid_correlation=("matches the session id passed to the CLI" if a.native_sid and nsid == a.native_sid else
                                                       "none: no session id was passed to the CLI (unpinned run); evidence is the supervisor-owned child's own output"))
                        sys.stderr.write("account-lane: failure classified %s via the observed non-Fable 429 envelope%s\n" % (c, " (lane exhaustion recorded; no automatic account switch of this run)" if rec else " (no state change, no fallback)"))
                        text = None; reported = True
                    elif term.get("api_error") == "model_requires_usage_credits" or term.get("result") == NATIVE_FABLE_LIMIT_TEXT:
                        sys.stderr.write("account-lane: native limit-shaped result not accepted: %s\n" % nwhy)   # prior Fable-contract diagnostic, unchanged
                    elif term.get("type") == "result" or term.get("api_error_status") is not None or term.get("terminal_reason") == "api_error":
                        sys.stderr.write("account-lane: non-Fable limit-shaped result not accepted: %s\n" % why2)
                elif term.get("api_error") == "model_requires_usage_credits" or term.get("result") == NATIVE_FABLE_LIMIT_TEXT:
                    sys.stderr.write("account-lane: native limit-shaped result not accepted: %s\n" % nwhy)
            if not reported:      # an accepted native contract already printed its single classification line
                c, rec = record_evidence(a.account, a.lane, text or "", "headless-run", a.session or "")
                sys.stderr.write("account-lane: failure classified %s%s\n" % (c, " (lane exhaustion recorded; no automatic account switch of this run)" if rec else " (no state change, no fallback)"))
        except Invalid as e:
            sys.stderr.write("account-lane: evidence not recorded: %s\n" % e)
    if a.session and SID_RE.match(a.session):
        _mark_session(a.session, rc)
    return rc if rc >= 0 else 128 - rc


def main():
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="c", required=True)
    def add(n, f, **opts):
        s = sp.add_parser(n); s.set_defaults(f=f)
        for o, kw in opts.items():
            s.add_argument("--" + o.replace("_", "-"), **kw)
        return s
    S = {"type": str, "default": ""}
    add("select", cmd_select, lane={**S, "choices": ["", "fable", "nonfable"]}, model=S)
    add("check", cmd_check, account={"required": True}, lane={**S, "choices": ["", "fable", "nonfable"]}, model=S)
    add("classify", cmd_classify)
    add("record", cmd_record, account={"required": True}, lane={**S, "choices": ["", "fable", "nonfable"]}, model=S, source={"default": "stdin"},
        session=S, reset_epoch={"type": int, "default": None})
    add("record-structured", cmd_record_structured, account={"required": True}, lane={"required": True, "choices": ["fable", "nonfable"]},
        source={"required": True}, reset_epoch={"type": int, "default": None})
    add("clear", cmd_clear, account={"required": True}, lane={"required": True, "choices": ["fable", "nonfable"]}, by={"default": ""}, reason={"default": ""})
    add("status", cmd_status)
    sc = add("session-claim", cmd_session_claim, session={"required": True}, account=S, pid={"type": int, "required": True},
             lane={**S, "choices": ["", "fable", "nonfable"]}, model=S, adopt_account=S, adopt_by=S, adopt_reason=S, evidence_log=S)
    sc.add_argument("--ack-unknown-effect", action="store_true"); sc.add_argument("--resume", action="store_true")
    add("session-abort", cmd_session_abort, session={"required": True})
    add("session-mark-unknown", cmd_session_mark_unknown, session={"required": True}, by={"default": ""}, reason={"default": ""})
    r = add("run", cmd_run, account={"required": True}, lane={"required": True, "choices": ["fable", "nonfable"]}, session=S)
    r.add_argument("--native-sid", default=""); r.add_argument("--tty", action="store_true"); r.add_argument("--output-format", choices=["text", "json", "stream-json"], default="text")
    r.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    if a.c == "run":
        a.cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd   # only the supervisor's own leading separator; later literal "--" belong to the child
        if not a.cmd:
            return 64
    try:
        return a.f(a)
    except Invalid as e:
        print(json.dumps({"ok": False, "blocked": True, "code": "state_invalid", "detail": str(e)}, sort_keys=True))
        return 76


if __name__ == "__main__":
    sys.exit(main())
