---
name: review-buddy
description: Manual-invoke only — do NOT auto-trigger. Interactive pair-reviewer that gathers the diff (uncommitted files, open PR) plus the ticket, then walks the changed files one at a time on the user's lead — what each does, whether it matches the ticket's intent, and any gaps. Pairs with /manual-review. Use ONLY when the user explicitly runs /review-buddy or names the skill.
---

# Review Buddy

## Overview

Sit beside the user and review their change file by file. Establish the ticket's intent and what was built once, up front, then walk each changed file on the user's lead — judging it against that intent, not as generic lint. This is a conversation, not a batch report.

**Pairs with [[manual-review]].** That skill produces the ordered file list the user follows along with; review-buddy is the back-and-forth on top of it. It never edits code.

## Setup — gather context once

Before reviewing anything, assemble:

- **The diff.** `git status --porcelain` (uncommitted) plus, if the branch is ahead of base, `git diff --name-only $(git merge-base <base> HEAD)...HEAD`. If there's an open PR, `gh pr view --json title,body` for its description.
- **The ticket / intent.** The user usually pastes it — use that as-is; only touch the Linear MCP for a bare ID/URL or on request (same posture as [[scoping-linear-tickets]]).
- **What was built.** The plan or scope the user worked from — from this conversation, the scoping brief, or the PR body.

If the user is following a [[manual-review]] list, use that ordering and let them hand you files by it.

## Establish shared intent (before file 1)

State in 2–3 lines: what the ticket wants, and what was built to satisfy it. Confirm with the user before diving in. Every per-file judgment hangs off this — get it right first.

## Walk files — one at a time, on the user's lead

The user names a file (or says "next"). **One file per turn. Do not run ahead.** For each, read the actual diff (`git diff -- <path>`) — don't guess from the name — then cover:

- **What it does** — the real change in plain terms.
- **Intent match** — ✅ / ⚠️ / ❌: does this serve the ticket's goal and the design you built?
- **Gaps / concerns** — missing pieces, edge cases, things that don't line up, follow-ups. Or "clean — nothing"; don't manufacture concerns.

Then **stop** and let the user respond. Answer their questions on that file before moving on.

## Track + recap

Keep a running note of every gap you flag. When the user is done (or asks), recap: what looks solid, what to fix, what's still an open question. That list is the handoff — to the user, or to a fix step.

## Posture

- **Judge against intent, not style.** "Does this do what the ticket wanted" first; real bugs second; lint is not the point.
- **Don't rubber-stamp and don't perform.** No "looks great!" If a file misses intent, say so plainly; if it's clean, say clean. (See [[receiving-code-review]].)
- **Review, don't fix.** No edits. Flagged gaps route to a fix step ([[address-review-comments]] or a build skill), not to you editing here.

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Dumping all files at once | One file per turn; wait for the user |
| Reviewing before intent is agreed | Establish + confirm ticket intent first |
| Guessing a file's change from its name | Read the diff |
| Manufacturing concerns to look thorough | "Clean — nothing" is a valid verdict |
| Generic lint review | Judge against ticket intent first |
| Re-fetching a pasted ticket | Use what the user pasted |
| Editing code mid-review | Review only; route fixes elsewhere |
| Rubber-stamping / performative praise | State the verdict plainly |
