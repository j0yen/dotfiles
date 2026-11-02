#!/usr/bin/env bash
# wm-build-status-gate.sh -- PreToolUse hook (Bash), EVERY session (no WM_SEAT exemption): refuses a top-level
# `wm-build status` / `wm-build runs` that would EXECUTE, locally or inside an executor payload.
# PREMISE: those two subcommands parse the whole user journal (~12 G RSS). 10-24 2:38 PM a timer ran `ssh ryzen7 'wm-build status'` and froze
#   ryzen7; 2:54 PM `timeout 20 ssh ryzen7 '... wm-build status'` orphaned a remote 12 G read (a carbon-side timeout kills ssh, not the remote
#   process). Approval 26 (Joe 10-24 4:02 PM "build the guard"). This is the CLIENT-SIDE STOPGAP: it cannot see timers, scripts or subprocesses;
#   the durable control is the host-side shim (dotfiles#94, ~/.cargo/bin/wm-build MemoryMax=2G).
# REMOVAL: delete this hook, lib/wmb-classify.sh and the test in ONE PR when rb's wm-build status/runs no longer parse the whole journal
#   (rb hand PR 1e3f promoted). EXPIRES: 2026-10-31 (same as the shim).
#
# ONE PATTERN: the classifier is lib/wmb-classify.sh (`wmb_classify`, byte-identical to the shim's, pinned by tests/wm-build-status-gate.test.sh).
#   This hook never special-cases around it: whatever the lib says is bound, the hook denies (so `wm-build --json land status` denies: the lib's
#   unknown-`-*` fallback says bound iff some word is status/runs; that over-match is the shim's too).
#
# HOW: (1) heredocs: a body fed to an executor (ssh/bash/sh/python/... on the same line) is scanned, a body consumed by cat/tee/a file is data;
#   (2) every $(...), backtick, <(...) and >(...) anywhere is extracted and scanned, even inside echo/printf/commit-message strings;
#   (3) the rest is tokenized (quotes, comments, redirects) into simple commands split at ; && || | & ( ) and newlines; (4) each simple command
#   has its executor prefixes peeled (timeout nice ionice env nohup setsid sudo exec command flock xargs watch systemd-run stdbuf ...),
#   then: argv0 basename wm-build|wm-build.new|wm-build.real -> wmb_classify on the rest, bound = DENY; ssh <opts> <host> '...', bash/sh -c,
#   su -c, eval -> the payload is scanned recursively; tmux, parallel, pssh, python -c, perl -e, node -e, find -exec -> a flat word scan;
#   a variable / substituted argv0 (`$w status`) -> DENY when a later word is status/runs. echo/printf args, comments, grep patterns and
#   `git commit -m` text are never commands, so mentions are allowed unless they contain a substitution. r7-ro.sh (any path) is exempt PER
#   INVOCATION: that simple command's args are not scanned, the rest of the line is.
# Fails OPEN (exit 0) on malformed JSON, missing jq, a missing lib or an oversize command (> 12 KB of non-heredoc text); each fail-open appends one line (ts, reason, no command
#   text) to ${XDG_CACHE_HOME:-$HOME/.cache}/wm-build-status-gate/fail-open.log, never to stdout.
# Deny = refusal on stderr + exit 2 (redrive-gate.sh shape). --selftest runs the cases below against this script (nothing executed).

set -o pipefail
export LC_ALL=C

self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || self=${BASH_SOURCE[0]}
libfile=$(dirname "$self")/lib/wmb-classify.sh
SEP=$'\002'      # command separator in the token arrays
SUBST=$'\001'    # placeholder for an extracted $(...) / backtick / <(...)

DENY_TEXT='wm-build-status-gate: refused. Top-level `wm-build status` / `wm-build runs` parse the whole journal (~12 G RSS) and froze ryzen7 on 10-24 2:38 PM (a carbon-side `timeout ssh` does not stop the remote read, 2:54 PM).
Read instead:
  cat ~/.cache/fleet-dash/status.json
  ssh <host> wm-build land status
  ~/.cache/r7-seat/r7-ro.sh '"'"'<narrow read>'"'"'
