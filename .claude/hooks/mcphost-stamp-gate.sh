#!/usr/bin/env bash
# mcphost-stamp-gate.sh — PreToolUse hook (Bash): a write call to the mcphost hub that carries NO auth and NO
# synthetic stamp creates a tenant the hub counts as a REAL user (the hub stamps a tenant synthetic at creation only
# when the signup request has `x-mcphost-synthetic: <label>`, label ^[a-z0-9][a-z0-9:_-]{0,63}$; that covers an
# explicit `signup` AND the first keyless call, which signs up implicitly).
#
# Trigger: the command is split into SEGMENTS (on | ; & && || newlines, subshell parens, quote-aware, heredoc bodies and
# comments dropped) and each segment is judged on its own; `ssh host '...'`, `bash -c '...'`, `eval` and $(...) bodies are
# recursed into. A segment is evaluated ONLY when its first word (after env assignments, sudo/env/timeout/nice/time/nohup
# wrappers and shell keywords) is curl, wget, http, https or xh. It hits when ALL of these hold ON THAT SEGMENT:
#   (1) the hub is a URL argument (mcphost.dev, any subdomain, $MCPHOST_URL / $MCPHOST_PUBLIC_URL / $MCPHOST_HUB, or a
#       $VAR assigned a hub URL earlier in the same command); a literal hub URL whose path is /healthz, /health,
#       /.well-known/*, /docs*, /status.json is read-only and never hits;
#   (2) a real write flag sits on that segment: curl -d/--data*/--json/-F/--form/-T/--upload-file or -X POST|PUT|PATCH
#       (standalone, attached -d@f / -XPOST, or inside a cluster such as -sd; option arguments are consumed, so a header
#       value or `awk -F` elsewhere never counts); wget --post-data/--post-file/--body-*/--method POST|PUT|PATCH;
#       httpie/xh a POST|PUT|PATCH method word or a data item (k=v, k:=json, k@file). -G/--get/-I/--head/-X GET|HEAD = read;
#   (3) BODY POLICY (decided 10-23): only a call that can create a tenant counts. Keyless initialize / tools/list / ping
#       POSTs do not (no tenant is made), so a readable body that mentions neither `signup` nor `tools/call`, or no body at
#       all, is allowed. It hits when the body or URL mentions `signup` or `tools/call`, or the body is UNREADABLE (`-d @file`,
#       `-d @-`, `-T file`, a body built with $VAR / $(...)): then the absence of auth is all we can key on, EXCEPT when
#       another segment of the same command visibly handles tenant_key / Authorization / x-mcphost-synthetic (a body built
#       with the key one segment earlier is not keyless). A body built from $VAR / $(...) is flagged only when the command as
#       a whole names `tools/call` (loops over initialize / tools/list / ping with a `$m` method are protocol probes);
#   (4) the segment has none of: an Authorization header, --oauth2-bearer, -u/--user, `tenant_key`, `x-mcphost-synthetic`.
# Text that merely MENTIONS curl+hub (git commit -m, echo, heredocs, quoted strings) is not a segment head and never hits.
# Flags like `awk -F'|'`, `paste -sd`, `git log -F` in other segments are ignored. DELETE is not a write here (no tenant).
#
# MODE: WARN first, then BLOCK. WARN = exit 0 + a stderr line naming the exact header to add; from
# DEPLOY_TS + WARN_HOURS on it BLOCKS (exit 2, probe-gate's deny shape). Every hit is appended to
# ~/.local/state/mcphost-stamp-gate/warn.log (ts, mode, cwd, first 80 chars of the command with Bearer/key-shaped
# tokens redacted) so the BLOCK decision can be read off hit counts. Nothing is exempt by seat or model.
# DEPLOY_TS is the clock start recorded in this file; if the merge lands later than that, bump it in a one-line follow-up.
#
# KNOWN GAPS (not covered, do not claim otherwise): MCP-tool signups through Claude Code's mcp__mcphost__* tools; scripts
# that read the URL from a file or env (the script's own curl is never in the Bash command); non-Bash tools (WebFetch,
# python/node HTTP inside a script, etc.). A `-d @file` that holds a tenant_key warns too (false positive: add the header).
# The segment parser is best-effort (no full bash grammar): exotic quoting can hide a call, never invent one.
#
# Fails OPEN on malformed input, missing jq/python3, any parser error or an unparsable DEPLOY_TS: a bug here must never
# block unrelated Bash (settings.json also guards the file being absent).
# Test hooks (honored only with MCPHOST_STAMP_GATE_SELFTEST=1): MCPHOST_STAMP_GATE_NOW=<epoch>.
set -uo pipefail

