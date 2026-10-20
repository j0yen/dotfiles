---
name: designing-ml-systems
description: >
  Reference Chip Huyen's *Designing Machine Learning Systems* (O'Reilly, 2022) for production-ML system design, MLOps, and debugging production-ML failure modes. Covers ML problem framing, data engineering for ML, training-data construction, feature engineering (data leakage, generalization), offline evaluation (slice-based, perturbation/invariance, calibration, baselines), the four modes of prediction, deployment (train/serve skew, feature stores), distribution-shift monitoring (covariate / label / concept drift), continual learning (shadow / A/B / canary / interleaving / bandits), the four-layer MLOps stack, and responsible AI. Use when structuring an ML pipeline, debugging drift or train/serve skew, choosing batch vs online prediction, deciding feature-store-vs-not, picking offline-eval metrics, planning continual-learning cadence, or making build-vs-buy MLOps decisions. Trigger on requests like "why is my model drifting", "training-serving skew", "how do I monitor an ML system", "should I use a feature store", "shadow vs canary deployment", "covariate vs concept drift", "build or buy MLOps", "is this a good ML problem". Skip pure modeling / SOTA-architecture questions (this is systems, not modeling), non-ML data-engineering questions (use a data-platform resource), and LLM / foundation-model-specific operational patterns (the book predates the LLM wave — some patterns transfer, RAG/agent/prompt-eval don't).
version: 2.0.0
last_updated: 2026-05-18
---

# Designing Machine Learning Systems — Chip Huyen

## Core frame

**ML systems are iterative socio-technical systems, not algorithmic puzzles.** ML systems design is the holistic discipline of which MLOps is the operational toolchain — covering when (and when not) to use ML, problem framing, data engineering, training-data construction, feature engineering, offline evaluation, deployment, distribution-shift monitoring, continual learning, infrastructure, and the human dimension (responsible AI, team structure). Quality bar: the four requirements — **reliability, scalability, maintainability, adaptability**. Methodological move: prefer simple solutions until they plateau. This is a reference lens; pull on the specific concept the question touches.

## Key concepts

- **The four ML-system requirements** — reliability, scalability, maintainability, adaptability. Used to evaluate any production-ML design decision.
- **Four modes of prediction** — batch (offline, scheduled), online-batch (request-triggered, cached), streaming (real-time), on-device (edge). Choice depends on latency budget and freshness need.
- **Train-serve skew** — divergence between training features and serving features. The dominant production-ML failure mode. Caused by separate code paths, feature-pipeline drift, time-window leakage.
- **Feature store** — centralized store that produces features for both training and serving from a single definition. Solves train-serve skew, enables feature reuse.
- **Streaming-batch unification** — using one engine (Flink, Spark Structured Streaming) for both batch backfills and streaming serving, to keep feature definitions consistent.
- **Data leakage** — training data contains information not available at inference time (e.g., target leakage, temporal leakage). Causes optimistic offline metrics that don't reproduce online.
- **Slice-based evaluation** — disaggregating metrics by user/data segment to catch failures hidden in the aggregate. Cornerstone of responsible AI and fairness.
- **Perturbation / invariance tests** — offline robustness checks: small input perturbations shouldn't change predictions meaningfully; semantically-invariant changes shouldn't either.
- **Calibration** — degree to which predicted probabilities match observed frequencies. Often important even when accuracy is high.
- **Distribution shifts** — covariate shift (P(X) changes, P(Y|X) stable), label shift (P(Y) changes), concept drift (P(Y|X) changes). Different shifts call for different responses.
- **Continual learning** — keeping models current under shifting data. Maturity stages: manual retrain → automatic retrain on schedule → continual retrain on streaming data.
- **Test-in-production techniques** — shadow deployment (mirror, no impact), A/B (split traffic, compare), canary (small slice ramped up), interleaving (mix results), multi-armed bandits (allocate by performance).
- **Four-layer MLOps stack** — storage & compute / resource management / ML platform / dev environment. Use to decompose build-vs-buy decisions per layer.
- **Build-vs-buy** — Huyen's heuristic: buy the layers where vendors have scale-economy advantage; build where competitive advantage lives.
- **Responsible AI** — UX for ML, team structure, fairness trade-offs, model cards, slice-based evaluation, the "should this system exist" question.

## Heuristics

- **Don't use ML if a rule will do.** Before recommending ML, ask: would 50 hand-coded rules + monitoring suffice? Often yes. ML is expensive maintenance.
- **Start with the simplest baseline.** Linear/logistic regression or a rule-based heuristic — ship it, measure it, then only add complexity that beats baseline by a meaningful margin.
- **Build a feature store when more than one model shares features.** Premature for a first model; essential by the third.
- **Slice every metric.** Aggregate accuracy hides failures by segment. Always disaggregate by user/data slice before declaring a model production-ready.
- **Pair offline eval with shadow deployment.** Offline eval is necessary but not sufficient. Shadow the new model against prod traffic for at least a week before A/B.
- **Diagnose drift type before responding.** Covariate shift → retrain on recent data. Label shift → recalibrate or reweight. Concept drift → retrain *and* re-evaluate features. Wrong diagnosis means wrong fix.
- **Train/serve skew is the prior.** When a deployed model underperforms its offline metrics, assume skew and instrument feature distributions on both paths before changing anything else.
- **Continual learning maturity is a ladder.** Start manual; automate retrain cadence; move to streaming only when the data velocity justifies the operational cost.
- **Bandits over A/B for many variants.** Multi-armed bandits explore-and-exploit; A/B is fixed-split. For >2 variants or non-stationary winners, prefer bandits.

## When to apply

- **"Is this a good ML problem?"** → Run the "would 50 rules suffice" test. If yes, use rules. If no, frame the ML problem (objective, task type, requirements).
- **"Why is my model drifting?"** → Diagnose the shift type (covariate / label / concept). Each has a different remedy. Don't retrain blindly.
- **"How do I structure features?"** → Define them once (feature store if multi-model), eliminate data leakage (target + temporal), instrument the same path for training and serving.
- **"Training-serving skew."** → Instrument feature distributions on both paths. Find the divergent feature. Usually root cause: separate code paths or a time-window mismatch.
- **"How do I monitor an ML system?"** → Four layers: operational metrics (latency, error rate), accuracy-related metrics (when ground truth lands), prediction monitoring (distribution shifts in outputs), feature monitoring (distribution shifts in inputs).
- **"Should I use a feature store?"** → Yes when features are shared across models or when offline/online consistency is hard to enforce. Otherwise premature.
- **"Shadow vs canary vs A/B for this rollout?"** → Shadow for safety (no user impact); canary for risk-tiered exposure; A/B for measurement. Often a sequence: shadow → canary → A/B.
- **"Build or buy our MLOps platform?"** → Decompose by the four layers. Buy where vendor economies dominate (storage, compute). Build where your competitive advantage lives.
- **"What offline metrics besides accuracy?"** → Slice-based by segment, perturbation/invariance tests, calibration, baselines. Accuracy alone is misleading.
- **"Continual learning cadence?"** → Maturity ladder: schedule-based first; move to streaming only when data velocity justifies it.

## Out of scope

- **Pure modeling / algorithm / architecture questions** — this is the *systems* book; for "which architecture for task X" or SOTA tuning, use a modeling reference.
- **General data engineering** disconnected from ML — Ch 3 covers the ML-relevant slice; for general data-platform design, use `practical-lakehouse-architecture` or a data-platform resource.
- **LLM / foundation-model operational patterns** — the book predates the LLM wave. Some patterns transfer (drift monitoring, slice-based eval, train-serve skew); some don't (RLHF lifecycle, prompt eval, RAG, agent ops). Flag the gap.
- **GenAI prompt engineering / agent design** — out of scope.

## Source

*Designing Machine Learning Systems: An Iterative Process for Production-Ready Applications*, Chip Huyen, May 2022 (O'Reilly).
