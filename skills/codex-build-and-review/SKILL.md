---
name: codex-build-and-review
description: Manual-invoke only — do NOT auto-trigger. Use when a scoping brief is green-lit and you are ready to implement it and then have it adversarially reviewed. You build the change, write a handoff, derive ≤3 concern lenses, then spawn your own reviewer and fixer subagents and loop until the reviews come back clean. Confident fixes apply automatically; everything uncertain stops and goes to the human. Use ONLY when the user runs /codex-build-and-review or names it.
metadata:
  short-description: Build a green-lit brief, then loop your own reviewer and fixer subagents until clean
---

# Codex Build and Review

## Overview

The post-green-light pipeline: **build → handoff → review loop**, all inside one Codex session.
You are the root agent. You build the change, then stop touching it: every review and every fix
after that is done by **subagents you spawn** (`spawn_agent`). You stay the lean orchestrator —
you derive lenses, route findings by path, and aggregate. Confident findings get auto-fixed;
everything uncertain stops and goes to the human.

**You do not review your own work.** That is the entire point. You just built this code and you
believe it is correct — that belief is exactly the blind spot an adversarial review exists to
find. Route it to subagents that start cold.

**Precondition:** the user has already green-lit a scoping brief. If they haven't, scope it first —
don't scope inside this skill.

## Before you start

Check all three. Any one missing means stop and say so, rather than degrade into something weaker.

1. **Subagents.** You need `spawn_agent` and some way to wait on what it spawns — `wait_agent` if
   your session has it, otherwise the mailbox `wait` tool. That is the whole requirement.
   `close_agent` is a bonus: some sessions expose it, many don't, and its absence changes nothing
   except that you skip the close steps. If you cannot spawn at all, stop and tell the user to
   enable the tools:
   `codex features enable multi_agent` (or `features.multi_agent = true` in `~/.codex/config.toml`),
   then restart the session. **Do not fall back to reviewing the change yourself** — a self-review by
   the builder is the one outcome this skill exists to prevent, and it would look like a pass.
2. **Write access.** Fixer subagents edit files. In the TUI that means approvals set to workspace
   write; non-interactive that means `--sandbox workspace-write`. Read-only, and every fix silently
   fails.
3. **A git repo with the change uncommitted.** The working tree — staged, unstaged, and untracked —
   is the review target. Do not commit before or during the loop.

## Workflow

### 1. Build

Implement the green-lit brief. Test-drive it where tests make sense. Leave everything
**uncommitted**: the loop reviews the working tree.

### 2. Mint the run dir and write the handoff

```sh
sh "<this skill dir>/review-loop.sh" init
```

It prints `RUN=`, `HANDOFF=`, `REVIEWER_BRIEF=`, `FIXER_BRIEF=`, `OBSERVER_BRIEF=`. Keep those five
paths for the rest of the run — everything downstream is addressed by path.

`init` puts the run dir in `$TMPDIR`, **outside the repo, on purpose**. The loop reviews untracked
files too, so a `HANDOFF.md` written at the repo root would end up in the very review it feeds — and
dirty the working tree the human is about to read.

`$HANDOFF` starts as the template. Fill it in for what you just built. Section 3, the concern map,
is the important one — the lenses come from it. Be honest in section 5 about where you are unsure;
that is where the review pays off. The template's header tells every subagent that the handoff is
context, not ground truth, and that the code wins when they disagree. Leave section 7 empty.

### 3. Derive the concern lenses

From the concern map, write **≤3 lenses** — one focused review angle each, e.g. `"the auth-token
refresh path and its race conditions"`, `"the migration's backfill correctness"`. One concern → one
lens. Three is the cap, not a target: more passes don't find more, they just cost more and repeat
each other.

### 3.5 Snapshot the run

```sh
sh "<skill dir>/review-loop.sh" snapshot "$RUN"
```

A run is one invocation of this skill or **codex-continue-review-loop**, and it can hold several
rounds. This records the tree the run reviews and prints its number. It hashes the working tree
through a throwaway index, so the real index, HEAD, refs, and stash are untouched. The tree is
uncommitted, so without this nothing records what changed between runs.

### 4. Review round

For each lens, write its focus file (this is also what injects the already-adjudicated list):

```sh
sh "<skill dir>/review-loop.sh" focus "$RUN" <round> <n> "<lens text>"
```

Then spawn all lenses **in one batch** — `spawn_agent` per lens, back to back, before you wait on
any of them. Reviewers are independent; running them one at a time turns three 10-minute reviews
into a 30-minute round.

- `task_name`: `review_lens<n>_r<round>` (lowercase, digits, underscores)
- **no inherited history** — `fork_context: false`, or `fork_turns: "none"` if that is the parameter
  your `spawn_agent` takes. Check the tool's own schema and use whichever it has.
