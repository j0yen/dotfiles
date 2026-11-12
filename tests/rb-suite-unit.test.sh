#!/usr/bin/env bash
# rb-suite-unit.test.sh - rb-suite-unit.sh --selftest: a suite/verifier unit starts with TasksMax=infinity + MemoryMax=infinity +
# IOWeight=50 (A1304; the 11-12 rb-sd-a1573-suite unit inherited the user slice's TasksMax 33183), writes EXIT=<rc>, and refuses bad input
# before systemd-run is called.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$here/../.local/bin/rb-suite-unit.sh" --selftest
