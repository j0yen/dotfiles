---
name: data-governance-compliance-deep-dive
description: >
  Apply the AtScale data-governance-and-regulatory-compliance lens — how SOX 404, GDPR,
  HIPAA, CCPA/CPRA, EU AI Act, SOC 2 Type II, FedRAMP, Basel III/IV, Solvency II, and
  FDA 21 CFR Part 11 translate into concrete semantic-layer requirements (RBAC, ABAC,
  RLS, CLS, dynamic masking, metric versioning, audit trails, lineage, classification,
  AI query governance, model cards, compliance evidence). Centers on the governance
  maturity model (Levels 1–5), centralized / federated / hybrid org patterns with data
  stewards and governance councils, the semantic layer as security boundary for AI
  (prompt-injection / exfiltration defense), and competitive positioning vs dbt SL,
  Cube, Unity Catalog, and Snowflake Horizon. Use when scoping governance features,
  reviewing an RFP security section, writing the compliance section of a PRD, framing
  a regulated-enterprise deal, or assessing competitive gaps. Trigger on requests like
  "how do I structure data governance", "what controls do I need for HIPAA", "SOX
  audit trail for metrics", "GDPR right to be forgotten in a semantic layer", "EU AI
  Act risk classification for text-to-SQL", "metric approval workflow", "RACI for the
  analytics team", "RBAC vs ABAC vs RLS vs CLS", "catalog integration with Collibra
  Purview", "FedRAMP for our product", "small-cell suppression for PHI", "compliance
  evidence generation", "how do I write the governance section of a PRD". Skip pure
  BI-visualization design, warehouse-internal security tuning (Snowflake masking
  policies / Unity Catalog mechanics — point at those products), generic cybersecurity
  questions unrelated to analytics data, and pure data-modeling questions with no
  compliance angle.
version: 1.0.0
last_updated: 2026-05-18
---

# Data Governance & Compliance Deep Dive — the semantic layer as the governance enforcement point

## Core frame

A semantic layer sits between every consumption tool (BI, Excel, Python, AI agents) and the warehouse. That position makes it either the strongest governance enforcement point in the stack — or the worst single point of failure. Every regulation that touches analytics (SOX 404, GDPR, HIPAA, CCPA/CPRA, EU AI Act, SOC 2, FedRAMP, FDA 21 CFR Part 11, Basel III/IV, Solvency II, PCI DSS) decomposes into the same handful of capabilities: classify data, enforce access (RBAC/ABAC/RLS/CLS/masking), version and approve metric definitions, produce tamper-evident audit trails, prove lineage, suppress small-cell PHI, and govern AI queries identically to human queries. Governance is a maturity ladder (Ad Hoc → Repeatable → Defined → Managed → Optimized) and the buyer's level decides which features they will actually pay for. The competitive thesis: cross-protocol security enforcement and AI-query audit parity are unique semantic-layer advantages over warehouse-native (Snowflake/Databricks) and code-only (dbt SL, Cube) competitors — but data classification, dynamic masking, catalog integration, and compliance-evidence generation are the gaps that lose deals today.

## Key concepts

