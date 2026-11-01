#!/usr/bin/env bash
# Coders run Sonnet at medium effort (Joe 10-24 "change coder agents to use Sonnet Medium").
# Guards both coder launchers: the Agent-tool `coder` definition and the rb seat's headless rb-run-coder.sh.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
A="$here/.claude/agents/coder.md"
fm=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$A")
if printf '%s\n' "$fm" | grep -qx 'model: sonnet' && printf '%s\n' "$fm" | grep -qx 'effort: medium'; then echo "ok - coder.md frontmatter = model: sonnet + effort: medium"
else echo "NOT OK - coder.md frontmatter lacks model: sonnet / effort: medium"; fail=1; fi
R="$here/.local/bin/rb-run-coder.sh"
if grep -v '^[[:space:]]*#' "$R" | grep -E 'claude -p ' | grep -q -- '--model "$model" --effort "$effort"' && grep -qF 'model="${RB_CODER_MODEL:-sonnet}"; case "$model" in sonnet) effort=medium ;; opus) effort=high ;;' "$R"; then echo "ok - rb-run-coder.sh: sonnet (default) -> medium, opus -> high"
else echo "NOT OK - rb-run-coder.sh model/effort mapping (sonnet=medium, opus=high) missing"; fail=1; fi
O="$here/.claude/agents/coder-opus.md"
ofm=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$O" 2>/dev/null)
if printf '%s\n' "$ofm" | grep -qx 'name: coder-opus' && printf '%s\n' "$ofm" | grep -qx 'model: opus' && printf '%s\n' "$ofm" | grep -qx 'effort: high'; then echo "ok - coder-opus.md frontmatter = model: opus + effort: high"
else echo "NOT OK - coder-opus.md frontmatter lacks name/model: opus/effort: high"; fail=1; fi
# Opus escalation (Joe 10-24 "Switch to Opus 5.5 when tackling ambiguous multi-file refactors…"): only sonnet|opus admitted; a bad value exits 78 before any gate.
out=$(RB_CODER_MODEL=haiku bash "$R" t /dev/null 2>&1); rc=$?
if [ "$rc" = 78 ]; then echo "ok - RB_CODER_MODEL=haiku refused rc=78"; else echo "NOT OK - RB_CODER_MODEL=haiku rc=$rc ($out)"; fail=1; fi
if grep -q 'ESCALATE: opus' "$A"; then echo "ok - coder.md carries the repair-loop ESCALATE: opus stop"; else echo "NOT OK - coder.md lacks ESCALATE: opus"; fail=1; fi
C="$here/.claude/CLAUDE.md"
if grep -q '| coder-opus | opus, high effort' "$C" && grep -q 'coder `ESCALATE: opus` gets one opus re-dispatch' "$C"; then echo "ok - CLAUDE.md routes hard coder work + ESCALATE to one opus re-dispatch"; else echo "NOT OK - CLAUDE.md opus coder row/escalation line missing"; fail=1; fi
exit $fail
