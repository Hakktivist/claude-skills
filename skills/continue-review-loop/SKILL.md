---
name: continue-review-loop
description: Manual-invoke only — do NOT auto-trigger. Use after a /build-and-codex-review run, when the user has answered the loop's HITL questions (needs-pick / intent-check / unclear) and their decisions need to be built and the handoff updated. Use ONLY when the user runs /continue-review-loop or names it.
---

# Continue Review Loop

Companion to [[build-and-codex-review]] — run it after the user has adjudicated that loop's HITL items.

Build out anything that the user asked you to in response to your questions. After building it out, edit your hand-off: document all decisions and changes made, including all autofixes, all fixes from the user, and all items that were brought up and accepted. If the handoff path isn't in context, ask the user for it.

Then ALWAYS re-run the review loop — do not stop after building and editing the handoff; the re-run is the point of this skill. Invoke the codex-review-loop Workflow exactly as [[build-and-codex-review]] step 4 describes, passing the updated handoff's path as `args.handoffPath` — edit the prior run's `HANDOFF.md` in place so the path stays valid, and never inline the text (reuse the prior run's lenses unless the handoff's concern map changed — then re-derive ≤3), and present the results per its step 5.
