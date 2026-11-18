#!/usr/bin/env bash
# gen-base-fixtures.sh: (re)writes this directory's f9066716 fixtures (A1300 E13 analysis route, AC 2). Deterministic, never by hand:
# the three files are git show of the base commit, each checked against its full sha256; the table is the FFDR generator
# (tests/fixtures/ffdr/gen-route-table.py, unchanged) run on those vendored bytes. Needs the base commit in the clone; writes only here.
# Run from anywhere: bash tests/fixtures/analysis-route/gen-base-fixtures.sh
set -euo pipefail
D="$(cd "$(dirname "$0")/../../.." && pwd)"; FX="$D/tests/fixtures/analysis-route"
B=f9066716b260e6ba14b8a7cca8ee27b35954555d
git -C "$D" cat-file -e "$B^{commit}"
vend(){ # repo path, fixture name, sha256
  git -C "$D" show "$B:$1" >"$FX/$2.tmp"
  [ "$(sha256sum <"$FX/$2.tmp" | cut -c1-64)" = "$3" ] || { echo "gen-base-fixtures: $1 at $B does not hash to $3" >&2; rm -f "$FX/$2.tmp"; exit 1; }
  mv "$FX/$2.tmp" "$FX/$2"; chmod 644 "$FX/$2"
}
vend .local/lib/skill-route-resolve.py f9066716-skill-route-resolve.py 088dd2ec89627541dda79ff08bc03d72b99d2a609a24aa62629fa487cb46d055
vend .config/skill-routing/policy.json f9066716-policy.json a5b27682b5787d4b12edc77e0e228e26d2cb2255d5c429a0345be859836bd388
vend .claude/hooks/analysis-page-gate.sh f9066716-analysis-page-gate.sh f11751ecf35a1d9b5ba106aa099a48ccb626bfc10d625b933eb3f5c8448d8a6a
python3 -I "$D/tests/fixtures/ffdr/gen-route-table.py" --policy "$FX/f9066716-policy.json" --resolver "$FX/f9066716-skill-route-resolve.py" \
  --source "j0yen/dotfiles $B" >"$FX/base-route-table.json"
