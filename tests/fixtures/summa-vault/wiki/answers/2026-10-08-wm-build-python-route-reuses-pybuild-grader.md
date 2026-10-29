---
summa: answer
question: "does wm-build's python route reuse pybuild's own grader? (2026-09-19)"
asked: 2026-10-08T00:00:17Z
cites: ["[[wm-build]]"]
---
Yes. For `python-*` PRDs the inner step shells `/pybuild` as one command and takes its receipt as the verdict, so pybuild's own grader runs unchanged.

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
