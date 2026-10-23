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
#   --selftest        stub-only checks (never real ssh, never the real hand dir): the six watcher-premise cases; prints
#                     `SELFTEST PASS rb-spawn-hold.sh` (exit 0) or `SELFTEST FAIL ...` (exit 1); the service runs it as ExecStartPre
# env: RB_SPAWN_HOLD_TIMEOUT_S (ssh journal-read timeout, default 45; a timeout reads `rc=124` in the failure text),
#      RB_SPAWN_HOLD_HOST (default redbaron), RB_SPAWN_HOLD_SSH (ssh command; default `ssh -o BatchMode=yes -o ConnectTimeout=8`),
#      CARGO_SLOT_HAND_DIR (default /mnt/data/hand on the host; the HAND-YIELD flag lives there)
#      WP_LIB (default ~/.local/lib/watcher-premise.sh; absent = flag ARM disarmed), RB_SPAWN_HOLD_EXPIRES (watcher EXPIRES, ISO)
# HAND-YIELD writes carry a premise (watcher-premise.sh): ARM = wp_gate && wp_emit_write && ssh write, only on a state change
#   (flag absent, or ours and < 10 min from expiry); CLEAR is never gated (a flag we wrote we can always remove) but still emits.
# stdout (one line): `HOLD run=<id> refusal=<r> age_s=<n> hand_slots=<k> source=<s>` exit 76, or `OK <why> source=<s>` exit 0;
#   an ssh read appends ` walls=runs:<s>,land:<s>,daemon:<s>,builder:<s>` (per-table remote wall seconds).
#
# HOLD iff EITHER
#   lagging: a `release-mem` decision=refuse row < 30 min old whose run_id has no later release-mem grant / driver-adopted /
#            land-cargo-granted row (running) and no later `update runs` row with an outcome (closed). A refused run later
#            `release-mem-dropped reason=run-ended` stays HOLD until running/closed or the 30 min ceiling.
#   leading: a `release-mem-queued` run (< 30 min old) with no later grant/drop while any via=hand cargo job is held.
# Journal window: the last 60 min (the spec says 30; hand slots taken before the 30 min mark must still count as held).
# Read failure: previous file HOLD and its read_at < 30 min old -> stay HOLD with source=stale-ssh (read_at is NOT advanced,
#   so the stickiness cannot renew itself); otherwise `OK unknown: <err>` with source=unknown.
# Blind (shu, ctl a43d: the gate failed OPEN): a non-probe, non-exempt call whose source=unknown has lasted >= 600 s since unknown_since
#   prints `HOLD unknown-blind unknown_since=<iso> age_s=<n> source=unknown fix: ...` (exit 76). Also `HOLD unknown-blind state-unreadable`
#   (state file exists but does not parse, unknown branch) and `HOLD unknown-blind engine-failed` (decision engine crash, incl. a failed
#   state write). --probe-only (the timer) and --exempt (rb-run-coder --no-cargo) never refuse; the next good read resets unknown_since.
set -uo pipefail

state="$HOME/.cache/rb-seat/spawn-hold.json"; jf=""; now=""; probe=0; noflag=0; exempt=""; selftest=0
while [ $# -gt 0 ]; do
  case "$1" in
    --journal-file) jf="${2:-}"; shift 2 ;;
    --state-file) state="${2:-}"; shift 2 ;;
    --now) now="${2:-}"; shift 2 ;;
    --probe-only) probe=1; shift ;;
    --no-flag) noflag=1; shift ;;
    --exempt) exempt="${2:-}"; shift 2 ;;
    --selftest) selftest=1; shift ;;
    -h|--help) sed -n 2,30p "$0"; exit 0 ;;
    *) echo "rb-spawn-hold.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
