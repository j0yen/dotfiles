---
name: 5whysandrhyme
description: >
  Five whys + WWHTBT + rhyme post-mortem for a failure, stall, freeze, red run, outage or bad
  decision. Invoke on "5 whys and rhyme", "five whys", "why did X happen / why didn't the seats
  fix it", "rhyme check", or /5whysandrhyme. Builds a host-truth timeline, five evidenced whys,
  the weakest link, the prior incidents this rhymes with (root vs branch), and code mechanisms
  with owners; files the page to ~/Notes/wiki/answers/. No second Fable launch by default; a review runs only when justified and the reason is recorded first.
model: fable
effort: xhigh
fable-spawn: true
last_updated: 2026-10-24
---

# 5whysandrhyme

Joe's standing failure method (CLAUDE.md § FAILURES: five whys + WWHTBT, verify before
concluding). Invoking this skill is Joe's explicit request to file the answer to the vault.

ALWAYS THIS SKILL (Joe 10-24 4:2x PM "make sure the new skill /5whysandrhyme is always used for
analysis. never try to analyze it without the skill."): no five whys, rhyme or root cause is
written by hand (⚙ analysis-page-gate.sh refuses a new page without this skill's marker).
Forward analysis of a plan or feature is the sibling skill /wwhtbt.

MITIGATE FIRST, ANALYZE AFTER: the skill never gates the same-sweep mitigation (PROACTIVE).

Pins: `model: fable` + `effort: xhigh` (Joe 10-24 3:5x PM "use fable xHigh or Max for this skill").
From a non-Fable session, run it as a separate Fable process on jyen.pm, never a native Agent (A1169, Joe 11-07):
`~/.local/bin/fable-launch.sh --model claude-fable-5-1 --effort xhigh -p "Invoke the <skill> skill (Skill tool) ... <context>"` via Bash
(⚙ fable-native-agent-guard.sh denies native model=fable Agents on josephsyen and any non-Fable native Agent under a jyen.pm Fable parent;
non-Fable helpers of a Fable parent run as `fable-launch.sh --helper --model <sonnet|haiku> -p ...`). The caller's prompt cache stays warm. Helpers this skill spawns
(haiku runners, one sonnet verifier, a justified Fable review if any) never spawn further agents.

Joe approved xhigh as the default on 2026-11-06 to conserve Fable quota. This applies to synthesis and the independent Fable review. Retrieval stays Haiku; factual verification stays Sonnet. Use max only for a specific unresolved reasoning gap, with that reason recorded in the ledger. This supersedes the earlier max default, not the no-worker-caps rule.

## Steps

1. **Question.** Quote Joe's words verbatim with a 12-hour local time from `date`. Name the
   incident window in local time.

2. **Timeline from host truth.** Fable plans the reads; haiku runner/triage agents perform them
   (state.db, journals, dmesg, circuits, seat tick files, `~/.cache/fleet-dash/status.json`,
   CI logs as ZIPs). Every spawn passes `model:`. Rules:
   - Never quote a local clone as current: fetch, read `behind N`, name the tree.
   - Never run raw `wm-build status`/`runs` on a build host (12 G journal read); use status.json or r7-ro.sh.
   - Tool output > 2 KB goes to a file; read the tail.
   - One bullet per event: `H:MM <host> <run/unit> <what> (<source>)`. End with the result line
     (shipped / lost / idle-hours).

3. **Five whys.** Five numbered answers, each one level deeper than the last, each citing the
   read that proves it. Why 5 names a missing mechanism (a governor, alarm, contract, test), never a
   person or "carelessness". A claim backed by a single haiku read is labelled `provisional`, and a
   sonnet verifier confirms the claim that carries the whys before the page is final.

4. **WWHTBT (weakest link).** One paragraph: what would have to be true for this not to recur,
   with leaves marked known / testable / assumed. Name the ONE weakest link. Test it: "if only this
   were fixed, does the incident still happen later?" If yes, it is not the weakest link.

5. **Rhyme.** Search for earlier incidents with the same shape before writing any of them:
   - `ls ~/Notes/wiki/answers/ | grep -i rhyme`, then grep those pages for the class terms
   - MEMORY.md LIVE TRAPS + the archives, and `memory/project_sonnet_operator_decision_ledger_20261016.md`
   - `~/Notes/wiki/decisions/`
   One bullet per rhyme: `<date time>: <what> → same root | branch | the last fix is a link in this one`.
   Mark which rhymes share THIS root and which are branches. A rhyme whose earlier fix did not
   prevent this one is the most important row: name why the fix missed.

6. **Mechanisms (build in code, never prose).** Numbered; each =
   `<mechanism> — ⚙ <path or PR> — owner <seat> — state <LIVE | MERGED | SPEC | DISABLED until …>`.
   Kinds: unit/timer, hook, check, test, generated contract, status.json field + alarm.
   An order to a seat is not a mechanism. Per ACT ON EVERY RECOMMENDATION, each one starts at once
   in its owning seat (cross-host by tmux message, controller by SendMessage) and gets a DECISION row;
   anything that spends money or raises a cost/idle limit is asked first.

7. **Fair record.** Short section: what the seats, controller and mechanisms did right, and
   what none of them could do (the lever that did not exist).

8. **File the page.** `~/Notes/wiki/answers/<YYYY-MM-DD>-<slug>-five-whys-rhyme.md`, frontmatter:
   ```yaml
   ---
   title: "<question> (five whys + rhyme)"
   date: <YYYY-MM-DD>
   asked_by: Joe
   answered_by: <seat> (<model>, <host>)
   status: draft for Fable regrade
   ---
   ```
   Sections in order: `# Question`, `# What happened (<sources>)`, `# Five whys`,
   `WWHTBT (the weakest link):`, `# Rhyme`, `# Mechanisms`, `# Fair record`.
   Then run `~/.claude/skills/5whysandrhyme/scripts/lint-page.sh <page>`. It must exit 0 before step 9.

9. **Review only when justified (default: no second Fable launch).** The synthesis is the one Fable launch.
   A second Fable review turn runs only for a recorded reason: `prod_money_real_user_data`,
   `unresolved_assumption` / `contradiction` / `low_confidence_weakest_link`,
   `independent_verifier_required`, or `explicit_user_request`. Write the reason (and evidence refs)
   into the page (`review_reason:` front-matter line) and the ledger row FIRST; with no recorded
   reason, skip this step and set `status: unreviewed-by-design`. Resolve the route with
   `skill-route-resolve.py` (`review: {reason, evidence}`), then run ONE turn via
   `~/.local/bin/fable-launch.sh --route-request <file> -p "<prompt>"` (never a native Agent), tool calls forbidden, with the
   page text inline. Prompt: "Grade each why, the WWHTBT and each rhyme: AGREE / DISAGREE + one line.
   Is why 5 a missing mechanism? Is the weakest link the weakest? Which rhyme is a root and which a
   branch? Missing fact → NEEDS-READ <exact read>." A NEEDS-READ goes to a haiku runner. Apply every
   DISAGREE as a `## Amendments after Fable regrade (<row>), <date time>` section (keep the original
   text so the correction stays visible), then set `status: reviewed`.

10. **Memory.** If the incident is a live trap, add a one-line LIVE TRAPS entry in MEMORY.md
    pointing at the page (MEMORY.md stays < 17 KB). Write rules to CLAUDE.md, never to memory.

## Reply to Joe

Lead with the weakest link and the first mechanism already started. Then the page path,
the five whys as one line each, the top rhyme, and the mechanisms with state. No P(H), no rates per hour.
