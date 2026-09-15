export const meta = {
  name: 'codex-review-loop',
  description: 'Run concern-lens codex adversarial reviews against the working tree and route findings to code-reading fixers, looping until reviews come back clean. Confident fixes auto-apply (one fixer per file, parallel-safe); low-confidence / intent-mismatch items are aggregated for the human.',
  phases: [
    { title: 'Review', detail: 'one codex adversarial-review pass per concern lens' },
    { title: 'Fix', detail: 'one fixer per file, applying the address-review-comments matrix after reading the code' },
  ],
}

// ---- args ----------------------------------------------------------------
// REQUIRED — the run refuses to start without a real review spec:
// args.lenses:      string[]  concern focuses derived from the handoff (<=3)
// args.handoffPath: string    absolute path to the handoff file (context, NOT ground truth).
//                             Passed by PATH, not text: runners `cat` it straight into the codex
//                             command and fixers Read it themselves, so the multi-KB handoff never
//                             sits in a runner's context and never gets re-typed through Write.
// Optional knobs (these keep defaults):
// args.scope:       string    codex --scope (default 'working-tree')
// args.base:        string?   optional --base ref
// args.maxRounds:   number    safety cap (default 3)
// args.arcSkillPath:string    absolute path to address-review-comments/SKILL.md
// args.progressDir: string?   absolute path to an empty per-run dir. Each lens points
//                             CLAUDE_PLUGIN_DATA at "<progressDir>/lens<N>", which relocates the
//                             codex companion's job state (state.mjs:41) so its live progress log
//                             lands at a path the MAIN thread can predict and tail with Monitor.
//                             Without it the review still runs — you just get no live visibility.
// args.runnerModel: string?   model for the codex review-RUNNER agents (default 'sonnet').
//                             Runners only invoke codex + transcribe its JSON — no code
//                             reasoning — so a cheap model is the right fit.
// args.fixerModel:  string?   model for the FIXER agents (default 'opus' — the alias always
//                             resolves to the latest Opus). Fixers do the real claim-accuracy /
//                             intent judgment and the edits, so they need a strong model; fable is
//                             not worth the spend here and anything below opus misjudges the matrix.
//
// The harness sometimes delivers args as a JSON-encoded STRING; reading .lenses off a
// string yields undefined, and the old defaults silently degraded the run to a generic
// single-lens review with no handoff — a blind pass that could return a false clean bill.
// So: parse the string form back, and if the review spec still isn't there, die loudly
// before any codex spend. A review harness that loses its spec must fail, not improvise.
const a = typeof args === 'string' ? JSON.parse(args) : args
if (!a || !Array.isArray(a.lenses) || !a.lenses.length || typeof a.handoffPath !== 'string' || !a.handoffPath.length) {
  throw new Error(`codex-review-loop: lenses/handoffPath missing (typeof args=${typeof args}) — refusing to run the default-lens fallback`)
}
const lenses = a.lenses.slice(0, 3)
// handoffPath is interpolated (double-quoted) into the runner's shell command, so allow only
// plain path characters — anything shell-active is rejected loudly, never interpolated.
const SAFE_PATH = /^\/[A-Za-z0-9._/ -]+$/
const handoffPath = a.handoffPath
if (!SAFE_PATH.test(handoffPath)) {
  throw new Error(`codex-review-loop: handoffPath "${handoffPath}" contains unsafe characters — refusing to interpolate it into a shell command`)
}
// scope goes straight into the shell command, so constrain it to the companion's
// accepted enum — never trust args. Anything else falls back to working-tree.
const SCOPES = ['auto', 'working-tree', 'branch']
const scopeArg = a.scope
const scope = SCOPES.includes(scopeArg) ? scopeArg : 'working-tree'
if (scopeArg && scope !== scopeArg) log(`WARNING: invalid scope "${scopeArg}" — falling back to working-tree.`)
const base = a.base
const maxRounds = a.maxRounds || 3
const arcSkillPath = a.arcSkillPath || '/Users/alannguyen/.claude/skills/address-review-comments/SKILL.md'
// Review runners do zero code reasoning (invoke codex, transcribe its JSON) — pin them to a
// cheap model by default so a strong session model isn't burned on mechanical transcription.
const runnerModel = a.runnerModel || 'sonnet'
// Fixers are the opposite: they read real code, score claim-accuracy vs intent, and make the
// edits. Pin them to opus rather than inheriting the session model — inheriting means a fable
// session silently pays fable rates per fixer per round, and anything cheaper than opus
// misapplies the two-dimensional matrix (the expensive failure is a confident wrong fix).
const fixerModel = a.fixerModel || 'opus'
// progressDir is interpolated into the runner's shell command exactly like handoffPath, so it
// gets the same allow-list. Absent → no isolation and no live progress path (loud warning).
const progressDir = typeof a.progressDir === 'string' && a.progressDir.length ? a.progressDir : null
if (progressDir && !SAFE_PATH.test(progressDir)) {
  throw new Error(`codex-review-loop: progressDir "${progressDir}" contains unsafe characters — refusing to interpolate it into a shell command`)
}
if (!progressDir) log('WARNING: no progressDir — codex job logs stay in the shared state dir, so live per-lens progress is NOT tailable this run.')
// Only allow git-ref-safe characters into the shell command. Anything with shell
// metacharacters is rejected (and surfaced) rather than silently interpolated.
const SAFE_REF = /^[A-Za-z0-9._/-]+$/
const baseUnsafe = base && !SAFE_REF.test(base)
const baseFlag = (base && !baseUnsafe) ? `--base ${base} ` : ''
if (baseUnsafe) log(`WARNING: base ref "${base}" contains unsafe characters — ignoring it and reviewing the working tree instead.`)

