#!/usr/bin/env bash
# sudo-stdin-guard.sh -- PreToolUse hook (Bash). Incident 10-29 2:25 PM: a stdin-sudo wrapper with cached creds never read stdin, so the wrapped `tee` read the
# pass file as DATA and appended the password to /etc/fstab. Rules (exit 2 + one reason line; no bypass env var, no override file):
#  1. a sudo that reads its password from stdin (-S, --stdin, S inside a short cluster) may only VALIDATE: its sole action is -v/-k/-K (-p <arg> allowed) with no command, or its command is exactly `true`.
#  2. the literal wm-sudo/pass may appear ONLY as the `<` redirect of such a validate-only stdin-sudo. `cat <path> |`, `< <path>` on any other command, or <path> as an argument is denied.
# The whole command text is scanned by a quote-aware scanner (a `"` inside '...' is literal, \" escapes inside "...", backslash-newline continues); every quoted string is scanned again
# (ssh h '...', bash -c "..."). An invocation ends at ; && || | & ( ) a backtick, a newline, or the end of its quote. Ambiguous shape = DENY.
# Accepted gaps: variable indirection (s=sudo; $s -S ...), globbed pass paths (wm-sudo/pa*), heredoc bodies. Fails OPEN on a missing python3 or an unparseable payload.
set -uo pipefail
PY=$(command -v python3) || exit 0
PROG=$(cat <<'PYEOF'
import json, os, re, sys
PASS, OK, SEP = "wm-sudo/pass", {"v", "k", "K"}, set(";&|\n()`")
RED = re.compile(r"^(\d*|&)(<<<|<<-?|<>|>>|>\||<&|>&|<|>)(.*)$", re.S)
LONGARG = {"prompt", "user", "group", "chdir", "host", "role", "type", "close-from", "other-user", "chroot", "command-timeout"}
LONGACT = {"validate": "v", "reset-timestamp": "k", "remove-timestamp": "K", "shell": "x", "login": "x", "edit": "x", "list": "x"}
def tok(t):
    segs, subs, w, inw, q, i, n = [[]], [], "", False, False, 0, len(t)
    def end():
        nonlocal w, inw, q
        if inw: segs[-1].append((w, q))
        w, inw, q = "", False, False
    while i < n:
        c = t[i]
        if c == "\\":
            if t[i+1:i+2] != "\n": w, inw = w + t[i+1:i+2], True
            i += 2; continue
        if c in "'\"":
            j, b = i + 1, ""
            while j < n and t[j] != c:
                if c == '"' and t[j] == "\\" and t[j+1:j+2] == "\n": j += 2; continue
                if c == '"' and t[j] == "\\" and t[j+1:j+2] in ('"', "\\", "$", "`"): j += 1
                b += t[j]; j += 1
            w, inw, q = w + b, True, True
            subs.append(b); i = j + 1; continue
        if c in " \t\r": end(); i += 1; continue
        if c in SEP and not (c == "&" and ((i and t[i-1] in "<>") or t[i+1:i+2] == ">")):
            end()
            if segs[-1]: segs.append([])
            i += 1; continue
        w, inw = w + c, True; i += 1
    end()
    return segs, subs
def scan(text):
    segs, subs = tok(text); bad = False
    for seg in segs:
        words, reds, k = [], [], 0
        while k < len(seg):
            s, q = seg[k]; m = None if q else RED.match(s)
            if not m: words.append((s, q))
            else:
                tgt, tq = m.group(3), False
                if not tgt and k + 1 < len(seg): k += 1; tgt, tq = seg[k]
                reds.append((m.group(2), tgt, tq))
            k += 1
        validate_only = False
        for idx, (s, _) in enumerate(words):
            if os.path.basename(s) != "sudo": continue
            stdin, acts, j = False, set(), idx + 1
            while j < len(words) and words[j][0].startswith("-") and words[j][0] != "-":
                a = words[j][0]; j += 1
                if a == "--": break
                if a.startswith("--"):
                    nm, eq, _ = a[2:].partition("=")
                    stdin = stdin or nm == "stdin"
                    if nm in LONGACT: acts.add(LONGACT[nm])
                    if nm in LONGARG and not eq: j += 1
                    continue
                for p, c in enumerate(a[1:], 1):
                    if c == "S": stdin = True
                    elif c in "vkK": acts.add(c)
                    elif c in "isel": acts.add("x")
                    elif c in "pugCDhRTUrt":
                        if p == len(a) - 1: j += 1
                        break
            cmd = [w for w, _ in words[j:]]
            safe = acts <= OK and ((bool(acts) and not cmd) or cmd == ["true"])  # SAFE-LINE
            if stdin and not safe: bad = True
            if stdin and safe and acts and not cmd: validate_only = True
        pw_ok = validate_only
        for w, q in words:
            if PASS in w and not q: bad = True  # RULE2-LINE
        for op, t, tq in reds:
            if PASS in t and not tq and not (op == "<" and pw_ok): bad = True  # RULE2-LINE
    for sub in subs:  # RECURSE-LINE
        bad = scan(sub) or bad
    return bad
try:
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command")
except Exception:
    sys.exit(0)
if isinstance(cmd, str) and scan(cmd):
    sys.stderr.write('sudo-stdin-guard: sudo -S/--stdin may only validate. Use: sudo -S -p "" -v < ~/.config/wm-sudo/pass && sudo -n <cmd> (never pipe data into a sudo -S < passfile wrapper)\n')
    sys.exit(2)
PYEOF
)
exec "$PY" -I -c "$PROG"
