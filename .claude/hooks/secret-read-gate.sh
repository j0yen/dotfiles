#!/usr/bin/env bash
# secret-read-gate.sh -- PreToolUse hook (Bash, Read, Grep), every session on every host, NO seat exemption and NO override flag.
# Added 2026-10-24. Refuses model-issued tool calls that would READ or PRINT a credential into the transcript.
# Exit 2 + ONE stderr line `secret-read-gate: REFUSED <rule>: <why> (allowed forms: ...)` blocks; exit 0 allows.
# The refusal never prints a matched value and the gate never opens a secret file; it sees only the tool-call TEXT.
# Scripts that legitimately read tokens (aide-verifier.sh TOKEN_FILE, fleet-token-place.sh) are unaffected: the hook
# never sees inside a script file, only the command line the model typed.
# Every refusal appends `<iso> <session_id> <tool> <rule> cmd=<<=120 chars, secret-shaped strings redacted>` to
# ~/.local/state/secret-read-gate/refusals.log.
#
# INCIDENTS (all 10-24, all model-issued tool calls on carbon):
#   (a) jsy-01 haiku scout printed this aide's WM_ANTHROPIC_API_KEY + CLAUDE_CODE_OAUTH_TOKEN (env / environ dump).
#   (b) 7:09 PM rb sonnet runner printed the fleet CLAUDE_CODE_OAUTH_TOKEN by sourcing RedBaron ~/.config/environment.d
#       through a sed, inside an ssh command (ctl 844d assigned the aide this hook, "with a selftest on the sed form").
#   (c) 7:33 PM the aide wrote a wiki page with an UNQUOTED heredoc whose markdown body held backticks; bash ran `env`,
#       `ps eww`, `claude -p`, `gh pr merge` and wrote env values into the page.
#
# RULES (spec secret-gate-spec.md; the A1-A10 amendments override S1-S7 where they conflict):
#   S1  SECRET PATHS, one constant (S1_MEMBERS below, a test asserts the list). Anchored at /home/<user>/ (after expanding
#       ~, $HOME, ${HOME}) or /proc/, and SEARCHED FOR INSIDE each argument string (A1), so
#       python3 -c 'open("/home/jsy/.config/environment.d/...")' refuses while a pattern argument with a slash but no
#       anchor root (grep -rn 'environment.d/90-claude-oauth.conf' .local/bin) is allowed. Paths are normalised
#       (// , /./ , /../) before matching; one-level {a,b} braces are expanded.
#   A2  GLOB: an anchored argument with * ? [ that could expand onto an S1 member (~/.config/env*/90-*), checked
#       component by component with the shell's leading-dot rule, refuses for any non-metadata command.
#   S2  BASH READS: the command is split into simple commands (| ; && || & newline, ( ) ) with shlex after quotes,
#       heredoc bodies and $(...) / backtick substitutions are pulled out (A7: heredoc bodies are stripped FIRST). It recurses
#       into bash/sh/zsh -c STRING, eval, ssh [opts] host CMD..., timeout, sudo/doas, env, xargs, nohup/nice/stdbuf/command/exec
#       and every substitution. A simple command with any argument (or `<` redirect source, or assignment value) matching S1
#       is REFUSED unless
#         (i)   argv0 is metadata-only: ls stat test [ [[ realpath readlink sha256sum md5sum wc file du;
#         (ii)  the whole pipeline's stdout AND stderr go to /dev/null (>/dev/null 2>&1, &>/dev/null, ...);
#         (iii) its stdout pipes ONLY into wc -c|-l|-w, test, [, or grep -q / grep -c.
#       A3  `source` / `.` of an S1 file is an ALLOWLIST: every OTHER simple command in the same command line must be
#       set -a, set +a, exec, claude ..., systemd-run ..., aide-launch.sh ... (the scripted `set -a; . file; set +a; claude -p`
#       launch). Anything else (python3 -c, X=$TOKEN, echo) refuses.
#   S3  ENV DUMPS refused: bare env (no command after options/assignments), printenv with no args or a secret-name arg,
#       export / export -p, declare|typeset with -p/-x or no name or a secret name, bare set, compgen -e beside a value
#       read, ps with an `e` in a BSD flag cluster (ps e, ps eww, ps auxe) or -E / --env, systemctl show-environment,
#       systemctl show -p Environment, any read of /proc/*/environ (S1). A4: echo/printf (and a <<< here-string) of
#       $VAR / ${VAR} whose name matches (TOKEN|KEY|SECRET|PASSWORD|OAUTH) refuses ANYWHERE, no source needed (incident (a):
#       sessions already carry the token in environ). ALLOWED: env -u X cmd, env V=v cmd, printenv WM_SEAT, ps -ef,
#       ps -eo pid,cmd, ps aux, ps -o pid,cmd -p 1, and the (ii)/(iii) sinks above (env | grep -c NAME).
#   S4  UNQUOTED HEREDOC (<<EOF, <<-EOF, << EOF): REFUSED when the body holds an unescaped backtick (the incident class,
#       message "quote the delimiter: <<'EOF'"); A5: also refused when the body holds $NAME / ${NAME} with a secret-shaped
#       name, or a $(...) whose text fails the S2/S3 checks ($(date) passes, $(cat <S1 path>) refuses). <<'EOF', <<"EOF"
#       and <<\EOF are never inspected, except that a body fed to a shell (bash, sh, ssh) is checked as a script.
#   S5  READ / GREP TOOLS: Read file_path or Grep path matching S1 refuses. A6: Grep content mode (the default, or
#       `content`) also refuses when path is an ANCESTOR of an S1 member (~, /home/jsy, ~/.config, ~/.claude, /proc, ...)
#       or is unset while cwd is one. files_with_matches and count stay allowed.
#   S6  PARSE FAILURE: when shlex fails on the heredoc-stripped text, fail closed on substrings: an S1 fragment
#       (environment.d, 90-claude-oauth.conf, /environ, .credentials.json, age-identity.txt, storagebox.password) AND a
#       reader word (cat sed awk grep head tail less more source xxd od strings cut jq python base64 perl) refuses.
#   S7  No seat exemption, no override flag, no env switch: an override the model can set is not a gate.
#   A10 Latency: python runs with -I -S; the test asserts 100 calls in under 6 s on carbon.
#
# KNOWN GAPS (A8; this is a text gate, not a sandbox). The real fix is mech 9, secrets OUT of the session environ:
#   - Write a script, then `bash x.sh` (the hook sees the Bash command, not the file body).
#   - Interpreter-constructed paths: python3 -c building the path from pieces, node -e process.env, perl/ruby equivalents.
#   - Relative paths after a cd (cd ~/.config/environment.d && cat 90-claude-oauth.conf); find ... -exec cat {} +;
#     `ls dir | xargs cat`; recursive grep -r over a PARENT directory of a secret path (Bash form).
#   - systemd-run --user -P env, ssh to a host that runs a script, scp/rsync pulling a secret to a readable copy are only
#     caught when the secret path itself appears in an argument.
#   - Secret-name matching is upper-case only ($api_key is not caught); an escaped or here-string-split variable name is not.
# OUT OF SCOPE (separate mechanisms): removing tokens from the session environ (mech 9), scrubbing old transcripts (mech 8).
#
# Usage: hook stdin = PreToolUse JSON.  secret-read-gate.sh --selftest | --list-s1
# Body: python3 -I -S loads the quoted heredoc at the end of THIS file (: <<'PYBODY'); the compiled code is cached under
# ~/.cache/secret-read-gate/ keyed by python version + this file's mtime and size (saves ~15 ms of compile per call). (no sibling .py to symlink per host).
set -u
command -v python3 >/dev/null 2>&1 || { echo "secret-read-gate: python3 missing, gate not applied" >&2; exit 0; }
exec python3 -I -S -c 'import sys, os, marshal
p = sys.argv[1]
st = os.stat(p)
cd = os.path.join(os.environ.get("HOME") or "/tmp", ".cache", "secret-read-gate")
cf = os.path.join(cd, "code-%x-%d-%d.bin" % (sys.hexversion, st.st_mtime_ns, st.st_size))
try:
    code = marshal.loads(open(cf, "rb").read())
