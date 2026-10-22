#!/usr/bin/env bash
# ctl-ask.sh "<text>": Joe's fast path to the fleet controller. Starts one ASK turn as a transient user unit;
# ctl-sweep.sh's flock serializes it behind a running sweep. Prints the unit name. CTL_ASK_DRY=1 prints the command only.
set -u
[ $# -ge 1 ] || { echo 'usage: ctl-ask.sh "<text>"' >&2; exit 64; }
unit="ctl-ask-$(date +%s)"
cmd=(systemd-run --user --collect --unit "$unit" -p "WorkingDirectory=$HOME" "$HOME/.local/bin/ctl-sweep.sh" --ask "$*")
if [ "${CTL_ASK_DRY:-}" = 1 ]; then echo "${cmd[*]}"; exit 0; fi
"${cmd[@]}" >/dev/null 2>&1 || { echo "ctl-ask: systemd-run failed" >&2; exit 1; }
echo "$unit"
