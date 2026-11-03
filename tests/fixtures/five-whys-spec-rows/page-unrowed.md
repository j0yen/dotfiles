# Question
fixture (A684): a copy of the 10-30 ryzen7 disk-low page Mechanisms section

# Mechanisms
1. Shared verify-leg lib `r7-verify-leg.sh` (source'd by every r7-wmb-*/r7-syn-*/mcphost hand leg): exports `CARGO_PROFILE_DEV_DEBUG=0 CARGO — owner r7 — state SPEC (A901)
2. Hand-target reaper: r7-hand-target-purge extended to `~/.cache/tmp/*` and `/mnt/ssd/r7-legs/*` with no live process holding a path inside — owner r7 — state SPEC (A902)
3. Disk bell with a lever: r7-mon-host `df-root` at ≥ 95 % runs the purge (mechanism 2) itself and names the top-3 writers (`du -sh ~/.cache — owner r7 — state SPEC (no row named)
4. Measured premise for (b): one leg on `/mnt/ssd` with `TARGET-PEAK` and wall time beside the same leg on /; the lib defaults to /mnt/ssd o — owner r7 — state LIVE
5. The 10-09 page's unbuilt weakest link, for daemon runs: `CARGO_PROFILE_TEST_DEBUG=0` + `CARGO_INCREMENTAL=0` in the wm-build inner/gate e — owner r7 — state LIVE

# Fair record
fixture
