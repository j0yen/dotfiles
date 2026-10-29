---
summa: answer
question: "wm-build: can land conflicts be resolved faster than waiting for the next tick? (2026-09-17)"
asked: 2026-10-08T00:00:18Z
cites: ["[[wm-build]]"]
---
**Yes. Today a rebase conflict is a dead end by design:** gate-then-land aborts the rebase, writes `land-conflict:<files>`, and exits "branch kept, not retried" (gate-then-land.sh:434-440). Nothing touches it until the next dispatch admits the slug, which with 1h30 ticks and a cap of 2 per target is one to three hours. Two conflicts in two days, each costing that.

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
