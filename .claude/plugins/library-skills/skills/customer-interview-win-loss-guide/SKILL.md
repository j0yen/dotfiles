---
name: customer-interview-win-loss-guide
description: >
  Apply the AtScale customer-interview and win/loss playbook to enterprise B2B
  data-platform product-management questions — discovery / usability / churn /
  prospect / power-user / executive interviews, win/loss program design, churn
  analysis, NPS/CSAT, CABs, and turning interview signal into roadmap action.
  Centers on The Mom Test (talk about their life, not your idea; past specifics,
  not future hypotheticals; commitments not compliments), TEDW question stems,
  SVIPT note-taking, the six primary win/loss reason codes (PROD / PRICE / REL /
  TIME / COMP / INERT), the six recurring middleware loss patterns (inertia,
  platform-native consolidation, champion departure, budget cut, POC failure,
  internal build), and the insight-quality test before any pattern becomes
  roadmap.
  Use when user is preparing for or synthesizing a customer interview, designing
  a win/loss or churn program, coding loss reasons, building a churn-risk score,
  running NPS follow-up, scoping a CAB, or pushing back on a feature request
  driven by a single loud customer or one lost deal.
  Trigger on requests like "how do I run a win/loss interview", "what should I
  ask a churned customer", "structure for a discovery interview", "how do I code
  this loss", "we lost to Snowflake-native — what now", "our biggest customer
  wants feature X", "draft a quarterly win/loss report", "churn risk score",
  "how should I run our CAB", "is this insight actionable".
  Skip pure sales-tactics / closing-techniques (this is research, not selling),
  individual career coaching for PMs, generic UX research outside enterprise B2B
  data, and quantitative product analytics methodology (use a telemetry resource).
version: 1.0.0
last_updated: 2026-05-18
---

# Customer Interview / Win-Loss Guide — listen first, code ruthlessly, act on patterns not anecdotes

## Core frame
Every customer conversation is research, not selling. The PM is a journalist, not a salesperson — talk less than 30% of the time, anchor every question to past specifics rather than future hypotheticals, and treat compliments as noise and commitments (time / introductions / resources) as signal. Discovery surfaces problems; win/loss surfaces deal truths; churn surfaces what broke; CAB surfaces strategic shifts; telemetry corroborates everything. A single interview is an observation — an insight requires multiple independent accounts, telemetry corroboration, evidence of customer effort (workarounds), strategic alignment, and segment-level value. For enterprise middleware specifically (semantic layers, catalogs, governance), the biggest threats are inertia ("do nothing") and platform-native consolidation, not point competitors.

## Key concepts
- **The Mom Test** — Rob Fitzpatrick's foundational rules: talk about their life not your idea; ask past specifics not future generics; talk less / listen more; compliments are noise, commitments are signal; people predict their own behavior badly.
- **TEDW stems** — Tell me about / Explain how you / Describe the last time / Walk me through. Carries 80% of any discovery interview.
- **Six interview types** — Discovery (journalist mode, 12–20 to saturation), Usability (shut up and watch, think-aloud), Churned (post-mortem not rescue, ≤30 min, ≤4 weeks post-churn), Prospect (separate from sales cycle), Power User (peer not subject, "teach me"), Executive Sponsor (business outcomes / TCO language, 30 min crisp).
- **Commitment Test** — A real signal demands a commitment of time (4-week beta), reputation (introduce 2 teammates), or resources (engineering integration time). "Sounds great" without any of these = politeness.
- **SVIPT note-taking** — Story, Verbatim quote, Insight (flagged as YOUR interpretation), Pain, Task/workflow. Tags during interview: [!] surprising, [*] important, [?] unclear, [C] competitive, [Q] quotable.
- **Active-listening toolkit** — Mirroring (last 2–3 words back), Labeling ("it sounds like that was frustrating"), Calibrated silence (5–7s after their answer), Summarizing, "Tell me more", Anchoring to specifics.
- **Insight Quality Test (5 gates)** — (1) Multiple independent accounts? (2) Corroborated by telemetry / tickets? (3) Customer-built workaround? (4) Aligned with strategy? (5) Generalizable beyond one account? <3 yeses = observation, not insight.
- **Six win/loss reason codes** — PROD (feature/perf/UX/integration/scale/arch), PRICE (absolute/relative/model/ROI), REL (sales/trust/support/exec), TIME (budget/reorg/priority/maturity), COMP (platform-native/incumbent/brand/ecosystem), INERT (good-enough/risk/effort/no-champion). Primary = the thing that, if different, would have changed the outcome.
- **Sales reason vs. customer reason** — They disagree ~60% of the time. Customer's version is closer to truth. Track both as separate data points.
- **Six middleware loss patterns** — Inertia / "good enough"; Platform-native consolidation play; Champion departure; Budget cut / macro headwinds; POC failure modes (scope creep / data quality exposure / performance mismatch / integration complexity / wrong evaluator); Internal build.
- **Churn taxonomy** — Voluntary (Product / Business / Competitive / Relationship) vs Involuntary vs Downgrade. Code every churn to type + sub-type per Section 14 of source.
- **Churn risk score (composite)** — Usage trend 35%, Relationship health 25%, Account context 20%, Market exposure 20%. Bands: 80+ healthy, 60–79 watch, 40–59 at risk, <40 critical.
- **NPS follow-up bands** — 9–10 ask for reference + "what makes it a 10?"; 7–8 schedule 15-min "what moves you to a 9?" call (most actionable); 0–6 escalate to CSM in 48h, treat as churn risk.
- **CAB rules** — 8–12 members, no competitors in the room, Chatham House Rule, no selling, equal airtime, follow through on every commitment.

