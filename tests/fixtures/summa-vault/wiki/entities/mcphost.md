---
summa: entity
title: mcphost
aliases: [mcphost.dev, MCPHost]
created: 2026-09-23T05:42:53Z
updated: 2026-10-29T22:15:00Z
tags: [fleet, hub, product]
---
> **As of 2026-10-29.** mcphost is the product: a hosted MCP server at `https://mcphost.dev/mcp` that gives an agent its own persistent backend in one call (publish a tool, keep state, schedule, message other agents, per-end-user auth passthrough). The Rust server (sandboxed Python/HTTP tools under bwrap + AppArmor, SQLite) runs on the single prod box `mcphost-1`; the repo is public. Fleet-side, mcphost PRDs are daemon-built on RedBaron (with a ryzen7 fallback), landed through wm-build, and deployed by the `mcphost-deploy` repo running on orch. Live truth: `https://mcphost.dev/status.json` and `/healthz` (public), `prod.version` in `~/.cache/fleet-dash/status.json` (carbon, <= 60 s old), the generated handoff "Versions" block. The product goal is NOT stated here; read `~/Notes/wiki/goal.md` § Stage after a ff-only pull.