- `reasoning_effort`: `high`
- message:

```
Read <REVIEWER_BRIEF> and follow it exactly.
FOCUS: <the focus path that `focus` printed>
HANDOFF: <HANDOFF>
Repo: <absolute path to the repo root>
Write your findings to the file named in the FOCUS file, then reply with the single line the brief specifies.
```

That message is short by design. The brief, the lens, the adjudicated list, and the handoff all
reach the subagent as files it opens itself — nothing multi-KB is retyped through your context or
theirs.

Then wait on all of them with a generous `timeout_ms` — `wait_agent` on the ids, or the mailbox
`wait`, whichever your session gives you. Reviews routinely run 5–20 minutes. A timed-out wait
returns empty; that means *still working*, not dead. Wait again. Use `list_agents` to confirm one is
alive. Do not go do the review yourself because a wait came back empty.

When all lenses have replied:

```sh
sh "<skill dir>/review-loop.sh" collect "$RUN" <round>
```

It prints `BLOCKED:` lines (a lens that errored), the round's counts, and one `GROUP` line per file
with fresh findings. It has already deduped within the round, dropped anything the human already
owns, and escalated anything re-flagged after an earlier auto-fix. **Read only what it prints** —
you do not open the findings files. Routing is the job; judging them is the fixers'.

If `close_agent` is exposed in your session, close each reviewer once it has replied — a completed
agent holds its concurrency slot until closed. If it isn't exposed, skip it and move on; it is not a
precondition for anything.

### 5. Fix round

One fixer per `GROUP` line — that is, **one fixer per file**, which is what makes them parallel-safe.
Spawn them in batches of ≤4:

- `task_name`: `fix_<slug>_r<round>`
- **no inherited history**, same as the reviewers
- message:

```
Read <FIXER_BRIEF> and follow it exactly.
FILE: <the file from the GROUP line> — the only file you may edit.
FINDINGS: <the group path from the GROUP line>
HANDOFF: <HANDOFF>
OUTPUT: <RUN>/results/r<round>/<same basename as the group file>
Reply with the single line the brief specifies.
```

Wait for them, then:

```sh
sh "<skill dir>/review-loop.sh" absorb "$RUN" <round>
```

It records each result as auto-fixed or human-owned and regenerates the adjudicated list the next
round's reviewers read. Close the fixers too, if you have `close_agent`.

If a spawn is refused for hitting the concurrency cap and you have no `close_agent` to free slots,
finish the batch you have, then tell the user to raise
`multi_agent.max_concurrent_threads_per_session` — don't drop the remaining files silently.

### 6. Loop control

Go back to step 4 with `<round>` + 1. Stop when any of these is true:

- **A round produced no fresh findings** (`FRESH: 0`). That is the clean bill — one confirming round
  is enough.
- **Three rounds are done.** Report what you have; more rounds stop paying.
- **Everything left is human-owned.** If a round's only output is suppressions and escalations,
  nothing will change until the human decides.
- **A lens is `BLOCKED:`.** Finish the round with the healthy lenses — their findings are already
  paid for — then stop and report the incomplete coverage. Do not start another round on a broken
  reviewer.

### 7. Observer

Reviewers start cold and each fixer sees one file, so only something reading every run can notice
that the findings keep being the same bug. Record this run and see whether that is due:

```sh
sh "<skill dir>/review-loop.sh" ledger "$RUN"
sh "<skill dir>/review-loop.sh" observer-due "$RUN"
```

Anything but `yes` means skip to step 8. On `yes`, spawn one subagent, with no inherited history and
`reasoning_effort: high`, using `task_name` `observer_r<k>`, where `<k>` is the run number:

```
Read <OBSERVER_BRIEF> and follow it exactly.
LEDGER: <RUN>/observer/ledger
HANDOFF: <HANDOFF>
DECISIONS: <RUN>/observer/decisions.md
DELTAS: <RUN>/observer/deltas
LANDED: sh "<skill dir>/review-loop.sh" landed "<RUN>"
REPORT: <RUN>/observer/report-run-<k>.md
CLASSES: <RUN>/observer/classes-run-<k>.txt
Repo: <absolute path to the repo root>
Reply with the single line the brief specifies.
```

Wait for it, then:

```sh
sh "<skill dir>/review-loop.sh" classes "$RUN"
```

It prints each class that clears the bar, highest confidence first. **Read only what it prints.** The
script counts confidence from the evidence: a class needs 2+ distinct bugs across 2+ runs to be shown
at all. High also needs 3+ bugs, a sibling confirmed at a `file:line`, a change that eliminates most
members, and 2+ lenses. Expect some false positives. If the observer fails, say so in the report and
carry on: it is advisory and never affects the review result.

### 8. Report

