# claude-skills

A collection of custom [Claude Code](https://claude.com/claude-code) skills.

All three are **manual-invoke only** — they never auto-trigger. Run them with their
slash command (e.g. `/scoping-linear-tickets`) or by naming the skill.

## Skills

| Skill | What it does |
| --- | --- |
| [`scoping-linear-tickets`](skills/scoping-linear-tickets/) | Scopes a pasted Linear ticket into a structured brief — what it achieves, how it fits the epic, localhost before/after, and grill questions or files-to-touch. |
| [`build-and-codex-review`](skills/build-and-codex-review/) | After a scoping brief is green-lit: builds the change, writes a handoff, derives concern lenses, and runs a Workflow that loops codex adversarial reviews into code-reading fixers until reviews come back clean. |
| [`address-review-comments`](skills/address-review-comments/) | Investigates PR review comments (pasted or pulled via `gh`), scores each by confidence, then fixes, surfaces options with a recommendation, or reports uncertainty. |

These pair up as a workflow: **scope** a ticket → **build & review** it → **address** the review comments that come back.

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
