#!/usr/bin/env bash
# fleet-serve-inventory (A255): every served artifact has a row, every row's deploy unit exists (dotfiles unit dir or declared host-units.tsv),
# and the committed artifacts.tsv matches the generator.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
G="$here/.local/bin/fleet-serve-inventory.sh"; T="$here/.config/fleet-serve/artifacts.tsv"; H="$here/.config/fleet-serve/host-units.tsv"
U="$here/.config/systemd/user"
gen="$("$G" --tsv)"
[ "$gen" = "$(cat "$T")" ] && ok "artifacts.tsv matches generator" || bad "artifacts.tsv drifted (regenerate: $G --tsv > $T)"
# the served set; a new served artifact must be added here and in the generator
for id in fleet-dash wm-build dotfiles-carbon dotfiles-redbaron dotfiles-ryzen7 memory-sync synthorg-config mcphost-prod; do
  awk -F'\t' -v i="$id" '$1==i{f=1} END{exit !f}' <<<"$gen" && ok "row for $id" || bad "served artifact $id has no row"
done
while IFS=$'\t' read -r id host art ref unit field alarm; do
  case "$id" in '#'*|'') continue ;; esac
  for v in "$host" "$art" "$ref" "$unit" "$field" "$alarm"; do [ -n "$v" ] || { bad "$id has an empty column"; break; }; done
  case "$unit" in
    spec:*) echo "PENDING $id unit $unit" ;;
    *) if [ -e "$U/$unit" ] || [ -d "$U/$unit.d" ] || awk -F'\t' -v h="$host" -v u="$unit" '$1==h&&$2==u{f=1} END{exit !f}' "$H"; then ok "$id unit $unit exists"; else bad "$id unit $unit not found on $host"; fi ;;
  esac
done <<<"$gen"
n="$("$G" --alarms | wc -l)"; r="$(grep -vc '^#' <<<"$gen")"
[ "$n" = "$r" ] && ok "alarms rows = artifact rows ($n)" || bad "alarms rows $n != $r"
# negative: a row whose unit is missing must fail the lookup
awk -F'\t' -v h=carbon -v u=no-such.timer '$1==h&&$2==u{f=1} END{exit f}' "$H" && [ ! -e "$U/no-such.timer" ] && ok "missing unit is detected" || bad "negative fixture"
exit $fail
