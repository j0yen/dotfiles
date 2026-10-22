#!/usr/bin/env python3
"""walk_guard.py -- engine for the walk-guard PreToolUse(Bash) hook.

Everything it knows about commands, roots, prunes, wrappers and hosts comes from
contracts/walk-guard.json (override: $WALK_GUARD_CONTRACT); tests/walkguard_drift.test.sh fails
if any of it is also written down here.

Modes (argv[1]):
  hook          Bash-tool JSON on stdin -> exit 0 (pass, maybe a WARN as additionalContext on stdout)
                or exit 2 (refuse; stderr carries the reason and the rewritten command).
  selftest      run the case table through the real walk-guard.sh entry point; [--write-state].
  pgrep-pattern print the ERE for `pgrep -af` generated from the contract.
  template      print the generic refusal template.
Any exception exits 3; walk-guard.sh turns that into "walk-hook internal error" (exit 2) when the
command names a guarded ssh host, else lets the call through.
"""
import json
import os
import re
import shlex
import socket
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
CONTRACT_DEFAULT = os.path.join(HERE, "..", "contracts", "walk-guard.json")
HOME = os.path.expanduser("~")
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "time", "exec",
            "command", "builtin", "sudo", "env", "nohup", "setsid"}
SHELLS = {"bash", "sh", "zsh", "dash"}
FIND_ACTIONS = {"-print", "-print0", "-printf", "-fprint", "-fprint0", "-fprintf", "-ls", "-fls",
                "-exec", "-execdir", "-ok", "-okdir", "-delete", "-quit"}
SSH_ARG_OPTS = set("bcDEeFIiJLlmOopQRSWwB")
REFUSE_BEGIN = "--- rewritten command (run this) ---"
REFUSE_END = "--- end rewritten command ---"


# --------------------------------------------------------------------------- contract
def load_contract(path=None):
    path = path or os.environ.get("WALK_GUARD_CONTRACT") or CONTRACT_DEFAULT
    with open(path) as f:
        c = json.load(f)
    for k in ("commands", "roots", "prune_dirs", "wrappers", "hosts"):
        if k not in c:
            raise ValueError("contract missing key %s" % k)
    c["_path"] = os.path.realpath(path)
    return c


def exp_home(p):
    if p == "~":
        return HOME
    if p.startswith("~/"):
        return HOME + p[1:]
    return p


class Contract:
    def __init__(self, c):
        self.c = c
        self.roots = [(os.path.normpath(exp_home(r["path"])), int(r["depth"])) for r in c["roots"]]
        self.exact = [os.path.normpath(exp_home(p)) for p in c.get("exact_roots", [])]
        self.prunes = list(c["prune_dirs"])
        w = c["wrappers"]
        self.io_class = int(re.sub(r"\D", "", w["ionice"]))
        self.nice_level = int(re.sub(r"\D", "", w["nice"]))
        self.timeout_max = int(w["timeout_max"])
        self.canon = "ionice -c%d nice -n%d timeout %d" % (self.io_class, self.nice_level, self.timeout_max)
        h = c["hosts"]
        self.ssh_targets = [t.lower() for t in h["ssh_targets"]]
        self.local_guarded = [t.lower() for t in h["local_guarded"]]
        self.never = [t.lower() for t in h["never"]]
        self.cmds = {}
        for name, prof in c["commands"].items():
            self.cmds[name] = prof
            for a in prof.get("aliases", []):
                self.cmds[a] = prof
        self.names = list(c["commands"].keys())

    def guarded(self, p):
        p = os.path.normpath(p)
        if p in self.exact:
            return True
        for base, depth in self.roots:
            if p == base:
                return True
            if p.startswith(base.rstrip("/") + "/"):
                rel = p[len(base.rstrip("/")) + 1:]
                if len([x for x in rel.split("/") if x]) <= depth:
                    return True
            elif (base.rstrip("/") + "/").startswith(p.rstrip("/") + "/"):
                return True  # p is an ancestor of a guarded root
        return False

    def pgrep_pattern(self):
        parts = []
        for name in self.names:
            prof = self.c["commands"][name]
            alts = "|".join([name] + prof.get("aliases", []))
            alts = "(%s)" % alts if prof.get("aliases") else alts
            rec = prof.get("recursive")
            if prof.get("always") or not rec:
                parts.append("(^|[ /])%s " % alts)
            else:
                letters = rec.get("short", "")
                parts.append("(^|[ /])%s (.* )?-[A-Za-z]*[%s]" % (alts, letters))
        return "|".join(parts)

    def template(self):
        h = self.ssh_targets[0]
        flags = " ".join("--exclude-dir=%s" % d for d in self.prunes)
        return "ssh %s '%s grep -r %s ...'" % (h, self.canon, flags)


