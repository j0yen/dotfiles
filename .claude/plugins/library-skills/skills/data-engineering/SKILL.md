---
name: data-engineering
description: >
  Reference the Reis & Housley *Fundamentals of Data Engineering* lens (via the
  DeepLearning.AI Data Engineering Professional Certificate) for end-to-end
  data-platform design questions — moving raw source data through ingestion,
  storage, transformation, and serving while threading six undercurrents
  (security, data management, DataOps, architecture, orchestration, software
  engineering) underneath. Centers on the Data Engineering Lifecycle, the
  4-Step Framework (goals → requirements → tools → build/iterate), the 9
  Principles of good architecture, the warehouse/lake/lakehouse trichotomy,
  Kimball-vs-Inmon-vs-Data-Vault-vs-OBT modeling, Lambda/Kappa/Unified
  streaming patterns, ETL/ELT/EtLT, CDC, the Iron Triangle, and one-way-vs-
  two-way-door decisions. Use when designing or reviewing a pipeline,
  picking batch vs streaming, choosing a modeling approach, scoping AWS data
  services, framing requirements for a stakeholder, or sequencing a DataOps
  rollout. Trigger on requests like "design a data pipeline for X", "should
  this be batch or streaming", "ETL vs ELT", "star schema vs Data Vault vs
  OBT", "Lambda vs Kappa architecture", "what are the undercurrents", "Kimball
  vs Inmon", "how do I gather data requirements", "which AWS service for
  ingestion / storage / orchestration", "CDC strategy", "is this a data
  swamp", "MapReduce vs Spark", "row vs column store", "what's a semantic
  layer in serving". Skip ML-system operational concerns like drift,
  train/serve skew, and continual learning (use designing-ml-systems),
  lakehouse-deep open-table-format teardowns (use practical-lakehouse-
  architecture), AtScale semantic-layer internals (use atscale-technical-
  reference), and BI dashboard design.
version: 1.0.0
last_updated: 2026-05-18
---

# Data Engineering — raw-to-served, with six undercurrents under everything

## Core frame
A data engineer takes in raw data from source systems they do not control and produces high-quality, consistent information for downstream consumers. The Data Engineering Lifecycle is **Generation → Ingestion → Transformation → Serving**, with **Storage underpinning every stage**, and six undercurrents (Security, Data Management, DataOps, Data Architecture, Orchestration, Software Engineering) running beneath all of it. Every project follows the cyclical **4-Step Framework**: identify business goals and stakeholder needs → define functional + non-functional requirements → choose tools → build, evaluate, iterate, and loop back. Good data architecture is "flexible and reversible decisions reached through careful evaluation of trade-offs" — favor two-way doors, loosely coupled components, and FinOps awareness.

## Key concepts
- **Data Engineering Lifecycle** — Generation → Ingestion → Transformation → Serving; Storage underpins all stages. The mental model the whole field hangs from.
- **6 Undercurrents** — Security, Data Management, DataOps, Data Architecture, Orchestration, Software Engineering. They cut across every lifecycle stage simultaneously.
- **4-Step Framework** — (1) business goals & stakeholders → (2) functional + non-functional requirements → (3) tools/tech with cost-benefit → (4) build, evaluate, iterate, evolve, **loop back to step 1**.
- **9 Principles of Good Data Architecture** — Choose common components wisely; Plan for failure; Architect for Scalability; Architecture is leadership; Always be Architecting; Build loosely coupled systems; Make reversible decisions; Prioritize Security; Embrace FinOps.
- **One-way vs two-way door decisions** — One-way = nearly irreversible (e.g. foundational enterprise architecture). Two-way = easily reversible (e.g. S3 storage class). Favor two-way doors.
- **Iron Triangle** — Scope, Cost, Timeline: pick two. Break it with loosely coupled components + two-way doors + stakeholder collaboration.
- **Storage abstractions** — Data Warehouse (schema-on-write, structured BI), Data Lake (schema-on-read, raw, ML/big data), Data Lakehouse (both, on open table formats: Iceberg / Delta Lake / Hudi).
- **Batch vs Streaming** — Batch = minutes-to-hours, cheaper, simpler maintenance. Streaming = <1s, more expensive, operationally complex. Microbatch sits between.
- **ETL / ELT / EtLT** — ETL transforms pre-load (limited storage). ELT loads raw, transforms in warehouse (cheap cloud storage) — **risk: data swamp**. EtLT = light pre-load + heavy post-load.
- **CDC (Change Data Capture)** — Track row-level source changes for incremental loading. Capture-updates: insert-only (full history) vs upsert (latest). Capture-deletes: hard / soft / insert-only.
- **Modeling approaches** — Kimball (bottom-up star schemas, fast delivery), Inmon (top-down 3NF, enterprise SSOT), Data Vault (Hubs/Links/Satellites, insert-only, auditable, change-friendly), One Big Table (denormalized wide table, columnar-friendly).
- **Star schema 4-step conversion** — Pick business process → declare grain → identify dimensions (who/what/where/when) → identify facts (measures). Use surrogate keys (e.g. MD5 of business key) to decouple from source.
- **Streaming architecture patterns** — Lambda (two paths: batch + stream, complex), Kappa (single stream path, replay from log), Unified (same code for bounded + unbounded, e.g. Beam/Flink).
- **DataOps three pillars** — Automation (IaC: Terraform), Observability & Monitoring (volume/null/distribution/freshness; Great Expectations, CloudWatch), Incident Response.
- **Principle of Least Privilege** — Give users/apps access to only the essential data and resources they need, for only the duration required.
- **Source systems are unpredictable** — Outages, schema changes, silent data-content shifts. The DE does **not** control them.
- **Semantic layer (serving)** — Abstraction providing consistent definitions, logic, and business metrics on top of physical data; built in BI (LookML) or dbt.