- **SOX Section 404** — US public-company ICFR. Requires immutable audit logs, metric version history, approval workflows, segregation of duties, access-control evidence, 7-year retention. PCAOB AS 2201 increasingly scrutinizes IT-dependent controls. Strongest enterprise sales argument for a governed semantic layer.
- **GDPR (EU 2016/679)** — Articles 5 (data minimization), 17 (RTBF), 22 (automated decision-making — affects text-to-SQL feeding decisions), 25 (privacy by design). Penalties up to 4% global revenue or EUR 20M. The "aggregation paradox": RTBF may require aggregate rebuilds if a motivated intruder could re-identify.
- **HIPAA** — Safe Harbor's 18 identifiers (45 CFR §164.514), minimum necessary standard, 6-year audit retention, BAA for any PHI processor. Demands small-cell suppression (typically 5–11) with complementary suppression for cross-tabs.
- **CCPA/CPRA** — California opt-out model (not opt-in like GDPR); CPPA enforcement; broader "sensitive PI" (financial accounts, precise geolocation); per-violation penalties can exceed GDPR at scale. 19+ US state laws converge on this baseline.
- **EU AI Act (Reg. EU 2024/1689)** — Risk tiers: unacceptable / high / limited / minimal. Text-to-SQL is generally limited risk (transparency obligation) unless feeding high-risk downstream decisions (credit, HR, essential services), which makes the chain high-risk. Full high-risk requirements by August 2026. Up to 7% global revenue or EUR 35M for prohibited AI.
- **SOC 2 Type II** — AICPA Trust Services Criteria (Security required; Availability, Processing Integrity, Confidentiality, Privacy optional). Type II = 6–12 month operating-effectiveness period. Table stakes for enterprise SaaS procurement.
- **FedRAMP** — Low / Moderate / High (~125 / 325 / 421 NIST 800-53 controls). FIPS 140-2 crypto, GovCloud, US residency. $500K–$2M and 12–18 months for Moderate. AtScale gap; Databricks and Snowflake have it.
- **FDA 21 CFR Part 11** — Electronic records / signatures for life sciences. IQ/OQ/PQ system validation, attributable signatures on approvals, tamper-evident audit trail. Most demanding analytics audit standard in any industry.
- **RBAC / ABAC / RLS / CLS** — Role-, attribute-, row-, column-level access control. RBAC suffers role explosion; ABAC scales but is hard to audit; no semantic-layer vendor has full ABAC. RLS via filter injection, security views, or warehouse-native row policies. CLS via hiding, static masking, dynamic masking, or tokenization.
- **Metric lifecycle (Draft → Review → Certified → Deprecated → Retired)** — Each stage logs author, reviewer, approver, justification, version. Approval workflows are a Level-3 must-have and a competitive gap across all semantic layers.
- **Tamper-evidence patterns** — Write-once storage (S3 Object Lock, Azure Immutable Blob), cryptographic chaining, real-time SIEM forwarding (Splunk / Sentinel / Chronicle), digital signatures. Required for SOX, HIPAA, 21 CFR 11. Recommended: real-time SIEM forwarding + write-once primary.
- **Lineage levels** — Table-level (insufficient), column-level (necessary), metric-to-source (gold standard), business lineage (auditor-readable). Semantic layer is uniquely positioned for metric-to-source.
- **Classification taxonomy** — Public / Internal / Confidential / Restricted-or-Regulated. Manual classification doesn't scale; need automated detection (pattern matching, column-name heuristics, profiling, ML, catalog import from Collibra / Alation / Atlan / Purview).
- **Governance maturity model (Levels 1–5)** — Ad Hoc → Repeatable → Defined → Managed → Optimized. ~65% of enterprises are at Levels 2–3; design for Level 3 with a path to 4. Level 5 is co-dev with design partners.
- **Hybrid governance + data steward + governance council** — Most common org pattern. Central framework + domain stewards (metric ownership, quality, access reviews, classification, policy enforcement, change management, incident response). Council meets quarterly.
- **Semantic layer as AI security boundary** — Primary defense against prompt injection / exfiltration: AI generates queries against the semantic model (not raw tables), so RLS/CLS applies before SQL is generated and the AI cannot see unauthorized tables, columns, or join paths.
- **Model card** — Standardized AI documentation (overview, model details, performance, ethical considerations, regulatory mapping). Accelerates enterprise security review by 2–4 weeks.
- **Small-cell suppression** — Suppress aggregate results below a minimum count (5–11), with complementary suppression to prevent inference from marginal totals. Required for HIPAA; no semantic-layer competitor has it.

## Heuristics

- **If financial metrics flow through it, SOX applies.** Don't ask "are we in scope"; assume yes for any public-company customer and design the audit-trail / change-control / segregation-of-duties controls accordingly.
- **Build for the strictest privacy regime (GDPR), then CCPA/CPRA is free.** Per-state compliance does not scale to 19+ US laws.
- **The semantic layer must be the AI security boundary, not a bypass.** If the AI can generate SQL that runs around the semantic model, every governance control is void. RLS/CLS must apply to AI queries identically to human queries — verify in the test matrix.
- **Cross-protocol parity is the differentiator.** RLS/CLS must enforce identically across DAX, MDX, SQL, PGWire, Python, and MCP. A policy violation via any protocol is a P0 bug.
- **Tamper-evidence requires the application to not be the sole custodian.** Real-time SIEM forwarding satisfies auditors that the vendor can't retroactively modify logs.
- **Map regulations to features, not features to regulations.** Start from the applicable-regulations checklist (SOX / GDPR / HIPAA / CCPA / EU AI Act / 21 CFR 11 / PCI DSS / industry) and derive NFRs. The reverse produces feature piles.
- **Classify before you control.** Without classification, every other control is guesswork. Classification is the foundation; everything else is enforcement.
- **Design for Level 3 buyers; roadmap for Level 4.** That's where the paying volume is. Level 5 is co-dev with a design partner, not GA.
- **Approval workflows beat Git PRs for SOX-designated metrics.** SOX auditors want named approvers with attributable signatures and explicit dual-control on financial metrics.
- **High-risk EU AI Act classification is contagious.** A limited-risk text-to-SQL feature becomes high-risk if its output feeds credit / HR / essential-services decisions. Classify by downstream usage, not in isolation.
- **Governance lock-in should be value-based, not portability-based.** Support OpenLineage and Open Data Contract Standard alongside proprietary capabilities — paradoxically increases retention by reducing buyer commitment anxiety.
- **In RFPs: table stakes get you invited (SSO, RBAC, SOC 2, encryption); differentiators get you shortlisted (cross-protocol security, AI audit parity, SML governance-as-code); gaps lose the deal (FedRAMP, catalog integration, dynamic masking, lineage).**