// ---- schemas -------------------------------------------------------------
const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdict', 'summary', 'findings'],
  properties: {
    verdict: { type: 'string', enum: ['approve', 'needs-attention', 'error'] },
    summary: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'title', 'body', 'file', 'line_start', 'line_end', 'confidence', 'recommendation'],
        properties: {
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          title: { type: 'string' },
          body: { type: 'string' },
          file: { type: 'string' },
          line_start: { type: 'integer' },
          line_end: { type: 'integer' },
          confidence: { type: 'number' },
          recommendation: { type: 'string' },
        },
      },
    },
  },
}

const FIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['file', 'results'],
  properties: {
    file: { type: 'string' },
    results: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'action', 'claim_accuracy', 'intent_match', 'detail'],
        properties: {
          title: { type: 'string' },
          action: { type: 'string', enum: ['fixed', 'needs-pick', 'intent-check', 'unclear'] },
          claim_accuracy: { type: 'number' },
          intent_match: { type: 'number' },
          detail: { type: 'string' },
          changed: { type: 'string' },
        },
      },
    },
  },
}

// ---- helpers -------------------------------------------------------------
function findingKey(f) {
  return `${(f.file || '').trim()}:${f.line_start || 0}:${(f.title || '').trim().toLowerCase()}`
}

function reviewPrompt(lens, i, suppress, round) {
  // Everything already surfaced to the human is fed back to codex so it stops
  // re-analyzing and re-reporting the same topics every round. This is semantic
  // (codex reads the descriptions), so it survives title/line drift that the
  // exact-key dedup below misses — and it saves credits UPSTREAM, before codex
  // spends them, not just downstream in Claude.
  const suppressBlock = (suppress && suppress.length)
    ? `\n\nALREADY ADJUDICATED — DO NOT RE-REPORT. Each item below has already been reviewed ` +
      `by a code-reading fixer or by the human, and was resolved, deferred to the human, or judged ` +
      `intentional. Do NOT raise any of these again — even if the code still looks wrong, the decision ` +
      `is already made and re-reporting only wastes review budget. Report ONLY issues NOT in this list:\n` +
      suppress.map((s, n) => `${n + 1}. [${s.file}] ${s.title} — ${s.disposition}${s.reason ? `: ${s.reason}` : ''}`).join('\n')
    : ''
  // The handoff is deliberately NOT inlined here: the runner never needs to read it —
  // only codex does. It is appended after the focus at the shell via cat, so the runner's
  // context stays a few lines no matter how big the handoff is.
  const focusText =
    `FOCUS: ${lens}. ` +
    `Use the handoff appended after this focus as CONTEXT only — do NOT trust it as ground truth; ` +
    `verify against the real diff.` +
    suppressBlock +
    `\n\nHandoff:`
  // Per-lens-per-ROUND working base. Everything about this lens's run (detached job output,
  // exit-code sentinel, focus file, and the relocated CLAUDE_PLUGIN_DATA state dir) hangs off one
  // stable prefix, so a LATER Bash call can re-attach to the SAME run without knowing anything new.
  // The round MUST be in the path: the re-attach guard is `.started`/`.done` on this prefix, so a
  // prefix shared across rounds makes round 2+ short-circuit to round 1's cached `.out` without
  // ever invoking codex — a replayed review that both fakes the confirming round and re-flags every
  // item auto-fixed in round 1, escalating each to HITL as "the fix did not satisfy codex".
  // progressDir is per-run and unique; the fallback is stable-but-shared, hence the warning above.
  const lensBase = progressDir
    ? `${progressDir}/lens${i + 1}-r${round}`
    : `\${TMPDIR:-/tmp}/bcr-fallback-lens${i + 1}-r${round}`
  return (
    `You are a codex review RUNNER. Do not review the code yourself and do not fix anything. ` +
    `Your job is to invoke codex once and faithfully transcribe its findings. Make NO exploratory ` +
    `tool calls — every extra call re-pays your whole context.\n\n` +
    `Step 1 — run EXACTLY this script with Bash, verbatim, in the FOREGROUND with the timeout ` +
    `parameter set to 540000. Do NOT use run_in_background: you are a schema-bound subagent, so if ` +
    `you background the work you have nothing to do and the task gets torn down before codex ever ` +
    `finishes. This script instead DETACHES codex on the first run and then waits for it, so no single ` +
    `Bash call ever approaches the 10-minute cap. The quoted heredoc keeps the focus text literal (the ` +
    `shell never interprets it) and the command substitution hands focus+handoff to codex as one ` +
    `literal argument — so do not "improve" the quoting.\n\n` +
    `BASE="${lensBase}"\n` +
    `mkdir -p "$(dirname "$BASE")"\n` +
    `OUT="$BASE.out"; DONE="$BASE.done"; ERR="$BASE.err"; STARTED="$BASE.started"\n` +
    `export CLAUDE_PLUGIN_DATA="$BASE.data"\n` +
    `if [ ! -f "$STARTED" ]; then\n` +
    `  COMPANION=$(find "$HOME/.claude/plugins" -name codex-companion.mjs 2>/dev/null | head -1)\n` +
    `  [ -n "$COMPANION" ] || { echo "BCR_ERROR: codex plugin not installed"; exit 9; }\n` +
    `  [ -s "${handoffPath}" ] || { echo "BCR_ERROR: handoff missing or empty at ${handoffPath}"; exit 9; }\n` +
    `  mkdir -p "$CLAUDE_PLUGIN_DATA"\n` +
    `  FOCUS="$BASE.focus"\n` +
    `  cat > "$FOCUS" <<'BCR_FOCUS_EOF'\n` +
    `${focusText}\n` +
    `BCR_FOCUS_EOF\n` +
    `  cat > "$BASE.sh" <<BCR_RUN_EOF\n` +
    `export CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA"\n` +
    `node "$COMPANION" adversarial-review --wait --json --scope ${scope} ${baseFlag}"\\$(cat "$FOCUS" "${handoffPath}")" > "$OUT" 2> "$ERR"\n` +
    `echo \\$? > "$DONE"\n` +
    // Reap this lens's codex broker. Because we point CLAUDE_PLUGIN_DATA at a private per-lens
    // dir (for the tailable job log), the companion also registers its broker there — and the
    // plugin's only teardown, the SessionEnd hook, looks for broker.json under the SESSION's
    // CLAUDE_PLUGIN_DATA. It never sees ours. The broker is spawned detached+unref'd with no idle
    // timeout, so without this every lens of every run leaks a broker + `codex app-server` +
    // `codex-code-mode-host` that survive until the machine reboots. This runs AFTER $DONE is
    // written, so the waiting runner is already free — the reap costs it nothing.
    `for bj in "\\$CLAUDE_PLUGIN_DATA"/state/*/broker.json; do\n` +
    `  [ -f "\\$bj" ] || continue\n` +
    `  BPID=\\$(grep -o '"pid"[^0-9]*[0-9][0-9]*' "\\$bj" | grep -o '[0-9][0-9]*\\$')\n` +
    `  [ -n "\\$BPID" ] || continue\n` +
    // Snapshot the tree BEFORE killing: once the broker dies its children reparent to init and
    // pgrep -P can no longer find them. Two levels is the real shape (broker -> app-server -> host).
    `  TREE="\\$BPID"\n` +
    `  for k in \\$(pgrep -P "\\$BPID" 2>/dev/null); do\n` +
    `    TREE="\\$TREE \\$k"\n` +
    `    for g in \\$(pgrep -P "\\$k" 2>/dev/null); do TREE="\\$TREE \\$g"; done\n` +
    `  done\n` +
    `  kill -TERM \\$TREE 2>/dev/null\n` +
    `  sleep 3\n` +
    `  kill -KILL \\$TREE 2>/dev/null\n` +
    `done\n` +
    `BCR_RUN_EOF\n` +
    `  : > "$STARTED"\n` +
    `  nohup sh "$BASE.sh" >/dev/null 2>&1 &\n` +
    `  disown 2>/dev/null\n` +
    `fi\n` +
    `i=0\n` +
    `until [ -f "$DONE" ] || [ $i -ge 250 ]; do sleep 2; i=$((i+1)); done\n` +
    `if [ -f "$DONE" ]; then RC=$(cat "$DONE"); echo "BCR_EXIT=$RC"; cat "$OUT"; ` +
    `[ "$RC" = 0 ] || { echo "BCR_STDERR:"; tail -20 "$ERR"; }; else echo "BCR_PENDING"; fi\n\n` +
    `The first run detaches codex and waits up to ~8 minutes for it. **If the output is ` +
    `BCR_PENDING, codex is still working — run the EXACT SAME script again.** It will detect the ` +
    `existing run and re-attach rather than relaunch (that is what the .started marker is for), so ` +
    `repeating it is cheap and safe. Keep repeating until you get a BCR_EXIT line. Give up only after ` +
    `6 consecutive BCR_PENDING results (~50 minutes), and return verdict "error" saying codex hung.\n\n` +
    `Do NOT read, cat, or paste the handoff yourself — it reaches codex inside the command substitution. ` +
    `Do NOT add other flags, edit the script between runs, or tail the logs — the main thread is already ` +
    `watching codex's live progress; extra calls here just re-pay your context.\n\n` +
    `If the script prints a BCR_ERROR line, return verdict "error" with that line as the summary and ` +
    `findings [] — never run a blind review without the handoff, and do NOT retry (neither cause is ` +
    `transient). A BCR_EXIT line with a non-zero code means codex itself failed: return verdict "error" ` +
    `with the BCR_STDERR text in the summary.\n\n` +
    `Step 2 — once you have BCR_EXIT=0, everything printed after it is the JSON ` +
    `payload (because of --json) with verdict, summary, and findings ` +
    `(each with file, line_start/line_end, severity, confidence 0-1, recommendation). ` +
    `Transcribe ALL findings into the schema verbatim from that JSON — do not add, drop, merge, or editorialize. ` +
    `If a finding lacks a line number, use 1. ` +
    `If the command exits non-zero, prints no parseable JSON, or otherwise fails, return verdict "error", ` +
    `summary describing exactly what went wrong (include stderr), and findings [] — do NOT fabricate findings or confidence.`
  )
}

