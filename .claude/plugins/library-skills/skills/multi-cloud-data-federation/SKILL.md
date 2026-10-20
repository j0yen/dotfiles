---
name: multi-cloud-data-federation
description: >
  Apply the multi-cloud data federation lens to questions about querying analytical data across
  Snowflake, Databricks, BigQuery, Redshift, and Synapse without moving it. Centers on the
  5-level federation spectrum (Simple Connectors → Cross-DB Queries → Federated Joins →
  Distributed QP → Autonomous Multi-Platform), the physics of cross-cloud latency, egress as
  the hidden tax ($0.09–0.12/GB), the cost-model mismatch (Snowflake credits vs BigQuery
  TB-scanned vs Databricks DBUs), SQL dialect translation gotchas, virtual vs materialized
  federation, the "primary platform plus satellite" reality, and AtScale's structural advantage
  as the only platform-neutral federation layer (Attribute Graph + autonomous aggregates +
  MDX/DAX). Use when scoping a multi-cloud architecture, debating build-vs-buy federation,
  positioning AtScale against Trino/Starburst, Dremio, Denodo, or platform-native features
  (Snowgrid, Lakehouse Federation, BigQuery Omni), sizing egress cost, or deciding whether
  federation is a real need or an insurance policy. Trigger on requests like "should we
  federate across clouds", "egress costs for cross-cloud queries", "Snowflake on AWS plus
  BigQuery — how do we federate", "Trino across regions", "Databricks Lakehouse Federation vs
  AtScale", "virtual vs materialized federation", "data sovereignty multi-cloud", "post-M&A
  federation", "BigQuery Omni vs Snowgrid". Skip pure single-platform tuning (use
  atscale-technical-reference), pure data-engineering pipeline design (use data-engineering),
  metric/semantic-modeling questions unrelated to federation (use atscale-technical-reference),
  and write/transactional consistency questions — federation here is analytical and read-only.
version: 1.0.0
last_updated: 2026-05-18
---

# Multi-Cloud Data Federation — Query Where the Data Lives

## Core frame
Multi-cloud data federation is the ability to execute analytical queries across multiple, independent cloud data platforms — Snowflake, Databricks, BigQuery, Redshift, Synapse — without copying or moving the data first. It is NOT ETL, NOT replication, NOT multi-region deployment of the same platform, and NOT data mesh (which is organizational, not a query capability). The core technical act: a federated engine decomposes one logical query into platform-specific sub-queries, pushes predicates/projections/aggregations down, collects intermediate results across the network, and assembles a unified answer. Federation is bounded by physics (speed of light + egress pricing) and by the heterogeneity of cost models, SQL dialects, security models, and statistics. The honest take: federation is critical for ~30–40% of large enterprises (post-M&A, best-of-breed, sovereignty, in-flight migration) and a strategic insurance policy for another 40–50%. Position it as additive, never as the sole reason to buy.

