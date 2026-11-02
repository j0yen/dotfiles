#!/usr/bin/env bash
# fleet-serve-inventory (A255, mechanism 7 of the fleet-dash stale-carbon-tree five-whys): one row per served artifact.
# Usage: fleet-serve-inventory.sh [--tsv | --alarms]   (default --tsv; redirect into ~/.config/fleet-serve/artifacts.tsv)
# --tsv    artifacts.tsv: id host artifact source_ref deploy_unit version_field drift_alarm
# --alarms rows for the A238 gen/alarms.json contract (JSON lines: alarm, field, host, unit)
# A deploy_unit "spec:<A-id>" names a unit not yet built; the test reports it as pending.
set -euo pipefail
rows() {
  cat <<'ROWS'
fleet-dash	carbon	fleet-dash collector + index.html	j0yen/fleet-dash@main	spec:A248-fleet-dash-deploy.timer	dash.version	dash-version-drift
wm-build	orch	wm-build binary	j0yen/wm-build@main	wm-build-shim-check.timer	wm_build.version	wm-build-version-drift
dotfiles-carbon	carbon	dotfiles symlinks	j0yen/dotfiles@main	dotfiles-hook-sync.timer	dotfiles.version.carbon	dotfiles-version-drift
dotfiles-redbaron	redbaron	dotfiles symlinks	j0yen/dotfiles@main	dotfiles-hook-sync.timer	dotfiles.version.redbaron	dotfiles-version-drift
dotfiles-ryzen7	ryzen7	dotfiles symlinks	j0yen/dotfiles@main	dotfiles-hook-sync.timer	dotfiles.version.ryzen7	dotfiles-version-drift
memory-sync	carbon	memory-sync installer	j0yen/dotfiles@main	spec:A255-memory-sync-unit	memory_sync.version	memory-sync-version-drift
synthorg-config	ryzen7	synthorg config	j0yen/dotfiles@main	spec:A255-synthorg-config-unit	synthorg_config.version	synthorg-config-version-drift
mcphost-prod	mcphost-1	mcphost prod binary	j0yen/mcphost@main	mcphost-deploy-release.service	mcphost.version	mcphost-version-drift
ROWS
}
case "${1:---tsv}" in
  --tsv) printf '# id\thost\tartifact\tsource_ref\tdeploy_unit\tversion_field\tdrift_alarm\n'; rows ;;
  --alarms) rows | awk -F'\t' '{printf "{\"alarm\":\"%s\",\"field\":\"%s\",\"host\":\"%s\",\"unit\":\"%s\"}\n",$7,$6,$2,$5}' ;;
  *) echo "usage: $0 [--tsv|--alarms]" >&2; exit 2 ;;
esac
