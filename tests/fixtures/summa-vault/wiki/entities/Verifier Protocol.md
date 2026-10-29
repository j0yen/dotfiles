---
summa: entity
title: Verifier Protocol
aliases: [verifier split, via verifier, VERIFY BEFORE VERDICT, verifier rate, haiku never ends an action, correction counting]
created: 2026-10-29T22:15:00Z
updated: 2026-10-29T22:15:00Z
tags: [fleet, hub, verification, review]
---
> **As of 2026-10-29 3:15 PM PDT.** The protocol that decides who may say "done", "merge", "CONFIRM" or "CORRECT" on fleet work. Cheap models (haiku scout/runner/triage) read and run; they never end an action. A sonnet `verifier` (a separate session from the coder or the seat) sits on the same row and is the only kind of agent whose CONFIRM may gate a merge (`--via verifier`). Every verdict names the ONE read it checked; none means `UNVERIFIED` and the row goes to Fable the same sweep. The controller gives the first verdict, one Fable one-turn spawn per sweep re-grades, and a DISAGREE or CORRECT counts as a correction against the owning seat. Owners: the controller (first verdicts, correction counts), the aide (swarm-decide code), each seat for its own rows. Live truth: `~/.local/state/swarm-decide/{decisions.sqlite,stats.json}` (regenerated about every minute; read 10-29 3:07 PM) and `~/.cache/fleet-dash/status.json` (the operator card at SessionStart prints seat correction rates). The gate side (what the machine refuses) is [[Verify and Merge Gates]].

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
