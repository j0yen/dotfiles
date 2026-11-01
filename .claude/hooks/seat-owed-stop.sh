#!/usr/bin/env bash
# Stop hook (A49 D2, on D1's seat-owed.sh): a seat (WM_SEAT rb|r7|ctl|aide) may not end a turn while it has OVERDUE follow-up ids
#   its final assistant message neither cites in full nor shows as cleared.
# Overdue ids: the first M ids of the `OVERDUE <seat>:` line (M = `overdue M` on the `OWED` line; escalated ids come first) plus every id on
#   the `ASKS <seat>: overdue` line; at most the 5 oldest are required, and the reason names the uncited ones in one line.
# Cleared: the message carries `FOLLOWUPS <seat> owed <n>-><n>`.  Loop guard: stop_hook_active true = allow.
# Final message: stdin .last_assistant_message, else the last assistant text in .transcript_path.
# No WM_SEAT, other seat, no overdue ids, or seat-owed.sh missing / failing = exit 0 (failures warn on stderr); this hook never blocks on its own failure.
# Env: SEAT_OWED_BIN (default: seat-owed.sh on PATH, else ~/.local/bin/seat-owed.sh).
set -u
seat="${WM_SEAT:-}"
case "$seat" in rb|r7|ctl|aide) ;; *) exit 0 ;; esac
in="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || { echo "seat-owed-stop: jq missing, allowing" >&2; exit 0; }
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null)" = true ] && exit 0
bin="${SEAT_OWED_BIN:-}"
[ -n "$bin" ] || bin="$(command -v seat-owed.sh 2>/dev/null || true)"
[ -n "$bin" ] || bin="$HOME/.local/bin/seat-owed.sh"
[ -x "$bin" ] || { echo "seat-owed-stop: seat-owed.sh not found, allowing" >&2; exit 0; }
out="$(timeout 25 "$bin" "$seat" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || { echo "seat-owed-stop: seat-owed.sh exit $rc, allowing" >&2; exit 0; }
m="$(sed -n "s/^OWED $seat: owed [0-9]*, overdue \([0-9]*\),.*/\1/p" <<<"$out" | head -1)"
ids=""
if [[ "${m:-}" =~ ^[0-9]+$ ]] && [ "$m" -gt 0 ]; then
  ids="$(sed -n "s/^OVERDUE $seat: //p" <<<"$out" | head -1 | tr -s ' ' '\n' | head -n "$m")"
fi
asks="$(sed -n "s/^ASKS $seat: overdue //p" <<<"$out" | head -1 | tr -s ' ' '\n')"
ids="$(printf '%s\n%s\n' "$ids" "$asks" | awk 'NF && !seen[$0]++' | head -5)"
[ -n "$ids" ] || exit 0
msg="$(jq -r '.last_assistant_message // empty' <<<"$in" 2>/dev/null)"
if [ -z "$msg" ]; then
  tp="$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)"
  if [ -n "$tp" ] && [ -r "$tp" ]; then
    msg="$(jq -rs '[.[] | select(.type=="assistant")] | last | [.message.content[]? | select(.type=="text") | .text] | join("\n")' "$tp" 2>/dev/null)"
  fi
fi
grep -Eq "FOLLOWUPS $seat owed [0-9]+->[0-9]+" <<<"$msg" && exit 0
missing=""
while IFS= read -r id; do
  grep -qF -- "$id" <<<"$msg" || missing="$missing $id"
done <<<"$ids"
[ -n "$missing" ] || exit 0
reason="Seat $seat has overdue follow-ups the final message does not cite:${missing}. Cite each id in full with what was done, or print 'FOLLOWUPS $seat owed <n>-><n>'."
jq -nc --arg r "$reason" '{decision:"block",reason:$r}'
exit 0
