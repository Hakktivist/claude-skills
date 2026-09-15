---
name: build-and-codex-review
description: Manual-invoke only — do NOT auto-trigger. Use when a scoping brief is green-lit and the user is ready to implement and then run the automated codex review loop. Builds the change, writes a handoff, derives concern lenses, and runs a Workflow that loops codex adversarial reviews into code-reading fixers until reviews come back clean. Use ONLY when the user runs /build-and-codex-review or names it.
---

# Build and Codex Review

## Overview

The post-green-light pipeline: **build → handoff → codex-review-loop**. You (main thread) stay the *lean orchestrator* — you build, write a handoff, derive ≤3 concern lenses, then hand the deterministic review loop to a Workflow. Confident findings get auto-fixed; everything uncertain comes back to the user.

**Precondition:** the user has already run `/scoping-linear-tickets` and green-lit the brief. If they haven't, send them there first — don't scope here.

**Setup precondition (check once):** the codex plugin must be installed. If `find "$HOME/.claude/plugins" -name codex-companion.mjs` is empty, tell the user to run `/plugin install codex@openai-codex` then `/codex:setup`, and stop.

## Workflow

### 1. Build
Implement the green-lit brief. For multi-task plans, use [[subagent-driven-development]]; otherwise build directly with [[test-driven-development]]. When you dispatch build subagents, launch them with `model: "opus"` — the alias always resolves to the latest Opus. Do **not** commit — the loop reviews the working tree.

