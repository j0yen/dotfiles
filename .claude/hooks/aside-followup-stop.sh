#!/usr/bin/env bash
# aside-followup-stop.sh: Stop hook, every Claude session on carbon (not keyed on WM_SEAT).
# Refuses a turn end when the final message holds an aside phrase (separate check, not
# investigated, ...) in a sentence with no subject token in an OPEN canonical ledger ask
# (wm-asks asks query; the retired open-asks.tsv is still read, read-only, if a file exists) and no "done" claim. A49 D3, Joe 10-31 6:4x PM. Fast, no network; allows on any error.
# A section under a "Director aside" heading that itself names an owed item (id/path/unit/PR token) is accounted: its sentences are not scanned.
# Env: ASIDE_OPEN_ASKS (legacy rows file, read-only), ASIDE_WM_ASKS_BIN (default wm-asks), ASIDE_STOP_LOG (fires log), FOLLOWUP_TRACE=1 (phase timings to $TMPDIR/followup-trace.log).
set -u
# Scoped to WM_SEAT sessions (handover 2.7): a plain/director session is never gated.
[ -n "${WM_SEAT:-}" ] || exit 0
# A1300 E4: a Fable/helper child of a ctl session (fable-launch.sh --helper, WM_HELPER=1) carries no Stop-obligation of its own; every other gate stays enforced.
[ -z "${WM_HELPER:-}" ] || { cat >/dev/null 2>&1; exit 0; }
export ASIDE_OPEN_ASKS="${ASIDE_OPEN_ASKS:-$HOME/.cache/aide/open-asks.tsv}"
export ASIDE_STOP_LOG="${ASIDE_STOP_LOG:-$HOME/.local/state/aside-stop/fires.log}"
python3 -I -c '
import json, os, re, sys, time
LOG = os.environ["ASIDE_STOP_LOG"]
T0 = time.monotonic(); TRACE = os.environ.get("FOLLOWUP_TRACE") == "1"
def trace(phase):
    global T0
    if not TRACE:
        return
    now = time.monotonic()
    try:
        with open(os.path.join(os.environ.get("TMPDIR") or "/tmp", "followup-trace.log"), "a") as f:
            f.write("%s aside-followup-stop phase=%s ms=%d\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), phase, (now - T0) * 1000))
    except Exception:
        pass
    T0 = now
def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S") + " " + msg.replace("\n", " ")[:300] + "\n")
    except Exception:
        pass
try:
    d = json.load(sys.stdin)
    if d.get("stop_hook_active"):
        sys.exit(0)
    trace("stdin-parse")
    msg = d.get("last_assistant_message")
    if not msg:
        tp = d.get("transcript_path")
        msg = ""
        if tp and os.path.isfile(tp):
            for line in open(tp, errors="replace"):
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                m = e.get("message") if isinstance(e.get("message"), dict) else e
                if (e.get("type") or m.get("role")) != "assistant":
                    continue
                c = m.get("content")
                if isinstance(c, list):
                    t = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
                else:
                    t = c if isinstance(c, str) else ""
                if t.strip():
                    msg = t
    trace("transcript-read")
    PH = re.compile(r"separate check|not investigated|unrelated to|informational|still open|has not been done|flagged|worth a look|\blater\b", re.I)
    DONE = re.compile(r"(?<!not )(?<!n.t )\b(checked|fixed|done|resolved|found normal)\b|rowed as A\d+", re.I)
    TOK = re.compile(r"""(~?/[\w.@-]+(?:/[\w.@-]+)+|[\w@.-]+\.(?:service|timer)\b|[\w.-]+#\d+|\b[AP]\d+\b|\bd-2026[\w-]*|"[^"\n]{3,}")""")
    rows = ""
    try:
        keep = []
        for ln in open(os.environ["ASIDE_OPEN_ASKS"], errors="replace"):
            if ln.startswith("# CLOSED"):
                break
            if ln.startswith("#") or not ln.strip():
                continue
            keep.append(ln)
        rows = "".join(keep)
    except OSError:
        pass
    try:
        import subprocess
        p = subprocess.run([os.environ.get("ASIDE_WM_ASKS_BIN", "wm-asks"), "asks", "query", "--status", "open", "--json"], capture_output=True, text=True, timeout=5)
        if p.returncode == 0:
            rows += "\n" + p.stdout
    except Exception:
        pass
    trace("ledger-query")
    HEAD = re.compile(r"^\s{0,3}#{1,6}\s*director[ -]aside\b(.*)$", re.I)
    SEC = re.compile(r"^\s{0,3}#{1,6}\s")
    segs, owed_sec = [], False
    for ln in msg.split("\n"):
        h = HEAD.match(ln)
        if h:
            owed_sec = bool(TOK.search(h.group(1)))
            continue
        if SEC.match(ln):
            owed_sec = False
        if not owed_sec:
            segs.append(ln)
    for s in re.split(r"(?<=[.!?])\s+|\n+", "\n".join(segs)):
        m = PH.search(s)
        if not m:
            continue
        rest = s[:m.start()] + " " + s[m.end():]
        if DONE.search(rest):
            continue
        toks = [t.strip("\"") for t in TOK.findall(s)]
        hit = [t for t in toks if re.search(r"(?<![\w])" + re.escape(t) + r"(?![\w])", rows)]
        if hit:
            log("allow-after-match phrase=%r token=%r" % (m.group(0), hit[0]))
            continue
        s1 = s.strip()[:160]
        log("refuse phrase=%r sentence=%r" % (m.group(0), s1))
        trace("phrase-scan+verdict-block")
        print(json.dumps({"decision": "block", "reason": "aside not rowed: phrase \"%s\" in \"%s\" - fix it now or add a typed ask (wm-asks asks add --owner <seat> --due <ISO> --key <k> --check <cmd> --what <text>) naming a path/unit/PR/row id from this sentence" % (m.group(0), s1)}))
        sys.exit(0)
    trace("phrase-scan+verdict-allow")
except SystemExit:
    raise
except Exception as ex:
    log("error allow: %r" % (ex,))
sys.exit(0)
'
exit 0
