---
name: improv
description: >
  The generation skill — invoke when the task is coming up with material rather than polishing it:
  brainstorming, ideation, naming, story and narrative construction, product visions and /dream-style
  seeding, "give me ideas/angles/options", writing fiction or talks, breaking creative blocks, or any
  session where the user and Claude are riffing together. Grounded in Keith Johnstone's Impro:
  accept the first idea, be obvious, accept every offer (yes-and), interrupt routines, reincorporate.
  Companion to /write, which owns editing and polish; /improv owns getting material to exist.
model: fable
effort: high
last_updated: 2026-08-31
---

# improv

Generate first, judge later. The primary reference is `references/johnstone-distilled.md` — read it before a generative session. Also in `references/`: `young-distilled.md` (the five-step idea cycle — gather, digest, drop it, arrival, shape; governs the campaign the way Johnstone governs the session). Secondary: the "Where material comes from" section of `~/.claude/skills/write/references/king-distilled.md` (situation over plot, stories as fossils, the door-shut draft — King saying what Johnstone says, in a novelist's vocabulary). The failure mode this skill exists to prevent: auditioning candidate ideas for originality and shipping the safe, generic survivor.

## Operating rules

1. **Search rigorously; commit once.** Never ship a model's first idea — it is the mode of the training distribution, everyone's obvious — and never fake the search with "internal sketching" (one rollout where sketch 2 is the formulaic inversion of sketch 1). The procedure:
   a. **Gather ground truth first** (rule 7a): scouts, /summa, web — the brief, the incumbents, the constraints. Ungrounded search regurgitates the prior.
   b. **Map the space**: name the axes of variation explicitly before generating anything.
   c. **Generate for coverage**: candidates written out (scratchpad, not head), spanning the axes — check the set actually spans rather than clusters near the mode.
   d. **Evaluate against criteria fixed before generation** — criteria chosen after always drift to fit the favorite.
   e. **Commit the winner and develop it fully; shelve the runners-up** — they become reincorporation material (rule 4).
   The deliverable still commits (rule 6): rigorous search, one developed answer, runners-up shelved not menued. k>1 independent parallel contexts remain an explicit-ask escalation. (Origin: this inverts Johnstone's "take the first idea," 2026-09-12 — his rule assumes a diverse unconscious behind a censor and still applies to the *human* in the room: when the user offers their first idea, take it seriously; their obvious is original.)
2. **Yes-and, never block.** Treat everything the user says as an offer: accept the premise and develop it. Refining, escalating, or even opposing inside the premise is accepting; wiping out the premise ("that won't work, instead...") is blocking. If an idea must die, kill it by offering a better development, not a veto.
3. **Interrupt routines to make stories.** When narrative is wanted, don't hunt for interesting content — name the routine and break it. Each break establishes a new routine; break that too.
4. **Reincorporate.** When stuck, look backwards, never forwards: what got shelved earlier in the conversation, the doc, the project? Bring it back and connect it. Endings are reincorporations, not new inventions.
5. **Don't cancel.** Never introduce a problem and then neutralize it back to zero; develop consequences instead. Keep the action in the material at hand — not in referenced events elsewhere.
6. **Commit and develop — no menus.** (First test-drive failure, 2026-08-31: a numbered list of ten labeled premises "wasn't landing.") A catalog of angles is auditioning with the audition published; the labels ("the status lens", "routines to interrupt") are technique vocabulary leaking into the output. Take the obvious idea and *play the scene*: produce actual material — real sentences in the piece's voice, developed far enough to feel — then offer to go again from a different premise if it misses. One committed riff beats ten described ones. Quantity still matters across rounds, not within one answer. **Carve-out:** when the deliverable *is* a list — names, options, candidates — the list is the committed material, and quantity within the answer is the point; the ban is on menus that defer the work (labeled premises for one piece, each item an IOU), not on lists where every item arrives complete.
7. **Remove responsibility to unfreeze.** When the user is stuck, don't demand ideas — play a game that displaces authorship: ask rapid category-shifting questions, offer a premise for them to yes-and, start the sentence and let them finish it. The facilitator takes the blame for failures.
7a. **Gather before you riff; stop when the well is dry.** On a real problem, read the raw material first (the brief, the notes, the incumbents) — a riff on an empty stomach produces only general-knowledge combinations. Deep gathering delegates: /summa for outside sources worth keeping, scout agents for the codebase and filesystem, web search for the outside world — then riff on what came back. And when rounds stop yielding fresh material, ending the session is a move, not a failure: park the jumble, set a return time, let the idea arrive off-duty (Young's steps 1–3).
8. **Status is a lens, not a garnish.** When designing dialogue, characters, personas, or persuasion, read the status transactions: who's playing high, who low, where the see-saw tips. A scene or pitch that ignores status reads false.

## Session shape

1. **Establish the target** — what kind of material, roughly how much, and who judges (usually: later, separately).
2. **Generate** — rules 1–5 above, keeping pace fast enough to outrun the censor.
3. **Reincorporate and close** — link back to shelved material; a set of ideas or a story ends when earlier threads connect, not when steam runs out.
4. **Hand off** — anything that ships as prose goes through /write for the edit pass.
