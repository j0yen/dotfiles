---
name: ai-product-management-patterns
description: >
  Apply AI Product Management Patterns to building, scoping, evaluating, or governing AI-powered features in enterprise data platforms — especially text-to-SQL, AI agents, and semantic-layer-grounded LLMs. Centers on the deterministic-vs-probabilistic gap (you ship eval criteria and confidence intervals, not specs), the 5-phase AI lifecycle (frame → prototype → evaluate → ship-with-guardrails → monitor), the three-layer eval pipeline (offline golden dataset, online shadow/canary/A-B, periodic human review), the "95% accuracy problem" in enterprise, trust calibration (over-trust is dangerous, under-trust is wasteful), progressive autonomy (copilot → draft → delegate → agent), the autonomy spectrum mapped to action risk, the AI Product Canvas, the Impact × Probability × (1−Reversibility) risk formula, and the central thesis that the semantic layer is the AI grounding layer (constrained output space + governed metric vocabulary kills hallucination). Use when scoping or critiquing an AI feature, designing evals, debugging trust-calibration issues, deciding build/buy/integrate, planning enterprise rollout, justifying ROI, or arguing the semantic-layer-for-AI position. Trigger on requests like "should we add AI to this", "how do I eval a text-to-SQL feature", "what's our golden dataset look like", "how do we handle ambiguous queries", "build vs buy AI", "what's the risk of this AI feature", "how do I roll out AI to the enterprise", "does the semantic layer actually matter for AI", "users don't trust our AI", "the model is 95% accurate, ship it". Skip pure modeling/architecture questions (use designing-ml-systems), agent-framework implementation details, consumer-AI UX, and prompt-engineering tactics — this lens is enterprise-data-platform product management, not ML engineering.
version: 1.0.0
last_updated: 2026-05-18
---

# AI Product Management Patterns — enterprise-data-platform PM lens

## Core frame
AI features are **probabilistic**, not deterministic. PMs ship evaluation criteria and confidence intervals, not complete specs. The product is never "done" — accuracy degrades with data drift, model updates, and user-behavior shifts. Edge cases ARE the product: an LLM handles the happy 80% in weeks; the 5–20% of ambiguous, multi-step, domain-specific queries is what separates demo from product. **Trust is a product metric** — miscalibrated trust (over-trust = uncaught errors; under-trust = abandonment) is failure. For enterprise data, the central strategic claim is that the **semantic layer is the AI grounding layer**: it bounds the LLM's output space to governed metrics/dimensions, killing whole classes of hallucination and making the remaining accuracy *trustworthy* (auditable, secured, explainable).

