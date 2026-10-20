---
name: dbt-metricflow-cube-technical-architecture
description: >
  Technical-architecture lens on AtScale's two primary semantic-layer competitors — dbt Semantic Layer
  (MetricFlow engine) and Cube — covering query pipelines, modeling languages, API surfaces, performance
  characteristics, caching, multi-tenancy, deployment, and the exploitable architectural gaps AtScale
  product managers can target in PRDs. Centers on three architecture types (SQL-generation engine vs.
  caching semantic layer vs. virtual OLAP platform), MetricFlow's semantic manifest + fanout-aware joins
  + zero-state pushdown, Cube's three-tier query resolution (in-memory → Cube Store pre-aggregations →
  warehouse) with manually-defined rollups, and the protocol/modeling gaps (MDX, DAX, hierarchies,
  calculated members, autonomous aggregates) that competitors cannot close in a sprint. Use when
  answering technical questions about dbt SL or Cube internals, writing PRDs that exploit competitor
  limitations, scoping competitive features, evaluating "should we build X" against dbt/Cube parity,
  responding to RFPs that compare semantic layers, or coaching sales/SE on architectural talk tracks.
  Trigger on requests like "dbt Semantic Layer vs Cube", "how does MetricFlow generate SQL", "what's
  Cube Store", "should we adopt Cube or build on dbt", "why can't Cube roll up COUNT_DISTINCT", "what
  protocols does dbt SL support", "MetricFlow semantic manifest", "Cube pre-aggregation matching",
  "exploitable gaps in dbt", "PRD against Cube". Skip pure AtScale product internals (use
  atscale-technical-reference), generic OLAP theory unrelated to these three products, BI-tool
  visualization design, warehouse-internal tuning, and Looker/LookML deep dives (a different competitor).
version: 1.0.0
last_updated: 2026-05-18
---

# dbt / MetricFlow / Cube Technical Architecture — competitor teardown for PRD writers

## Core frame

Three semantic-layer products, three architecture types. **dbt Semantic Layer** is a pure SQL-generation engine (MetricFlow compiler → warehouse pushdown, zero state, no caching). **Cube** is a caching semantic layer (in-memory cache → Cube Store pre-aggregations → warehouse, manually-defined rollups, multi-protocol API). **AtScale** is a virtual OLAP platform (Attribute Graph + autonomous aggregates + six query protocols). The architecture choice is fundamental, not a feature gap: dbt's commitment to pushdown precludes caching; Cube's manual pre-aggregations preclude autonomous optimization; both lack the OLAP primitives (MDX/DAX, hierarchies, calculated members) needed for native Power BI / Excel / enterprise drill-down. Use this lens to identify which competitor weaknesses are sprint-fixable (table stakes) and which require a fundamental architectural rewrite (durable moat).

## Key concepts

- **MetricFlow query compilation pipeline** — YAML (semantic_models / metrics / saved_queries) → `dbt parse` → **semantic manifest (JSON)** → uploaded to dbt Cloud → query-time semantic resolution → join planning → dialect-specific SQL → warehouse. No caching at any step.
- **Semantic manifest** — Compile-time JSON artifact; metric changes require re-parse and re-upload. Good for CI/CD versioning, bad for runtime governance.
- **MetricFlow entity-based join graph** — `primary` / `unique` / `foreign` / `natural` entities define joins; resolves star/snowflake schemas automatically. Cannot express inequality joins, date-range joins, or multi-column composite keys.
- **Fanout-aware join resolution** — MetricFlow detects many-to-many fanouts and isolates aggregations via subqueries/CTEs to prevent double-counting. Genuine strength.
- **MetricFlow metric types** — `simple` / `derived` / `ratio` / `cumulative` (with `grain_to_date` and `offset_window`). No calculated members, no hierarchies, no recursive CTEs, no window functions in metric definitions.
- **Cube three-tier query resolution** — (1) in-memory query result cache (Redis/in-process, LRU), (2) **Cube Store** pre-aggregation lookup, (3) warehouse pushdown fallback.
- **Cube Store** — Rust-built columnar engine storing pre-aggregated Parquet rollups; distributed in Cube Cloud; not a general-purpose database.
- **Pre-aggregations (rollup matching)** — Manually defined per-cube; types are `rollup` / `rollup_join` / `rollup_lambda` / `original_sql`. Matched at query time by exact-match, rollup-up from finer grain, or partial match. **Additive measures (SUM/COUNT/MIN/MAX) can roll up; COUNT_DISTINCT, AVG, PERCENTILE cannot** — forces combinatorial pre-agg explosion across granularities.
- **Cube modeling primitives** — `cubes` / `views` / `measures` / `dimensions` / `joins` (SQL expressions, supports inequality/date-range joins — advantage over MetricFlow) / `pre_aggregations`. `running_total` and `count_distinct_approx` (HyperLogLog) are native measure types.
- **dbt SL API surface** — GraphQL (primary), JDBC (BI tools), REST (metadata only). **No MDX, no DAX, no PGWire, no MCP, no Python SDK for queries.**
- **Cube API surface** — REST, GraphQL, **SQL API (PostgreSQL wire protocol)**. No MDX, no DAX, no XMLA, no MCP (as of early 2026), no ODBC.
- **Lambda pre-aggregations** — Cube-only feature combining batch pre-aggs with streaming overlay for near-real-time metrics. Neither dbt nor AtScale has equivalent.
- **Cube security contexts** — JavaScript-driven multi-tenancy (schema-based / RLS / database-per-tenant / pre-agg isolation). Real strength for SaaS-embedded analytics.
- **Open-source split** — MetricFlow OSS is **compiler only** (API gateway / JDBC proxy / auth are proprietary dbt Cloud); Cube OSS is **full platform** (Docker/K8s self-host produces a working semantic layer). Cube's OSS story is dramatically more favorable than dbt's.
- **Deployment lock-in** — Full dbt SL is dbt Cloud only (Team / Enterprise / Developer tiers). No self-host, no air-gapped, no government/regulated option. Cube self-host is genuine.

