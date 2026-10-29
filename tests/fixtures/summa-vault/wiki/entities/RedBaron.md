---
summa: entity
title: RedBaron
aliases: [redbaron, rb host, RedBaron build host, Red Baron]
created: 2026-10-29T22:15:00Z
updated: 2026-10-29T22:15:00Z
tags: [fleet, hub]
---
> **As of 2026-10-29.** RedBaron is an always-on headless Ubuntu build host (nproc 16, 30.7 G RAM, 8 G swap) running the wm-build 0.77.109 daemon in host mode for mcphost PRDs (`admit_slug_prefixes ["mcphost-"]`). It also builds the wm-build binary and the nextest archive that orch executes. The rb seat (tmux/systemd-user unit on carbon, over ssh) owns it, its runs and its goal.md line. Live truth: `~/.cache/fleet-dash/status.json` `hosts.redbaron` on carbon (read 10-29 3:07 PM). Never call RedBaron a "hub": that is the legacy name in cloudbuild.sh; the Hetzner box is Wintermute Hub (Joe 09-02, memory/fleet-hosts.md).

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
