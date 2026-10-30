#!/usr/bin/env python3
"""wmb-agent-search-gate.py -- classifier for wmb-agent-search-gate.sh (PreToolUse, Bash).

Only acts when env WM_BUILD_AGENT=1 (set by wm-build for every inner/land/verifier agent).
Refuses (exit 2, one stderr line) a whole-tree search: find/bfs/fd/fdfind/rg/ugrep, or
grep/egrep with a recursive flag, rooted at depth <= 2 from /, at a strict ancestor of the cwd,
or at ~ itself, or under ~/.local, ~/.cache, ~/.cargo, or at /mnt/data/hand itself. The cwd and its subtree pass.
10-30 premise: `bfs -S dfs / -name PRD-...` and `ugrep -rl X . ~/.local/state/wm-build` from a
land agent drove RedBaron IO full avg10 to 97. Any internal error allows (stderr line, exit 0).
"""
import json
import os
import shlex
import sys
import time

SEP_CHARS = set(";&|()")
REDIR_CHARS = set("<>&|;()")
PREFIX_ARG_OPTS = {
    "env": {"-u", "-C", "-S", "--unset", "--chdir"},
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "-R"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
}
WRAPPERS = {"env", "sudo", "nice", "ionice", "timeout", "nohup", "time", "command", "exec"}
FIND_PRE = {"-H", "-L", "-P", "-E", "-X", "-x", "-s", "-d", "-D", "-S", "-j", "-f", "-color", "-nocolor", "-O"}
FIND_PRE_ARG = {"-D", "-S", "-j"}
GREP_SHORT_ARG = {
    "grep": set("emfABCdD"),
    "rg": set("efgtTABCmjMEr"),
    "ugrep": set("efmABCtgJKN"),
}
GREP_LONG_ARG = {
    "--regexp", "--file", "--max-count", "--after-context", "--before-context", "--context",
    "--directories", "--devices", "--include", "--exclude", "--exclude-from", "--exclude-dir",
    "--label", "--binary-files", "--group-separator", "--glob", "--iglob", "--type", "--type-not",
    "--max-depth", "--max-filesize", "--threads", "--replace", "--encoding", "--sort", "--sortr",
    "--pre", "--pre-glob", "--type-add", "--type-clear", "--ignore-file", "--path-separator",
    "--colors", "--context-separator", "--field-match-separator", "--dfa-size-limit",
    "--regex-size-limit", "--engine", "--max-columns", "--file-type", "--tag", "--format",
}
FD_SHORT_ARG = set("eEtdjSoc")
FD_LONG_ARG = {
    "--extension", "--exclude", "--type", "--max-depth", "--min-depth", "--exact-depth", "--threads",
    "--size", "--owner", "--color", "--changed-within", "--changed-before", "--max-results",
    "--ignore-file", "--format", "--batch-size", "--strip-cwd-prefix",
}


def is_sep(t):
    return t != "" and all(c in SEP_CHARS for c in t)


def is_redir(t):
    return t != "" and all(c in REDIR_CHARS for c in t) and ("<" in t or ">" in t)


def split_segments(cmd):
    cmd = cmd.replace("\r", " ").replace("\n", " ; ")
    try:
        lx = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lx.whitespace_split = True
        toks = list(lx)
    except ValueError:
        toks = [t.strip("\"'") for t in cmd.split()]
    segs, cur, skip = [], [], False
    for t in toks:
        if skip:
            skip = False
            continue
        if is_sep(t):
            if cur:
                segs.append(cur)
            cur = []
        elif is_redir(t):
            skip = True
        else:
            cur.append(t)
    if cur:
        segs.append(cur)
    return segs


def expand(path, home, cwd):
    for pre in ("${HOME}", "$HOME", "~"):
        if path == pre or path.startswith(pre + "/"):
            path = home + path[len(pre):]
            break
    if not path.startswith("/"):
        path = os.path.join(cwd, path)
    return os.path.normpath(path)


def strip_wrappers(seg):
    i = 0
    while i < len(seg):
        t = seg[i]
        base = os.path.basename(t)
        if "=" in t and not t.startswith("-") and t.split("=", 1)[0].replace("_", "a").isalnum():
            i += 1
            continue
        if base not in WRAPPERS:
            break
        i += 1
        argopts = PREFIX_ARG_OPTS.get(base, set())
        while i < len(seg):
            u = seg[i]
            if base == "env" and "=" in u and not u.startswith("-"):
                i += 1
            elif u.startswith("-") and len(u) > 1:
                i += 2 if u in argopts else 1
            else:
                break
        if base == "timeout" and i < len(seg):
            i += 1  # the duration
    return seg[i:]