except Exception:
    src = open(p, encoding="utf-8").read().split("\n: <<" + chr(39) + "PYBODY" + chr(39) + "\n", 1)[1].rsplit("\nPYBODY\n", 1)[0]
    code = compile(src, p, "exec")
    try:
        os.makedirs(cd, 0o700, exist_ok=True)
        for f in os.listdir(cd):
            if f.startswith("code-"):
                os.unlink(os.path.join(cd, f))
        tmp = cf + ".%d" % os.getpid()
        open(tmp, "wb").write(marshal.dumps(code))
        os.replace(tmp, cf)
    except Exception:
        pass
sys.argv = [p] + sys.argv[2:]
exec(code)' "$0" "$@"
exit 0
: <<'PYBODY'
import json, os, re, shlex, sys

# ---------------------------------------------------------------------------------------------------------------
# S1: the ONE member list (a test asserts it through --list-s1).
S1_MEMBERS = (
    "*/.config/environment.d/*",
    "*/90-claude-oauth.conf",
    "/proc/*/environ",
    "*/.claude/.credentials.json",
    "*/.config/mcphost-deploy/age-identity.txt",
    "*/storagebox.password",
    "*/.config/gh/hosts.yml",
)
# Concrete paths (under a home) a glob could expand to; used only by the A2 glob check.
S1_CONCRETE = (
    ".config/environment.d", ".config/environment.d/90-claude-oauth.conf", ".claude/.credentials.json",
    ".config/mcphost-deploy/age-identity.txt", ".config/mcphost-deploy/storagebox.password", ".config/gh/hosts.yml",
)
PROC_CONCRETE = ("/proc/self/environ", "/proc/1/environ", "/proc/self/task/1/environ")
S6_FRAGMENTS = ("environment.d", "90-claude-oauth.conf", "/environ", ".credentials.json", "age-identity.txt", "storagebox.password")
S6_READERS = ("cat", "sed", "awk", "grep", "head", "tail", "less", "more", "source", "xxd", "od", "strings", "cut", "jq", "python", "base64", "perl")
METADATA = {"ls", "stat", "test", "[", "[[", "realpath", "readlink", "sha256sum", "md5sum", "wc", "file", "du"}
SECRET_NAME = re.compile(r"(TOKEN|KEY|SECRET|PASSWORD|OAUTH)")
A3_ALLOW = {"claude", "systemd-run", "aide-launch.sh"}

HOME = os.environ.get("HOME") or ""
SEG = r"[^\s'\"]*"
ANCH = r"(?:/home/[^/\s'\"]+" + (("|" + re.escape(HOME.rstrip("/"))) if HOME.rstrip("/") not in ("", "/") else "") + ")"


def _member_re(m):
    if m.startswith("*/"):
        pre, rest = ANCH + "/(?:" + SEG + "/)?", m[2:]
    else:
        pre, rest = "", m
    tail = ""
    if rest.endswith("/*"):
        rest, tail = rest[:-2], "(?:/" + SEG + ")?"
    if rest.startswith("/proc/"):
        return "/proc/(?:" + SEG + "/)?environ"
    return pre + re.escape(rest).replace(r"\*", SEG) + tail


SECRET_RE = re.compile("|".join(_member_re(m) for m in S1_MEMBERS))
ANCESTOR_RE = re.compile(
    r"^(?:/|/home|/proc(?:/[^/]+)?|/home/[^/]+|/home/[^/]+/\.(?:config|claude)|/home/[^/]+/\.config/(?:mcphost-deploy|gh|environment\.d))/?$"
)
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# Sentinels: the scanner maps quoted / escaped shell metacharacters to private-use controls so shlex never sees them as operators.
SQ_DOLLAR = "\x01"
SUBST = "\x02"
FD_MARK = "\x05"
QMAP = {";": "\x10", "&": "\x11", "|": "\x12", "(": "\x13", ")": "\x14", "<": "\x15", ">": "\x16", "$": SQ_DOLLAR}
UNQ = {ord(v): k for k, v in QMAP.items()}
UNQ_KEEP_DOLLAR = {ord(v): k for k, v in QMAP.items() if k != "$"}

