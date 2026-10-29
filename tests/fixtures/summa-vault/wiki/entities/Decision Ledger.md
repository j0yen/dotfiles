---
summa: entity
title: Decision Ledger
aliases: [DECISION line, DECISION rows, decision ledger, swarm-decide, wm-decide, correction share, FABLE-REGRADE]
created: 2026-10-29T22:20:00Z
updated: 2026-10-29T22:20:00Z
tags: [fleet, hub, review, ledger]
---
> **As of 2026-10-29 3:11 PM PDT.** The Decision Ledger is the running record of every fleet decision that changes a limit, config, run state, prod, a binary or a PRD. A seat (or the aide or a plain session) files it as a `DECISION:` line the same sweep; the controller gives the first verdict; a blind Fable grader re-grades it; Joe re-grades after the fact ("I'm the top reviewer", 10-22). It lives in two forms: the prose file `memory/project_sonnet_operator_decision_ledger_20261016.md` (1,017,615 bytes on 10-29, never read whole) and the swarm-decide database `~/.local/state/swarm-decide/decisions.sqlite`, driven by the `wm-decide` CLI. swarm-decide is FROZEN for new code since 10-29 (approvals #62). Live truth: `wm-decide stats`.

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
