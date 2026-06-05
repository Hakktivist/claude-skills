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

## Dependency skills

The skills above (and each other) reference these supporting skills, vendored here so the
repo is self-contained. They're copies of the [superpowers](https://github.com/obra/superpowers) skill set:

| Skill | Referenced by |
| --- | --- |
| [`subagent-driven-development`](skills/subagent-driven-development/) | `build-and-codex-review` |
| [`test-driven-development`](skills/test-driven-development/) | `build-and-codex-review`, `subagent-driven-development` |
| [`receiving-code-review`](skills/receiving-code-review/) | `address-review-comments` |
| [`requesting-code-review`](skills/requesting-code-review/) | `subagent-driven-development` |
| [`writing-plans`](skills/writing-plans/) | `subagent-driven-development` |
| [`executing-plans`](skills/executing-plans/) | `subagent-driven-development` |
| [`using-git-worktrees`](skills/using-git-worktrees/) | `subagent-driven-development` |
| [`finishing-a-development-branch`](skills/finishing-a-development-branch/) | `subagent-driven-development` |
| [`grill-me`](skills/grill-me/) | `scoping-linear-tickets` |
| [`brainstorming`](skills/brainstorming/) | `writing-plans`, others |

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
