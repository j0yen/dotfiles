---
name: retrieval-eval
description: Build and run a retrieval evaluation for any ranked-search component — photo matching (homeward), memory recall, semantic/code search, kNN over embeddings. Covers golden-set construction (held-out, temporally split, never agent-authored with the change under test), metrics (recall@k, mAP, per-segment splits), baseline pinning, and the ship/no-ship regression gate. Use when the user asks "did this retrieval change help", wants an eval harness for a search/matching feature, wants a golden dataset designed, or quotes retrieval numbers that need auditing.
---

# retrieval-eval

Method skill: turn "the matching feels better" into a measured gate. Applies to
any component with the shape *query → ranked candidates → was the right item
in the results?*

## When this applies

- Embedding/model swaps, preprocessing changes, index rebuilds, chunking or
  scoring changes in: homeward photo match, recall memory retrieval, summa
  `ask`, any future search feature.
- Auditing a quoted number ("accuracy is 95%") — first question is always
  *on what set, constructed how?*

## 1. Golden set construction (where evals are won or lost)

1. **Held out**: the eval set never trains, tunes, or seeds the system under
   test. If the same change adds data AND evaluates, split first.
2. **Independent authorship**: never evaluate on fixtures written by the same
   agent/session that wrote the change — recall/accuracy claims from
   self-authored fixtures prove nothing ([[feedback_agent_written_fixtures_tautology]];
   wm-router went 100%→73.5% on a real held-out set).
3. **Match deployment conditions**: eval pairs must reproduce the hard part of
   production. Homeward's lesson: same-session photo pairs gave r1 0.611; the
   deployment-realistic cross-session (≥30d gap) number was 0.449. Ask "what
   makes the real query hard?" and build THAT into the set.
4. **Segment labels**: tag every item with the dimensions that could hide
   weakness (species, age/gap bucket, source, length, type). Aggregates lie.
5. **Freeze and pin**: version the set (git commit or content hash). Numbers
   are only comparable on the same frozen set. Extending the set = new baseline
   run for old AND new system before any comparison.
6. Size: enough per segment that a real change moves the metric more than
   noise — ~100+ queries per segment you intend to gate on; report counts.

## 2. Metrics

- **recall@k** for the k's the product actually uses (homeward: 1, 5, 20 —
  r20 because a human reviews a 20-item shortlist; r1 because auto-match would
  need it). Pick k from the UX, not convention.
- **mAP** (or MRR for single-answer tasks) for ranking quality between the k's.
- Always report **per segment** and per gap/difficulty bucket alongside the
  aggregate.
- Latency and index size when the change could move them.

## 3. Baseline pinning and the regression gate

- A baselines table lives with the harness: date, set version, variant/config,
  metrics per segment. Current homeward pins: large 2026-08-26 — r1 0.449 /
  r5 0.693 / r20 0.880 / mAP 0.558; dogs 0.538 vs cats 0.346; 30–60d 0.538 →
  1–2y 0.341.
- **Gate**: a change ships only if primary metrics beat (or hold, if the change
  targets something else) the pinned baseline on the same frozen set, with no
  segment regressing materially. State the comparison explicitly in the ship
  report: baseline → new, per metric.
- One run is one sample. If the harness has stochastic parts (sampling,
  tie-breaks), run N≥3 and report spread before claiming a small delta is real.

## 4. Reporting

One table: metric × segment, baseline vs candidate, delta. Then two sentences:
what improved, what regressed. Never quote the aggregate alone; never quote a
number without set version + date. Weak segments (homeward: cats, old photos)
get named — they are the roadmap.

## 5. Anti-patterns (each has cost real work here)

- Same-session / easy-pair eval sets → inflated numbers (homeward 0.611 vs 0.449).
- Agent-authored fixtures evaluating that agent's change → tautology.
- Comparing across different or silently-extended sets.
- Aggregate-only reporting → cats-weakness invisible.
- Concluding from one anecdotal query instead of the harness
  ([[feedback_verify_before_concluding]]).
- Retrieval eval as a proxy for coverage: it measures "can we find what we
  have", not "do we have it" — pair with a coverage audit (homeward-ops).

## Existing harnesses

- **homeward**: ryzen7 `~/homeward-eval/` — see /homeward-ops "Retrieval-eval
  contract" for invocation and pins.
- **recall**: no harness yet. First candidate: golden set of (session-context →
  memories that should have surfaced) pairs, labeled by memory type and age;
  would diagnose whether the 103 never-recalled memories are retrieval misses
  or true negatives. Build via /pybuilder if it becomes a tool.
