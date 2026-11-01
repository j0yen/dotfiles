#!/usr/bin/env bash
# row-gate-guard.sh — PreToolUse hook (Bash): a row gate must be gated on the row tool's OWN exit status.
# 10-23 3:58 PM (rb): `R=$(rb-row.sh … 2>&1 | tail -1) && <reset + redrive>` ran the action although rb-row.sh refused
# (exit 1): the pipeline's status is tail's 0. rb-row.sh itself is right; the defect is the caller's shape, so only a
# pre-execution hook can stop it. The row tools are rb-row.sh, r7-row.sh, ctl-row.sh and `wm-decide record`.
#
# Rules (the command is tokenised by a small quote- and $( / backtick-depth-aware scanner, never a bare regex):
#   A  a row tool that is a NON-LAST element of a pipeline, at any depth ($(…), "$(…)", backticks, or bare
#      `rb-row.sh … | tail -1 && go`): the pipeline's status is the last command's, not the row tool's. A `|` inside a
#      quoted argument (`--what "a | b"`) is data and never denies; a row tool as the LAST element is allowed.
#   B  `NAME=$(row tool …)` / `NAME="$(row tool …)"` whose first list operator is `;` or a newline with another command
#      after it: the action no longer depends on the row. `&&`, `||`, or the end of the command are allowed.
#   C  `[ -n "$NAME" ]`, `[[ -n $NAME ]]` or `test -n "$NAME"` on a NAME assigned from a row tool in the same command:
#      a non-empty string is not a recorded row.
# A row-tool word is a command-position word (after assignments / bash / env / command / if …); a path to the script
# counts; `rb-row.sh --selftest …` is not a row. Over-deny accepted: a row tool piped into something else always denies.
# Quoted payloads handed to an executor (`bash -c "…"`, `ssh h "…"`) are not parsed (data), so they are allowed.
#
# Deny shape: redrive-gate.sh / probe-gate.sh's (refusal text on stderr, exit 2). Python reads the stdin JSON itself
# (no jq dependency). Cheap first exit: a command naming no row tool exits 0 before any scanning.
# Fails OPEN on empty or malformed JSON, a non-Bash tool, a missing python3, a scanner parse error (unterminated
# quote or $( ), or any python exception: a bug here must never block unrelated Bash calls.
#
# --selftest runs every case below against this script (no real commands executed). Needs jq (selftest only).

set -uo pipefail

read -r -d '' PY <<'PYEOF' || true
import json
import re
import sys

DENY = ("row-gate-guard: gate on the row tool's own exit: R=$(rb-row.sh ...) && <action> "
        "(no pipe, no ;, no [ -n ])")
ROW_NAMES = ("rb-row.sh", "r7-row.sh", "ctl-row.sh")
CHEAP = re.compile(r"(rb-row\.sh|r7-row\.sh|ctl-row\.sh|wm-decide\s+record)")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SKIP = {"bash", "sh", "zsh", "env", "command", "exec", "time", "nohup", "sudo", "builtin", "export", "local",
        "declare", "readonly", "typeset", "if", "while", "until", "then", "do", "else", "elif", "!"}
TESTS = {"[", "[[", "test"}


class ParseError(Exception):
    pass


class Word:
    __slots__ = ("raw", "subs")

    def __init__(self):
        self.raw = ""
        self.subs = []