# --------------------------------------------------------------------------- scanner
class Word:
    __slots__ = ("text", "start", "end", "nested")

    def __init__(self, text, start, end, nested):
        self.text, self.start, self.end, self.nested = text, start, end, nested


class Cmd:
    def __init__(self, sep):
        self.sep = sep
        self.words = []
        self.heredoc = None  # (body_start, body_end, body_text)


REDIR = re.compile(r"^[0-9]*(>>?|<>?|>&|<&|&>>?)")


def find_close(s, i):
    """s[i] is just after '$('; return index of the matching ')'."""
    depth, n, q = 1, len(s), None
    while i < n:
        ch = s[i]
        if q:
            if ch == "\\" and q == '"':
                i += 1
            elif ch == q:
                q = None
        elif ch in "'\"":
            q = ch
        elif ch == "\\":
            i += 1
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def scan(s, base=0):
    """Split a shell string into simple commands with word offsets. Flat: $( ) ( ) ` and the
    control operators all just start a new command. Quotes are removed from word text; heredoc
    bodies are attached to the command that opened them."""
    cmds = []
    cur = Cmd("")
    buf, wstart, nested = [], None, []
    pending = []  # (cmd, delim, dash)
    i, n = 0, len(s)

    def endword(i):
        nonlocal buf, wstart, nested
        if wstart is not None:
            cur.words.append(Word("".join(buf), wstart, i, nested))
        buf, wstart, nested = [], None, []

    def endcmd(sep):
        nonlocal cur
        cmds.append(cur)
        cur = Cmd(sep)

    while i < n:
        ch = s[i]
        if ch in " \t":
            endword(i)
            i += 1
        elif ch == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                i += 2
                continue
            if wstart is None:
                wstart = i
            if i + 1 < n:
                buf.append(s[i + 1])
            i += 2
        elif ch == "#" and wstart is None:
            while i < n and s[i] != "\n":
                i += 1
        elif ch == "'":
            if wstart is None:
                wstart = i
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            buf.append(s[i + 1:j])
            i = j + 1
        elif ch == '"':
            if wstart is None:
                wstart = i
            i += 1
            while i < n and s[i] != '"':
                if s[i] == "\\" and i + 1 < n:
                    if s[i + 1] in '"\\$`':
                        buf.append(s[i + 1])
                    else:
                        buf.append(s[i:i + 2])
                    i += 2
                elif s[i] == "$" and s[i + 1:i + 2] == "(":
                    j = find_close(s, i + 2)
                    nested.append((base + i + 2, s[i + 2:j]))
                    buf.append(s[i:j + 1])
                    i = j + 1
                elif s[i] == "`":
                    j = s.find("`", i + 1)
                    j = n if j < 0 else j
                    nested.append((base + i + 1, s[i + 1:j]))
                    buf.append(s[i:j + 1])
                    i = j + 1
                else:
                    buf.append(s[i])
                    i += 1
            i += 1
        elif ch == "$" and s[i + 1:i + 2] == "(":
            endword(i)
            endcmd("$(")
            i += 2
        elif ch == "<" and s[i + 1:i + 2] == "<" and s[i + 2:i + 3] != "<":
            endword(i)
            j = i + 2
            dash = False
            if s[j:j + 1] == "-":
                dash, j = True, j + 1
            while j < n and s[j] in " \t":
                j += 1
            k = j
            while k < n and s[k] not in " \t\n;|&()<>":
                k += 1
            delim = re.sub(r"""["'\\]""", "", s[j:k])
            pending.append((cur, delim, dash))
            i = k
        elif ch == "\n":
            endword(i)
            endcmd("\n")
            i += 1
            for owner, delim, dash in pending:
                body_start = i
                while i <= n:
                    j = s.find("\n", i)
                    line = s[i:(n if j < 0 else j)]
                    if (line.strip("\t") if dash else line) == delim:
                        break
                    if j < 0:
                        i = n + 1
                        break
                    i = j + 1
                body_end = min(i, n)
                owner.heredoc = (base + body_start, base + body_end, s[body_start:body_end])
                j = s.find("\n", i)
                i = n if j < 0 else j + 1
            pending = []
        elif ch in ";|(`)":
            endword(i)
            sep = ch
            if ch == "|" and s[i + 1:i + 2] == "|":
                sep, i = "||", i + 1
            elif ch == "|" and s[i + 1:i + 2] == "&":
                i += 1
            endcmd(sep)
            i += 1
        elif ch == "&":
            prev = s[i - 1] if i else ""
            nxt = s[i + 1:i + 2]
            if prev in "<>" or nxt == ">":
                if wstart is None:
                    wstart = i
                buf.append(ch)
                i += 1
            else:
                endword(i)
                sep = "&&" if nxt == "&" else "&"
                if nxt == "&":
                    i += 1
                endcmd(sep)
                i += 1
        else:
            if wstart is None:
                wstart = i
            buf.append(ch)
            i += 1
    endword(i)
    cmds.append(cur)
    out = []
    for c in cmds:
        ws, skip = [], False
        for w in c.words:
            w.start += base
            w.end += base
            if skip:
                skip = False
                continue
            if REDIR.match(w.text):
                if REDIR.sub("", w.text, count=1) == "":
                    skip = True
                continue
            ws.append(w)
        c.words = ws
        if ws or c.heredoc:
            out.append(c)
    return out


