# FFDR route-table fixture (A1300 FFDR Phase 1, test T1)

`base-route-table.json` is the skill-routing resolution table of j0yen/dotfiles base commit `a244971e489bfa240782de5d56e023228bb9a48d`, generated on 2026-11-17 by `gen-route-table.py` (this directory) from that commit's own bytes. No row was written or edited by hand.

- Inputs at the base commit: `.config/skill-routing/policy.json` (sha256 `11a8a48c6b29b18a2f3ea26cc3a7d715dc901615f86d60ebe846cb421af0fc08`) and `.local/lib/skill-route-resolve.py` (sha256 `d44867bba8b9b4ca2fd928d3b6f8ea6eabbb631d5707e485d823a916d89a5ed0`). The table records both digests.
- Command, from the repository root (it writes nothing but the fixture and its own temporary directory):

      B=a244971e489bfa240782de5d56e023228bb9a48d; X="$(mktemp -d)"
      git show "$B:.config/skill-routing/policy.json" >"$X/policy.json"
      git show "$B:.local/lib/skill-route-resolve.py" >"$X/skill-route-resolve.py"
      python3 -I tests/fixtures/ffdr/gen-route-table.py --policy "$X/policy.json" --resolver "$X/skill-route-resolve.py" \
        --source "j0yen/dotfiles $B" >tests/fixtures/ffdr/base-route-table.json
      rm -rf "$X"

- Rows (61): for each governed skill, its baseline request, every class and every escalation reason (evidence `ledger:A1300`; the `max_exception` class carries a recorded exception with a ledger reference), then every review reason on the skill's first model-routed row. The generator's docstring defines each request. A row keeps the request, the resolver's exit code and its output, denied rows included.
- `tests/ffdr-route-table.test.sh` regenerates this file from the base commit when the commit is in the clone and requires the two byte-identical. It then compares the head table with this one: the only differences allowed are spec R1.3's four dream classes and the R1.4 review echo.
- The fixture belongs to this base commit. A different base needs a new fixture generated the same way.