class Lexer:
    def __init__(self, s):
        self.s = s
        self.n = len(s)
        self.i = 0

    def level(self, closer):
        s, n = self.s, self.n
        items = []
        cur = [None]
        heredocs = []
        paren = 0

        def word():
            if cur[0] is None:
                cur[0] = Word()
            return cur[0]

        def flush():
            if cur[0] is not None:
                items.append(cur[0])
                cur[0] = None

        def sub(kind):
            # called just after the opener; returns after the matching closer
            word().subs.append(self.level(kind))

        def skip_brace():
            # ${ ... } kept as plain word text
            depth, j = 0, self.i
            while j < n:
                if s[j] == "{":
                    depth += 1
                elif s[j] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= n:
                raise ParseError("unterminated ${")
            word().raw += s[self.i:j + 1]
            self.i = j + 1

        while True:
            if self.i >= n:
                if closer is None:
                    break
                raise ParseError("unterminated " + closer)
            c = s[self.i]
            if closer == "`" and c == "`":
                self.i += 1
                break
            if closer == ")" and c == ")" and paren == 0:
                self.i += 1
                break
            if c == "\\":
                word().raw += s[self.i:self.i + 2]
                self.i += 2
            elif c == "'":
                j = s.find("'", self.i + 1)
                if j < 0:
                    raise ParseError("unterminated '")
                word().raw += s[self.i:j + 1]
                self.i = j + 1
            elif c == '"':
                word().raw += '"'
                self.i += 1
                while True:
                    if self.i >= n:
                        raise ParseError('unterminated "')
                    ch = s[self.i]
                    if ch == "\\":
                        word().raw += s[self.i:self.i + 2]
                        self.i += 2
                    elif ch == '"':
                        word().raw += '"'
                        self.i += 1
                        break
                    elif s.startswith("$(", self.i):
                        word().raw += "$("
                        self.i += 2
                        sub(")")
                        word().raw += ")"
                    elif s.startswith("${", self.i):
                        skip_brace()
                    elif ch == "`":
                        word().raw += "`"
                        self.i += 1
                        sub("`")
                        word().raw += "`"
                    else:
                        word().raw += ch
                        self.i += 1
            elif s.startswith("$(", self.i):
                word().raw += "$("
                self.i += 2
                sub(")")
                word().raw += ")"
            elif s.startswith("${", self.i):
                skip_brace()
            elif c == "`":
                word().raw += "`"
                self.i += 1
                sub("`")
                word().raw += "`"
            elif c == "#" and cur[0] is None:
                j = s.find("\n", self.i)
                self.i = n if j < 0 else j
            elif c in " \t":
                flush()
                self.i += 1
            elif c == "\n":
                flush()
                items.append("\n")
                self.i += 1
                for delim in heredocs:
                    while self.i < n:
                        j = s.find("\n", self.i)
                        line = s[self.i:n if j < 0 else j]
                        self.i = n if j < 0 else j + 1
                        if line.strip() == delim:
                            break
                heredocs = []
            elif c == "|":
                flush()
                if s.startswith("||", self.i):
                    items.append("||")
                    self.i += 2
                elif s.startswith("|&", self.i):
                    items.append("|")
                    self.i += 2
                else:
                    items.append("|")
                    self.i += 1
            elif c == "&":
                if (cur[0] is not None and cur[0].raw[-1:] in ("<", ">")) or s.startswith("&>", self.i):
                    word().raw += c
                    self.i += 1
                elif s.startswith("&&", self.i):
                    flush()
                    items.append("&&")
                    self.i += 2
                else:
                    flush()
                    items.append("&")
                    self.i += 1
            elif c == ";":
                flush()
                items.append(";")
                self.i += 2 if s[self.i + 1:self.i + 2] in (";", "&") else 1
            elif c == "(":
                flush()
                paren += 1
                items.append("(")
                self.i += 1
            elif c == ")":
                flush()
                paren = max(0, paren - 1)
                items.append(")")
                self.i += 1
            elif c == "<" and s.startswith("<<", self.i) and not s.startswith("<<<", self.i):
                j = self.i + 2
                if s[j:j + 1] == "-":
                    j += 1
                while j < n and s[j] in " \t":
                    j += 1
                k = j
                while k < n and s[k] not in " \t\n;&|()<>":
                    k += 1
                heredocs.append(s[j:k].strip("'\"\\"))
                word().raw += "<<"
                self.i += 2
            else:
                word().raw += c
                self.i += 1
        flush()
        return items


def split(items):
    """items -> [(words, following_op)]"""
    cmds, words = [], []
    for it in items:
        if isinstance(it, Word):
            words.append(it)
        else:
            cmds.append((words, it))
            words = []
    if words:
        cmds.append((words, None))
    return cmds


def prog_index(words):
    k = 0
    while k < len(words):
        r = words[k].raw
        if ASSIGN.match(r) or r in SKIP or r.startswith("-"):
            k += 1
        else:
            break
    return k


def unq(raw):
    return raw.strip("\"'")


def is_row(words):
    if any(w.raw == "--selftest" for w in words):
        return False
    k = prog_index(words)
    if k >= len(words):
        return False
    base = unq(words[k].raw).rsplit("/", 1)[-1]
    if base in ROW_NAMES:
        return True
    return base == "wm-decide" and k + 1 < len(words) and unq(words[k + 1].raw) == "record"


def has_row(items):
    for words, _op in split(items):
        if words and is_row(words):
            return True
        for w in words:
            if any(has_row(sub) for sub in w.subs):
                return True
    return False


def all_cmds(items):
    for idx, (words, op) in enumerate(split(items)):
        yield idx, words, op
        for w in words:
            for sub in w.subs:
                yield from all_cmds(sub)


def scan(items, out, names):
    cmds = split(items)
    for idx, (words, op) in enumerate(cmds):
        for w in words:
            for sub in w.subs:
                scan(sub, out, names)
        if words and op == "|" and is_row(words):
            out.append(("A", "a row tool is a non-last element of a pipeline: the pipeline's status is the last "
                             "command's, so a refused row still exits 0"))
        asg = [w for w in words if ASSIGN.match(w.raw) and any(has_row(sub) for sub in w.subs)]
        for w in asg:
            names.add(w.raw.split("=", 1)[0])
        if asg and op in (";", "\n") and any(c[0] for c in cmds[idx + 1:]):
            out.append(("B", "the row assignment is followed by `;` or a newline: the action no longer depends on "
                             "the row tool's exit"))


