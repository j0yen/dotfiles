---
name: data-platform-metrics-telemetry
description: >
  Apply enterprise data platform metrics, KPIs, and telemetry design patterns
  for semantic-layer products (e.g., AtScale). Covers North Star Metric (NSM)
  selection, AARRR adapted for B2B middleware, the health/growth/monetization
  split, category-specific KPIs (adoption, activation, engagement & retention,
  performance, business, AI-specific), telemetry instrumentation across the
  five domains (query / model / performance / feature usage / error), privacy-
  respecting telemetry (per-tenant salted hashing, k-anonymization,
  differential privacy, never-collect list), the four-stage collection
  pipeline (emitter -> edge buffer -> ingestion -> analytics store), and how
  to embed measurable success metrics in PRDs (primary/secondary/guardrails,
  leading vs lagging, output-outcome-impact). Use when picking a North Star,
  designing telemetry schemas for a data platform, writing or critiquing PRD
  metrics sections, building an Account Health Score, setting SLOs for query
  latency / cache hit rate / aggregate utilization, planning churn prediction
  signals, calibrating NPS expectations against the "invisible middleware
  problem," or benchmarking activation/retention/expansion against B2B-infra
  norms. Trigger on requests like "what should our North Star metric be",
  "design telemetry for a semantic layer", "is this PRD success metric any
  good", "build an account health score", "what's a good cache hit rate /
  P95 latency target", "AARRR for B2B middleware", "vanity metric red
  flags", "privacy-respecting product telemetry", "NRR / NDR / GRR
  benchmarks", "text-to-SQL accuracy target". Skip pure BI dashboarding (this
  is product instrumentation, not visualization), warehouse query-optimizer
  internals, SRE incident playbooks (overlaps but isn't the lens), and
  vanilla SaaS consumer growth — Patton/PLG frames; this lens is enterprise
  data-platform middleware.
version: 1.0.0
last_updated: 2026-05-18
---

# Data Platform Metrics & Telemetry — instrument the invisible middleware

## Core frame

Semantic-layer products are **invisible when they work** — the better the
plumbing, the less credit the user gives it. The lens: pick **one North Star
Metric** that tracks value delivered (governed queries served), decompose it
into actionable inputs, then instrument *enough* to know what was asked, how
it was answered, and how it performed — **without** ever capturing query
text, data values, schema names, or model logic. Separate **health** (non-
negotiable baselines), **growth** (traction), and **monetization** (durable
revenue) — confusing them produces bad decisions. Embed metrics in every PRD
at three levels — **output / outcome / impact** — with explicit baselines,
targets, and timelines. Always measure latency in percentiles, never
averages: the tail is what produces support tickets.

## Key concepts

- **North Star Metric (NSM):** single metric capturing core value. For a
  semantic layer the recommended NSM is **Governed Queries Served / Week** —
  protocol-agnostic, compounds with adoption × engagement, correlates with
  expansion revenue. Decomposes as: Active Accounts × Models/Account ×
  Users/Model × Queries/User/Week.
- **AARRR adapted for B2B middleware:** Acquisition = qualified pipeline (not
  pageviews); Activation = **Time to First Query (TTFQ)** + **Time to
  Multi-Tool** (same metric, second protocol); Retention = account-level not
  user-level; Revenue = NRR + usage-to-contract ratio (>= 80% utilization is
  a sales trigger, not just an engineering alert); Referral = **champion
  mobility** (when a data architect changes jobs, the semantic layer comes
  with them).
- **Health / Growth / Monetization split:** Health = non-negotiable baselines
  (query success > 99.5%, P99 cached < 5s, uptime > 99.9%, error rate <
  0.1%); Growth = adoption breadth + depth trending up QoQ; Monetization =
  ARR, NRR, gross margin, CAC payback, LTV/CAC, Rule of 40.
- **Activation funnel (8 steps):** provisioned -> warehouse connected ->
  first model -> first query issued -> first query succeeds -> second
  protocol connected -> first auto-aggregate -> ACTIVATED. The biggest
  drop-off tells you where to invest.
- **Account Health Score (composite, 0-100):** 0.30 query_volume_trend +
  0.20 user_growth + 0.15 model_growth + 0.15 performance + 0.10
  support_sentiment + 0.10 engagement_breadth. Alert CS at < 60; exec
  outreach at < 40.
- **Performance SLOs (semantic layer):** P50 cached < 500ms, P95 cached < 2s,
  P99 cached < 5s; P50 pushdown < 5s, P95 < 30s, P99 < 60s. Cache hit rate >
  60% at steady state. Aggregate utilization > 40% mature. Aggregate ROI > 3x.
- **AI-era metrics:** text-to-SQL accuracy > 95%, disambiguation success >
  80%, agent error rate < 5%, context retrieval accuracy > 95%. The
  **accuracy gap** between semantic-layer-routed AI and raw-warehouse AI is
  the moat — measure it explicitly.
- **Five telemetry domains:** Query (highest priority), Model lifecycle,
  Performance snapshots, Feature usage, Error/incident.
- **Never-collect list:** query text/SQL, data values, schema details
  (table/column/db names), user PII, model content (measure definitions,
  calculated formulas), connection strings.
- **Safe-to-collect (with disclosure):** hashed identifiers, structural
  counts (measures/dimensions/tables — counts, not names), latency &
  throughput, feature usage flags, protocol distribution, aggregate stats.
- **Anonymization stack:** per-tenant salted one-way hash; k-anonymization
  (aggregate to account level if account has < 5 users); differential
  privacy (calibrated noise) for benchmark reports; 90-day raw retention
  then pre-aggregated summaries.
- **Telemetry pipeline:** Product Service (emitter) -> Edge Buffer
  (in-process ring buffer / local file, survives network blips) ->
  Ingestion Pipeline (Kafka/Kinesis, schema validation/enrichment) ->
  Analytics Store (Snowflake / BigQuery / ClickHouse); branch to Real-time
  Alerts via Flink/Kafka Streams.
- **Five analytical patterns:** cohort analysis, feature adoption curves,
  usage-based pricing signals, churn prediction, launch impact analysis.
- **PRD metrics structure:** 1 primary + 2-3 secondary + 2-3 guardrails. At
  least one **leading** metric (course-correct) and one **lagging** metric
  (prove impact). Always specify baseline (with date), target, timeline,
  measurement method.

## Heuristics

- **Pick the NSM that tracks value delivered, not activity.** "Total queries
  all-time" is vanity (only goes up). "Governed queries / week" is value.
- **Decompose the NSM into 4 levers** so product, sales, engineering, and CS
  each have one they can move.
- **Three input tiers:** Tier 1 = direct NSM drivers (models created, first
  query latency, cache hit rate). Tier 2 = 2-4 week leading indicators (POC
  starts, docs traffic, MCP registrations). Tier 3 = strategic canaries (1-2
  quarter horizon: declining query diversity, rising AI query error rate).
- **Latency rule:** always P50/P95/P99, never mean. Averages hide the tail
  that creates tickets.
- **Telemetry must never block the product.** Fire-and-forget with local
  buffering. Sample on volume spikes; don't crash.
- **Batch over streaming for cost.** 15-min latency is fine for most product
  analytics. Reserve real-time only for alerts.
- **Schema-version every event from day 1.** Add fields; never remove or
  rename. Common envelope (timestamp, event_type, account_id, schema_version);
  payload varies. Enums over free text. UTC ISO-8601 with ms precision.
- **Correlation IDs chain events** (query_id links query_event ->
  performance data -> errors).
- **At-risk heuristic (pre-ML):** account at risk if any 2 of {query volume
  down > 20% MoM for 2 consecutive months, net user count declined, no new
  models in 60 days, NPS < 6 at last touchpoint}.
- **Usage-to-contract ratio is a sales signal, not an engineering alert.**
  >= 80% utilization = expansion trigger.
- **Champion mobility is the strongest enterprise referral.** Track former
  champions who moved companies — they're warm pipeline.
- **Segment NPS by persona.** Model authors see the product; query consumers
  don't. Target > 40 among authors, > 30 overall. Make contribution visible
  in BI tooltips to fight the invisible-middleware problem.
- **PRD rule:** if you have 15 success metrics, you have zero. 1 primary,
  2-3 secondary, 2-3 guardrails — no more. Apply the "how would I know?"
  test: if you can't describe the dashboard query that confirms success, the
  metric is unmeasurable.
- **Telemetry opt-out must be available**; for on-prem, default-off.
  Customers can see what's being sent; telemetry scope changes require
  customer notification.

## Vanity-metric red flags

- "Total queries all-time" -> use trailing 4-week average.
- "Total registered users" -> use MAU.
- "Models created" -> use models with >= 1 query in trailing 30 days.
- "99.99% uptime" with favorable exclusions -> use uptime as customers
  experience it (including degraded performance).
- "Number of features shipped" -> incentivizes fragmentation; use impact of
  features shipped.
- "Cache hit rate alone" -> incentivizes stale data; pair with cache
  freshness SLA compliance.

## Benchmarks (B2B infra, growth stage)

- POC -> production conversion: median 40-50%, top quartile 65-75%.
- Setup completion: median 60-70%, top quartile 85%+.
- GRR: median 85-90%, top quartile 92-95%, world class > 95%.
- NRR: median 105-115%, top quartile 120-130%, world class > 130%.
- DAU/MAU: median 0.15-0.25, top quartile 0.30-0.40.
- CAC payback: median 18-24 months, efficient 12-15, elite < 12.
- LTV/CAC: median 2-3x, efficient 3-5x, elite > 5x.
- Magic number: median 0.5-0.75, efficient 0.75-1.0, elite > 1.0.
- Burn multiple: median 2-3x, efficient 1.5-2x, elite < 1.5x.
- Rule of 40: > 40 growth stage; > 60 great.
- Enterprise middleware NPS: median 15-25 (invisible-middleware drag), top
  quartile 35+.

## When to apply

- Picking or critiquing a North Star Metric for a data platform.
- Designing telemetry schemas for a semantic-layer or middleware product.
- Writing the success-metrics section of a PRD; reviewing one for vanity
  metrics, missing baselines, or perverse incentives.
- Building an Account Health Score or churn-prediction signal set.
- Setting SLOs for query latency, cache hit rate, aggregate utilization.
- Calibrating NPS or activation expectations against B2B-infra benchmarks.
- Triangulating competitor metrics from public signals (job postings, G2,
  LinkedIn headcount, SEC filings, GitHub).
- Planning launch impact analysis (pre-launch baseline -> week 1 discovery
  -> week 2-4 stickiness -> month 2-3 NSM contribution -> quarter 2 ROI).

## Out of scope

- BI visualization design (Tableau / Power BI dashboards) — this is product
  instrumentation, not visualization.
- Warehouse query-optimizer internals (Snowflake / Databricks / BigQuery
  tuning) — out of scope.
- SRE incident-management playbooks (PagerDuty workflows, postmortems) —
  overlapping but not the lens.
- Consumer PLG growth tactics (viral coefficient, K-factor optimization) —
  the lens is enterprise B2B middleware.
- ML modeling for churn prediction itself (feature engineering, model
  selection) — use designing-ml-systems.

## Source

Data Platform Metrics, KPIs & Telemetry Design Patterns, AtScale Reference,
2026-03-25.
