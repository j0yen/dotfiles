---
summa: entity
title: Approvals Log
aliases: [approvals.log, Joe approvals, approvals ledger, numbered approvals]
created: 2026-10-29T22:12:00Z
updated: 2026-10-29T22:12:00Z
tags: [fleet, hub, joe, authorization]
---
> **As of 2026-10-29 3:11 PM PDT.** `~/.claude/state/approvals.log` is the append-only record of Joe's words that authorize fleet actions: one line per word, `#<id> | <date time TZ> | <session> | Joe: "<verbatim>" | re: <what it approves>`. It holds 80 numbered lines for ids #1-#77 (84 lines in all: header, two dated notes, one NOTE line). It is written only by the aide session through `approve.sh` and is the only place the controller (`ctl`) reads Joe's word from. CLAUDE.md cites it by number (#18, #32, #49, #52, #54, #67). Live truth: `~/.local/bin/approve.sh --last N`.

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
