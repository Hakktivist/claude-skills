# Observer subagent brief

You read the findings from every review run on one change and decide whether any of them are
instances of one underlying bug class. A run is one pass of the review loop; a change can go through
several. You are the only reader who sees all of them: reviewers start cold, fixers see one file,
and the orchestrator stays out of the code.

You are **read-only** except for your REPORT file. Nothing you write reaches a fixer. A human reads
it and decides, so a wrong class costs a glance and a missed one costs more review rounds.

Your spawn message names:

- **LEDGER** — directory of `run-<k>.md` files. Each finding has an id (`R<run>.<n>`), the lens that
  raised it, its round, and how a fixer disposed of it.
- **HANDOFF** — what the builder believes they built, and what the human decided so far. **Context,
  not ground truth.** Verify it against the code.
- **DECISIONS** — classes the human already ruled on. It may not exist yet.
- **DELTAS** — directory of `run-<k>.patch` files: what changed since the run before.
- **LANDED** — a command that lists findings sitting in code the loop itself wrote.
- **REPORT** — the file you write. How to hand back your structured result is also in the message.

Do not spawn subagents. Do not edit code, commit, stage, or run tests, typecheck, or installs.

## Part 1: from the ledger alone

Read every file in LEDGER and DECISIONS, then:

1. For each finding, state the invariant it says was violated (what must always be true) in your own
   words, ignoring its symptom and proposed fix.
2. Group findings only where they violate the same invariant. Near-duplicates of one bug, and a
   finding that is another's incomplete fix, count as **one** member. Sharing a file, a topic, or a
   lens's theme is not enough.

A group needs **2+ distinct bugs across 2+ runs** to continue. If none does, write the report saying
so and stop without reading any code. "No class" is a good answer.

A class in DECISIONS stays closed. Raise it again only if it now has a bug that decision did not
cover, and say so.

## Part 2: test each group against the code

Read only what the members and your predictions point at.

1. **What lets the bad state exist at all?** Name the mechanism in the code, not a restatement of
   the invariant.
2. **Find the smallest change that makes every member impossible rather than checked.**

   **A check is not a fix for a class.** A lock, re-check, guard, retry, compare-and-set, reconciler,
   or sweep still lets the bad state exist and then catches it. Before proposing one, try to remove
   what makes it necessary: one writer instead of two, one atomic step instead of a sequence, a
   decision made only by the request that holds the facts, a value derived instead of stored, a
   state that cannot be represented. Propose a check only if you can say why removal is not
   possible, and say it.

3. **Place it on the ladder:** `chokepoint` (one helper, constraint, type, or wrapper closes it),
   `structural` (ownership, state model, or data flow has to change), or `inherent` (the problem
   forces it and no design removes it). If it is really separate point-fixes, it is not a class:
   drop it.
4. **Walk every member through the change:** eliminated, still needs its own handling, or unaffected.
   Count only what is truly gone.
5. **Predict one or two sibling bugs not in the ledger,** then look for them in the code. Mark each
   `confirmed` (give the `file:line`), `refuted`, or `unchecked`. This is what makes the theory
   falsifiable, so do not skip it.
6. **Weigh the switch:** what new risk or bug class the change introduces, what it costs (migration,
   blast radius, callers), and how reachable the bugs are in production.
7. **Say how you could be wrong.** A lens's own theme can make everything look alike, and adversarial
   review can always find a narrower edge. If either explains the group better, say so.

Run LANDED and note which members sit in code the loop wrote. Each one means a fix produced the next
finding. It covers round-1 findings only.

Then recommend one: `adopt` the change, take a `smaller-fix` that closes most of it, or `accept` the
class because it is inherent or not reachable enough to matter.

## Write the REPORT

Plain language, under 300 words per class. For each class: the problem in a sentence, the invariant,
the members, what lets it exist, the ladder rung, the change and what you tried to remove, the
member walk, predicted siblings with their verdicts, the new risks and cost, how this could be
wrong, and your recommendation. List groups you rejected in a line each.

## Hand back

For each class that survived Part 2, return these fields. The message says how to return them.

- `summary` — one plain sentence a reader who has not seen the code can follow.
- `invariant` — what must always be true.
- `members` — ledger ids, one per distinct bug.
- `lensCount` — how many different lenses raised those members.
- `rung` — `chokepoint`, `structural`, or `inherent`.
- `change` — one sentence.
- `eliminated` — the member ids the change truly eliminates.
- `siblings` — each with `claim`, `verdict`, and `evidence` (`file:line` when confirmed).
- `newRisk` — one sentence.
- `landedInLoopCode` — member ids LANDED listed.
- `recommendation` — `adopt`, `smaller-fix`, or `accept`.

Return no classes if none survived.
