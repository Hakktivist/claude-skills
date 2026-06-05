# Handoff: <ticket / branch name>

> **To every downstream agent (codex reviewers and fixers): this handoff is CONTEXT, not ground truth.**
> It records what I *intended* and *believe* I did. Verify every claim against the actual diff and code.
> If the code contradicts this document, the code wins — flag the divergence.

## 1. What was built
2–5 sentences. The behavior change, not the file list.

## 2. Scope of the change (what to review)
- Working-tree state under review: staged + unstaged + untracked.
- Out of scope / intentionally deferred: <things reviewers should NOT flag as missing>.

## 3. Concern map  ← the orchestrator derives review lenses from this
List the 1–3 distinct *concerns* in this change. Each becomes one codex adversarial-review lens.
Order by risk. Keep to ≤3 — more passes ≠ better, just noisier.

- **Concern A — <name>:** <where it lives, what could go wrong, the assumption it rests on>
- **Concern B — <name>:** ...
- **Concern C — <name>:** ...

## 4. Deliberate decisions (pre-empt false positives)
Things a reviewer will likely flag that were on purpose. For each: what + why.
- <decision> — intentional because <reason>.

## 5. Known soft spots
Where I'm genuinely unsure and *want* scrutiny. Be honest — this is where review pays off.
- <area> — <the specific doubt>.

## 6. Verification done / not done
- Tests run: <command + result, or "none">.
- Manually verified: <what, or "not yet">.
- Not verified: <what reviewers should assume is unverified>.
