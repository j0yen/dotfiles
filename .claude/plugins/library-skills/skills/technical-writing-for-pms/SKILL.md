---
name: technical-writing-for-pms
description: >
  Apply the AtScale technical-writing-for-PMs playbook to any PM-authored document — PRDs,
  RFCs, design docs, one-pagers, executive briefs, strategy memos, release notes, API specs,
  migration guides, postmortems. Centers on the thesis that writing is the PM's primary tool
  of influence, the reader-contract per document type, audience-first reframing (engineer /
  exec / customer / sales), precision-vs-brevity as context-dependent tradeoff, layered
  disclosure (Title -> TL;DR -> Body -> Appendix), the Minto Pyramid (answer-first, then
  arguments, then evidence), the SCR framework (Situation / Complication / Resolution),
  outcome-not-mechanism requirements, the Compression Test, the "So What" test, the
  By-Whom-By-When test, calibrated confidence language, signpost headers, examples-first
  API docs, progressive disclosure, and the seven anti-patterns (hedge words, passive voice,
  solution-first framing, jargon overload, wall of text, infinite preamble, writing to
  impress). Use when drafting / reviewing / tightening a PM document, picking the right
  artifact for the audience, structuring an executive ask, writing release notes, specifying
  an API contract, or diagnosing why a doc is not landing. Trigger on requests like
  "tighten this doc", "is this BLUF", "review my PRD writing", "structure for a launch
  announcement", "how should I write this for an exec audience", "make this RFC stronger",
  "draft release notes for X", "review my strategy memo", "what's wrong with this exec
  brief", "rewrite this passively-voiced section". Skip pure PRD-mechanics questions (use
  prd-writing-guide if present), marketing copy and ad copy, LinkedIn post craft (use
  linkedin-posting), user-story phrasing (use user-story-mapping), and code-comment / API
  implementation style guides.
version: 1.0.0
last_updated: 2026-05-18
---

# Technical Writing for PMs — write to influence, not to impress

## Core frame
A PM's output is written artifacts. Code ships features; documents ship alignment. Each document type carries a different reader contract — violate it (an exhaustive PRD where a one-pager was expected, an RFC that is really an announcement, release notes written for the team that built the feature) and trust collapses faster than from any typo. Good PM writing is audience-first, answer-first, and ruthlessly compressed: lead with the ask, quantify everything, name the actor, cut anything that would not change a reader's decision.

## Key concepts
- **Reader contract per artifact.** PRD = what + why. RFC = proposal seeking pushback. Design doc = spec written after the decision. One-pager = shortest possible version. Release notes = what / why-it-matters / what-to-do. Strategy memo = why this direction not that. Executive brief = the ask. Postmortem = precise timeline.
- **The Audience Matrix.** Engineers want constraints and interfaces, distrust hand-waving, tolerate length. Executives want the recommendation, distrust long docs, demand brevity. Customers want the action they must take, distrust jargon and marketing fluff. Sales wants the talking point and competitive angle.
- **Minto Pyramid.** Answer at the top, supporting arguments under it, evidence under those. Most writers do the reverse; executives want the reverse-reverse.
- **SCR — Situation / Complication / Resolution.** Situation = uncontroversial stable reality (1–2 sentences). Complication = what changed or is at risk. Resolution = the recommendation and the specific ask.
- **Layered disclosure.** Level 0 = title (a complete sentence). Level 1 = TL;DR (3–5 bullets: ask, why, timeline). Level 2 = body. Level 3 = appendices. Reader stops at the layer they need.
- **Outcome-not-mechanism requirements.** "p95 < 800ms for 10M-row datasets without >15% infra cost increase" beats "use Redis." PM defines problem + constraint, engineer picks mechanism.
- **API-doc progressive disclosure.** Quick Start (working curl in 30s) -> Common Use Cases -> Full Reference -> Advanced. Examples first, parameters second.
- **Signpost headers.** "Query Latency Exceeds SLA for Large Datasets" beats "Performance." Headers tell the reader what the section says, not what it is about.
- **Calibrated confidence.** "I recommend" (high) vs "Based on current data, I lean toward" (medium) vs "My working hypothesis is, I recommend we validate by" (low). Executives respect calibration, not false certainty.
- **Active voice + concrete nouns + specific verbs.** "It was decided" hides the actor. "We need better alignment" specifies nothing. "Look into this" commits to nothing. Fix these three and clarity jumps more than any other intervention.
- **Hedge words.** "Probably / arguably / it might be worth considering / going forward / at the end of the day" — delete or replace with a position.

