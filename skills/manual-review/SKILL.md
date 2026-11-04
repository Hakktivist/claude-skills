---
name: manual-review
description: Use when the user asks to prepare their changes for manual review, wants the modified files listed with a one-line description each, or runs /manual-review.
---

# Manual Review

## Overview

Produces a scan list of the files you changed, grouped by how much attention each one needs, so the reviewer spends their time on the files that take judgment and skims the rest. One line per file: what changed, or what it's for if new. Not a narrative summary.

`/manual-review by-layer` gives a single list in stack order instead (see **By layer**).

## Scope

Default to the current diff: `git status --porcelain` (uncommitted) plus, if the branch has commits ahead of the base branch, `git diff --name-only $(git merge-base <base> HEAD)...HEAD`. Use a different range or file set only if the user specifies one.

## Groups

Read each file's diff before placing it — `git diff -- <path>` for uncommitted, `git diff <base>...HEAD -- <path>` for committed. Never place a file by its name alone. Then put it in the **first** group that matches, checking top to bottom. Every file lands in exactly one group.

| Check | Group | Goes here |
| --- | --- | --- |
| 1 | Codegen | Written by a tool, not a person: tRPC `*.outputs.ts` sister files, ORM clients, lockfiles, snapshots, anything with a generated header or produced by a codemod or CLI |
| 2 | Tests | Test files, plus fakes, fixtures and helpers that only tests use |
| 3 | Needs human review | Any hunk that takes judgment: logic, conditions, queries, data writes, auth or permission checks, API or contract shapes, migrations, behaviour-changing config or docs, new tuning values such as a cache time or batch size. Frontend files count too when the change adds this kind of logic: a new query or mutation, loading or error handling, derived state, gating who sees what |
| 4 | Frontend only | UI changes a reviewer can check by eye in the browser: markup, styling, layout, copy, focus and keyboard behaviour, props passed through to rendering |
| 5 | Mechanical | No decisions: renames, moved imports, lint or formatting fixes, a value threaded through unchanged, a type or constant edit that only follows another file |

**Judge what the hunks do, not where the file lives.** A component that adds a query with its own loading and error handling is Needs human review. One whose query call was only renamed to follow a router change is Mechanical. A frontend file is not Frontend only just because it is a frontend file.

One judgment-bearing hunk puts a file in **Needs human review**, however mechanical the rest. Unsure between Needs human review and a group below it? Choose Needs human review: a wasted look costs less than a missed bug.

## Order

Print the groups in this order, omitting empty ones and numbering straight through:

1. **Needs human review**, in bottom-up stack order so the reviewer builds context before the surface: schema and migrations, data and auth layer, business logic, API and interface, frontend, everything else.
2. **Mechanical**
3. **Codegen**
4. **Tests**, in the order of the files they cover
5. **Frontend only**

Within the other groups, put a file before the files that consume it, or fall back to alphabetical. Bucket by what each file obviously is; don't re-derive order from the import graph.

## Writing the one-liner

State the specific change and why it matters to a reviewer ("adds X check", "new method Y", "wires Z into the state machine"), not "updated file". For a new file (`??` in git status, or no `-` lines in the diff), describe its purpose.

- **Mechanical:** name the kind of change so the skim can be trusted ("rename only", "threads `isParked` through, no new logic"). If you can't name it that plainly, the file isn't mechanical.
- **Codegen:** say what it was regenerated for. If it picked up unrelated drift, say so instead of listing it as reviewed content.
- **Tests:** say what behaviour they pin down, not how many cases there are.

## Output format

```
## Needs human review
1. `prisma/schema.prisma` — adds `churn_escalation_count` to `role_churn_risk_state`
2. `lib/repositories/role_churn_risk_state.repository.ts` — new `enterParkedMonitoring()`, idempotent against overlapping cron runs
3. `lib/services/churn_risk/churn_risk.service.ts` — routes capped re-entries into parking instead of Needs Action

## Mechanical
4. `server/api/routers/churn-risk.ts` — threads `isParked` from the service to the output, no new logic

## Codegen
5. `server/api/routers/churn-risk.outputs.ts` — regenerated for `isParked`, no unrelated drift

## Tests
6. `lib/services/churn_risk/churn_risk.service.test.ts` — capped re-entry parks the role; uncapped still goes to Needs Action

## Frontend only
7. `components_new/paratools/pararoles/RolesKanbanCard.tsx` — "Parked" pill on capped roles
```

No commentary beyond the one-liners.

## By layer

When the user passes `by-layer`, skip the groups and print one list with a header per stack layer, in this order: schema and migrations, data and auth layer, business logic, API and interface, frontend, tests (or grouped with the layer they cover, if that reads better), everything else. Same scope, numbering and one-liner rules.
