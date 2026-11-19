---
name: 5whysandrhyme
description: >
  Five whys + WWHTBT + rhyme post-mortem for a failure, stall, freeze, red run, outage or bad
  decision. Invoke on "5 whys and rhyme", "five whys", "why did X happen / why didn't the seats
  fix it", "rhyme check", or /5whysandrhyme. Builds a host-truth timeline, five evidenced whys,
  the weakest link, the prior incidents this rhymes with (root vs branch), and code mechanisms
  with owners; files the page to ~/Notes/wiki/answers/. No second launch by default; a review runs only when justified and the reason is recorded first.
fable-spawn: true
last_updated: 2026-11-18
---

# 5whysandrhyme

Joe's standing failure method (CLAUDE.md § FAILURES: five whys + WWHTBT, verify before
concluding). Invoking this skill is Joe's explicit request to file the answer to the vault.

ALWAYS THIS SKILL (Joe 10-24 4:2x PM "make sure the new skill /5whysandrhyme is always used for
analysis. never try to analyze it without the skill."): no five whys, rhyme or root cause is
written by hand (⚙ analysis-page-gate.sh refuses a new page without this skill's marker).
Forward analysis of a plan or feature is the sibling skill /wwhtbt.

MITIGATE FIRST, ANALYZE AFTER: the skill never gates the same-sweep mitigation (PROACTIVE).

The routing policy chooses the model and effort: Fable is its default for this skill's consequential classes, and a listed non-Fable alternate runs only when the launch request names it in requested.route with its model and effort.

Run it through the managed launcher, never inline and never as a native Agent (A1169, A1300): write a request file, pre-draw a
session id (`cat /proc/sys/kernel/random/uuid`), then via Bash
`~/.local/bin/fable-launch.sh --route-request <request file> --session-id <pre-drawn id> -p "Invoke the 5whysandrhyme skill (Skill tool, skill: 5whysandrhyme, args: <question>). Context + evidence: <paste>. Return the page path, lint result and verdict lines."`
The launcher resolves the route from `.config/skill-routing/policy.json`, records the launch row the page gate binds the page to, and
takes the account from the selected model. Example request for this skill's consequential class, asking its listed alternate
(`<LEDGER_REF>` is a `ledger:` reference, `<FILE_REF>` a `file:` reference; without `requested` the policy's default route runs):

```json
{"task_id":"<TASK_ID>","skill":"5whysandrhyme","decision_class":"consequential_prevention","evidence_refs":["<LEDGER_REF>","<FILE_REF>"],"requested":{"route":"opus-xhigh","model":"claude-opus-5-5","effort":"xhigh"}}
```

(⚙ fable-skill-spawn-gate.sh denies an inline call outside the managed worker; fable-native-agent-guard.sh keeps native helpers on
their parent's account lane; helpers of a launched parent run as `fable-launch.sh --helper --model <sonnet|haiku> -p ...`.) The caller's
prompt cache stays warm. Helpers this skill spawns (haiku runners, one sonnet verifier, a justified review if any) never spawn further agents.

Effort (Joe approved the quota routing addendum 2026-11-08, A1300): high, the baseline. Synthesis is the one launch; retrieval and timelines stay Haiku/code; factual verification stays Sonnet medium. xhigh comes only from an evidenced class or escalation (`decision_class` with `evidence_refs`, or `escalation{reason,evidence}`, recorded in the ledger BEFORE launch); max is only the policy's recorded exception and is no route of this skill. No retry count or worker cap is implied; this is model selection only.

## Steps

1. **Question.** Quote Joe's words verbatim with a 12-hour local time from `date`. Name the
   incident window in local time.

2. **Timeline from host truth.** The synthesis turn plans the reads; haiku runner/triage agents perform them
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
   status: draft for <model> regrade
   ---
   ```
   (`<model>` = the model this run's launch row records.)
   Sections in order: `# Question`, `# What happened (<sources>)`, `# Five whys`,
   `WWHTBT (the weakest link):`, `# Rhyme`, `# Mechanisms`, `# Fair record`.
   Then run `~/.claude/skills/5whysandrhyme/scripts/lint-page.sh <page>`. It must exit 0 before step 9.

9. **Review only when justified (default: no second launch).** The synthesis is the one launch.
   A second review turn runs only for a recorded reason: `prod_money_real_user_data`,
   `unresolved_assumption` / `contradiction` / `low_confidence_weakest_link`,
   `independent_verifier_required`, or `explicit_user_request`. Write the reason (and evidence refs)
   into the page (`review_reason:` front-matter line) and the ledger row FIRST; with no recorded
   reason, skip this step and set `status: unreviewed-by-design`. Resolve the route with
   `skill-route-resolve.py` (`review: {reason, evidence}`); a run that asked for an alternate asks the same
   `requested` for its review. Then run ONE turn via
   `~/.local/bin/fable-launch.sh --route-request <file> --session-id <pre-drawn id> -p "<prompt>"` (never a native Agent), tool calls forbidden, with the
   page text inline. Prompt: "Grade each why, the WWHTBT and each rhyme: AGREE / DISAGREE + one line.
   Is why 5 a missing mechanism? Is the weakest link the weakest? Which rhyme is a root and which a
   branch? Missing fact → NEEDS-READ <exact read>." A NEEDS-READ goes to a haiku runner. Apply every
   DISAGREE as a `## Amendments after <model> regrade (<row>), <date time>` section (`<model>` = the review
   launch's model; keep the original text so the correction stays visible), then set `status: reviewed`.

10. **Memory.** If the incident is a live trap, add a one-line LIVE TRAPS entry in MEMORY.md
    pointing at the page (MEMORY.md stays < 17 KB). Write rules to CLAUDE.md, never to memory.

## Reply to Joe

Lead with the weakest link and the first mechanism already started. Then the page path,
the five whys as one line each, the top rhyme, and the mechanisms with state. No P(H), no rates per hour.
