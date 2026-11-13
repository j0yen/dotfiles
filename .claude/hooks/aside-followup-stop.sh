#!/usr/bin/env bash
# aside-followup-stop.sh: Stop hook, every Claude session on carbon (not keyed on WM_SEAT).
# Refuses a turn end when the final message holds an aside phrase (separate check, not
# investigated, ...) in a sentence with no subject token in an OPEN canonical ledger ask
# (wm-asks asks query, owner-scoped; the retired open-asks.tsv is no longer read; a failed or non-JSON read = LEDGER-UNKNOWN, never a match) and no "done" claim. A49 D3, Joe 10-31 6:4x PM. Fast, no network; allows on any error.
# A section under a "Director aside" heading is accounted (not scanned) only when the heading names a token bound to an open ledger row of this seat; a token naming nothing open, a closed/foreign row or no row suppresses nothing.
# Env: ASIDE_OPEN_ASKS (legacy, ignored), ASIDE_WM_ASKS_BIN (default wm-asks), ASIDE_STOP_LOG (fires log), FOLLOWUP_TRACE=1 (phase timings to $TMPDIR/followup-trace.log).
# F6 (A1296 pkg2 review 1, intended widening): seat ops is an alias of ctl (spec amendment 3, rev181). ops therefore sees the full ctl set, the ctl/aide
# owner catch-all included, in followup-eval.py main() and owed-now.sh lint; this hook scopes rows by the same alias (ops -> ctl owner set). No seats.tsv row is added.
set -u
# Scoped to WM_SEAT sessions (handover 2.7): a plain/director session is never gated.
[ -n "${WM_SEAT:-}" ] || exit 0
# A1300 E4: a Fable/helper child of a ctl session (fable-launch.sh --helper, WM_HELPER=1) carries no Stop-obligation of its own; every other gate stays enforced.
[ -z "${WM_HELPER:-}" ] || { cat >/dev/null 2>&1; exit 0; }
export ASIDE_OPEN_ASKS="${ASIDE_OPEN_ASKS:-$HOME/.cache/aide/open-asks.tsv}"
export ASIDE_STOP_LOG="${ASIDE_STOP_LOG:-$HOME/.local/state/aside-stop/fires.log}"
python3 -I -c '
import json, os, re, sys, time
os.umask(0o077)
LOG = os.environ["ASIDE_STOP_LOG"]
T0 = time.monotonic(); TRACE = os.environ.get("FOLLOWUP_TRACE") == "1"
def trace(phase):
    global T0
    if not TRACE:
        return
    now = time.monotonic()
    try:   # private, no-follow: a pre-existing symlink is refused (ELOOP), file is 0600 and ours
        fd = os.open(os.path.join(os.environ.get("TMPDIR") or "/tmp", "followup-trace.log"), os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            if os.fstat(fd).st_uid == os.getuid():
                os.fchmod(fd, 0o600)
                os.write(fd, ("%s aside-followup-stop phase=%s ms=%d\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), phase, (now - T0) * 1000)).encode())
        finally:
            os.close(fd)
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
    # Canonical OPEN ledger only (the retired open-asks.tsv is never read). A failed, non-JSON or malformed read is UNKNOWN:
    # nothing matches, nothing is suppressed, and the block text says so. Rows are scoped to the seat that owns them.
    import subprocess
    SEAT = os.environ.get("WM_SEAT", "")
    SEAT = "ctl" if SEAT == "ops" else SEAT   # ops = ctl alias (A1296 rev181)
    OWNERS = ("ctl", "aide") if SEAT in ("ctl", "aide") else (SEAT,)
    FIELDS = ("what", "check", "key", "scope", "title")
    open_rows, unknown, unreadable = [], "", 0
    try:
        p = subprocess.run([os.environ.get("ASIDE_WM_ASKS_BIN", "wm-asks"), "asks", "query", "--status", "open", "--json"], capture_output=True, text=True, timeout=5)
        if p.returncode != 0:
            unknown = "ledger query exit %d" % p.returncode
        else:
            lst = json.loads(p.stdout)
            if not isinstance(lst, list) or not all(isinstance(r, dict) and isinstance(r.get("ask_id"), str) for r in lst):
                unknown = "malformed ledger output"
            else:
                for r in lst:
                    if not isinstance(r.get("owner"), str) or any(r.get(k) is not None and not isinstance(r.get(k), str) for k in FIELDS):
                        unreadable += 1   # reported, never silently dropped
                    elif r["owner"] in OWNERS:
                        open_rows.append(r["ask_id"] + "\n" + "\n".join(r.get(k) or "" for k in FIELDS))
    except Exception as ex:
        unknown = "ledger command failed: %s" % type(ex).__name__
    rows = "\n".join(open_rows)
    if unknown or unreadable:
        log("ledger-unknown %s unreadable_rows=%d" % (unknown or "-", unreadable))
    def bound(t):   # a token is bound only when it names an actual open ledger row of this seat
        return bool(re.search(r"(?<![\w])" + re.escape(t) + r"(?![\w])", rows))
    trace("ledger-query")
    HEAD = re.compile(r"^\s{0,3}#{1,6}\s*director[ -]aside\b(.*)$", re.I)
    SEC = re.compile(r"^\s{0,3}#{1,6}\s")
    segs, owed_sec = [], False
    for ln in msg.split("\n"):
        h = HEAD.match(ln)
        if h:
            owed_sec = any(bound(t.strip("\"")) for t in TOK.findall(h.group(1)))
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
        hit = [t for t in toks if bound(t)]
        if hit:
            log("allow-after-match phrase=%r token=%r" % (m.group(0), hit[0]))
            continue
        s1 = s.strip()[:160]
        note = (" [LEDGER-UNKNOWN: %s; no ask could be matched]" % unknown if unknown else "") + (" [%d ledger row(s) with unreadable owner/fields not used]" % unreadable if unreadable else "")
        log("refuse phrase=%r sentence=%r" % (m.group(0), s1))
        trace("phrase-scan+verdict-block")
        print(json.dumps({"decision": "block", "reason": "aside not rowed: phrase \"%s\" in \"%s\" - fix it now or add a typed ask (wm-asks asks add --owner <seat> --due <ISO> --key <k> --check <cmd> --what <text>) naming a path/unit/PR/row id from this sentence%s" % (m.group(0), s1, note)}))
        sys.exit(0)
    trace("phrase-scan+verdict-allow")
except SystemExit:
    raise
except Exception as ex:
    log("error allow: %r" % (ex,))
sys.exit(0)
'
exit 0
