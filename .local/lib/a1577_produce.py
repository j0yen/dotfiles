#!/usr/bin/python3 -I
"""A1577 producer (v6, private, UNINSTALLED): the CALLER runs this BEFORE launch.
The producer NEVER authors an effect: the planned INV may be minted by the caller, but the a1577-effect/1 receipt (outcome applied, effect_id,
source_row, readback) must already exist in the authoritative effect store for that ask+INV; it is copied byte-exact and re-validated. A missing
or non-applied effect, no readback, or any unresolved prior invocation without a matching a1577-reconcile/1 receipt REFUSES. ->
append ONE whole line `a1577-bind inv=<INV> effect-sha=<sha256 of the effect file> prior=<basename:sha,...|none>` to the canonical ask row
through an injected ledger -> write binding.json in the shape succ_v5.check() reads. Refuses when the row is not open or already carries
an a1577-bind line. The caller then passes WM_SUCC_INV=<INV> and WM_SUCC_BINDING=<binding.json> to ctl-relaunch.
Ledger interface: read(ask) -> row dict | None ; append_line(ask, line, expect_rev) -> None (raises on refusal).
Residual: same-uid forgeability (A1582 BLOCKED)."""
import hashlib, json, os, re, secrets, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try: import succ_v5 as succ
except ImportError:   # install layout: the checker ships as a1577-succ.py beside this file
    import importlib.util
    _sp = importlib.util.spec_from_file_location("succ_v5", os.path.join(os.path.dirname(os.path.abspath(__file__)), "a1577-succ.py")); succ = importlib.util.module_from_spec(_sp); sys.modules["succ_v5"] = succ; _sp.loader.exec_module(succ)

class Refused(Exception): pass

class ShellLedger:
    """Real ledger (not exercised in tests): reads via `wm-decide asks query`, appends via `wm-asks asks update --append`. Append semantics (whole line, newline) are verified at install time."""
    def read(self, ask): return succ.live_ledger(ask)
    def append_line(self, ask, line, expect_rev):
        o = subprocess.run(["wm-asks", "asks", "update", ask, "--by", "ctl", "--expect-rev", str(expect_rev), "--append", line], capture_output=True, text=True, timeout=60)
        if o.returncode != 0: raise Refused("ledger append refused: " + (o.stderr or o.stdout)[-300:])

def mint_inv(now=None):
    t = time.strftime("%Y%m%d-%H%M%S", time.localtime(now if now is not None else time.time()))
    return f"rl-{t}-{os.getpid()}-{secrets.token_hex(4)}"

