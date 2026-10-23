#!/usr/bin/env bash
# rb-spawn-hold.sh - CSH (rb 10-23 2:xx AM, ctl: "coder-starvation mechanism instead of my prose ask").
# Holds rb coder spawns while a daemon redrive on redbaron is memory-refused, so product runs (wm-build runs 1039/1042)
# get the hand slots that rb's own coder/verifier units would otherwise take.
#
# usage: rb-spawn-hold.sh [--journal-file F] [--state-file F] [--now ISO] [--probe-only] [--no-flag] [--exempt NAME]
#   --journal-file F  read `wm-build journal` JSON-lines from F instead of ssh (tests); an unreadable F = a read failure
#   --state-file F    default ~/.cache/rb-seat/spawn-hold.json (atomic write: tmp + mv)
#   --now ISO         clock override (tests), e.g. 2026-10-23T09:00:00Z
#   --probe-only      refresh the file, always exit 0 (the systemd timer)
#   --no-flag         skip the HAND-YIELD write/remove (AC7); rb-run-coder.sh and read-only live probes use it
#   --exempt NAME     record `exempt` = NAME in the state file (rb-run-coder.sh --no-cargo)
# env: RB_SPAWN_HOLD_HOST (default redbaron), RB_SPAWN_HOLD_SSH (ssh command; default `ssh -o BatchMode=yes -o ConnectTimeout=8`),
#      CARGO_SLOT_HAND_DIR (default /mnt/data/hand on the host; the HAND-YIELD flag lives there)
# stdout (one line): `HOLD run=<id> refusal=<r> age_s=<n> hand_slots=<k> source=<s>` exit 76, or `OK <why> source=<s>` exit 0.
#
# HOLD iff EITHER
#   lagging: a `release-mem` decision=refuse row < 30 min old whose run_id has no later release-mem grant / driver-adopted /
#            land-cargo-granted row (running) and no later `update runs` row with an outcome (closed). A refused run later
#            `release-mem-dropped reason=run-ended` stays HOLD until running/closed or the 30 min ceiling.
#   leading: a `release-mem-queued` run (< 30 min old) with no later grant/drop while any via=hand cargo job is held.
# Journal window: the last 60 min (the spec says 30; hand slots taken before the 30 min mark must still count as held).
# Read failure: previous file HOLD and its read_at < 30 min old -> stay HOLD with source=stale-ssh (read_at is NOT advanced,
#   so the stickiness cannot renew itself); otherwise `OK unknown: <err>` with source=unknown.
set -uo pipefail

state="$HOME/.cache/rb-seat/spawn-hold.json"; jf=""; now=""; probe=0; noflag=0; exempt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --journal-file) jf="${2:-}"; shift 2 ;;
    --state-file) state="${2:-}"; shift 2 ;;
    --now) now="${2:-}"; shift 2 ;;
    --probe-only) probe=1; shift ;;
    --no-flag) noflag=1; shift ;;
    --exempt) exempt="${2:-}"; shift 2 ;;
    -h|--help) sed -n 2,24p "$0"; exit 0 ;;
    *) echo "rb-spawn-hold.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
host="${RB_SPAWN_HOLD_HOST:-redbaron}"
if [ -n "${RB_SPAWN_HOLD_SSH:-}" ]; then read -r -a ssh_cmd <<< "$RB_SPAWN_HOLD_SSH"; else ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=8); fi
mkdir -p "$(dirname "$state")" 2>/dev/null || true
tmpd=$(mktemp -d "${TMPDIR:-/tmp}/rb-spawn-hold.XXXXXX") || exit 2
trap 'rm -rf "$tmpd"' EXIT
[ -n "$now" ] || now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
now_epoch=$(date -u -d "$now" +%s) || { echo "rb-spawn-hold.sh: bad --now $now" >&2; exit 2; }

# ---- one journal read ----
jfile="$tmpd/journal.jsonl"; rerr=""; source_kind=ssh
if [ -n "$jf" ]; then
  source_kind=file
  cp -- "$jf" "$jfile" 2>"$tmpd/err" || rerr="journal file unreadable: $(head -c 120 "$tmpd/err" | tr '\n' ' ')"