# ---- --selftest: the six watcher-premise cases (a-f) in a mktemp HOME; ssh = an argv-logging stub, wm-decide = a stub ----
rsh_selftest() {
  local self real_lib T fails=0 now=2026-10-23T09:30:00Z fut past
  self=$(readlink -f "${BASH_SOURCE[0]}"); real_lib=${WP_LIB:-$HOME/.local/lib/watcher-premise.sh}
  [ -r "$real_lib" ] || { echo "SELFTEST FAIL rb-spawn-hold.sh: watcher-premise lib not readable: $real_lib"; return 1; }
  T=$(mktemp -d "${TMPDIR:-/tmp}/rb-spawn-hold-selftest.XXXXXX") || return 1
  fut=$(date -d '+1 day' -Is); past=$(date -d '-1 day' -Is)
  printf '#!/usr/bin/env bash\ncmd="$*"\ncase "$cmd" in\n *"cargo-jobs list"*) echo "PREMISE $cmd" >> "$STUB_LOG"; cat "$STUB_LIST"; exit "${STUB_LIST_RC:-0}" ;;\n *hy-probe*) echo "PROBE $cmd" >> "$STUB_LOG"; echo "${STUB_FLAG:-absent}" ;;\n *hy-arm*) echo "WRITE-ARM $cmd" >> "$STUB_LOG"; echo armed ;;\n *hy-clear*) echo "WRITE-CLEAR $cmd" >> "$STUB_LOG"; echo cleared ;;\n *) echo "OTHER $cmd" >> "$STUB_LOG"; exit 3 ;;\nesac\n' > "$T/ssh.stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$STUB_DECIDE_LOG"\n' > "$T/decide.stub"
  chmod +x "$T/ssh.stub" "$T/decide.stub"
  printf 'id\trun\tproducer\tpid\talive\ttaken\tage\n11799\thand-2419612\tcargo-slot\t2419612\tyes\t2026-10-23T09:29:00+00:00\t60s\n' > "$T/list.hand"
  ago() { date -u -d "$now - $1 seconds" +%Y-%m-%dT%H:%M:%S.000000000+00:00; }
  printf '{"op":"release-mem","row":{"class":"land","decision":"refuse","refusal":"budget","run_id":1039,"parts":["hand-1:hand:5"]},"table":"runs","ts":"%s"}\n' "$(ago 300)" > "$T/hold.jsonl"
  : > "$T/ok.jsonl"
  # sc <case> <journal> <flag-state> <expires> [WP_LIB] [disarm]; sets sc_out sc_rc sc_err, logs under $T/<case>/
  sc() {
    local c=$1 d="$T/$1"; mkdir -p "$d/home/.cache/rb-seat" "$d/wp"
    [ "${6:-}" != disarm ] || : > "$d/home/.cache/rb-seat/spawn-hold.disarm"
    sc_out=$(env -i PATH="$PATH" HOME="$d/home" TMPDIR="$d" RB_SPAWN_HOLD_SSH="$T/ssh.stub" WP_LIB="${5:-$real_lib}" WP_STATE="$d/wp" \
      WP_DECIDE_BIN="$T/decide.stub" RB_SPAWN_HOLD_EXPIRES="$4" WP_OWNER=rb STUB_LOG="$d/ssh.log" STUB_LIST="$T/list.hand" \
      STUB_FLAG="$3" STUB_DECIDE_LOG="$d/decide.log" CARGO_SLOT_HAND_DIR="$d/hand" \
      bash "$self" --journal-file "$T/$2" --state-file "$d/state.json" --now "$now" 2>"$d/err"); sc_rc=$?
    sc_err=$(cat "$d/err" 2>/dev/null)
  }
  cnt() { local n; n=$(grep -c "$2" "$T/$1" 2>/dev/null); echo "${n:-0}"; }   # cnt <case>/<file> <pattern>
  chk() { # chk <label> <condition-result 0|1> <detail>
    if [ "$2" -ne 0 ]; then fails=$((fails+1)); echo "SELFTEST FAIL rb-spawn-hold.sh: case ($1) $3"; fi
  }
  local ok
  sc a hold.jsonl absent "$fut"
  ok=1; [ "$(cnt a/ssh.log '^WRITE-ARM')" = 1 ] && [ "$(cnt a/decide.log .)" = 1 ] && [[ $sc_out == HOLD* ]] && [ "$sc_rc" = 76 ] && ok=0
  chk a "$ok" "arm: write=$(cnt a/ssh.log '^WRITE-ARM') decide=$(cnt a/decide.log .) rc=$sc_rc out=$sc_out"
  sc b hold.jsonl absent "$past"
  ok=1; [ "$(cnt b/ssh.log '^WRITE')" = 0 ] && [[ $sc_err == *"HAND-YIELD arm SKIPPED (disarmed:"* ]] && [[ $sc_out == HOLD* ]] && [ "$sc_rc" = 76 ] && ok=0
  chk b "$ok" "expired: write=$(cnt b/ssh.log '^WRITE') rc=$sc_rc err=$sc_err"
  sc c hold.jsonl absent "$fut" "" disarm
  ok=1; [ "$(cnt c/ssh.log '^WRITE')" = 0 ] && [[ $sc_err == *"SKIPPED (disarmed: GONE"* ]] && ok=0
  chk c "$ok" "disarm file: write=$(cnt c/ssh.log '^WRITE') err=$sc_err"
  sc d hold.jsonl absent "$fut" /nonexistent
  ok=1; [ "$(cnt d/ssh.log '^WRITE')" = 0 ] && [[ $sc_out == HOLD* ]] && [ "$sc_rc" = 76 ] && ok=0
  chk d "$ok" "no lib: write=$(cnt d/ssh.log '^WRITE') rc=$sc_rc"
  sc e ok.jsonl ours:9999999999 "$past"
  ok=1; [ "$(cnt e/ssh.log '^WRITE-CLEAR')" = 1 ] && [ "$(cnt e/decide.log .)" = 1 ] && [[ $sc_out == OK* ]] && [ "$sc_rc" = 0 ] && ok=0
  chk e "$ok" "expired + flag present + OK: clear=$(cnt e/ssh.log '^WRITE-CLEAR') decide=$(cnt e/decide.log .) rc=$sc_rc"
  sc f hold.jsonl absent "$fut"; sc f hold.jsonl ours:9999999999 "$fut"
  ok=1; [ "$(cnt f/ssh.log '^WRITE')" = 1 ] && [ "$(cnt f/decide.log .)" -le 1 ] && ok=0
  chk f "$ok" "HOLD twice: write=$(cnt f/ssh.log '^WRITE') decide=$(cnt f/decide.log .)"
  case "$T" in */rb-spawn-hold-selftest.*) rm -rf "$T";; esac
  if [ "$fails" -eq 0 ]; then echo "SELFTEST PASS rb-spawn-hold.sh"; return 0; fi
  echo "SELFTEST FAIL rb-spawn-hold.sh: $fails case(s)"; return 1
}
[ "$selftest" -eq 0 ] || { rsh_selftest; exit $?; }

