---
name: build-and-codex-review
description: Manual-invoke only — do NOT auto-trigger. Use when a scoping brief is green-lit and the user is ready to implement and then run the automated codex review loop. Builds the change, writes a handoff, derives concern lenses, and runs a Workflow that loops codex adversarial reviews into code-reading fixers until reviews come back clean. Use ONLY when the user runs /build-and-codex-review or names it.
---

# Build and Codex Review

## Overview

The post-green-light pipeline: **build → handoff → codex-review-loop**. You (main thread) stay the *lean orchestrator* — you build, write a handoff, derive ≤3 concern lenses, then hand the deterministic review loop to a Workflow. Confident findings get auto-fixed; everything uncertain comes back to the user.

**Precondition:** the user has already run `/scoping-linear-tickets` and green-lit the brief. If they haven't, send them there first — don't scope here.

**Setup precondition (check once):** the codex plugin must be installed. If `find "$HOME/.claude/plugins" -name codex-companion.mjs` is empty, tell the user to run `/plugin install codex@openai-codex` then `/codex:setup`, and stop.

## Workflow

### 1. Build
Implement the green-lit brief. For multi-task plans, use [[subagent-driven-development]]; otherwise build directly with [[test-driven-development]]. Do **not** commit — the loop reviews the working tree.

### 2. Write the handoff
Copy `handoff-template.md` (in this skill's directory) and fill it in for what you just built. The concern map (section 3) is the important part — it's where review lenses come from. The template's first line tells every downstream agent: **this is context, not ground truth — verify against the code.** Keep it honest about soft spots; that's where review pays off. Save it (e.g. `HANDOFF.md` at repo root, or a temp path).

### 3. Derive concern lenses
From the handoff's concern map, write **≤3 distinct lenses** — one focused review angle each (e.g. `"the auth-token refresh path and its race conditions"`, `"the data migration's backfill correctness"`). More passes ≠ better; 3 is the max for a reason. One concern → one lens.

### 4. Run the loop (Workflow)
Invoke the **Workflow** tool with `scriptPath` set to this skill's `codex-review-loop.workflow.js`, passing `args`:
```
{ lenses: [...],            // step 3
  handoff: "<full handoff text>",
  scope: "working-tree",    // staged + unstaged + untracked
  base: undefined,          // or a ref for branch review
  maxRounds: 3,
  arcSkillPath: "/Users/alannguyen/.claude/skills/address-review-comments/SKILL.md" }
```
The Workflow runs each lens as a codex adversarial-review, dedups findings, dispatches one code-reading fixer per file (applying [[address-review-comments]]'s two-dimensional matrix), and loops until codex stops raising fresh findings or only HITL items remain. This is an explicit, skill-directed Workflow invocation — that's the opt-in; just call it.

### 5. Present results
When the Workflow returns, relay its `note`, then:
- **Blocked** (`blocked[]`) — surface FIRST and loudly. These are review-runner failures (codex errored or an agent crashed), so the review did **not** actually run that round — the result is NOT a clean bill of health. Tell the user what failed and that coverage is incomplete; do not present the run as passing.
- **Auto-fixed** (`fixed[]`) — one line each: `file — what changed`. Tell the user to review the diff.
- **Needs your decision** (`hitl[]`) — surface each per [[address-review-comments]]'s output format: needs-pick (options + your rec), intent-check (codex is right but maybe intentional — confirm/override), or unclear (what couldn't be verified). Do **not** auto-fix these.

Then stop. Do not commit or push unless the user says so.

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Scoping the ticket here | Precondition — the user runs `/scoping-linear-tickets` first |
| Committing before review | Loop reviews the working tree; leave it uncommitted |
| Writing >3 lenses to "be thorough" | 3 max; more passes just add noise. One concern → one lens |
| Handoff written as ground truth | It's the builder's belief; the template says verify against code, and fixers do |
| Letting the orchestrator (you) review code | You stay lean — codex reviews, fixers read code. You derive lenses and aggregate |
| Auto-fixing HITL items | needs-pick / intent-check / unclear go to the user, never silent fixes |
| Re-running a clean loop "to be sure" | If it returned clean + a verdict, trust it; re-run only after the user resolves HITL |
