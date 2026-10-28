#!/usr/bin/env bash
# coder-heartbeat.sh <pre|post|stop> — proof-of-life lines for a coder session (503 MECH1a).
# Wired on PreToolUse / PostToolUse / PostToolUseFailure / Stop (matcher ""). Reads the hook JSON on stdin.
#
# Target file: $WM_BUILD_PROGRESS, else ~/.cache/rb-seat/coders/$RB_CODER_ID.progress.jsonl, else exit 0
# at once (non-coder sessions are untouched: no jq, no file). One printf per line, O_APPEND, keys exactly the
# vendored contract `keys` (heartbeat-contract.json next to this script; constants are read from it, never
# hardcoded). `what` = tool name + ":" + the command's first token (basename, leading VAR=val words skipped)
# or the file basename — never args, env or headers.
#
# pre   -> pre line + a detached setsid ticker that appends `heartbeat tick` every tick_s for the same call
#          while the coder pid lives, no done-marker exists, and now < deadline + 60.
# post  -> post line, ends that call's ticker (exact pid, checked to be a ticker).
# stop  -> stop line, ends every ticker this session created (/tmp/coder-hb-session-<sid>.list).
# Always exits 0; any internal error is silent.
#
# Test-only env overrides: CODER_HB_TICK_S (replaces contract tick_s), CODER_HB_PID (replaces the claude pid).

mode=${1:-}
case "$mode" in pre|post|stop) ;; *) exit 0 ;; esac

target=${WM_BUILD_PROGRESS:-}
if [ -z "$target" ] && [ -n "${RB_CODER_ID:-}" ]; then
    target="$HOME/.cache/rb-seat/coders/$RB_CODER_ID.progress.jsonl"
fi
[ -n "$target" ] || exit 0

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || exit 0
contract="$here/heartbeat-contract.json"
[ -r "$contract" ] || exit 0
T=${TMPDIR:-/tmp}

# claude pid: nearest ancestor whose comm is claude or node, else $PPID
pid=${CODER_HB_PID:-}
if [ -z "$pid" ]; then
    pid=$PPID
    p=$PPID
    for _ in 1 2 3 4 5 6 7 8; do
        [ "${p:-0}" -gt 1 ] 2>/dev/null || break
        read -r comm < "/proc/$p/comm" 2>/dev/null || break
        case "$comm" in claude|node) pid=$p; break ;; esac
        p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || break
    done
fi

printf -v epoch '%(%s)T' -1