def check_c(items, names, out):
    if not names:
        return
    for _idx, words, _op in all_cmds(items):
        k = prog_index(words)
        if k >= len(words) or words[k].raw not in TESTS:
            continue
        for j, w in enumerate(words):
            if w.raw == "-n" and j + 1 < len(words):
                for nm in names:
                    if re.search(r"\$\{?" + re.escape(nm) + r"(?![A-Za-z0-9_])", words[j + 1].raw):
                        out.append(("C", "`-n $%s` tests a non-empty string, not a recorded row" % nm))
                        return


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        return 0
    try:
        data = json.loads(raw)
    except ValueError:
        sys.stderr.write("row-gate-guard: input is not valid JSON; allowing\n")
        return 0
    if not isinstance(data, dict) or data.get("tool_name") != "Bash":
        return 0
    ti = data.get("tool_input")
    cmd = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(cmd, str) or not CHEAP.search(cmd):
        return 0
    try:
        items = Lexer(cmd).level(None)
    except ParseError as e:
        sys.stderr.write("row-gate-guard: cannot parse the command (%s); allowing\n" % e)
        return 0
    out, names = [], set()
    scan(items, out, names)
    check_c(items, names, out)
    if out:
        sys.stderr.write(DENY + "\nrow-gate-guard: rule %s: %s\n" % out[0])
        return 2
    return 0


try:
    rc = main()
except Exception as e:  # a bug here must never block an unrelated call
    sys.stderr.write("row-gate-guard: internal error (%s); allowing\n" % type(e).__name__)
    rc = 0
sys.exit(rc)
PYEOF

gate_main() {
    command -v python3 >/dev/null 2>&1 || exit 0
    python3 -I -c "$PY"
    [ "$?" = 2 ] && exit 2
    exit 0
}

