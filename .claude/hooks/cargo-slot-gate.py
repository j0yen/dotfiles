#!/usr/bin/env python3
"""Classifier for cargo-slot-gate.sh: reads the PreToolUse hook JSON on stdin and
prints 'deny <host> <subcommand>' when an ssh to a build host (redbaron, ryzen7)
carries a compiling cargo subcommand with no memory gate on the same ssh segment,
else 'allow'.

A segment = the text from the `ssh` word to the end of its line, plus the body of a
heredoc opened on that line (`ssh host bash -s <<EOF`). Gates accepted on the
segment: cargo-slot (cargo-slot.sh, r7-cargo-slot.sh) or `cargo-jobs acquire`.
Only compiling/running subcommands count, so reads like `grep cargo`, `ls ~/.cargo`
or `cargo --version` pass. Cargo inside a script file run over ssh is NOT seen
(backstop only; the daemon gate and hand-sandbox are the real contract)."""
import sys, json, re

HOSTS = r"(redbaron|ryzen7)"
SUBS = (r"build|b|test|t|check|c|run|r|clippy|nextest|bench|install|doc|xtask|"
        r"rustc|llvm-cov|mutants|miri|fix")
GATE = re.compile(r"cargo-slot|cargo-jobs\s+acquire")
CARGO = re.compile(r"(?:^|[\s;&|(`'\"/=])cargo\s+(?:\+\S+\s+)?(?:-\S+\s+)*(" + SUBS + r")\b")
SSH = re.compile(r"(?:^|[\s;&|(`$])ssh\b(?:\s+-\S+(?:\s+(?!" + HOSTS + r"\b)[^\s-]\S*)?)*\s+(?:\S+@)?" + HOSTS + r"\b")

def classify(cmd: str) -> str:
    lines = cmd.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        m = SSH.search(line)
        if not m:
            i += 1
            continue
        host = m.group(2)
        seg = line[m.start():]
        hd = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", seg)
        j = i + 1
        if hd:
            term = hd.group(1)
            body = []
            while j < len(lines) and lines[j].strip() != term:
                body.append(lines[j]); j += 1
            seg += "\n" + "\n".join(body)
            j += 1
        c = CARGO.search(seg)
        if c and not GATE.search(seg):
            return f"deny {host} {c.group(1)}"
        i = j
    return "allow"

if __name__ == "__main__":
    try:
        cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "") or ""
    except Exception:
        cmd = ""
    print(classify(cmd) if cmd else "allow")