DEPLOY_TS="2026-10-23T16:58:25-07:00"
WARN_HOURS=24

JQ=$(command -v jq) || exit 0
PY=$(command -v python3) || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0
[ "$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null); [ -n "$CWD" ] || CWD="$PWD"

# cheap pre-filter: an HTTP client word and a hub mention somewhere, else nothing below can hit
printf '%s' "$CMD" | grep -qE '(curl|wget|http|https|xh)([[:space:]]|$)' || exit 0
printf '%s' "$CMD" | grep -qiE 'mcphost\.dev|MCPHOST_(PUBLIC_)?URL|MCPHOST_HUB|\$' || exit 0

# segment-level analysis (python). exit 10 = hit (offending segment on stdout); anything else, crash or timeout = fail open.
read -r -d '' PYSRC <<'PYEOF'
import re, sys

HUB_RE = re.compile(r'mcphost\.dev|MCPHOST_(PUBLIC_)?URL|MCPHOST_HUB', re.I)
AUTH_RE = re.compile(r'authorization|--oauth2-bearer|tenant_key|x-mcphost-synthetic', re.I)
TEXT_RE = re.compile(r'signup|tools/call', re.I)
SAFE_PATH = re.compile(r'^(/healthz(/.*)?|/health(/.*)?|/\.well-known/.*|/docs(/.*)?|/status\.json)$')
MAX_DEPTH = 6

# ---------------------------------------------------------------- tokenizer
def match_paren(s, i):
    """s[i] == '(' just after '$'; return index of the matching ')' (quote-aware) or len(s)."""
    depth = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == '\\':
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            i = (j if j >= 0 else n) + 1
            continue
        if c == '"':
            i += 1
            while i < n and s[i] != '"':
                i += 2 if s[i] == '\\' else 1
            i += 1
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def split_shell(s):
    """-> (segments, nested). segments = list of word lists (quotes removed); nested = $(...) / `...` bodies."""
    segs, words, nested = [], [], []
    cur, inword = [], False
    heredocs = []          # delimiters waiting for the next newline
    skip_next_word = False  # the word after a redirection operator
    n, i = len(s), 0

    def end_word():
        nonlocal cur, inword, skip_next_word
        if inword:
            w = ''.join(cur)
            if skip_next_word:
                skip_next_word = False
            else:
                words.append(w)
        cur, inword = [], False

    def end_seg():
        nonlocal words, skip_next_word
        end_word()
        skip_next_word = False
        if words:
            segs.append(words)
        words = []

    while i < n:
        c = s[i]
        if c == '\\':
            if i + 1 < n and s[i + 1] == '\n':
                i += 2
                continue
            if i + 1 < n:
                cur.append(s[i + 1]); inword = True
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                j = n
            cur.append(s[i + 1:j]); inword = True
            i = j + 1
            continue
        if c == '"':
            i += 1; inword = True
            while i < n and s[i] != '"':
                if s[i] == '\\' and i + 1 < n:
                    if s[i + 1] in '"\\$`':
                        cur.append(s[i + 1])
                    else:
                        cur.append(s[i:i + 2])
                    i += 2
                elif s[i] == '$' and i + 1 < n and s[i + 1] == '(':
                    j = match_paren(s, i + 1)
                    nested.append(s[i + 2:j])
                    cur.append(s[i:j + 1]); i = j + 1
                elif s[i] == '`':
                    j = s.find('`', i + 1)
                    if j < 0:
                        j = n
                    nested.append(s[i + 1:j])
                    cur.append(s[i:j + 1]); i = j + 1
                else:
                    cur.append(s[i]); i += 1
            i += 1
            continue
        if c == '$' and i + 1 < n and s[i + 1] == '(':
            j = match_paren(s, i + 1)
            nested.append(s[i + 2:j])
            cur.append(s[i:j + 1]); inword = True
            i = j + 1
            continue
        if c == '`':
            j = s.find('`', i + 1)
            if j < 0:
                j = n
            nested.append(s[i + 1:j])
            cur.append(s[i:j + 1]); inword = True
            i = j + 1
            continue
        if c == '#' and not inword:
            while i < n and s[i] != '\n':
                i += 1
            continue
        if c == '\n':
            end_seg()
            i += 1
            while heredocs:
                delim, strip = heredocs.pop(0)
                while i < n:
                    j = s.find('\n', i)
                    if j < 0:
                        j = n
                    line = s[i:j]
                    i = j + 1
                    if (line.strip() if strip else line) == delim:
                        break
            continue
        if c in ';()':
            end_seg(); i += 1
            continue
        if c == '|':
            end_seg()
            i += 2 if s[i:i + 2] in ('||', '|&') else 1
            continue
        if c == '&':
            if s[i:i + 2] == '&>':           # &> file
                end_word(); skip_next_word = True
                i += 3 if s[i:i + 3] == '&>>' else 2
                continue
            end_seg()
            i += 2 if s[i:i + 2] == '&&' else 1
            continue
        if c in '<>':
            if inword and ''.join(cur).isdigit():   # fd prefix: 2>file
                cur, inword = [], False
            else:
                end_word()
            if s[i:i + 3] == '<<<':
                skip_next_word = True; i += 3
                continue
            if s[i:i + 2] == '<<':
                i += 2
                strip = s[i:i + 1] == '-'
                if strip:
                    i += 1
                while i < n and s[i] in ' \t':
                    i += 1
                d = []
                while i < n and s[i] not in ' \t\n;|&<>()':
                    if s[i] in '\'"':
                        q = s[i]; j = s.find(q, i + 1)
                        j = n if j < 0 else j
                        d.append(s[i + 1:j]); i = j + 1
                    else:
                        d.append(s[i]); i += 1
                heredocs.append((''.join(d), strip))
                continue
            i += 2 if s[i:i + 2] in ('>>', '>&', '<&', '>|') else 1
            skip_next_word = True
            continue
        if c in ' \t\r':
            end_word(); i += 1
            continue
        cur.append(c); inword = True
        i += 1
    end_seg()
    return segs, nested

# ---------------------------------------------------------------- command head
ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\+?=')
KEYWORDS = {'do', 'then', 'else', 'elif', 'if', 'while', 'until', '!', '{', '}', 'time', 'command', 'exec', 'builtin', 'nohup', 'setsid', 'then:'}
WRAP_ARGS = {  # wrapper -> options that take an argument
    'sudo': set('ughpCTrtU'), 'env': set('uSC'), 'timeout': set('sk'), 'nice': set('n'), 'stdbuf': set('ioe'),
    'ionice': set('cnp'), 'chrt': set(),
}


def strip_head(words):
    """Drop env assignments, shell keywords and sudo/env/timeout/... wrappers; return (assigns, rest)."""
    assigns = []
    i, n = 0, len(words)
    while i < n:
        w = words[i]
        base = w.rsplit('/', 1)[-1]
        if ASSIGN.match(w):
            assigns.append(w); i += 1
        elif base in KEYWORDS:
            i += 1
        elif base in WRAP_ARGS:
            optargs = WRAP_ARGS[base]
            i += 1
            while i < n:
                x = words[i]
                if base == 'env' and ASSIGN.match(x):
                    assigns.append(x); i += 1
                elif x == '--':
                    i += 1; break
                elif x.startswith('--'):
                    i += 1
                    if base == 'timeout' and x in ('--signal', '--kill-after') and '=' not in x:
                        i += 1
                elif x.startswith('-') and len(x) > 1:
                    i += 2 if (len(x) == 2 and x[1] in optargs) else 1
                else:
                    break
            if base == 'timeout' and i < n and re.match(r'^[0-9.]+[smhd]?$', words[i]):
                i += 1
            elif base == 'nice' and i < n and re.match(r'^-?[0-9]+$', words[i]):
                i += 1
        else:
            break
    return assigns, words[i:]

# ---------------------------------------------------------------- client option parsing
CURL_SHORT_ARG = set('AbcCdDeEFHKmoPQrTuUwxXyYzt')
CURL_LONG_ARG = {
    'data', 'data-raw', 'data-binary', 'data-urlencode', 'data-ascii', 'json', 'form', 'form-string', 'header',
    'proxy-header', 'request', 'user', 'proxy-user', 'output', 'url', 'upload-file', 'cookie', 'cookie-jar',
    'user-agent', 'referer', 'proxy', 'max-time', 'connect-timeout', 'write-out', 'config', 'retry', 'retry-delay',
    'retry-max-time', 'cacert', 'capath', 'cert', 'key', 'resolve', 'connect-to', 'range', 'limit-rate',
    'oauth2-bearer', 'dump-header', 'trace', 'trace-ascii', 'interface', 'max-redirs', 'unix-socket', 'aws-sigv4',
    'time-cond', 'netrc-file', 'variable', 'expand-data', 'expand-url', 'keepalive-time', 'local-port', 'noproxy',
    'request-target', 'speed-limit', 'speed-time', 'stderr', 'tls-max', 'tlsv1.3', 'ciphers', 'happy-eyeballs-timeout-ms',
    'parallel-max', 'etag-save', 'etag-compare', 'continue-at', 'create-file-mode', 'ftp-port', 'hostpubmd5',
}
CURL_BODY_LONG = ('data', 'json', 'form', 'upload-file')
WGET_LONG_ARG = {
    'post-data', 'post-file', 'body-data', 'body-file', 'method', 'header', 'output-document', 'output-file',
    'user', 'password', 'http-user', 'http-password', 'user-agent', 'referer', 'timeout', 'tries', 'wait', 'bearer',
    'directory-prefix', 'input-file', 'load-cookies', 'save-cookies', 'proxy-user', 'proxy-password', 'ca-certificate',
    'certificate', 'private-key', 'execute', 'read-timeout', 'dns-timeout', 'connect-timeout', 'level', 'accept', 'reject',
}
WGET_SHORT_ARG = set('OoPUtTwejiBlAR')
WGET_BODY = {'post-data', 'post-file', 'body-data', 'body-file'}
WRITE_METHODS = {'POST', 'PUT', 'PATCH'}


class Call:
    def __init__(self):
        self.pos = []        # positional args (URLs)
        self.method = ''
        self.write = False   # a real write flag on this segment
        self.bodies = []     # body strings (readable or not)
        self.unreadable = False   # body hidden in a file / stdin (@file, @-, -T)
        self.varbody = False      # body built from $VAR / $(...) / backticks
        self.readonly = False
        self.auth = False


def parse_curl(args):
    c = Call()
    i, n = 0, len(args)

    def body(v, kind):
        c.write = True
        if v.startswith('@') or v == '-':
            c.unreadable = True
        elif '$' in v or '`' in v:
            c.varbody = True
        c.bodies.append(v)

    while i < n:
        a = args[i]; i += 1
        if a == '--':
            c.pos.extend(args[i:]); break
        if a.startswith('--'):
            name, eq, val = a[2:].partition('=')
            has_val = bool(eq)
            takes = name in CURL_LONG_ARG
            if takes and not has_val and i < n:
                val = args[i]; i += 1; has_val = True
            if name in ('get', ):
                c.readonly = True
            elif name == 'head':
                c.readonly = True
            elif name == 'request' and has_val:
                c.method = val.upper()
            elif name == 'upload-file' and has_val:
                c.write = True; c.unreadable = True; c.bodies.append(val)
            elif name.startswith('data') or name in ('json', 'form', 'form-string'):
                if has_val:
                    body(val, 'inline')
                else:
                    c.write = True
            elif name == 'url' and has_val:
                c.pos.append(val)
            elif name in ('user', 'proxy-user', 'oauth2-bearer', 'netrc', 'netrc-file', 'aws-sigv4'):
                if name != 'proxy-user':
                    c.auth = True
            continue
        if a.startswith('-') and len(a) > 1:
            j = 1
            while j < len(a):
                ch = a[j]; j += 1
                if ch in CURL_SHORT_ARG:
                    val = a[j:]
                    if not val and i < n:
                        val = args[i]; i += 1
                    j = len(a)
                    if ch == 'd':
                        body(val, 'inline')
                    elif ch == 'F':
                        body(val, 'inline')
                    elif ch == 'T':
                        c.write = True; c.unreadable = True; c.bodies.append(val)
                    elif ch == 'X':
                        c.method = val.upper()
                    elif ch == 'u':
                        c.auth = True
                elif ch in 'IG':
                    c.readonly = True
            continue
        c.pos.append(a)
    return c


def parse_wget(args):
    c = Call()
    i, n = 0, len(args)
    while i < n:
        a = args[i]; i += 1
        if a == '--':
            c.pos.extend(args[i:]); break
        if a.startswith('--'):
            name, eq, val = a[2:].partition('=')
            if name in WGET_LONG_ARG and not eq and i < n:
                val = args[i]; i += 1; eq = '='
            if name in WGET_BODY:
                c.write = True
                if name.endswith('file') or val.startswith('@'):
                    c.unreadable = True
                elif '$' in val or '`' in val:
                    c.varbody = True
                c.bodies.append(val)
            elif name == 'method':
                c.method = val.upper()
            elif name in ('user', 'http-user', 'password', 'http-password', 'bearer'):
                c.auth = True
            continue
        if a.startswith('-') and len(a) > 1:
            j = 1
            while j < len(a):
                ch = a[j]; j += 1
                if ch in WGET_SHORT_ARG:
                    if j >= len(a) and i < n:
                        i += 1
                    break
            continue
        c.pos.append(a)
    return c


ITEM_DATA = re.compile(r'^[^=:@\s/][^=:@\s]*(:=@?|=@?|@)(?!=)')   # k=v  k:=json  k@file  (not k==v, not Header:value)


def parse_httpie(args):
    c = Call()
    i, n = 0, len(args)
    seen_url = False
    while i < n:
        a = args[i]; i += 1
        if a.startswith('-') and len(a) > 1:
            name = a.lstrip('-').split('=')[0]
            if name in ('auth', 'a', 'A', 'auth-type', 'bearer'):
                c.auth = True
            if name in ('auth', 'a', 'auth-type', 'A', 'bearer', 'o', 'output', 'timeout', 'proxy', 'session', 'verify', 'cert', 'cert-key') and '=' not in a and i < n:
                i += 1
            continue
        if not seen_url and not c.pos and a.isalpha() and a.isupper():
            c.method = a; continue
        if not seen_url:
            c.pos.append(a); seen_url = True; continue
        if '==' in a and not a.startswith('='):
            continue
        if ITEM_DATA.match(a):
            c.write = True; c.bodies.append(a)
            if '=@' in a or re.match(r'^[^=:]+@', a):
                c.unreadable = True
            elif '$' in a:
                c.varbody = True
    return c

# ---------------------------------------------------------------- judging
def var_names(w):
    return re.findall(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)', w)


def is_hub(w, hubvars):
    return bool(HUB_RE.search(w)) or any(v in hubvars for v in var_names(w))


WHOLE = ''


def judge(cmd, args, hubvars, ctx_auth=False):
    if cmd in ('curl',):
        c = parse_curl(args)
    elif cmd == 'wget':
        c = parse_wget(args)
    else:
        c = parse_httpie(args)
    hub = [p for p in c.pos if is_hub(p, hubvars)]
    if not hub:
        return False
    # a literal hub URL on a read-only path (and nothing hub-shaped but literal) is never a tenant creator
    def literal_safe(u):
        if re.search(r'\$|`', u):
            return False
        m = re.search(r'mcphost\.dev(.*)$', u, re.I)
        if not m:
            return False
        path = re.split(r'[?#]', m.group(1), 1)[0]
        return bool(SAFE_PATH.match(path))
    if all(literal_safe(u) for u in hub):
        return False
    method = c.method
    write = c.write or method in WRITE_METHODS
    if not write:
        return False
    if c.readonly or method in ('GET', 'HEAD'):
        return False
    if c.auth or AUTH_RE.search(' '.join(args)):
        return False
    text = ' '.join(c.bodies + hub)
    if TEXT_RE.search(text):
        return True
    # hidden body: unless ANOTHER segment of the same command visibly handles a tenant_key / Authorization / synthetic
    # header (e.g. `BODY=$(jq ... tenant_key:$key)` then `curl -d "$BODY"`), a file/stdin body (@file, @-, -T) is flagged;
    # a body built from $VAR / $(...) is flagged only when the command as a whole names `tools/call` (a loop over
    # initialize / tools/list / ping with `\"method\":\"$m\"` is a protocol probe, not a signup)
    if ctx_auth:
        return False
    return c.unreadable or (c.varbody and 'tools/call' in WHOLE.lower())


CLIENTS = {'curl', 'wget', 'http', 'https', 'xh'}
SSH_ARG = set('bcDEeFIiJLlmOopQRSWw')
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh'}


def analyze(text, hubvars, depth=0, outer_auth=False):
    """-> offending segment text or None."""
    if depth > MAX_DEPTH:
        return None
    segs, nested = split_shell(text)
    parsed = []
    for words in segs:
        assigns, rest = strip_head(words)
        if rest and rest[0].rsplit('/', 1)[-1] in ('export', 'declare', 'local', 'readonly', 'typeset'):
            assigns += [w for w in rest[1:] if ASSIGN.match(w)]
        for a in assigns:
            name, _, val = a.partition('=')
            if HUB_RE.search(val):
                hubvars.add(name.rstrip('+'))
        parsed.append((words, rest))
    for idx, (words, rest) in enumerate(parsed):
        if not rest:
            continue
        cmd = rest[0].rsplit('/', 1)[-1]
        args = rest[1:]
        if cmd in CLIENTS:
            ctx_auth = outer_auth or any(AUTH_RE.search(' '.join(w2)) for j, (w2, _) in enumerate(parsed) if j != idx)
            if judge(cmd, args, hubvars, ctx_auth):
                return ' '.join(words)
        elif cmd == 'ssh':
            i = 0
            while i < len(args):
                a = args[i]
                if a == '--':
                    i += 1; break
                if a.startswith('-') and len(a) > 1:
                    i += 2 if (len(a) == 2 and a[1] in SSH_ARG) else 1
                else:
                    break
            if i < len(args):          # args[i] is the host; the rest is the remote command
                r = analyze(' '.join(args[i + 1:]), hubvars, depth + 1, outer_auth or bool(AUTH_RE.search(text)))
                if r:
                    return r
        elif cmd in SHELLS:
            for k, a in enumerate(args):
                if re.match(r'^-[a-z]*c[a-z]*$', a) and k + 1 < len(args):
                    r = analyze(args[k + 1], hubvars, depth + 1, outer_auth or bool(AUTH_RE.search(text)))
                    if r:
                        return r
                    break
        elif cmd == 'eval':
            r = analyze(' '.join(args), hubvars, depth + 1, outer_auth or bool(AUTH_RE.search(text)))
            if r:
                return r
    for body in nested:
        r = analyze(body, hubvars, depth + 1, outer_auth or bool(AUTH_RE.search(text)))
        if r:
            return r
    return None


try:
    WHOLE = sys.stdin.read()
    hit = analyze(WHOLE, set())
except Exception:
    sys.exit(0)
if hit:
    sys.stdout.write(hit)
    sys.exit(10)
sys.exit(0)
PYEOF
HIT=$(printf '%s' "$CMD" | timeout 5 "$PY" -I -c "$PYSRC" 2>/dev/null); prc=$?
[ "$prc" = 10 ] || exit 0

# --- hit: decide WARN vs BLOCK from the clock --------------------------------
DEPLOY_EPOCH=$(date -d "$DEPLOY_TS" +%s 2>/dev/null) || exit 0
BLOCK_EPOCH=$(( DEPLOY_EPOCH + WARN_HOURS * 3600 ))
NOW=$(date +%s)
[ "${MCPHOST_STAMP_GATE_SELFTEST:-}" = 1 ] && [ -n "${MCPHOST_STAMP_GATE_NOW:-}" ] && NOW="$MCPHOST_STAMP_GATE_NOW"
if [ "$NOW" -ge "$BLOCK_EPOCH" ]; then MODE=BLOCK; else MODE=WARN; fi

# warn.log: ts, mode, cwd, first 80 chars of the command, Bearer/key-shaped tokens redacted BEFORE truncation
redacted=$(printf '%s' "$HIT" | tr '\n\t' '  ' \
  | sed -E 's/(Bearer[[:space:]]+)[^[:space:]"'"'"']+/\1<redacted>/Ig; s/(mcp|mh|tk|sk|pk|ak|key)[_-][A-Za-z0-9_-]{8,}/<redacted>/Ig; s/[A-Za-z0-9_+\/=-]{32,}/<redacted>/g')
LOGDIR="${HOME}/.local/state/mcphost-stamp-gate"
( umask 077; mkdir -p "$LOGDIR" 2>/dev/null \
  && printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$MODE" "$CWD" "${redacted:0:80}" >> "$LOGDIR/warn.log" ) 2>/dev/null || true

HDR="x-mcphost-synthetic: <label>"
if [ "$MODE" = WARN ]; then
  cat >&2 <<MSG
mcphost-stamp-gate WARN: keyless write to the mcphost hub creates a tenant counted as a REAL user. Add the header
  -H '$HDR'   (label ^[a-z0-9][a-z0-9:_-]{0,63}\$, e.g. harness:<script> or agent:<seat>) or send Authorization/tenant_key.
This becomes a BLOCK at $(date -d "@$BLOCK_EPOCH" '+%Y-%m-%d %I:%M %p %Z').
MSG
  exit 0
fi
cat >&2 <<MSG
mcphost-stamp-gate: BLOCKED. A keyless write to the mcphost hub creates a tenant counted as a REAL user.
Add the header  -H '$HDR'  (label ^[a-z0-9][a-z0-9:_-]{0,63}\$, e.g. harness:<script> or agent:<seat>), or send Authorization/tenant_key.
MSG
exit 2
