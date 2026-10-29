---
summa: answer
question: "Why did every mcphost gate on RedBaron hang for 90 minutes on 2026-10-09 (five whys), what does it rhyme with, and what is the falsifier?"
asked: 2026-10-09T17:35:00Z
cites: ["[[mcphost]]", "[[wm-build]]", "[[RedBaron]]", "[[Five Whys]]"]
---
Evidence: `/mnt/data/wm-build/runs/574/gate-receipts/flake-audit-attempt1.log` and `-attempt2.log`, `runs/583/gate-receipts/flake-audit-attempt1.log`, `runs/574/gate.result.json` (`flake-audit`, `risk-gate` → `gate-aborted`, `wall_secs 7128`), `runs/574/gate-receipts/flake-audit-receipt.json` (`wall_secs 5400.02`, captured 09:38:40 PDT), `runs/*/progress.jsonl`; peer observation (session jsy-4b, 9:4x am): 574 and 583 both stopped at exactly 1274/1313 tests, threads parked in futex waits, no sockets, egress and DNS fine; mcphost `origin/main` 1a7b0ad `tests/common/mod.rs:1760-1790` (`ENV_GUARD_LOCK`, `EnvGuard`), `tests/ac12_preflight.rs:112-140`, `tests/support/busyaudit.rs:83`; `~/.config/wm-build/config.toml:36,80` (`parallelism = 1`, `cargo_jobs = 2`); triage notes `scratchpad/disk/hang-triage.txt`, `hang-tests.txt`.

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