# one jq read: payload + contract -> call, session, tick_s, deadline, line
mapfile -t out < <(jq -r --slurpfile c "$contract" --arg mode "$mode" --argjson now "$epoch" \
    --argjson pid "${pid:-0}" --arg envt "${BASH_DEFAULT_TIMEOUT_MS:-}" '
  ($c[0]) as $k
  | select(type == "object" and ($mode == "stop" or (.tool_name | type) == "string"))
  | (.tool_name // "") as $tool
  | (.tool_input // {}) as $in
  | (($in | if type == "object" then (.command // "") else "" end) | if type == "string" then . else "" end
      | [split("[ \t\n]+"; "") | .[] | select(length > 0)]
      | (reduce .[] as $w ({skip: true, out: []};
           if .skip and ($w | test("^[A-Za-z_][A-Za-z0-9_]*=")) then . else {skip: false, out: (.out + [$w])} end) | .out)) as $tok
  | (if ($tok | length) > 0 then ($tok[0] | split("/") | last) else "" end) as $cmd0
  | (($in | if type == "object" then (.file_path // "") else "" end) | if type == "string" then split("/") | last else "" end) as $fbase
  | ($tok | map(select(startswith("+") | not))) as $t2
  | ((($t2[0] // "") | split("/") | last) == "cargo" and ($t2[1] // "") == "nextest") as $nextest
  | (if $tool == "Bash" and ($in.timeout | type) == "number" then $in.timeout / 1000
     elif ($envt | test("^[0-9]+$")) then ($envt | tonumber) / 1000
     else $k.default_tool_timeout_s end) as $tmo
  | (if $tool == "Agent" or $tool == "Task" then $k.deadline_clamp_s
     elif $nextest then ([$tmo, $k.nextest_budget_s + $k.compile_allowance_s] | min)
     else ([$tmo, $k.deadline_clamp_s] | min) end) as $dl
  | (if $mode == "stop" then "Stop"
     elif $cmd0 != "" then $tool + ":" + $cmd0
     elif $fbase != "" then $tool + ":" + $fbase
     else $tool end) as $what
  | (.tool_use_id // null) as $call
  | [ ($call // ""), (.session_id // ""), $k.tick_s, ($now + $dl),
      ({v: 1, ts: ($now | todate), msg: (("heartbeat " + $mode + " " + $tool) | rtrimstr(" ")), phase: "coder",
        what: $what, pid: $pid,
        since: (if $mode == "pre" then $now else null end),
        deadline: (if $mode == "pre" then $now + $dl else null end),
        call: $call} | tojson) ]
  | .[]' 2>/dev/null)
[ "${#out[@]}" -eq 5 ] || exit 0
call=${out[0]} sid=${out[1]} tick=${CODER_HB_TICK_S:-${out[2]}} deadline=${out[3]} line=${out[4]}

mkdir -p "$(dirname "$target")" 2>/dev/null
printf '%s\n' "$line" >> "$target" 2>/dev/null

safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

# end the ticker of one call: marker, exact-pid TERM (only if it is still a ticker), cleanup
end_ticker() {
    local c=$1 pf="$T/coder-hb-$1.pid" dn="$T/coder-hb-$1.done" tp
    if [ -r "$pf" ]; then
        read -r tp < "$pf" 2>/dev/null
        : > "$dn" 2>/dev/null
        if [ -n "$tp" ] && tr '\0' ' ' < "/proc/$tp/cmdline" 2>/dev/null | grep -q 'coder-hb-ticker'; then
            kill "$tp" 2>/dev/null
        else
            rm -f "$dn"
        fi
        rm -f "$pf"
    fi
}

case "$mode" in
pre)
    [ -n "$call" ] || exit 0
    c=$(safe "$call"); s=$(safe "$sid")
    [ -n "$s" ] && printf '%s\n' "$c" >> "$T/coder-hb-session-$s.list" 2>/dev/null
    rm -f "$T/coder-hb-$c.done"
    setsid bash -c '
        pf=$1; dn=$2; tgt=$3; pid=$4; dl=$5; tick=$6; line=$7
        echo $$ > "$pf"
        trap "kill \$sp 2>/dev/null; rm -f \"$dn\"; [ \"\$(cat \"$pf\" 2>/dev/null)\" = \$\$ ] && rm -f \"$pf\"; exit 0" TERM
        while :; do
            sleep "$tick" & sp=$!; wait $sp
            [ -e "$dn" ] && break
            kill -0 "$pid" 2>/dev/null || break
            now=$(printf "%(%s)T" -1); [ "$now" -lt $((dl + 60)) ] || break
            jq -c --argjson now "$now" ".ts = (\$now | todate) | .msg |= sub(\"pre\"; \"tick\")" <<< "$line" >> "$tgt" 2>/dev/null
        done
        rm -f "$dn"; [ "$(cat "$pf" 2>/dev/null)" = $$ ] && rm -f "$pf"
    ' coder-hb-ticker "$T/coder-hb-$c.pid" "$T/coder-hb-$c.done" "$target" "$pid" "$deadline" "$tick" "$line" \
        </dev/null >/dev/null 2>&1 &
    echo $! > "$T/coder-hb-$c.pid" 2>/dev/null
    disown 2>/dev/null
    ;;
post)
    [ -n "$call" ] && end_ticker "$(safe "$call")"
    ;;
stop)
    s=$(safe "$sid"); lf="$T/coder-hb-session-$s.list"
    if [ -n "$s" ] && [ -r "$lf" ]; then
        while read -r c; do [ -n "$c" ] && end_ticker "$c"; done < "$lf"
        rm -f "$lf"
    fi
    ;;
esac
exit 0
