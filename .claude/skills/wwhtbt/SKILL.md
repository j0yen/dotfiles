---
name: wwhtbt
description: >
  What Would Have To Be True (Roger Martin), run forward for a goal, plan, design, strategy or
  future feature before work starts. Invoke on "wwhtbt", "wwit", "what would have to be true",
  or /wwhtbt. Builds the end-state, 3-7 leaves marked known/testable/assumed, the weakest link and
  its cheapest falsifier (step 1 / AC 1), a backward rhyme against past five-whys pages, and files
  the page to ~/Notes/wiki/decisions/. A product feature then goes to /dream with the page as seed.
  Backward sibling for failures: /5whysandrhyme.
model: fable
effort: high
fable-spawn: true
last_updated: 2026-10-24
---

# wwhtbt

Joe 2026-09-27: "just as important as the 5 whys is the wwit? analysis." Joe 2026-10-24: "what
about the WWIT analysis for future features?" Five whys explains a failure backward; WWHTBT runs
the end-state forward and catches the assumption that will fail before the work is spent on it.
Invoking this skill is Joe's explicit request to file the answer to the vault.

From a non-Fable session, run it as a separate Fable process on jyen.pm, never a native Agent (A1169, Joe 11-07):
`~/.local/bin/fable-launch.sh --model claude-fable-5-1 --effort high -p "Invoke the <skill> skill (Skill tool) ... <context>"` via Bash
(⚙ fable-native-agent-guard.sh denies native model=fable Agents on josephsyen and any non-Fable native Agent under a jyen.pm Fable parent;
non-Fable helpers of a Fable parent run as `fable-launch.sh --helper --model <sonnet|haiku> -p ...`). The caller's prompt cache stays warm. Helpers this skill spawns
(haiku runners, one sonnet verifier, a justified Fable review if any) never spawn further agents.

Effort default is high (Joe approved the fable-quota routing addendum 2026-11-08, A1300): Fable high for strategy / cross-system plans; Sonnet medium for a straightforward reversible plan. Synthesis is the one Fable launch; retrieval and timelines stay Haiku/code; factual verification stays Sonnet medium. xhigh or max is a reasoned exception only: a named unresolved reasoning gap or an explicit Joe request, with the evidence and the reason recorded in the ledger BEFORE launch (managed route: `--route-request` escalation{reason,evidence}; plain launch: `FABLE_LAUNCH_EFFORT_REASON="ledger:<id> <reason>"`). No retry count or worker cap is implied; this is model selection only.

## Steps

1. **End-state.** Joe's words verbatim with a 12-hour local time from `date`. One sentence: what
   is true in the world when this is done, observable by whom.

2. **Leaves (3-7).** Each = a condition that must hold for the end-state. Label each:
   - `known` — cite the read that proves it (host truth via haiku runners; never a local clone as current)
   - `testable` — name the exact test, its cost in minutes, and what result kills the plan
   - `assumed` — say why it cannot be tested yet
   No leaf restates the end-state. Split any leaf that holds two conditions.

3. **Weakest link.** The leaf most likely to be false times the cost of finding out late. Check:
   "if only this leaf fails, does the end-state still fail?" If no, pick again. Its cheapest test
   becomes step 1 of the plan, or AC 1 of the first PRD (`Falsifier:`), before any other work.

4. **Backward rhyme.** For each `assumed` and `testable` leaf, grep
   `~/Notes/wiki/answers/*five-whys-rhyme*`, MEMORY.md LIVE TRAPS and the decision ledger for the
   same assumption failing before. One bullet per hit: `<date>: <page> → this leaf failed because …`.
   A leaf with a past failure moves up the weakest-link ranking.

5. **Mechanisms.** What ships in code so each leaf stays true after launch: a check, test,
   status.json field + alarm, or generated contract. Each =
   `<mechanism> — ⚙ <path or PR> — owner <seat> — state <LIVE | SPEC | …>`.

6. **File the page.** `~/Notes/wiki/decisions/<YYYY-MM-DD>-<slug>-wwhtbt.md`, frontmatter
   `title`, `date`, `asked_by`, `answered_by`, `status: draft for Fable regrade`. Sections in order:
   `# End-state`, `# Leaves`, `# Weakest link`, `# Backward rhyme`, `# Mechanisms`.
   Run `~/.claude/skills/wwhtbt/scripts/lint-page.sh <page>`; it must exit 0.

7. **Review only when justified (default: no second Fable launch).** The synthesis is the one Fable launch.
   A second Fable review turn runs only for a recorded reason: `prod_money_real_user_data`,
   `unresolved_assumption` / `contradiction` / `low_confidence_weakest_link`,
   `independent_verifier_required`, or `explicit_user_request`. Write the reason (and evidence refs)
   into the page (`review_reason:` front-matter line) and the ledger row FIRST; with no recorded
   reason, skip this step and set `status: unreviewed-by-design`. Resolve the route with
   `skill-route-resolve.py` (`review: {reason, evidence}`), then ONE turn via
   `~/.local/bin/fable-launch.sh --route-request <file> -p "<prompt>"` (never a native Agent), tool calls forbidden, page inline:
   "Grade each leaf's label, the weakest link and the falsifier: AGREE / DISAGREE + one line.
   Is a leaf missing? Missing fact → NEEDS-READ <exact read>." Apply each DISAGREE as an
   `## Amendments after Fable regrade` section; set `status: reviewed`.

8. **Hand-off.** A product feature → `/dream` with the page path as the seed; the vision's WWHTBT
   section cites this page instead of re-deriving it. A plan → its step 1 is the falsifier.

## Reply to Joe

Lead with the weakest link and its falsifier (cost in minutes). Then the page path and each leaf
as one line with its label.
