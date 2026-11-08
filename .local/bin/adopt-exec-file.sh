#!/usr/bin/env bash
# A1296/A1346 W3: install ONE reviewed executable (hook, evaluator, script) with an explicit mode, atomically, and prove the direct entrypoint runs.
# usage: adopt-exec-file.sh <src> <dest> [mode=755]
# Same-directory temp + chmod before rename (no window at the wrong mode); an existing dest is copied to <dest>.bak-<epoch> first (bytes + mode kept for rollback);
# no other file in the tree is touched. A dest that is not directly executable afterwards = exit 3 and the backup is restored, never a silent pass (`bash hook` would hide it).
set -u
src="${1:-}"; dest="${2:-}"; mode="${3:-755}"
[ -f "$src" ] && [ -n "$dest" ] || { echo "usage: adopt-exec-file.sh <src> <dest> [mode]" >&2; exit 64; }
case "$mode" in [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;; *) echo "adopt-exec-file: bad mode $mode" >&2; exit 64;; esac
bak=""
if [ -e "$dest" ]; then bak="$dest.bak-$(date +%s)"; cp -p "$dest" "$bak" || exit 2; fi
tmp="$(mktemp "$(dirname "$dest")/.adopt.XXXXXX")" || exit 2
cp "$src" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; echo "adopt-exec-file: install failed" >&2; exit 2; }
if [ ! -x "$dest" ]; then
  echo "adopt-exec-file: $dest not directly executable (mode $(stat -c %a "$dest"))" >&2
  [ -n "$bak" ] && mv -f "$bak" "$dest"
  exit 3
fi
echo "adopted $dest mode $(stat -c %a "$dest")${bak:+ backup $bak}"
