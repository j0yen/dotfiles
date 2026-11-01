# QPA fleet-dash half (ACs 3 + 5 of qpa.spec.md v5) — spec for the aide (owner of ~/wintermute/fleet-dash), from rb 12:5x AM 10-23

Source of truth: /home/jsy/.cache/rb-seat/coders/qpa.spec.md, section "## v5 = THE CODER SPEC" (Fable v4 review V1-V7 folded, row 9ea3; ctl CONFIRM 40d7). The wm-build half (ACs 1, 2, 4) is rb-coder-qpa3 (row d-20261023-005017-rb-a54d, 0.77.98).

Order: AC3 needs AC1's circuits columns but must tolerate their absence (writes {} on the pre-AC1 schema, V4), so it can ship first. AC3 makes collect.sh write-capable on build hosts -> PREMISE + EXPIRES + --selftest from the shared watcher lib.

## Premises
- Quota circuit opens with a parsed resets_at on the circuits row: src/daemon/circuit.rs:302 `row.resets_at = Some(r.to_string())` (origin/main ff83b6e, coder report qpa.report.md)
- Call site: src/daemon/tick.rs:1827 `circuit::record_failure_with_resets(...)`; parse: src/auth_probe.rs:265 `parse_resets_at(result, Local::now())`
- close/reset clears resets_at and deletes circuit_events: src/daemon/circuit.rs:481 `resets_at: None`, circuit.rs:497 `DELETE FROM circuit_events`
- No daemon status.json writer; fleet-dash writes it on carbon: collect.sh:650 (fleet-dash tree ~/wintermute/fleet-dash)
- collect.sh already calls `wm-build config show` per host: collect.sh:363; opens state.db read-only: collect.sh:378
- Coders inherit the daemon env token: src/daemon/install_unit.rs:15 (environment.d import comment)
- circuits row stores an absolute opened_at: PREMISE-UNVERIFIED (V1; coder STEP 0 quotes `CREATE TABLE circuits`, adds opened_at/resets_at-UTC columns if absent)
- collect.sh's ssh key on RB and ryzen7 is an unrestricted key (no forced command): PREMISE-UNVERIFIED (V5; haiku read of the authorized_keys OPTIONS prefix only, never the key, before AC3 spawn)
- No per-run token override between daemon env and the claude child: PREMISE-UNVERIFIED (coder STEP 0, ESCALATE with quotes if one exists)
## ACs for the aide
3. collect.sh reads `peer_quota_hold_path` from the `config show` it already runs (no-drift test against a fixture config show), probes the circuits columns before the SELECT and writes {} when absent (pre-AC1 schema, V4), exposes `hosts.<h>.quota_circuit`, and writes the peer file (tmp + mv) onto every OTHER build host on the same pull. Write-capable: PREMISE + EXPIRES + --selftest from the shared watcher lib. If the V5 read shows a forced-command key, add one forced command accepting only this file path, never a general shell.
5. collect.sh exposes it as `hosts.<h>.peer_hold` and fleet-dash alarms `quota-peer-window-admit` when a host admits a run whose start lies inside a peer's open circuit window with equal token_id (the 1041 shape) (V6). Test: fixture replay of 1041 (peer open 01:00:56Z, admit 01:22:19Z, same token_id) -> alarm.

STEP 0 before AC3: the V5 read (authorized_keys OPTIONS prefix only for collect.sh's key on RB and ryzen7, never the key); a forced-command key = ESCALATE to rb + ctl, do not add a transport.
