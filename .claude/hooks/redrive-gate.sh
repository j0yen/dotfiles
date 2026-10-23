#!/usr/bin/env bash
# redrive-gate.sh — PreToolUse hook (Bash): the operator seat r7 (env WM_SEAT=r7) never runs a bare
# `wm-build run redrive …` (or `wm-build redrive …`); every hand redrive goes through ~/.local/bin/r7-redrive.sh,
# which files the wm-decide run-state row FIRST and redrives only on a decision id (ctl 10-23, class 373c: a
# `[ -n "$R" ] &&` in a one-off command line is not a mechanism).
#
# Scope: WM_SEAT=r7 only. No .local/bin/rb-redrive.sh exists in this repo (only rb-merge.sh), so rb has no sanctioned
# wrapper to route to and is NOT gated; add rb to GATED_SEATS when an rb-redrive.sh lands. WM_SEAT unset (the aide),
# ctl (the controller) and every other value are never gated.
#
# Deny shape: probe-gate.sh's (refusal text on stderr, exit 2). prd-write-gate.sh instead prints a
# hookSpecificOutput JSON on stdout with exit 0; the two differ, so this follows probe-gate as the spec says.
#
# Matching: a command-position `wm-build [run] redrive` (optionally behind a path such as ~/.cargo/bin/ or $HOME/.cargo/bin/)
# after `; & | (` or whitespace. Before matching, text that is only MENTIONING redrive is blanked: comments, the quoted
# value of r7-redrive.sh --why/--evidence/--reverse, the quoted argument of echo/printf, and (when no ssh/bash/sh/eval/
# tmux/xargs executor is on the line) every quoted string. A quoted payload handed to an executor, such as
# `ssh host "wm-build run redrive …"` or `bash -c '…'`, is still a redrive and is denied. A chain like
# `r7-redrive.sh … ; wm-build run redrive 9` is denied too (the wrapper does not excuse a second, bare call).
# Fails OPEN on malformed input or missing jq: a bug here must never block unrelated Bash calls.
#
# --selftest runs every case below against this script (no real commands executed).

set -uo pipefail

GATED_SEATS="r7"
DENY_TEXT='r7-redrive-gate: a bare `wm-build run redrive` from a seat is refused; use ~/.local/bin/r7-redrive.sh <run> <inner|gate|land|live> --expect <state> --why <W> --evidence <E> (it files the wm-decide row first).'

# redrive_mention_blanked <cmd>: print cmd with non-executing mentions removed
blank_mentions() {
    printf '%s' "$1" | sed -E \
        -e 's/(--(why|evidence|reverse))[ =]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"')/\1 X/g' \
        -e 's/(^|[;&|( \t])(echo|printf)([ \t]+-[a-zA-Z]+)*[ \t]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"')/\1\2 X/g' \
        -e 's/(^|[ \t])#.*$/\1/'
}

# is_redrive <cmd>: 0 when cmd runs a wm-build redrive
is_redrive() {
    local c pos qpos exec_re
    c=$(blank_mentions "$1")
    pos='(^|[;&|(]|[[:space:]])([^[:space:];&|(]*/)?wm-build[[:space:]]+(run[[:space:]]+)?redrive([^[:alnum:]_]|$)'
    qpos='["'"'"'`]([^[:space:];&|(]*/)?wm-build[[:space:]]+(run[[:space:]]+)?redrive([^[:alnum:]_]|$)'
    exec_re='(^|[;&|(]|[[:space:]])(ssh|eval|bash|sh|zsh|tmux|xargs)[[:space:]]'
    if printf '%s' "$c" | grep -qE "$exec_re"; then
        # an executor may run a quoted payload: ssh h "wm-build run redrive …", bash -c '…', eval "…"
        printf '%s' "$c" | grep -qE "$pos" && return 0
        printf '%s' "$c" | grep -qE "$qpos" && return 0
        return 1
    fi
    # no executor: quoted text is data (git commit -m "…", grep "…"); blank it, then look for a real invocation
    c=$(printf '%s' "$c" | sed -E -e 's/"([^"\\]|\\.)*"/ X /g' -e "s/'[^']*'/ X /g")
    printf '%s' "$c" | grep -qE "$pos"
}