selftest() {
    local me fail=0 n=0 d want o e
    me=$(readlink -f "${BASH_SOURCE[0]}")
    d=$(mktemp -d) || return 1
    trap 'rm -rf -- "${d:?}"' RETURN
    # the verbatim refusal line, written independently of the python DENY
    want="row-gate-guard: gate on the row tool's own exit: R=\$(rb-row.sh ...) && <action> (no pipe, no ;, no [ -n ])"
    chk() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
    run_() { bash "$me" <<<"$1" >"$d/o" 2>"$d/e"; rc=$?; }
    # deny <name> <rule> <command>: rc 2, stdout empty, stderr line 1 = the refusal, line 2 names the rule
    deny() {
        local json
        json=$(jq -nc --arg c "$3" '{tool_name:"Bash",tool_input:{command:$c}}')
        run_ "$json"
        [ "$rc" = 2 ] && [ ! -s "$d/o" ] && [ "$(sed -n 1p "$d/e")" = "$want" ] \
            && sed -n 2p "$d/e" | grep -q "^row-gate-guard: rule $2: "
        chk "DENY $1 [rule $2] (rc=$rc)" $?
    }
    # allow <name> <command>: rc 0, stdout empty
    allow() {
        local json
        json=$(jq -nc --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}')
        run_ "$json"
        [ "$rc" = 0 ] && [ ! -s "$d/o" ]; chk "ALLOW $1 (rc=$rc)" $?
    }
    # allow_raw <name> <raw stdin>
    allow_raw() { run_ "$2"; [ "$rc" = 0 ] && [ ! -s "$d/o" ]; chk "ALLOW $1 (rc=$rc)" $?; }

    deny "pipe in \$( ) with 2>&1 | tail"           A 'R=$(rb-row.sh --kind x 2>&1 | tail -1) && echo go'
    deny "1b quoted \"\$( )\" with a pipe"          A 'R="$(rb-row.sh --kind x 2>&1 | tail -1)" && go'
    deny "bare rb-row.sh | tail && go"              A 'rb-row.sh --kind x 2>&1 | tail -1 && go'
    deny "backtick form"                            A 'R=`rb-row.sh --kind x 2>&1 | tail -1` && go'
    deny "wm-decide record | tail"                  A 'R=$(wm-decide record --kind x | tail -1) && x'
    deny "ctl-row.sh | tail"                        A 'R=$(ctl-row.sh --kind x | tail -1) && go'
    deny "r7-row.sh | tee"                          A 'R=$(r7-row.sh --kind x | tee /tmp/x) && go'
    deny "path to the script piped"                 A 'R=$(~/.cache/rb-seat/rb-row.sh --kind x 2>&1 | tail -1) && go'
    deny "bash <script> piped"                      A 'R=$(bash ~/.cache/rb-seat/rb-row.sh --kind x | tail -1) && go'
    deny "pipe nested 30 deep"                      A "R=$(printf '$(%.0s' $(seq 1 30))rb-row.sh x | tail -1$(printf ')%.0s' $(seq 1 30)) && go"
    deny "pipe inside \"\$( )\" in an argument"     A 'echo "x $(rb-row.sh --kind x | tail -1)" && go'
    deny "row; action"                              B 'R=$(rb-row.sh --kind x); go'
    deny "row newline action"                       B $'R=$(rb-row.sh --kind x)\ngo'
    deny "quoted row; action"                       B 'R="$(r7-row.sh --kind x)"; go'
    deny "row; [ -n \"\$R\" ] && go"                B 'R=$(rb-row.sh --kind x); [ -n "$R" ] && go'
    deny "&& [ -n \"\$R\" ] && go"                  C 'R=$(rb-row.sh --kind x) && [ -n "$R" ] && go'
    deny "&& test -n \"\$R\" && go"                 C 'R=$(r7-row.sh --kind x) && test -n "$R" && go'
    deny "&& [[ -n \$R ]] && go"                    C 'R=$(ctl-row.sh --kind x) && [[ -n $R ]] && go'
    deny "if [ -n \"\${R}\" ]"                      C 'R=$(rb-row.sh --kind x) || true; if [ -n "${R}" ]; then go; fi'

    allow "quoted | in an argument"                 'R=$(rb-row.sh --kind x --what "a | b") && go'
    allow "single-quoted | in an argument"          "R=\$(rb-row.sh --kind x --what 'a | b') && go"
    allow "plain row && go"                         'R=$(rb-row.sh --kind x) && go'
    allow "quoted row && go"                        'R="$(rb-row.sh --kind x)" && go'
    allow "unrelated pipe in \$( )"                 'echo $(date | cut -c1-5)'
    allow "pipe at depth 2 inside a row argument"   'R=$(rb-row.sh --kind x --what "$(date | cut -c1-5)") && go'
    allow "row && go; echo done"                    'R=$(rb-row.sh --kind x) && go; echo done'
    allow "row only (end of command)"               'R=$(rb-row.sh --kind x)'
    allow "row then trailing newline only"          $'R=$(rb-row.sh --kind x)\n'
    allow "row || exit"                             'R=$(rb-row.sh --kind x) || exit 1'
    allow "row tool as the LAST pipeline element"   'R=$(echo x | rb-row.sh --kind x) && go'
    allow "reading the script: cat … | head"        'cat ~/.cache/rb-seat/rb-row.sh | head -20'
    allow "rb-row.sh --selftest | tail"             'bash ~/.cache/rb-seat/rb-row.sh --selftest | tail -3'
    allow "wm-decide list | tail (not record)"      'wm-decide list | tail -3'
    allow "quoted mention in echo"                  "echo 'R=\$(rb-row.sh x | tail -1) && go'"
    allow "commit message mention"                  'git commit -m "gate rb-row.sh | tail"'
    allow "comment mention"                         'ls # R=$(rb-row.sh x | tail -1) && go'
    allow "heredoc body mention"                    $'cat <<EOF\nR=$(rb-row.sh x | tail -1) && go\nEOF'
    allow "bash -c payload is data"                 'bash -c "R=\$(rb-row.sh x | tail -1) && go"'
    allow "-n on a variable not from a row tool"    'Q=$(date) && [ -n "$Q" ] && rb-row.sh --kind x'
    allow "no row tool named (cheap exit)"          'ls | wc -l; R=$(date | tail -1); [ -n "$R" ]'
    allow_raw "non-Bash tool"                       '{"tool_name":"Write","tool_input":{"command":"R=$(rb-row.sh x | tail -1) && go"}}'
    allow_raw "malformed JSON"                      '{not json'
    allow_raw "empty input"                         ''
    allow_raw "JSON that is not an object"          '[1,2]'
    allow_raw "command is not a string (error branch)" '{"tool_name":"Bash","tool_input":{"command":5}}'
    allow "unterminated \$( (parse-error branch)"   'R=$(rb-row.sh --kind x | tail -1'
    allow "unterminated quote (parse-error branch)" 'R=$(rb-row.sh --kind x --what "a | b) && go'
    allow "recursion bomb (python exception branch)" "R=$(printf '$(%.0s' $(seq 1 1500))rb-row.sh x | tail -1$(printf ')%.0s' $(seq 1 1500)) && go"
    grep -q 'internal error (RecursionError); allowing' "$d/e"; chk "recursion bomb hit the except branch, not a parse path" $?
    allow "unterminated quote stderr is the parse note" 'R="$(rb-row.sh x | tail -1) && go'
    grep -q 'cannot parse the command' "$d/e"; chk "parse-error branch prints its note" $?

    echo "selftest: $((n-fail))/$n passed, $fail failed"
    [ "$fail" = 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
fi
gate_main
