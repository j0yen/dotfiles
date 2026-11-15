#!/usr/bin/env bash
# tests/dpms_live.sh — install readback for PRD dream-prd-marker-per-session
# (AC 8). Run by the host seat after its ~/dotfiles holds the landed commit:
#
#   bash ~/dotfiles/tests/dpms_live.sh
#   git -C ~/dotfiles show origin/main:tests/dpms_live.sh | bash   # before install
#
# Resolves the INSTALLED hook $HOME/.claude/hooks/prd-write-gate.sh with
# readlink -f, prints `hook=<resolved path> sha256=<digest>`, then runs two
# probes through `bash <resolved path>` (so a readable non-executable file is
# probed, never 126), each in a fresh temporary HOME holding a fresh legacy
# ~/.claude/.dream-active, with SKILL_MARKER_DIR exported inside that HOME and
# DREAM_TTL_MIN unset: `empty` (empty marker directory) and `foreign`
# (dream-prd.other and dream.other present). One line per probe:
# `probe=<empty|foreign> verdict=<deny|admit>`; a probe that prints no deny
# decision, including a gate that exits non-zero, counts as admit.
#
# Exit 0  both probes deny (the per-session gate is installed)
#      7  not-installed: a probe admits and the digest is the 61d0c6a2 gate
#      8  a probe admits under any other digest
#      2  usage: jq absent, hook path unresolvable / not a readable regular
#         file, temporary HOME not creatable (no probe line printed)
# A missing script is bash's own 127, not an exit of this script. Reads
# nothing from its own stdin, reads the checkout and updates nothing. Its
# exits are proven by tests/dpms_ac08_live_script.test.sh (R5(e)).
set -uo pipefail

OLD_SHA=cf9bee6ab7d9143bbfaedd03ae0c926a6a89cd8885e1152302f63e0fcc1e6915

command -v jq >/dev/null 2>&1 || { echo "dpms_live: jq not on PATH" >&2; exit 2; }
LINK="$HOME/.claude/hooks/prd-write-gate.sh"
HOOK=$(readlink -f "$LINK" 2>/dev/null </dev/null) || HOOK=""
if [ -z "$HOOK" ] || [ ! -f "$HOOK" ] || [ ! -r "$HOOK" ]; then
    echo "dpms_live: $LINK resolves to no readable regular file" >&2
    exit 2
fi
SHA=$(sha256sum "$HOOK" </dev/null | cut -d' ' -f1)
[ -n "$SHA" ] || { echo "dpms_live: cannot hash $HOOK" >&2; exit 2; }

SCRATCH=$(mktemp -d 2>/dev/null </dev/null) || { echo "dpms_live: cannot create a temporary HOME" >&2; exit 2; }
trap 'rm -rf "$SCRATCH"' EXIT
for p in empty foreign; do
    h="$SCRATCH/$p"
    mkdir -p "$h/.claude/state/skill-active" "$h/.cache" "$h/proj/build-queue" \
        && touch "$h/.claude/.dream-active" \
        || { echo "dpms_live: cannot create a temporary HOME" >&2; exit 2; }
done
touch "$SCRATCH/foreign/.claude/state/skill-active/dream-prd.other" \
      "$SCRATCH/foreign/.claude/state/skill-active/dream.other" \
    || { echo "dpms_live: cannot create a temporary HOME" >&2; exit 2; }

echo "hook=$HOOK sha256=$SHA"

admitted=0
for p in empty foreign; do
    h="$SCRATCH/$p"
    input=$(jq -cn --arg p "$h/proj/build-queue/PRD-dpms-live-probe.md" \
        '{session_id:"dpms-live-probe",tool_name:"Write",tool_input:{file_path:$p,content:"x"}}' </dev/null)
    out=$(printf '%s' "$input" | env -u DREAM_TTL_MIN HOME="$h" SKILL_MARKER_DIR="$h/.claude/state/skill-active" \
        bash "$HOOK" 2>/dev/null)
    rc=$?
    if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
        verdict=deny
    else
        verdict=admit; admitted=1
    fi
    echo "probe=$p verdict=$verdict"
done

if [ "$admitted" = 0 ]; then echo "verdict=installed"; exit 0; fi
if [ "$SHA" = "$OLD_SHA" ]; then echo "verdict=not-installed"; exit 7; fi
echo "verdict=admit-unknown-gate"
exit 8
