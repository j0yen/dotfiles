#!/usr/bin/env python3
"""handover-monitor.py: model-free Stage A handover monitor (Hermes task model-free-handover-monitor-20261106, ledger A1150).

  run          one collect -> normalize -> diff -> alert pass (cron `no_agent` script; stdout stays empty = silent)
  ack KEY|all  acknowledge active alerts (suppresses reminders until the condition clears)
  status       print active alerts and counters

Unchanged state => ZERO inference requests and zero sends. A model is called only for NEW meaningful events, always
`claude -p --model claude-haiku-5-5` (pinned, not overridable, no fallback to any other model). Alerts are built and
delivered in code (`hermes send`, no LLM); a triage failure only tags the alert `triage-unavailable`.
Env (tests): HM_CONFIG HM_STATE HM_CLAUDE HM_SEND HM_SYSTEMCTL HM_SEAT_EVENT HM_NOW.
"""
import fcntl, glob, hashlib, json, os, re, subprocess, sys, time

HAIKU = "claude-haiku-5-5"   # real ID, seen rc=0 in ~/.cache/aide/event-route/model-calls.log with claude CLI 2.1.293
HOME = os.path.expanduser("~")
FB = HOME + "/wintermute-operations/feedback"
DEFAULT_CFG = {
    "target": "discord:1564394044195606568",
    "stale_minutes": 45,
    "repeat_minutes": {"default": 60, "missing-evidence": 360, "unit-down": 360},
    "units": ["ctl-dispatch.path", "ctl-event-bridge.service"],
    "receipts": [
        {"id": "handover-status", "path": FB + "/hermes-handover-stage-a-status.md", "kind": "md"},
        {"id": "model-free-receipt", "path": FB + "/model-free-handover-monitor-20261106.receipt.md", "kind": "md"},
        {"id": "router-proof", "path": HOME + "/wintermute-operations/ctl-pre-fable-routing-proof-20261106.json", "kind": "json"},
    ],
    "progress_paths": [FB + "/*.receipt.md", FB + "/*.task.md", HOME + "/Notes/ctl-*-2026*.md",
                       HOME + "/.cache/aide/event-bridge/status.json"],
    "deadlines": [{"id": "model-free-cutover", "due": "2026-11-07T01:30:00-08:00", "satisfied_by": "cutover:model-free"}],
    "cutover": {"id": "model-free", "timer": "handover-monitor.timer"},
    "stall": {"substantive_minutes": 10, "ack_minutes": 5, "ctl_seat": "ctl", "hermes_seat": "hermes"},
    "tasks": [{"id": "model-free-monitor", "title": "model-free handover monitor replacement (A1150)",
               "receipt": FB + "/model-free-handover-monitor-20261106.receipt.md",
               "evidence_paths": [HOME + "/.cache/coder-clones/dotfiles-model-free-monitor/.local/bin/*.py",
                                  HOME + "/.cache/coder-clones/dotfiles-model-free-monitor/tests/*.sh",
                                  HOME + "/.cache/coder-clones/dotfiles-model-free-monitor/.config/systemd/user/*"],
               "git_dir": HOME + "/.cache/coder-clones/dotfiles-model-free-monitor",
               "worker_stream_globs": [HOME + "/wintermute-operations/*model-free*.jsonl"],
               "worker_units": ["ctl-model-free*"],
               "done_requires": "cutover:model-free"}],
    "cron_file": HOME + "/.hermes/cron/jobs.json",
    "cron_ids": ["378a97370a05"],
    "hold_file": HOME + "/wintermute-operations/quota-conservation/HOLD.json",
    "ledger": HOME + "/wintermute-operations/hermes-trial.tsv",
}
LOCAL_KINDS = ("stalled", "deadline-missed", "provider-failure", "unit-down", "notification-failure")
QUOTA_RE = re.compile(r"usage limit|429|rate.?limit|quota|overloaded|credit", re.I)


def now():
    return int(os.environ.get("HM_NOW") or time.time())


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(t))


def hhmm(t):
    return time.strftime("%H:%M", time.localtime(t))


