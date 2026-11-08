#!/usr/bin/env python3
"""followup-eval: the one evaluator of open obligations (ledger ask A1346, repair of A1307).

  followup-eval.py eval   --seat S   every open obligation with its disposition (read-only)
  followup-eval.py new    --seat S   the actionable ones whose fingerprint was never delivered: persisted atomically, queued in the outbox
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
import argparse, datetime, fcntl, json, os, re, subprocess, sys

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
    if subprocess.run(["tmux", "has-session", "-t", w], capture_output=True).returncode == 0:
        return True
    return subprocess.run(["pgrep", "-f", "--", w], capture_output=True).returncode == 0


def read_ledger():
    bin_ = os.environ.get("WM_ASKS_BIN", "wm-asks")
    try:
        p = subprocess.run([bin_, "query", "--status", "open", "--json"], capture_output=True, text=True, timeout=20)
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
        cw, _, lease = str(r.get("claim") or "").partition("@")
        ck = str(r.get("claim_session") or "") or cw
        acc = r.get("acceptance") if isinstance(r.get("acceptance"), dict) else {}
        verdict = str(acc.get("verdict") or "")
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
            out.append(mk("overdue-ack", "prose-waits-on", "overdue since %s with only a prose waits-on / PID / ACK; record a claim or a structured blocker (owner, dependency, next check)%s" % (due, note), True)); continue
        out.append(mk("ready", "overdue", "overdue since %s, no live claim and no structured blocker (owner, dependency, next check)%s" % (due, note), True))
    return out


NEXT = {
    "dead-worker": "re-dispatch or release the claim (wm-asks claim <id> --worker <live worker>)",
    "lease-expired": "re-dispatch or release the claim (wm-asks claim <id> --worker <live worker>)",
    "stale-revision": "re-claim at the current revision (wm-asks claim <id> --worker <live worker>)",
    "verifier-pending": "run the required verifier and record a PASS acceptance before the ending action",
    "ledger-unreadable": "repair the canonical ledger query (wm-asks query --status open --json)",
    "dependency-cleared": "dispatch it to a worker now (wm-asks claim <id> --worker <live worker>)",
}


def reason(new):
    parts = ["%s [%s/%s] %s -> next: %s" % (n["id"], n["disposition"], n["kind"], n["detail"],
             NEXT.get(n["kind"], "claim it with a live worker, record a structured blocker (owner, dependency, next check), or resolve it with a PASS acceptance")) for n in new[:5]]
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


def cmd_new(seat):
    sd = state_dir(); fh = locked(sd)
    rows, why = read_ledger()
    if rows is None:
        obl = [{"id": "LEDGER", "rev": 0, "disposition": "blocked", "kind": "ledger-unreadable", "owner": "", "next_check": "", "due": "",
                "detail": "ledger malformed or unreadable: " + why, "actionable": True, "fp": "LEDGER|0|ledger-unreadable|" + why}]
    else:
        obl = [d for d in evaluate(seat, rows, now_min()) if d["actionable"]]
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
    for line in open(ob):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            lines.append(line); continue
        if e.get("delivered") is False:
            try:
                if subprocess.run([dc], input=line, text=True, capture_output=True, timeout=30).returncode == 0:
                    e["delivered"] = True
            except (OSError, subprocess.TimeoutExpired):
                pass
        lines.append(json.dumps(e, separators=(",", ":")))
    atomic_write(ob, "\n".join(lines) + ("\n" if lines else ""))
    fh.close()


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("cmd", choices=("eval", "new", "replay", "reason")); ap.add_argument("--seat", default=os.environ.get("WM_SEAT", "ctl"))
    a = ap.parse_args()
    if a.cmd == "eval":
        rows, why = read_ledger()
        print(json.dumps({"dispositions": evaluate(a.seat, rows, now_min()) if rows is not None else [], "error": why or None}))
    elif a.cmd == "new":
        cmd_new(a.seat)
    elif a.cmd == "reason":   # stdin: one obligation JSON per line -> the one-line machine-actionable block text
        print(reason([json.loads(l) for l in sys.stdin if l.strip()]))
    else:
        cmd_replay()


if __name__ == "__main__":
    main()
