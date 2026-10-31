#!/usr/bin/env python3
"""Classifier for cargo-block-carbon.sh: reads the PreToolUse hook JSON on stdin,
prints 'deny' when cargo/rustc/rustup sits in COMMAND POSITION in the local part
of the Bash command, else 'allow'. Quoted strings, heredoc bodies and everything
after an `ssh` word on a line are ignored; --version/--help are allowed."""
import socket
import sys, json, re

# hostname guard (tracked in dotfiles; carbon-only hook): silent no-op on every other node
if socket.gethostname().split(".")[0] != "carbon":
    sys.exit(0)

try:
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "") or ""
except Exception:
    cmd = ""
if not cmd:
    print("allow"); sys.exit(0)

# 1. drop heredoc bodies
lines = cmd.split("\n"); out = []; i = 0
while i < len(lines):
    m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", lines[i])
    out.append(lines[i]); i += 1
    if m:
        term = m.group(1)
        while i < len(lines) and lines[i].strip() != term:
            i += 1
        i += 1
cmd = "\n".join(out)
# 2. drop quoted strings
cmd = re.sub(r"'[^']*'", "''", cmd)
cmd = re.sub(r'"(?:[^"\\]|\\.)*"', '""', cmd)
# 3. drop everything from an ssh word to the end of that line
cmd = re.sub(r"(^|[;&|(\s])ssh\b[^\n]*", r"\1", cmd)
# 4. command-position match
tok = r"(?:~?/?[\w./-]*/)?(?:cargo|rustc|rustup)\b"
pre = r"(?:(?:env\s+(?:\w+=\S*\s+)*|nice\s+(?:-n\s*\d+\s+)?|timeout\s+\S+\s+|time\s+|exec\s+|sudo\s+)*)"
pat = re.compile(r"(?:^|[;&|(`]\s*|\$\(\s*|\n\s*)" + pre + "(" + tok + r")(\s+[^\n;&|]*)?", re.M)
for m in pat.finditer(cmd):
    args = m.group(2) or ""
    if re.match(r"\s+(--version|-V|--help|-h)\b", args):
        continue
    print("deny"); sys.exit(0)
print("allow")
