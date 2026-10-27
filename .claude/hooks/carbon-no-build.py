#!/usr/bin/env python3
"""Classifier for carbon-no-build.sh: reads the PreToolUse hook JSON on stdin and prints
'deny <rule>' or 'allow'. Carbon is for administration and monitoring (CLAUDE.md § Hosts): no builds,
no test suites, no coding.

Bash   : command position only, after unwrapping systemd-run/timeout/nice/nohup/env/setsid/sudo/time/exec;
         quotes and heredoc bodies are ignored, ssh/scp segments are ignored; the first quoted string of
         `bash -c`, `sh -c` and `tmux send-keys|new-session|new-window|...` is classified as a command.
Edit/Write/MultiEdit/NotebookEdit : the path AS GIVEN is matched against the allowlist first; else the
         symlink-resolved path is denied when it sits in a git work tree.
Agent  : subagent_type coder / coder-opus.
"""
import fnmatch, json, os, re, sys


def out(v):
    print(v)
    sys.exit(0)


try:
    data = json.load(sys.stdin)
except Exception:
    out("allow")
if not isinstance(data, dict):
    out("allow")
tool = data.get("tool_name", "") or ""
ti = data.get("tool_input", {}) or {}
if not isinstance(ti, dict):
    out("allow")

HOME = os.path.expanduser("~")

# ------------------------------------------------------------------ Agent
if tool in ("Agent", "Task"):
    st = str(ti.get("subagent_type", "") or "").rsplit(":", 1)[-1]
    if st in ("coder", "coder-opus"):
        out("deny agent-coder")
    out("allow")

# ------------------------------------------------------------------ Edit / Write
if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    p = ti.get("file_path") or ti.get("notebook_path") or ""
    if not p:
        out("allow")
    p = os.path.expanduser(str(p))
    if not os.path.isabs(p):
        p = os.path.join(str(data.get("cwd") or os.getcwd()), p)
    given = os.path.normpath(p)
    allow = [
        os.path.join(HOME, ".claude/CLAUDE.md"),
        os.path.join(HOME, ".claude/projects/*/memory/*"),
        os.path.join(HOME, "Notes/*"),
        os.path.join(HOME, ".claude/state/*"),
        os.path.join(HOME, ".cache/tmp/claude-*/*"),
        os.path.join(HOME, ".config/systemd/user/*.d/*.conf"),
        os.path.join(HOME, ".config/*"),
    ]
    # fnmatch's * crosses '/', which is what the ** globs mean
    if any(fnmatch.fnmatchcase(given, g) for g in allow):
        out("allow")
    real = os.path.realpath(given)
    home_real = os.path.realpath(HOME)
    d = os.path.dirname(real)
    while d and d != home_real and d != os.path.dirname(d):
        if os.path.exists(os.path.join(d, ".git")):
            out("deny edit-in-git-tree")
        d = os.path.dirname(d)
    out("allow")

if tool != "Bash":
    out("allow")
cmd = ti.get("command", "") or ""
if not cmd:
    out("allow")

# ------------------------------------------------------------------ Bash
WRAP_SIMPLE = {"nohup", "setsid", "time", "exec", "command", "builtin", "stdbuf", "ionice", "chrt", "taskset"}
SD_VALUE_OPTS = {"-p", "--property", "-u", "--unit", "--setenv", "-E", "--working-directory", "--slice", "--description",
                 "--uid", "--gid", "--service-type", "--on-active", "--on-calendar"}
SKIP_LEAD = {"do", "then", "else", "elif", "{", "}", "!", "if", "while", "until", "time"}
DIRECT = {"pytest", "py.test", "wm-verify-run", "tsc", "make", "gmake", "cargo", "rustc"}
READERS = {"cat", "grep", "egrep", "fgrep", "rg", "head", "tail", "ls", "wc", "git", "diff", "less", "more", "stat", "file", "sha256sum",
           "md5sum", "test", "[", "echo", "printf", "jq", "sed", "awk", "find", "readlink", "realpath", "basename", "dirname", "tee", "rm", "cp", "mv",
           "chmod", "touch", "mkdir", "seat-ask.sh", "ssh", "scp", "rsync", "gh"}
TEST_PATH = re.compile(r"(?:^|/)tests/(?:run\.sh|[^\s]*\.test\.sh)$")


