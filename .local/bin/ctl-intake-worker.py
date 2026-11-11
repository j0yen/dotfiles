#!/usr/bin/env python3
"""ctl-intake-worker.py once --registry FILE   (A1303 W8/W9: scheduled binding of an approved recipe to the installed swarm-decide intake_worker.run_task)
For each ask in the trusted REGISTRY (json {ask_id: {recipe, rev, approved_by, target, ...}}) whose canonical state is `ready` (or this worker's own claim/blocked-with-effect), run_task once.
It never accepts (accept_task stays an independent call), never reads authorization from task text, and treats every refusal as ZERO effect. Identity fields are truthful: no model/account (deterministic).
Authentication limit (named, not solved here): the registry file is trusted by owner+mode only (mine, not group/world writable); the ledger does not authenticate who wrote `approved_by`.
Env: WM_DECIDE_STATE (ledger dir; a private one for canaries), SWARM_DECIDE_LIVE (default ~/.local/share/swarm-decide/live/current).
Exit: 0 ok/WAIT, 64 usage, 65 bad registry, 66 ledger unavailable, 70 refused/conflict, 75 NeedsReadback (UNKNOWN kept)."""
import json
import os
import socket
import stat
import sys

live = os.environ.get("SWARM_DECIDE_LIVE") or os.path.expanduser("~/.local/share/swarm-decide/live/current")
sys.path.insert(0, live)
from wm_decide import asks, intake, intake_worker, store  # noqa: E402


def load_registry(path):
    st = os.stat(path)
    if st.st_uid != os.getuid() or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise ValueError("registry %s must be owned by this user and not group/world writable" % path)
    with open(path) as f:
        reg = json.load(f)
    if not isinstance(reg, dict):
        raise ValueError("registry must be a json object keyed by ask id")
    return reg


def main(argv):
    if len(argv) != 3 or argv[0] != "once" or argv[1] != "--registry":
        print(__doc__.splitlines()[0], file=sys.stderr)
        return 64
    try:
        reg = load_registry(argv[2])
    except (OSError, ValueError) as e:
        print("bad registry: %s" % e, file=sys.stderr)
        return 65
    try:
        db = store.connect()
        intake.ensure(db)
    except Exception as e:
        print("ledger unavailable: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 66
    rc = 0
    session = os.environ.get("INVOCATION_ID") or "manual-%d" % os.getpid()
    for ask in sorted(reg):
        row = intake._row(db, ask)
        if row is None or row["state"] not in ("ready", "claimed", "blocked"):
            print(json.dumps({"ask_id": ask, "status": "SKIP", "state": row["state"] if row else None}))
            continue
        try:
            r = intake_worker.run_task(db, ask, expect_rev=row["rev"], worker="ctl-intake-worker", host=socket.gethostname(), pid=os.getpid(),
                                       session=session, model="none-deterministic", account="none", effort="none", registry=reg)
        except intake.NeedsReadback as e:
            r, rc = {"ask_id": ask, "status": "UNKNOWN", "msg": str(e)}, max(rc, 75)
        except intake.Unavailable as e:
            r, rc = {"ask_id": ask, "status": "UNAVAILABLE", "msg": str(e)}, max(rc, 66)
        except (store.Refused, asks.Conflict) as e:
            r, rc = {"ask_id": ask, "status": "REFUSED", "msg": str(e)}, max(rc, 70)
        print(json.dumps(r))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
