---
title: "Why mcphost #532 (CI green) is held on a verify clippy red that main already carries, and why rb spent a coder before reading the base (five whys + rhyme)"
date: 2026-10-27
asked_by: Joe
answered_by: rb (Fable 5.1 via /5whysandrhyme, carbon)
status: Fable regraded AGREE-WITH-CHANGES 12:57 PM PDT 10-27 (ctl d-20261027-125725-controller-6987); changes applied below
skill: 5whysandrhyme
---
Asked by the rb seat on Joe's standing rule (CLAUDE.md § FAILURES) at 12:42 PM PDT 10-27, incident window 7:34 AM – 12:50 PM PDT 10-27. The ask, verbatim: "mcphost PR #532 (head d9221f00…, a 1-line Cargo.toml + Cargo.lock change dropping the wasmtime "cache" feature to clear zstd RUSTSEC advisories) showed GitHub CI green (23 pass, 2 skipped). r7's full verify on ryzen7 … failed `cargo clippy --all-targets -- -D warnings` EXIT=101: suite_core_08 13 errors. The rb seat (Opus) read that as a #532 regression and launched a sonnet coder … The coder found that all errors are pre-existing clippy 1.98 style lints in test files and src test modules untouched by #532 … So main's CI does not gate `clippy --all-targets -D warnings`, while the merge-gate verify does, and the merge of a deps PR (and the 1061 land behind it) is held on lint debt nobody owns." Questions: why CI and the verify disagree on scope; why the seat mis-classified a pre-existing red as a delta and spent a coder before the base read; why lint debt accumulated (toolchain bump or scope; which clippy CI pins vs the hosts' 1.98.1).

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