else
  since=$(date -u -d "@$((now_epoch - 3600))" +%Y-%m-%dT%H:%M:%SZ)
  remote='export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH; wm-build journal --since '"$since"
  if ! timeout 20 "${ssh_cmd[@]}" "$host" "$remote" >"$jfile" 2>"$tmpd/err"; then
    rerr="ssh $host journal failed: $(head -c 120 "$tmpd/err" | tr '\n' ' ')"
  fi
fi

# ---- decide + write the state file; prints: line 1 = output line, line 2 = flag action (arm <run>|clear|none) ----
decision=$(RSH_JFILE="$jfile" RSH_RERR="$rerr" RSH_STATE="$state" RSH_NOW="$now" RSH_SRC="$source_kind" RSH_EXEMPT="$exempt" python3 -I - <<'PY'
import json, os, re, datetime as dt

CEIL = 1800
now = dt.datetime.strptime(os.environ["RSH_NOW"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
state_path = os.environ["RSH_STATE"]; rerr = os.environ["RSH_RERR"]; src = os.environ["RSH_SRC"]
exempt = os.environ["RSH_EXEMPT"] or None

def pts(s):
    s = re.sub(r"(\.\d{6})\d+", r"\1", s.replace("Z", "+00:00"))
    return dt.datetime.fromisoformat(s)

def iso(d): return d.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def rid(v):
    return None if v is None else str(v)

prev = None
try:
    with open(state_path) as f: prev = json.load(f)
except Exception:
    prev = None

rows = []
if not rerr:
    bad = n = 0
    try:
        with open(os.environ["RSH_JFILE"]) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                n += 1
                try:
                    r = json.loads(line); r["_t"] = pts(r["ts"]); rows.append(r)
                except Exception:
                    bad += 1
    except Exception as e:
        rerr = "journal unreadable: %s" % e
    if not rerr and n and not rows:
        rerr = "journal had %d lines, none parseable" % n
rows.sort(key=lambda r: r["_t"])

out = {"active": False, "run_id": None, "refusal": None, "refused_at": None, "read_at": iso(now),
       "source": src, "hand_slots": 0, "parts": [], "exempt": exempt, "unknown_since": None}
line = None
# unknown_since: when the journal first became unreadable (fleet-dash warns after 10 min); carried while reads keep failing
unk0 = (prev or {}).get("unknown_since") if (prev or {}).get("source") in ("unknown", "stale-ssh") else None

if rerr:
    ok_prev = False
    if prev and prev.get("active"):
        try: ok_prev = (now - pts(prev["read_at"])).total_seconds() < CEIL
        except Exception: ok_prev = False
    if ok_prev:
        out = dict(prev); out["source"] = "stale-ssh"; out["exempt"] = exempt; out["unknown_since"] = unk0 or iso(now)
        age = int((now - pts(prev["refused_at"] or prev["read_at"])).total_seconds())
        line = "HOLD run=%s refusal=%s age_s=%d hand_slots=%s source=stale-ssh" % (out.get("run_id"), out.get("refusal"), age, out.get("hand_slots"))
    else:
        out["source"] = "unknown"; out["unknown_since"] = unk0 or iso(now)
        line = "OK unknown: %s source=unknown" % rerr.replace("\n", " ")[:200]
else:
    def fresh(age):  # the 30 min ceiling
        return age < CEIL
    def running(t, run):
        for r in rows:
            if r["_t"] <= t: continue
            row = r["row"]
            if r["op"] == "release-mem" and row.get("decision") != "refuse" and rid(row.get("run_id")) == run: return True
            if r["op"] in ("driver-adopted", "land-cargo-granted") and rid(row.get("run_id")) == run: return True
        return False
    def closed(t, run):
        for r in rows:
            row = r["row"]
            if r["_t"] > t and r["op"] == "update" and r.get("table") == "runs" and rid(row.get("id")) == run and row.get("outcome"):
                return True
        return False
    # held hand cargo jobs: via=hand taken, not released/reaped later
    taken = {}
    for r in rows:
        row = r["row"]
        if r["op"] == "cargo-jobs-taken" and row.get("via") == "hand": taken[row.get("id")] = row.get("run_id")
        elif r["op"] in ("cargo-jobs-released", "cargo-jobs-reaped"): taken.pop(row.get("id"), None)
    hand_held = [str(v) for v in taken.values()]
    hit = None
    # lagging: newest unresolved refusal inside the ceiling
    for r in reversed([r for r in rows if r["op"] == "release-mem" and r["row"].get("decision") == "refuse"]):
        run = rid(r["row"].get("run_id")); age = (now - r["_t"]).total_seconds()
        if not fresh(age): continue
        if running(r["_t"], run) or closed(r["_t"], run): continue
        parts = list(r["row"].get("parts") or [])
        hits = [p for p in parts if ":hand:" in p]
        hit = ("lagging", run, r["row"].get("refusal"), r["_t"], parts, len(hits)); break
    if hit is None and hand_held:
        for r in reversed([r for r in rows if r["op"] == "release-mem-queued"]):
            run = rid(r["row"].get("run_id")); age = (now - r["_t"]).total_seconds()
            if not fresh(age): continue
            if running(r["_t"], run): continue
            if any(x["_t"] > r["_t"] and x["op"] == "release-mem-dropped" and rid(x["row"].get("run_id")) == run for x in rows): continue
            hit = ("leading", run, "queued", r["_t"], ["%s:hand" % h for h in hand_held], len(hand_held)); break
    if hit:
        kind, run, refusal, t, parts, k = hit
        out.update(active=True, run_id=int(run) if run and run.isdigit() else run, refusal=refusal, refused_at=iso(t), hand_slots=k, parts=parts)
        line = "HOLD run=%s refusal=%s age_s=%d hand_slots=%d source=%s" % (run, refusal, int((now - t).total_seconds()), k, src)
    else:
        why = "no unresolved memory refusal in the last 60 min (%d journal rows)" % len(rows)
        line = "OK %s source=%s" % (why, src)

tmp = state_path + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f: json.dump(out, f, sort_keys=True); f.write("\n")
os.replace(tmp, state_path)
act = "none"
if out["source"] != "unknown":
    act = ("arm %s" % out["run_id"]) if out["active"] else "clear"
print(line); print(act)
PY
) || { echo "OK unknown: decision engine failed source=unknown"; exit 0; }
line=$(printf '%s\n' "$decision" | sed -n 1p); act=$(printf '%s\n' "$decision" | sed -n 2p)

# ---- AC7: running hand units yield too; the flag is only ever written/removed when its reason starts `spawn-hold` ----
if [ "$noflag" -eq 0 ]; then
  hand_dir="${CARGO_SLOT_HAND_DIR:-/mnt/data/hand}"
  qd=$(printf '%q' "$hand_dir")
  case "$act" in
    arm\ *)
      run=$(printf '%s' "${act#arm }" | tr -c 'A-Za-z0-9_-' '_')
      exp=$((now_epoch + 1800))
      rcmd="f=$qd/HAND-YIELD; if [ ! -e \"\$f\" ] || awk 'NR==1{exit !(\$2 ~ /^spawn-hold/)}' \"\$f\"; then printf '%s spawn-hold run=%s\\n' $exp $run > \"\$f.tmp.\$\$\" && mv \"\$f.tmp.\$\$\" \"\$f\" && echo armed; else echo foreign-flag-left; fi" ;;
    clear)
      rcmd="f=$qd/HAND-YIELD; if [ -e \"\$f\" ] && awk 'NR==1{exit !(\$2 ~ /^spawn-hold/)}' \"\$f\"; then rm -f \"\$f\" && echo cleared; fi" ;;
    *) rcmd="" ;;
  esac
  if [ -n "$rcmd" ]; then
    res=$(timeout 20 "${ssh_cmd[@]}" "$host" "$rcmd" 2>&1 | head -c 200 | tr '\n' ' ') || true
    [ -z "$res" ] || echo "rb-spawn-hold: HAND-YIELD $act: $res" >&2
  fi
fi

printf '%s\n' "$line"
case "$line" in
  HOLD*) [ "$probe" -eq 1 ] && exit 0; exit 76 ;;
esac
exit 0
