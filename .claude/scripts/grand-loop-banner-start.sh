#!/usr/bin/env bash
# grand-loop-banner-start.sh — SessionStart hook wrapper for
# grand-loop-banner.sh (PRD-grand-loop-liveness-contract Requirement 3).
# Every node that installs this dotfiles repo gets this hook via
# settings.json, which is how the banner reaches "every node" without a
# per-host install step. Silent (exit 0) if the banner script isn't
# installed yet (e.g. install.sh hasn't run on this node).
set -uo pipefail

BANNER="$HOME/.local/bin/grand-loop-banner.sh"
[ -x "$BANNER" ] || exit 0

"$BANNER"
