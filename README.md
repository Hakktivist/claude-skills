# claude-skills

A collection of custom [Claude Code](https://claude.com/claude-code) skills.

The custom skills are **manual-invoke only** — they never auto-trigger. Run them
with their slash command (e.g. `/scoping-linear-tickets`) or by naming the skill.

## Custom skills

| Skill | What it does |
| --- | --- |
| [`scoping-linear-tickets`](skills/scoping-linear-tickets/) | Scopes a pasted Linear ticket into a structured brief — what it achieves, how it fits the epic, localhost before/after, and grill questions or files-to-touch. |
| [`build-and-codex-review`](skills/build-and-codex-review/) | After a scoping brief is green-lit: builds the change, writes a handoff, derives concern lenses, and runs a Workflow that loops codex adversarial reviews into code-reading fixers until reviews come back clean. |
| [`continue-review-loop`](skills/continue-review-loop/) | Post-HITL companion to `build-and-codex-review`: once you've answered the loop's needs-pick / intent-check / unclear questions, builds your decisions, updates the handoff, and relaunches the review loop. |
| [`triage-bug`](skills/triage-bug/) | Runs a bug report to ground: reproduces it locally (live server → shrunk harness → static trace), root-causes it, applies and re-verifies a fix (left uncommitted), and reports back — asking you only when blocked on something only you can do. |
| [`address-review-comments`](skills/address-review-comments/) | Investigates PR review comments (pasted or pulled via `gh`), scores each by confidence, then fixes, surfaces options with a recommendation, or reports uncertainty. |
| [`review-buddy`](skills/review-buddy/) | Interactive pair-reviewer: gathers the diff (uncommitted files, open PR) and the ticket, then walks the changed files one at a time on your lead — what each does, whether it matches the ticket's intent, and any gaps. Pairs with `/manual-review`. |
| [`alan-ship`](skills/alan-ship/) | Ships the current branch: lint, commit, push, open the PR in the Paraform format, then one Monitor (`watch-pr.sh`) reports CI results and review comments as they land. Comments go through `address-review-comments`; a verdict like `1. agreed 2. wontfix 3. your rec, reply flow` commits, pushes, and replies `addressed - …` / `wontfix - …` inline before resolving each thread. No local typecheck, no commit without a go-ahead. |

These pair up as a workflow: **scope** a ticket → **build & review** it → **address** the review comments that come back. `review-buddy` sits alongside for a manual, file-by-file pass with a human in the loop, and `triage-bug` is the entry point when the ticket is a bug report rather than a feature.

From the second run of a review loop, an **observer** reads every run's findings and flags when they look like one bug class, such as fixes that keep producing the next finding, or several decisions that may be one decision. It reports a counted confidence, the smallest change that would remove the class, and that change's trade-offs. It's advisory: you adopt it, take a smaller fix, or accept the class. Both the Claude and Codex loops have it.

## Codex-native skills

These two run **inside Codex**, not Claude Code. They are the mirror image of
`build-and-codex-review`: there, Claude builds and Codex reviews; here, Codex builds and then spawns
**its own** reviewer and fixer subagents (`spawn_agent` / `wait_agent`) and loops them itself. Same
contract as the Claude-side pair — handoff-as-context, ≤3 concern lenses, one fixer per file, the
claim-accuracy × intent-match matrix, a suppression ledger across rounds, and every uncertain item
stopping for you.

| Skill | What it does |
| --- | --- |
| [`codex-build-and-review`](skills/codex-build-and-review/) | Codex builds the green-lit change, writes a handoff outside the repo, derives ≤3 concern lenses, then loops: spawn one adversarial reviewer subagent per lens → route findings by file → one code-reading fixer subagent per file → repeat until a round comes back with no fresh findings. |
| [`codex-continue-review-loop`](skills/codex-continue-review-loop/) | Post-decision companion: builds what you decided on the open items, records each as *built* (still reviewable) or *accepted* (suppressed), updates the handoff, and re-runs the loop. |

The loop's bookkeeping — parsing subagent output, dedup across rounds, suppressing adjudicated
items, escalating a finding that reappears after an auto-fix — lives in
[`review-loop.sh`](skills/codex-build-and-review/review-loop.sh) (POSIX sh + awk, no deps), so it
can't drift the way a long agent turn's memory does. Codex keeps the judgment: what to build, which
lenses, when to stop.

They need Codex's multi-agent tools. If `spawn_agent` isn't in the session, run
`codex features enable multi_agent` and restart — the skill stops rather than falling back to
reviewing its own work.

## Supporting skills

The rest of the repo vendors the [superpowers](https://github.com/obra/superpowers) skill set
so it's self-contained — both the skills the custom three (transitively) depend on and the
general-purpose helpers. Excludes `daily-update` and `find-skills`.

| Skill | Role |
| --- | --- |
| [`subagent-driven-development`](skills/subagent-driven-development/) | Dep of `build-and-codex-review` |
| [`test-driven-development`](skills/test-driven-development/) | Dep of `build-and-codex-review`, `subagent-driven-development` |
| [`receiving-code-review`](skills/receiving-code-review/) | Dep of `address-review-comments` |
| [`requesting-code-review`](skills/requesting-code-review/) | Dep of `subagent-driven-development` |
| [`writing-plans`](skills/writing-plans/) | Dep of `subagent-driven-development` |
| [`executing-plans`](skills/executing-plans/) | Dep of `subagent-driven-development` |
| [`using-git-worktrees`](skills/using-git-worktrees/) | Dep of `subagent-driven-development` |
| [`finishing-a-development-branch`](skills/finishing-a-development-branch/) | Dep of `subagent-driven-development` |
| [`manual-review`](skills/manual-review/) | Dep of `review-buddy`; lists changed files grouped as needs human review, mechanical, codegen, tests, frontend only (`by-layer` for stack order) |
| [`grill-me`](skills/grill-me/) | Dep of `scoping-linear-tickets` |
| [`brainstorming`](skills/brainstorming/) | Dep of `writing-plans` |
| [`systematic-debugging`](skills/systematic-debugging/) | General-purpose |
| [`verification-before-completion`](skills/verification-before-completion/) | General-purpose |
| [`dispatching-parallel-agents`](skills/dispatching-parallel-agents/) | General-purpose |
| [`using-superpowers`](skills/using-superpowers/) | General-purpose |
| [`writing-skills`](skills/writing-skills/) | General-purpose |

## Install

Claude skills live in `~/.claude/skills/`; the `codex-*` skills go to `$CODEX_HOME/skills`
(`~/.codex/skills`) instead, since Codex is what runs them. `install.sh` sorts them out. Clone this
repo and symlink each skill (so `git pull` keeps them current):

```sh
git clone https://github.com/Hakktivist/claude-skills.git
cd claude-skills
./install.sh
```

Or copy them in manually:

```sh
cp -R skills/* ~/.claude/skills/
```

## Note on `build-and-codex-review`

`build-and-codex-review` references `address-review-comments` by its installed path
(`~/.claude/skills/address-review-comments/SKILL.md`). Install both for the full loop.
The path can be overridden via the workflow's `arcSkillPath` arg.
