---
name: codex-continue-review-loop
description: Manual-invoke only — do NOT auto-trigger. Use after a /codex-build-and-review run, once the human has answered the open items (needs-pick / intent-check / unclear) and their decisions need to be built, recorded, and put back through the review loop. Use ONLY when the user runs /codex-continue-review-loop or names it.
metadata:
  short-description: Build the human's decisions, record them, and re-run the review loop
---

# Codex Continue Review Loop

Companion to **codex-build-and-review**. Run it once the human has answered that loop's open items.

The shape: **build their decisions → record them → re-run the loop.** The re-run is the point. A
decision that was never reviewed is just an unreviewed change, and the ones you build here are
usually in the code's most contested spots.

## 1. Find the run dir

If `$RUN` isn't already in this session, ask the user for the handoff path — the run dir is its
parent:

```sh
RUN=$(dirname "<handoff path>"); ls "$RUN/state"
```

If the run dir is gone (temp dirs get reaped), say so plainly, then `init` a fresh one per
codex-build-and-review step 2, copy the old handoff into it as `$RUN/HANDOFF.md`, and re-seed the
suppression list from the handoff's section 7 ledger:

```sh
cat >> "$RUN/adjudicated.md"   # one line per item already decided: [file] title — disposition: reason
```

Round numbering restarts at 1. Say that too — without the old ledger, a reviewer can legitimately
re-raise something already settled, and the user should know why. The observer's history is gone
with it, so it starts over from run 1.

Otherwise the next round is one higher than the highest `r<N>` under `$RUN/findings`.

## 2. Build the decisions

You are the builder here, same as in the original run. Implement exactly what the user decided —
their pick on a needs-pick, their override on an intent-check, whatever they resolved on an
unclear. Keep the edits minimal and scoped to the decision; a decision is not a licence to
refactor around it. Leave everything **uncommitted**.

If a decision is ambiguous, ask before building it. Guessing here is worse than guessing during the
review: you are writing code into the exact spot a reviewer already flagged.

## 3. Record each decision in the ledger

```sh
sh "<skill dir>/review-loop.sh" resolve "$RUN" <N> built|accepted "<the decision, in one line>"
```

`<N>` is the `#N` that `report` prints beside each item. **Resolve in descending index order** — `built` removes a
row and renumbers everything below it.

- **`built`** — you implemented their decision. It moves into the auto-fixed set, so a later
  reviewer re-flagging it **escalates** rather than being silently suppressed. Their decision still
  has to survive review; that is the point of putting it back through.
- **`accepted`** — they judged it fine as-is. It stays suppressed for the rest of the run, and no
  reviewer will spend another round on it.

Record every item the user answered. An unrecorded `accepted` comes straight back next round, and
the user gets asked the same question twice.

If the user ruled on an observer class, record that too, so the observer doesn't raise it again:

```sh
sh "<skill dir>/review-loop.sh" decide "$RUN" adopted|smaller-fix|accepted "<the class summary>" "<their reasoning>"
```

## 4. Update the handoff

Edit `$RUN/HANDOFF.md` in place — the path must stay valid, and reviewers read it fresh each round.

- **Section 7 (ledger):** every auto-fix from the earlier rounds, every decision the human made, and
  what you built for it.
- **Section 4 (deliberate decisions):** anything the human just confirmed as intentional belongs
  here now, including an accepted bug class. This is what stops the next round's reviewer arriving at
  the same objection cold.
- **Section 3 (concern map):** if the human adopted a class's change, the concerns have usually
  moved. Update them so the lenses follow.
- **Sections 1, 5, 6:** update anything your new edits made untrue — what the change does now, which
  soft spots closed, what you re-ran or didn't.

Keep it honest. It is still context, not ground truth, and the subagents still verify it.

## 5. Re-run the loop

Always. Take a new snapshot first, so this counts as a new run:

```sh
sh "<skill dir>/review-loop.sh" snapshot "$RUN"
```

Then pick up at **codex-build-and-review step 4** with the next round number:

- Reuse the previous lenses unless the concern map actually changed — then re-derive, still ≤3.
- Same mechanics, no shortcuts: `focus` per lens, spawn the batch with no inherited history and
  `reasoning_effort: high`, wait, `collect`, one fixer per file, `absorb`, close if you can.
- Same stopping rules: a round with `FRESH: 0` is the clean bill; a `BLOCKED:` lens is never a pass.

Then run the observer step and report, per steps 7 and 8, and append the result to section 7 of the
handoff. If open items remain, the user runs this skill again.

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Building the decisions and stopping there | The re-run is the point — freshly built code in contested spots is exactly what needs review |
| Skipping `resolve` | Unrecorded decisions come back next round and the user gets asked twice |
| Recording a built decision as `accepted` | `accepted` suppresses it; `built` keeps it reviewable, which is what a new edit needs |
| Resolving items in ascending order | `built` renumbers the rows under it — go descending |
| Writing a new handoff file | Edit the existing one in place; its path is what every subagent reads |
| Guessing at an ambiguous decision | Ask. You are editing the exact line a reviewer already flagged |
| Starting a fresh run dir when the old one still exists | You'd drop the ledger and re-litigate everything already settled |
| Reviewing the new edits yourself | Still the builder, still the blind spot. Spawn the subagents |
| Skipping the snapshot before re-running | The rounds join the previous run, so the observer can't see recurrence and never comes due |