gate_main() {
    local jq input tool cmd seat s
    jq=$(command -v jq) || exit 0
    input=$(cat) || exit 0
    [ -n "$input" ] || exit 0
    if ! tool=$(printf '%s' "$input" | "$jq" -r '.tool_name // empty' 2>/dev/null); then
        echo "redrive-gate: input is not valid JSON; allowing" >&2
        exit 0
    fi
    [ "$tool" = "Bash" ] || exit 0
    cmd=$(printf '%s' "$input" | "$jq" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
    [ -n "$cmd" ] || exit 0
    seat="${WM_SEAT:-}"
    [ -n "$seat" ] || exit 0
    local gated=0
    for s in $GATED_SEATS; do [ "$seat" = "$s" ] && gated=1; done
    [ "$gated" = 1 ] || exit 0
    if is_redrive "$cmd"; then
        printf '%s\n' "$DENY_TEXT" >&2
        exit 2
    fi
    exit 0
}

selftest() {
    local me fail=0 n=0 rc err out want
    me=$(readlink -f "${BASH_SOURCE[0]}")
    # the verbatim refusal text from r7, written independently of DENY_TEXT
    want='r7-redrive-gate: a bare `wm-build run redrive` from a seat is refused; use ~/.local/bin/r7-redrive.sh <run> <inner|gate|land|live> --expect <state> --why <W> --evidence <E> (it files the wm-decide row first).'
    chk() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
    # case <name> <want_rc> <seat|-> <tool> <command>
    case_() {
        local name=$1 wrc=$2 seat=$3 tool=$4 command=$5 json
        json=$(jq -nc --arg t "$tool" --arg c "$command" '{tool_name:$t,tool_input:{command:$c}}')
        if [ "$seat" = - ]; then
            err=$(printf '%s' "$json" | env -u WM_SEAT bash "$me" 2>&1 >/dev/null); rc=$?
        else
            err=$(printf '%s' "$json" | WM_SEAT=$seat bash "$me" 2>&1 >/dev/null); rc=$?
        fi
        if [ "$wrc" = 2 ]; then
            [ "$rc" = 2 ] && [ "$err" = "$want" ]; chk "$name (rc=$rc)" $?
        else
            [ "$rc" = 0 ] && [ -z "$err" ]; chk "$name (rc=$rc)" $?
        fi
    }
    case_ "bare 'wm-build run redrive 123' as r7 denied"          2 r7 Bash 'wm-build run redrive 123'
    case_ "'wm-build run redrive 123 --from land' denied"         2 r7 Bash 'wm-build run redrive 123 --from land --operator r7'
    case_ "'wm-build redrive 123' spelling denied"                2 r7 Bash 'wm-build redrive 123 --from gate'
    case_ "~/.cargo/bin/wm-build path denied"                     2 r7 Bash '~/.cargo/bin/wm-build run redrive 5 --from inner'
    case_ "\$HOME/.cargo/bin/wm-build path denied"                2 r7 Bash '$HOME/.cargo/bin/wm-build run redrive 5 --from inner'
    case_ "chained 'cd x && wm-build run redrive' denied"         2 r7 Bash 'cd /tmp/x && wm-build run redrive 7 --from land'
    case_ "ssh ryzen7 \"wm-build run redrive\" denied"            2 r7 Bash 'ssh ryzen7 "export PATH=$HOME/.cargo/bin:$PATH; wm-build run redrive 9 --from gate"'
    case_ "ssh with the command quoted first denied"              2 r7 Bash "ssh ryzen7 'wm-build run redrive 9 --from gate'"
    case_ "wrapper then bare redrive in one line denied"          2 r7 Bash 'r7-redrive.sh 1 land --expect land --why w --evidence e; wm-build run redrive 2'
    case_ "r7-redrive.sh invocation allowed"                      0 r7 Bash '~/.local/bin/r7-redrive.sh 123 land --expect land --why "redo the redrive" --evidence "tail"'
    case_ "r7-redrive.sh with 'wm-build run redrive' in --why allowed" 0 r7 Bash 'r7-redrive.sh 123 land --expect land --why "ran wm-build run redrive by hand before" --evidence "x"'
    case_ "redrive in an echo string allowed"                     0 r7 Bash 'echo "do not run wm-build run redrive by hand"'
    case_ "redrive in a comment allowed"                          0 r7 Bash 'ls /tmp # wm-build run redrive 5 later'
    case_ "git commit -m mentioning redrive allowed"              0 r7 Bash 'git commit -m "gate wm-build run redrive"'
    case_ "other wm-build verb allowed"                           0 r7 Bash 'wm-build run status 123'
    case_ "non-Bash tool allowed"                                 0 r7 Write 'wm-build run redrive 123'
    case_ "WM_SEAT unset (aide) allowed"                          0 -  Bash 'wm-build run redrive 123 --from land'
    case_ "WM_SEAT=ctl allowed"                                   0 ctl Bash 'wm-build run redrive 123 --from land'
    case_ "WM_SEAT=rb allowed (no rb-redrive.sh exists)"          0 rb Bash 'wm-build run redrive 123 --from land'
    err=$(printf '%s' '{not json' | WM_SEAT=r7 bash "$me" 2>&1 >/dev/null); rc=$?
    [ "$rc" = 0 ] && [ -n "$err" ]; chk "malformed JSON allowed, rc 0, stderr note (rc=$rc)" $?
    err=$(printf '' | WM_SEAT=r7 bash "$me" 2>&1 >/dev/null); rc=$?
    [ "$rc" = 0 ] && [ -z "$err" ]; chk "empty input allowed, rc 0 (rc=$rc)" $?
    [ "$DENY_TEXT" = "$want" ]; chk "DENY_TEXT byte-equal to the verbatim refusal" $?
    echo "selftest: $((n-fail))/$n passed, $fail failed"
    [ "$fail" = 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
fi
gate_main
