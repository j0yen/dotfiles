#!/usr/bin/env bash
# hold-gate.sh <caller> | --explain  (hermes-handover item 2.4): the ONE read of the quota HOLD file for every spawner.
#   HOLD file = ${WM_HOLD_JSON:-$HOME/wintermute-operations/quota-conservation/HOLD.json}
#   absent                          -> exit 0, silent
#   present, <caller> is preserved   -> exit 0 (a `preserved` entry equal to <caller> or to `caller:<caller>`, case-insensitive, trimmed)
#   present otherwise                -> stderr `hold-gate: HOLD blocks <caller> (<reason, 120 chars>) file=<path>`, exit 1
#   present but unreadable/unparseable (or `preserved` not a list) -> HOLD (exit 1, reason `unparseable`): a hold file never fails open
#   --explain                        -> prints the file path and the preserved list, exit 0 (read-only)
# No env override skips the gate; WM_HOLD_JSON only moves the file (tests point it at a fixture).
set -uo pipefail
HOLD="${WM_HOLD_JSON:-$HOME/wintermute-operations/quota-conservation/HOLD.json}"
arg="${1:-}"
[ -n "$arg" ] || { echo "usage: hold-gate.sh <caller> | --explain" >&2; exit 64; }
if [ "$arg" = --explain ]; then
  echo "hold file: $HOLD"
  if [ -e "$HOLD" ]; then
    python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    p = d["preserved"]
    assert isinstance(p, list)
    print("preserved: " + json.dumps(p))
except Exception:
    print("preserved: unparseable (the gate treats this file as a HOLD that preserves nothing)")
' "$HOLD"
  else
    echo "state: absent (no hold)"
  fi
  exit 0
fi
[ -e "$HOLD" ] || exit 0
python3 -I -c '
import json, sys
path, caller = sys.argv[1], sys.argv[2]
def block(reason):
    print("hold-gate: HOLD blocks %s (%s) file=%s" % (caller, reason[:120].replace("\n", " "), path), file=sys.stderr)
    sys.exit(1)
try:
    d = json.load(open(path))
    pres = d["preserved"]
    if not isinstance(pres, list):
        raise ValueError("preserved is not a list")
    reason = d.get("reason", "") if isinstance(d, dict) else ""
    reason = reason if isinstance(reason, str) and reason else "no reason given"
except Exception:
    block("unparseable")
want = {caller.strip().lower(), ("caller:" + caller.strip()).lower()}
for e in pres:
    if isinstance(e, str) and e.strip().lower() in want:
        sys.exit(0)
block(reason)
' "$HOLD" "$arg"