WP_LIB=${WP_LIB:-$HOME/.local/lib/watcher-premise.sh}
if [ -r "$WP_LIB" ]; then . "$WP_LIB"; else wp_arm() { return 2; }; wp_gate() { return 1; }; wp_emit_write() { return 1; }; fi   # no lib = flag writes disarmed
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
  # shj: one `wm-build journal --table <t>` read per table the predicate uses, in parallel inside one ssh session (POSIX sh on the
  # host). runs = release-mem*/update, land = land-cargo-granted, daemon = driver-adopted (filtered remote-side: it is 3 MB/h),
  # builder = cargo-jobs-taken/released/reaped (the leading HOLD's held hand jobs). Each table prints `### table=<t> rc=<n> wall_s=<n>`
  # before its rows; grep rc 1 (no match) is success, rc >= 2 is a failure. An ssh timeout kill can leak the remote mktemp -d.
  remote='export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH; d=$(mktemp -d) || exit 3
trap '\''rm -rf -- "${d:?}"'\'' EXIT; trap '\''exit 129'\'' HUP; trap '\''exit 143'\'' TERM
rd() { t=$1; s=$(date +%s)
  wm-build journal --since '"$since"' --table "$t" >"$d/$t.raw" 2>"$d/$t.err"; rc=$?
  if [ $rc -eq 0 ] && [ -n "$2" ]; then grep -F -- "$2" "$d/$t.raw" >"$d/$t.out"; g=$?; [ $g -le 1 ] || rc=$((100+g))
  elif [ $rc -eq 0 ]; then mv -- "$d/$t.raw" "$d/$t.out"; else : >"$d/$t.out"; head -c 200 "$d/$t.err" >&2; fi
  echo "$rc $(( $(date +%s) - s ))" >"$d/$t.hdr"; }
