---
summa: entity
title: Dream Skill
aliases: [/dream, dream, dream skill, PRD dreaming, dream-persist]
created: 2026-10-29T22:20:00Z
updated: 2026-10-29T22:20:00Z
tags: [fleet, hub]
---
> **As of 2026-10-29.** `/dream` is the only way to write a PRD (CLAUDE.md § PRDs; hook `prd-write-gate.sh`). It takes a seed, gathers evidence, writes a vision and then buildable PRDs into `~/Documents/PRDs/build-queue/` for the installed builder (wm-build daemon fleet-wide). It reads the builder's `build-contract.md` at run start, so the skill drives any builder without edits. Dream does not implement. Skill files: `~/.claude/skills/dream/SKILL.md` (15,343 bytes, last edit 10-24 4:58 PM), `history.md` (why each rule exists), `reference.md`, `writing-standard.md`, `scripts/`; source repo `vibecode-kit` `skills/dream/` (latest 5380c9e, 10-24). The contract and its hook scripts live in the build skill: `~/.claude/skills/build/build-contract.md` (§ Dream hooks) and `scripts/dream-*.sh`. Where the PRDs go and how they are built: [[PRD Pipeline]].

Fixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.