// Findings as labeled text, not JSON.stringify — models read it at least as reliably,
// and it drops the brace/quote/indent overhead from every fixer prompt.
function renderFinding(f, n) {
  return `${n + 1}. [${f.severity}] ${f.title}\n` +
    `   ${f.file}:${f.line_start}-${f.line_end} — codex confidence ${f.confidence}\n` +
    `   claim: ${f.body}\n` +
    `   recommendation: ${f.recommendation}`
}

function fixPrompt(file, findings) {
  return (
    `You are a FIXER handling CODEX review findings on a single file: ${file}\n\n` +
    `FIRST read ${arcSkillPath} and apply its address-review-comments method: score each finding on two ` +
    `independent dimensions — claim-accuracy (is codex's technical observation actually correct?) and ` +
    `intent-match (does the requested change match what the builder intended, per the handoff?). ` +
    `Act on the matrix: fix ONLY when BOTH > 90% and there is one clear fix; if multiple reasonable fixes ` +
    `exist -> needs-pick; if claim is right but the behavior was intentional -> intent-check; if claim-accuracy ` +
    `< 90% -> unclear. Never fix on a guess.\n\n` +
    `NON-NEGOTIABLE: You MUST read the actual code in ${file} (plus relevant callers/callees) before scoring. ` +
    `Codex's finding is a CLAIM, not truth. The handoff is CONTEXT, not truth. Verify both against the real code.\n\n` +
    `The builder's handoff is at ${handoffPath} — Read it for intent context (context only — verify it).\n\n` +
    `Codex findings for ${file}:\n${findings.map(renderFinding).join('\n')}\n\n` +
    `For each finding: read code -> score both dimensions -> act. When you fix, make the minimal correct edit ` +
    `with Edit and run cheap affected lint/typecheck if obvious. Do NOT commit. Do NOT touch any file other ` +
    `than ${file}. Return structured output: action per finding, both scores, and a one-line detail (for fixes, ` +
    `what changed; for HITL, what the human must decide).`
  )
}

