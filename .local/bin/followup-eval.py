#!/usr/bin/env python3
"""followup-eval: the one evaluator of open obligations (ledger ask A1346, repair of A1307).

  followup-eval.py eval   --seat S   every open obligation with its disposition (read-only)
  followup-eval.py new    --seat S   the actionable ones whose fingerprint was never delivered: persisted atomically, queued in the outbox
  followup-eval.py emit   --seat S --id I --rev R --kind K --fp F --detail D   persist ONE obligation through the same fingerprint file, flock and outbox as new
                           (exit 2 missing/invalid args, JSON error on stderr; exit 3 state unwritable, visible error)
  followup-eval.py suggestion --seat S --id I --rev R [--owner O --due D]   stdin = a final message; a suggestion with no owner + due is a defect: persisted as kind suggestion-only
                           through emit's store (exit 1 flagged, 0 clean; repeat of the same text is deduped)
  followup-eval.py reason            stdin obligations (jsonl) -> the one-line block text
  followup-eval.py replay            deliver queued outbox entries; mark delivered on rc 0 only

Disposition per obligation: verified | claimed | blocked | ready | overdue-ack | stale-worker.
  verified     acceptance verdict PASS on the row
  claimed      live claim: worker/session alive, lease unexpired, claim revision equals row revision
  blocked      structured blocker {owner, dependency, next_check > now}, or an open dependency ask that has an owner; an expired next_check stays
               blocked but is actionable (kind blocker-expired)
  ready        unclaimed and runnable: overdue with nothing accounting for it, or every dependency ask has left the open set
  overdue-ack  overdue with only a prose waits-on / PID / ACK (not a disposition), or an unreadable due
  stale-worker claim whose worker or session is dead, lease expired, or taken at an older revision
Actionable = ready | overdue-ack | stale-worker | expired blocker | verifier-pending. A fingerprint (id|rev|disposition|kind|next_check) is delivered once;
a new id, a changed revision, a changed disposition or a lapsed next_check is a new fingerprint. State: $FOLLOWUP_STATE_DIR/{fingerprints.json,outbox.jsonl,lock}
(one flock serialises check, outbox append, fingerprint write and replay; files are replaced by rename).
Env: WM_ASKS_BIN FOLLOWUP_STATE_DIR FOLLOWUP_OUTBOX FOLLOWUP_DELIVER_CMD FOLLOWUP_WORKER_ALIVE_CMD FOLLOWUP_NOW.
"""
import argparse, datetime, fcntl, hashlib, json, os, re, subprocess, sys

KNOWN = ("rb", "r7", "ctl", "aide")
PROSE = re.compile(r"waits-on=|\bPID\b|\bACK\b", re.I)


def state_dir():
    return os.environ.get("FOLLOWUP_STATE_DIR") or os.path.expanduser("~/.local/state/followup-loop")


def now_min():
    v = os.environ.get("FOLLOWUP_NOW")
    if v:
        return datetime.datetime.fromisoformat(v.replace(" ", "T")[:16]).strftime("%Y-%m-%dT%H:%M")
    return datetime.datetime.now().strftime("%Y-%m-%dT%H:%M")


def ts(v):
    if isinstance(v, str) and re.match(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}", v):
        return v[:16].replace(" ", "T")
    return ""


def alive(w):
    if not w:
        return False
    cmd = os.environ.get("FOLLOWUP_WORKER_ALIVE_CMD")
    if cmd:
        return subprocess.run([cmd, w], capture_output=True).returncode == 0
    # canonical handle form seat:<session-prefix> (wm-asks asks claim --worker ctl:42a49890): live when the bare token names a tmux session or a running process
    for tok in dict.fromkeys([w, w.split(":", 1)[-1]]):
        if len(tok) < 4:
            continue
        for probe in (["tmux", "has-session", "-t", tok], ["pgrep", "-f", "--", tok]):
            try:
                r = subprocess.run(probe, capture_output=True, text=True)
            except OSError:   # probe binary absent on this host (e.g. no tmux on ryzen7): treat as not live by that probe
                continue
            if r.returncode != 0:
                continue
            if probe[0] == "pgrep":
                # pgrep -f matches any argv containing the token, including this evaluator's own ancestors (a shell whose command line names the token): those never count
                pids = {int(x) for x in r.stdout.split() if x.isdigit()} - _ancestors()
                if not pids:
                    continue
            return True
    return False


