---
title: "How to build the 387-PRD queue faster: measured bottlenecks and ranked levers (2026-10-09)"
question: "Joe 2026-10-09 11:0x am: think hard about how to build this PRD queue as quickly as possible — any process improvements, any changes that would increase PRDs/hour?"
date: 2026-10-09
tags: [wm-build, throughput, host-mode, redbaron, prds-per-hour, decision-input]
---
| Quantity | Value |
|---|---|
| Queue | 387 queued (mcphost 249, synthorg 132, dotfiles 5, fleet 1); 190 carry Depends-on |
| Shipped | 8 on 10-08 (0.33/h); 0 from 12:36 am to 11:13 am 10-09 |
| Wall hours, 48 h | released 129.5 h (23 runs); code 47.3 h (27); infra 76.5 h (95) → **49 % waste** |
| Successful leg walls (72 h avg) | inner 71 min (mcphost coder leg 85–141 min; verify legs 2–19 min total); gate 26 min (mcphost 24–80); land 28 min incl. final gate |
| Concurrency | max_runs 4, gate parallelism 1, cargo_jobs 2, CARGO_BUILD_JOBS 8, sccache on; load 24–32 on 16 threads, 30 G RAM |
| Operator tick | 36 min wall / 28 min CPU per tick, still running at 11:13 (journal.jsonl 359 MB re-read per tick, reconcile.rs:188) |
| Daemon | 460 crash-loop restarts today ([[2026-10-09-red-legs-catalog-five-whys-rhyme]] §11); 0 ticks → 0 lands while looping |

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
