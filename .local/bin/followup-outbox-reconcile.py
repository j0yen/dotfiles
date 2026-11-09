#!/usr/bin/env python3
"""followup-outbox-reconcile.py: reviewed exact-identity supersession of stale follow-up outbox entries.

  followup-outbox-reconcile.py --classified classified.tsv [--snapshot outbox.snap.jsonl] [--apply]

classified.tsv columns: bucket, id, rev, kind, seat, fp, evidence (tab separated; bucket STALE-SUPERSEDED | CURRENT-UNDELIVERED | UNKNOWN).
Dry-run by default: prints what --apply would write. --apply appends one JSON line per matched entry to the sidecar next to the outbox
(outbox.jsonl -> outbox.superseded.jsonl) with the evidence; outbox.jsonl is never rewritten or deleted. Only an outbox entry whose (id, rev, fp)
EXACTLY equals a STALE-SUPERSEDED row, still undelivered, is marked; CURRENT-UNDELIVERED and UNKNOWN rows are never touched, a changed rev or fp is a
different identity, and with --snapshot an entry is marked only if its exact line (ts included) is in the snapshot, so entries newer than the review are left alone.
followup-eval.py replay skips sidecar-superseded identities and still delivers everything else.
Env: FOLLOWUP_STATE_DIR / FOLLOWUP_OUTBOX (as followup-eval.py). A CURRENT/UNKNOWN row with the same (id, rev, fp) vetoes a STALE row. --apply requires --snapshot. Exit 0 ok, 2 bad input.
"""
import argparse, fcntl, json, os, sys, time

STALE = "STALE-SUPERSEDED"


def paths():
    sd = os.environ.get("FOLLOWUP_STATE_DIR") or os.path.expanduser("~/.local/state/followup-loop")
    ob = os.environ.get("FOLLOWUP_OUTBOX") or os.path.join(sd, "outbox.jsonl")
    side = (ob[:-6] if ob.endswith(".jsonl") else ob) + ".superseded.jsonl"
    return sd, ob, side


def ident(e):
    return (str(e.get("id")), str(e.get("rev", 0)), str(e.get("fp")))


def lineid(e):  # the identity plus the entry's own ts: a later re-queue of the same identity is a different line
    return ident(e) + (str(e.get("ts")),)


def jlines(path):
    out = []
    if os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if line:
                try:
                    out.append((line, json.loads(line)))
                except ValueError:
                    pass
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--classified", required=True); ap.add_argument("--snapshot"); ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    if a.apply and not a.snapshot:
        print("--apply requires --snapshot (the reviewed outbox copy); dry-run may omit it", file=sys.stderr); sys.exit(2)
    sd, ob, side = paths()
    stale = {}; keep = set()
    try:
        for line in open(a.classified, encoding="utf-8"):
            f = line.rstrip("\n").split("\t")
            if len(f) < 7:
                continue
            if f[0] == STALE:
                stale[(f[1], f[2], f[5])] = f[6]
            else:
                keep.add((f[1], f[2], f[5]))
    except OSError as ex:
        print("cannot read classified file: %s" % ex, file=sys.stderr); sys.exit(2)
    for k in keep:  # a CURRENT/UNKNOWN row with the same identity vetoes a STALE row: fail toward delivery
        stale.pop(k, None)
    snap = None
    if a.snapshot:
        try:
            snap = {l for l, _ in jlines(a.snapshot)}
        except OSError as ex:
            print("cannot read snapshot: %s" % ex, file=sys.stderr); sys.exit(2)
    if not os.path.exists(ob):
        print("no outbox at %s; nothing to do" % ob); return
    os.makedirs(sd, exist_ok=True)
    lock = open(os.path.join(sd, "lock"), "w"); fcntl.flock(lock, fcntl.LOCK_EX)
    done = {ident(e) + (str(e.get("entry_ts")),) for _, e in jlines(side)}
    todo = []; seen = set()
    for line, e in jlines(ob):
        if e.get("delivered") is not False or "fp" not in e:
            continue
        k = ident(e)
        if k in stale and lineid(e) not in done and lineid(e) not in seen and (snap is None or line in snap):
            seen.add(lineid(e)); todo.append((k, e))
    for k, e in todo:
        print("%s %s rev=%s fp=%s" % ("SUPERSEDE" if a.apply else "WOULD-SUPERSEDE", k[0], k[1], k[2]))
    if a.apply and todo:
        gap = False
        if os.path.exists(side) and os.path.getsize(side) > 0:  # a crash-truncated sidecar must not glue the next line onto its tail
            with open(side, "rb") as bh:
                bh.seek(-1, 2); gap = bh.read(1) != b"\n"
        with open(side, "a", encoding="utf-8") as fh:
            if gap:
                fh.write("\n")
            for k, e in todo:
                fh.write(json.dumps({"id": k[0], "rev": e.get("rev", 0), "fp": k[2], "entry_ts": e.get("ts"), "bucket": STALE, "evidence": stale[k], "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, separators=(",", ":")) + "\n")
            fh.flush(); os.fsync(fh.fileno())
    print("%s %d entries (sidecar %s)" % ("superseded" if a.apply else "would supersede", len(todo), side))


if __name__ == "__main__":
    main()