## When to apply

- **"Write the compliance section of this PRD"** → Use the three NFR categories (Regulatory NFRs, Security NFRs, Governance-Enabling FRs) and the PRD template: applicable regulations checklist → access control → audit trail → AI governance → quality SLA → compliance evidence audience.
- **"What does SOX require from our semantic layer"** → Immutable audit logs, Git-like metric version history with diff/rollback, approval workflows on SOX-designated metrics with attributable signatures, exportable access-control reports, reconciliation to investor-reported values, 7-year retention.
- **"HIPAA compliance for a healthcare deal"** → BAA, Safe Harbor at semantic layer (state-level geographic cap, year-quarter date cap, age 89+ bucket, ZIP-3), minimum-necessary RBAC, role-purpose-time-limited research access, small-cell suppression (threshold 5–11) with complementary suppression, 6-year audit retention.
- **"Classify this AI feature under EU AI Act"** → Decision tree: credit / employment / essential services / law enforcement / education → high-risk; interacts with humans → limited risk; everything else → minimal risk. Then check downstream contagion.
- **"GDPR RTBF in an analytics platform"** → Erasure propagation from warehouse to aggregates and caches, audit-log design that captures query metadata without PII values, aggregation-paradox DPIA assessment, Article 22 flagging for AI queries feeding automated decisions.
- **"AtScale vs dbt SL vs Cube vs Unity Catalog vs Snowflake on governance"** → AtScale wins cross-protocol security + AI audit parity; loses on dynamic masking, catalog integration, lineage, FedRAMP. dbt SL has no semantic-layer-level access control (fundamental gap). Platform-native (Unity Catalog, Horizon) is deep within ecosystem but creates silos in multi-cloud.
- **"How do I structure our data governance team"** → Hybrid model: central framework (taxonomy, minimum controls, cross-domain reconciliation) + domain stewards (metric ownership, quality, access reviews, classification) + quarterly governance council (CDO chairs; stewards, security, legal, business, IT).
- **"Prompt injection / exfiltration defense for text-to-SQL"** → Semantic layer as security boundary (primary), RLS/CLS on AI queries (critical), query allowlisting (high), output filtering for dangerous SQL patterns (moderate), result-set validation, prompt hardening, anomaly alerting.
- **"Which governance features next"** → Regulatory Customer Impact Matrix. P1: dynamic masking, metric approval workflows, Collibra/Purview integration, SOX evidence generator. P2: classification annotations in SML, end-to-end lineage, HIPAA small-cell suppression, EU AI Act transparency labels, change impact analysis. P3: FedRAMP, 21 CFR 11, governance dashboard.
- **"What artifacts do auditors actually want"** → SOX: control matrix, access review, query audit. GDPR: DPIA, ROPA. HIPAA: access audit reports, risk assessment. SOC 2: control evidence package. EU AI Act: conformity assessment, transparency disclosure. 21 CFR 11: validation evidence (IQ/OQ/PQ). A compliance-evidence generator saves 100+ hours per audit and is a premium add-on.

## Out of scope

- **Pure BI visualization design** — Tableau / Power BI report formatting, dashboard UX. Use a BI-specific resource.
- **Warehouse-internal security mechanics** — Snowflake masking policy syntax, Unity Catalog row-filter internals, BigQuery authorized-view tuning. Point at the warehouse documentation; this lens is the semantic layer.
- **Generic cybersecurity / SOC engineering** — Firewall rules, SIEM tuning, EDR, network segmentation. This skill is data governance and analytics compliance, not enterprise InfoSec.
- **Pure data modeling questions** — Star schema, SCDs, naming conventions with no compliance angle. Use a Kimball / modeling resource.
- **Legal interpretation** — "Does this specific scenario violate Article 22?" Escalate to actual counsel; this lens is the product / engineering interpretation.

## Source

Data Governance & Regulatory Compliance Deep Dive, AtScale Reference, 2026-03-25. Cross-refs: AtScale Technical Reference (security model, audit), Enterprise Data Buyer Personas (governance lead, CDO), AI Product Management Patterns (AI governance, trust), Data Mesh & Data Contracts (federated governance).