def apply_edits(text, edits, base=0):
    """edits are (start, end, repl) in absolute offsets; base = absolute offset of text[0]."""
    for a, b, r in sorted(edits, key=lambda e: -e[0]):
        text = text[:a - base] + r + text[b - base:]
    return text


# --------------------------------------------------------------------------- analysis
class Wrap:
    def __init__(self, io=False, nice=False, to=None):
        self.io, self.nice, self.to = io, nice, to

    def copy(self):
        return Wrap(self.io, self.nice, self.to)


def parse_duration(t):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([smhd]?)", t)
    if not m:
        return None
    return float(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


class Finding:
    def __init__(self, cmd, roots, hit, missing, missing_prunes, edits, rewritable):
        self.cmd, self.roots, self.hit = cmd, roots, hit
        self.missing, self.missing_prunes = missing, missing_prunes
        self.edits, self.rewritable = edits, rewritable


class Guard:
    def __init__(self, contract, host, fullcmd, cwd):
        self.k = contract
        self.host = host
        self.full = fullcmd
        self.cwd0 = cwd or HOME

    # ---- paths
    def norm(self, p, cwd):
        if re.search(r"\$(?!\{?HOME\b)", p) or "`" in p:
            return None
        p = p.replace("${HOME}", "~").replace("$HOME", "~")
        p = exp_home(p)
        m = re.search(r"[*?\[]", p)
        if m:
            p = p[:m.start()]
            p = p[:p.rfind("/") + 1] if "/" in p else ""
            if not p:
                p = "./"
        if not os.path.isabs(p):
            p = os.path.join(cwd, p)
        return os.path.normpath(p)

    # ---- wrappers
    def eat_wrappers(self, words, i, wrap):
        """Consume env assignments / keywords / ionice / nice / timeout. Returns (i, wrap, first_wrapper_idx)."""
        wrap = wrap.copy()
        first = None
        while i < len(words):
            t = words[i].text
            base = os.path.basename(t)
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t) or t in KEYWORDS:
                i += 1
                continue
            if base == "ionice":
                j, cls = i + 1, None
                while j < len(words) and words[j].text.startswith("-"):
                    o = words[j].text
                    if o in ("-c", "--class") and j + 1 < len(words):
                        cls, j = words[j + 1].text, j + 2
                    elif o.startswith("--class="):
                        cls, j = o.split("=", 1)[1], j + 1
                    elif o.startswith("-c") and len(o) > 2:
                        cls, j = o[2:], j + 1
                    elif o in ("-n", "--classdata", "-u", "--uid", "-p", "--pid", "-P", "--pgid"):
                        j += 2
                    else:
                        j += 1
                if first is None:
                    first = i
                if cls in (str(self.k.io_class), "idle"):
                    wrap.io = True
                i = j
            elif base == "nice":
                j, lvl = i + 1, None
                while j < len(words) and words[j].text.startswith("-"):
                    o = words[j].text
                    if o in ("-n", "--adjustment") and j + 1 < len(words):
                        lvl, j = words[j + 1].text, j + 2
                    elif o.startswith("--adjustment="):
                        lvl, j = o.split("=", 1)[1], j + 1
                    elif re.fullmatch(r"-n[+-]?\d+", o):
                        lvl, j = o[2:], j + 1
                    elif re.fullmatch(r"-\d+", o):
                        lvl, j = o[1:], j + 1
                    else:
                        j += 1
                if first is None:
                    first = i
                if lvl is not None and re.fullmatch(r"\+?\d+", lvl) and int(lvl) == self.k.nice_level:
                    wrap.nice = True
                i = j
            elif base == "timeout":
                j, dur = i + 1, None
                while j < len(words) and words[j].text.startswith("-"):
                    o = words[j].text
                    if o in ("-k", "--kill-after", "-s", "--signal"):
                        j += 2
                    else:
                        j += 1
                if j < len(words):
                    dur = parse_duration(words[j].text)
                    j += 1
                if first is None:
                    first = i
                if dur is not None and 0 < dur <= self.k.timeout_max:
                    wrap.to = dur
                i = j
            else:
                break
        return i, wrap, first

    # ---- per-command parsing
    def extract(self, prof, args, piped):
        """-> (is_walk, [root strings]) for a walk command's args (list of Word)."""
        texts = [w.text for w in args]
        rec = prof.get("recursive")
        if prof.get("roots") == "leading":
            roots, j = [], 0
            while j < len(texts):
                t = texts[j]
                if t in ("-H", "-L", "-P") or re.fullmatch(r"-O\d", t):
                    j += 1
                elif t == "-D":
                    j += 2
                elif t.startswith("-") or t in ("(", "!", ","):
                    break
                else:
                    roots.append(t)
                    j += 1
            return True, (roots or ["."]), j
        opt_args = set(prof.get("opt_args", []))
        pat_flags = set(prof.get("pattern_flags", []))
        nopat = set(prof.get("no_pattern_flags", []))
        is_rec = bool(prof.get("always"))
        have_pat = False
        pos, j, rest = [], 0, False
        while j < len(texts):
            t = texts[j]
            if rest or t == "-" or not t.startswith("-"):
                pos.append(t)
                j += 1
                continue
            if t == "--":
                rest = True
                j += 1
                continue
            if t.startswith("--"):
                name = t.split("=", 1)[0]
                if rec and name in rec.get("long", []):
                    is_rec = True
                for a, b in (rec or {}).get("pairs", []):
                    if name == a and ("=" in t and t.split("=", 1)[1] == b or j + 1 < len(texts) and texts[j + 1] == b):
                        is_rec = True
                if name in pat_flags:
                    have_pat = True
                if name in nopat:
                    have_pat = True
                if "=" not in t and name in opt_args:
                    j += 1
                j += 1
                continue
            # short cluster
            k = 1
            while k < len(t):
                c = "-" + t[k]
                if rec and t[k] in rec.get("short", ""):
                    is_rec = True
                if c in pat_flags:
                    have_pat = True
                if c in opt_args:
                    for a, b in (rec or {}).get("pairs", []):
                        val = t[k + 1:] or (texts[j + 1] if j + 1 < len(texts) else "")
                        if c == a and val == b:
                            is_rec = True
                    if k + 1 >= len(t):
                        j += 1
                    break
                k += 1
            j += 1
        if not is_rec:
            return False, [], 0
        if prof.get("pattern_positional") and not have_pat and pos:
            pos = pos[1:]
        if not pos:
            if prof.get("stdin_when_pathless") and piped:
                return False, [], 0
            pos = ["."]
        return True, pos, 0

    def has_prune(self, name, prof, argv, d):
        if prof.get("prune_style") == "find":
            return "-prune" in argv and d in argv
        tpl = [x.replace("{dir}", d) for x in prof.get("prune", [])]
        if not tpl:
            return True  # nothing to prune with (ls -R): not counted as missing
        if len(tpl) == 1:
            return tpl[0] in argv
        return any(argv[i:i + len(tpl)] == tpl for i in range(len(argv)))

    def build_edit(self, name, prof, words, c, first, roots_end, missing_prunes, args_texts):
        """Edits that put the canonical wrappers (+ missing prunes) on one walk command."""
        cmdw = words[c]
        f = words[first] if first is not None else cmdw
        edits = []
        if prof.get("prune_style") == "find":
            repl = "%s %s" % (self.k.canon, self.rawtext(cmdw))
            edits.append((f.start, cmdw.end, repl))
            if missing_prunes:
                expr = " -o ".join("-name %s" % shlex.quote(d) for d in self.k.prunes)
                anchor = roots_end if roots_end is not None else cmdw.end
                has_or = bool(set(args_texts) & {"-o", "-or"})
                acts = bool(set(args_texts) & FIND_ACTIONS)
                edits.append((anchor, anchor, " \\( %s \\) -prune -o%s" % (expr, " \\(" if has_or else "")))
                tail = ""
                if has_or:
                    tail += " \\)"
                if not acts:
                    tail += " -print"
                if tail and words:
                    edits.append((words[-1].end, words[-1].end, tail))
        else:
            flags = []
            for d in missing_prunes:
                flags += [x.replace("{dir}", d) for x in prof.get("prune", [])]
            tail = (" " + " ".join(shlex.quote(x) for x in flags)) if flags else ""
            edits.append((f.start, cmdw.end, "%s %s%s" % (self.k.canon, self.rawtext(cmdw), tail)))
        return edits

    def rawtext(self, w):
        return w.text if re.fullmatch(r"[\w./+-]+", w.text) else shlex.quote(w.text)

    # ---- recursion helper
    def sub(self, text, span, requote, mode, cwd, wrap, base):
        """Analyze `text` located at absolute span in the enclosing string; returns findings whose
        edits are rewritten into ONE edit on the enclosing string."""
        found = self.script(text, mode, cwd, wrap, base=0)
        if not found:
            return []
        allspans = [e for f in found for e in f.edits]
        ok = all(f.rewritable for f in found)
        new = apply_edits(text, allspans, 0) if allspans and ok else None
        edit = []
        if new is not None and new != text:
            if requote:
                if "$" in text or "`" in text:
                    ok = False
                else:
                    edit = [(span[0], span[1], shlex.quote(new))]
            else:
                edit = [(span[0], span[1], new)]
        for f in found:
            f.edits = []
            f.rewritable = ok
        found[0].edits = edit
        return found

    # ---- the script walker
    def script(self, text, mode, cwd, wrap, base=0):
        findings = []
        cwd = cwd
        for cmd in scan(text, base):
            ws = cmd.words
            if not ws:
                continue
            piped = cmd.sep == "|"
            c, w2, first = self.eat_wrappers(ws, 0, wrap)
            if c >= len(ws):
                continue
            name = os.path.basename(ws[c].text)
            args = ws[c + 1:]
            for w in ws:  # $( ... ) inside double quotes
                for off, inner in w.nested:
                    findings += self.sub(inner, (off, off + len(inner)), False, mode, cwd, w2, 0)
            if name == "cd" and args:
                nd = self.norm(args[0].text, cwd)
                if nd:
                    cwd = nd
            elif name == "ssh":
                findings += self.ssh(cmd, ws, c, base, mode)
            elif name in SHELLS:
                done = False
                for j, a in enumerate(args):
                    if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", a.text) and j + 1 < len(args):
                        s = args[j + 1]
                        findings += self.sub(s.text, (s.start, s.end), True, mode, cwd, w2, 0)
                        done = True
                        break
                if not done and cmd.heredoc:
                    a, b, body = cmd.heredoc
                    findings += self.sub(body, (a, b), False, mode, cwd, w2, 0)
            elif name in self.k.cmds and (mode == "remote" or self.host in self.k.local_guarded):
                f = self.walk(name, self.k.cmds[name], ws, c, first, w2, args, piped, mode, cwd)
                if f:
                    findings.append(f)
        return findings

    def walk(self, name, prof, ws, c, first, wrap, args, piped, mode, cwd):
        is_walk, roots, lead = self.extract(prof, args, piped)
        if not is_walk:
            return None
        nroots = [(r, self.norm(r, cwd)) for r in roots]
        hit = [n for _, n in nroots if n and self.k.guarded(n)]
        if not hit:
            return None
        missing = []
        if not wrap.io:
            missing.append("ionice -c%d" % self.k.io_class)
        if not wrap.nice:
            missing.append("nice -n%d" % self.k.nice_level)
        if wrap.to is None:
            missing.append("timeout <= %d" % self.k.timeout_max)
        texts = [w.text for w in ws[c:]]
        mp = [d for d in self.k.prunes if not self.has_prune(name, prof, texts, d)]
        edits, rewritable = [], True
        if missing:
            roots_end = None
            if prof.get("prune_style") == "find":
                rw = args[:lead]
                roots_end = rw[-1].end if rw else None
            edits = self.build_edit(name, prof, ws, c, first, roots_end, mp, [a.text for a in args])
        return Finding(name, roots, hit, missing, mp, edits, rewritable)

    def ssh(self, cmd, ws, c, base, mode):
        args = ws[c + 1:]
        j, host = 0, None
        while j < len(args):
            t = args[j].text
            if t == "--":
                j += 1
                if j < len(args):
                    host, j = args[j], j + 1
                break
            if t.startswith("-") and len(t) > 1:
                k = 1
                while k < len(t):
                    if t[k] in SSH_ARG_OPTS:
                        if k + 1 >= len(t):
                            j += 1
                        break
                    k += 1
                j += 1
            else:
                host, j = args[j], j + 1
                break
        if host is None:
            return []
        ht = host.text.lower()
        if "$" in ht or "`" in ht:
            guarded = any(t in self.full.lower() for t in self.k.ssh_targets)
        else:
            ht = ht.split("@")[-1].strip("[]").split(".")[0]
            guarded = ht in self.k.ssh_targets
        if not guarded:
            return []
        rest = args[j:]
        if rest:
            remote_words = " ".join(w.text for w in rest).split()
            first_is_shell = bool(remote_words) and os.path.basename(remote_words[0]) in SHELLS
            has_c = any(re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", a) for a in remote_words[1:])
            if first_is_shell and not has_c and cmd.heredoc:
                a, b, body = cmd.heredoc
                return self.sub(body, (a, b), False, "remote", HOME, Wrap(), 0)
            remote = " ".join(w.text for w in rest)
            return self.sub(remote, (rest[0].start, rest[-1].end), True, "remote", HOME, Wrap(), 0)
        if cmd.heredoc:
            a, b, body = cmd.heredoc
            return self.sub(body, (a, b), False, "remote", HOME, Wrap(), 0)
        return []


# --------------------------------------------------------------------------- hook decision
def this_host():
    return (os.environ.get("WALK_GUARD_HOST") or socket.gethostname().split(".")[0]).lower()


def decide(k, command, cwd, host=None):
    """-> (exit_code, stderr_text, stdout_text)"""
    host = host or this_host()
    if host in k.never:
        return 0, "", ""
    g = Guard(k, host, command, cwd)
    found = g.script(command, "local", cwd or HOME, Wrap(), 0)
    refuse = [f for f in found if f.missing]
    warn = [f for f in found if not f.missing]
    if refuse:
        msg = ["walk-hook: REFUSED. An unbounded walk of a guarded root on a build host holds the IO queue "
               "(10-22: three orphan greps/finds, 12 GB read, IO full avg60 26-43, blocked run 1037)."]
        for f in refuse:
            msg.append("  %s over %s: missing %s%s" % (
                f.cmd, ", ".join(f.hit), ", ".join(f.missing),
                ("; no prune of " + ", ".join(f.missing_prunes)) if f.missing_prunes else ""))
        msg.append("Required on the remote side: ionice -c%d AND nice -n%d AND timeout <= %d. "
                   "Prune dirs: %s." % (k.io_class, k.nice_level, k.timeout_max, ", ".join(k.prunes)))
        edits = [e for f in found if f.missing for e in f.edits]
        if refuse and all(f.rewritable for f in refuse) and edits:
            new = apply_edits(command, edits, 0)
            msg += ["Re-run exactly this:", REFUSE_BEGIN, new, REFUSE_END]
        else:
            msg += ["Template (adapt to your command): " + k.template()]
        return 2, "\n".join(msg) + "\n", ""
    if warn:
        w = "walk-hook WARN: %s walk of %s runs under the required wrappers; it still reads a lot. " \
            "Keep it bounded; the watcher bells on any walk older than 10 min." % (
                ", ".join(sorted({f.cmd for f in warn})), ", ".join(sorted({h for f in warn for h in f.hit})))
        miss = sorted({d for f in warn for d in f.missing_prunes})
        if miss:
            w += " Missing prune of: %s." % ", ".join(miss)
        out = json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": w}})
        return 0, w + "\n", out + "\n"
    return 0, "", ""


def hook_main():
    if os.environ.get("WALK_GUARD_SELFTEST") == "1" and os.environ.get("WALK_GUARD_FAULT") == "1":
        raise RuntimeError("injected fault")
    raw = sys.stdin.read()
    d = json.loads(raw) if raw.strip() else {}
    if d.get("tool_name", "Bash") != "Bash":
        return 0
    command = (d.get("tool_input") or {}).get("command") or ""
    if not command:
        return 0
    k = Contract(load_contract())
    code, err, out = decide(k, command, d.get("cwd") or HOME)
    if out:
        sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    return code


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "hook"
    try:
        if mode == "hook":
            sys.exit(hook_main())
        elif mode == "pgrep-pattern":
            print(Contract(load_contract()).pgrep_pattern())
        elif mode == "template":
            print(Contract(load_contract()).template())
        elif mode == "selftest":
            import walk_guard_selftest
            sys.exit(walk_guard_selftest.main(sys.argv[2:]))
        else:
            sys.stderr.write("usage: walk_guard.py hook|selftest|pgrep-pattern|template\n")
            sys.exit(64)
    except SystemExit:
        raise
    except BaseException as e:  # noqa: BLE001 - any failure is an internal error, see docstring
        sys.stderr.write("walk_guard.py: %s: %s\n" % (type(e).__name__, e))
        sys.exit(3)
