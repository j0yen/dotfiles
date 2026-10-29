---
summa: entity
title: Mcphost Production Box
aliases: [mcphost-1, mcphost prod, prod box]
created: 2026-09-08T06:50:59Z
updated: 2026-10-29T22:15:00Z
tags: [fleet, hub]
---
> **As of 2026-10-29.** mcphost-1 (Hetzner cx33, fsn1, 2.28.40.4) serves production mcphost at https://mcphost.dev/mcp, currently version 0.118.8 with all four health components (mcp, exec, billing, claim) ok and overall "operational" (fleet-dash status.json `prod`, 10-29 3:07 PM). It has served prod since 2026-09-06; the hub is NOT prod (its `mcphost.service` is inactive by design). Deploys come from `mcphost-deploy` on orch under standing authorization (CLAUDE.md § Build operations). Live truth: `https://mcphost.dev/healthz` (authed diagnostics) and status.json `prod`.
