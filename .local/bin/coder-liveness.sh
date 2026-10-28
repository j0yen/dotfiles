#!/usr/bin/env bash
# coder-liveness.sh WT_SLUG — newest nested jsonl FILE mtime for a wm-build coder worktree (ctl 66c5).
# A directory mtime does not track writes to files nested below it (r7 read 19:51 while the 503 coder wrote 8:23 PM),
# so this reads file mtimes only, recursively.
set -u
usage() {
  cat <<'U'
usage: coder-liveness.sh WT_SLUG
  Prints: coder-liveness slug=<slug> newest=<path> mtime=<iso8601> age_s=<n> files=<count>
  Root:   ${CODER_LIVENESS_ROOT:-$HOME/.claude/projects}/-home-jsy--local-state-wm-build-wt-<slug>/
  Exit:   0 ok · 3 root missing · 4 no jsonl files · 64 usage
U
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -eq 1 ] && [ -n "$1" ] || { usage >&2; exit 64; }
slug="$1"
# Claude encodes the cwd path by turning every non-alphanumeric, non-dash char into '-'.
enc="$(printf '%s' "$slug" | tr -c 'A-Za-z0-9-' '-')"
root="${CODER_LIVENESS_ROOT:-$HOME/.claude/projects}/-home-jsy--local-state-wm-build-wt-${enc}"
[ -d "$root" ] || { echo "coder-liveness: root missing: $root" >&2; exit 3; }
# newest FILE mtime + count in one pass (never a directory mtime)
read -r newest_t count newest < <(find "$root" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | awk 'NR==1{t=$1; $1=""; sub(/^ /,""); p=$0} END{print (NR?t:0), NR, p}')
if [ "${count:-0}" -eq 0 ]; then echo "coder-liveness: no jsonl files under $root" >&2; exit 4; fi
t="${newest_t%.*}"
now="$(date +%s)"
printf 'coder-liveness slug=%s newest=%s mtime=%s age_s=%s files=%s\n' \
  "$slug" "$newest" "$(date -d "@$t" --iso-8601=seconds)" "$((now - t))" "$count"
