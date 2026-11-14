#!/usr/bin/env bash
# Test: ctl-launch.sh --seat: ctl and ops are one identity (WM_SEAT=ctl, tmux `aide`, ~/.cache/aide); bld/rls get their own WM_SEAT, wake dir and tmux session; bad seat refused.
set -u
d=$(mktemp -d); export HOME="$d/home"; mkdir -p "$HOME/.config/environment.d" "$HOME/.config/wm-decide"
printf '%s\n' '{"ctl":{"model":"claude-sonnet-5-5","effort":"medium"}}' > "$HOME/.config/wm-decide/seat-model-hold.json"
printf 'CLAUDE_CODE_OAUTH_TOKEN=fixture-not-a-token\n' > "$HOME/.config/environment.d/90-claude-oauth.conf"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$HOME" > "$d/cj"
printf '#!/bin/sh\necho "SEAT=$WM_SEAT WAKE=${AIDE_WAKE_DIR:-}"\n' > "$d/stub"; chmod +x "$d/stub"
printf '#!/bin/sh\necho "TMUX-ARGS $*"\n' > "$d/tmux"; chmod +x "$d/tmux"
L="$(dirname "$0")/../.local/bin/ctl-launch.sh"; fail=0
run() { AIDE_CLAUDE_JSON="$d/cj" AIDE_CLAUDE_BIN="$d/stub" "$L" "$@" --model claude-sonnet-5-5 2>&1; }
chk() { grep -q "$2" <<<"$1" && echo "PASS $3" || { echo "FAIL $3: $1"; fail=1; }; }
chk "$(run)" 'SEAT=ctl WAKE=$' default-ctl
chk "$(run --seat ops)" 'SEAT=ctl WAKE=$' ops-is-ctl
chk "$(run --seat bld)" "SEAT=bld WAKE=$HOME/.cache/bld" bld-own-seat-and-wake
chk "$(run --seat rls)" "SEAT=rls WAKE=$HOME/.cache/rls" rls-own-seat-and-wake
o=$(env -u TMUX -u TMUX_PANE AIDE_TMUX=1 AIDE_TMUX_BIN="$d/tmux" AIDE_CLAUDE_JSON="$d/cj" AIDE_CLAUDE_BIN="$d/stub" "$L" --seat bld --model claude-sonnet-5-5 2>&1)
chk "$o" 'new-session -s bld .*--seat bld' bld-own-tmux-session
o=$(env -u TMUX -u TMUX_PANE AIDE_TMUX=1 AIDE_TMUX_BIN="$d/tmux" AIDE_CLAUDE_JSON="$d/cj" AIDE_CLAUDE_BIN="$d/stub" "$L" --seat ops --model claude-sonnet-5-5 2>&1)
chk "$o" 'new-session -s aide ' ops-keeps-aide-tmux
"$L" --seat nope >/dev/null 2>&1; [ $? = 64 ] && echo "PASS bad-seat-refused" || { echo "FAIL bad-seat-refused"; fail=1; }
rm -rf "$d"; exit $fail