def grep_family(tool, args):
    """Return (recursive, roots_args, pattern_given_flag consumed) for grep/egrep/rg/ugrep."""
    key = "grep" if tool in ("grep", "egrep", "fgrep") else tool
    short_arg = GREP_SHORT_ARG[key]
    recursive = tool in ("rg", "ugrep")
    pat_given, pos, i, endopts = False, [], 0, False
    while i < len(args):
        a = args[i]
        i += 1
        if endopts or a == "-" or not a.startswith("-"):
            pos.append(a)
            continue
        if a == "--":
            endopts = True
            continue
        if a.startswith("--"):
            name, eq, _ = a.partition("=")
            if name in ("--recursive", "--dereference-recursive"):
                recursive = True
            if name in ("--regexp", "--file"):
                pat_given = True
            if name == "--directories" and a.endswith("recurse"):
                recursive = True
            if name == "--directories" and not eq and i < len(args) and args[i] == "recurse":
                recursive = True
            if name in GREP_LONG_ARG and not eq:
                i += 1
            continue
        j = 1
        while j < len(a):
            c = a[j]
            if key == "grep" and c in "rR":
                recursive = True
            if c in short_arg:
                if c in "ef":
                    pat_given = True
                if j + 1 >= len(a):
                    i += 1
                break
            j += 1
    roots = pos if pat_given else pos[1:]
    return recursive, roots


def find_family(tool, args):
    roots, i = [], 0
    while i < len(args):
        a = args[i]
        if a in FIND_PRE or (a.startswith("-O") and a[2:].isdigit()):
            if a == "-f" and i + 1 < len(args):
                roots.append(args[i + 1])
            i += 2 if a in FIND_PRE_ARG or a == "-f" else 1
            continue
        if a.startswith("-") and a != "-" or a in ("!", ",") or a.startswith("("):
            break
        roots.append(a)
        i += 1
    return roots


def fd_family(args):
    pos, roots, base, i, endopts = [], [], None, 0, False
    while i < len(args):
        a = args[i]
        i += 1
        if endopts or a == "-" or not a.startswith("-"):
            pos.append(a)
            continue
        if a == "--":
            endopts = True
            continue
        if a in ("-x", "-X", "--exec", "--exec-batch"):
            break
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            if name == "--search-path":
                if eq:
                    roots.append(val)
                elif i < len(args):
                    roots.append(args[i]); i += 1
            elif name == "--base-directory":
                if eq:
                    base = val
                elif i < len(args):
                    base = args[i]; i += 1
            elif name in FD_LONG_ARG and not eq:
                i += 1
            continue
        j = 1
        while j < len(a):
            if a[j] in FD_SHORT_ARG:
                if j + 1 >= len(a):
                    i += 1
                break
            j += 1
    return roots + pos[1:], base


def classify(seg, home, cwd, depth=0):
    """Yield (tool, resolved_root) for each search root in one simple command; may update cwd via return."""
    seg = strip_wrappers(seg)
    if not seg:
        return cwd, []
    prog = os.path.basename(seg[0])
    args = seg[1:]
    if prog == "cd":
        if args and args[0] != "-" and not args[0].startswith("-"):
            cwd = expand(args[0], home, cwd)
        return cwd, []
    if prog in ("bash", "sh", "zsh", "dash") and depth < 2:
        for k, a in enumerate(args):
            if a.startswith("-") and not a.startswith("--") and "c" in a and k + 1 < len(args):
                found, c2 = [], cwd
                for s2 in split_segments(args[k + 1]):
                    c2, f = classify(s2, home, c2, depth + 1)
                    found += f
                return cwd, found
        return cwd, []
    raw = None
    if prog in ("find", "bfs"):
        raw = find_family(prog, args)
    elif prog in ("fd", "fdfind"):
        raw, base = fd_family(args)
        if base:
            cwd = expand(base, home, cwd)
    elif prog in ("rg", "ugrep", "grep", "egrep", "fgrep"):
        rec, raw = grep_family(prog, args)
        if not rec:
            return cwd, []
    else:
        return cwd, []
    if not raw:
        raw = ["."]
    return cwd, [(prog, expand(r, home, cwd), cwd) for r in raw]


def under(p, base):
    return p == base or p.startswith(base.rstrip("/") + "/")


def verdict(root, cwd, home):
    comps = [c for c in root.split("/") if c]
    if len(comps) <= 2:
        if os.path.isfile(root):
            return False
        return True
    if root == home or (cwd != root and under(cwd, root)):
        return True
    if under(root, cwd):
        return False
    if root == "/mnt/data/hand":
        return True
    return any(under(root, os.path.join(home, d)) for d in (".local", ".cache", ".cargo"))


def log_fire(home, tool, root):
    try:
        d = os.path.join(home, ".cache", "wmb-agent-search-gate")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "fires.log"), "a") as f:
            f.write("%s %s %s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), os.environ.get("WM_BUILD_RUN") or "-", tool, root))
    except Exception:
        pass


def main():
    if os.environ.get("WM_BUILD_AGENT") != "1":
        return 0
    data = json.load(sys.stdin)
    cmd = (data.get("tool_input") or {}).get("command") or ""
    cwd = os.path.normpath(data.get("cwd") or os.getcwd())
    home = os.path.normpath(os.environ.get("HOME") or os.path.expanduser("~"))
    for seg in split_segments(cmd):
        cwd, found = classify(seg, home, cwd)
        for tool, root, ccwd in found:
            if verdict(root, ccwd, home):
                log_fire(home, tool, root)
                sys.stderr.write(
                    "wmb-agent-search-gate: whole-tree search refused (%s rooted at %s); search inside your "
                    "worktree, e.g. grep -rn PATTERN . ; PRD files are under the PRDs repo path given in your prompt\n"
                    % (tool, root))
                return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:  # a crash must allow, never block
        sys.stderr.write("wmb-agent-search-gate: internal error, allowing (%s: %s)\n" % (type(e).__name__, e))
        sys.exit(0)
