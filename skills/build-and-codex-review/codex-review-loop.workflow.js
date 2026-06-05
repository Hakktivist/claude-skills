export const meta = {
  name: 'codex-review-loop',
  description: 'Run concern-lens codex adversarial reviews against the working tree and route findings to code-reading fixers, looping until reviews come back clean. Confident fixes auto-apply (one fixer per file, parallel-safe); low-confidence / intent-mismatch items are aggregated for the human.',
  phases: [
    { title: 'Review', detail: 'one codex adversarial-review pass per concern lens' },
    { title: 'Fix', detail: 'one fixer per file, applying the address-review-comments matrix after reading the code' },
  ],
}

// ---- args ----------------------------------------------------------------
// args.lenses:      string[]  concern focuses derived from the handoff (<=3)
// args.handoff:     string    the handoff text, inlined (context, NOT ground truth)
// args.scope:       string    codex --scope (default 'working-tree')
// args.base:        string?   optional --base ref
// args.maxRounds:   number    safety cap (default 3)
// args.arcSkillPath:string    absolute path to address-review-comments/SKILL.md
const lenses = (args && args.lenses && args.lenses.length) ? args.lenses.slice(0, 3) : ['overall correctness and design risk']
const handoff = (args && args.handoff) || 'No handoff provided. Review the working tree on its own merits.'
// scope goes straight into the shell command, so constrain it to the companion's
// accepted enum — never trust args. Anything else falls back to working-tree.
const SCOPES = ['auto', 'working-tree', 'branch']
const scopeArg = args && args.scope
const scope = SCOPES.includes(scopeArg) ? scopeArg : 'working-tree'
if (scopeArg && scope !== scopeArg) log(`WARNING: invalid scope "${scopeArg}" — falling back to working-tree.`)
const base = args && args.base
const maxRounds = (args && args.maxRounds) || 3
const arcSkillPath = (args && args.arcSkillPath) || '/Users/alannguyen/.claude/skills/address-review-comments/SKILL.md'
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

function reviewPrompt(lens, i) {
  const focusText =
    `FOCUS: ${lens}. ` +
    `Use the handoff below as CONTEXT only — do NOT trust it as ground truth; verify against the real diff. ` +
    `Handoff:\n${handoff}`
  const focusFile = `/tmp/codex-focus-lens${i + 1}.txt`
  return (
    `You are a codex review RUNNER. Do not review the code yourself and do not fix anything. ` +
    `Your job is to invoke codex and faithfully transcribe its findings.\n\n` +
    `Step 1 — locate the codex companion script:\n` +
    `  find "$HOME/.claude/plugins" -name codex-companion.mjs 2>/dev/null | head -1\n` +
    `If it prints nothing, return verdict "error", summary "codex plugin not installed", findings [].\n\n` +
    `Step 2 — write the focus text to ${focusFile} using the Write tool (NOT the shell, NOT echo — ` +
    `so its contents are never interpreted by a shell). Write EXACTLY this text, verbatim, between the markers ` +
    `(do not include the markers themselves):\n` +
    `<<<<FOCUS\n${focusText}\nFOCUS>>>>\n\n` +
    `Step 3 — run a focused adversarial review (blocks until done; may take several minutes). ` +
    `Pass the focus via command substitution so its contents reach codex as a single literal argument, ` +
    `never re-scanned by the shell. Use this EXACT shape, substituting only the companion path you found:\n` +
    `  node "<companion>" adversarial-review --wait --json --scope ${scope} ${baseFlag}"$(cat ${focusFile})"\n` +
    `Do NOT inline the focus text into the command. Do NOT add other flags.\n\n` +
    `Step 4 — the command prints a JSON payload (because of --json) with verdict, summary, and findings ` +
    `(each with file, line_start/line_end, severity, confidence 0-1, recommendation). ` +
    `Transcribe ALL findings into the schema verbatim from that JSON — do not add, drop, merge, or editorialize. ` +
    `If a finding lacks a line number, use 1. ` +
    `If the command exits non-zero, prints no parseable JSON, or otherwise fails, return verdict "error", ` +
    `summary describing exactly what went wrong (include stderr), and findings [] — do NOT fabricate findings or confidence.`
  )
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
    `Handoff (context only — verify it):\n${handoff}\n\n` +
    `Codex findings for ${file}:\n${JSON.stringify(findings, null, 2)}\n\n` +
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

while (round < maxRounds && dry < 1) {
  round++
  log(`Round ${round}: ${lenses.length} codex lens review(s) over the ${scope}`)

  const reviews = (await parallel(
    lenses.map((lens, i) => () =>
      agent(reviewPrompt(lens, i), { label: `review:lens${i + 1}`, phase: 'Review', schema: FINDINGS_SCHEMA })
    )
  )).filter(Boolean)

  // A broken/missing codex runtime or a crashed runner must NOT look like a clean review.
  // Detect error verdicts and dropped (null/thrown) agents, surface as blocking, and stop —
  // these don't self-heal, so re-reviewing is pointless and silently passing is dangerous.
  const dropped = lenses.length - reviews.length
  const errored = reviews.filter(r => r.verdict === 'error')
  if (dropped > 0 || errored.length) {
    for (const e of errored) {
      blocked.push({ round, kind: 'review-error', lens: e.summary || 'unknown',
        detail: `A review lens returned verdict "error": ${e.summary || 'no detail'}. The review did not run — this round's coverage is NOT trustworthy.` })
    }
    if (dropped > 0) {
      blocked.push({ round, kind: 'review-dropped',
        detail: `${dropped} of ${lenses.length} review lens agent(s) returned no result (crashed/timed out). Coverage is incomplete — do not treat as clean.` })
    }
    log(`Round ${round}: ${errored.length} errored + ${dropped} dropped review(s) — surfacing as BLOCKING, halting the loop.`)
    break
  }

  lastVerdict = reviews.some(r => r.verdict === 'needs-attention')
    ? 'needs-attention'
    : (reviews.length && reviews.every(r => r.verdict === 'approve') ? 'approve' : 'unknown')

  // dedup within round, then classify against history
  const roundKeys = new Set()
  const fresh = []
  for (const r of reviews) {
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
      agent(fixPrompt(g.file, g.findings), { label: `fix:${g.file}`, phase: 'Fix', schema: FIX_SCHEMA })
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