```sh
sh "<skill dir>/review-loop.sh" report "$RUN"
```

**If anything was auto-fixed, typecheck once yourself before relaying.** Fixers are forbidden from
typechecking (see `fixer-brief.md`): they run in parallel on a half-edited tree, and in Paraform
typecheck reinstalls dependencies and regenerates the Prisma client under the running dev app. You
are the only one who runs it — never hand it to a subagent. Report failures alongside the results.

Relay it in this order:

- **Blocked** — first and plainly. A blocked lens means the review **did not run**, so this is not a
  clean bill of health. Say which lens failed and that coverage is incomplete. Never present a run
  with a blocked lens as passing.
- **Possible shared cause** — what `classes` printed, framed as an alert: these N decisions may be
  one problem. The change is **unverified**, so present it that way, and give the report path. Ask
  the user to adopt it, take a smaller fix, or accept the class. Leave the report unread unless they
  ask.
- **Auto-fixed** — one line each, `file — what changed`. Tell the user to read the diff.
- **Needs your decision** — each with its type: **needs-pick** (the options and your recommendation),
  **intent-check** (the reviewer is right about the code, but it looks deliberate — confirm or
  override), **unclear** (what couldn't be verified). List the `#N` items a class names under that
  class, because its decision may settle them. Never fix these yourself; that call is theirs.

Then append the same ledger to section 7 of `$HANDOFF`, and tell the user the handoff path and that
`/codex-continue-review-loop` picks up from it once they've answered.

Stop there. Do not commit or push unless the user asks.

## Why the subagents are shaped this way

- **Never fork your history into a subagent** (`fork_context: false` / `fork_turns: "none"` —
  sessions differ on which one `spawn_agent` takes). Forking hands the reviewer your reasoning, your
  assumptions, and your confidence that the change is right. It would review your intent instead of
  your code, and agree with you. A cold subagent with the diff and a lens is the whole value.
- **Reviewers run at high effort; fixers at the default.** The reviewer subagent *is* the review —
  all the adversarial reasoning happens there. Fixers read code and score two dimensions, which the
  default handles; the brief, not the effort knob, is what keeps them honest.
- **Subagents never spawn subagents.** Both briefs say so. A flat tree stays legible, stays inside
  the depth limit, and keeps the concurrency cap meaningful — which matters most in the sessions that
  expose no `close_agent` and so can never free a slot.
- **Everything travels by path.** Briefs, focus, handoff, findings, results. Text pasted into a spawn
  message gets retyped token by token and bloats both sides for nothing.
- **Reviewers are read-only; fixers own exactly one file.** That is what makes a batch safe to run in
  parallel — no two agents ever write the same file.

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Reviewing or fixing the change yourself | You built it; you are the blind spot. Spawn subagents, route by path, aggregate |
| Falling back to a self-review when `spawn_agent` is missing | Stop and tell the user to enable `multi_agent`. A builder's self-review reads as a pass |
| Letting a reviewer inherit your history | It inherits your confidence and reviews your intent. `fork_context: false` / `fork_turns: "none"` |
| Committing before or during the loop | The loop reviews the working tree; leave it uncommitted |
| Writing the handoff into the repo | It's an untracked file the review would flag. `init` puts it in `$TMPDIR` for that reason |
| Pasting brief or handoff text into the spawn message | Pass the path; the subagent opens it |
| More than 3 lenses | 3 is the cap. Extra passes repeat each other and cost a full round each |
| Spawning lenses one at a time | Spawn the batch, then wait. Serial rounds cost 3× the wall clock |
| Treating an empty `wait_agent` as failure | Empty means timed out, not dead. Wait again; `list_agents` to confirm |
| Refusing to run because `close_agent` isn't exposed | Only `spawn_agent` and `wait_agent` are required; close when you can, skip when you can't |
| Leaving agents open when you *do* have `close_agent` | Completed agents hold concurrency slots — close each one as it replies |
| Opening the findings files yourself | `collect` prints what you need. Reading them pulls you back into judging the code |
| Two fixers on one file | One fixer per file, always — that is what makes the batch parallel-safe |
| Auto-fixing a needs-pick / intent-check / unclear | Those are the human's call. Surface them and stop |
| Calling a round clean when a lens was `BLOCKED:` | That lens never ran. Report incomplete coverage, not a pass |
| Re-running a clean loop "to be sure" | A confirming round already ran. Re-run only after the human resolves the open items |
| Skipping the step 3.5 snapshot | `observer-due` says `no: no snapshot`, and later runs lose this one's findings |
| Building an observer class's change without asking | It is an unverified alert. The user adopts it, takes a smaller fix, or accepts the class |
| Saying "no shared cause" when the observer never ran | Only a run the observer actually read can say that. Report the `observer-due` reason |
