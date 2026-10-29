---
summa: entity
title: Controller Seat
aliases: [controller, ctl, seat-tick@ctl, SWARM-CONTROL]
created: 2026-10-29T22:20:00Z
updated: 2026-10-29T22:20:00Z
tags: [fleet, hub]
---
> **As of 2026-10-29.** The controller (`ctl`) is the fleet's grader and sweeper: a `claude -p --resume de73e73c-5095-4d39-9703-1fc439e7236d` turn started by the systemd-user unit `seat-tick@ctl` on [[Carbon]], every tick a SWEEP, EVENT or ASK prompt. It gives the first verdict on every rb, r7 and aide DECISION (CONFIRM, CORRECT, UNVERIFIED), writes FLEET STATUS, and reads Joe's word only from `approvals.log`. It owns no host and builds nothing. Model: Opus 5.5 for its sweep loop, with Fable kept for one-turn re-grades (controller-model-required, 10-29). Live truth: `~/.cache/fleet-dash/ctl-tick.json`, `~/.cache/fleet-dash/fleet-status.md`, the ledger memory/project_sonnet_operator_decision_ledger_20261016.md. Overview: [[Operator Seats]].

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
