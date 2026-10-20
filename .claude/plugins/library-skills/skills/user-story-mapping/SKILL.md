---
name: user-story-mapping
description: >
  Apply Jeff Patton's *User Story Mapping* practice to product-team questions about stories, backlogs, releases, MVPs, discovery, and outcomes. Centers on shared understanding as the real deliverable, the story map's backbone-and-slices structure (activities across the top, prioritized details below), user stories as conversation tokens (Three Cs — Card, Conversation, Confirmation), Patton's outcome-first definition of MVP, dual-track discovery/delivery, the walking skeleton, and the output → outcome → impact chain. Use when user is writing/critiquing a user story, planning a release, scoping an MVP, organizing a backlog, running a story workshop, sequencing discovery vs. delivery, slicing a feature for launch, or pushing back on feature-list planning. Trigger on requests like "how should I write this user story", "what's our MVP", "how do I slice this release", "story map for X", "discovery vs delivery", "we need a walking skeleton", "is this Connextra format good", "we're shipping features but not moving the metric", "how do we plan a release", "build to learn vs build to ship". Skip questions about engineering implementation details (this is product framing, not technical design), pure agile-ceremony logistics (sprint mechanics), and project portfolio management — Patton's frame is product team practice, not project management.
version: 2.0.0
last_updated: 2026-05-18
---

# User Story Mapping — Jeff Patton

## Core frame

**The deliverable that matters is shared understanding inside the team, not the artifacts (documents, backlogs, maps) the team produces.** Maps, workshops, reviews, and backlogs are devices for producing or preserving that understanding. The signature practice is a **story map**: a two-dimensional arrangement with a *backbone* of user activities/tasks across the top and prioritized *details* sliced below, letting the team see the whole product and slice horizontally for releases. User stories are *tokens for conversations*, not requirements. Patton's MVP is the smallest *release* that achieves the desired *outcome* — not the smallest feature set. The release chain is **output → outcome → impact**; teams that confuse them ship features that don't move metrics.

## Key concepts

- **Shared understanding** — what the team holds in common about what they're building and why. The real product of the work; documents are stand-ins.
- **Story map** — backbone (activities/tasks across the top, time-ordered) + slices (prioritized details below). Lets the team see the whole and decide what to cut for a release.
- **Backbone** — the user's journey at the activity level. Captures *what they do*, time-ordered, before any feature thinking.
- **Slice** — a horizontal cut across the backbone that produces a usable product release. Slices represent releases; cards in a slice represent stories.
- **Walking skeleton** — the thinnest end-to-end slice that proves the whole journey works. Then thicken it (opening → midgame → endgame).
- **Three Cs of user stories** — Card (the title), Conversation (the discussion the card prompts), Confirmation (acceptance criteria). The card alone isn't the story; the conversation is.
- **Story as a token** — the story is a placeholder for a conversation, not a written requirement. A team that skips the conversation reduces stories to mini-specs.
- **Connextra format** — "As a [user], I want [goal], so that [reason]." Useful but limited; not the whole story (see Three Cs).
- **Patton's MVP** — smallest *product release* that successfully achieves its desired outcome. Distinct from Eric Ries's MVP (a learning experiment) — call out the conflation.
- **Output / outcome / impact** — the value chain. Output = what shipped. Outcome = behaviour change in users/customers. Impact = business effect. Stop celebrating output.
- **Opportunity backlog vs release backlog** — the opportunity backlog is the list of things worth discovering; the release backlog is the list of things the team has committed to build. Don't conflate them.
- **Dual-track (discovery / delivery)** — discovery validates that an opportunity is worth committing engineering capacity to; delivery builds the validated thing. Run both in parallel.
- **Rock breaker** — the person/role that takes huge stories ("rocks") and decomposes them into deliverable size. Rocks → stories → tasks.
- **Story workshop** — the meeting where a card becomes a deliverable story via the Three Cs. The "last best conversation" before build.

## Heuristics

- **Reach for the outcome question first.** Before "should we build X?" ask "what behaviour change are we trying to cause, and for whom?" Output-as-goal is the failure mode.
- **Defend the conversation.** When asked to write a story, produce card + conversation prompts + acceptance examples, not just a Connextra sentence.
- **Slice horizontally, not by feature.** When asked to plan a release, prefer a walking-skeleton + opening/midgame/endgame structure over a feature-by-feature plan. Releases ship slices, not feature columns.
- **Build the walking skeleton first.** Before optimizing any one part, prove the end-to-end journey works at minimum thickness. Then thicken where it pays.
- **Distinguish MVP definitions.** When a stakeholder says "MVP," ask: do you mean a learning experiment (Ries) or a minimum releasable solution that hits an outcome (Patton)? They're different products.
- **Run discovery and delivery in parallel.** Don't gate delivery on completed discovery; both tracks run continuously, with discovery feeding the next slice.
- **The map is the conversation memory.** Maintain the story map as an artifact precisely because it captures *what the team agreed* — when memory diverges, the map adjudicates.
- **Don't sweat the small stuff.** Bundle tiny stories; cap mapping detail at the level where it stops adding clarity. Over-mapping is a tell.

## When to apply

- **"How do I write this user story?"** → Three Cs: produce card + conversation prompts + acceptance criteria. Don't ship just the Connextra sentence.
- **"What's our MVP?"** → Outcome first: what behaviour change are we trying to cause? Then the MVP is the smallest *release* that causes it. Disambiguate from Ries-MVP if needed.
- **"How do I slice this release?"** → Build a story map (backbone of user activities, slices for releases). Plan the walking skeleton as release 1; thicken in subsequent slices.
- **"We're shipping features but the metric isn't moving."** → Output ≠ outcome. Diagnose: what behaviour change did each shipped feature *cause*? If you can't answer, you're optimizing the wrong thing.
- **"How should we organize the backlog?"** → Two backlogs: opportunity (discovery candidates) + release (committed builds). Don't mix them.
- **"How do we run a story workshop?"** → Bring the card. Walk through the Three Cs. Get to acceptance examples before estimating. Capture the conversation in the map.
- **"Discovery vs delivery — how do we sequence?"** → Run them in parallel. Discovery validates *should we build this?*; delivery builds the validated thing. Gate delivery on validation, not on completion-of-discovery.
- **"Is this story too big?"** → If it doesn't fit in one slice, it's a rock. Break it. If breaking it loses the user-value coherence, the story map's wrong level — re-map.

## Out of scope

- **Engineering implementation details** — Patton's frame is product framing and team conversation; architecture / data-model / API specifics don't live here.
- **Pure agile-ceremony mechanics** — sprint length, standup format, retro variations are adjacent but not what this book is about.
- **Project portfolio management** — the book is team-and-product scoped, not portfolio-of-projects scoped.
- **Company-level OKR setting** — Patton's outcome chain operates at the product-team scope. For higher levels, use high-output-management or good-strategy-bad-strategy.

## Source

*User Story Mapping: Discover the Whole Story, Build the Right Product*, Jeff Patton with Peter Economy, 2014 (O'Reilly).
