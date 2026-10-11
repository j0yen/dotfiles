#!/usr/bin/env bash
# handoff-lint.sh <prose-file> — advisory (PRD dotfiles-handoff-generated R6).
# Prints one `line N restates <source> <key>` for each line of the prose handoff
# that copies a fact handoff-gen.sh already generates. Always exits 0.
set -uo pipefail
f="${1:-}"
[ -r "$f" ] || exit 0
# pattern<TAB>source<TAB>key — one row per generated-fact shape
rules=$(printf '%s\t%s\t%s\n' \
  'max_runs [0-9]'                       effective_config max_runs \
  'parallelism [0-9]'                    effective_config parallelism \
  'run [0-9]{3}\b.*(stage|outcome)'      runs 'stage/outcome' \
  'v?0\.[0-9]+\.[0-9]+ (live|LIVE|tagged)' versions version \
  'cordon [0-9]+'                        decisions cordon \
  'decision [0-9]+ (open|closed)'        decisions 'open/closed')
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  while IFS=$'\t' read -r pat src key; do
    if grep -qE -- "$pat" <<<"$line"; then
      printf 'line %d restates %s %s — drop it\n' "$n" "$src" "$key"
      break # one report per prose line, first matching rule wins
    fi
  done <<<"$rules"
done <"$f"
exit 0
