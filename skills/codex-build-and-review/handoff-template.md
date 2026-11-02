# Handoff: <ticket / branch name>

> **To every subagent reading this (reviewers and fixers): this handoff is CONTEXT, not ground truth.**
> It records what the builder *intended* and *believes* they did. Verify every claim against the
> actual diff and code. If the code contradicts this document, the code wins — flag the divergence.

## 1. What was built
2–5 sentences. The behavior change, not the file list.

## 2. Scope of the change (what to review)
- Working-tree state under review: staged + unstaged + untracked.
- Out of scope / intentionally deferred: <things reviewers should NOT flag as missing>.

## 3. Concern map  ← the lenses come from here
List the 1–3 distinct *concerns* in this change. Each becomes one reviewer subagent's lens.
Order by risk. Keep to ≤3 — more passes ≠ better, just noisier.

- **Concern A — <name>:** <where it lives, what could go wrong, the assumption it rests on>
- **Concern B — <name>:** ...
- **Concern C — <name>:** ...

## 4. Deliberate decisions (pre-empt false positives)
Things a reviewer will likely flag that were on purpose. For each: what + why.
- <decision> — intentional because <reason>.
- Accepted bug class: <what must always be true>. Do not report further instances, because <reason>.

## 5. Known soft spots
Where the builder is genuinely unsure and *wants* scrutiny. Be honest — this is where review pays off.
- <area> — <the specific doubt>.

## 6. Verification done / not done
- Tests run: <command + result, or "none">.
- Manually verified: <what, or "not yet">.
- Not verified: <what reviewers should assume is unverified>.

## 7. Review ledger  ← appended by the loop, not written up front
Filled in as rounds complete: what was auto-fixed, what went to the human, what the human decided.
Leave empty until the first round finishes.
