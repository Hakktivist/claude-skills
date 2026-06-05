---
name: scoping-linear-tickets
description: Manual-invoke only — do NOT auto-trigger. Scopes a pasted Linear ticket into a structured brief (what it achieves, how it fits the epic, localhost before/after, grill questions or files-to-touch). Use ONLY when Alan explicitly runs /scoping-linear-tickets or names the skill.
---

# Scoping Linear Tickets

## Overview

Turn a pasted Linear ticket into a tight scoping brief. The brief answers: what is this trying to achieve, how does it fit the bigger picture, where do I look on localhost for before/after, and — depending on how clear the ticket is — either grilling questions OR a concise files-to-touch plan.

**This skill ends at a plan. Never write code or make edits while scoping.**

## Workflow

### 1. Work from what Alan pasted

- Alan usually pastes the ticket content directly — that **is** the source. Use it. Do **not** re-fetch it from the Linear MCP; he pastes it precisely to save tokens.
- **Only** touch the Linear MCP when: he pasted a bare ID/URL with no content, or he explicitly asks you to pull something.
- Need parent/epic context for section 2 and it wasn't pasted? Then you can auto-fetch.

### 2. Explore the codebase

- Find the surfaces and files the ticket touches.
- **Verify the ticket's claims.** Tables, services, routes, and "foundation from the blocking ticket" it references may not exist yet, or may be named differently. Check, don't trust.

### 3. Decide: clear or unclear?

- **Unclear** — ambiguous scope, undecided design choices, conflicting ticket text, or a dependency that hasn't landed → **Grill mode** (4a).
- **Clear** — you could hand this to someone and they'd build the right thing → **Files-to-touch mode** (4b).

## Output format

Always produce sections 1–3, then either 4a or 4b — not both. Keep it scannable, not an essay.

**1. What this ticket achieves** — 2–4 plain sentences.

**2. How it fits the bigger picture** — If it's a sub-ticket, name the parent/epic and where this slice sits in the sequence (e.g. "2b of 6: foundation → **writes** → bell UI"). If standalone, say so in one line.

**3. Where to look on localhost** — Concrete route(s) like `localhost:3000/client/...`, the file that renders them, and the exact before/after to look for. Backend-only ticket with no UI → say so, and give the DB row / log / endpoint to check instead.

**4a. Grill mode (if unclear)** — STOP. Ask questions **one at a time**, each with your recommended answer. If a question can be answered by reading the codebase, read it instead of asking. Do not produce a files-to-touch list until the ambiguity is resolved. (The `grill-me` skill is the same posture if you want to go deeper.)

**4b. Files to touch (if clear)** — Bullet list, `path` — one-line why. Keep the why tight. Call out blockers and unlanded dependencies explicitly.

## Common mistakes

| Mistake                                  | Fix                                                                                      |
| ---------------------------------------- | ---------------------------------------------------------------------------------------- |
| Re-fetching a ticket Alan already pasted | Use the pasted content; only fetch a bare ID/URL or on explicit request                  |
| Skipping the epic for a sub-ticket       | Section 2 still needs it — if the parent wasn't pasted, say so rather than auto-fetching |
| Trusting the ticket's codebase claims    | Verify tables/services/routes exist before listing them                                  |
| Dumping every question at once           | One at a time, each with a recommendation                                                |
| Grilling _and_ listing files in one shot | Pick one — if unclear, grill first                                                       |
| Verbose files list with paragraphs       | `path` — short why. Scannable.                                                           |
| Drifting into implementation             | Stop at the plan. No code, no edits.                                                     |
