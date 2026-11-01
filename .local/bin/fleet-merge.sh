#!/usr/bin/env bash
# fleet-merge.sh [--dry-run] [--repo owner/name]... -- timed merge executor (A13 MVP, approvals #190).
# For every open PR whose newest controller/verifier CONFIRM verdict row names the PR's live head, runs rb-merge.sh <verdict-id> <pr> <repo>
# (rb-merge.sh runs the merge gate itself; a refusal is recorded, never fatal). Oldest PR first per repo, at most FLEET_MERGE_MAX (default 5) merges per tick.
# A newer CORRECT / DISAGREE / MERGE-BLOCK / ADV-BLOCK row on the same PR (and head, when it names one) blocks the PR. No row = skip no-confirm.
# One JSON receipt line per tick in $FLEET_MERGE_STATE/ticks.jsonl; `MERGED <repo>#<pr>` on stdout per merge (journalctl | grep -c MERGED).
# launched stays 0 in this MVP (a later coder adds the verifier-unit launch). Env: FLEET_MERGE_REPOS FLEET_MERGE_GH FLEET_MERGE_RB_MERGE FLEET_MERGE_STATE FLEET_MERGE_MAX WM_DECIDE_BIN.
# Gate-producer table (one line per gate in wm_decide/mergegate.py; tests/gate-producer-contract.test.sh keeps it complete):
# PRODUCER G0 inline grade by the controller for product rows / logged tooling rows per #139; Fable regrade or FABLE-GRADE row (swarm-decide-regrade.timer)
# PRODUCER G1 verifier row carries COMMIT=<hex> (aide-verifier.sh / verifier unit)
# PRODUCER G2 live PR state read by merge-gate itself (verdict ts after gated row ts)
# PRODUCER G3 r7 leg under wm-verify-run attached to the verifier row (ATTACH blocks)
# PRODUCER G4 verifier row prose counts checked against the attached log (verifier unit)
# PRODUCER G5 verifier row mutation claims survivor= ids (verifier unit)
# PRODUCER G6 agent=<id> on the GATED row and on the verdict row (coder row writer / verifier unit)
# PRODUCER G7 verifier recorded from a separate headless session (aide-verifier.sh unit)
# PRODUCER G8 extra_required row kinds from mergegate.toml (ADV rows) MISSING A13-g8-adv-row-producer (rb)
# PRODUCER G9 wm-verify-run pytest -rs log from the r7 leg (load-guard skips refused)
# PRODUCER G10 Fable regrade verdict on the verifier row or a FABLE-GRADE row (swarm-decide-regrade.timer)
# PRODUCER G12 hand-PR reference (gate-fix daemon run or revert PR) in the PR body MISSING A35-hand-pr-refs-producer (rb)
set -euo pipefail

GH="${FLEET_MERGE_GH:-gh}"
WM_DECIDE="${WM_DECIDE_BIN:-wm-decide}"
RB_MERGE="${FLEET_MERGE_RB_MERGE:-$HOME/.local/bin/rb-merge.sh}"
STATE="${FLEET_MERGE_STATE:-$HOME/.local/state/fleet-merge}"
MAX="${FLEET_MERGE_MAX:-5}"
dry=0
repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --repo) [ $# -ge 2 ] || { echo "fleet-merge.sh: --repo needs owner/name" >&2; exit 64; }; repos+=("$2"); shift 2 ;;
    *) echo "usage: fleet-merge.sh [--dry-run] [--repo owner/name]..." >&2; exit 64 ;;
  esac
