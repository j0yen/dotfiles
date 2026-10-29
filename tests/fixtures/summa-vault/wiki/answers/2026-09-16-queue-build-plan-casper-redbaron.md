---
summa: answer
question: "What is the plan to build the current PRD queue (2026-09-16, 28 PRDs) across casper, RedBaron, ryzen7 and carbon?"
asked: 2026-09-16T03:30:00Z
cites: ["[[Casper]]", "[[Process]]"]
---
Short answer: casper does every cargo run, RedBaron does everything else, ryzen7 and carbon stay out. The queue is bounded by three serial locks, not by CPU: the mcphost crate's gate lock (one main-scope gate at a time, 6 min warm, 18 cold), the Sonnet weekly quota (resets 2026-09-17), and the build-skill repo (10 shell PRDs, no worktree isolation yet). Joe, 2026-09-16 ~03:35Z: "i love this plan. hold onto this. lets come back when burst is ready."

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
