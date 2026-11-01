#!/usr/bin/env bash
# probe-gate exemption for Joe's own sessions: the aide (WM_SEAT=aide, exported
# only by aide-launch.sh) and a plain `claude` (no WM_SEAT, approvals #195 11-01)
# are NOT gated; a fleet seat (WM_SEAT=ctl/rb) IS gated (exit 2).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
gate="$here/.claude/hooks/probe-gate.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tr="$tmp/transcript.jsonl"
id="toolu_test_aide_exempt_01"
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-fable-5-1\",\"content\":[{\"type\":\"tool_use\",\"id\":\"$id\",\"name\":\"Bash\",\"input\":{\"command\":\"cat /etc/hostname\"}}]}}" > "$tr"
input="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat /etc/hostname\"},\"session_id\":\"s\",\"transcript_path\":\"$tr\",\"tool_use_id\":\"$id\"}"
fail=0
run() { # name expected_rc env...
    local name="$1" want="$2"; shift 2
    local rc=0
    printf '%s' "$input" | env -u WM_SEAT -u TMUX HOME="$tmp" "$@" bash "$gate" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "$want" ]; then echo "PASS $name (rc=$rc)"; else echo "FAIL $name (rc=$rc want $want)"; fail=1; fi
}
run aide-marker-exempt         0 PROBE_GATE_HOSTNAME=carbon WM_SEAT=aide
run aide-marker-exempt-anyhost 0 PROBE_GATE_HOSTNAME=redbaron WM_SEAT=aide
run plain-carbon-exempt        0 PROBE_GATE_HOSTNAME=carbon
run plain-tmux-exempt          0 PROBE_GATE_HOSTNAME=carbon TMUX=/tmp/tmux-1000/default,1,0
run plain-other-host-exempt    0 PROBE_GATE_HOSTNAME=redbaron
run seat-ctl-gated             2 PROBE_GATE_HOSTNAME=carbon WM_SEAT=ctl
run seat-rb-gated              2 PROBE_GATE_HOSTNAME=redbaron WM_SEAT=rb
grep -q '"${WM_SEAT:-}" = aide' "$gate" && echo "PASS gate-has-aide-predicate" || { echo "FAIL gate-has-aide-predicate"; fail=1; }
grep -q -- '-z "${WM_SEAT:-}"' "$gate" && echo "PASS gate-has-plain-predicate" || { echo "FAIL gate-has-plain-predicate"; fail=1; }
if sed 's/#.*//' "$gate" | grep -q 'hostname'; then echo "FAIL gate-still-reads-hostname"; fail=1; else echo "PASS gate-does-not-infer-aide-from-hostname"; fi
exit $fail
