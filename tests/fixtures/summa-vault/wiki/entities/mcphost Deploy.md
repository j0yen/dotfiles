---
summa: entity
title: mcphost Deploy
aliases: [mcphost-deploy, mcphost deploy, deploy-on-land]
created: 2026-10-29T22:20:00Z
updated: 2026-10-29T22:20:00Z
tags: [fleet, hub, deploy]
---
> **As of 2026-10-29.** How mcphost reaches prod: the private repo `j0yen/mcphost-deploy` (Python, default branch `master`) installs, redeploys, probes and rolls back the single prod box `mcphost-1`. It runs on orch, not on carbon or the build hosts. A landed mcphost build is handed to orch by wm-build; orch's deploy-on-land path unit runs `redeploy`, which backs up the DB, checks migration compatibility, swaps the binary and `www/`, restarts, probes, and auto-rolls-back on failure. Prod deploys and promotions are inside Joe's standing authorization (CLAUDE.md § Build operations). Live truth: `https://mcphost.dev/healthz` and `/status.json` (version), orch `~/.local/state/mcphost-deploy/journal.log` and `releases.jsonl`. Parent: [[mcphost]]; box: [[Mcphost Production Box]]; owner of deploy ops: rb seat.

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