## Key concepts
- **AI tax** — hidden ongoing costs (eval infra, non-deterministic debugging, trust UX, model-dependency risk, continuous accuracy maintenance). If the tax exceeds the AI's value, use deterministic logic (a good dropdown beats a bad NL bar).
- **Golden dataset** — 200–1000 versioned, ground-truthed examples segmented by difficulty/domain/query-type. The most important artifact, more important than the prototype.
- **Execution accuracy** — gold-standard text-to-SQL metric: does the generated SQL run AND return correct results? Beats exact-match and string similarity.
- **The 95% problem** — 95% on consumer queries = fine; on 10K enterprise queries/day = 500 wrong answers visible in board decks. Benchmark accuracy ≠ enterprise production accuracy.
- **Trust calibration** — goal is matching user trust to actual reliability, not maximizing trust.
- **Progressive autonomy** — Copilot (suggest) → Draft Author (review) → Delegate (approve exceptions) → Agent (monitor aggregates). Progresses per-user, not per-org. P0 errors demote.
- **Autonomy spectrum** — full human control → human approves → AI suggests → AI acts/human monitors → full AI. Map by error consequence × reversibility × expertise.
- **Failure taxonomy** — silent wrong answer (worst), hallucination, partial answer, refusal, latency failure, confidently-wrong (kills calibration).
- **Disambiguation cascade** — semantic-model default → conversation context → ask user → NEVER silently guess.
- **Semantic layer as grounding** — constrained output space (can't invent columns/joins), governed metric vocab (canonical revenue), enforced security context, "show your work" in business terms not SQL.
- **AI Product Canvas** — Problem / AI Solution / Metrics / UVP / Failure Modes / Eval Strategy / Trust Design / Cost / Governance / Rollout / Risk. Fill before PRD.
- **Risk = Impact × Probability × (1 − Reversibility)** — irreversible high-impact = block from AI automation entirely.
- **Build vs Buy vs Integrate** — AtScale's bet is *integrate* (foundation-model APIs + semantic model as the differentiating context). Moat = SML, not the model.

## Heuristics
- **You cannot write complete specs.** Write evaluation criteria: "≥95% accuracy on eval set, <2% catastrophic failures, <3s p95 latency."
- **Build the eval set before the prototype.** 50–200 representative examples with ground truth; grow to 200–1000. Test on real enterprise schemas (`tbl_fin_rev_q3_adj_v2`), not synthetic ones.
- **Three-layer eval, always:** (1) offline golden dataset gating CI/CD, (2) online shadow → canary → A/B → interleaving + implicit accept/modify/reject signals, (3) periodic stratified expert review (50–100/week).
- **Regression gate by severity:** P0 catastrophic = zero tolerance, P1 incorrect <2%, P2 suboptimal <5%, P3 stylistic = no limit. CI blocks deploys that violate.
- **Product metrics beat model metrics.** 80% accuracy saving 2 hrs/day beats 90% accuracy nobody uses. Prioritize: Safety → Accuracy → Usefulness → Adoption → Efficiency.
- **Detect uncertainty, route to humans.** Confidence scoring + low-confidence escalation must be a first-class UX path, not an error state.
- **"Show your understanding" before showing results.** Display the AI's interpretation of the question — users catch interpretation errors before they become result errors.
- **Never silently guess on ambiguity.** Present alternatives: "Revenue (Booked) or Revenue (Recognized)?"
- **Calibrate model confidence empirically.** Raw logprobs are poorly calibrated — LLMs are confident when wrong. "90% confidence" must mean "correct 90% of the time" on YOUR eval set.
- **Every AI workflow needs a non-AI escape hatch.** SQL editor, visual builder, pre-built reports. AI is accelerant, not gate.
- **Tier autonomy by action reversibility.** Read-only query → AI suggests; modify semantic model → admin approves; grant data access → human only, never automate.
- **Ship in stages:** internal dogfood (wk 1–4) → 5–10 champion users w/ white-glove (wk 5–12) → controlled expansion 50–200 users (wk 13–24) → GA (wk 25+). Build initial golden set from dogfooding.
- **Audit-trail every interaction.** Timestamp, user identity, input, AI interpretation, output, model version, data sources accessed, security context, user action, result hash. 7yr retention for financial.
- **Metadata-only context to external LLMs.** Send schema/metric definitions; never raw data values. SQL executes inside the customer boundary. This is the AtScale pattern.
- **Kill switches via feature flags, not deploys.** Governance must disable any AI feature instantly.
- **Decision rule on adding AI:** large variable input space × approximate-is-useful × user-can-verify × failure-is-recoverable → ship with AI. Any "no" → deterministic logic or mandatory HITL.
- **Build / Buy / Integrate:** Build if AI IS the product or you have proprietary data; Buy if table-stakes and speed > differentiation; Integrate if you can differentiate through context (semantic model) rather than the model itself.

## When to apply
- **"Should we add AI to feature X?"** → run the decision tree (input variability → approximate useful? → user verifiable? → reversible?); compute AI tax; compare to deterministic alternative.
- **"How do we evaluate this AI feature?"** → three-layer pipeline; execution accuracy as primary metric; severity-tiered regression gates; expert review weekly.
- **"The model is 95% accurate, can we ship?"** → invoke the 95% problem; check enterprise vs. benchmark schema realism; require zero P0 regressions; check confidence calibration.
- **"Users don't trust our AI" / "Users blindly accept wrong answers."** → trust calibration diagnosis (over- vs under-trust); add transparency patterns (interpretation display, source attribution, confidence, alternatives); scaffolded introduction; earned autonomy.
- **"Should this be autonomous or human-approved?"** → map to autonomy spectrum by error consequence × reversibility × user expertise × regulatory load.
- **"How do we roll this out to enterprise?"** → 4-phase playbook; address the 5 personas (Skeptic, Threatened, Compliance Officer, Executive, Power User) with persona-specific responses.
- **"What's the ROI of this AI feature?"** → annual time savings (N analysts × Q queries × S self-serve% × T mins × 52 / 60) × hourly cost − (license + infra + monitoring).
- **"Build vs buy vs integrate?"** → use the 7-factor matrix; for data platforms, integrate + semantic-layer-as-context is usually right.
- **"What can go wrong?"** → failure taxonomy + Impact × Probability × (1 − Reversibility) score; irreversible high-impact = no automation.
- **"Does the semantic layer actually matter for AI?"** → grounding-problem framing (LLMs invent columns, mis-join, misapply aggregation, ignore business rules); semantic model = constrained output space + governed vocab + security context + meaningful explanations; counter to MotherDuck thesis = enterprise schemas are never clean and SL provides governance value beyond accuracy.
- **"Scoping a new AI feature"** → fill the AI Product Canvas; force the Failure Modes + Trust Design sections; cross-functional review before PRD.

## Out of scope
- **Pure modeling questions** (which architecture, fine-tune vs RAG, embedding choice) — use `designing-ml-systems` instead. This lens is product framing, not ML engineering.
- **Agent framework / orchestration internals** (tool-calling protocols, agent loops, memory architectures) — use Anthropic-style agent skill references.
- **Consumer-AI UX patterns** — this lens assumes regulated enterprise context (SOX/HIPAA/GDPR, executive blast-radius, audit retention).
- **Prompt engineering tactics** (chain-of-thought wording, few-shot example selection, prompt templates) — adjacent craft; this lens is what to measure and ship, not how to write the prompt.
- **General product strategy questions** (positioning, pricing, GTM) not specific to AI features — use `good-strategy-bad-strategy` or `your-next-five-moves`.

## Source
*AI Product Management Patterns*, AtScale Reference Library, 2026. Companion documents: `AtScale-Technical-Reference.md` (Section 7: AI/Agentic Integrations), `AI Writes SQL at 95% Accuracy - Do You Need a Semantic Layer.md` (counter-thesis), `knowledge-graphs-llms-in-action.md` (Named Entity Disambiguation as semantic-grounding analog), `Anthropic - Don't Build Agents Build Skills Instead.md` (skills as domain-expertise analog).