## Heuristics

- **Architecture-type diagnostic first.** Before comparing features, name the type: SQL-gen engine vs. caching semantic layer vs. virtual OLAP. Most "feature gaps" are actually architectural commitments — dbt cannot "just add caching" without contradicting pure pushdown.
- **Sprint-fixable vs. architectural.** Adding an ODBC driver = sprint. Adding MDX = 10+ years of OLAP engineering. PRDs that exploit architectural-cost gaps (MDX/DAX, autonomous aggregates, hierarchies, calculated members, multi-protocol-from-one-model) compound the moat.
- **COUNT_DISTINCT is Cube's pre-agg trap.** Any PRD or sales talk track that emphasizes non-additive measures (unique users, distinct customers across grains) directly attacks Cube's biggest performance pothole.
- **dbt SL's lock-in is the wedge.** Self-hosted regulated industries, air-gapped gov/defense, and customers who fear dbt Cloud price hikes have **no escape valve** — full SL requires dbt Cloud. Cube has self-host; AtScale has K8s containers.
- **Six protocols from one model > one model serving six protocols.** Each protocol AtScale serves (DAX, MDX, SQL, PGWire, Python, MCP) is a separate engineering investment for competitors. AtScale's protocol surface scales sublinearly; competitors' scales linearly.
- **MetricFlow's wins to respect.** Fanout-aware joins, clean YAML, dbt-project CI/CD integration, Hex co-developed UX. Do not claim AtScale beats dbt on developer-experience time-to-value — concede and reframe as "complexity graduation path."
- **Cube's wins to respect.** Lambda pre-aggregations (real-time), open-source self-host, application-embedded multi-tenancy via JS security contexts, REST/GraphQL ergonomics for app developers. Do not invest heavily in REST/GraphQL app-embedding — Cube's home turf.
- **Trust the manifest/rollup boundary.** MetricFlow changes need re-parse + re-upload (compile time). Cube pre-aggregations need scheduled refresh + may serve stale. Both are weaker than AtScale's runtime governance + autonomous aggregate lifecycle.
- **Pricing reality check.** dbt SL Enterprise $50K–$200K/yr; Cube Cloud Premium $300+/mo with Enterprise custom; AtScale ~$50K–$200K+/yr. Do not chase SMB/startup on price — Cube and dbt own that tier.

## When to apply

- Writing a PRD that needs to articulate why a feature exploits a competitor's structural limitation (not just a missing checkbox).
- Responding to "should we build X to match dbt/Cube" — apply the sprint-fixable-vs-architectural test.
- Coaching SE or sales on architectural talk tracks ("here's why Cube cannot serve sub-second non-additive measure rollups").
- RFP response prep where the buyer is comparing semantic layers — use the protocol matrix and modeling-expressiveness matrix.
- Analyst briefing prep where the question is "what's different about AtScale" — lead with the architecture-type frame.
- Diagnosing a customer's current dbt SL or Cube deployment to find graduation triggers (COUNT_DISTINCT pain, Power BI gap, hierarchy needs, regulated-industry self-host).
- Build-vs-buy reasoning where the team is weighing dbt SL + Cube + AtScale or considering "good enough" with a single tool.

## Out of scope

- AtScale's internal architecture in depth (Attribute Graph mechanics, SML grammar, autonomous-aggregate ML) — use **atscale-technical-reference**.
- Looker / LookML, MicroStrategy, Tableau Semantic Layer, warehouse-native semantic layers (Snowflake Cortex Analyst, Databricks Genie) — different competitor cohort.
- Generic OLAP theory unrelated to these three products' implementations.
- BI-tool visualization design, dashboard UX, warehouse-internal tuning (Snowflake/BigQuery/Databricks internals).
- Pure dbt transformation / dbt Core / dbt Mesh questions where the Semantic Layer is not the topic.

## Source

dbt Semantic Layer (MetricFlow) & Cube — Technical Architecture Teardown, AtScale Reference, 2026-03-25.
