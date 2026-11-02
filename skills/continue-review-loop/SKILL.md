---
name: continue-review-loop
description: Manual-invoke only — do NOT auto-trigger. Use after a /build-and-codex-review run, when the user has answered the loop's HITL questions (needs-pick / intent-check / unclear) and their decisions need to be built and the handoff updated. Use ONLY when the user runs /continue-review-loop or names it.
---

# Continue Review Loop

Companion to [[build-and-codex-review]] — run it after the user has adjudicated that loop's HITL items.

Build out anything that the user asked you to in response to your questions. After building it out, edit your hand-off: document all decisions and changes made, including all autofixes, all fixes from the user, and all items that were brought up and accepted. If the handoff path isn't in context, ask the user for it.

If the user ruled on an observer class, record it so the observer doesn't raise it again:

```sh
sh ~/.claude/skills/build-and-codex-review/observer-ledger.sh decide "$(dirname "<handoff path>")" adopted|smaller-fix|accepted "<the class summary>" "<their reasoning>"
```

- **adopted / smaller-fix** — build it, then update the handoff's sections 1 and 3. The concern map has usually changed, so re-derive the lenses.
- **accepted** — add it to the handoff's section 4 as an accepted bug class. That is what stops codex reporting further instances.

Then ALWAYS re-run the review loop — do not stop after building and editing the handoff; the re-run is the point of this skill. Take a new snapshot per [[build-and-codex-review]] step 3.6, using the prior run's handoff directory, then invoke the codex-review-loop Workflow exactly as its step 4 describes, passing the run number it printed as `args.runNumber` and the updated handoff's path as `args.handoffPath` — edit the prior run's `HANDOFF.md` in place so the path stays valid, and never inline the text (reuse the prior run's lenses unless the handoff's concern map changed — then re-derive ≤3), and present the results per its step 5.

`mktemp -d` a **fresh** `PROGRESS_DIR` for the re-run and arm its progress Monitor per [[build-and-codex-review]] step 3.5 before invoking the Workflow — do not reuse the previous run's dir, whose `.seen-lens*` markers would suppress the new run's early progress. TaskStop the Monitor when the Workflow returns.
