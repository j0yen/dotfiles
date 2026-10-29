---
summa: entity
title: Hetzner Cost Rules
aliases: [no non-permanent boxes, hetzner fleet guard, box idle 20 minutes, fixed floor, money seared]
created: 2026-10-29T22:12:02Z
updated: 2026-10-29T22:12:02Z
tags: [fleet, hub]
---
> **As of 2026-10-29 3:12 PM PDT.** The money rules for Hetzner and CI. The fleet owns exactly three Hetzner servers, all always-on cx33: **hub**, **orch**, **mcphost-1**. Every other server is a violation and `hetzner-fixed-fleet-guard.timer` deletes it. All builds run on Joe's RedBaron and ryzen7 machines, not rented boxes. Joe's rule (10-11 11:3x AM): "continue building on redbaron again. no non-permanent hetzner boxes. hard rule this time." Box idle is 20 minutes if a box is ever leased; no seat raises an idle, grace or cost limit; no paid GitHub Actions. Owner: Joe sets limits; the aide and the controller enforce. Live truth: the Hetzner API server list, [[Hetzner Fleet]] (inventory), `~/.cache/cargo-box/journal.log` (carbon lease attempts), the guard timer on RedBaron.

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
