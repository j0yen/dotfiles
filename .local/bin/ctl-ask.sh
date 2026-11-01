#!/usr/bin/env bash
# wrapper kept so the controller's existing instructions work: ctl-ask.sh "<text>" = seat-ask.sh ctl "<text>"
exec "$HOME/.local/bin/seat-ask.sh" ctl "$@"