done
if [ ${#repos[@]} -eq 0 ]; then
  read -r -a repos <<< "${FLEET_MERGE_REPOS:-j0yen/dotfiles j0yen/swarm-decide j0yen/wm-build j0yen/mcphost j0yen/synthorg}"
fi
case "$MAX" in ''|*[!0-9]*) echo "fleet-merge.sh: FLEET_MERGE_MAX must be a number" >&2; exit 64 ;; esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gated=0 merged=0 skipped=0 errors=0
: > "$work/refused"

"$WM_DECIDE" list --json --since 7d > "$work/rows.json" || { echo "fleet-merge: wm-decide list failed" >&2; errors=$((errors + 1)); echo '[]' > "$work/rows.json"; }

# plan.py <rows.json> <prs.json> <repo>: one line per open PR, oldest (lowest number) first: "<pr>\t<verdict-id>" or "<pr>\tskip"
cat > "$work/plan.py" <<'PYEOF'
import json, re, sys
rows = json.load(open(sys.argv[1]))
if isinstance(rows, dict):
    rows = rows.get("rows") or rows.get("decisions") or []
rows = [r for r in rows if isinstance(r, dict) and r.get("id")]
prs = json.load(open(sys.argv[2]))
repo = sys.argv[3]
name = repo.split("/")[-1]
PRE = re.compile(r"^\s*[`*_]*((?:[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+)#(\d+)\s+head\s+([0-9a-fA-F]{7,40})\s+(.*)$", re.S)
CONFIRM = ("CONFIRM", "MERGE-OK")
BLOCK = ("CORRECT", "DISAGREE", "MERGE-BLOCK", "ADV-BLOCK")
def word(text):
    t = (text or "").split(None, 1)
    return t[0].strip("*_`:;,.()[]-").upper() if t else ""
def claim(r):
    what = r.get("what") or ""
    m = PRE.match(what)
    if m:
        rr = m.group(1)
        if rr.split("/")[-1] != name:
            return None
        return int(m.group(2)), m.group(3).lower(), word(m.group(4))
    m = re.search(r"\b" + re.escape(name) + r"#(\d+)\b", what)
    c = re.search(r"COMMIT=([0-9a-fA-F]{7,40})", what + " " + (r.get("evidence") or ""))
    if m:
        return int(m.group(1)), (c.group(1).lower() if c else ""), word(what)
    return None
def by_ctl(r):
    s = ((r.get("via") or "") + " " + (r.get("agent") or "")).lower()
    return any(k in s for k in ("verifier", "controller", "ctl"))
cl = []
for r in rows:
    if r.get("kind") != "verdict" or not by_ctl(r):
        continue
    c = claim(r)
    if c:
        cl.append((r.get("ts") or "", r["id"], c))
cl.sort()
for p in sorted(prs, key=lambda p: int(p["number"])):
    n, head = int(p["number"]), (p.get("headRefOid") or "").lower()
    sel, blocked, nohead = None, False, False
    for ts, rid, (pn, h, w) in cl:
        if pn != n:
            continue
        if not h:
            if w in CONFIRM:
                nohead = True
            elif w in BLOCK:
                blocked = True
            continue
        if not head or (not head.startswith(h) and not h.startswith(head)):
            continue
        if w in CONFIRM:
            sel, blocked = rid, False
        elif w in BLOCK:
            blocked = True
    if sel and not blocked:
        print("%d\t%s" % (n, sel))
    elif nohead and not sel:
        print("%d\tskip-nohead" % n)
    else:
        print("%d\tskip" % n)
PYEOF

for repo in "${repos[@]}"; do
  if ! "$GH" pr list --repo "$repo" --state open --limit 500 --json number,headRefOid,title > "$work/prs.json"; then
    echo "fleet-merge: gh pr list $repo failed" >&2; errors=$((errors + 1)); continue
  fi
  python3 -I "$work/plan.py" "$work/rows.json" "$work/prs.json" "$repo" > "$work/plan.txt" || { echo "fleet-merge: plan failed for $repo" >&2; errors=$((errors + 1)); continue; }
  while IFS=$'\t' read -r pr vid; do
    [ -n "$pr" ] || continue
    if [ "$vid" = skip-nohead ]; then
      echo "skip: confirm-without-head $repo#$pr"; skipped=$((skipped + 1)); continue
    fi
    if [ "$vid" = skip ]; then
      echo "skip no-confirm $repo#$pr"; skipped=$((skipped + 1)); continue
    fi
    gated=$((gated + 1))
    if [ "$merged" -ge "$MAX" ]; then
      echo "skip max-per-tick $repo#$pr"; skipped=$((skipped + 1)); continue
    fi
    if [ "$dry" = 1 ]; then
      echo "DRY-RUN $RB_MERGE $vid $pr $repo"; continue
    fi
    rc=0
    "$RB_MERGE" "$vid" "$pr" "$repo" > "$work/out.txt" 2> "$work/err.txt" || rc=$?
    cat "$work/out.txt"
    if [ "$rc" = 0 ]; then
      echo "MERGED $repo#$pr"; merged=$((merged + 1))
    elif [ "$rc" = 2 ]; then
      first="$(head -n 1 "$work/err.txt")"
      g="$(printf '%s\n' "$first" | grep -oE '^G[0-9]+' || echo G?)"
      echo "$g" >> "$work/refused"
      echo "REFUSED $repo#$pr rc=2 $first"
    else
      echo "ERROR $repo#$pr rc=$rc $(head -n 1 "$work/err.txt")"; errors=$((errors + 1))
    fi
  done < "$work/plan.txt"
done

[ "$dry" = 1 ] && exit 0
mkdir -p "$STATE"
python3 -I - "$work/refused" "$gated" "$merged" "$skipped" "$errors" >> "$STATE/ticks.jsonl" <<'PYEOF'
import json, sys, time, collections
refused = collections.Counter(l.strip() for l in open(sys.argv[1]) if l.strip())
g, m, s, e = (int(x) for x in sys.argv[2:6])
print(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "launched": 0, "gated": g, "merged": m,
                  "refused_by_gate": dict(refused), "skipped": s, "errors": e}, sort_keys=True))
PYEOF