def split_segments(s):
    """-> list of segments; a segment is a list of (text, quoted). Heredoc bodies are dropped."""
    lines = s.split("\n")
    kept = []
    i = 0
    while i < len(lines):
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", lines[i])
        kept.append(lines[i])
        i += 1
        if m:
            term = m.group(1)
            while i < len(lines) and lines[i].strip() != term:
                i += 1
            i += 1
    s = "\n".join(kept)
    segs, cur, tok, quoted, intok = [], [], [], False, False

    def end_tok():
        nonlocal tok, quoted, intok
        if intok:
            cur.append(("".join(tok), quoted))
        tok, quoted, intok = [], False, False

    def end_seg():
        nonlocal cur
        end_tok()
        if cur:
            segs.append(cur)
        cur = []

    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            tok.append(s[i + 1:j]); quoted = intok = True
            i = j + 1
        elif c == '"':
            j = i + 1; buf = []
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n:
                    buf.append(s[j + 1]); j += 2
                else:
                    buf.append(s[j]); j += 1
            tok.append("".join(buf)); quoted = intok = True
            i = j + 1
        elif c == "\\" and i + 1 < n:
            if s[i + 1] != "\n":
                tok.append(s[i + 1]); intok = True
            i += 2
        elif c in " \t":
            end_tok(); i += 1
        elif c == "#" and not intok:
            while i < n and s[i] != "\n":
                i += 1
        elif c in ";&|\n()`":
            end_seg(); i += 1
        else:
            tok.append(c); intok = True; i += 1
    end_seg()
    return segs


def base(t):
    return os.path.basename(t.rstrip("/"))


def unwrap(toks):
    """Drop env assignments, loop keywords and wrapper commands; return the remaining tokens (text only)."""
    t = [x[0] for x in toks]
    while t:
        w = t[0]
        if re.match(r"^[A-Za-z_]\w*=", w) or w in SKIP_LEAD:
            t = t[1:]
            continue
        b = base(w)
        if b in WRAP_SIMPLE or b == "sudo":
            t = t[1:]
            while b == "sudo" and t and t[0].startswith("-"):
                t = t[1:]
            continue
        if b == "env":
            t = t[1:]
            while t and (t[0].startswith("-") or re.match(r"^[A-Za-z_]\w*=", t[0])):
                if t[0] in ("-u", "-C", "-S"):
                    t = t[1:]
                t = t[1:]
            continue
        if b == "nice":
            t = t[1:]
            if t and t[0] == "-n":
                t = t[2:]
            elif t and re.match(r"^-\d+$", t[0]):
                t = t[1:]
            continue
        if b == "timeout":
            t = t[1:]
            while t and t[0].startswith("-"):
                t = t[2:] if t[0] in ("-s", "-k", "--signal", "--kill-after") else t[1:]
            t = t[1:]   # the duration
            continue
        if b == "systemd-run":
            t = t[1:]
            while t and t[0].startswith("-"):
                t = t[2:] if t[0] in SD_VALUE_OPTS else t[1:]
            continue
        break
    return t


def classify(cmd, depth=0):
    for seg in split_segments(cmd):
        t = unwrap(seg)
        if not t:
            continue
        b = base(t[0])
        if b in ("ssh", "scp", "sftp", "rsync"):
            continue
        rest = t[1:]
        # tests/*.test.sh at ANY token position (reads of those files excepted)
        if b not in READERS and any(TEST_PATH.search(x) for x in t):
            return "test-suite"
        if b in ("cargo", "rustc"):
            if rest and re.match(r"^(--version|-V|--help|-h)$", rest[0]):
                continue
            return "cargo"
        if b in DIRECT:
            return "build-or-test"
        if re.match(r"^python[\d.]*$", b):
            if re.search(r"(^|\s)-m\s*pytest\b", " ".join(rest)) or (rest and base(rest[0]) in ("pytest", "py.test")):
                return "pytest"
        if b in ("uv", "uvx", "poetry", "pipx", "pdm", "hatch", "npx", "pnpx", "bunx", "pnpm", "yarn", "npm", "bun") and \
                any(base(x) in ("pytest", "py.test", "tsc", "wm-verify-run") for x in rest):
            return "pytest-or-tsc"
        if b == "go":
            sub = [x for x in rest if not x.startswith("-")][:1]
            if sub and sub[0] in ("build", "test", "install"):
                return "go"
        if b in ("npm", "pnpm", "yarn", "bun"):
            sub = [x for x in rest if not x.startswith("-")][:1]
            if sub and sub[0] in ("test", "build", "run", "t", "run-script"):
                return "npm"
        if b == "aide-verifier.sh" and "launch" in rest:
            return "aide-verifier-launch"
        if b == "git":
            sub = [x for x in rest if not x.startswith("-")]
            if len(sub) >= 2 and sub[0] == "worktree" and sub[1] == "add":
                return "git-worktree-add"
        if b in ("bash", "sh", "zsh", "dash", "ksh") and depth < 4:
            for i, x in enumerate(rest):
                if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", x) and i + 1 < len(rest):
                    v = classify(rest[i + 1], depth + 1)
                    if v:
                        return v
                    break
        if b == "tmux" and depth < 4:
            sub = [x for x in rest if not x.startswith("-")][:1]
            if sub and sub[0] in ("send-keys", "send", "new-session", "new", "new-window", "neww", "split-window", "splitw", "respawn-pane", "respawn-window", "run-shell", "run"):
                for text, q in seg:
                    if q:
                        v = classify(text, depth + 1)
                        if v:
                            return v
                        break
    return None


v = classify(cmd)
out("deny " + v if v else "allow")