class DecisionEffects:
    """Authoritative provenance (v6 private): the canonical decision ledger (`wm-decide list --json`). An effect = a recorded row whose what carries
    `a1577-effect ask=<ask> inv=<inv> outcome=applied` and whose evidence is non-empty; the receipt is DERIVED from that row (effect_id = source_row = row id,
    readback = the row's evidence). Prior invocations = rows `a1577-effect ask=<ask> inv=<x>` with x != inv and no row `a1577-reconciled ask=<ask> prior=<x>`.
    Ledger unreadable -> None (UNKNOWN, refuses). Rows are immutable and written by the effect owner; the producer only reads them."""
    def __init__(self, rows=None, since="60d"):
        self._rows = rows; self.since = since
    def _load(self):
        if self._rows is not None: return self._rows
        try:
            o = subprocess.run(["wm-decide", "list", "--json", "--since", self.since], capture_output=True, text=True, timeout=60)
            d = json.loads(o.stdout)
        except Exception: return None
        return d if o.returncode == 0 and isinstance(d, list) else None
    @staticmethod
    def _lines(r): return str(r.get("what")).split("\n")   # split on \n only: \r, \x0b, \u2028 never create a typed line
    @staticmethod
    def _mentions(ask, l):
        """True when a not-exactly-typed effect line could be about this ask: the ask id appears left-bounded (digit-bounded on the right when the id ends in a digit),
        or the line names no well-formed ask=<token> (then it is unattributable and refuses every ask)."""
        right = r"(?![0-9])" if ask[-1:].isdigit() else ""
        body = re.sub(r"^\s*a1577-effect", "", l, flags=re.I)   # the tag itself is not a mention of the ask
        if re.search(r"(?<![A-Za-z0-9])" + re.escape(ask) + right, body, re.I): return True
        return not re.search(r"\bask\s*[=:]\s*[\"'(]*[A-Za-z0-9._-]+", body, re.I)
    @staticmethod
    def _typed(ask, r):
        """(ok, [(inv, outcome)]) for one row. ok False = a line that starts like a typed effect line for this ask but is not exactly one."""
        out, ok = [], True
        for l in DecisionEffects._lines(r):
            m = re.fullmatch(r"a1577-effect ask=" + re.escape(ask) + r" inv=([A-Za-z0-9._-]+) outcome=([A-Za-z0-9._-]+)", l)
            if m: out.append((m.group(1), m.group(2)))
            elif l.strip().lower().startswith("a1577-effect") and DecisionEffects._mentions(ask, l): ok = False   # any not-exactly-typed line that names this ask in any punctuation/spacing, or names no well-formed ask at all = ambiguous
        rid = r.get("id")
        if out and not (isinstance(rid, str) and rid.strip() and rid != "None"): ok = False   # an effect row without a real id cannot be named by a receipt
        return ok, out
    @staticmethod
    def _ts(r):
        from datetime import datetime
        try:
            d = datetime.fromisoformat(str(r.get("ts")))
            return d.timestamp() if d.tzinfo else None
        except ValueError: return None
    @staticmethod
    def _readback_ok(ev):
        e = str(ev or "").strip()
        return len(e) >= 8 and e.lower() not in ("none", "n/a", "na", "null", "unknown", "todo", "tbd")
    def effect(self, ask, inv):
        rows = self._load()
        if rows is None: return None
        hits, other = [], False
        for r in rows:
            if not isinstance(r, dict): continue
            ok, ts = self._typed(ask, r)
            mine = [o for (i, o) in ts if i == inv]
            if not ok: other = True   # a malformed/sloppy typed line about this ask = ambiguous, refuse
            if not mine: continue
            if len(ts) != 1 or len(mine) != 1 or mine[0] != "applied": other = True   # an UNKNOWN/failed/duplicate typed row for this invocation: not applied
            else: hits.append(r)
        if other or len(hits) != 1 or not self._readback_ok(hits[0].get("evidence")): return None
        r = hits[0]
        return json.dumps(dict(schema="a1577-effect/1", ask=ask, invocation=inv, outcome="applied", effect_id=r["id"], source_row=r["id"], readback=str(r["evidence"])), sort_keys=True).encode()
    def _window_ok(self, ask):
        """The read window must cover the ask's whole life (asked <= now - 0): otherwise earlier effect rows could be missing -> UNKNOWN."""
        if self._rows is not None: return True   # injected rows (tests) are the whole ledger by construction
        row = succ.live_ledger(ask)
        try:
            from datetime import datetime
            days = int(self.since.rstrip("d"))
            return (datetime.now() - datetime.fromisoformat(str(row["asked"]))).days < days
        except Exception: return False
    def unresolved(self, ask, inv=None):
        """EVERY recorded effect row for the ask other than `inv` (outcome applied, UNKNOWN, failed, intended, anything) is an unresolved prior
        until a reconciliation row names it. Read failure or a window that does not cover the ask's life = None (UNKNOWN, refuses)."""
        rows = self._load()
        if rows is None or not self._window_ok(ask): return None
        eff, effts, rec = {}, {}, set()   # eff: prior inv -> ids of ALL its typed effect rows (any outcome); effts: inv -> newest ts of those rows
        for r in rows:
            if not isinstance(r, dict): continue
            ok, ts = self._typed(ask, r)
            if not ok: return None   # a malformed typed-looking line about this ask: UNKNOWN, refuses
            if not ts: continue
            t = self._ts(r)
            if t is None: return None   # an effect row with no parseable timestamp cannot be ordered: UNKNOWN
            for (i, o) in ts:
                eff.setdefault(i, set()).add(str(r.get("id"))); effts[i] = max(effts.get(i, t), t)
        if inv is not None and inv in effts and any(t > effts[inv] for i, t in effts.items() if i != inv):
            return None   # D3: the invocation being bound is not the newest effect; reusing an older id would launder the newer unresolved prior
        for r in rows:   # a reconciliation counts only as a DISTINCT, LATER row: typed line + evidence receipt naming the task, the prior, ALL of its effect rows and a resolution
            if not isinstance(r, dict): continue
            ls = [l for l in self._lines(r) if l.startswith("a1577-reconciled ")]
            if len(ls) != 1: continue
            m = re.fullmatch(r"a1577-reconciled ask=" + re.escape(ask) + r" prior=([A-Za-z0-9._-]+)", ls[0])
            if not m: continue
            x = m.group(1)
            if x not in eff or str(r.get("id")) in eff[x] or self._typed(ask, r)[1]: continue   # N1: a row that is itself an effect row cannot reconcile
            t = self._ts(r)
            if t is None or t <= effts[x]: continue   # N1: the reconciliation must be strictly later than every effect row it clears
            try: d = json.loads(str(r.get("evidence") or ""))
            except ValueError: continue
            if (isinstance(d, dict) and d.get("schema") == "a1577-reconcile/1" and d.get("ask") == ask and d.get("prior_invocation") == x
                    and d.get("status") == "reconciled" and isinstance(d.get("effects"), list) and d["effects"]
                    and set(map(str, d["effects"])) == eff[x] and self._readback_ok(d.get("resolution")) and self._readback_ok(d.get("readback"))):   # N2: states what resolved it
                rec.add(x)
        return sorted(set(eff) - rec - {inv})

