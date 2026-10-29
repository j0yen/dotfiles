#!/usr/bin/env bash
# Provenance only: the 30 most frequent keyword SHAPES in the real ledger = keywords minus the v2 stopwords
# (base list + seat event events wait lets status) and 20xx year tokens, sorted, >= 2 keywords left, counted.
# usage: summa-hub-coverage-gen.sh <ledger>
jq -r --arg stop "the this that with from what when where which does have about into your should would could there their they them then than also just like make need want some more only very been were will seat event events wait lets status" '
  select(.keywords != null)
  | ($stop | split(" ")) as $sw
  | [.keywords[] | select((. as $k | $sw | index($k) | not) and (test("^20[0-9][0-9]$") | not))]
  | select(length >= 2) | sort | join(" ")' "$1" | sort | uniq -c | sort -rn | head -30