ALLOWED = {
    "S1": "ls/stat/sha256sum/wc on the file, >/dev/null 2>&1, or | wc -c",
    "S2": "ls/stat/sha256sum/wc on the file, >/dev/null 2>&1, | wc -c, or scripted set -a; . file; set +a; claude ...",
    "S3": "env -u X cmd, env V=v cmd, printenv WM_SEAT, ps -ef, ps -o pid,cmd, ... | grep -c NAME",
    "S4": "quote the delimiter: <<'EOF'",
    "S5": "Grep output_mode files_with_matches or count, or name a non-secret path",
    "S6": "quote the command so it parses, or avoid naming the secret path",
}


def unsent(s):
    return s.translate(UNQ)


# ---------------------------------------------------------------------------------------------------------------
# Path matching (S1, A1, A2)
def expand(s):
    s = unsent(s)
    if HOME:
        s = s.replace("${HOME}", HOME).replace("$HOME", HOME)
        s = re.sub(r"(?<![\w$])~(?=/|$|[\s'\"])", HOME, s)
    return s


def _brace(s, limit=64):
    m = re.search(r"\{([^{}]*,[^{}]*)\}", s)
    if not m:
        return [s]
    out = []
    for alt in m.group(1).split(","):
        out += _brace(s[:m.start()] + alt + s[m.end():], limit)
        if len(out) > limit:
            break
    return out[:limit]


def _comp_match(pat, cand):
    import fnmatch
    if cand.startswith(".") and not pat.startswith("."):
        return False
    return fnmatch.fnmatchcase(cand, pat)


def _glob_could_match(arg):
    """A2: can this anchored glob arg expand onto an S1 member? (component-wise, leading-dot rule)"""
    pcs = [c for c in arg.split("/") if c != ""]
    homes = []
    m = re.match(r"^/home/[^/*?\[]+", arg)
    if m:
        homes.append(m.group(0))
    if HOME and arg.startswith(HOME.rstrip("/") + "/"):
        homes.append(HOME.rstrip("/"))
    cands = [h + "/" + c for h in set(homes) for c in S1_CONCRETE]
    if arg.startswith("/proc/"):
        cands += list(PROC_CONCRETE)
    for cand in cands:
        ccs = [c for c in cand.split("/") if c != ""]
        if len(ccs) < len(pcs):
            continue
        # allow the glob to stop at a directory that contains the member only when it ends in a directory candidate
        if len(ccs) == len(pcs) and all(_comp_match(p, c) for p, c in zip(pcs, ccs)):
            return True
    return False


def s1_hit(arg):
    """Return 'path', 'glob' or None for one argument string."""
    a = expand(arg)
    cands = [a]
    if "{" in a and "," in a:
        cands += _brace(a)
    extra = []
    for c in cands:
        if "//" in c or "/./" in c or "/.." in c or c.endswith("/."):
            extra.append(os.path.normpath(re.sub(r"/{2,}", "/", c)))
    cands += extra
    for c in cands:
        if SECRET_RE.search(c):
            return "path"
    if re.search(r"[*?\[]", a):
        for c in cands:
            if re.match(r"^(?:/home/[^/]+|" + (re.escape(HOME.rstrip("/")) if HOME.rstrip("/") else "/home/[^/]+") + r"|/proc)(?:/|$)", c) and _glob_could_match(c):
                return "glob"
    return None


# ---------------------------------------------------------------------------------------------------------------
# Scanner: quotes, heredocs, substitutions (A7: heredoc bodies leave the text BEFORE shlex sees it)
def _match_paren(t, i):
    """t[i] == '(': return index of the matching ')' (len(t) when unbalanced)."""
    n, depth, j = len(t), 0, i
    while j < n:
        c = t[j]
        if c == "\\":
            j += 2
            continue
        if c == "'":
            k = t.find("'", j + 1)
            j = (k if k >= 0 else n) + 1
            continue
        if c == '"':
            j += 1
            while j < n and t[j] != '"':
                j += 2 if t[j] == "\\" else 1
            j += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return n


def scan(text):
    """-> (clean_text, substitutions[list of inner text], heredocs[list of (quoted, body)], unbalanced)"""
    out, subs, heredocs, pending = [], [], [], []
    n, i, state = len(text), 0, 0  # 0 normal, 1 single, 2 double
    while i < n:
        c = text[i]
        if state == 1:
            if c == "'":
                state = 0
                out.append(c)
            else:
                out.append(QMAP.get(c, c))
            i += 1
            continue
        if c == "\\":
            if i + 1 >= n:
                out.append(c)
                i += 1
                continue
            d = text[i + 1]
            if d == "\n":
                i += 2
                continue
            if d in QMAP:
                out.append(QMAP[d])
            else:
                out.append(c)
                out.append(d)
            i += 2
            continue
        if state == 2:
            if c == '"':
                state = 0
                out.append(c)
                i += 1
                continue
            if c in ";&|()<>":
                out.append(QMAP[c])
                i += 1
                continue
        else:
            if c == "'":
                state = 1
                out.append(c)
                i += 1
                continue
            if c == '"':
                state = 2
                out.append(c)
                i += 1
                continue
            if c == "\n":
                out.append(" ; ")
                i += 1
                for delim, strip, quoted in pending:
                    lines = []
                    while i < n:
                        j = text.find("\n", i)
                        line = text[i:] if j < 0 else text[i:j]
                        i = n if j < 0 else j + 1
                        if (line.lstrip("\t") if strip else line) == delim:
                            break
                        lines.append(line)
                    heredocs.append((quoted, "\n".join(lines)))
                pending = []
                continue
            if c == "<" and text.startswith("<<<", i):
                out.append("<<<")
                i += 3
                continue
            if c == "<" and text.startswith("<<", i):
                j, strip = i + 2, False
                if j < n and text[j] == "-":
                    strip, j = True, j + 1
                while j < n and text[j] in " \t":
                    j += 1
                quoted, d = False, []
                while j < n:
                    ch = text[j]
                    if ch in " \t\n;&|<>()":
                        break
                    if ch in "'\"":
                        k = text.find(ch, j + 1)
                        k = n if k < 0 else k
                        d.append(text[j + 1:k])
                        quoted, j = True, k + 1
                        continue
                    if ch == "\\":
                        quoted = True
                        if j + 1 < n:
                            d.append(text[j + 1])
                        j += 2
                        continue
                    d.append(ch)
                    j += 1
                delim = "".join(d)
                if delim:
                    pending.append((delim, strip, quoted))
                    out.append("<<" + ("-" if strip else "") + " HEREDOC")
                    i = j
                    continue
            if c.isdigit() and (i == 0 or text[i - 1] in " \t\n;&|(") :
                j = i
                while j < n and text[j].isdigit():
                    j += 1
                if j < n and text[j] in "<>":
                    out.append(FD_MARK + text[i:j])
                    i = j
                    continue
        if c == "$" and i + 1 < n and text[i + 1] == "(":
            e = _match_paren(text, i + 1)
            subs.append(text[i + 2:e])
            out.append(SUBST)
            i = e + 1
            continue
        if c == "`":
            j = i + 1
            while j < n and text[j] != "`":
                j += 2 if text[j] == "\\" else 1
            subs.append(text[i + 1:j])
            out.append(SUBST)
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), subs, heredocs, state != 0