## Heuristics
- **Bad anti-pattern questions:** leading ("don't you think a semantic layer would help?"), binary ("do you like the performance?"), future hypothetical ("would you use X?"), stacked, jargon-laden, opinion-fishing. Rewrite into TEDW + past-specific form.
- **Talk-time discipline:** if you're talking more than 30% of the time, you're pitching. Calibrated silence (5–7s) is the single most underused tool.
- **Workarounds are gold:** "what have you built or hacked together to deal with this?" The amount of duct-tape effort = the true intensity of the pain.
- **Prep before every interview:** account ARR + renewal + health score, usage telemetry, sales notes, LinkedIn, conference talks, recent company news, technical stack, 3 specific topics surfaced from research. Showing up cold is disrespectful and produces shallow data.
- **Two-people max in the room.** One asks, one notes. Never outnumber the customer.
- **Churned-customer tone:** no defensiveness, no save attempts, no "would you come back if we built X?" (that's negotiation, not research). Send interview request from a neutral party — not the AE / CSM who owned the relationship.
- **Win/loss timing:** won deals 2–4 weeks post-signature; lost-to-competitor 1–2 weeks; lost-to-no-decision 4–6 weeks; lost-to-platform-native 2–3 weeks (existential intel for middleware).
- **POC discipline:** designed to succeed in 2 weeks with success criteria agreed upfront; if ambiguous or longer, the POC is already failing.
- **Feature-request prioritization weights:** customer frequency 30%, revenue impact 20%, strategic fit 25%, effort 15%, competitive urgency 10%. Weight by distinct-customer frequency, not by ARR of the loudest account.
- **Quarterly win/loss review rule:** no defending past decisions. The moment people get defensive, data quality collapses.
- **Insight-to-action pipeline:** Interview → Coded Data → Pattern → Insight → testable Hypothesis (metric + timeframe + success criteria) → Product Action (PRD / roadmap / positioning). If the gap is perception not capability, the action is marketing, not engineering.

## When to apply
- **"How do I run a [discovery / win-loss / churn] interview?"** → pick the right type from the six (each has different prep, tone, duration); use the corresponding template (Sections 20–23 of source); pre-research checklist; TEDW + past-specific framing.
- **"What should I ask a churned customer?"** → 30-min cap; sequence: decision → experience → what's next → what could have been different. NEVER "would you come back if". Send from neutral party.
- **"We lost the deal — how do I code it?"** → Six categories (PROD / PRICE / REL / TIME / COMP / INERT) + sub-code + up to 2 contributing. Code on customer's words, not your inference. Track BOTH sales-stated and customer-stated.
- **"Our biggest customer wants feature X"** → loudest-voice trap. Weight by distinct-customer frequency, not by ARR. Validate against win/loss data + telemetry. Apply Insight Quality Test (5 gates).
- **"We're losing to Snowflake/Databricks-native"** → Platform-native consolidation play (Section 11.2). Be multi-engine + consumption-tool-agnostic. Quantify TCO gap. Threshold: native-loss >30% of total losses = strategy-level conversation.
- **"Account looks shaky — is it churning?"** → Compute churn risk score; check telemetry signals (login decline, model staleness, error spike, seat-utilization <40%), relationship signals (NPS drop, QBR declined, support spike), market signals (warehouse-vendor competing feature, customer M&A, new CDO). Below-40 score = escalate.
- **"Draft a quarterly win/loss report"** → Section 25 template: exec summary + one-sentence narrative, win-rate dashboard (overall / by competitor / by segment / by champion persona), top 3 loss themes with quotes, top win themes, competitive landscape shifts, recommended actions.
- **"Set up our CAB"** → 8–12 members, ICP-fit + candor + diversity + non-competitive. 2x/year full-day + quarterly virtual. Chatham House + no selling + equal airtime + follow-through.
- **"Is this insight real?"** → run the 5-gate Insight Quality Test. <3 yes = observation only.
- **"Sales says we'll lose the deal without feature X"** → sales says this about everything. Validate with the customer directly, check win/loss data for corroboration, compare sales-stated to customer-stated reason (they disagree 60% of the time).

## Out of scope
- **Closing tactics / sales negotiation** — this is research methodology. PMs interview to learn, not to convert. If a sales call is needed, route to the AE.
- **Individual UX research outside enterprise B2B data** — the persona banks, telemetry signals, and platform-native logic are calibrated to data platforms / semantic layers. Consumer UX questions need a different lens.
- **Quantitative product analytics methodology** — telemetry is referenced as corroboration, but instrumentation, A/B test design, and analytics infrastructure are out of frame.
- **Sales win-rate forecasting / pipeline modeling** — win/loss here is qualitative-pattern research, not deal-stage probability math.
- **PM career coaching** — this is operational research practice, not personal development.

## Source
Customer Interviews & Win/Loss Analysis — The Definitive Guide for Enterprise B2B Data Platform PMs, AtScale Reference, 2026.