## Heuristics
- **Storage underpins everything.** Whenever you sketch a pipeline, draw storage *under* generation, ingestion, transformation, and serving — not as a sibling stage.
- **Stakeholders first; tools last.** Never start at "which tool" — start at "which business goal and what action will the stakeholder take with this data?" Step 3 (tools) is third for a reason.
- **Translate to functional + non-functional, then confirm.** Functional = what the system does ("ingest every 15 min"). Non-functional = how well (latency, availability, cost, throughput, security). Document and **confirm with stakeholders** before choosing tools.
- **Favor two-way doors.** When a decision is reversible, choose the cheaper/simpler option and iterate. Reserve deep analysis for one-way doors.
- **Loosely couple to survive change.** Source schemas, regulations (GDPR/HIPAA/SOX), and stakeholder needs will all shift. Loose coupling lets you swap components without rewriting the platform.
- **Batch unless you have a real streaming use case.** Streaming is more expensive and operationally heavier. Demand a stakeholder-grounded reason for sub-second latency before reaching for Kinesis/Kafka/Flink.
- **ELT is the default in cloud, but guard against the data swamp.** Cheap storage makes "load raw first" the right move — pair it with schema management, data quality checks, and curated zones (landing → cleaned → curated → analytics).
- **Use surrogate keys in the warehouse.** Decouple from source business keys with hashed surrogates so source-system reorgs don't break your star.
- **Pick the modeling approach by use case.** Kimball for fast analytics delivery; Inmon for enterprise SSOT; Data Vault for auditability and changing sources; OBT when storage is cheap, schema is wide, and joins are too expensive.
- **A silent data failure is worse than an outage.** A 404 alerts you. Data drift produces low-quality output that downstream consumers trust. Monitor volume, nulls, distribution, freshness — but avoid alert fatigue by anchoring metrics to stakeholder requirements.
- **MapReduce-style I/O is the bottleneck.** Prefer Spark (in-memory, lazy evaluation) over raw MapReduce; prefer Flink for true sub-second streaming over Spark Streaming's microbatch.
- **Columnar for OLAP, row for OLTP.** Redshift/BigQuery/Snowflake for analytics. MySQL/PostgreSQL for transactions. Parquet > CSV at the file layer when you're going to scan.
- **Cost = TCO, not invoice.** Business value = benefits − costs, and costs = direct + indirect (ops burden, retraining, lock-in). Embrace FinOps as a first-class architecture principle.
- **Apply XCom only to small metadata.** In Airflow, pass dates/metrics through XCom; route large datasets through S3.

## When to apply
- **"Should this be batch or streaming?"** → Anchor in stakeholder latency tolerance + cost. Batch unless sub-minute matters for action. Microbatch is the middle ground.
- **"ETL or ELT?"** → Cheap cloud storage + warehouse compute → ELT (with dbt). Limited storage or pre-load transforms required → ETL. Mix → EtLT.
- **"Which modeling approach?"** → Kimball (fast BI), Inmon (enterprise SSOT), Data Vault (changing sources + audit), OBT (columnar, simple queries, no joins).
- **"Lambda or Kappa?"** → Kappa if you can replay from the log; Lambda only if batch and stream genuinely diverge in logic. Unified (Beam/Flink) if your team can absorb the framework.
- **"How do I gather requirements?"** → 4-Step Framework, step 1–2. Ask stakeholders what *action* they'll take with the data, then translate to functional + non-functional and confirm.
- **"Which AWS service?"** → Storage: S3 (object/lake), EBS (block), EFS (file), RDS (relational), DynamoDB (NoSQL), Redshift (warehouse). Ingestion: Glue ETL (managed), EMR (control), Kinesis (managed stream), MSK (managed Kafka), Firehose (zero-code delivery). Orchestration: MWAA (Airflow), Step Functions (serverless), Glue Workflows (ETL-only). Query: Athena (serverless SQL on S3).
- **"How do I avoid a data swamp?"** → Zones (landing/raw → cleaned → curated → analytics), schema management on the lake, ACID via lakehouse table formats, data observability.
- **"How do I roll out DataOps?"** → IaC (Terraform), data observability (Great Expectations + CloudWatch), and an incident-response loop — Plan → Create → Deploy → Monitor → Improve.
- **"Is this architecture good?"** → Run it against the 9 Principles, especially loose coupling, reversibility, and FinOps. If it fails on multiple, it's brittle.

## Out of scope
- **ML system operations** (drift detection, train/serve skew, continual learning, feature stores in depth, online-vs-batch prediction). Use `designing-ml-systems`.
- **Lakehouse open-table-format teardowns** (Iceberg vs Delta vs Hudi internals, catalog choice, medallion zone design beyond the basics). Use `practical-lakehouse-architecture`.
- **AtScale semantic-layer internals** (Attribute Graph, autonomous aggregates, SML, MCP server, DAX/MDX/SQL/PGWire routing). Use `atscale-technical-reference`.
- **BI visualization design** (dashboard layout, chart selection, Tableau/Looker/Power BI report craft).
- **Pure software-engineering / cloud-foundation questions** unrelated to data flow (web app architecture, mobile, generic Kubernetes, non-data IAM).

## Source
Data Engineering, AtScale Reference, 2026. Distilled from the DeepLearning.AI *Data Engineering Professional Certificate* (Courses 1–4), based on Joe Reis & Matt Housley, *Fundamentals of Data Engineering*.
