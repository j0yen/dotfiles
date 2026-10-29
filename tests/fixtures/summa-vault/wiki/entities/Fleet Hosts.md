---
summa: entity
title: Fleet Hosts
aliases: [fleet hosts, host table, fleet topology, hosts]
created: 2026-10-29T22:15:00Z
updated: 2026-10-29T22:15:00Z
tags: [fleet, hub]
---
> **As of 2026-10-29.** The fleet is six machines on one tailnet: carbon (Joe's laptop, administration and monitoring only), RedBaron (mcphost build host), ryzen7 (synthorg build host), and three permanent Hetzner cx33 boxes: orch (release gate, mcphost-deploy, discovery chain, backups), hub (Wintermute Hub: NATS, caddy, demos) and mcphost-1 (prod). Nothing else may exist: the fleet guard deletes every other Hetzner server (CLAUDE.md § Money). Rules and ownership: `~/.claude/CLAUDE.md` § Hosts. Live truth: `~/.cache/fleet-dash/status.json` (carbon, at http://carbon:8787/, at most 60 s old).

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
