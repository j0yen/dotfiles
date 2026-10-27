#!/usr/bin/env bash
# aide-claim-gate.sh -- PreToolUse hook (Bash): two aide lanes must not act on the same PR (aide-lanes 10-27, mechanism 6; decisions/2026-10-27-aide-lanes-wwhtbt.md).
# Scope: acts ONLY when WM_SEAT=aide; every other process exits 0 with no output. Inert until a claim file exists: ${FLEET_DASH_DIR:-~/.cache/fleet-dash}/claims/ is
# created by the first `aide-claim.sh take` or the first claim-on-act below.
# Rule: for every PR object the command acts on, read claims/<repo>#<pr> (lines lane= sid= expires=<epoch>):
#   - held by ANOTHER lane and unexpired -> deny, exit 2: `aide-claim-gate: <repo>#<pr> claimed by lane <lane> (sid ..., expires <time>); aide-claim.sh show <repo>#<pr>; ... release <repo>#<pr> --force` (steal, logged)
#   - no live claim -> TAKE it for the own lane (claim-on-act, ttl 2 h, same format as aide-claim.sh take) and exit 0
#   - own lane's claim -> exit 0 (ttl not extended)
#   own lane = ${WM_AIDE_LANE:-main}. repo = the basename of owner/repo (claims are keyed `<repo>#<pr>`).
# Objects recognised (segments split on ; && || | & newline; `bash -c '...'` is not unwrapped):
#   gh pr merge|close|edit|ready|review <N|url> [--repo|-R O/R]   (no --repo: basename of `git remote get-url origin` in the payload cwd)
#   gh api ... repos/O/R/pulls/N/(merge|reviews)                  (any method)
#   aide-verifier.sh launch|finish|watch ... --pr N --repo O/R
#   wm-decide merge-gate|record|promote ... --pr N --repo O/R
#   rb-merge.sh <verdict-id> <pr> <O/R>
#   rb-land-push.sh --repo <git dir> --branch <b>   (no PR number: the object is `<basename of git dir>#<branch with / as _>`)
#   (approve.sh is not in dotfiles at 5451819, so it is not parsed.)
# BLIND PATHS (not parsed, the claim does not cover them): `git push` / `git merge` of a PR branch, SendMessage/tmux asks to rb/r7, MCP writes (they carry the lane only
#   in their source stamp, mechanism 10), and any wrapper that hides the command (eval, bash -c, xargs, $VAR splices).
# ADVISORY: task objects `task:<slug>` are claim-by-convention only, never parsed here: run `aide-claim.sh take task:<slug>` before a hand task.
# Fails OPEN on a missing jq/python3 or a non-Bash payload.
set -uo pipefail
[ "${WM_SEAT:-}" = aide ] || exit 0
JQ=$(command -v jq) || exit 0
PY=$(command -v python3) || exit 0
INPUT=$(cat) || exit 0
[ "$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null)" = Bash ] || exit 0
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null); [ -n "$CWD" ] || CWD="$PWD"
SID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null); [ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:--}"
objs=$(printf '%s' "$CMD" | CWD="$CWD" "$PY" -I -c '
import os, re, shlex, subprocess, sys
cmd = sys.stdin.read(); cwd = os.environ.get("CWD") or "."
SEP = set(";&|()")
def segments(text):
    lx = shlex.shlex(text.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lx.whitespace_split = True; lx.commenters = ""
    seg = []
    for t in lx:
        if set(t) <= SEP:
            if seg: yield seg
            seg = []
        else: seg.append(t)
    if seg: yield seg
def base(r): return r.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
def origin_repo():
    try:
        u = subprocess.run(["git", "-C", cwd, "remote", "get-url", "origin"], capture_output=True, text=True, timeout=3).stdout.strip()
        return base(u) if u else ""
    except Exception: return ""
def flag(args, *names):
    for i, a in enumerate(args):
        for n in names:
            if a == n and i + 1 < len(args): return args[i + 1]
            if a.startswith(n + "=") and n.startswith("--"): return a.split("=", 1)[1]
    return ""
out = []
def add(repo, ident):
    if re.fullmatch(r"[A-Za-z0-9._-]+", repo or "") and re.fullmatch(r"[A-Za-z0-9._-]+", ident or ""): out.append(f"{repo}#{ident}")
try:
    segs = list(segments(cmd))
except ValueError:
    segs = []
for seg in segs:
    while seg and (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", seg[0]) or seg[0] in ("env", "command", "exec", "sudo", "time")): seg = seg[1:]
    if not seg: continue
    w0 = seg[0].rsplit("/", 1)[-1]; a = seg[1:]
    if w0 == "gh" and a:
        rest = list(a)
        if rest[0] == "pr" and len(rest) >= 3 and rest[1] in ("merge", "close", "edit", "ready", "review"):
            tail = rest[2:]; num = ""; urlrepo = ""
            for t in tail:
                m = re.fullmatch(r"https?://[^/]+/[^/]+/([^/]+)/pull/(\d+).*", t)
                if m: urlrepo, num = m.group(1), m.group(2); break
                if re.fullmatch(r"\d+", t): num = t; break
            r = flag(tail, "--repo", "-R"); repo = base(r) if r else (urlrepo or origin_repo())
            if num: add(repo, num)
        elif rest[0] == "api":
            for t in rest:
                m = re.search(r"repos/([^/\s]+)/([^/\s]+)/pulls/(\d+)/(merge|reviews)\b", t)
                if m: add(m.group(2), m.group(3))
    elif w0 == "aide-verifier.sh" and a and a[0] in ("launch", "finish", "watch"):
        n = flag(a, "--pr"); r = flag(a, "--repo")
        if n and r: add(base(r), n)
    elif w0 in ("wm-decide", "wm_decide") and a and a[0] in ("merge-gate", "record", "promote"):
        n = flag(a, "--pr"); r = flag(a, "--repo")
        if n and r: add(base(r), n)
    elif w0 == "rb-merge.sh" and len(a) >= 3 and re.fullmatch(r"\d+", a[1]): add(base(a[2]), a[1])
    elif w0 == "rb-land-push.sh":
        d = flag(a, "--repo"); b = flag(a, "--branch")
        if d and b: add(base(d), b.replace("/", "_"))
print("\n".join(dict.fromkeys(out)))
' 2>/dev/null) || exit 0
[ -n "$objs" ] || exit 0
DIR="${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}/claims"
lane="${WM_AIDE_LANE:-main}"; [[ "$lane" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || lane=main
now=$(date +%s)
cget() { c_lane=""; c_sid=""; c_exp=0; [ -f "$DIR/$1" ] || return 1
  c_lane=$(sed -n 's/^lane=//p' "$DIR/$1" | head -n1); c_sid=$(sed -n 's/^sid=//p' "$DIR/$1" | head -n1); c_exp=$(sed -n 's/^expires=//p' "$DIR/$1" | head -n1)
  [[ "$c_exp" =~ ^[0-9]+$ ]] || c_exp=0; return 0; }
# pass 1: any foreign live claim denies the whole command, before anything is taken
while IFS= read -r o; do
  [ -n "$o" ] || continue
  if cget "$o" && [ "$c_exp" -gt "$now" ] && [ "$c_lane" != "$lane" ]; then
    echo "aide-claim-gate: $o claimed by lane $c_lane (sid ${c_sid:--}, expires $(date -d "@$c_exp" '+%-I:%M %p')); aide-claim.sh show $o; to release or take it over (logged): aide-claim.sh release $o --force" >&2
    exit 2
  fi
done <<<"$objs"
# pass 2: claim-on-act for every free object (expired or absent); an own-lane claim is left as is
while IFS= read -r o; do
  [ -n "$o" ] || continue
  if cget "$o" && [ "$c_exp" -gt "$now" ]; then continue; fi
  ( umask 077; mkdir -p "$DIR" ) 2>/dev/null || continue
  tmp=$(mktemp "$DIR/.claim.XXXXXX" 2>/dev/null) || continue
  printf 'lane=%s\nsid=%s\nexpires=%s\n' "$lane" "$SID" "$((now + 7200))" >"$tmp" && mv -f "$tmp" "$DIR/$o" || rm -f "$tmp"
done <<<"$objs"
exit 0
