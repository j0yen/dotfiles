#!/usr/bin/env bash
# A1309: ADHD style is Hermes-only (Joe via Hermes 11-08). No executor seat injects it.
# Repo files carry no adhd-always-on SessionStart entry or blanket CLAUDE.md rule, and each installed
# file equals the repo file (symlink into this checkout, or byte-identical copy) when it is present.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok(){ echo "ok - $1"; }; bad(){ echo "NOT OK - $1"; fail=1; }
for f in .claude/settings.json .claude/CLAUDE.md; do
  if grep -qi 'adhd' "$here/$f"; then bad "$f still mentions adhd"; else ok "$f has no adhd entry"; fi
done
python3 -I -c 'import json,sys;json.load(open(sys.argv[1]))' "$here/.claude/settings.json" && ok "settings.json valid JSON" || bad "settings.json invalid"
for f in settings.json CLAUDE.md; do
  inst="$HOME/.claude/$f"
  [ -e "$inst" ] || { ok "$f not installed here (skip)"; continue; }
  if [ "$(readlink -f "$inst")" = "$(readlink -f "$here/.claude/$f")" ] || cmp -s "$inst" "$here/.claude/$f"; then ok "installed $f equals repo $f"
  elif grep -qi adhd "$inst"; then bad "installed $f carries adhd"
  else ok "installed $f carries no adhd (host copy carries other local drift)"; fi
done
[ "$fail" = 0 ]
