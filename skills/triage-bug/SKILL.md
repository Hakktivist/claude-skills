---
name: triage-bug
description: Manual-invoke only — do NOT auto-trigger. Takes a bug report (pasted ticket, Slack thread, or description), reproduces it locally, root-causes it, applies and re-verifies a fix, then reports back — asking the human only when blocked on something only they can do. Use ONLY when the user explicitly runs /triage-bug or names the skill.
---

# Triage Bug

## Overview

Run a bug report to ground: reproduce it, root-cause it, fix it, prove the fix, report back. Minimal human-in-the-loop — the user handed this off precisely so they could stay heads-down.

**Triage does not end at diagnosis.** It ends with an applied, re-verified, uncommitted fix — or an explicit "blocked, need X from you." Never a bare recommendation. "You asked for triage, so I'm leaving the change to you" is the failure mode this skill exists to prevent.

## Workflow

### 1. Ingest the report

Work from what the user pasted — same posture as [[scoping-linear-tickets]]: don't re-fetch a pasted ticket; only touch Linear/`gh` for a bare ID/URL. Extract expected vs actual, repro steps, and the exact records/values named (reproduce with *those*, not lookalikes). Treat the ticket's claims as unverified.

### 2. Reproduce before touching code

Confirm the bug exists first — the ticket may be stale, wrong, or already fixed. Work down the **repro ladder**, taking the highest rung available:

1. **Live** — dev server, real endpoint/route/command, ticket's data. (`npm start` + curl beats reading code.)
2. **Shrunk** — a harness or one-off test importing the *real* suspect module with synthetic data.
3. **Static** — the traced code path, cited `file:line`, mechanism explained.

Step down a rung only when the one above is blocked; your report must name the rung you verified on. Don't start at rung 2 because it's easier — if the server boots, use it.

### 3. Blocked? Step down or ask — never fabricate

- **Step down** when a lower rung still gives confident verification. That's what minimal HITL means — don't interrupt for a nice-to-have.
- **Stop and ask** only when nothing short of the human unblocks confident verification: a secret or env value, a service login (suggest `! <command>` so it runs in-session), prod data access. Ask **once, batched**, with the exact action per item — then continue.
- **Never fabricate.** No invented env values, no deleting boot checks, no stubbing the suspect module itself and calling it a repro. A "repro" against code you modified to boot proves nothing.
- **Timebox environment fights** to ~10 minutes. A clean rung-2 verification beats an hour of yak-shaving toward rung 1.

### 4. Root-cause and fix

State one hypothesis: "X because Y." If the cause isn't near-obvious, follow [[systematic-debugging]]. Fix at the root, not the symptom — if the bad logic lives in a shared helper, fix the helper and check its other callers, don't patch one route. If the fix contradicts possibly-intentional behavior, note the product question in the report; the ticket's stated expectation wins in the meantime.

### 5. Prove the fix

Re-run the **same repro from step 2** and show before/after. A fix without a re-run is still a hypothesis ([[verification-before-completion]]). Then sweep blast radius: other endpoints/callers of what you changed, and mirrored logic you can't reach from here (client copies, other repos) — flag those, don't chase them.

### 6. Report

Leave the fix **uncommitted** for review. Report exactly:

- **Status** — one line: `reproduced → fixed → verified (rung N)`, or `blocked — need X from you`.
- **Root cause** — `file:line` and why, in plain terms.
- **Fix** — what changed, files touched.
- **Evidence** — before/after output from the same repro.
- **Blast radius / follow-ups** — other affected surfaces, mirrored logic, missing test coverage.
- **Needs from you** — empty, or the batched asks (including optional "for live confirmation, do X" when you verified on a lower rung).

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Stopping at diagnosis ("you asked for triage") | Apply the fix and re-verify; that IS triage here |
| Editing code before reproducing | Confirm the bug exists first — tickets lie |
| Starting at a unit harness when the server boots | Highest rung first; step down only when blocked |
| Inventing env values / removing boot checks to "repro" | Fabrication. Step down a rung or ask |
| Interrupting the user when a lower rung verifies fine | Ask only when the human is the sole unblock; batch it |
| Symptom patch in one route | Fix the shared root; check every caller |
| Claiming fixed without re-running the repro | Same repro, before/after evidence |
| Committing the fix | Leave uncommitted; the user reviews |
| Fighting the environment indefinitely | ~10 min timebox, then step down |
| Drive-by refactors while in there | Fix the bug; log everything else as follow-ups |
