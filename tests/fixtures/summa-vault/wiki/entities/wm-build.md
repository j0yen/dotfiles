---
summa: entity
title: wm-build
aliases: [wm-build daemon, wm-build.service, the daemon, wm-build binary]
created: 2026-09-23T14:47:16Z
updated: 2026-10-29T22:13:00Z
tags: [fleet, hub]
---
> **As of 2026-10-29.** wm-build is the Rust daemon (`wm-build.service`, a systemd user unit; binary `~/.cargo/bin/wm-build`) that admits PRDs from the PRDs repo and carries each run through inner (coder) → verify (gate) → land → merge → close. It builds mcphost and synthorg PRDs; it never builds itself. Both build hosts run 0.77.109 today. Owners: `rb` seat owns [[RedBaron]] and its daemon; `r7` seat owns [[Ryzen7]] and its daemon ([[Operator Seats]], CLAUDE.md § Hosts). Live truth: `~/.cache/fleet-dash/status.json` on carbon (probe-free, at most 60 s old, http://carbon:8787/), never a raw `wm-build status`/`runs` (that is a 12 G journal read that froze ryzen7 10-24). Trap catalog: [[wm-build Traps]]. Landing train: [[Landing Train]].
