---
summa: answer
question: "A lot of improvements shipped in the past 24 hours. Based on current behavior and the changes expected with upcoming PRDs, think deeply about improving the build process: more reliable, faster, fewer reds, delights customers (agents). (Joe 2026-10-15 9:5x am PDT)"
asked: 2026-10-15T17:00:00Z
cites: ["[[2026-10-13-fastest-way-to-build-the-queue]]", "[[2026-10-09-prd-queue-throughput-levers]]", "[[2026-10-07-agents-cannot-use-mcp-tools-five-whys-rhyme]]", "[[2026-10-14-hand-vs-daemon-ab]]", "[[2026-10-15-post-ship-only-parks-lifted-queue-is-fixed-point]]", "[[wm-build]]", "[[mcphost]]", "[[Synthorg]]"]
---
| | RedBaron | ryzen7 |
|---|---|---|
| shipped / live_failed | 7 / 1 | 15 / 6 (the 6 are live-wait timeouts on "next chain" evidence, not reds) |
| host minutes per ship | **463** (3240 min / 7) | 277 (4150 / 15) |
| minutes in prd-defect class | 1172 (36 %) | 1190 (29 %) |
| defects found at CI vs gate | **27 vs 13** | 11 vs 19 |
| land lane: regen avg / max | 51 min / 144 min (cold SATA builds; fixed 7:55 am → 3 min) | 3.8 / 9.7 |
| land lane: ci-wait avg | 25.5 min (n=12) | 8 |
| land lane: live-install | 9 min | 2 |

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
