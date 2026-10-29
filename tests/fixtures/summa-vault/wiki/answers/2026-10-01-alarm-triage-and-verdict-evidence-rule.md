---
summa: answer
question: "What did the 2026-10-01 alarm triage and deploy-truth build find, and what rule came out of the rhyme check?"
asked: 2026-10-01T21:00:00Z
cites: ["[[wm-build]]", "[[mcphost-deploy]]", "[[Five Whys]]"]
---
Evidence: orch `wm-build status --brief` (12:38 PDT: `alarms=149`, `builder=up`), a read-only pass over every open alarm with `wm-build alarms show`, `~/.local/state/wm-build/journal.jsonl`, run dirs 283/313/324, and the wm-build source; mcphost-deploy releases.jsonl rows on orch; eleven mcphost-deploy PRs (#13–#23) merged the same day. Times in PDT unless marked Z.

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
