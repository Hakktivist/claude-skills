# claude-skills

A collection of custom [Claude Code](https://claude.com/claude-code) skills.

The three custom skills are **manual-invoke only** — they never auto-trigger. Run them
with their slash command (e.g. `/scoping-linear-tickets`) or by naming the skill.

## Custom skills

| Skill | What it does |
| --- | --- |
| [`scoping-linear-tickets`](skills/scoping-linear-tickets/) | Scopes a pasted Linear ticket into a structured brief — what it achieves, how it fits the epic, localhost before/after, and grill questions or files-to-touch. |
| [`build-and-codex-review`](skills/build-and-codex-review/) | After a scoping brief is green-lit: builds the change, writes a handoff, derives concern lenses, and runs a Workflow that loops codex adversarial reviews into code-reading fixers until reviews come back clean. |
| [`address-review-comments`](skills/address-review-comments/) | Investigates PR review comments (pasted or pulled via `gh`), scores each by confidence, then fixes, surfaces options with a recommendation, or reports uncertainty. |

These three pair up as a workflow: **scope** a ticket → **build & review** it → **address** the review comments that come back.

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
| [`grill-me`](skills/grill-me/) | Dep of `scoping-linear-tickets` |
| [`brainstorming`](skills/brainstorming/) | Dep of `writing-plans` |
| [`systematic-debugging`](skills/systematic-debugging/) | General-purpose |
| [`verification-before-completion`](skills/verification-before-completion/) | General-purpose |
| [`dispatching-parallel-agents`](skills/dispatching-parallel-agents/) | General-purpose |
| [`using-superpowers`](skills/using-superpowers/) | General-purpose |
| [`writing-skills`](skills/writing-skills/) | General-purpose |

## Install

Skills live in `~/.claude/skills/`. Clone this repo and symlink each skill (so
`git pull` keeps them current):

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
