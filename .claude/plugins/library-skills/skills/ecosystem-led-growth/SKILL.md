---
name: ecosystem-led-growth
description: >
  Apply Bob Moore's *Ecosystem-Led Growth* (ELG) framework to GTM, sales, marketing, partnerships, and customer-success questions where the engine is the partner ecosystem (not the rep or the product). Centers on the account mapping matrix (nine cells: overlap × stage with partners), second-party data, the partnership paradox, the readiness matrix, and four playbooks (ecosystem development, ecosystem-led marketing with EQLs and ABM, ecosystem-led sales with co-selling and marketplaces, ecosystem-led customer success focused on NRR and integration adoption). Use when user asks about partnerships, channel/tech/strategic alliances, co-selling, account mapping with partners, Crossbeam-style data sharing, marketplace strategy, EQLs vs MQLs, partner tiers, integration-driven retention, or how to build a partner motion alongside PLG/SLG. Trigger on requests like "should we invest in partnerships", "what's an EQL", "how do we do account mapping with partner X", "co-sell motion", "partner tiers", "PRM vs ELG platform", "Crossbeam", "we're hitting cold-outbound fatigue", "how do partnerships drive NRR", "second-party data". Skip pure PLG product growth tactics (use a PLG-specific resource), traditional channel-program-only questions (this is the broader ELG frame), and CRM/RevOps infrastructure questions — Moore's frame is the GTM motion, not the tooling.
version: 2.0.0
last_updated: 2026-05-18
---

# Ecosystem-Led Growth — Bob Moore

## Core frame

**Ecosystem-led growth (ELG) is the third major modern GTM pattern**, alongside product-led (PLG) and sales-led (SLG), where the engine of sourcing, winning, and retaining customers is the partner *ecosystem* itself — not the product, not the rep. Three forces make it viable now: (1) the modern data stack makes cross-org partner-data analysis affordable; (2) cold outbound and freemium are saturated; (3) ELG platforms (Crossbeam, Reveal) solved the *partnership paradox* — the historical inability to share account data securely. The signature instrument is the **account mapping matrix** (nine cells: overlap × stage per partner). Four playbooks operationalise it: ecosystem development, ecosystem-led marketing, ecosystem-led sales, ecosystem-led customer success.

## Key concepts