# ---------------------------------------------------------------------------------------------------------------
# S4 / A5
def _check_body(body, depth):
    for m in re.finditer(r"(\\*)`", body):
        if len(m.group(1)) % 2 == 0:
            return ("S4", "unquoted heredoc body holds a backtick, bash would run it (quote the delimiter: <<'EOF')")
    for m in re.finditer(r"(\\*)\$\{?([A-Za-z_][A-Za-z0-9_]*)", body):
        if len(m.group(1)) % 2 == 0 and SECRET_NAME.search(m.group(2)):
            return ("S4", "unquoted heredoc body expands a secret-named variable (quote the delimiter: <<'EOF')")
    pos = 0
    for m in re.finditer(r"(\\*)\$\(", body):
        if len(m.group(1)) % 2 or m.start() < pos:
            continue
        e = _match_paren(body, m.end() - 1)
        pos = e
        v = analyze(body[m.end():e], False, depth + 1)
        if v:
            return ("S4", "unquoted heredoc body command substitution is refused: " + v[1])
    return None


# ---------------------------------------------------------------------------------------------------------------
# S6 fallback
def fallback(text):
    if any(f in text for f in S6_FRAGMENTS) and re.search(r"(?<![\w-])(?:" + "|".join(S6_READERS) + r")(?![\w-])", text):
        return ("S6", "command could not be parsed and names a secret path beside a reader word")
    return None


# ---------------------------------------------------------------------------------------------------------------
# Simple-command analysis
def base(w):
    return os.path.basename(w) if w else w