def wjson(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        json.dump(obj, f, sort_keys=True, indent=1)
    os.replace(path + ".tmp", path)


def rjson(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


def load_cfg():
    cfg = dict(DEFAULT_CFG)
    p = os.environ.get("HM_CONFIG")
    if p:
        cfg.update(json.load(open(p)))
    return cfg


class State:
    def __init__(self):
        self.dir = os.environ.get("HM_STATE") or HOME + "/.cache/aide/handover-monitor"
        os.makedirs(self.dir + "/outbox", exist_ok=True)
        self.snap = rjson(self.dir + "/snapshot.json", None)
        self.alerts = rjson(self.dir + "/alerts.json", {})
        self.meta = rjson(self.dir + "/meta.json", {})

    def save(self, snap):
        wjson(self.dir + "/snapshot.json", snap)
        wjson(self.dir + "/alerts.json", self.alerts)
        wjson(self.dir + "/meta.json", self.meta)

    def log(self, name, line):
        with open(self.dir + "/" + name, "a") as f:
            f.write(line + "\n")


# ---------------------------------------------------------------- collect
def collect(cfg):
    facts = {"units": {}, "receipts": {}, "progress": {}, "cron": {}, "hold": None, "ledger": None}
    sysctl = os.environ.get("HM_SYSTEMCTL") or "systemctl"
    for u in cfg["units"]:
        try:
            out = subprocess.run([sysctl, "--user", "show", "-p", "LoadState,ActiveState,SubState", u],
                                 capture_output=True, text=True, timeout=20).stdout
            kv = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
            facts["units"][u] = "%s/%s" % (kv.get("LoadState", "?"), kv.get("ActiveState", "?"))
        except Exception as e:
            facts["units"][u] = "probe-failed:" + type(e).__name__
    for r in cfg["receipts"]:
        facts["receipts"][r["id"]] = read_evidence(r["path"], r.get("kind", "md"))
    for pat in cfg["progress_paths"]:
        for fp in sorted(glob.glob(pat))[:300]:
            try:
                facts["progress"][fp] = sha(fp) if os.path.getsize(fp) < 5_000_000 else "big:%d" % os.path.getsize(fp)
            except Exception:
                facts["progress"][fp] = "unreadable"
    # cron jobs: read-only; only enabled/state/last_status/last_error (no timestamps)
    jobs = rjson(cfg["cron_file"], {}).get("jobs", []) if cfg.get("cron_file") else []
    for j in jobs:
        if j.get("id") in cfg.get("cron_ids", []):
            facts["cron"][j["id"]] = {"enabled": j.get("enabled"), "state": j.get("state"),
                                      "last_status": j.get("last_status"), "last_error": j.get("last_error")}
    facts["cutover"] = cutover_facts(cfg, facts)
    if cfg.get("hold_file"):
        facts["hold"] = read_evidence(cfg["hold_file"], "json")
    if cfg.get("ledger"):
        facts["ledger"] = read_evidence(cfg["ledger"], "md")
    return facts


def read_evidence(path, kind):
    if not os.path.isfile(path):
        return "missing"
    try:
        if os.path.getsize(path) == 0:
            return "malformed:empty"
        if kind == "json":
            json.load(open(path))
        return "ok:" + sha(path)
    except Exception:
        return "malformed:unparseable"


def cutover_facts(cfg, facts):
    """Cutover = installed timer active AND a scheduled (timer-triggered) run executed AND a real delivery succeeded.
    A receipt file existing is NOT cutover."""
    c = cfg.get("cutover") or {}
    d = os.environ.get("HM_STATE") or HOME + "/.cache/aide/handover-monitor"
    sysctl = os.environ.get("HM_SYSTEMCTL") or "systemctl"
    timer = c.get("timer", "")
    try:
        out = subprocess.run([sysctl, "--user", "show", "-p", "ActiveState", timer], capture_output=True, text=True, timeout=20).stdout
        active = "ActiveState=active" in out
    except Exception:
        active = False
    def has(name, needle):
        try:
            return any(needle in l for l in open(os.path.join(d, name)))
        except Exception:
            return False
    sched = has("runs.log", "trigger=timer")
    allow_test = bool(os.environ.get("HM_TEST_CUTOVER"))     # stub deliveries (HM_SEND) count only inside tests
    try:
        deliv = any(" ok " in l + " " and (allow_test or not l.rstrip().endswith(" test")) for l in open(os.path.join(d, "delivery.log")))
    except Exception:
        deliv = False
    return {"timer_active": active, "scheduled_run": sched, "delivery_ok": deliv, "ok": active and sched and deliv}


# ---------------------------------------------------------------- derive
def progress_sig(facts):
    blob = json.dumps([facts["progress"], facts["receipts"]], sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()[:12]


def due_epoch(s):
    return int(subprocess.run(["date", "-d", s, "+%s"], capture_output=True, text=True).stdout.strip() or 0)


def satisfied(spec, facts):
    kind, _, name = spec.partition(":")
    if kind == "receipt":
        return facts["receipts"].get(name, "missing").startswith("ok:")
    if kind == "unit":
        return facts["units"].get(name, "").endswith("/active")
    if kind == "cutover":
        return facts.get("cutover", {}).get("ok", False)
    return False


def conditions(cfg, facts, st, t):
    """Level conditions: key -> (kind, detail). Active while true."""
    c = {}
    for u, s in facts["units"].items():
        if not s.endswith("/active"):
            c["unit-down:" + u] = ("unit-down", "%s state %s" % (u, s))
    for rid, s in facts["receipts"].items():
        if s == "missing":
            c["missing-evidence:" + rid] = ("missing-evidence", "receipt %s not found" % rid)
        elif s.startswith("malformed"):
            c["malformed-evidence:" + rid] = ("malformed-evidence", "receipt %s %s" % (rid, s))
    for name, s in (("hold", facts["hold"]), ("ledger", facts["ledger"])):
        if s is None:
            continue
        if s == "missing" and name == "ledger":
            c["missing-evidence:ledger"] = ("missing-evidence", "trial ledger not found")
        elif s.startswith("malformed"):
            c["malformed-evidence:" + name] = ("malformed-evidence", "%s %s" % (name, s))
    for jid, j in facts["cron"].items():
        err = "%s %s" % (j.get("last_status"), j.get("last_error"))
        if j.get("last_status") not in (None, "ok") or j.get("last_error"):
            kind = "provider-failure" if QUOTA_RE.search(err) else "job-failure"
            c["%s:cron:%s" % (kind, jid)] = (kind, "cron %s: %s" % (jid, err.strip()[:160]))
    unmet = []
    for d in cfg.get("deadlines", []):
        if not satisfied(d["satisfied_by"], facts):
            unmet.append(d["id"])
            if d.get("due") and t > due_epoch(d["due"]):
                c["deadline-missed:" + d["id"]] = ("deadline-missed", "%s due %s not satisfied" % (d["id"], d["due"]))
    changed_at = st.meta.get("progress_changed_at", t)
    if unmet and t - changed_at >= cfg["stale_minutes"] * 60:
        c["stalled"] = ("stalled", "no content change in %d min; unmet: %s" % ((t - changed_at) // 60, ",".join(unmet)))
    return c


def edges(prev, cur):
    """Edge events from a snapshot diff: only content/state changes, never timestamps."""
    ev = {}
    if prev is None:
        return ev
    if prev.get("sig") != cur["sig"]:
        changed = sorted(k for k in set(prev["facts"]["progress"]) | set(cur["facts"]["progress"])
                         if prev["facts"]["progress"].get(k) != cur["facts"]["progress"].get(k))
        changed += sorted(k for k in cur["facts"]["receipts"] if prev["facts"]["receipts"].get(k) != cur["facts"]["receipts"][k])
        ev["progress:" + cur["sig"]] = ("progress", "content changed: " + ", ".join(os.path.basename(x) for x in changed[:6]))
    if prev["facts"].get("hold") != cur["facts"].get("hold"):
        ev["hold-changed:" + str(cur["facts"].get("hold"))] = ("hold-changed", "hold file now %s" % cur["facts"].get("hold"))
    for jid, j in cur["facts"]["cron"].items():
        pj = prev["facts"]["cron"].get(jid)
        if pj is not None and (pj.get("enabled"), pj.get("state")) != (j.get("enabled"), j.get("state")):
            ev["cron-changed:%s:%s:%s" % (jid, j.get("enabled"), j.get("state"))] = (
                "cron-changed", "cron %s enabled=%s state=%s" % (jid, j.get("enabled"), j.get("state")))
    return ev


# ---------------------------------------------------------------- triage + delivery
def triage(events, st, t):
    """One Haiku call for the batch. Returns (summary|None, needs_hermes, failed_reason|None)."""
    claude = os.environ.get("HM_CLAUDE") or "claude"
    prompt = ("Classify these Stage A handover monitor events. Reply ONLY JSON "
              '{"severity":"low|med|high","summary":"<=25 words","needs_hermes":true|false}. needs_hermes=true only for '
              "scope, authority or conflicting-evidence questions.\n" + json.dumps(events, sort_keys=True))
    rec = {"ts": iso(t), "model": HAIKU, "events": len(events), "rc": None}
    out = err = ""
    try:
        p = subprocess.run([claude, "-p", "--model", HAIKU, "--output-format", "json", "--tools", "", "--no-session-persistence",
                            "--disable-slash-commands", "--setting-sources", ""], input=prompt, capture_output=True,
                           text=True, timeout=120, env=dict(os.environ, WM_ROUTER="1"))
        rec["rc"], out, err = p.returncode, p.stdout, p.stderr
    except Exception as e:
        rec["error"] = type(e).__name__
        st.log("model-calls.log", json.dumps(rec, sort_keys=True))
        return None, False, "triage-unavailable"
    reason = None
    try:
        o = json.loads(out)
        rec["usage"], rec["total_cost_usd"] = o.get("usage"), o.get("total_cost_usd")
        if o.get("is_error") or p.returncode != 0:
            reason = "quota" if QUOTA_RE.search(out + err) else "error"
            res = None
        else:
            res = json.loads(o.get("result") or "{}")
    except Exception:
        res = None
        reason = reason or ("quota" if QUOTA_RE.search(out + err) else "malformed")
    rec["ok"] = reason is None and res is not None
    st.log("model-calls.log", json.dumps(rec, sort_keys=True))
    if reason or not isinstance(res, dict):
        return None, False, reason or "malformed"
    return str(res.get("summary", ""))[:200], bool(res.get("needs_hermes")), None


def deliver(msg, cfg, st):
    send = os.environ.get("HM_SEND") or "hermes"
    try:
        p = subprocess.run([send, "send", "--to", cfg["target"], msg], capture_output=True, text=True, timeout=60)
        ok = p.returncode == 0
    except Exception:
        ok = False
    st.log("delivery.log", "%s %s %s" % (iso(now()), "ok" if ok else "fail", cfg["target"]) + (" test" if os.environ.get("HM_SEND") else ""))
    return ok


def seat_event(line):
    return seat_event_to("ctl", line)


def seat_event_to(seat, line):
    cmd = os.environ.get("HM_SEAT_EVENT") or HOME + "/.local/bin/seat-event.sh"
    try:
        return subprocess.run([cmd, seat, line], capture_output=True, timeout=30).returncode == 0
    except Exception:
        return False


def send_or_spool(msg, cfg, st, t):
    if deliver(msg, cfg, st):
        return True
    n = len(os.listdir(st.dir + "/outbox"))
    with open("%s/outbox/%d-%04d.txt" % (st.dir, t, n), "w") as f:
        f.write(msg)
    if not st.meta.get("notify_failing"):
        st.meta["notify_failing"] = t
        seat_event("handover-monitor notification delivery failing; messages spooled in %s/outbox (deterministic alert path degraded)" % st.dir)
    return False


def flush_outbox(cfg, st, t):
    files = sorted(os.listdir(st.dir + "/outbox"))
    sent = 0
    for fn in files:
        path = st.dir + "/outbox/" + fn
        body = open(path).read()
        if not deliver("[recovered: delayed delivery] " + body, cfg, st):
            return sent, False
        os.remove(path)
        sent += 1
    if st.meta.pop("notify_failing", None) and sent:
        st.log("runs.log", "%s notification delivery recovered, flushed=%d" % (iso(t), sent))
    return sent, True


# ---------------------------------------------------------------- task stall supervision (no model)
def task_evidence_sig(task):
    """Substantive evidence only: receipt CONTENT, task code/test file content, git HEAD. Never mtimes, never other tasks' files."""
    parts = []
    for fp in [task.get("receipt", "")] + [f for pat in task.get("evidence_paths", []) for f in sorted(glob.glob(pat))[:100]]:
        try:
            parts.append((fp, sha(fp)))
        except Exception:
            parts.append((fp, "-"))
    if task.get("git_dir"):
        try:
            parts.append(("HEAD", subprocess.run(["git", "-C", task["git_dir"], "rev-parse", "HEAD"], capture_output=True,
                                                 text=True, timeout=20).stdout.strip()))
        except Exception:
            pass
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()[:12]


def worker_active(task, cfg, t):
    """A genuine task-linked worker: a matching unit is active AND its task-linked stream file grew within the window.
    A live PID/unit alone (no fresh task output) is NOT proof of work."""
    sysctl = os.environ.get("HM_SYSTEMCTL") or "systemctl"
    unit_up = False
    for u in task.get("worker_units", []):
        try:
            out = subprocess.run([sysctl, "--user", "show", "-p", "ActiveState", u], capture_output=True, text=True, timeout=20).stdout
            unit_up = unit_up or "ActiveState=active" in out
        except Exception:
            pass
    window = cfg["stall"]["substantive_minutes"] * 60
    fresh = any(t - os.path.getmtime(f) < window for pat in task.get("worker_stream_globs", []) for f in glob.glob(pat))
    return unit_up and fresh


def stall_pass(cfg, st, t):
    sc = cfg["stall"]
    stalls = st.meta.setdefault("stalls", {})
    for task in cfg.get("tasks", []):
        tid = task["id"]
        rec = stalls.setdefault(tid, {})
        sig = task_evidence_sig(task)
        done = satisfied(task["done_requires"], {"cutover": cutover_facts(cfg, None), "receipts": {}, "units": {}}) if task.get("done_requires") else False
        if rec.get("sig") != sig:
            rec["sig"], rec["last_substantive"] = sig, t
            if rec.get("stalled"):          # substantive evidence after detection clears it
                st.log("runs.log", "%s stall %s CLEARED by substantive evidence" % (iso(t), tid))
                seat_event_to(sc["ctl_seat"], "handover-monitor: stall on %s cleared (substantive evidence resumed)" % tid)
                rec.pop("stalled", None); rec.pop("ack", None)
        rec.setdefault("last_substantive", t)
        if done:
            rec.pop("stalled", None)
            continue
        idle = t - rec["last_substantive"] >= sc["substantive_minutes"] * 60
        if not rec.get("stalled"):
            if idle and not worker_active(task, cfg, t):
                ev = {"task": tid, "title": task.get("title"), "detected": iso(t), "last_substantive": iso(rec["last_substantive"]),
                      "owner": sc["ctl_seat"], "rule": "no substantive evidence for %d min and no task-linked active worker" % sc["substantive_minutes"]}
                os.makedirs(st.dir + "/stalls", exist_ok=True)
                wjson("%s/stalls/%s-%d.json" % (st.dir, tid, t), ev)
                rec["stalled"] = {"since": t, "notified": {}, "last_nag": 0, "event": ev}
            else:
                continue
        s_ = rec["stalled"]
        ack = rec.get("ack")
        # ack without resumed work: re-detect after another substantive window
        if ack and t - ack["at"] >= sc["substantive_minutes"] * 60:
            s_["last_nag"] = 0
            rec["ack"] = None
            ack = None
            s_["reopened"] = t
        if ack:
            continue
        due_nag = (t - s_["last_nag"] >= sc["ack_minutes"] * 60)
        if not due_nag and s_["notified"].get("ctl") and s_["notified"].get("hermes"):
            continue
        first = not s_["last_nag"]
        n = s_.get("count", 0) + (1 if due_nag else 0)
        msg = "%sSTALL %s: %s. %s. Owner ctl; unresolved until a substantive ack/action receipt: `handover-monitor.py stall-ack %s --action TEXT` then real evidence." % (
            "" if first else "ESCALATED (no ack, notice %d) " % n, tid, s_["event"]["title"], s_["event"]["rule"], tid)
        ok1 = seat_event_to(sc["ctl_seat"], msg)
        ok2 = seat_event_to(sc["hermes_seat"], msg)
        ok3 = send_or_spool(msg, cfg, st, t)
        s_["notified"] = {"ctl": ok1 or s_["notified"].get("ctl"), "hermes": (ok2 or ok3) or s_["notified"].get("hermes")}
        if due_nag or first:
            s_["last_nag"], s_["count"] = t, n
        if not (ok1 and (ok2 or ok3)):
            s_["last_nag"] = 0          # failed delivery: retry next run, do not mark delivered
            st.log("runs.log", "%s stall %s delivery incomplete ctl=%s hermes=%s" % (iso(t), tid, ok1, ok2 or ok3))


def stall_ack(tid, action):
    st = State()
    rec = st.meta.get("stalls", {}).get(tid)
    if not rec or not rec.get("stalled"):
        print("no active stall for", tid); return
    if not action.strip():
        print("ack needs --action text"); return
    rec["ack"] = {"at": now(), "action": action[:300]}
    st.log("runs.log", "%s stall %s acked: %s (stays open until substantive evidence)" % (iso(now()), tid, action[:100]))
    wjson(st.dir + "/meta.json", st.meta)
    print("acked; stall remains open until substantive evidence")


# ---------------------------------------------------------------- run
def run():
    cfg = load_cfg()
    st = State()
    lock = open(st.dir + "/lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    t = now()
    flush_outbox(cfg, st, t)
    facts = collect(cfg)
    sig = progress_sig(facts)
    cur = {"facts": facts, "sig": sig}
    if st.snap is None or st.snap.get("sig") != sig:
        st.meta["progress_changed_at"] = t
    conds = conditions(cfg, facts, st, t)
    edge = edges(st.snap, cur)

    new, remind = {}, {}
    for key, (kind, detail) in conds.items():
        a = st.alerts.get(key)
        rep = cfg["repeat_minutes"].get(kind, cfg["repeat_minutes"]["default"]) * 60
        if a is None:
            new[key] = (kind, detail)
        elif not a.get("acked") and t - a["last_sent"] >= rep:
            remind[key] = (kind, detail)
    for key in [k for k in st.alerts if k.split(":")[0] not in ("progress", "hold-changed", "cron-changed") and k not in conds]:
        st.log("runs.log", "%s resolved %s" % (iso(t), key))
        del st.alerts[key]
    for key in [k for k, a in st.alerts.items() if k.split(":")[0] in ("progress", "hold-changed", "cron-changed")
                and t - a.get("last_sent", t) > 86400]:
        del st.alerts[key]
    for key, v in edge.items():
        if key not in st.alerts:
            new[key] = v

    calls = 0
    if new or remind:
        events = {k: {"kind": v[0], "detail": v[1]} for k, v in new.items()}
        summary, needs_hermes, failed = (None, False, None)
        if events:
            summary, needs_hermes, failed = triage(events, st, t)
            calls = 1
        lines = []
        for k, (kind, d) in list(new.items()) + [(k, (v[0], "REMINDER " + v[1])) for k, v in remind.items()]:
            lines.append("- %s: %s" % (kind, d))
        head = "%s[handover-monitor %s] %d event(s)" % ("ESCALATE-TO-HERMES " if needs_hermes else "", hhmm(t), len(lines))
        tail = ("Triage: " + summary) if summary else (("triage-unavailable (%s); deterministic alert only" % failed) if failed else "")
        if failed == "quota":
            fk = "provider-failure:triage"
            if fk not in st.alerts and fk not in new:
                lines.append("- provider-failure: Haiku triage hit a usage limit")
                st.alerts[fk] = {"first": t, "last_sent": t, "acked": False, "kind": "provider-failure"}
        elif failed is None and events and "provider-failure:triage" in st.alerts:
            del st.alerts["provider-failure:triage"]
        msg = "\n".join([head] + lines + ([tail] if tail else []))
        send_or_spool(msg, cfg, st, t)
        for k, (kind, d) in list(new.items()) + list(remind.items()):
            prev = st.alerts.get(k, {})
            st.alerts[k] = {"first": prev.get("first", t), "last_sent": t, "acked": False, "kind": kind}
            if kind in LOCAL_KINDS and k in new:
                seat_event("handover-monitor %s: %s" % (kind, d))
    stall_pass(cfg, st, t)
    st.log("runs.log", "%s sig=%s new=%d remind=%d calls=%d trigger=%s" % (
        iso(t), sig, len(new), len(remind), calls, os.environ.get("HM_TRIGGER", "manual")))
    st.save(cur)
    return 0


def ack(key):
    st = State()
    n = 0
    for k, a in st.alerts.items():
        if key == "all" or k == key:
            a["acked"], n = True, n + 1
    wjson(st.dir + "/alerts.json", st.alerts)
    print("acked %d" % n)


def status():
    st = State()
    print(json.dumps({"alerts": st.alerts, "meta": st.meta}, indent=1, sort_keys=True))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "stall-ack" and len(sys.argv) > 4 and sys.argv[3] == "--action":
        stall_ack(sys.argv[2], " ".join(sys.argv[4:]))
        sys.exit(0)
    if cmd == "run":
        sys.exit(run())
    if cmd == "ack" and len(sys.argv) > 2:
        ack(sys.argv[2])
    elif cmd == "status":
        status()
    else:
        sys.exit("usage: handover-monitor.py run | ack KEY|all | status")
