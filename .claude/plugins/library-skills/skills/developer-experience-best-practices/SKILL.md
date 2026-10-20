---
name: developer-experience-best-practices
description: >
  Apply the Developer Experience (DX) playbook for data-platform tools — especially
  semantic layers — to questions about CLI design, SDK/API ergonomics, documentation
  architecture, onboarding/time-to-first-query, error messages, community, open-source
  strategy, and DX metrics. Centers on the full DX surface (Discovery → Evaluation →
  First Use → Building → Debugging → Operating → Advocacy), the DX Iceberg (what
  developers say vs what actually drives adoption), the 5-stage adoption funnel
  (Awareness → Trial → First Value → Habit → Advocacy), the four data-platform
  personas (Data Engineer, Analytics Engineer, AI/ML Engineer, Platform Engineer),
  the Divio docs system (Tutorials / How-To / Explanation / Reference), the First
  5 Minutes audit, the What/Why/Fix/Docs/ID error-message framework, the SPACE
  framework adapted for DX, and the open-core decision matrix. Includes the
  AtScale-specific gap analysis vs Cube and dbt and the prioritized Tier-1/2/3
  improvement roadmap. Use when reviewing or designing a CLI, SDK, quickstart,
  docs site, error message, telemetry plan, community strategy, or DX roadmap;
  when diagnosing why developers bounce; when comparing AtScale DX to Cube/dbt;
  or when scoring a DX investment for impact-vs-effort. Trigger on requests like
  "review our quickstart", "how should I structure our SDK", "what makes a good
  error message", "improve onboarding for new devs", "what's our time-to-first-query",
  "AtScale DX vs Cube", "should we open-source the CLI", "design a developer
  playground", "how do I measure DX". Skip pure BI-dashboard design (this is
  developer-facing tooling, not consumer analytics), warehouse-internal tuning,
  pure marketing/PR strategy (DevRel touches it but isn't marketing), and generic
  product-management framing unrelated to developer-facing surfaces.
version: 1.0.0
last_updated: 2026-05-18
---

# Developer Experience Best Practices — the playbook for data-platform tools

## Core frame
Developer Experience is not "nice documentation." It is the sum of every interaction
a developer has with the product — Discovery, Evaluation, First Use, Building,
Debugging, Operating, Advocacy. Data-platform DX is harder than app-framework DX
because of five constraints: data dependency (can't demo without data), multiple
personas, enterprise context, invisible value, and long feedback loops. The DX
Iceberg: developers *say* they want docs/APIs/SDKs; they *actually* choose tools
on time-to-first-value, error recovery, mental-model fit, confidence, and career
relevance. Stripe, Twilio, dbt, and Cube each won markets on DX, not features.
AtScale's strategic DX gap vs Cube and dbt is the single biggest barrier to
bottom-up adoption — closing it requires CLI, local validator, quickstart with
bundled data, playground, error overhaul, modern docs, Python SDK, and an
open-core posture.

## Key concepts
- **DX surface (7 stages):** Discovery, Evaluation, First Use, Building, Debugging, Operating, Advocacy. DX work touches all seven, not just docs.
- **The DX Iceberg:** stated drivers (docs, APIs, SDKs) vs real drivers (TTFV, error recovery, mental-model fit, confidence, career relevance).
- **Adoption funnel:** Awareness → Trial → First Value → Habit → Advocacy. Best-in-class conversions: A→T 15-25%, T→FV 60-80%, FV→H 30-50%, H→A 10-20%.
- **Time-to-First-Query (TTFQ):** the single most important DX metric for a semantic layer. Target <15 min self-serve, <2 hr enterprise.
- **Four personas:** Data Engineer (CLI/IaC-first), Analytics Engineer (YAML+Git+fast iteration), AI/ML Engineer (Python+DataFrame+MCP), Platform Engineer (Helm/Terraform/SLOs). Each persona has distinct DX priorities — do not collapse into one quickstart.
- **First 5 Minutes audit:** minute-by-minute walkthrough from "Google the tool" → "know what to do next." If any minute requires a sales call, demo form, or license key, you have lost the developer.
- **Divio Documentation System:** four quadrants — Tutorials (learning-oriented), How-To Guides (problem-oriented), Explanation (understanding-oriented), Reference (information-oriented). Never mix them in one document.
- **Progressive Complexity (CLI):** simple things simple, complex things possible. Level 1 defaults → Level 2 explicit flags → Level 3 full control.
- **Dual-Use CLI:** every CLI serves both human-at-terminal (color, prompts, progress bars) and CI/CD script (`--yes`, `--format json`, structured stderr, `NO_COLOR`). Detect via isatty().
- **Error Message Framework:** What happened / Why / To fix (1-3 numbered steps) / Docs link / Error ID. Never ship a bare error code or stack trace.
- **Plan-before-apply:** Terraform-style `plan` → `apply` pattern for semantic-layer deploys. Shows which metrics/aggregates/dashboards will change before executing.
- **Open-core decision matrix:** open-source CLI, SDKs, SML spec, model validator, sample projects. Keep query engine, aggregate engine, enterprise features (RLS/audit/SSO/multi-tenancy) proprietary.
- **SPACE for DX:** Satisfaction, Performance, Activity, Communication, Efficiency. Never measure Activity alone — high activity often means the tool is hard to use.
- **Aha moment:** the quickstart must culminate in the core value prop. For a semantic layer: "I defined the metric once and it's available across three tools."
- **Migration tooling:** importers from LookML / dbt YAML / Cube schema / SSAS TMDL → SML, plus `verify` mode (run same queries through old + new, diff results). Reduces switching costs in competitive displacement.

## Heuristics
- **Stripe rule:** the developer should process their first request in 7 lines of code or fewer. If your equivalent is "fill out this form to request a demo," you have lost the funnel.
- **5-minute quickstart rule (Twilio/Cube):** first valuable result must arrive in ≤5 minutes from landing-page click, with no sign-up form, no sales call, no warehouse credentials.
- **Discoverability rule:** a developer should learn the CLI by using the CLI. `--help` shows grouped commands with descriptions, examples, and next-step pointers — never a wall of flags.
- **Verb-noun commands:** `dbt run`, `terraform apply`, `atscale model validate`. Reads like English. Predictable structure.
- **`debug` as self-diagnostic:** ship `tool debug` / `tool status` so developers can fix setup issues without filing a ticket. Validates config, tests connections, surfaces missing creds.
- **Error = What + Why + Fix + Docs + ID.** Suggest fixes, not just problems. "Column 'revnue' not found. Did you mean 'revenue'?" beats "Column not found." Include file/line/snippet context.
- **No error codes without an explanation alongside.** `ERR_4012` means nothing. Always pair with a human-readable message.
- **Cursor pagination > offset pagination** for data that changes during iteration. Offset breaks when items are inserted/deleted between pages.
- **Versioning rule:** never break existing API versions. Add new versions. Deprecate with ≥12 months notice. Provide a migration guide.
- **Language-idiomatic SDK rule:** Python SDKs return pandas/Polars DataFrames, use context managers, raise typed exceptions. Do not mirror the REST shape — that's not an SDK, that's an HTTP client wrapper.
- **One quickstart per persona.** Do not make one quickstart serve all four. Bundle sample data (Jaffle-Shop-style); never require BYOD.
- **Time-to-first-value beats feature parity.** Stripe lost on features and won the market. Cube wins evaluations against AtScale despite a weaker architecture because TTFQ is 5 minutes vs days.
- **Docs search rule:** if developers cannot find an answer in <2 minutes, they file a ticket, ask in Slack, or give up. Full-text + fuzzy + Cmd+K + search analytics is the baseline.
- **Doc-as-product:** every page has copy-paste-fidelity code samples, "Edit on GitHub," "Was this helpful?", versioning, dark mode, syntax highlighting with language tabs.
- **Community signal rule:** measure community-answered % (>60% healthy, <20% means your team is the support). Ghost-town Slack is worse than no Slack.
- **Telemetry without PII:** never collect query results, column names, or data values. Opt-out via one command. Publish exactly what you collect.
- **Score initiatives on impact × competitive-gap × strategic-alignment / effort.** Tier-1: CLI, local validator, free quickstart. Tier-2: playground, error overhaul, docs rewrite, Python SDK. Tier-3: OSS CLI, IDE plugins, community, migration toolkit.

## When to apply
- Designing or reviewing a CLI for a data-platform product (`init`, `validate`, `deploy`, `query`, `test`, `diff`, `playground`).
- Reviewing a quickstart or "Get Started" flow for time-to-first-value.
- Critiquing or rewriting error messages (CLI, SDK, engine, validation).
- Comparing AtScale DX vs Cube vs dbt or scoping a DX improvement roadmap.
- Choosing protocol mix (REST / GraphQL / gRPC / PGWire / MCP) for a new surface.
- Picking an open-source posture for CLI / SDK / spec / engine.
- Designing developer telemetry and dashboards (TTFQ, quickstart completion, error resolution, SDK adoption by language).
- Building a developer satisfaction survey or DX dashboard using the SPACE adaptation.
- Justifying community / DevRel investment, or critiquing a "ghost town Slack."
- Designing migration tooling from a competitor's modeling format to SML.
- Sequencing a multi-quarter DX program with impact-vs-effort scoring.

## Out of scope
- BI dashboard / visualization UX (developer-facing tooling, not consumer analytics — use a Power BI / Tableau resource).
- Warehouse-internal tuning (Snowflake, Databricks, BigQuery internals).
- Pure marketing/PR strategy (DevRel content overlaps but is not the same as press/communications).
- Sales-enablement and SLG playbook design (DX feeds bottom-up adoption; it doesn't replace enterprise GTM — for that use ecosystem-led-growth or analyst-relations-framework).
- Generic UI/UX heuristics unrelated to developer surfaces (Nielsen heuristics, consumer-app design).

## AtScale-specific lens
The architecture teardown identifies DX as the single largest competitive gap vs
Cube and dbt. AtScale wins on protocol breadth, autonomous aggregation, and
enterprise governance. AtScale loses on TTFQ, self-service onboarding, CLI,
playground, sample projects, and developer community. Root cause is three
strategic choices, not accidents: enterprise-first GTM, protocol-breadth
engineering investment, and OLAP heritage. The Tier-1 fixes (CLI, local
validator, free quickstart with bundled data) are the highest-leverage moves;
Tier-2 (playground, error overhaul, modern docs, Python SDK) closes the
analytics-engineer persona gap; Tier-3 (OSS CLI/SML, IDE plugins, community,
migration toolkit) builds a long-term moat. The roadmap does NOT try to
out-community dbt, compete on price with Cube, or chase Cube features
(GraphQL subscriptions, real-time pre-aggs) that don't serve AtScale's target.

## Source
Developer Experience Best Practices for Data Platform Tools, AtScale Reference,
2026. Cross-refs: dbt-metricflow-cube-technical-architecture, AtScale-Technical-
Reference, prd-writing-guide, data-platform-metrics-telemetry.