// ---- loop ----------------------------------------------------------------
const hitlKeys = new Set()   // surfaced to human already — suppress on re-appearance
const fixedKeys = new Set()  // auto-fixed — if codex re-flags, the fix was insufficient -> escalate
const allFixed = []
const allHitl = []
const blocked = []   // review-runner failures (error verdict / dropped agent) — never silently treated as clean
let lastVerdict = 'unknown'
let round = 0
let dry = 0

while (round < maxRounds && dry < 1 && !blocked.length) {
  round++
  // Build the "already adjudicated" ledger from everything surfaced to the human so far
  // (needs-pick / intent-check / unclear/rejected) and feed it into codex's focus this round
  // so it doesn't re-raise the same topics. Fixed items are intentionally NOT here — we still
  // want codex to re-check that fixes held (a re-flag of a fix escalates below).
  // Collapse ALL whitespace in every field: suppress lines travel inside the runner's quoted
  // heredoc, so each item must stay a single line (a stray newline could even collide with the
  // heredoc delimiter). Single-line items also keep the numbered list parseable for codex.
  const oneLine = (s, cap) => (s || '').replace(/\s+/g, ' ').trim().slice(0, cap)
  const suppress = allHitl.map(h => ({
    file: oneLine(h.file, 200) || 'UNKNOWN',
    title: oneLine(h.title, 200) || '(untitled)',
    disposition: h.action || 'deferred',
    reason: oneLine(h.detail, 200),
  }))
  log(`Round ${round}: ${lenses.length} codex lens review(s) over the ${scope}` +
    (suppress.length ? ` — suppressing ${suppress.length} already-adjudicated item(s)` : ''))

  const reviews = (await parallel(
    lenses.map((lens, i) => () =>
      agent(reviewPrompt(lens, i, suppress, round), { label: `review:lens${i + 1}`, phase: 'Review', schema: FINDINGS_SCHEMA, model: runnerModel })
    )
  )).filter(Boolean)

  // A broken/missing codex runtime or a crashed runner must NOT look like a clean review.
  // Detect error verdicts and dropped (null/thrown) agents and surface them as blocking —
  // but FINISH the round with the healthy lenses first: their findings are already paid for,
  // and abandoning them mid-round has silently produced fixed:[] next to real findings that
  // only existed in the journal. The while condition halts the loop once blocked is non-empty.
  const dropped = lenses.length - reviews.length
  const errored = reviews.filter(r => r.verdict === 'error')
  const healthy = reviews.filter(r => r.verdict !== 'error')
  if (dropped > 0 || errored.length) {
    for (const e of errored) {
      blocked.push({ round, kind: 'review-error', lens: e.summary || 'unknown',
        detail: `A review lens returned verdict "error": ${e.summary || 'no detail'}. The review did not run — this round's coverage is NOT trustworthy.` })
    }
    if (dropped > 0) {
      blocked.push({ round, kind: 'review-dropped',
        detail: `${dropped} of ${lenses.length} review lens agent(s) returned no result (crashed/timed out). Coverage is incomplete — do not treat as clean.` })
    }
    log(`Round ${round}: ${errored.length} errored + ${dropped} dropped review(s) — BLOCKING; finishing the round with ${healthy.length} healthy lens(es), then halting.`)
  }

  lastVerdict = healthy.some(r => r.verdict === 'needs-attention')
    ? 'needs-attention'
    : (healthy.length && healthy.every(r => r.verdict === 'approve') ? 'approve' : 'unknown')

  // dedup within round, then classify against history
  const roundKeys = new Set()
  const fresh = []
  for (const r of healthy) {
    for (const f of (r.findings || [])) {
      const k = findingKey(f)
      if (roundKeys.has(k)) continue
      roundKeys.add(k)
      if (hitlKeys.has(k)) continue                 // human already owns it
      if (fixedKeys.has(k)) {                        // fix didn't satisfy codex -> escalate, don't re-fix
        allHitl.push({ file: f.file, title: f.title, action: 'unclear', claim_accuracy: 0, intent_match: 0, round,
          detail: `Re-flagged after an auto-fix in an earlier round — the fix did not satisfy codex. Needs your eyes. Codex says: ${f.recommendation || f.body}` })
        hitlKeys.add(k)
        continue
      }
      fresh.push(f)
    }
  }

  if (!fresh.length) {
    dry++
    log(`Round ${round}: no fresh findings (verdict=${lastVerdict}).`)
    continue
  }
  log(`Round ${round}: ${fresh.length} fresh finding(s).`)

  // one fixer per file -> no two agents edit the same file (parallel-safe)
  const byFile = {}
  for (const f of fresh) {
    const key = (f.file || 'UNKNOWN').trim()
    ;(byFile[key] = byFile[key] || []).push(f)
  }
  const groups = Object.keys(byFile).map(file => ({ file, findings: byFile[file] }))

  const fixResults = (await parallel(
    groups.map((g) => () =>
      agent(fixPrompt(g.file, g.findings), { label: `fix:${g.file}`, phase: 'Fix', schema: FIX_SCHEMA, model: fixerModel })
    )
  )).filter(Boolean)

  let fixedThisRound = 0
  for (const r of fixResults) {
    for (const item of (r.results || [])) {
      const rec = { ...item, file: r.file, round }
      if (item.action === 'fixed') {
        allFixed.push(rec)
        fixedThisRound++
        // mark its source finding(s) as fixed so re-appearance escalates
        for (const f of (byFile[r.file] || [])) {
          if ((f.title || '').trim().toLowerCase() === (item.title || '').trim().toLowerCase()) fixedKeys.add(findingKey(f))
        }
      } else {
        allHitl.push(rec)
        for (const f of (byFile[r.file] || [])) {
          if ((f.title || '').trim().toLowerCase() === (item.title || '').trim().toLowerCase()) hitlKeys.add(findingKey(f))
        }
      }
    }
  }

  log(`Round ${round}: ${fixedThisRound} auto-fixed, ${allHitl.length} total HITL so far.`)
  if (!fixedThisRound) {
    // nothing confidently fixable this round — re-reviewing won't change anything
    dry++
    log(`Round ${round}: remaining findings are all HITL. Stopping the auto-loop.`)
  }
}

return {
  rounds: round,
  finalVerdict: blocked.length ? 'blocked' : lastVerdict,
  fixed: allFixed,
  hitl: allHitl,
  blocked,
  note:
    (blocked.length ? `⚠ BLOCKED: ${blocked.length} review-runner failure(s) — coverage is incomplete, do NOT trust this as clean. Investigate before relying on results. ` : '') +
    `${allFixed.length} finding(s) auto-fixed across ${round} round(s); ` +
    `${allHitl.length} need your decision (HITL). Final codex verdict: ${blocked.length ? 'blocked' : lastVerdict}.` +
    (round >= maxRounds ? ` (Hit maxRounds=${maxRounds} cap.)` : ''),
}
