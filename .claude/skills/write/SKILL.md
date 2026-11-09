---
name: write
description: >
  The writing skill — invoke for any prose a human will read: emails, documents, PRDs, Confluence
  pages, Jira tickets, PR descriptions, Slack messages, LinkedIn posts, release notes, memos, essays,
  and rewrites ("tighten this", "say this better", "reword"). Grounded in a small canon of writing
  foundations (Strunk, The Elements of Style; Zinsser, On Writing Well) that every draft is edited against.
  Skip for raw code and non-prose output.
model: fable
effort: high
last_updated: 2026-08-31
---

# write

Write plainly, concretely, and briefly, in the manner of the foundations below. Draft first, then edit against the canon — the foundations are editing standards, not templates.

## Foundations (read before composing)

1. **Strunk, *The Elements of Style*** — `references/strunk-distilled.md` (full 1920 text alongside it; 4th-edition numbering, White's reminders on style, and the newer misused-words entries are folded in at the end). The core is Rules 10–13 (14–17 in the 4th edition): active voice, positive form, definite/specific/concrete language, omit needless words.
2. **Zinsser, *On Writing Well*** — `references/zinsser-distilled.md` (principles only; the book is in copyright). The core: strip every sentence to its cleanest components; sound like yourself; unity of point, person, and tense; the first sentence earns the second; the essence of writing is rewriting.
3. **Johnstone's status lens** (persuasion surfaces only: customer emails, exec comms, negotiations, review comments) — `~/.claude/skills/improv/references/johnstone-distilled.md`, Status section. Read the draft as a status transaction: what status does it play, what does it do to the reader's, where does the see-saw tip? A reply that plays high to someone who just lowered themselves reads badly no matter how clean the prose; fix the status before polishing the words.
4. **King, *On Writing*** — `references/king-distilled.md` (principles only; the book is in copyright). The core: first word, active voice, no adverbs, "said"; write with the door shut, rewrite with the door open; 2nd draft = 1st draft − 10%; kill your darlings; one Ideal Reader settles every cut. (Its generation half — situation over plot, stories as fossils — is cross-filed for /improv.)
5. **Williams, *Style: Toward Clarity and Grace*** — `references/williams-distilled.md` (principles only; the book is in copyright). The core, and the canon's only between-sentences coverage: characters as subjects, actions as verbs; old information opens the sentence, news lands in the stress position at its end; read the topic string when a paragraph feels wrong. Where another foundation's rule conflicts with information flow, flow wins.

**Voice** — `voice.md` is the calibration file: Joe's confirmed rules and corrections log. Read it with the foundations; it outranks them where they disagree. It grows only from his actual corrections — the second recurrence of a correction becomes a check script (see Gates).

More foundations will be added; each gets a distilled reference in `references/` and a line here.

## Method

1. **Scope** — surface, audience, intent, length. If genuinely ambiguous and it changes the output, ask one tight question; otherwise proceed. When a surface has a dedicated format guide, honor it for structure and apply this skill's craft on top: LinkedIn → `linkedin-posting`; Jira → `jira-writing-guide`; PRDs → `prd-writer` (personal) / `atscale-prd-writer` (enterprise); Confluence/long-form docs → `technical-writing-for-pms`. If the material doesn't exist yet, start with /improv.
2. **Draft** — get the whole piece down. Lead with the point. Ground every claim in real material (the actual diff, ticket, numbers, thread) — never write past the facts.
3. **Edit against the foundations** — run the draft through the canon, hardest rules first: active voice, positive form, concrete language, needless words out (Strunk 10–13); Zinsser's bracket test (cut every element doing no work — qualifiers, duplicate adverbs, idle adjectives, concept nouns); then paragraph unit and topic sentences (Strunk 8–9), emphasis at sentence end (18), parallel form (15), related words together (16). Check the joints: the lead earns the second sentence, each paragraph's last line springs to the next, and the ending stops instead of summarizing. Every word must tell; rewriting is the essence — one pass is a draft, not an edit.
4. **Deliver** — outward-facing pieces (customer, market, board) are drafts for the user's review, never sent autonomously. Run the Gates first.

## Modes

- **Edit** (default): the method above — draft or rework, then deliver the improved piece.
- **Critique-only**: when asked to review without rewriting ("what's wrong with this", sentence-by-sentence PRD review), report findings against the foundations — quote the sentence, name the rule, propose the fix — and change nothing. The user applies or rejects each finding.

## Gates (mechanical checks — run before publishing and after every edit to a polished document)

- `python3 ~/.claude/skills/write/check-opening-block.py <file>` — opening summary budget: ≤4 sentences, ≤70 words, no em-dash asides. For any document with a TL;DR/summary/abstract (PRDs, Confluence pages).
- `python3 ~/.claude/skills/write/check-provenance-stamps.py <file>` — no backward attribution or edit-history stamps in prose.
- FAIL means rewrite the flagged part from scratch and re-run until PASS. When a voice correction recurs, add a new gate script here rather than another `voice.md` note — written rules are recall-dependent; executable checks are not.

## Standing constraints

- Know the rule before breaking it; break it only when the gain in force is worth it (Strunk's own license).
- One paragraph per topic; the reader learns the topic in the first sentence.
- The emphatic position is the end — of the sentence, the paragraph, and the piece.