def _ancestors():
    out, pid = {os.getpid()}, os.getppid()
    while pid > 1 and pid not in out:
        out.add(pid)
        try:
            pid = int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return out


def read_ledger():
    bin_ = os.environ.get("WM_ASKS_BIN", "wm-asks")
    try:
        p = subprocess.run([bin_, "asks", "query", "--status", "open", "--json"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, "ledger command failed: %s" % type(e).__name__
    if p.returncode != 0:
        return None, "ledger query exit %d" % p.returncode
    try:
        rows = json.loads(p.stdout)
    except ValueError:
        return None, "malformed ledger output"
    if not isinstance(rows, list) or not all(isinstance(r, dict) and isinstance(r.get("ask_id"), str) for r in rows):
        return None, "malformed ledger output"
    return rows, ""


def evaluate(seat, rows, now):
    owners = ("ctl", "aide") if seat in ("ctl", "aide") else (seat,)
    catchall = seat in ("ctl", "aide")
    open_ids = {r["ask_id"]: r for r in rows}
    out = []
    for r in rows:
        owner = str(r.get("owner") or "")
        if not (owner in owners or (catchall and owner not in KNOWN)):
            continue
        rid, rev = r["ask_id"], r.get("rev", 0)
        due = ts(r.get("due"))
        note = " (owner empty: assign an owner)" if not owner else ("" if owner in KNOWN else " (owner %s is not a known seat: reassign)" % owner)
        cw, _, stamp = str(r.get("claim") or "").partition("@")
        lease = str(r.get("claim_lease") or "")  # the @stamp in claim is the claim time, never a lease expiry
        ck = str(r.get("claim_session") or "") or cw
        acc = r.get("acceptance") if isinstance(r.get("acceptance"), dict) else {}
        verdict = str(acc.get("verdict") or "")
        if not verdict and str(r.get("accept_result") or "") == "PASS" and r.get("accept_current") is True and r.get("verdict_row"):
            verdict = "PASS"  # flat canonical shape: current PASS backed by a verifier verdict row; file-only PASS (no verdict_row) or a stale accept_current=false never counts
        waits = r.get("waits_on") if isinstance(r.get("waits_on"), list) else []
        live_nc, lapsed = [], ""
        for w in waits:
            if isinstance(w, dict):
                nc = ts(w.get("next_check"))
                if str(w.get("owner") or "") and str(w.get("dependency") or "") and nc:
                    (live_nc if nc > now else []).append(nc)
                    if nc <= now:
                        lapsed = max(lapsed, nc)
            elif isinstance(w, str) and w in open_ids:
                d = open_ids[w]
                if str(d.get("owner") or "") and ts(d.get("due")) > now:
                    live_nc.append(ts(d.get("due")))
        dep_ids = [w for w in waits if isinstance(w, str)]
        deps_cleared = bool(dep_ids) and not any(w in open_ids for w in dep_ids)

        def mk(disp, kind, detail, actionable, nc=""):
            return {"id": rid, "rev": rev, "disposition": disp, "kind": kind, "owner": owner, "next_check": nc, "due": due,
                    "detail": detail, "actionable": actionable, "fp": "%s|%s|%s|%s|%s" % (rid, rev, disp, kind, nc)}

        if r.get("verifier_required") is True and r.get("ending") is True and verdict != "PASS":
            out.append(mk("blocked", "verifier-pending", "ending action on a verifier-required row without a PASS acceptance (verdict: %s)" % (verdict or "none"), True)); continue
        if verdict == "PASS":
            out.append(mk("verified", "accepted", "PASS acceptance recorded", False)); continue
        if cw:
            if ck and not alive(ck):
                out.append(mk("stale-worker", "dead-worker", "claim by %s is stale (worker or session dead or gone)" % ck, True)); continue
            if ts(lease) and ts(lease) <= now:
                out.append(mk("stale-worker", "lease-expired", "claim lease %s expired" % ts(lease), True)); continue
            if r.get("claim_rev") is not None and r.get("claim_rev") != rev:
                out.append(mk("stale-worker", "stale-revision", "claim taken at task revision %s, row is at revision %s" % (r.get("claim_rev"), rev), True)); continue
            out.append(mk("claimed", "live-claim", "live claim by %s" % ck, False)); continue
        if not due:
            out.append(mk("overdue-ack", "bad-due", "due unreadable" + note, True)); continue
        if live_nc:
            out.append(mk("blocked", "structured-blocker", "blocked until %s" % min(live_nc), False, min(live_nc))); continue
        if lapsed:
            out.append(mk("blocked", "blocker-expired", "structured blocker next_check %s passed" % lapsed, True, lapsed)); continue
        if deps_cleared:
            out.append(mk("ready", "dependency-cleared", "every dependency (%s) left the open set; dispatch it" % ",".join(dep_ids), True)); continue
        if dep_ids:
            out.append(mk("blocked", "dependency-open", "waiting on open dependency %s" % ",".join(dep_ids), False)); continue
        if due > now:
            continue
        if PROSE.search(str(r.get("what") or "")):
            out.append(mk("overdue-ack", "prose-waits-on", "overdue since %s with only a prose waits-on / PID / ACK; record a live claim (wm-asks asks claim) or append waits-on=row:<open-ask-id> naming an open dependency ask (wm-asks asks update %s --by ctl --expect-rev %s --append waits-on=row:<id>)%s" % (due, rid, rev, note), True)); continue
        out.append(mk("ready", "overdue", "overdue since %s, no live claim and no open dependency; claim it, or append waits-on=row:<open-ask-id> (wm-asks asks update %s --by ctl --expect-rev %s --append waits-on=row:<id>)%s" % (due, rid, rev, note), True))
    return out


def read_followups(seat):
    """Overdue or escalated wm-decide follow-up ids owed by the seat, as correction-owed obligations. A missing binary, timeout or bad JSON yields none."""
    bin_ = os.environ.get("WM_DECIDE_BIN", "wm-decide")
    try:
        p = subprocess.run(["timeout", os.environ.get("WM_FOLLOWUPS_TIMEOUT", "8"), bin_, "followups", "--json", "--agent", seat],
                           capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            return []
        ids = json.loads(p.stdout).get("ids")
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError):
        return []
    out = []
    for i in ids if isinstance(ids, list) else []:
        if not isinstance(i, dict) or i.get("state") not in ("overdue", "escalated") or not isinstance(i.get("id"), str):
            continue
        age = i.get("age_h")
        out.append({"id": i["id"], "rev": 0, "disposition": "overdue-ack", "kind": "correction-owed", "owner": seat, "next_check": "", "due": "",
                    "detail": "correction owed on verdict row %s (%s, %s h)" % (i["id"], i["state"], age if age is not None else "?"),
                    "actionable": True, "fp": "%s|wmdecide|%s" % (i["id"], i["state"])})
    return out


NEXT = {
    "correction-owed": "record the applying row for the verdict (wm-decide record/verdict) or a MOOT row naming why",
    "dead-worker": "re-dispatch the work, then re-claim with a live worker handle (wm-asks asks claim <id> --worker <tmux-session|pid-token>)",
    "lease-expired": "re-dispatch the work, then re-claim with a live worker handle (wm-asks asks claim <id> --worker <tmux-session|pid-token>)",
    "stale-revision": "re-claim at the current revision (wm-asks asks claim <id> --worker <live worker>)",
    "verifier-pending": "run the required verifier and record a PASS acceptance before the ending action",
    "ledger-unreadable": "repair the canonical ledger query (wm-asks asks query --status open --json)",
    "dependency-cleared": "dispatch it to a worker now (wm-asks asks claim <id> --worker <live worker>)",
}


def reason(new):
    parts = ["%s [%s/%s] %s -> next: %s" % (n["id"], n["disposition"], n["kind"], n["detail"],
             NEXT.get(n["kind"], "claim it with a live worker, append waits-on=row:<open-ask-id> for an open dependency ask, or resolve it with a PASS acceptance")) for n in new[:5]]
    return "FOLLOW-UP ACTION REQUIRED (escalated once, queued in the outbox; an unchanged id is not recited): " + "; ".join(parts) + (" and %d more" % (len(new) - 5) if len(new) > 5 else "")


def atomic_write(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        f.write(text); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)


def locked(sd):
    os.makedirs(sd, exist_ok=True)
    fh = open(os.path.join(sd, "lock"), "w")
    fcntl.flock(fh, fcntl.LOCK_EX)
    return fh


def outbox_path(sd):
    return os.environ.get("FOLLOWUP_OUTBOX") or os.path.join(sd, "outbox.jsonl")


def superseded_ids(ob):
    """Exact (id, rev, fp, entry ts) identities recorded in the reviewed sidecar next to the outbox (followup-outbox-reconcile.py --apply); replay never delivers these."""
    side = (ob[:-6] if ob.endswith(".jsonl") else ob) + ".superseded.jsonl"
    out = set()
    try:
        for line in open(side, encoding="utf-8", errors="replace"):
            try:
                r = json.loads(line)
                out.add((str(r["id"]), str(r.get("rev", 0)), str(r["fp"]), str(r.get("entry_ts"))))
            except (ValueError, KeyError, TypeError):
                pass
    except OSError:
        pass
    return out


def cmd_new(seat):
    sd = state_dir(); fh = locked(sd)
    rows, why = read_ledger()
    if rows is None:
        obl = [{"id": "LEDGER", "rev": 0, "disposition": "blocked", "kind": "ledger-unreadable", "owner": "", "next_check": "", "due": "",
                "detail": "ledger malformed or unreadable: " + why, "actionable": True, "fp": "LEDGER|0|ledger-unreadable|" + why}]
    else:
        obl = [d for d in evaluate(seat, rows, now_min()) if d["actionable"]]
    obl += read_followups(seat)
    fp_path = os.path.join(sd, "fingerprints.json")
    try:
        seen = json.load(open(fp_path))
        if not isinstance(seen, dict):
            seen = {}
    except (OSError, ValueError):
        seen = {}
    new, stamp = [], datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    for o in obl:
        if o["fp"] in seen:
            continue
        with open(outbox_path(sd), "a") as ob:   # outbox first: a failed write leaves the fingerprint unrecorded, so the next run re-escalates
            ob.write(json.dumps(dict(o, seat=seat, ts=stamp, delivered=False), separators=(",", ":")) + "\n")
        seen[o["fp"]] = stamp
        atomic_write(fp_path, json.dumps(seen, sort_keys=True))
        new.append(o)
    fh.close()
    print(json.dumps({"new": new, "reason": reason(new) if new else "", "error": why or None}))


def die(code, msg):
    print(json.dumps({"error": msg}), file=sys.stderr)
    sys.exit(code)


def cmd_emit(a):
    missing = [n for n in ("seat", "id", "rev", "kind", "fp", "detail") if getattr(a, n) in (None, "")]
    if missing:
        die(2, "emit missing required args: " + ",".join("--" + m for m in missing))
    try:
        rev = int(a.rev)
    except ValueError:
        die(2, "emit --rev must be an integer")
    o = {"id": a.id, "rev": rev, "disposition": "ready", "kind": a.kind, "owner": a.seat, "next_check": "", "due": "",
         "detail": a.detail, "actionable": True, "fp": a.fp}
    emitted, deduped = persist(o, a.seat)
    print(json.dumps({"emitted": emitted, "deduped": deduped}))


def persist(o, seat):
    """Write one obligation through the shared fingerprint file, flock and outbox. Returns (emitted, deduped); exit 3 when the state is unwritable."""
    try:
        sd = state_dir(); fh = locked(sd)
        fp_path = os.path.join(sd, "fingerprints.json")
        try:
            seen = json.load(open(fp_path))
            if not isinstance(seen, dict):
                seen = {}
        except (OSError, ValueError):
            seen = {}
        if o["fp"] in seen:
            fh.close()
            return False, True
        stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        with open(outbox_path(sd), "a") as ob:   # outbox first, as in new
            ob.write(json.dumps(dict(o, seat=seat, ts=stamp, delivered=False), separators=(",", ":")) + "\n")
        seen[o["fp"]] = stamp
        atomic_write(fp_path, json.dumps(seen, sort_keys=True))
        fh.close()
    except OSError as e:
        die(3, "emit state unwritable: %s" % (e.strerror or type(e).__name__))
    return True, False


SUGGEST = re.compile(r"\b(i\s+(would\s+)?(recommend|suggest|propose)|we\s+should|you\s+should|should\s+(probably\s+)?be|next\s+step\s+(would|is|should)|consider\s+(adding|moving|making|using)|worth\s+(adding|doing|fixing))", re.I)


def cmd_suggestion(a):
    """Adapter over emit: a final message (stdin) that suggests work with no owned next action (--owner and a readable --due) is a defect.
    The defect is persisted as kind suggestion-only through persist(), fingerprint = id|rev|kind|sha1(normalised text). Exit 1 = flagged, 0 = clean."""
    missing = [n for n in ("seat", "id", "rev") if getattr(a, n) in (None, "")]
    if missing:
        die(2, "suggestion missing required args: " + ",".join("--" + m for m in missing))
    text = " ".join(sys.stdin.read().split())
    owned = bool(a.owner) and bool(ts(a.due))
    if not SUGGEST.search(text) or owned:
        print(json.dumps({"flagged": False})); return
    fp = "%s|%s|suggestion-only|%s" % (a.id, a.rev, hashlib.sha1(text.lower().encode()).hexdigest()[:12])
    o = {"id": a.id, "rev": a.rev, "disposition": "ready", "kind": "suggestion-only", "owner": a.seat, "next_check": "", "due": "",
         "detail": "final message suggests work with no owned next action (owner + due): " + text[:120], "actionable": True, "fp": fp}
    emitted, deduped = persist(o, a.seat)
    print(json.dumps({"flagged": True, "emitted": emitted, "deduped": deduped}))
    sys.exit(1)


def cmd_replay():
    sd = state_dir(); ob = outbox_path(sd)
    if not os.path.exists(ob):
        return
    dc = os.environ.get("FOLLOWUP_DELIVER_CMD")
    if not dc:
        here = os.path.dirname(os.path.abspath(__file__))
        for c in (os.path.join(here, "followup-deliver.sh"), os.path.expanduser("~/.local/bin/followup-deliver.sh")):
            if os.access(c, os.X_OK):
                dc = c; break
    if not dc:
        return
    fh = locked(sd); lines = []
    raw = open(ob, "rb").read(); n0 = len(raw)   # deliver.sh appends sent-part records to this file while we hold the lock: keep whatever lands after n0
    env = dict(os.environ, FOLLOWUP_LOCK_HELD="1"); sup = superseded_ids(ob)
    for line in raw.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            lines.append(line); continue
        if e.get("delivered") is False and (str(e.get("id")), str(e.get("rev", 0)), str(e.get("fp")), str(e.get("ts"))) not in sup:
            try:
                if subprocess.run([dc], input=line, text=True, capture_output=True, timeout=300, env=env).returncode == 0:
                    e["delivered"] = True
            except (OSError, subprocess.TimeoutExpired):
                pass
        lines.append(json.dumps(e, separators=(",", ":")))
    tail = open(ob, "rb").read()[n0:].decode("utf-8", "replace")
    atomic_write(ob, "\n".join(lines) + ("\n" if lines else "") + tail)
    fh.close()


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("cmd", choices=("eval", "new", "emit", "replay", "reason", "suggestion")); ap.add_argument("--seat")
    for n in ("id", "rev", "kind", "fp", "detail", "owner", "due"):
        ap.add_argument("--" + n)
    a = ap.parse_args()
    if a.cmd not in ("emit", "suggestion"):
        a.seat = a.seat or os.environ.get("WM_SEAT", "ctl")
    if a.cmd == "eval":
        rows, why = read_ledger()
        print(json.dumps({"dispositions": (evaluate(a.seat, rows, now_min()) if rows is not None else []) + read_followups(a.seat), "error": why or None}))
    elif a.cmd == "new":
        cmd_new(a.seat)
    elif a.cmd == "emit":
        cmd_emit(a)
    elif a.cmd == "suggestion":
        cmd_suggestion(a)
    elif a.cmd == "reason":   # stdin: one obligation JSON per line -> the one-line machine-actionable block text
        print(reason([json.loads(l) for l in sys.stdin if l.strip()]))
    else:
        cmd_replay()


if __name__ == "__main__":
    main()
