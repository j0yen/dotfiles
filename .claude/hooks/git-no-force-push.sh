#!/usr/bin/env bash
# git-no-force-push.sh -- PreToolUse hook (Bash): force push and history rewrite are not done in this fleet (Joe 10-29 "why force push?", A51).
# Denies: `git push` with --force, -f (also bundled short flags like -fu), --force-with-lease[=..], --force-if-includes, or a +refspec;
#   `git filter-branch`; `git filter-repo`; `git rebase -i` / `--interactive`. Everything else exits 0 silently.
# Parsing: python3 -I shlex, segments split on ; && || | &, `git [-C dir] [-c k=v] <sub>`. Fails OPEN on a missing jq/python3 or a non-Bash payload.
set -uo pipefail
JQ=$(command -v jq) || exit 0
PY=$(command -v python3) || exit 0
INPUT=$(cat) || exit 0
[ "$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = Bash ] || exit 0
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
verdict=$(printf '%s' "$CMD" | "$PY" -I -c '
import re, shlex, sys
cmd = sys.stdin.read()
if not re.search(r"\bgit\b", cmd):
    print("pass"); sys.exit()
SEP = set(";&|()")
GIT_VAL = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
def segments(text):
    lx = shlex.shlex(text.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lx.whitespace_split = True; lx.commenters = ""
    seg = []
    for t in lx:
        if set(t) <= SEP:
            if seg: yield seg
            seg = []
        else:
            seg.append(t)
    if seg: yield seg
try:
    segs = list(segments(cmd))
except ValueError:
    segs = [cmd.split()]
for seg in segs:
    if "git" not in seg: continue
    i = seg.index("git") + 1
    while i < len(seg) and seg[i].startswith("-"):
        i += 2 if seg[i] in GIT_VAL else 1
    if i >= len(seg): continue
    sub, args = seg[i], seg[i + 1:]
    if sub in ("filter-branch", "filter-repo"):
        print("deny"); sys.exit()
    if sub == "rebase" and any(a in ("-i", "--interactive") or re.match(r"-[a-zA-Z]*i[a-zA-Z]*$", a) for a in args):
        print("deny"); sys.exit()
    if sub == "push":
        for a in args:
            if a in ("-f", "--force", "--force-if-includes") or a.startswith("--force-with-lease") or re.match(r"-[a-zA-Z]*f[a-zA-Z]*$", a) or a.startswith("+"):
                print("deny"); sys.exit()
print("pass")
' 2>/dev/null) || exit 0
if [ "$verdict" = deny ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"git-no-force-push: force push and history rewrite are not done in this fleet (Joe 10-29)"}}'
fi
exit 0
