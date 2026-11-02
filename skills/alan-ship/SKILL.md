---
name: alan-ship
description: Manual-invoke only — do NOT auto-trigger. Alan's personal ship flow for a Paraform branch, from the current diff to an open PR and on through CI and review comments, under his own commit, typecheck, PR-format and reply rules. Use ONLY when the user explicitly runs /alan-ship or names the skill. Words after the name are a PR title hint.
---

# Alan Ship

## Overview

Take the current branch from a working diff to a green, review-clean PR.

**Core principle: one go-ahead covers one change.** `/alan-ship` covers committing and pushing the diff that exists right now, and opening the PR. Everything after that waits for Alan's verdict.

This replaces the team `ship` skill, which typechecks locally, commits fixes on its own, wakes itself on a timer and posts top-level replies. Do none of those.

## Hard rules

| Rule | Detail |
| --- | --- |
| No local typecheck | CI typechecks. Run eslint, prettier and `pnpm lint:comments` only. If a change is type-risky, offer a local typecheck in one line and run it only on a yes. Never in a subagent. |
| One go-ahead, one change | After the first push, nothing is edited, committed, pushed, replied to or changed on GitHub until Alan gives a verdict on it. A monitor event is never a go-ahead. The one exception is re-running a cancelled duplicate CI run. |
| No waiting on a timer | One Monitor watches the PR. No `ScheduleWakeup`, no `sleep`, no re-running `gh pr checks` to see how it is going. |
| Replies | Inline threads only, through `reply-thread.sh`: `addressed - <one line>` or `wontfix - <one line>`, then resolved. Never a top-level PR comment. |
| Git | Stage by name. Never `git add -A`, `--no-verify`, `--amend`, plain `--force`, `git stash`, or `gt`. A rebase, merge or force-push needs its own go-ahead. |
| Never merge | Report the result. Merging is Alan's call. |

## 1. Pre-flight