- **ELG** — go-to-market motion where the partner ecosystem sources, wins, and retains customers. Third pattern alongside PLG and SLG.
- **Partnership paradox** — the historical inability for two companies to compare account data without leaking competitive info. Solved by ELG platforms.
- **Account mapping matrix (nine cells)** — overlap status × pipeline stage, per partner. Each cell is a specific play (joint open opportunity, joint customer, expansion, save, etc.).
- **Second-party data** — data the partner shares with you (with their customers' consent), distinct from first-party (yours) and third-party (intermediated).
- **EQL (Ecosystem-Qualified Lead)** — a lead that has been validated by partner data signals (the partner has a relationship). Higher converting than MQL/SQL because of the warm-intro layer.
- **ELG platform** — Crossbeam, Reveal, etc. — the data-sharing infrastructure that enables overlapping-account matching without raw-data exchange.
- **PRM vs ELG platform** — PRMs (Partner Relationship Management) automate partner-program *administration*; ELG platforms power partner *data sharing and play execution*. Different beasts.
- **Tech / channel / strategic partnerships** — three taxonomies. Tech = integration partner; channel = reseller/distributor; strategic = co-marketing/co-engineering at high commitment.
- **Readiness matrix** — diagnostic to assess whether the org is structurally ready for ELG (data infra, leadership buy-in, partner relationships, GTM motion fit).
- **Lavoie matrix (partner tiers)** — segment partners by potential × engagement; allocate investment by tier.
- **Co-selling tetrahedron** — four-point coordination model for joint sales motions: your AE, your partner manager, their counterpart, the customer.
- **Moneyball-style metrics** — partner-relationship metrics that predict revenue (integration adoption, co-marketing reach, joint pipeline) but aren't on the standard sales dashboard.
- **30% customer-concentration with one integration** — when 30%+ of customers use a particular integration, that partner's behaviour becomes a retention factor.
- **NRR via integration adoption** — net revenue retention correlates strongly with integration adoption depth; integrated customers churn less.

## Heuristics

- **Start every partner action from the matrix.** Before recommending a play, identify which of the nine cells you're targeting (joint open opps, joint customers, expansion, save, etc.). The cell dictates the play.
- **Reach for ELG when outbound and PLG are saturating.** ELG is the lever when CAC is climbing and rep-led / product-led are no longer accelerating. Diagnose saturation before recommending.
- **Treat EQLs as a separate funnel.** Don't dump them into MQL handling — they convert differently (warmer, longer-cycle, higher ACV). Build the routing accordingly.
- **Confirm partner-data sharing is two-way.** One-way data flow is a wishlist, not a partnership. Push back on motions that depend on the partner sharing while you keep your data locked.
- **Tier partners with the Lavoie matrix.** Invest by tier; don't give all partners equal attention. Top tier gets shared headcount; bottom tier gets the marketplace listing.
- **Make integration adoption a CS metric.** If integrations drive retention, the CS team owns adoption. Don't leave it to product or sales.
- **Co-sell with the tetrahedron.** Coordinate explicitly across the four points; the most common failure mode is one point missing context (especially the partner's AE).
- **PRM ≠ ELG.** If a stakeholder says "we have a PRM, we're doing ELG" — challenge it. The PRM tracks partner program ops; ELG requires actual partner-data integration.

## When to apply

- **"Should we invest in partnerships?"** → Run the readiness matrix (data infra, leadership buy-in, GTM fit). If readiness is low, fix that before building partner program. If high, scope by the three taxonomies (tech / channel / strategic).
- **"What's an EQL?"** → Partner-validated lead; explain the funnel difference and propose how to route them.
- **"How do we account-map with [partner X]?"** → Use an ELG platform (Crossbeam) for the data exchange. Then walk the nine-cell matrix to identify the priority plays (typically: joint open opps first, then joint customers for expansion).
- **"Co-sell motion — how do we set it up?"** → Co-selling tetrahedron: define each role, agree on the joint-pipeline definition, set a cadence between the partner managers, exit-criterion for stalled deals.
- **"Cold outbound isn't working anymore — what now?"** → Three forces analysis: is it really saturation? If yes, ELG. Start with tech-partner mapping (lowest-friction entry).
- **"How do partnerships drive NRR?"** → Integration adoption. Identify the 5–10 integrations that correlate with retention; instrument adoption; assign CS ownership.
- **"Partner tiers / who to invest in?"** → Lavoie matrix: potential × engagement. Top tier (high both) gets a dedicated partner manager. Don't let the matrix be theoretical — tie investment to it.
- **"Marketplace strategy?"** → Marketplaces are a discovery + transactional channel. Listing is table stakes; the real play is marketplace-driven co-sell with the hyperscaler's reps. Sequence: list → optimize → co-sell.

## Out of scope

- **Pure PLG growth tactics** — Moore's frame is *ecosystem*-led; for product-led onboarding/freemium-conversion tactics, use a PLG-specific resource.
- **Traditional channel-program-only questions** — ELG subsumes channel but isn't reducible to it; for partner-program admin, use a PRM-focused resource.
- **CRM / RevOps infrastructure** — Moore references Salesforce / tooling but doesn't develop them.
- **AtScale-specific customer questions** — for AtScale customer-health data pulls, use `hubspot-customer-health-pull`.

## Source

*Ecosystem-Led Growth: A Blueprint for Sales and Marketing Success Using the Power of Partnerships*, Bob Moore, 2024 (Wiley). Author co-founded Crossbeam.
