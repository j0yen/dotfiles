#!/bin/bash
# rb-reprice-watch-decide.sh - wm-decide capped at `timeout 10` (rwh3 E6): rb-reprice-watch points WP_DECIDE_BIN here so a hung
# wm-decide record can never stall a pressure pause. A timeout exits 124; the lib treats any non-zero record rc as "write proceeds,
# the outbox keeps the row for the puller". RW_DECIDE_REAL / RW_DECIDE_TIMEOUT exist for the test only.
exec timeout "${RW_DECIDE_TIMEOUT:-10}" "${RW_DECIDE_REAL:-wm-decide}" "$@"
