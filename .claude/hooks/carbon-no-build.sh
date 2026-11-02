#!/usr/bin/env bash
# carbon-no-build.sh — PreToolUse hook (Bash|Edit|Write|MultiEdit|NotebookEdit|Agent), ALL models, EVERY Claude session on
# carbon (aide, seats, ctl, Joe's plain `claude`): carbon is for administration and monitoring; nothing is built, tested or coded
# there (Joe 10-27 11:0x AM "Carbon is for administration and monitoring. Nothing should be built nor coded on carbon", approvals #47).
# Acts only when `hostname -s` (via PATH) is carbon. Classifier = carbon-no-build.py. This hook owns cargo/rustc on carbon too
# (cargo-block-carbon.sh stays untouched; a double deny is harmless). NO escape hatch: no file, no env var. A bypass is Joe's own
# shell outside Claude.
set -u
[ "$(hostname -s 2>/dev/null)" = "carbon" ] || exit 0
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
verdict=$(python3 -I "$here/carbon-no-build.py" 2>/dev/null)
case "$verdict" in deny\ *) ;; *) exit 0 ;; esac
echo "carbon-no-build: ${verdict#deny } denied on carbon; run on redbaron/ryzen7 over ssh (CLAUDE.md § Hosts)" >&2
exit 2