1. **Ticket.** It is needed for the branch, the commit and the title. Take it from the branch name, the commits or the conversation. If there is none, or it is not clear that it belongs to this diff, ask once before going further. Never invent one.
2. **Branch.** `git branch --show-current`. Empty (a detached worktree) or `main`: create the branch first, `alan/<ticket-id-lowercase>-<slug>`, using Linear's branch name when it is known. Choose the final name now: renaming a branch with an open PR closes the PR.
3. **Files.** `git status --short` and `git diff --name-only origin/main...HEAD`. Anything that is not part of this change (scratch files, env files, another ticket's edits) stays out of the commit; name it in the report. If it is unclear whether a file belongs, ask once.
4. **Lint.** `pnpm exec eslint --fix` and `pnpm exec prettier --write` on the changed files each tool handles, then `pnpm lint:comments`.
5. **tRPC.** A router handler's return shape changed: `pnpm codemod:add-trpc-output --router=<name>` and include the `*.outputs.ts` file.
6. **Tests.** Run the tests this branch added or changed (`pnpm exec vitest run <files>`; `pnpm test:integration <file>` for `*.integration.test.ts`). A failure stops the ship: report it, commit nothing.

## 2. Commit and push

- One commit, in the style of Alan's commits: `feat|fix|refactor|chore|test|docs(<scope>): <summary> (ENG-1234)`, with an optional short body on why. Pick the type and scope yourself. No trailers at all: no `Co-Authored-By`, no `Claude-Session`, no session link.
- A commit hook fails: fix the cause and make a new commit.
- `git push -u origin HEAD`. If the push is rejected, stop and report with a recommendation.

## 3. Open the PR

Skip this when `gh pr view --json number,url,state` already shows an open PR for the branch.

- **Base.** `main`, unless the branch was cut from another unmerged feature branch; then that branch is the base (a plain GitHub stack). `git log --format='%h %D' origin/main..HEAD` shows a parent branch as a remote ref on an earlier commit. State the base you chose; do not ask.
- **Title.** `Feature|Bug|Improvement (Alan): ENG-1234 <concise name>`. Pick the category yourself and say which. The title hint supplies the name.
- **Body.** Exactly these headings, kept short. Write it to a scratchpad file and pass `--body-file`. Open the PR ready for review, not as a draft.

```markdown
## Description

[ENG-1234](https://linear.app/paraform/issue/ENG-1234). <The problem in one or two sentences.>

- <What changed. A short table beats prose when behaviour differs per case.>

## Screenshots

<Only when screenshots exist: an HTML table, Before | After, caption row underneath. Otherwise drop the heading.>

## Risks

- <One line each: trade-offs, accepted losses, anything not yet tested.>
```

No test-plan section, no "Generated with" footer, no session link. Print the PR URL.

## 4. Arm the watch

```
Monitor({
  command: 'bash ~/.claude/skills/alan-ship/watch-pr.sh <pr> --state-dir "<scratchpad>/alan-ship-<pr>"',
  description: 'PR #<pr>: CI results and review comments',
  timeout_ms: 1800000,
})
```

The script looks at GitHub every 45 seconds in the background and prints a line only when something changes. Between events there is nothing to do: end the turn. Lines that arrive together are one round.

| Event | Meaning | Do |
| --- | --- | --- |
| `watching:` | First arm; where the PR stands | Nothing |
| `check-failed:` `check-cancelled:` | A check on the head commit failed | Read the log (section 5). Report once `ci-finished:` arrives |
| `ci-finished:` | Nothing pending, some checks failed | Section 5 |
| `ci-green:` | Nothing pending, nothing failed | One line to Alan; keep watching |
| `ci-missing:` | No CI/CD run for this commit | Section 5, last row |
| `thread:` `thread-update:` | An inline thread needs an answer, or a reviewer answered back | Section 6 |
| `review:` | A review landed | `APPROVED`: one line to Alan. A body with concerns: section 6, chat-only item |
| `top-level:` | A PR-level comment | Section 6, chat-only item |
| `conflict:` | The PR conflicts with its base | Name the conflicting files (`git fetch origin`, `git merge-tree`; both read-only). Recommend merging the base in for a single PR, a restack for a stack. Wait |
| `quiet:` | CI settled, nothing new for 15 minutes; the script exited | Section 7 |
| `closed:` | Merged or closed; the script exited | Stop |
| `watch-error:` | `gh` keeps failing | `gh auth status`; report |
| `already-watching:` | A watch on this state dir is still running | Nothing |
| Monitor timeout notice | The 30-minute cap | Arm again with the same command |

A running watch picks up a new push by itself. Arm again, with the same command and state dir, only when the watch has ended and the PR still needs it: on a timeout notice, or after a push that follows `quiet:`. Arming when unsure is safe; a second copy exits at once. The state dir is what stops an event being reported twice.

After two timeout notices in a row with no events, look once at `gh pr checks <pr>`, tell Alan what is still pending, and ask whether to keep watching.

## 5. CI failures

Read the log, change nothing, and add a numbered item to the report (section 6). The event's link ends in `/runs/<run>/job/<job>`: `gh run view <run> --log-failed` once the run has finished, `gh api repos/{owner}/{repo}/actions/jobs/<job>/logs` while it is still going.

| What the log shows | Item's rec |
| --- | --- |
| The failing files are in this branch's diff | `Rec: fix - <what, path:line>` |
| The failing files are not in the diff | `main` is red. Confirm on main's head commit. `Rec: wait - main is red`; never copy the fix in. Once main is fixed, merging `origin/main` needs a go-ahead |
| `lint` failed with 0 eslint errors | Read to the end of the log: it is the comment-budget step. `Rec: fix - …` |
| A cancelled duplicate run turned `test` or `post-checks` red | `gh run rerun <run>` (the full run, not `--failed`) straight away, and say so. No item needed |
| It looks flaky or like an infra fault | Give the evidence. `Rec: re-run` |
| `ci-missing:` | Two usual causes: the PR conflicts with its base (GitHub starts no pull-request workflows on a conflicting PR), or it is a later push to a stacked PR. Say "this commit has no CI run" and why, and offer a local typecheck. No empty commit or close-and-reopen without a go-ahead |

## 6. Review comments

**REQUIRED SUB-SKILL:** invoke `address-review-comments` on this PR for the investigation and scoring. Alan has pre-authorized that from inside this skill. Where the two differ, this skill wins:

- **Only what is new.** Report the items from events not yet reported, not every comment on the PR.
- **Change nothing yet.** Where the sub-skill would fix, say what the fix would be: `path:line` and one sentence.
- **Every item ends with a `Rec:` line.** Give your best call even on a "needs your pick" or "unclear" item; keep the options and the doubt above it and add `(low confidence)`.
- **Number across rounds.** A later round continues from the next number; never renumber. A reviewer's answer on a thread already replied to is a new item that names the old one.
- **Top-level items are chat-only**, not threads to fix and reply on.
- No typecheck, and replies only through `reply-thread.sh`.

| Item | `Rec:` line |
| --- | --- |
| Inline thread | `Rec: addressed - <one line>` or `Rec: wontfix - <one line>`: the exact reply |
| Chat-only: a review body, bot summary or top-level comment | `Rec: change - <what>` or `Rec: no change - <why>`, plus a one-liner Alan could post himself. Nothing is ever posted for these |
| CI failure | From section 5 |

Then stop and wait for the verdict.

### Alan's verdicts

`1. agreed 2. wontfix - deferred to next ticket 3. your rec, reply flow`

| He says | Do |
| --- | --- |
| `agreed` | He agrees with the reviewer: make the change, whatever your rec was. Thread reply: `addressed - <what changed>`. On a CI item: do the rec |
| `wontfix` or `wontfix - <reason>` | Change nothing. Thread reply: `wontfix - <his reason, else the one in your rec>`. If neither exists, ask him for the one line and carry on with the other items |
| `your rec` | Do what the `Rec:` line said |
| `all agreed`, `all your rec` | The same for every open item |
| `reply flow` | The go-ahead to commit, push, reply and resolve |

Verdicts without `reply flow` (or "push", "ship it", "reply and resolve"): make the edits, stop at the diff, and say what is waiting. Items he did not mention stay open: no edit, no reply.

### Reply flow

1. Make the edits the verdicts call for: code, or the PR description (`gh pr edit --body-file`) for a chat-only `change`. Run eslint, prettier and `pnpm lint:comments` on the edited files.
2. One commit, staged by name, and push. Skip both when nothing in the tree changed.
3. For each thread with a verdict: `bash ~/.claude/skills/alan-ship/reply-thread.sh <pr> <comment-id> 'addressed - <one line>'`. The comment id is the `[comment N]` in the event; `--list` shows them all. The script replies inline, resolves the thread, and refuses any other wording.
4. Arm the watch again if it has ended.
5. Report one line per item: the verdict, the reply posted, the commit.

A reply is the status word, ` - `, and one line in plain words. No greeting, no thanks, no second sentence, no commit hash. A thread that belongs to another PR in the stack gets its fix on that PR's branch; say so in the report before the flow runs.

## 7. Done

On `quiet:` with green CI and no item waiting on a verdict: the PR URL and one line on what shipped and how many comments were addressed or marked wontfix. Otherwise list what is still waiting on Alan: threads, chat-only items, CI items. Either way the watch is now off; it comes back on the next push, or when he asks.

## Common mistakes

| Mistake | Instead |
| --- | --- |
| Fixing or committing because "/alan-ship was the go-ahead" | That covered the diff that existed then. Report and wait |
| Typechecking "to be safe" before the push | CI is the typecheck |
| Checking on CI between events | Wait for the Monitor |
| Treating verdicts alone as permission to push | Wait for `reply flow` |
| Reading `agreed` as "agreed with my rec" | `agreed` sides with the reviewer; `your rec` sides with you |
| Answering a review body with a top-level comment | Chat-only item, with a one-liner for Alan |
| Padding a reply with an explanation | Status word, one line |

## Other repos

The flow is the same. Use that repo's lint commands and PR conventions, and pass `--require-workflow '<its main CI workflow>'` (or `''`) to `watch-pr.sh`.