r7-ro.sh refuses status/runs too: a retry is a narrower read, not a wrapper.'

failopen() {  # failopen <reason>: count it (no command text), then allow
    local d=${XDG_CACHE_HOME:-${HOME:-/nonexistent}/.cache}/wm-build-status-gate
    { mkdir -p "$d" && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$d/fail-open.log"; } 2>/dev/null
    exit 0
}

is_wmb_name() { case ${1##*/} in wm-build|wm-build.new|wm-build.real) return 0 ;; esac; return 1; }

# flat_scan <text...>: payloads we cannot parse as shell (python -c, tmux send-keys, parallel ...): any wm-build word followed by a bound argv
flat_scan() {
    local t="$*" i
    local -a F
    t=${t//[^A-Za-z0-9_.\/~\$=-]/ }
    read -ra F <<<"$t"
    for ((i = 0; i < ${#F[@]}; i++)); do
        if is_wmb_name "${F[i]}" && [[ $(wmb_classify "${F[@]:i+1}") == bound ]]; then return 0; fi
    done
    return 1
}

# extract_heredocs <text>: sets RES (text minus heredoc bodies) and appends to `queue` the bodies that must be scanned
extract_heredocs() {
    local text=$1 line l out='' delim='' dash=0 quoted=0 isexec=0 body='' inhd=0 re k
    local -a lines
    re='(^|[^<])<<(-?)[[:space:]]*("([^"]*)"|'"'"'([^'"'"']*)'"'"'|\\?([A-Za-z_][A-Za-z0-9_.-]*))'
    mapfile -t lines <<<"$text"
    for line in "${lines[@]}"; do
        if ((inhd)); then
            l=$line
            ((dash)) && l=${l#"${l%%[!$'\t']*}"}
            if [[ $l == "$delim" ]]; then
                inhd=0
                if ((isexec)); then queue+=("$body")
                elif ((!quoted)); then extract_substs "$body"
                fi
                body=''
            else
                body+=$line$'\n'
            fi
            continue
        fi
        out+=$line$'\n'
        if [[ $line =~ $re ]]; then
            dash=0; [[ ${BASH_REMATCH[2]} == - ]] && dash=1
            quoted=0
            if [[ -n ${BASH_REMATCH[4]}${BASH_REMATCH[5]} || ${BASH_REMATCH[3]} == \\* ]]; then quoted=1; fi
            delim=${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}
            [[ -n $delim ]] || continue
            isexec=0
            if [[ $line =~ (^|[\;\&\|\(\`[:space:]])(ssh|bash|sh|zsh|dash|ksh|su|python[0-9.]*|perl|node|ruby|eval|script|parallel|pssh|tmux)([[:space:]]|$) ]]; then isexec=1; fi
            inhd=1; body=''
        fi
    done
    if ((inhd)); then out+=$body; fi   # unterminated: not a heredoc, scan the lines as ordinary text
    RES=$out
}

# extract_substs <text>: sets RES (each $(...) <(...) >(...) `...` replaced by $SUBST) and appends their contents to `queue`
extract_substs() {
    local s=$1 n=${#1} i=0 j c ch two depth out='' inner rest p
    while ((i < n)); do
        c=${s:i:1}
        if [[ $c == '\' ]]; then out+=${s:i:2}; i=$((i + 2)); continue; fi
        two=${s:i:2}
        if [[ $two == '$(' || $two == '<(' || $two == '>(' ]]; then
            depth=1; j=$((i + 2))
            while ((j < n && depth > 0)); do
                ch=${s:j:1}
                case $ch in
                    '\') j=$((j + 2)); continue ;;
                    "'") rest=${s:j+1}
                         if [[ $rest == *"'"* ]]; then p=${rest%%"'"*}; j=$((j + ${#p} + 2)); else j=$n; fi
                         continue ;;
                    '"') j=$((j + 1))
                         while ((j < n)); do
                             ch=${s:j:1}
                             if [[ $ch == '\' ]]; then j=$((j + 2)); continue; fi
                             [[ $ch == '"' ]] && break
                             j=$((j + 1))
                         done
                         j=$((j + 1)); continue ;;
                    '(') depth=$((depth + 1)) ;;
                    ')') depth=$((depth - 1)) ;;
                esac
                j=$((j + 1))
            done
            if ((depth == 0)); then inner=${s:i+2:j-i-3}; else inner=${s:i+2}; fi
            queue+=("$inner"); out+=$SUBST; i=$j; continue
        fi
        if [[ $c == '`' ]]; then
            j=$((i + 1))
            while ((j < n)); do
                ch=${s:j:1}
                if [[ $ch == '\' ]]; then j=$((j + 2)); continue; fi
                [[ $ch == '`' ]] && break
                j=$((j + 1))
            done
            inner=${s:i+1:j-i-1}
            queue+=("$inner"); out+=$SUBST; i=$((j + 1)); continue
        fi
        out+=$c; i=$((i + 1))
    done
    RES=$out
}

# tokenize <text>: fills TV (unquoted values) and TR (raw, quotes kept) with words; $SEP,$SEP marks a command boundary
tokenize() {
    local s=$1 n=${#1} i=0 c nx rest seg ch j inw=0 cv='' cr=''
    TV=(); TR=()
    while ((i < n)); do
        c=${s:i:1}
        case $c in
            ' '|$'\t'|$'\r')
                if ((inw)); then TV+=("$cv"); TR+=("$cr"); cv=''; cr=''; inw=0; fi
                i=$((i + 1)) ;;
            $'\n'|';'|'|'|'('|')')
                if ((inw)); then TV+=("$cv"); TR+=("$cr"); cv=''; cr=''; inw=0; fi
                TV+=("$SEP"); TR+=("$SEP"); i=$((i + 1)) ;;
            '&')
                if ((inw)) && [[ $cr == *'>' || $cr == *'<' ]]; then
                    cv+=$c; cr+=$c; i=$((i + 1))          # 2>&1, >&2
                elif [[ ${s:i+1:1} == '>' ]]; then
                    if ((inw)); then TV+=("$cv"); TR+=("$cr"); cv=''; cr=''; fi
                    cv='&'; cr='&'; inw=1; i=$((i + 1))   # &>file
                else
                    if ((inw)); then TV+=("$cv"); TR+=("$cr"); cv=''; cr=''; inw=0; fi
                    TV+=("$SEP"); TR+=("$SEP"); i=$((i + 1))
                fi ;;
            "'")
                rest=${s:i+1}
                if [[ $rest == *"'"* ]]; then seg=${rest%%"'"*}; i=$((i + ${#seg} + 2)); else seg=$rest; i=$n; fi
                cv+=$seg; cr+="'$seg'"; inw=1 ;;
            '"')
                j=$((i + 1)); seg=''
                while ((j < n)); do
                    ch=${s:j:1}
                    if [[ $ch == '\' ]]; then
                        nx=${s:j+1:1}
                        case $nx in
                            '"'|'\'|'$'|'`') seg+=$nx ;;
                            $'\n') ;;
                            *) seg+="\\$nx" ;;
                        esac
                        j=$((j + 2)); continue
                    fi
                    [[ $ch == '"' ]] && break
                    seg+=$ch; j=$((j + 1))
                done
                cv+=$seg; cr+="\"$seg\""; inw=1; i=$((j + 1)) ;;
            '\')
                nx=${s:i+1:1}
                if [[ $nx != $'\n' ]]; then cv+=$nx; cr+="\\$nx"; inw=1; fi
                i=$((i + 2)) ;;
            '#')
                if ((inw)); then cv+=$c; cr+=$c; i=$((i + 1))
                else rest=${s:i}; seg=${rest%%$'\n'*}; i=$((i + ${#seg})); fi ;;
            *) cv+=$c; cr+=$c; inw=1; i=$((i + 1)) ;;
        esac
    done
    if ((inw)); then TV+=("$cv"); TR+=("$cr"); fi
}

# filter_redirs: drop redirect operators and their targets from V/R (unquoted only)
filter_redirs() {
    local -a nv=() nr=()
    local k=0 n=${#V[@]} r
    while ((k < n)); do
        r=${R[k]}
        if [[ $r =~ ^[0-9]*(\>\>?|\<|\&\>\>?|\>\&|\<\>|\<\<-?|\<\<\<)$ ]]; then k=$((k + 2)); continue; fi
        if [[ $r =~ ^[0-9]*(\>\>?|\<|\&\>\>?|\>\&|\<\>|\<\<-?|\<\<\<)[^[:space:]]+$ ]]; then k=$((k + 1)); continue; fi
        nv+=("${V[k]}"); nr+=("$r"); k=$((k + 1))
    done
    V=("${nv[@]}"); R=("${nr[@]}")
}

# peel_one: V[IDX] is an executor prefix; advance IDX past it and its options. rc 2 = not an execution (command -v)
peel_one() {
    local a=${V[IDX]##*/} k=$((IDX + 1)) n=${#V[@]} w valre='' pos=0 envs=0
    case $a in
        timeout)  valre='^(-k|-s|--kill-after|--signal)$'; pos=1 ;;
        nice)     valre='^(-n|--adjustment)$' ;;
        ionice)   valre='^(-c|-n|-p|-P|-u|--class|--classdata|--pid|--pgid|--uid)$' ;;
        env)      valre='^(-u|-C|-S|--unset|--chdir|--split-string)$'; envs=1 ;;
        sudo|doas) valre='^(-u|-g|-h|-p|-C|-D|-r|-t|-U|-T|--user|--group|--host|--prompt|--close-from|--chdir|--role|--type)$'; envs=1 ;;
        exec)     valre='^-a$' ;;
        command)  [[ ${V[k]:-} == -v || ${V[k]:-} == -V ]] && return 2 ;;
        flock)    valre='^(-w|-E|--timeout|--wait|--conflict-exit-code)$'; pos=1 ;;
        xargs)    valre='^(-I|-n|-P|-L|-d|-E|-s|-a|-l|--replace|--max-args|--max-procs|--max-lines|--delimiter|--arg-file)$' ;;
        watch)    valre='^(-n|--interval)$' ;;
        stdbuf)   valre='^(-i|-o|-e)$' ;;
        sshpass)  valre='^(-p|-f|-d)$' ;;
        time)     valre='^(-f|-o)$' ;;
        systemd-run) valre='^(-p|-u|-E|-M|-H|-G|--property|--unit|--setenv|--machine|--host|--slice|--description|--working-directory|--uid|--gid|--on-active|--on-boot|--on-calendar|--timer-property|--service-type|--nice|--collect-after)$' ;;
        nohup|setsid|builtin|chrt|taskset|unbuffer) ;;
    esac
    while ((k < n)); do
        w=${V[k]}
        if [[ $w == -- ]]; then k=$((k + 1)); break
        elif [[ -n $valre && $w =~ $valre ]]; then k=$((k + 2))
        elif [[ $w == -?* ]]; then k=$((k + 1))
        elif ((envs)) && [[ $w == [A-Za-z_]*=* ]]; then k=$((k + 1))
        else break; fi
    done
    if ((pos && k < n)); then k=$((k + 1)); fi
    if [[ $a == flock && ${V[k]:-} == -c ]]; then V=("${V[@]:0:k}" sh "${V[@]:k}"); fi
    IDX=$k
    return 0
}

# cmd_denied: V/R/IDX describe one simple command; 0 = it runs a bound wm-build
cmd_denied() {
    local a b k n w guard=0 rc payload posok last host
    while ((guard++ < 24)); do
        n=${#V[@]}
        while ((IDX < n)); do
            case ${V[IDX]} in
                if|then|else|elif|do|while|until|'!'|'{'|'}'|fi|done) IDX=$((IDX + 1)); continue ;;
            esac
            if [[ ${R[IDX]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then IDX=$((IDX + 1)); continue; fi
            break
        done
        ((IDX < n)) || return 1
        a=${V[IDX]}; b=${a##*/}
        case $b in
            timeout|nice|ionice|env|sudo|doas|exec|command|flock|xargs|watch|stdbuf|sshpass|time|systemd-run|nohup|setsid|builtin|chrt|taskset|unbuffer)
                peel_one; rc=$?
                ((rc == 2)) && return 1
                continue ;;
        esac
        # an argv0 that is a quoted payload with spaces (watch 'wm-build status', flock -c ...): scan it
        if [[ $a == *[[:space:]]* && ${R[IDX]} == [\"\']* ]]; then scan_text "$a" && return 0; fi
        case $b in
            r7-ro.sh) return 1 ;;
            wm-build|wm-build.new|wm-build.real)
                [[ $(wmb_classify "${V[@]:IDX+1}") == bound ]] && return 0
                return 1 ;;
            ssh)
                k=$((IDX + 1))
                while ((k < n)); do
                    w=${V[k]}
                    if [[ $w == -- ]]; then k=$((k + 1)); break
                    elif [[ $w =~ ^-[bcDEeFIiJLlmOopQRSWwB]$ ]]; then k=$((k + 2))
                    elif [[ $w == -?* ]]; then k=$((k + 1))
                    else break; fi
                done
                # V[k] is the host; the rest is the remote command line
                ((k + 1 < n)) || return 1
                payload="${V[*]:k+1}"
                scan_text "$payload" && return 0
                return 1 ;;
            bash|sh|zsh|dash|ksh|su|script|runuser)
                posok=0; [[ $b == su || $b == script || $b == runuser ]] && posok=1
                k=$((IDX + 1)); payload=''
                while ((k < n)); do
                    w=${V[k]}
                    if [[ $w == -o || $w == -O || $w == +o ]]; then k=$((k + 2)); continue; fi
                    if [[ $w =~ ^-[A-Za-z]*c[A-Za-z]*$ ]]; then payload=${V[k+1]:-}; break; fi
                    if [[ $w == --command=* ]]; then payload=${w#*=}; break; fi
                    if [[ $w == -* || $w == +* ]]; then k=$((k + 1)); continue; fi
                    ((posok)) || break
                    k=$((k + 1))
                done
                [[ -n $payload ]] && scan_text "$payload" && return 0
                return 1 ;;
            eval)
                payload="${V[*]:IDX+1}"
                scan_text "$payload" && return 0
                return 1 ;;
            tmux|parallel|pssh|pdsh|clush|perl|node|nodejs|ruby|screen|awk|gawk|python|python[0-9]*)
                flat_scan "${V[@]:IDX+1}" && return 0
                return 1 ;;
            find|fd)
                for w in "${V[@]:IDX+1}"; do
                    case $w in -exec|-execdir|-ok|-okdir|-x|--exec|-X|--exec-batch) flat_scan "${V[@]:IDX+1}" && return 0; break ;; esac
                done
                return 1 ;;
        esac
        # a variable / substituted argv0 (`$w status`): the mention check above already passed (echo/git args never reach here)
        if [[ ${R[IDX]} == *$SUBST* || ${R[IDX]} =~ ^\"?\$\{?[A-Za-z_@*0-9] ]]; then
            for w in "${V[@]:IDX+1}"; do
                [[ $w == status || $w == runs ]] && return 0
            done
        fi
        return 1
    done
    return 1
}

# scan_text <text> [depth]: 0 when the text would execute a bound wm-build
scan_text() {
    local text=$1 depth=${2:-${DEPTH:-0}} q i RES IDX
    local -a queue=() TV TR V R
    ((depth > 8)) && return 1
    extract_heredocs "$text"
    # bash substring indexing is O(n) per char: ~1 s per 20 KB per loop, quadratic overall; heredoc bodies are already out of RES
    ((${#RES} <= 12000)) || failopen oversize
    extract_substs "$RES"
    tokenize "$RES"
    V=(); R=()
    for ((i = 0; i <= ${#TV[@]}; i++)); do
        if ((i == ${#TV[@]})) || [[ ${TV[i]} == "$SEP" && ${TR[i]} == "$SEP" ]]; then
            if ((${#V[@]})); then
                filter_redirs
                IDX=0
                if ((${#V[@]})); then DEPTH=$((depth + 1)) cmd_denied && return 0; fi
            fi
            V=(); R=()
        else
            V+=("${TV[i]}"); R+=("${TR[i]}")
        fi
    done
    for q in "${queue[@]}"; do
        DEPTH=$((depth + 1)) scan_text "$q" $((depth + 1)) && return 0
    done
    return 1
}

gate_main() {
    local input tool cmd
    command -v jq >/dev/null 2>&1 || failopen no-jq
    input=$(cat) || failopen read-error
    [ -n "$input" ] || exit 0
    tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || failopen bad-json
    [ "$tool" = Bash ] || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || failopen bad-json
    [ -n "$cmd" ] || exit 0
    [ -r "$libfile" ] || failopen lib-missing
    . "$libfile" 2>/dev/null || failopen lib-source-error
    declare -F wmb_classify >/dev/null || failopen lib-no-function
    ((${#cmd} <= 200000)) || failopen oversize
    if scan_text "$cmd" 0 2>/dev/null; then
        printf '%s\n' "$DENY_TEXT" >&2
        exit 2
    fi
    exit 0
}

selftest() {
    local me fail=0 n=0 rc err json td
    me=$(readlink -f "${BASH_SOURCE[0]}")
    td=$(mktemp -d) || { echo "FAIL mktemp"; return 1; }
    trap 'rm -rf "$td"' RETURN
    chk() { n=$((n + 1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
    # case_ <deny|allow> <command>   (the hook is run as a subprocess; nothing in <command> is executed)
    case_() {
        local want=$1 command=$2 label
        label=${command//$'\n'/\\n}
        json=$(jq -nc --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c}}')
        err=$(printf '%s' "$json" | XDG_CACHE_HOME="$td" HOME="$td" bash "$me" 2>&1 >/dev/null); rc=$?
        if [ "$want" = deny ]; then
            [ "$rc" = 2 ] && [[ $err == "$DENY_TEXT" ]]; chk "deny  [$label] (rc=$rc)" $?
        else
            [ "$rc" = 0 ] && [ -z "$err" ]; chk "allow [$label] (rc=$rc)" $?
        fi
    }
    # the two incident lines, verbatim
    case_ deny  "ssh ryzen7 'wm-build status'"
    case_ deny  'timeout 20 ssh ryzen7 '"'"'export PATH=$HOME/.cargo/bin:$PATH; wm-build status'"'"
    case_ deny  'echo "$(ssh ryzen7 wm-build status)"'
    case_ deny  'printf "%s" "$(wm-build runs)"'
    case_ deny  'git commit -m "x $(wm-build status)"'
    case_ deny  'x=`wm-build status`'
    case_ deny  'wc -l <(wm-build runs)'
    case_ deny  'wm-build status'
    case_ deny  'wm-build status --json'
    case_ deny  './wm-build runs'
    case_ deny  '~/.cargo/bin/wm-build status'
    case_ deny  '$HOME/.cargo/bin/wm-build runs'
    case_ deny  '/home/jsy/.cargo/bin/wm-build.new status'
    case_ deny  '"wm-build" "status"'
    case_ deny  'wm-build --state-dir /x status --brief'
    case_ deny  'wm-build --state-dir=/x runs'
    case_ deny  'wm-build -j4 status'
    case_ deny  'wm-build --json land status'
    case_ deny  'cd /tmp && wm-build status | tail -3'
    case_ deny  'FOO=1 wm-build status'
    case_ deny  'nohup nice -n 5 env A=b wm-build runs &'
    case_ deny  'systemd-run --user --scope -p MemoryMax=2G wm-build status'
    case_ deny  'bash -c "wm-build status"'
    case_ deny  "sh -lc 'cd x; wm-build runs'"
    case_ deny  "eval 'wm-build status'"
    case_ deny  "tmux send-keys -t r7 'wm-build status' Enter"
    case_ deny  'for h in a b; do ssh $h wm-build status; done'
    case_ deny  'r7-ro.sh --selftest; ssh ryzen7 wm-build status'
    case_ deny  $'ssh ryzen7 <<\'EOF\'\nwm-build runs\nEOF'
    case_ deny  'w=wm-build; $w status'
    case_ deny  'ssh ryzen7 "sudo -u jsy wm-build runs"'
    case_ deny  'watch -n 5 "wm-build status"'
    case_ deny  'xargs -I{} wm-build status {}'
    case_ deny  'python3 -c "import subprocess; subprocess.run([\"wm-build\",\"status\"])"'
    case_ deny  $'cat <<EOF | ssh ryzen7 bash\nwm-build runs\nEOF'
    case_ allow 'git commit -m "fix wm-build status read"'
    case_ allow "ssh ryzen7 'grep \"wm-build status\" journal'"
    case_ allow 'systemctl --user status wm-build'
    case_ allow 'wm-build-status-gate.sh --selftest'
    case_ allow 'wm-build land status'
    case_ allow 'wm-build circuit status'
    case_ allow 'wm-build run show 5'
    case_ allow 'wm-build --state-dir /x run redrive 5 --from land'
    case_ allow 'echo "wm-build status"'
    case_ allow 'printf "%s\n" "wm-build runs is slow"'
    case_ allow 'ls /tmp # wm-build status later'
    case_ allow 'grep -rn "wm-build runs" /home/jsy/notes'
    case_ allow 'echo "$w status"'
    case_ allow 'git commit -m "$w status"'
    case_ allow '~/.cache/r7-seat/r7-ro.sh --check '"'"'wm-build status'"'"
    case_ allow 'r7-ro.sh "wm-build land status"'
    case_ allow $'cat > x.sh <<\'EOF\'\nwm-build runs\nEOF'
    case_ allow $'git commit -m "$(cat <<\'EOF\'\nfix: wm-build status gate (it\'s a stopgap)\nEOF\n)"'
    case_ allow 'command -v wm-build status'
    case_ allow 'cargo build -p wm-build --bin status'
    # a benign substitution inside a mention is fine
    case_ allow 'echo "see $(date) for wm-build status"'
    # fail-open cases
    json='{not json'
    err=$(printf '%s' "$json" | XDG_CACHE_HOME="$td" HOME="$td" bash "$me" 2>&1 >/dev/null); rc=$?
    [ "$rc" = 0 ] && [ -z "$err" ] && grep -q ' bad-json$' "$td/wm-build-status-gate/fail-open.log"; chk "malformed JSON allowed, counted in fail-open.log (rc=$rc)" $?
    err=$(printf '' | XDG_CACHE_HOME="$td" HOME="$td" bash "$me" 2>&1 >/dev/null); rc=$?
    [ "$rc" = 0 ]; chk "empty input allowed (rc=$rc)" $?
    json=$(jq -nc '{tool_name:"Write",tool_input:{command:"wm-build status"}}')
    err=$(printf '%s' "$json" | XDG_CACHE_HOME="$td" HOME="$td" bash "$me" 2>&1 >/dev/null); rc=$?
    [ "$rc" = 0 ]; chk "non-Bash tool allowed (rc=$rc)" $?
    case $DENY_TEXT in *'cat ~/.cache/fleet-dash/status.json'*'ssh <host> wm-build land status'*"r7-ro.sh '<narrow read>'"*'r7-ro.sh refuses status/runs too'*) true ;; *) false ;; esac
    chk "refusal text names the three retry forms and the r7-ro.sh note" $?
    echo "selftest: $((n - fail))/$n passed, $fail failed"
    [ "$fail" = 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
fi
gate_main
