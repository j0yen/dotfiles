#!/usr/bin/env bash
# operator-notices.sh — UserPromptSubmit hook (PRD dotfiles-operator-status-card R4).
# Prints every $OPERATOR_CACHE_DIR/notices/*.txt in name order, then deletes
# them; a notice older than 24 h is deleted unread. Silent when empty.
# Fail-open: always exits 0.
dir="${OPERATOR_NOTICES_DIR:-${OPERATOR_CACHE_DIR:-$HOME/.cache/operator}/notices}"
[ -d "$dir" ] || exit 0
find "$dir" -maxdepth 1 -name '*.txt' -type f -mmin +1440 -delete 2>/dev/null
export LC_ALL=C
for f in "$dir"/*.txt; do
  [ -f "$f" ] || continue
  cat "$f" 2>/dev/null
  rm -f "$f" 2>/dev/null
done
exit 0
