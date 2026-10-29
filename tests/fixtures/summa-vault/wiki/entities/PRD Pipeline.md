---
summa: entity
title: PRD Pipeline
aliases: [PRD queue, build-queue, PRDs repo, prds repo, PRD lifecycle]
created: 2026-10-29T22:15:00Z
updated: 2026-10-29T22:15:00Z
tags: [fleet, hub]
---
> **As of 2026-10-29.** A PRD is a markdown file in the private repo `j0yen/prds` (clone at `~/Documents/PRDs` on every host). `/dream` writes it into `build-queue/` (see [[Dream Skill]]); the wm-build daemon on a build host claims it, runs a coder inner, a gate and a land, then moves it to `built-prds/`. Deliberately shelved PRDs sit in `parked/` and are never scanned (see [[Parked PRDs]]). Frontmatter is the only state: `MANIFEST.md` and `manifest.json` are derived caches (PRDs `README.md`). Live truth: `ls ~/Documents/PRDs/build-queue`, `~/.cache/fleet-dash/status.json` `.queue` (probe-free, at most 60 s old), `wm-build queue` / `wm-build explain` on the owning host. Owners: the daemon owns every status change after `queued`; rb owns RedBaron's admission (mcphost), r7 owns ryzen7's (synthorg) ([[Operator Seats]], [[wm-build]]).

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
