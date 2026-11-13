#!/usr/bin/env python3
"""TEST-ONLY entrypoint for worker-route.py (review 4, seams). The production script is run as `__main__` and has NO test seams: no env var, argument or file can
move its state root, host, ask executable, launchers, hold gate, start client or unit probe. The seams exist only when the module is IMPORTED (not `__main__`)
AND WR_TEST_SEAMS=1; this harness is the importer for every test that runs the route as a program (and as the unit's supervisor, via the WR_SELF seam).
WR_SRC names another copy of worker-route.py (the nonce copy, mutants); default = this clone's .local/bin/worker-route.py."""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
SRC = os.environ.get("WR_SRC") or os.path.join(HERE, "..", "..", ".local", "bin", "worker-route.py")
spec = importlib.util.spec_from_file_location("worker_route", SRC)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.SELF = os.environ.get("WR_SELF") or os.path.realpath(__file__)      # the unit's supervisor is this harness, never the seam-less production script (which would use the real home)
sys.exit(m.main(sys.argv))
