#!/usr/bin/env bash
# verifier-kill-guard.sh: PreToolUse(Bash) hook for aide-verifier units (registered only through the unit's own settings.json, so it never touches other sessions).
# Denies (exit 2) a Bash command that kills by pattern, judged at COMMAND POSITION only (line start, or after ; && || | & $( ` and the prefixes xargs, timeout N, env, sudo, nohup):
#   pkill, killall, xargs kill, and `kill` with any argument that is not a numeric PID, a signal flag, `--`, a negative process group, a plain $var, or $(cat <file>).
# ssh/scp/sftp/rsync at command position are denied too (AIDE_VERIFIER_SUITE_HOST runs go through hpld-fetch-verify.sh, the one allowed invocation).
# `bash -c '<cmd>'` is checked recursively. grep/echo/sed/git text that merely contains "kill", and `systemctl --user kill|stop`, are allowed.
# Why: a verifier ran `pkill -f 'wm-verify-run'` on 10-24 11:05 PM and killed every seat's suite on carbon. Allowed: `kill 12345`, `kill -9 $pid`.
set -u
exec python3 -I -c '
import json, re, shlex, sys
try:
    cmd = (json.load(sys.stdin).get("tool_input") or {}).get("command") or ""
except Exception:
    cmd = ""
def deny(why):
    sys.stderr.write("verifier-kill-guard: refused (%s). Kill only PIDs you started, or stop your own unit with: systemctl --user stop <your unit>.\n" % why)
    sys.exit(2)
def blank(t):
    # blank (to _) single-quoted text and double-quoted text that holds no substitution, keeping a lone \"$var\" (length preserved)
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        if c in "\x27\"":
            j = t.find(c, i + 1)
            if j < 0:
                out.append(t[i:]); break
            body = t[i + 1:j]
            if re.match(r"^\$[A-Za-z_{!?][A-Za-z0-9_}]*$", body):
                out.append(t[i:j + 1])
            elif c == "\x27" or ("$(" not in body and "`" not in body):
                out.append(c + "_" * len(body) + c)
            else:
                out.append(t[i:j + 1])
            i = j + 1
        else:
            out.append(c); i += 1
    return "".join(out)
SEP = re.compile(r"(\$\(|`|;|&&|\|\||\||&|\n|\()")
CATPID = re.compile(r"\$\(cat [^\s()$`;&|]+\)")
SIG = re.compile(r"^-([0-9]+|[A-Z][A-Z0-9]*|l)$")
def strip_prefix(toks):
    xargs = False
    while toks:
        t = toks[0]
        base = t.rsplit("/", 1)[-1]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            toks = toks[1:]
        elif base in ("env", "sudo", "nohup", "nice", "command", "exec", "time"):
            toks = toks[1:]
            while toks and (toks[0].startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0])):
                toks = toks[1:]
        elif base == "timeout":
            toks = toks[1:]
            while toks and toks[0].startswith("-"):
                toks = toks[1:]
            if toks:
                toks = toks[1:]
        elif base == "xargs":
            xargs = True
            toks = toks[1:]
            while toks and toks[0].startswith("-"):
                toks = toks[1:]
        else:
            break
    return toks, xargs
def check(text, depth=0):
    if depth > 3:
        return
    work = CATPID.sub("0", blank(text))
    parts = SEP.split(work)
    pos = 0
    prev_kill = False
    for k, seg in enumerate(parts):
        if k % 2 == 1:
            if seg in ("$(", "`") and prev_kill:
                deny("kill with a command-substitution argument")
            pos += len(seg); continue
        orig = text[pos:pos + len(seg)] if len(CATPID.findall(text)) == 0 else seg
        pos += len(seg)
        toks = seg.split()
        toks, xargs = strip_prefix(toks)
        prev_kill = False
        if not toks:
            continue
        base = toks[0].rsplit("/", 1)[-1]
        if base in ("pkill", "killall"):
            deny("pkill/killall")
        if base in ("ssh", "scp", "sftp", "rsync"):
            deny("ssh/scp: a verifier never opens a remote shell itself; the only remote step is ~/.local/bin/hpld-fetch-verify.sh")
        if base in ("bash", "sh", "dash", "zsh") and "-c" in toks:
            try:
                real = shlex.split(orig)
                i = real.index("-c")
                check(real[i + 1], depth + 1)
            except Exception:
                pass
            continue
        if base == "kill":
            prev_kill = True
            if xargs:
                deny("xargs kill")
            for a in toks[1:]:
                a = a.strip("\"")
                if re.match(r"^[0-9]+$", a) or a == "--" or SIG.match(a) or re.match(r"^\$[A-Za-z_{!?][A-Za-z0-9_}]*$", a) or a in ("-s", "-n") or re.match(r"^[A-Z][A-Z0-9]*$", a):
                    continue
                deny("kill with pattern argument %r" % a)
check(cmd)
'