rd runs "" & rd land "" & rd daemon '\''"op":"driver-adopted"'\'' & rd builder "" & wait
bad=0
for t in runs land daemon builder; do
  if [ -r "$d/$t.hdr" ]; then read -r rc w <"$d/$t.hdr"; else rc=255; w=0; : >"$d/$t.out"; fi
  printf "### table=%s rc=%s wall_s=%s\n" "$t" "$rc" "$w"; cat "$d/$t.out"; [ "$rc" -eq 0 ] || bad=1
done
exit $bad'
  timeout_s="${RB_SPAWN_HOLD_TIMEOUT_S:-45}"
  timeout "$timeout_s" "${ssh_cmd[@]}" "$host" "$remote" >"$jfile" 2>"$tmpd/err"; src_rc=$?
  if [ "$src_rc" -ne 0 ]; then
    rerr="ssh $host journal failed: $(head -c 120 "$tmpd/err" | tr '\n' ' ') rc=$src_rc"
  fi
fi

# ---- decide + write the state file; prints: line 1 = output line, line 2 = flag action (arm <run>|clear|none) ----
decision=$(RSH_JFILE="$jfile" RSH_RERR="$rerr" RSH_STATE="$state" RSH_NOW="$now" RSH_SRC="$source_kind" RSH_EXEMPT="$exempt" RSH_PROBE="$probe" python3 -I - 2>"$tmpd/engine.err" <<'PY'
import json, os, re, datetime as dt

CEIL = 1800
TABLES = ("runs", "land", "daemon", "builder")
now =dt.datetime.strptime(os.environ["RSH_NOW"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
state_path = os.environ["RSH_STATE"]; rerr = os.environ["RSH_RERR"]; src = os.environ["RSH_SRC"]
exempt = os.environ["RSH_EXEMPT"] or None
probe_only = os.environ["RSH_PROBE"] == "1"

def pts(s):
    s = re.sub(r"(\.\d{6})\d+", r"\1", s.replace("Z", "+00:00"))
    return dt.datetime.fromisoformat(s)

def iso(d): return d.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def rid(v):
    return None if v is None else str(v)

# a MISSING state file is a first run; one that exists but does not parse (or is not an object) is state_corrupt
prev = None; state_corrupt = False
if os.path.lexists(state_path):
    try:
        with open(state_path) as f: prev = json.load(f)
        if not isinstance(prev, dict): raise ValueError("state is not an object")
    except Exception:
        prev = None; state_corrupt = True

rows = []
walls = ""
if not rerr:
    bad = n = 0
    hdrs = {}
    try:
        with open(os.environ["RSH_JFILE"]) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                if line.startswith("###"):   # per-table frame from the parallel remote read: `### table=<t> rc=<n> wall_s=<n>`
                    m = re.match(r"### table=(\w+) rc=(\d+) wall_s=(\d+)$", line)
                    if m: hdrs[m.group(1)] = (int(m.group(2)), int(m.group(3)))
                    continue
                n += 1
                try:
                    r = json.loads(line); r["_t"] = pts(r["ts"]); rows.append(r)
                except Exception:
                    bad += 1
    except Exception as e:
        rerr = "journal unreadable: %s" % e
    if not rerr and n and not rows:
        rerr = "journal had %d lines, none parseable" % n
    # a table read that failed (or a frame that never arrived) makes the whole read a failure: the survivors are not a complete picture
    if not rerr and src == "ssh":
        failed = ["%s rc=%d" % (t, hdrs[t][0]) for t in TABLES if t in hdrs and hdrs[t][0] != 0] + ["%s missing" % t for t in TABLES if t not in hdrs]
        if failed: rerr = "ssh journal table read failed: %s" % ", ".join(failed)
    if hdrs: walls = ",".join("%s:%d" % (t, hdrs[t][1]) for t in TABLES if t in hdrs)
rows.sort(key=lambda r: r["_t"])

out = {"active": False, "run_id": None, "refusal": None, "refused_at": None, "read_at": iso(now),
       "source": src, "hand_slots": 0, "parts": [], "exempt": exempt, "unknown_since": None}
line = None
# unknown_since: when the journal first became unreadable (fleet-dash warns after 10 min); carried while reads keep failing
unk0 = (prev or {}).get("unknown_since") if (prev or {}).get("source") in ("unknown", "stale-ssh") else None
if unk0 is not None:   # an unparseable unknown_since restarts the clock at now (never a traceback: the launcher handles only rc 0/76)
    try: pts(unk0)
    except Exception: unk0 = None
BLIND_FIX = "fix: ssh redbaron journal read or --no-cargo"
skip_write = False

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
        age_s = int((now - pts(out["unknown_since"])).total_seconds())
        # fail-closed (shu): only a spawn gate refuses; --probe-only (timer) and --exempt (--no-cargo) accept blindness.
        # source stays "unknown" below, so act=none and an unknown-blind HOLD never touches the HAND-YIELD flag.
        if state_corrupt and not probe_only and not exempt:
            line = "HOLD unknown-blind state-unreadable " + BLIND_FIX
            skip_write = True   # keep the corrupt file: rewriting it would restart the clock and let the next spawn through
        elif not probe_only and not exempt and age_s >= 600:
            line = "HOLD unknown-blind unknown_since=%s age_s=%d source=unknown %s" % (out["unknown_since"], age_s, BLIND_FIX)
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
        if walls: line += " walls=" + walls
    else:
        why = "no unresolved memory refusal in the last 60 min (%d journal rows)" % len(rows)
        line = "OK %s source=%s" % (why, src)
        if walls: line += " walls=" + walls

if not skip_write:
    tmp = state_path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f: json.dump(out, f, sort_keys=True); f.write("\n")
    os.replace(tmp, state_path)
act = "none"
if out["source"] != "unknown":
    act = ("arm %s" % out["run_id"]) if out["active"] else "clear"
print(line); print(act)
PY
) || {
  # the engine's stderr went to $tmpd/engine.err (never the gate's output): keep a copy beside the state file, best effort
  cp -f -- "$tmpd/engine.err" "$(dirname "$state")/engine.err" 2>/dev/null || true
  # a crash (incl. a failed state write) is blind: a spawn gate refuses. --exempt without --probe-only (the caller accepts blindness)
  # and --probe-only keep the old OK unknown / exit 0 ON PURPOSE.
  if [ "$probe" -eq 0 ] && [ -z "$exempt" ]; then echo "HOLD unknown-blind engine-failed fix: ssh redbaron journal read or --no-cargo"; exit 76; fi
  echo "OK unknown: decision engine failed source=unknown"; exit 0
}
line=$(printf '%s\n' "$decision" | sed -n 1p); act=$(printf '%s\n' "$decision" | sed -n 2p)

# ---- AC7: running hand units yield too; the flag is only ever written/removed when its reason starts `spawn-hold` ----
# Premise (watcher-premise.sh): the flag only makes sense while an rb hand cargo job holds a slot on RedBaron. Host truth = the
# slot table (`wm-build builder cargo-jobs list`: a live producer=cargo-slot hand-* row), not a seat file. rc 0 HOLDS, 1 GONE,
# 2 UNKNOWN (ssh/list failure); AND-ed with the manual retire file ~/.cache/rb-seat/spawn-hold.disarm.
rsh_premise_cmd() {
  local sq tmpl
  printf -v sq '%q ' "${ssh_cmd[@]}" "$host"
  tmpl=$(cat <<'EOF'
test ! -e "$HOME/.cache/rb-seat/spawn-hold.disarm" || exit 1
out=$(timeout 15 @SSH@'export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH; wm-build builder cargo-jobs list') || exit 2
printf '%s\n' "$out" | awk -F'\t' 'NR>1 && $2 ~ /^hand-/ && $3=="cargo-slot" && $5=="yes" {n++} END{exit !(n>0)}'
EOF
)
  printf '%s' "${tmpl//@SSH@/$sq}"
}
if [ "$noflag" -eq 0 ]; then
  hand_dir="${CARGO_SLOT_HAND_DIR:-/mnt/data/hand}"
  qd=$(printf '%q' "$hand_dir")
  export WP_OWNER=rb
  wp_arm rb-spawn-hold "$(rsh_premise_cmd)" "${RB_SPAWN_HOLD_EXPIRES:-2026-10-26T06:00:00-07:00}" \
    "an rb hand cargo job holds a slot on RedBaron while a product run is memory-refused (CSH); expires when daemon-side hand yielding ships or 10-26 6 AM" || true
  # presence read first (no write, no emit): prints absent | ours:<expiry epoch> | foreign
  pcmd=": hy-probe; f=$qd/HAND-YIELD; if [ ! -e \"\$f\" ]; then echo absent; elif awk 'NR==1{exit !(\$2 ~ /^spawn-hold/)}' \"\$f\"; then echo ours:\$(awk 'NR==1{print \$1}' \"\$f\"); else echo foreign; fi"
  fstate=""
  case "$act" in arm\ *|clear) fstate=$(timeout 20 "${ssh_cmd[@]}" "$host" "$pcmd" 2>/dev/null | head -c 100 | tr -d '\n') || fstate="" ;; esac
  rcmd=""; verb=""
  case "$act" in
    arm\ *)
      run=$(printf '%s' "${act#arm }" | tr -c 'A-Za-z0-9_-' '_')
      exp=$((now_epoch + 1800))
      case "$fstate" in
        absent) verb=arm ;;
        ours:*) fexp=${fstate#ours:}; case "$fexp" in ''|*[!0-9]*) fexp=0 ;; esac
                [ "$fexp" -ge $((now_epoch + 600)) ] || verb=refresh ;;   # steady HOLD, flag fresh = no write, no emit
      esac
      if [ -n "$verb" ]; then
        if wp_gate && wp_emit_write guard "host=$host file=$hand_dir/HAND-YIELD" "$verb HAND-YIELD run=$run" "$line" "clear HAND-YIELD (rm $hand_dir/HAND-YIELD; or touch ~/.cache/rb-seat/spawn-hold.disarm)"; then
          rcmd=": hy-arm; f=$qd/HAND-YIELD; if [ ! -e \"\$f\" ] || awk 'NR==1{exit !(\$2 ~ /^spawn-hold/)}' \"\$f\"; then printf '%s spawn-hold run=%s\\n' $exp $run > \"\$f.tmp.\$\$\" && mv \"\$f.tmp.\$\$\" \"\$f\" && echo armed; else echo foreign-flag-left; fi"
        else
          echo "rb-spawn-hold: HAND-YIELD arm SKIPPED (disarmed: ${WP_VERDICT:-no-lib}${WP_DEFECT:+ defect=$WP_DEFECT})" >&2
        fi
      fi ;;
    clear)
      case "$fstate" in
        ours:*)   # ungated: a flag the watcher wrote it can always remove, even expired; the ledger row is best-effort
          wp_emit_write guard "host=$host file=$hand_dir/HAND-YIELD" "clear HAND-YIELD" "$line" "arm HAND-YIELD (printf '<epoch> spawn-hold run=<id>' > $hand_dir/HAND-YIELD)" || true
          rcmd=": hy-clear; f=$qd/HAND-YIELD; if [ -e \"\$f\" ] && awk 'NR==1{exit !(\$2 ~ /^spawn-hold/)}' \"\$f\"; then rm -f \"\$f\" && echo cleared; fi" ;;
      esac ;;
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
