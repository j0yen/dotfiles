#!/usr/bin/env bash
# seat-owed.sh <seat>: print THAT seat's owed/overdue follow-up ids (A49 D1), <= 12 lines, exit 0 always.
#   OWED <seat>: owed N, overdue M, escalated E, oldest <id>   from `wm-decide followups --json --agent <name>` (WM_DECIDE_BIN overrides the binary)
#   OVERDUE <seat>: <id> <id> ...                    up to 20 full ids of owner <name> from `ids`, state escalated first, each group in given (oldest first) order
#   ASKS <seat>: overdue <ids>                       open rows of OPEN_ASKS (above "# CLOSED") owned by <seat> with due < now
# <name> = <seat>, except ctl -> controller (WM_SEAT ctl, ledger owner controller).
# wm-decide missing / timeout / non-zero / bad JSON / no `owed` -> `OWED <seat>: unknown (<reason>)`, never a number; the ASKS line still prints.
# JSON keys read: top-level owed, overdue, escalated, oldest (string or {id}), ids[{id,owner,state}]. If --agent did not filter (ids of other
#   owners present) ids are filtered by owner == <name>, owed = by_agent[<name>] else len(filtered), escalated and overdue = count of filtered ids in state escalated.
# PREMISE: a printer for seat prompts; it must never block a seat start, so every failure degrades to a line.
set -u
seat="${1:-}"
[ -n "$seat" ] || { echo "OWED unknown: no seat given"; exit 0; }
bin="${WM_DECIDE_BIN:-$HOME/.local/bin/wm-decide}"
name="$seat"; [ "$seat" = ctl ] && name=controller
asks="${OPEN_ASKS:-$HOME/.cache/aide/open-asks.tsv}"

if [ ! -x "$bin" ]; then
  echo "OWED $seat: unknown (wm-decide missing at $bin)"
else
  js="$(timeout 20 "$bin" followups --json --agent "$name" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="wm-decide exit $rc"; [ "$rc" = 124 ] && reason="wm-decide timed out"
    echo "OWED $seat: unknown ($reason)"
  else
    printf '%s' "$js" | python3 -I -c '
import json, sys
seat, name = sys.argv[1], sys.argv[2]
def unk(r):
    print("OWED %s: unknown (%s)" % (seat, r)); sys.exit(0)
try:
    d = json.load(sys.stdin)
except Exception:
    unk("bad JSON")
if not isinstance(d, dict):
    unk("unexpected JSON shape")
def num(v):
    return None if isinstance(v, bool) or not isinstance(v, (int, float)) else int(v)
rows = [r for r in (d.get("ids") or []) if isinstance(r, dict) and "id" in r] if isinstance(d.get("ids"), list) else []
mine = [r for r in rows if r.get("owner") == name]
unfiltered = len(mine) != len(rows)
owed, over, esc = num(d.get("owed")), num(d.get("overdue")), num(d.get("escalated"))
if unfiltered:
    ba = d.get("by_agent")
    owed = num(ba.get(name)) if isinstance(ba, dict) and name in ba else len(mine)
    esc = sum(1 for r in mine if r.get("state") == "escalated")
    over = esc
elif owed is None and "ids" in d:
    owed = len(mine)
if owed is None:
    unk("no owed in wm-decide JSON")
over = 0 if over is None else over
esc = 0 if esc is None else esc
ordered = [str(r["id"]) for r in mine if r.get("state") == "escalated"] + [str(r["id"]) for r in mine if r.get("state") != "escalated"]
oldest = d.get("oldest")
if isinstance(oldest, dict): oldest = oldest.get("id")
if unfiltered or not oldest: oldest = (str(mine[0]["id"]) if mine else "none")
print("OWED %s: owed %d, overdue %d, escalated %d, oldest %s" % (seat, owed, over, esc, oldest))
if ordered:
    print("OVERDUE %s: %s" % (seat, " ".join(ordered[:20])))
' "$seat" "$name"
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