SIMPLE_PREFIX = {"{", "}", "!", "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "time", "command", "builtin", "exec", "nohup", "setsid", "coproc"}
OPT_WRAP = {"sudo", "doas", "timeout", "nice", "ionice", "stdbuf", "xargs", "env", "chrt", "taskset"}
WRAP_OPTARGS = {
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t"}, "doas": {"-u", "-C"}, "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "nice": {"-n"}, "ionice": {"-c", "-n", "-p", "-t"}, "stdbuf": {"-i", "-o", "-e"}, "env": {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"},
    "xargs": {"-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a", "-l", "-i"}, "chrt": set(), "taskset": set(),
}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
SSH_OPTARGS = {"-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"}


def peel(argv):
    """Strip assignments and wrapper commands. -> (prefix_tokens, inner_argv). A bare `env` is returned as ['env']."""
    pre, i, n = [], 0, len(argv)
    while True:
        while i < n and ASSIGN_RE.match(argv[i]):
            pre.append(argv[i])
            i += 1
        if i >= n:
            return pre, []
        w = base(argv[i])
        if w in SIMPLE_PREFIX:
            pre.append(argv[i])
            i += 1
            continue
        if w in OPT_WRAP:
            pre.append(argv[i])
            i += 1
            optargs = WRAP_OPTARGS.get(w, set())
            while i < n:
                t = argv[i]
                if t == "--":
                    pre.append(t)
                    i += 1
                    break
                if t.startswith("-") and t != "-":
                    pre.append(t)
                    i += 1
                    if t in optargs and i < n:
                        pre.append(argv[i])
                        i += 1
                    continue
                if w in ("env", "sudo", "doas") and ASSIGN_RE.match(t):
                    pre.append(t)
                    i += 1
                    continue
                break
            if w == "timeout" and i < n:
                pre.append(argv[i])
                i += 1
            if w == "env" and i >= n:
                return pre, ["env"]
            continue
        break
    return pre, argv[i:]


def _is_count_sink(argv):
    pre, inner = peel(argv)
    if not inner:
        return False
    a0, rest = base(inner[0]), inner[1:]
    flags = [t for t in rest if t.startswith("-")]
    if a0 in ("test", "[", "[["):
        return True
    if a0 == "wc":
        return not [t for t in rest if not t.startswith("-")] and flags and all(set(f.lstrip("-")) <= set("clw") or f in ("--bytes", "--lines", "--words") for f in flags)
    if a0 == "grep":
        return any((re.fullmatch(r"-[A-Za-z]*[qc][A-Za-z]*", f) or f in ("--quiet", "--silent", "--count")) for f in flags)
    return False


class Ctx:
    def __init__(self, text, heredoc_bodies):
        self.text = text
        self.bodies = heredoc_bodies
        self.cmds = []          # (a0, rest, assign_only) for the A3 allowlist
        self.source_cmds = []   # indexes into cmds that source an S1 file


def _dollar_names(tok):
    return re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", tok.translate(UNQ_KEEP_DOLLAR))


def _s3(a0, rest, ctx):
    flags = [t for t in rest if t.startswith("-")]
    names = [t for t in rest if not t.startswith("-")]
    if a0 == "env" and not rest:
        return "bare env dumps the whole environment"
    if a0 == "printenv":
        if not names or any(SECRET_NAME.search(unsent(t)) for t in names):
            return "printenv of the whole environment or of a secret variable"
    if a0 == "export" and ("-p" in flags or not names):
        return "export without a name lists the environment"
    if a0 in ("declare", "typeset"):
        px = any(re.fullmatch(r"-[A-Za-z]*[px][A-Za-z]*", f) for f in flags)
        if (not names and (px or not flags)) or any(SECRET_NAME.search(unsent(t).split("=")[0]) for t in names):
            return "declare dumps the environment or a secret variable"
    if a0 == "set" and not rest:
        return "bare set dumps every variable"
    if a0 == "compgen" and "-e" in flags and re.search(r"\$\{!|\beval\b|printenv|declare|xargs", ctx.text):
        return "compgen -e feeding a value read"
    if a0 == "ps":
        skip = False
        for t in rest:
            if skip:
                skip = False
                continue
            if t == "-E" or t.startswith("--env"):
                return "ps -E / --env prints process environments"
            if t.startswith("--"):
                continue
            if t.startswith("-"):
                if t in ("-C", "-G", "-g", "-U", "-u", "-p", "-q", "-s", "-t", "-o", "-O") or (len(t) > 2 and t[-1] in "CGgUupqstoO" and "=" not in t):
                    skip = True
                continue
            if re.fullmatch(r"[A-Za-z]+", t) and "e" in t:
                return "ps with the BSD e modifier prints process environments"
    if a0 == "systemctl":
        if "show-environment" in rest:
            return "systemctl show-environment dumps the manager environment"
        if "show" in rest and any("Environment" in t for t in rest):
            return "systemctl show -p Environment prints unit environments"
    if a0 in ("echo", "printf"):
        for t in rest:
            if any(SECRET_NAME.search(nm) for nm in _dollar_names(t)):
                return a0 + " of a secret-named variable"
    return None


def _shell_c_string(rest):
    i, n = 0, len(rest)
    while i < n:
        t = rest[i]
        if t in ("-o", "-O"):
            i += 2
            continue
        if t.startswith("-") and not t.startswith("--") and len(t) > 1:
            if "c" in t[1:]:
                return rest[i + 1] if i + 1 < n else None, i + 1
            i += 1
            continue
        if t.startswith("--"):
            i += 1
            continue
        break
    return None, -1


def check_cmd(argv, redirs, sunk, count_sink, ctx, depth):
    pre, inner = peel(argv)
    a0 = base(inner[0]) if inner else ""
    rest = inner[1:]
    assign_only = (not inner) and bool(pre) and all(ASSIGN_RE.match(t) for t in pre)
    skip = set()   # indexes in rest consumed by recursion
    idx = len(ctx.cmds)
    ctx.cmds.append((a0, [unsent(t) for t in rest], assign_only))
    ok_sink = sunk or count_sink
    # --- recursion into wrappers ---
    if a0 in SHELLS:
        s, pos = _shell_c_string(rest)
        if s is not None:
            skip.add(pos - 0)
            v = analyze(unsent(s), ok_sink, depth + 1)
            if v:
                return v
        elif not [t for t in rest if not t.startswith("-")] or "-s" in rest:
            for body in ctx.bodies:
                v = analyze(body, ok_sink, depth + 1)
                if v:
                    return v
    elif re.match(r"^(?:python[0-9.]*|node|nodejs|perl|ruby|php|lua)$", a0) and ctx.bodies and not ok_sink:
        # a script fed through a heredoc: no shell parse, but an anchored S1 path inside it is a read
        for body in ctx.bodies:
            if SECRET_RE.search(expand(body)):
                return ("S2", "heredoc script for an interpreter names an S1 secret path")
    elif a0 == "eval" and rest:
        v = analyze(" ".join(unsent(t) for t in rest), ok_sink, depth + 1)
        if v:
            return v
        skip = set(range(len(rest)))
    elif a0 == "ssh":
        i = 0
        while i < len(rest):
            t = rest[i]
            if t.startswith("-") and len(t) > 1:
                i += 2 if t in SSH_OPTARGS else 1
                continue
            break
        remote = rest[i + 1:]
        if remote:
            v = analyze(" ".join(unsent(t) for t in remote), ok_sink, depth + 1)
            if v:
                return v
            skip |= set(range(i + 1, len(rest)))
        if (not remote or base(remote[0]) in SHELLS) and ctx.bodies:
            for body in ctx.bodies:
                v = analyze(body, ok_sink, depth + 1)
                if v:
                    return v
    # --- S3 ---
    viol = None
    why3 = _s3(a0, [unsent(t) if a0 not in ("echo", "printf") else t for t in rest], ctx)
    if why3:
        viol = ("S3", why3)
    for op, fd, tgt in redirs:
        if op == "<<<" and any(SECRET_NAME.search(nm) for nm in _dollar_names(tgt)) and not viol:
            viol = ("S3", "here-string of a secret-named variable")
    # --- S2 ---
    scan_tokens = list(pre) + [t for k, t in enumerate(rest) if k not in skip]
    if inner:
        scan_tokens.append(inner[0])
    sources = [tgt for op, fd, tgt in redirs if op in ("<", "<>")]
    hit_kind = None
    for t in scan_tokens + sources:
        hit_kind = s1_hit(t)
        if hit_kind:
            break
    if hit_kind and a0 in ("source", "."):
        ctx.source_cmds.append(idx)
        hit_kind = None
    elif hit_kind and a0 in METADATA:
        hit_kind = None
    if hit_kind and not viol:
        viol = ("S2", "reads an S1 secret path (%s)" % ("glob that can expand onto one" if hit_kind == "glob" else "environment.d, credentials, /proc environ, ..."))
    if viol and ok_sink:
        viol = None
    return viol


def _tokenize(clean):
    lx = shlex.shlex(clean, posix=True, punctuation_chars=";&|()<>")
    lx.whitespace_split = True
    lx.commenters = ""
    return list(lx)


def _is_punct(t):
    return bool(t) and all(ch in ";&|()<>" for ch in t)


def analyze(text, sunk=False, depth=0):
    if depth > 8:
        return ("S6", "command nesting too deep to verify")
    clean, subs, heredocs, unbalanced = scan(text)
    for quoted, body in heredocs:
        if not quoted:
            v = _check_body(body, depth)
            if v:
                return v
    for s in subs:
        v = analyze(s, False, depth + 1)
        if v:
            return v
    if unbalanced:
        return fallback(clean)
    try:
        toks = _tokenize(clean)
    except ValueError:
        return fallback(clean)
    cmds, cur, redirs, pend = [], [], [], None

    def flush(pipe_out=False, pipe_err=False):
        nonlocal cur, redirs, pend
        if cur or redirs:
            cmds.append({"argv": cur, "redirs": redirs, "pipe_out": pipe_out, "pipe_err": pipe_err})
        elif pipe_out and cmds:
            cmds[-1]["pipe_out"] = True
            cmds[-1]["pipe_err"] = cmds[-1]["pipe_err"] or pipe_err
        cur, redirs, pend = [], [], None

    for t in toks:
        if _is_punct(t):
            if ("<" in t or ">" in t) and not t.endswith("("):
                fd = None
                if cur and cur[-1].startswith(FD_MARK):
                    fd = cur.pop()[1:]
                pend = (t, fd)
                continue
            if t == "|":
                flush(True, False)
            elif t == "|&":
                flush(True, True)
            else:
                flush()
            continue
        if pend:
            redirs.append((pend[0], pend[1], t))
            pend = None
        else:
            cur.append(t)
    flush()
    # fd marks that were never consumed by a redirect are plain digits
    for c in cmds:
        c["argv"] = [a[1:] if a.startswith(FD_MARK) else a for a in c["argv"]]
    ctx = Ctx(text, [b for q, b in heredocs])
    i = 0
    while i < len(cmds):
        j = i
        while j + 1 < len(cmds) and cmds[j]["pipe_out"]:
            j += 1
        pl = cmds[i:j + 1]
        states = []
        for k, c in enumerate(pl):
            st = {1: "pipe" if c["pipe_out"] else "tty", 2: "pipe" if c["pipe_err"] else "tty"}
            for op, fd, tgt in c["redirs"]:
                tgt = unsent(tgt)
                if op in (">", ">>", ">|"):
                    st[int(fd) if fd and fd.isdigit() else 1] = "null" if tgt == "/dev/null" else "file"
                elif op in ("&>", "&>>"):
                    st[1] = st[2] = "null" if tgt == "/dev/null" else "file"
                elif op == ">&":
                    if tgt.isdigit():
                        st[int(fd) if fd and fd.isdigit() else 1] = st.get(int(tgt), "tty")
                    elif tgt != "-":
                        st[1] = st[2] = "null" if tgt == "/dev/null" else "file"
            states.append(st)
        p_sunk = sunk or (all(s[1] in ("null", "pipe") and s[2] in ("null", "pipe") for s in states) and states[-1][1] == "null")
        for k, c in enumerate(pl):
            cs = (not p_sunk) and k + 1 < len(pl) and states[k][1] == "pipe" and _is_count_sink(pl[k + 1]["argv"])
            v = check_cmd(c["argv"], c["redirs"], p_sunk, cs, ctx, depth)
            if v:
                return v
        i = j + 1
    if ctx.source_cmds:
        for idx, (a0, rest, assign_only) in enumerate(ctx.cmds):
            if idx in ctx.source_cmds or assign_only is False and a0 in A3_ALLOW:
                continue
            if a0 == "set" and all(t in ("-a", "+a") for t in rest) and rest:
                continue
            if a0 == "" and not assign_only:
                continue
            return ("S2", "sourcing an S1 file is allowed only beside set -a / set +a / exec / claude / systemd-run / aide-launch.sh")
    return None


# ---------------------------------------------------------------------------------------------------------------
# Tool dispatch
def _cwd(p):
    return p.get("cwd") or os.getcwd()


def decide(p):
    tn = p.get("tool_name")
    ti = p.get("tool_input") or {}
    if not isinstance(ti, dict):
        return None
    if tn == "Bash":
        cmd = ti.get("command")
        if isinstance(cmd, str) and cmd:
            return analyze(cmd)
        return None
    if tn == "Read":
        fp = ti.get("file_path")
        if isinstance(fp, str) and fp:
            fp = expand(fp)
            if not fp.startswith("/"):
                fp = os.path.join(_cwd(p), fp)
            if s1_hit(fp):
                return ("S5", "Read of an S1 secret path")
        return None
    if tn == "Grep":
        mode = ti.get("output_mode") or "content"
        if mode in ("files_with_matches", "count"):
            return None
        path = ti.get("path")
        path = expand(path) if isinstance(path, str) and path else _cwd(p)
        if not path.startswith("/"):
            path = os.path.join(_cwd(p), path)
        path = os.path.normpath(path)
        if s1_hit(path) or ANCESTOR_RE.match(path) or (HOME and path.rstrip("/") == HOME.rstrip("/")):
            return ("S5", "Grep in content mode on an S1 secret path or a directory that holds one")
    return None


# ---------------------------------------------------------------------------------------------------------------
# Refusal log (never the command beyond 120 chars, secret-shaped strings redacted)
def redact(s):
    s = s.replace("\n", " ")
    s = re.sub(r"(?i)\b(?:sk-ant-\S+|ghp_\w+|gho_\w+|github_pat_\w+|xox\w-[\w-]+|AKIA\w{12,}|oat\w*-[\w-]{10,})", "<redacted>", s)
    s = re.sub(r"(?i)(bearer\s+)\S+", r"\1<redacted>", s)
    s = re.sub(r"((?:TOKEN|KEY|SECRET|PASSWORD|OAUTH)\w*=)\S+", r"\1<redacted>", s)
    s = re.sub(r"(?<![\w/.-])[A-Za-z0-9_+=-]{24,}(?![\w/.:-])", "<redacted>", s)
    return s[:120]


def log_refusal(p, rule):
    try:
        import time
        d = os.environ.get("SRG_LOG_DIR") or os.path.join(HOME or "/tmp", ".local/state/secret-read-gate")
        os.makedirs(d, mode=0o700, exist_ok=True)
        ti = p.get("tool_input") or {}
        what = ti.get("command") or ti.get("file_path") or ti.get("path") or ""
        sid = re.sub(r"\s", "", str(p.get("session_id") or "-"))
        with open(os.path.join(d, "refusals.log"), "a") as f:
            f.write("%s %s %s %s cmd=%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), sid, p.get("tool_name"), rule, redact(str(what))))
    except Exception:
        pass


# ---------------------------------------------------------------------------------------------------------------
# Selftest
def _b(cmd):
    return {"tool_name": "Bash", "tool_input": {"command": cmd}}


def selftest():
    SECF = "~/.config/environment.d/90-claude-oauth.conf"
    SED = "sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' " + SECF
    refuse = [
        ("sed form", _b(SED)),
        ("sed in ssh", _b('ssh redbaron "%s"' % SED)),
        ("sed in ssh opts", _b("ssh -o BatchMode=yes -p 22 redbaron '%s'" % SED)),
        ("sed in bash -c", _b("bash -c '%s'" % SED)),
        ("sed in bash -lc", _b("bash -lc \"%s\"" % SED)),
        ("sed in timeout", _b("timeout 5 " + SED)),
        ("sed in sudo", _b("sudo -u x " + SED)),
        ("sed in $()", _b("echo $(%s)" % SED)),
        ("sed in backticks", _b("echo `%s`" % SED)),
        ("cat /proc/N/environ", _b("cat /proc/1234/environ")),
        ("tr < /proc/self/environ", _b("tr '\\0' '\\n' < /proc/self/environ")),
        ("proc $$", _b("cat /proc/$$/environ")),
        ("env", _b("env")),
        ("env | sort", _b("env | sort")),
        ("printenv", _b("printenv")),
        ("printenv secret", _b("printenv CLAUDE_CODE_OAUTH_TOKEN")),
        ("ps eww", _b("ps eww -p 1")),
        ("ps auxe", _b("ps auxe")),
        ("ps e", _b("ps e")),
        ("source then echo", _b("set -a; . %s; echo $CLAUDE_CODE_OAUTH_TOKEN" % SECF)),
        ("unquoted heredoc backtick", _b("cat > f.md <<EOF\nrun `env`\nEOF")),
        ("unquoted <<- backtick", _b("cat > f.md <<-EOF\n\trun `env`\n\tEOF")),
        ("Read env.d", {"tool_name": "Read", "tool_input": {"file_path": "/home/jsy/.config/environment.d/90-claude-oauth.conf"}}),
        ("Grep content creds", {"tool_name": "Grep", "tool_input": {"pattern": "tok", "path": "~/.claude/.credentials.json", "output_mode": "content"}}),
        ("env | grep TOKEN", _b("env | grep TOKEN")),
        ("echo $TOKEN", _b("echo $CLAUDE_CODE_OAUTH_TOKEN")),
        ("printf ${KEY}", _b("printf '%s' \"${WM_ANTHROPIC_API_KEY}\"")),
        ("show-environment", _b("systemctl --user show-environment")),
        ("show -p Environment", _b("systemctl --user show -p Environment foo.service")),
        ("heredoc $(cat secret)", _b("cat > f.md <<EOF\n$(cat %s)\nEOF" % SECF)),
        ("heredoc $TOKEN", _b("cat > f.md <<EOF\nrun echo $CLAUDE_CODE_OAUTH_TOKEN\nEOF")),
        ("glob", _b("cat ~/.config/env*/90-*")),
        ("source then python", _b(". %s; python3 -c 'import os; print(os.environ)'" % SECF)),
        ("source then assign", _b(". %s; X=$CLAUDE_CODE_OAUTH_TOKEN; echo $X" % SECF)),
        ("Grep content /home/jsy", {"tool_name": "Grep", "tool_input": {"pattern": "x", "path": "/home/jsy"}}),
        ("Grep content ~/.config", {"tool_name": "Grep", "tool_input": {"pattern": "x", "path": "~/.config", "output_mode": "content"}}),
        ("python open()", _b("python3 -c 'open(\"/home/jsy/.config/environment.d/90-claude-oauth.conf\")'")),
        ("export -p", _b("export -p")),
        ("declare -p", _b("declare -p")),
        ("bare set", _b("set")),
        ("env -i bare", _b("env -i")),
        ("xargs cat", _b("echo x | xargs cat /home/jsy/.claude/.credentials.json")),
        ("redirect to null on stdout only", _b(SED + " >/dev/null")),
        ("2>&1 then null", _b(SED + " 2>&1 >/dev/null")),
        ("tee to file not sunk", _b(SED + " > /tmp/x")),
        ("var indirection", _b("F=~/.config/environment.d/90-claude-oauth.conf; sed -n p $F")),
        ("normalised ..", _b("cat /home/jsy/dotfiles/../.config/environment.d/x")),
        ("braces", _b("cat ~/.config/{environment.d,x}/90-claude-oauth.conf")),
        ("gh hosts", _b("cat ~/.config/gh/hosts.yml")),
        ("age identity", _b("head -c 20 ~/.config/mcphost-deploy/age-identity.txt")),
        ("storagebox", _b("cat /home/jsy/.config/mcphost-deploy/storagebox.password")),
        ("heredoc into bash", _b("bash <<'EOF'\ncat %s\nEOF" % SECF)),
        ("quoted ; not an operator", _b("cat ';' " + SECF)),
        ("eval", _b("eval \"cat %s\"" % SECF)),
        ("env wrapper cat", _b("env FOO=1 cat " + SECF)),
        ("S6 unbalanced quote", _b("cat " + SECF + " 'oops")),
        ("here-string var", _b("cat <<< \"$CLAUDE_CODE_OAUTH_TOKEN\"")),
        ("while read < file", _b("while read l; do echo x; done < " + SECF)),
    ]
    allow = [
        ("sed >/dev/null 2>&1", _b(SED + " >/dev/null 2>&1")),
        ("sed &>/dev/null", _b(SED + " &>/dev/null")),
        ("sed >/dev/null 2>/dev/null", _b(SED + " >/dev/null 2>/dev/null")),
        ("sed | wc -c", _b(SED + " | wc -c")),
        ("ssh sed null", _b('ssh redbaron "%s" >/dev/null 2>&1' % SED)),
        ("ls -l env.d", _b("ls -l ~/.config/environment.d/")),
        ("stat creds", _b("stat ~/.claude/.credentials.json")),
        ("sha256sum", _b("sha256sum " + SECF)),
        ("test -s", _b("test -s " + SECF)),
        ("[ -f ]", _b("[ -f %s ] && echo yes" % SECF)),
        ("env -u", _b("env -u CLAUDE_CODE_OAUTH_TOKEN claude -p x")),
        ("env V=v", _b("env FOO=1 make")),
        ("printenv WM_SEAT", _b("printenv WM_SEAT")),
        ("ps -o", _b("ps -o pid,cmd -p 1")),
        ("grep pattern", _b("grep -n environment.d .local/bin/seat-tick.sh")),
        ("quoted heredoc backtick", _b("cat > f.md <<'EOF'\nrun `env`\nEOF")),
        ("dq heredoc backtick", _b("cat > f.md <<\"EOF\"\nrun `env`\nEOF")),
        ("backslash heredoc", _b("cat > f.md <<\\EOF\nrun `env`\nEOF")),
        ("heredoc $(date)", _b("cat <<EOF\n$(date)\nEOF")),
        ("scripted launch", _b("set -a; . %s; set +a; claude -p x" % SECF)),
        ("Grep files_with_matches", {"tool_name": "Grep", "tool_input": {"pattern": "x", "path": "~/.config", "output_mode": "files_with_matches"}}),
        ("Grep count", {"tool_name": "Grep", "tool_input": {"pattern": "x", "path": "/home/jsy", "output_mode": "count"}}),
        ("Grep content repo", {"tool_name": "Grep", "tool_input": {"pattern": "x", "path": "/home/jsy/dotfiles", "output_mode": "content"}}),
        ("Read other", {"tool_name": "Read", "tool_input": {"file_path": "/home/jsy/dotfiles/README.md"}}),
        ("ps -ef", _b("ps -ef")),
        ("ps aux", _b("ps aux")),
        ("ps -eo", _b("ps -eo pid,cmd")),
        ("grep -rn unanchored", _b("grep -rn 'environment.d/90-claude-oauth.conf' .local/bin")),
        ("heredoc apostrophe", _b("cat > page.md <<EOF\nthe five-whys don't mention environment.d or sed -n here\nEOF")),
        ("echo $HOME", _b("echo $HOME")),
        ("echo WM_SEAT", _b('echo "$WM_SEAT"')),
        ("echo single-quoted token name", _b("echo '$CLAUDE_CODE_OAUTH_TOKEN is the name'")),
        ("env | grep -c", _b("env | grep -c NAME")),
        ("git status", _b("git status")),
        ("ls ~/.config", _b("ls ~/.config")),
        ("ls glob ~/.config", _b("ls ~/.config/*")),
        ("grep json glob", _b("grep -l x ~/.config/*.json")),
        ("bash -c ls", _b("bash -c 'ls ~/.config/environment.d'")),
        ("ps -C emacs", _b("ps -C emacs -o pid")),
        ("head -n 5 > null", _b("head -n 5 foo >/dev/null 2>&1")),
        ("find in repo", _b("find . -name '*.sh' -exec grep -l foo {} \\;")),
        ("heredoc to non-shell with sudo word", _b("cat > x <<'EOF'\nsudo cat ~/.config/environment.d/x\nEOF")),
        ("multi-line apostrophe comment", _b("echo hi\n# it's fine\nls")),
        ("export FOO=1", _b("export FOO=1")),
        ("declare -p NAME", _b("declare -p PATH")),
        ("systemctl show MainPID", _b("systemctl --user show -p MainPID foo.service")),
        ("read repo script", _b("sed -n 1,5p .local/bin/seat-tick.sh")),
    ]
    fails, total = [], 0
    for name, payload in refuse:
        total += 1
        v = decide(payload)
        if not v:
            fails.append("should REFUSE: " + name)
    for name, payload in allow:
        total += 1
        v = decide(payload)
        if v:
            fails.append("should ALLOW: %s (got %s: %s)" % (name, v[0], v[1]))
    # message never carries the matched value, log redacts
    total += 1
    r = redact("echo sk-ant-oat01-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 CLAUDE_CODE_OAUTH_TOKEN=abcdef123456 Bearer abcdefghijkl0123456789ABCDEFG")
    if re.search(r"sk-ant|abcdef123456|abcdefghijkl", r):
        fails.append("redact leaked: " + r)
    total += 1
    if len(redact("x " * 200)) > 120:
        fails.append("redact did not truncate")
    # S1 member list is the documented seven
    total += 1
    if len(S1_MEMBERS) != 7:
        fails.append("S1_MEMBERS length")
    # exit-code path through main() with a throwaway log dir
    import tempfile
    td = tempfile.mkdtemp()
    os.environ["SRG_LOG_DIR"] = td
    total += 1
    log_refusal({"tool_name": "Bash", "session_id": "s1", "tool_input": {"command": "cat /proc/1/environ sk-ant-oat01-ZZZZZZZZZZZZZZZZZZZZZZZZZZ"}}, "S2")
    try:
        line = open(os.path.join(td, "refusals.log")).read()
        if "S2" not in line or "sk-ant" in line:
            fails.append("log line wrong: " + line)
    except OSError as e:
        fails.append("log not written: %s" % e)
    for f in os.listdir(td):
        os.remove(os.path.join(td, f))
    os.rmdir(td)
    for f in fails:
        print("FAIL " + f)
    print("selftest: %d passed, %d failed" % (total - len(fails), len(fails)))
    return 1 if fails else 0


def main(argv):
    if len(argv) > 1 and argv[1] == "--selftest":
        return selftest()
    if len(argv) > 1 and argv[1] == "--list-s1":
        print("\n".join(S1_MEMBERS))
        return 0
    try:
        p = json.loads(sys.stdin.read())
        if not isinstance(p, dict):
            return 0
    except Exception:
        return 0
    try:
        v = decide(p)
    except Exception:
        ti = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
        v = fallback(str(ti.get("command") or "")) if p.get("tool_name") == "Bash" else None
    if not v:
        return 0
    rule, why = v
    log_refusal(p, rule)
    sys.stderr.write("secret-read-gate: REFUSED %s: %s (allowed forms: %s)\n" % (rule, why, ALLOWED.get(rule, ALLOWED["S2"])))
    return 2


sys.exit(main(sys.argv))
PYBODY