### 2. Write the handoff
Copy `handoff-template.md` (in this skill's directory) and fill it in for what you just built. The concern map (section 3) is the important part — it's where review lenses come from. The template's first line tells every downstream agent: **this is context, not ground truth — verify against the code.** Keep it honest about soft spots; that's where review pays off.

**Always write the handoff into a fresh temp dir — never the repo.** The loop reviews the working tree *including untracked files*, so a `HANDOFF.md` at repo root would pollute the very review it feeds (and dirty git). Mint a unique dir each run with `mktemp -d` and write `HANDOFF.md` inside it:
```sh
HANDOFF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bcr-handoff.XXXXXX")
PROGRESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bcr-progress.XXXXXX")
# write the filled-in template to "$HANDOFF_DIR/HANDOFF.md"
echo "$HANDOFF_DIR/HANDOFF.md"
echo "$PROGRESS_DIR"
```
Note both printed paths. The handoff path IS the review spec: pass it as `args.handoffPath` in step 4. `PROGRESS_DIR` is where each lens's live codex progress log lands — pass it as `args.progressDir` and use it in step 3.5. Never inline the handoff *text* into args: review runners `cat` the file straight into the codex command and fixers Read it themselves, so the text never sits in any agent's context or gets re-typed token-by-token.

### 3. Derive concern lenses
From the handoff's concern map, write **≤3 distinct lenses** — one focused review angle each (e.g. `"the auth-token refresh path and its race conditions"`, `"the data migration's backfill correctness"`). More passes ≠ better; 3 is the max for a reason. One concern → one lens.

### 3.5 Arm the progress watch

Codex reviews run 5–20+ minutes and print nothing until they finish (`--json` suppresses the companion's live stderr trace). Without this step the user stares at a silent workflow. Each lens redirects `CLAUDE_PLUGIN_DATA` to `$PROGRESS_DIR/lens<N>-r<round>.data`, which relocates the companion's job log somewhere you can predict — so arm **one** Monitor over the whole dir *before* invoking the Workflow, substituting the real `PROGRESS_DIR`:

```sh
PD="<PROGRESS_DIR>"
while true; do
  for f in "$PD"/lens*.data/state/*/jobs/review-*.log; do
    [ -f "$f" ] || continue
    lens=$(printf '%s\n' "$f" | sed -n 's|.*/\(lens[^/]*\)\.data/state/.*|\1|p')
    marker="$PD/.seen-$lens"
    prev=$(cat "$marker" 2>/dev/null || echo 0)
    cur=$(wc -l < "$f" | tr -d ' ')
    [ "$cur" -gt "$prev" ] || continue
    sed -n "$((prev+1)),${cur}p" "$f" \
      | grep -v 'Running command\|Command completed\|^{' \
      | grep -E 'Assistant message captured|Turn completed|Turn failed|Starting Codex Adversarial Review|Verdict:|[Ee]rror|[Ff]ailed|cancelled' \
      | sed -e 's/^\[[^]]*\] //' -e 's/Assistant message captured: {[^}]*"summary":"/» /' -e 's/","findings.*//' -e "s|^|[$lens] |" \
      | cut -c1-200
    printf '%s' "$cur" > "$marker"
  done
  sleep 20
done
```

Use `persistent: true` and a description like `codex review progress`. It emits roughly 4–8 lines per lens per review — the `»` lines are codex narrating its current hypothesis — and stays silent when nothing has changed. Stop it with TaskStop once the Workflow returns.

The label captured by that `sed` is the whole lens-and-round tag (`lens2-r1`), which is also what keys the `.seen-` markers — so each round gets its own marker and line count, and the output tells you which round you are watching. Don't narrow the capture to `lens[0-9]*`: it silently matches nothing against a round-suffixed dir, which collapses every lens onto one shared marker and prints empty `[]` labels.

The filter deliberately covers `Turn failed` / error / cancelled as well as the happy path: a monitor that only greps for progress goes silent on a crash, and silence is indistinguishable from "still thinking."

### 4. Run the loop (Workflow)
Invoke the **Workflow** tool with `scriptPath` set to this skill's `codex-review-loop.workflow.js`, passing `args`:
```
{ lenses: [...],            // step 3
  handoffPath: "<absolute path to HANDOFF.md from step 2>",  // the PATH, never the text
  progressDir: "<PROGRESS_DIR from step 2>",                 // what step 3.5 is watching
  scope: "working-tree",    // staged + unstaged + untracked
  base: undefined,          // or a ref for branch review
  maxRounds: 3,
  arcSkillPath: "/Users/alannguyen/.claude/skills/address-review-comments/SKILL.md",
  runnerModel: "sonnet",    // review RUNNERS only; omit to keep the default
  fixerModel: "opus" }      // FIXERS; omit to keep the default (also opus)
```
The Workflow runs each lens as a codex adversarial-review, dedups findings, dispatches one code-reading fixer per file (applying [[address-review-comments]]'s two-dimensional matrix), and loops until codex stops raising fresh findings or only HITL items remain. This is an explicit, skill-directed Workflow invocation — that's the opt-in; just call it.

**`lenses` and `handoffPath` are required.** The script parses stringified-args deliveries itself and throws `lenses/handoffPath missing` if the review spec still isn't there — it will never fall back to a generic single-lens review. If it throws, relaunch with `args` as a real JSON object; do not hardcode a temp copy of the script. The path must be plain (letters, digits, `._/ -`); it is interpolated into a shell command, so the script rejects anything shell-active.

**Adjudicated items are fed back to codex each round.** HITL items aren't fixed, so the code stays the same and codex would otherwise re-flag them every round — wasting review credits. Once an item is surfaced to the human (needs-pick / intent-check / unclear), the loop injects it into the next round's codex focus as an "already adjudicated — do not re-report" list, so codex stops re-analyzing it. Fixes are *not* suppressed — codex still re-checks that they held.

**Both agent tiers are pinned; neither inherits the session model.** Review runners use `runnerModel` (default `sonnet`) — they do no code reasoning, just invoke codex and transcribe its JSON, so a strong model is pure waste. Fixers use `fixerModel` (default `opus`, an alias that always resolves to the latest Opus) — they read real code, score claim-accuracy against intent, and make the edits, so they need the judgment. Pinning rather than inheriting matters in both directions: inheriting meant a fable session silently paid fable rates for every fixer on every round, and anything below opus misapplies the two-dimensional matrix — where the expensive failure mode is a confident wrong fix, not a missed one.

**Review runners detach codex, then re-attach.** A foreground Bash call is capped at 10 minutes; codex adversarial reviews routinely exceed that, and the cap SIGTERMs codex mid-flight — which reads as a review failure and blocks the whole loop. `run_in_background` does **not** solve this: a schema-bound subagent that backgrounds its work has nothing left to do, so the task is torn down before codex ever finishes (the symptom is a 0-byte output file and "did not complete within the available turns").

So the runner's script `nohup`s codex on first run, writing its stdout, stderr, and exit code to files under a stable per-lens-per-round prefix (`lens<N>-r<round>`), then waits ~8 minutes in the foreground. If codex hasn't finished it prints `BCR_PENDING` and the runner re-runs the **identical** script — a `.started` marker makes it re-attach to the live run instead of relaunching. Each call stays well under the cap, and a 20-minute review costs about 3 model requests instead of 2. Detached processes provably survive across Bash calls, which is what makes the re-attach work.

**The round belongs in that prefix.** `.started`/`.done` are what make the re-attach cheap, and they are exactly what makes a round-invariant prefix dangerous: round 2 finds round 1's sentinels, skips the launch, and re-prints round 1's cached `.out` without ever invoking codex. That replay both fakes the confirming round and re-flags everything auto-fixed in round 1, escalating each to HITL as "the fix did not satisfy codex."

**Each lens reaps its own codex broker.** Redirecting `CLAUDE_PLUGIN_DATA` buys the tailable job log, but it also relocates the companion's broker registry (`lib/broker-lifecycle.mjs` keys `broker.json` off `$CLAUDE_PLUGIN_DATA/state`). The plugin's only teardown is its `SessionEnd` hook, which looks under the *session's* `CLAUDE_PLUGIN_DATA` and so never sees a lens's broker — and brokers are spawned detached with no idle timeout. So the detached script kills its broker tree (broker → `codex app-server` → `codex-code-mode-host`) after writing `.done`. Without it, every lens of every run leaks three processes that live until reboot.

### 5. Present results
When the Workflow returns, **TaskStop the progress Monitor from step 3.5** (it is persistent and will otherwise run until the session ends), then relay its `note`, then:
- **Blocked** (`blocked[]`) — surface FIRST and loudly. These are review-runner failures (codex errored or an agent crashed), so the review did **not** actually run that round — the result is NOT a clean bill of health. Tell the user what failed and that coverage is incomplete; do not present the run as passing.
- **Auto-fixed** (`fixed[]`) — one line each: `file — what changed`. Tell the user to review the diff.
- **Needs your decision** (`hitl[]`) — surface each per [[address-review-comments]]'s output format: needs-pick (options + your rec), intent-check (codex is right but maybe intentional — confirm/override), or unclear (what couldn't be verified). Do **not** auto-fix these.

Then stop. Do not commit or push unless the user says so.

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Scoping the ticket here | Precondition — the user runs `/scoping-linear-tickets` first |
| Committing before review | Loop reviews the working tree; leave it uncommitted |
| Writing `HANDOFF.md` into the repo | It's an untracked file the working-tree review would flag; always `mktemp -d` it outside the repo |
| Passing handoff text instead of its path | `args.handoffPath` only — inlining the text bloats every runner's context and Write output |
| Writing >3 lenses to "be thorough" | 3 max; more passes just add noise. One concern → one lens |
| Handoff written as ground truth | It's the builder's belief; the template says verify against code, and fixers do |
| Letting the orchestrator (you) review code | You stay lean — codex reviews, fixers read code. You derive lenses and aggregate |
| Auto-fixing HITL items | needs-pick / intent-check / unclear go to the user, never silent fixes |
| Re-running a clean loop "to be sure" | If it returned clean + a verdict, trust it; re-run only after the user resolves HITL |
| Using `run_in_background` for the codex call | A schema-bound subagent can't idle — the task is torn down and you get a 0-byte output. Detach + re-attach in the foreground instead |
| Editing the script between `BCR_PENDING` retries | It must be byte-identical to re-attach; any change risks relaunching a second full review |
| Skipping the step 3.5 Monitor | The user gets a silent 20-minute workflow and can't tell slow from hung |
| Leaving the Monitor armed after the run | It's `persistent: true` — TaskStop it in step 5 |
| Reusing one `PROGRESS_DIR` across runs | Stale `.seen-lens*` markers suppress the new run's early progress; `mktemp -d` a fresh one each time |
| Dropping the round from the lens prefix | Round 2+ re-attaches to round 1's `.done` and replays its findings without running codex — a fake clean round that also escalates every auto-fix to HITL |
