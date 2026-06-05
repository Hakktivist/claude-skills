---
name: address-review-comments
description: Manual-invoke only — do NOT auto-trigger. Investigates PR review comments (pasted or pulled via gh), assigns a confidence score per comment, then either fixes (high-confidence + one path), surfaces options with a recommendation (high-confidence + multiple paths), or reports uncertainty (low-confidence). Use ONLY when the user explicitly runs /address-review-comments or names the skill.
---

# Address Review Comments

## Overview

Take PR review comments, investigate each one against the actual code, and decide per comment whether to fix, ask, or push back. Confidence is the gate — never act on a guess.

**Pair this with [[receiving-code-review]].** That skill sets the posture (verify, don't perform; no "you're absolutely right!"; push back when wrong). This skill is the operational loop on top.

## Workflow

### 1. Get the comments

- **Pasted** — use what the user pasted as-is. Don't re-fetch from `gh` to "double-check."
- **Asked to pull** — `gh pr view <PR> --json reviews,comments` for top-level review bodies, and `gh api repos/{owner}/{repo}/pulls/{pr}/comments` for inline thread comments. Use the current branch's PR if no number is given.
- **Codex findings** — a codex review (via the codex plugin / [[build-and-codex-review]]) yields structured findings: `{severity, title, body, file, line_start, recommendation, confidence}`. Treat each finding exactly like an inline review comment — the `title`/`body`/`recommendation` is the reviewer's claim, `file:line_start` is its anchor. Codex's own `confidence` (0–1) is **input, not output**: it informs but never replaces your claim-accuracy score, and it says nothing about intent-match. A high codex confidence on intentional behavior is still an intent-check, not a fix.
- If both top-level and inline exist, treat them as one list. Number them so the user can reference by index.

### 2. Investigate each comment

For each comment, before deciding anything:

- Read the file(s) the comment points to. Read enough surrounding context to understand the call sites and invariants — not just the highlighted lines.
- Trace: who calls this, what does it return, what does the reviewer assume vs. what the code actually does.
- Check the reviewer's claim against codebase reality. They may be working from a stale assumption, may have missed a guard, or may be exactly right.
- For style/convention claims, grep for existing usage — does the codebase already do it the reviewer's way, or the current way?

**Parallelize when ≥3 comments touch different files.** Dispatch one `Explore` subagent per comment (in a single message, multiple Agent calls) to do the code-investigation leg — read the file, check the claim, report back what the code actually does. Brief each subagent with: the reviewer's quote, the `file:line`, and "report under 200 words: is the claim factually accurate, and what does the surrounding code actually do." Do **not** delegate scoring or fix decisions — subagents lack the user's intent context for this PR. Main thread synthesizes.

Skip subagents for 1–2 comments or when all comments cluster in the same file (you'll read it anyway).

### 3. Score per comment — two dimensions

Old single-confidence number conflated two different things. Score both:

- **Claim accuracy** (0–100%): Is the reviewer's *technical observation* correct? "This function returns null in case X" — does it actually? This is verifiable from the code alone.
- **Intent match** (0–100%): Does what the reviewer *wants* match what the user was trying to build? A reviewer can be 100% right about what the code does and still be flagging intentional behavior as a bug. Use the user's stated PR scope, recent commits, and prior conversation to judge. **If you don't know the user's intent, intent-match is unknown — don't guess high.**

Don't inflate either. "Probably right, sounds reasonable" is not >90% — that's the trap.

### 4. Act on the two scores

```
FOR each comment:
  IF claim-accuracy > 90% AND intent-match > 90%:
    IF one clear fix:
      → fix it
    ELSE (multiple reasonable fixes):
      → surface options with a recommendation; wait for the user to pick
  ELIF claim-accuracy > 90% AND intent-match < 90%:
    → likely "reviewer is right about the code, but the code is on purpose"
    → DO NOT fix. Surface as: "reviewer's observation is accurate, but I think this
       was intentional because <reason>. Confirm or override?"
  ELIF claim-accuracy < 90%:
    → reviewer may be wrong on the facts
    → report what you couldn't verify + what they got right (if anything)
    → do NOT fix
```

Batch the report at the end — one pass through all comments first, then act. Don't fix #1, then investigate #2; the user loses the thread.

## Output format

Lead with a one-line tally: `5 comments: 3 fixed, 1 intent-check, 1 needs your pick`. Then per comment:

**Comment N — <one-line summary>** (`file:line` if inline)
> short quote of the reviewer's point

- **Claim accuracy:** XX% — one sentence why (note "verified via subagent" if delegated).
- **Intent match:** XX% — one sentence on whether this matches what you were building (or "unknown — no PR-intent context" if you can't judge).
- **Action:** one of:
  - **Fixed** — what you changed, `path:line`.
  - **Needs your pick** — 2–3 options, each with a one-line tradeoff. Mark your rec.
  - **Intent check** — reviewer's observation is accurate, but I read this as intentional because <reason>. Confirm or override?
  - **Unclear** — what you couldn't verify, what the reviewer got right (if anything), what you'd need to decide.

Keep it scannable. No essays.

## After fixing

- Run `pnpm exec eslint --fix` + `pnpm exec prettier --write` on edited files, then `pnpm run typecheck:affected`. Fix errors before reporting done.
- Do **not** auto-reply on GitHub or push. The user reviews the diff first. If they tell you to reply, use the inline thread reply (`gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies`), not a top-level PR comment.
- Do **not** commit unless explicitly told to.

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Re-fetching pasted comments | Use what the user pasted; only `gh` when asked or given a bare PR # |
| Inflating either score to avoid bothering the user | <90% is fine — surfacing uncertainty is the point |
| Fixing a comment because claim-accuracy is high, ignoring intent | High claim accuracy ≠ should-fix. If the flagged behavior was intentional, it's an "intent check," not a fix |
| Guessing intent-match high when you don't know the user's intent | Mark intent-match as "unknown" and route to intent-check, not a silent fix |
| Delegating the score itself to a subagent | Subagents lack PR-intent context. They gather evidence; main thread scores |
| Dispatching subagents for 1–2 comments | Overhead > savings. Only parallelize at ≥3 comments across different files |
| Fixing #1 before investigating the rest | Investigate all first, then act in a batch |
| Acting on the multi-option case | Surface options + rec, then wait |
| Skipping the "what the reviewer got right" on unclear ones | Even when pushing back, name the valid part |
| Performative agreement in the fix summary | Just state the change. No "great catch." (See [[receiving-code-review]].) |
| Auto-replying on GitHub | the user reviews the diff first; only reply when told |
| Committing without being told | Stop at the diff |