def _write(path, data):
    with open(path, "wb") as f: f.write(data)
    return hashlib.sha256(data).hexdigest()

def produce(ask, outdir, ledger, effects, prior_receipts=(), inv=None, now=None, consumed_path=None, produced_path=None, void_path=None):
    """effects: .effect(ask, inv) -> bytes|None ; .unresolved(ask, inv) -> list of prior invocation ids | None (unknown = refuse).
    prior_receipts: iterable of dicts (a1577-reconcile/1)."""
    row = ledger.read(ask)
    if not isinstance(row, dict) or row.get("ask_id") != ask: raise Refused("canonical ledger row unreadable or not the ask")
    if str(row.get("status")) != "open": raise Refused("canonical ask is not open")
    voided = set(open(void_path).read().split()) if void_path and os.path.exists(void_path) else set()
    if consumed_path and os.path.exists(consumed_path): voided -= {l.split()[0] for l in open(consumed_path).read().splitlines() if l.strip()}
    launched_path = os.path.join(os.path.dirname(os.path.abspath(void_path)), 'succ-launched') if void_path else None
    if launched_path and os.path.exists(launched_path): voided -= set(open(launched_path).read().split())   # H1: an id that reached the kill step is never voided   # S1: an id a live child consumed is never voided
    binds = [succ.BIND_LINE.match(l) for l in str(row.get("what")).splitlines()]; binds = [m for m in binds if m]
    if binds and binds[-1].group(1) not in voided: raise Refused("canonical row already carries a live a1577-bind line (bind-once; only a bind whose launch was voided before any kill is superseded)")
    inv = inv or mint_inv(now)
    if not re.fullmatch(r"[A-Za-z0-9._-]+", inv): raise Refused("invocation id has unsafe characters")
    if consumed_path and os.path.exists(consumed_path) and any(l.split()[:1] == [inv] for l in open(consumed_path).read().splitlines()): raise Refused("invocation id already consumed by a successor check (reuse refused)")
    if produced_path and os.path.exists(produced_path) and any(l.split()[:1] == [inv] for l in open(produced_path).read().splitlines()): raise Refused("invocation id already produced a binding (reuse refused, even if its relaunch was never checked)")
    eb = effects.effect(ask, inv)
    if not eb: raise Refused("no authoritative effect receipt for this ask and invocation (producer does not author effects)")
    try: e = json.loads(eb)
    except ValueError: raise Refused("effect receipt is not JSON")
    if not (isinstance(e, dict) and e.get("schema") == "a1577-effect/1" and e.get("ask") == ask and e.get("invocation") == inv and e.get("outcome") == "applied" and e.get("effect_id") and e.get("source_row") and e.get("readback")):
        raise Refused("effect receipt is not an applied receipt with effect_id, source_row and readback for this ask and invocation")
    unres = effects.unresolved(ask, inv)
    if unres is None: raise Refused("unresolved prior invocations unknown (UNKNOWN is not none)")
    recs = list(prior_receipts)
    for rec in recs:
        if not (isinstance(rec, dict) and rec.get("schema") == "a1577-reconcile/1" and rec.get("ask") == ask and rec.get("status") == "reconciled" and rec.get("prior_invocation") and rec.get("effects")):
            raise Refused("prior receipt is not a reconciled a1577-reconcile/1 document for this ask")
    missing = sorted(set(map(str, unres)) - {str(r.get("prior_invocation")) for r in recs})
    if missing: raise Refused("unresolved prior invocations without a reconciliation receipt: " + ",".join(missing))
    os.makedirs(outdir, exist_ok=True)
    effect_file = os.path.join(outdir, f"effect-{inv}.json")
    esha = _write(effect_file, eb)
    prior = []
    for i, rec in enumerate(recs):
        pf = os.path.join(outdir, f"prior-{inv}-{i}.json")
        prior.append(dict(file=pf, sha=_write(pf, json.dumps(rec, sort_keys=True).encode())))
    pr = ",".join(f"{os.path.basename(x['file'])}:{x['sha']}" for x in prior) or "none"
    line = f"a1577-bind inv={inv} effect-sha={esha} prior={pr}"
    ledger.append_line(ask, line, row.get("rev"))
    row2 = ledger.read(ask)   # the bound rev is the revision AFTER the append
    if not isinstance(row2, dict) or row2.get("ask_id") != ask: raise Refused("canonical row unreadable after append")
    b2 = [m for m in (succ.BIND_LINE.match(l) for l in str(row2.get("what")).splitlines()) if m]
    if len(b2) != len(binds) + 1 or b2[-1].group(1) != inv or any(m.group(1) not in voided for m in b2[:-1]): raise Refused("canonical row bind lines are not: voided priors + exactly this one last")
    try: rev = int(row2.get("rev"))
    except (TypeError, ValueError): raise Refused("canonical rev is not an integer")
    bp = os.path.join(outdir, f"binding-{inv}.json")
    _write(bp, json.dumps(dict(ask=ask, rev=rev, invocation=inv, task_digest=succ.task_digest(row2), effect_file=effect_file, effect_sha=esha, prior=prior), sort_keys=True).encode())
    if produced_path:
        os.makedirs(os.path.dirname(produced_path) or ".", exist_ok=True)
        with open(produced_path, "a") as f: f.write(inv + "\n")
    return dict(inv=inv, binding=bp, effect_file=effect_file, line=line)

def main(argv):
    import argparse
    a = argparse.ArgumentParser(); a.add_argument("--ask", required=True); a.add_argument("--outdir", required=True)
    a.add_argument("--inv", required=True, help="planned invocation id"); a.add_argument("--prior", action="append", default=[], help="path of a reconcile receipt JSON")
    n = a.parse_args(argv[1:])
    try:
        pr = [json.load(open(p)) for p in n.prior]
        out = produce(n.ask, n.outdir, ShellLedger(), DecisionEffects(), pr, n.inv, consumed_path=os.path.expanduser('~/.local/state/aide/succ-consumed'), produced_path=os.path.expanduser('~/.local/state/aide/succ-produced'), void_path=os.path.expanduser('~/.local/state/aide/succ-void'))
    except (Refused, OSError, ValueError) as e:
        print("REFUSED:", e, file=sys.stderr); return 2
    print(f"WM_SUCC_INV={out['inv']}"); print(f"WM_SUCC_BINDING={out['binding']}"); return 0
if __name__ == "__main__": sys.exit(main(sys.argv))
