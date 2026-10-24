#!/usr/bin/env bash
# land-push-gate.sh -- PreToolUse hook (Bash): an rb-marked process may not `git push` to a wm-build run/land branch except through rb-land-push.sh.
# Why (ctl d-20261024-091807-controller-6985, rb row d-20261024-121515-rb-7178): the wrapper alone is opt-in; a bare `git push origin HEAD:refs/heads/wm-build/<slug>`
# is the push-before-confirm. Fable review rlp1 edit 1.
# Scope: acts ONLY when the process is rb-marked: WM_SEAT=rb (the seat, seat-tick.sh) or WM_SEAT=rb-coder / RB_CODER_ID set (rb-run-coder.sh). Every other session passes untouched.
# Run-branch naming, quoted from wm-build src/daemon/worktree.rs:71 (and :276, :350, tick.rs:1330, ci_dispatch.rs:145): `let branch = format!("wm-build/{slug}");`
# (train branches `wm-build/train/{id}` at land/train.rs:1512 and canary `wm-build/{slug}-{stamp}` at canary.rs:685 share the prefix). The gate matches destination branch ^wm-build/.
# Rule: a command whose segment is `git [-C dir] push ...` with a destination branch under wm-build/ is blocked (exit 2, one reason line naming rb-land-push.sh).
#   A segment whose first word is rb-land-push.sh (or its full path) passes. A destination the parser cannot resolve (bare `git push`, `git push origin`, `HEAD`, `--all`, `--mirror`,
#   `$VAR`/glob refspec, unbalanced quotes) is blocked for an rb-marked process: "unparsed push target". Hand branches (ci/split-contracts-core, rb/...) pass.
# Indirection (rlp1b): for rb, any command with the word `push` is blocked ("indirect") when it contains `wm-build/` or any of `$`, backtick, eval, xargs, sh -c / bash -c, unless it is ONE
#   simple command whose first word is rb-land-push.sh (nothing chaining after it). This closes eval, `bash -c`, xargs, `B=wm-; ... ${B}build/x` and `rb-land-push.sh ...; git push ...`.
#   Cost of coarse: an rb command that mentions `push` together with `$VAR`/`$(...)` is refused even for a hand branch. Out of scope (known gaps): main/master pushes, git aliases (`git p`).
# Parsing is by python3 -I shlex (segments split on ; && || | &, `bash -c '...'` unwrapped). Fails OPEN on a missing jq/python3 or a non-Bash payload; fails CLOSED on a push it cannot parse.
set -uo pipefail
case "${WM_SEAT:-}" in rb|rb-coder) ;; *) [ -n "${RB_CODER_ID:-}" ] || exit 0 ;; esac
JQ=$(command -v jq) || exit 0
PY=$(command -v python3) || exit 0
INPUT=$(cat) || exit 0
[ "$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = Bash ] || exit 0
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
verdict=$(printf '%s' "$CMD" | "$PY" -I -c '
import re, shlex, sys
cmd = sys.stdin.read()
# Indirection rule (rlp1b, Fable edits 1+2). Coarse on purpose, on top of the parser: eval, sh -c, xargs and $VAR splices cannot be parsed.
# Allowlist = ONE simple command whose first word is rb-land-push.sh (or its full path): nothing after it may chain (; && || | newline, $( , backtick, lone &).
words = cmd.strip().split(None, 1)
rest = words[1] if len(words) > 1 else ""
allow = bool(words) and words[0].rsplit("/", 1)[-1] == "rb-land-push.sh" and not re.search(r"[;|`\n]|&&|\$\(|(?<![>&])&(?![>&])", rest)
if allow:
    print("pass"); sys.exit()
if re.search(r"\bpush\b", cmd):
    if "wm-build/" in cmd or re.search(r"[$`]|\beval\b|\bxargs\b|\b(?:ba|z|da)?sh\s+(?:-\S+\s+)*-\w*c\b", cmd):
        print("indirect"); sys.exit()
if not (re.search(r"\bgit\b", cmd) and re.search(r"\bpush\b", cmd)):
    print("pass"); sys.exit()
PUSH_VAL = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}
GIT_VAL = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
SEP = {";", "&&", "||", "|", "&", "|&", "(", ")"}
def segments(text):
    lx = shlex.shlex(text.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lx.whitespace_split = True; lx.commenters = ""
    seg = []
    for t in lx:
        if t in SEP or set(t) <= set(";&|()"):
            if seg: yield seg
            seg = []
        else:
            seg.append(t)
    if seg: yield seg
def check(text, depth=0):
    """-> ("pass"|"block"|"unparsed", dest)"""
    try:
        segs = list(segments(text))
    except ValueError:
        return ("unparsed", "") if (re.search(r"\bgit\b", text) and re.search(r"\bpush\b", text)) else ("pass", "")
    worst = ("pass", "")
    for seg in segs:
        i = 0
        while i < len(seg) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[i]): i += 1
        while i < len(seg) and seg[i] in ("sudo", "env", "command", "exec", "nohup", "time", "builtin"):
            i += 1
            while i < len(seg) and (seg[i].startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[i])): i += 1
        if i >= len(seg): continue
        w = seg[i].rsplit("/", 1)[-1]
        if w == "rb-land-push.sh": continue
        if w in ("bash", "sh", "zsh", "dash") and depth < 4:
            for j in range(i + 1, len(seg) - 1):
                if re.match(r"^-[A-Za-z]*c$", seg[j]):
                    r = check(seg[j + 1], depth + 1)
                    if r[0] != "pass" and worst[0] != "block": worst = r
                    break
            continue
        if w != "git": continue
        j = i + 1
        while j < len(seg) and seg[j].startswith("-"):
            j += 2 if seg[j] in GIT_VAL else 1
        if j >= len(seg) or seg[j] != "push": continue
        args = seg[j + 1:]; pos = []; k = 0; flags = set()
        while k < len(args):
            a = args[k]
            if a == "--": pos += args[k + 1:]; break
            if a.startswith("-"):
                flags.add(a.split("=")[0])
                if a in PUSH_VAL: k += 1
            else: pos.append(a)
            k += 1
        if flags & {"--all", "--mirror"}: return ("unparsed", "")
        if len(pos) < 2:
            if flags & {"--tags"} and len(pos) <= 1: continue
            if worst[0] == "pass": worst = ("unparsed", "")
            continue
        for ref in pos[1:]:
            if ref == "tag": continue
            dest = ref.lstrip("+").rsplit(":", 1)[-1] if ":" in ref else ref.lstrip("+")
            if dest == "" or re.search(r"[$`*?\[{]", dest) or dest in ("HEAD", "@"):
                if worst[0] == "pass": worst = ("unparsed", "")
                continue
            d = dest[len("refs/heads/"):] if dest.startswith("refs/heads/") else dest
            if dest.startswith("refs/") and not dest.startswith("refs/heads/"): continue
            if d.startswith("wm-build/"): return ("block", d)
    return worst
v, d = check(cmd)
print(v + (" " + d if d else ""))
' 2>/dev/null) || verdict="unparsed"
[ -n "$verdict" ] || verdict="unparsed"
case "$verdict" in
  pass) exit 0 ;;
  indirect) echo "land-push-gate: a command with 'push' that names wm-build/ or uses \$VAR, backticks, eval, xargs or sh -c is refused for rb; the only allowed form is ONE simple command: rb-land-push.sh --confirm <ctl CONFIRM d-id> --repo <dir> --branch <branch> (no ; && || | newline \$( after it)" >&2; exit 2 ;;
  block*) echo "land-push-gate: a bare git push to wm-build run branch '${verdict#block }' is refused for rb; use rb-land-push.sh --confirm <ctl CONFIRM d-id> --repo <dir> --branch ${verdict#block }" >&2; exit 2 ;;
  *) echo "land-push-gate: unparsed push target; a git push whose destination branch cannot be read is refused for rb (name it: git push origin HEAD:refs/heads/<branch>, or use rb-land-push.sh --confirm <d-id> --repo <dir> --branch <branch> for a wm-build/* branch)" >&2; exit 2 ;;
esac
