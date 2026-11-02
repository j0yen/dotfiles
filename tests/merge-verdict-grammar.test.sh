#!/usr/bin/env bash
# merge-verdict-grammar.sh: format -> parse round trip, refusals, and the four real `what` shapes seen in the ledger (only the canonical one parses). No network, no ledger.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
. "$here/.local/lib/merge-verdict-grammar.sh"
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
H="7b5d87787ea9bd9368a4ebb3906e293edc4dd3c2"; H2="c98cba51221a5c19c80c4eb13795c88e13dd923e"

# round trip
p="$(mvg_format j0yen/mcphost 541 "$H" aide-verifier-v541)" && ok format-ok || bad format-ok
[ "$p" = "MERGE-OK j0yen/mcphost#541 COMMIT=$H agent=verifier:aide-verifier-v541" ] && ok format-exact || bad "format-exact: $p"
out="$(mvg_parse "$p free text after")" && [ "$out" = "j0yen mcphost 541 $H aide-verifier-v541" ] && ok roundtrip || bad "roundtrip: $out"
out="$(mvg_parse "$p")" && ok parse-no-free-text || bad parse-no-free-text
out="$(mvg_parse "$(printf '%s ok\nsecond line COMMIT=%s' "$p" "$H2")" 2>&1)" && bad multiline-extra-commit-accepted || ok multiline-extra-commit-refused

# format refusals
mvg_format j0yen/mcphost 541 "${H:0:12}" aide-verifier-v1 >/dev/null 2>&1 && bad format-short-sha || ok format-short-sha-refused
mvg_format mcphost 541 "$H" aide-verifier-v1 >/dev/null 2>&1 && bad format-no-owner || ok format-no-owner-refused
mvg_format j0yen/mcphost 54x "$H" aide-verifier-v1 >/dev/null 2>&1 && bad format-pr-nonnumeric || ok format-pr-nonnumeric-refused
mvg_format j0yen/mcphost 541 "${H^^}" aide-verifier-v1 >/dev/null 2>&1 && bad format-upper-sha || ok format-upper-sha-refused
mvg_format j0yen/mcphost 541 "$H" v1 >/dev/null 2>&1 && bad format-bad-token || ok format-bad-token-refused

# parse refusals
r() { # label what -> must refuse
  if mvg_parse "$2" >/dev/null 2>&1; then bad "$1 parsed"; else ok "$1 refused"; fi
}
r two-commit "$p COMMIT=$H"
r two-agent "$p agent=verifier:rb-verifier-x"
r confirm-prefix "CONFIRM j0yen/mcphost#541 COMMIT=$H agent=verifier:aide-verifier-v541"
r no-agent "MERGE-OK j0yen/mcphost#541 COMMIT=$H scope=suite"
r no-owner "MERGE-OK mcphost#541 COMMIT=$H agent=verifier:aide-verifier-v541"
r short-commit "MERGE-OK j0yen/mcphost#541 COMMIT=${H:0:12} agent=verifier:aide-verifier-v541"
r upper-commit "MERGE-OK j0yen/mcphost#541 COMMIT=${H^^} agent=verifier:aide-verifier-v541"
r leading-space " $p"
r pr-zero "MERGE-OK j0yen/mcphost#0 COMMIT=$H agent=verifier:aide-verifier-v541"
r glued-commit "MERGE-OK j0yen/mcphost#541 COMMIT=${H}a agent=verifier:aide-verifier-v541"
r bad-agent-kind "MERGE-OK j0yen/mcphost#541 COMMIT=$H agent=verifier:coder-verifier-v541"
r empty ""

# the four real rows (verbatim prefixes) and a second-sha-in-free-text row
ra="CONFIRM dotfiles#157 MERGEABLE head=017841abbbf285a593d83ee801d5491062498888 checks fail=0 after a real merge of origin/main (1 conflicted files resolved: .claude/settings.json)"
rb="CONFIRM j0yen/dotfiles#176 head c98cba51221a MERGEABLE CLEAN on GitHub, base main; COMMIT=$H2; agent=verifier:aide-verifier-opus-1300; rb-merge may run under #194"
rc="CONFIRM mcphost#541 ci: ceiling-guard blocks the merge"
rd="MERGE-OK j0yen/mcphost#541 COMMIT=$H agent=verifier:aide-verifier-v541 CONFIRM: OPEN MERGEABLE CLEAN head 0123456789ab"
r row-a "$ra"; r row-b "$rb"; r row-c "$rc"
out="$(mvg_parse "$rd")" && [ "$out" = "j0yen mcphost 541 $H aide-verifier-v541" ] && ok row-d-parses || bad "row-d: $out"
[ "$fail" = 0 ] && echo "ALL PASS merge-verdict-grammar" || { echo "FAILED merge-verdict-grammar"; exit 1; }
