---
summa: answer
question: "wm-build: what does flake-audit-single-run do, are the timing-sensitive tests necessary, and does a second cargo job break parallelism? (2026-10-05)"
asked: 2026-10-08T00:00:20Z
cites: ["[[wm-build]]"]
---
**flake-audit** is a gate producer that runs the repo's whole test suite N times (3 on the current binary) and blocks if any pass fails or the passes disagree. Its purpose: catch flaky tests before they land. On mcphost and synthorg it is cheap. On wm-build's own repo the suite is ~388 unit tests plus ~60 integration binaries that spawn real processes, fake builders, git fixtures, and systemd units. One pass ≈ 16–18 min solo on the 32-vCPU box; three passes ≈ 55 min; the wall was 60.

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