## Key concepts
- **The 5-level federation spectrum.** L1 Simple Connectors (Pandas + ODBC) → L2 Cross-DB Queries (Snowflake External Tables, BigQuery federated queries) → L3 Federated Joins (Trino/Starburst, Dremio, Denodo) → L4 Distributed Query Planning (cost-based, cross-platform — few products achieve this) → L5 Autonomous Multi-Platform (auto-materialize cross-platform aggregates from observed patterns — AtScale's aspiration).
- **Five drivers of multi-cloud.** M&A integration, best-of-breed by team, data sovereignty (GDPR/CCPA/PIPL), vendor negotiation leverage, lock-in avoidance.
- **Distributed query planning hardness.** Single-DB has unified stats + cost units. Federated has stale/partial stats, heterogeneous cost models (credits vs TB-scanned vs DBUs), no global join-strategy control, network-bounded intermediate results, and partial-failure semantics.
- **Network latency table.** Same region 0.1–0.5ms / 10–25Gbps. Cross-region same cloud 10–80ms / 1–5Gbps. Cross-cloud 5–30ms / 1–10Gbps. Cross-cloud cross-continent 100–300ms. A 500MB intermediate transfer at 1Gbps ≈ 4s before joining.
- **Egress as the hidden tax.** Snowflake $0.09/GB (AWS). BigQuery $0.12/GB. Databricks/Redshift at cloud-provider rates. 1TB egress ≈ $90–120 per transfer. A 10GB query × 100/day = $33K–44K/yr in pure transfer fees. This is why materialized federation often beats pure virtual for hot queries.
- **Cost-model mismatch.** Snowflake = credit-seconds (warehouse × time). BigQuery = $6.25/TB scanned (on-demand) or slot-hours. Databricks = DBUs. Redshift = node-hours or RPU-hours. No common unit — global cost-based optimization is unsolved.
- **SQL dialect traps.** `DATEDIFF(unit, start, end)` (Snowflake) vs `DATE_DIFF(end, start, unit)` (BigQuery — reversed args, silent wrong results). BigQuery/Spark `CONCAT('a', NULL) = 'a'` (drops NULL) vs Snowflake/Redshift `'a' || NULL = NULL` (propagates). QUALIFY supported by Snowflake/Databricks/BigQuery (2023+), not Redshift. Type systems, NULL ordering, semi-structured types all diverge.
- **Consistency reality.** No global transaction coordinator across independent SaaS platforms exists. Strong consistency = impossible. Per-source snapshot isolation = achievable but not coordinated. Eventual consistency = the operational reality. Mitigate with time-based windowing, watermark tables, idempotent loads.
- **Virtual vs materialized federation.** Virtual = query in place, no copies, real-time, slow on cross-platform joins. Materialized = selectively pre-compute / cache the hot 20% of cross-platform joins where they are consumed. The autonomous aggregate engine turns federation from a real-time problem into a batch problem.
- **Federation engines.** Trino/Starburst (L3–4, 40+ connectors, own compute cluster, no semantic layer, no MDX/DAX). Dremio (L3–4, Arrow Flight native, reflections ≈ aggregates, lakehouse-leaning). Denodo (L3–4, 150+ sources, mature enterprise, not cloud-native origin, no OLAP protocols). AtScale (L5 aspiration, pushes to warehouse compute rather than running its own, semantic layer + MDX/DAX + autonomous aggregates).
- **Platform-native cross-cloud.** Snowflake = Snowgrid + cross-cloud replication + Data Sharing + Iceberg (intra-Snowflake only). Databricks = Delta Sharing (vendor-neutral, read-only) + Unity Catalog + Lakehouse Federation (Databricks-as-hub). BigQuery = Omni (BQ compute in AWS/Azure on S3/ADLS) + BigLake + federated queries (GCP-hosted DBs only).
- **The platform-neutrality structural argument.** Every platform's "cross-cloud" features are designed to keep you in that platform — Snowgrid keeps you in Snowflake, Lakehouse Federation makes Databricks the hub, Omni brings BigQuery to other clouds. A platform-independent federation layer has no structural incentive to deprioritize any vendor. This is unreplicable by platform incumbents without undermining their own business.
- **Arrow Flight.** gRPC + columnar transport, 20–100× faster than JDBC/ODBC for large result sets. Solves the transfer problem, not the query-planning problem. Adoption: Dremio native, BigQuery Storage API yes, Databricks emerging via Spark Connect, Snowflake not yet.
- **The MDX/DAX moat.** ~60% of enterprises use Power BI as primary BI. No competing federation product (Trino, Dremio, Denodo) implements DAX or MDX. Building a compliant XMLA/DAX engine is years of work. AtScale is the only federation-capable product that serves Power BI/Excel natively across multiple platforms.
- **Primary-plus-satellite reality.** Typical multi-platform enterprise has 70–80% data + 80–90% queries on a primary platform, 15–25% data + 10–15% queries on satellite #1, <5% on satellite #2. Cross-platform queries are 5–15% of analytical workload, not the majority.

## Heuristics
- **Move data vs move compute.** If a small reference table is hit by many federated queries, a one-time copy (with refresh discipline) beats recurring egress + cross-cloud compute every time.
- **Aggressive pushdown first.** Push filters, projections, partial aggregations to each source. Pull only the minimal intermediate. This dominates every other optimization.
- **Bloom-filter shipping for skewed joins.** Send a Bloom filter of join keys from the smaller side to the larger side's platform; let the large platform pre-filter before transmitting.
- **Materialize the 20% that drive 80%.** Identify recurring cross-platform join shapes and pre-compute them as aggregates in the platform that serves most queries. Convert real-time federation into batch pre-computation.
- **Place aggregates by data gravity + query volume + compute cost + refresh cost.** Usually data gravity wins — put aggregates where the biggest contributing table lives.
- **Semantic layer as schema indirection.** Map logical → physical column names in one place (SML dataset). When a platform-side rename hits, update one mapping, not every downstream report.
- **Federation latency budget ≠ operational latency budget.** Cross-platform joins have irreducible network cost. Use federation for strategic dashboards (hourly refresh, 30s queries OK), not sub-second operational queries.
- **Don't promise transactional consistency across clouds.** Document eventual-consistency as a feature, not a bug. Use watermark tables to gate cross-platform queries until all upstream loads are done.
- **Treat "primary platform + satellites" as the default architecture.** Build the semantic layer to work great on one platform, gracefully across many. Most queries will stay single-platform.
- **Federation is rarely the sole reason to buy.** Lead with semantic layer, governance, MDX/DAX, autonomous performance. Federation is what makes that investment future-proof, not the headline.

## When to apply
- Scoping a multi-cloud architecture or critiquing one a customer has proposed.
- A prospect describes a post-M&A, best-of-breed split, sovereignty, or migration-bridge scenario.
- Comparing AtScale to Trino/Starburst, Dremio, Denodo, or platform-native federation (Snowgrid, Lakehouse Federation, BigQuery Omni, Delta Sharing).
- Sizing egress cost or query-latency budget for a cross-cloud workload.
- Deciding virtual vs materialized federation, or where to place a cross-platform aggregate.
- Pushing back on "federation enables real-time, any-to-any joins" overclaim, or framing federation as insurance for a still-single-platform enterprise.
- Responding to "why not just use Databricks Lakehouse Federation / Snowflake External Tables / BigQuery Omni" — invoke the platform-neutrality structural argument.

## Out of scope
- Single-platform query tuning, semantic-model details, or AtScale internals beyond the federation lens — use `atscale-technical-reference`.
- Data-pipeline / ELT / ingestion design upstream of federation — use `data-engineering`.
- Cross-platform write transactions and operational data sync — federation here is analytical, read-only.
- Real-time streaming federation (Kafka stream joined to warehouse) — no federation product supports this well today.
- Pure data-mesh / data-contract questions — use `data-mesh-data-contracts`. Federation is the query capability; mesh is the org principle.

## Source
Multi-Cloud Data Federation — Technical Reference, AtScale Reference, 2026-03-25.