## Heuristics
- **The Compression Test.** "If I cut this, would the reader make a different decision?" No -> cut. Yes -> keep, but shorter.
- **The "So What" Test.** For every data point: "This matters because we should ___." Cannot finish the sentence -> cut the data.
- **The "By Whom, By When" Test.** For every sentence: does it make clear who does what by when? If no, rewrite.
- **One page maximum for executive briefs.** "If it cannot fit on one page, you have not finished thinking."
- **Exactly two options in an exec brief.** Your recommendation + the credible alternative. More options = no recommendation. Fewer = no choice.
- **Lead with the ask.** The first sentence tells the executive what you need from them.
- **Quantify everything.** "Significant revenue impact" is noise. "$1.2M ARR at risk" is signal.
- **Diagram = picture + paragraph.** A diagram without prose telling the reader what to notice is decoration. Label every arrow; show protocols.
- **No prose block > 5 sentences without a break** (header, bullet, table, diagram). Formatting is structural, not cosmetic.
- **Test the migration guide on a clean environment.** Skip this and you ship broken instructions.
- **Show exact commands, not paraphrases.** "Update your configuration" is not a step. `sed -i 's/v1/v2/g' config.yaml` is.
- **Additive API changes are not breaking; rename / retype / default-change are.** Communicate deprecation with a removal date.

## Anti-patterns (the 7)
1. **Hedge words** — "probably / arguably / might be worth" — pick a position or remove.
2. **Passive voice that hides accountability** — "it was decided" = "someone decided but I will not say who." Corrosive in accountable orgs.
3. **Solution-first framing** — "We should build a Slack integration" before stating the problem. Robs the reader of evaluating whether your solution is the right one.
4. **Jargon overload (wrong jargon for the audience)** — "refactor the monolith into microservices" to an exec means nothing; "ship independently, cut release cycle from 4 weeks to 1 week" means something.
5. **The wall of text** — no headers, no bullets, no tables = will not be read.
6. **The infinite preamble** — two pages of context before the point. State the point first; context for those who need it after.
7. **Writing to impress vs writing to communicate** — "effectuate a paradigmatic shift in our architectural modality" vs "change our architecture."

Plus RFC-specific failures: strawman alternatives, no rollback plan, missing success metrics, RFC-after-the-decision-is-made.

## When to apply
- Reviewing any PM-authored document for tightness, structure, or audience fit.
- Picking the right artifact for the task (RFC vs design doc vs PRD vs one-pager vs strategy memo).
- Drafting an executive ask, a launch announcement, release notes, an API spec, a migration guide, a postmortem.
- Diagnosing why a doc is not landing — usually wrong reader contract, buried ask, vague requirements, or solution-first framing.
- Coaching a PM on writing craft — active voice, signpost headers, calibrated confidence, layered disclosure.
- Critiquing a memo / RFC / brief written by someone else before it ships.

## Format-selection cheat sheet
- Comparison across multiple dimensions -> **table**.
- Sequence of steps -> **numbered list**.
- Relationships between components -> **diagram** (with a paragraph that says what to notice).
- Argument or rationale -> **prose** (tables cannot say "because" or "therefore").
- Reference data / specs / parameters -> **table**.
- Status / progress -> **table or checklist**.
- Decision + rationale -> **prose with a comparison table inside it**.
- Architecture / data flow -> **diagram + prose**.

## Out of scope
- PRD-section mechanics (problem statement, user stories, acceptance criteria) — use a dedicated PRD-writing skill if present.
- Marketing / advertising copy, brand voice, taglines.
- LinkedIn / social posts — use `linkedin-posting`.
- User-story phrasing and backlog mechanics — use `user-story-mapping`.
- Code comments, docstrings, engineering style guides.
- Analyst-briefing message-house design — use `analyst-relations-framework`.

## Further reading (when the user needs depth)
- Barbara Minto, *The Pyramid Principle* (foundational for the Pyramid + SCR).
- Google "Technical Writing Courses" (free, developers.google.com/tech-writing).
- Stripe API docs — the gold standard for examples-first progressive disclosure.
- Amazon "Working Backwards" 6-pager / PR-FAQ — answer-first as discipline.
- Paul Graham, "Write Like You Talk" (2015) — close the gap between thought and prose.

## Source
Technical Writing for Product Managers, AtScale Reference, 2026.
