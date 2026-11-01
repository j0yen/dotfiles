#!/usr/bin/env bash
# seat-owed.sh <seat>: print THAT seat's owed/overdue follow-up ids (A49 D1), <= 12 lines, exit 0 always.
#   OWED <seat>: owed N, overdue M, oldest <id>      from `wm-decide followups --json` (WM_DECIDE_BIN overrides the binary)
#   OVERDUE <seat>: <id> <id> ...                    up to 20 full ids, oldest first, when the JSON lists them
#   ASKS <seat>: overdue <ids>                       open rows of OPEN_ASKS (above "# CLOSED") owned by <seat> with due < now
# wm-decide missing / timeout / bad JSON -> `OWED <seat>: unknown (<reason>)`, never a number; the ASKS line still prints.
# JSON keys read (defensively): per-seat entry = per_agent[seat] (dict keyed by seat, or list of {agent|seat|name}), else the top level;
#   counts owed/overdue (number, or list whose length is the count); ids from overdue_ids / overdue (list) / owed_ids / ids / rows[].id;
#   oldest from oldest / oldest_id, else the first overdue id.
# PREMISE: a printer for seat prompts; it must never block a seat start, so every failure degrades to a line.
set -u
seat="${1:-}"
[ -n "$seat" ] || { echo "OWED unknown: no seat given"; exit 0; }
bin="${WM_DECIDE_BIN:-$HOME/.local/bin/wm-decide}"
asks="${OPEN_ASKS:-$HOME/.cache/aide/open-asks.tsv}"

if [ ! -x "$bin" ]; then
  echo "OWED $seat: unknown (wm-decide missing at $bin)"
else
  js="$(timeout 20 "$bin" followups --json 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="wm-decide exit $rc"; [ "$rc" = 124 ] && reason="wm-decide timed out"
    echo "OWED $seat: unknown ($reason)"
  else
    printf '%s' "$js" | python3 -I -c '
import json, sys
seat = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("OWED %s: unknown (bad JSON)" % seat); sys.exit(0)
if not isinstance(d, dict):
    print("OWED %s: unknown (unexpected JSON shape)" % seat); sys.exit(0)
e = None
pa = d.get("per_agent")
if isinstance(pa, dict):
    e = pa.get(seat)
elif isinstance(pa, list):
    for x in pa:
        if isinstance(x, dict) and seat in (x.get("agent"), x.get("seat"), x.get("name")):
            e = x; break
if e is None and pa is None:
    e = d
if not isinstance(e, dict):
    e = {}
def cnt(v):
    if isinstance(v, list): return len(v)
    if isinstance(v, bool) or not isinstance(v, (int, float)): return None
    return int(v)
def ids(x):
    for k in ("overdue_ids", "overdue", "owed_ids", "ids"):
        v = x.get(k)
        if isinstance(v, list) and v:
            return [str(i.get("id", i)) if isinstance(i, dict) else str(i) for i in v]
    rows = x.get("rows")
    if isinstance(rows, list):
        return [str(r["id"]) for r in rows if isinstance(r, dict) and "id" in r]
    return []
owed, over = cnt(e.get("owed")), cnt(e.get("overdue"))
if owed is None and over is None and not e:
    owed, over = 0, 0
owed = 0 if owed is None else owed
over = 0 if over is None else over
oid = ids(e)
oldest = e.get("oldest") or e.get("oldest_id") or (oid[0] if oid else "none")
if isinstance(oldest, dict): oldest = oldest.get("id", "none")
print("OWED %s: owed %d, overdue %d, oldest %s" % (seat, owed, over, oldest))
if oid:
    print("OVERDUE %s: %s" % (seat, " ".join(oid[:20])))
' "$seat"
  fi
fi

if [ -r "$asks" ]; then
  now="$(date +%s)"
  od="$(awk -F'\t' -v s="$seat" -v now="$now" '
    /^# CLOSED/ {exit}
    /^#/ || NF < 4 {next}
    $2 ~ /^(MET|DONE|CANCELLED|MOOT)/ {next}
    $3 != s {next}
    { t = 0; cmd = "date -d \"" $4 "\" +%s 2>/dev/null"; cmd | getline t; close(cmd); t += 0
      if (t > 0 && t < now) printf "%s ", $1 }' "$asks")"
  od="${od% }"
  [ -z "$od" ] || echo "ASKS $seat: overdue $od"
fi
exit 0
