// Runs codex-review-loop.workflow.js with fake agents. No codex, no model calls.
//   node skills/build-and-codex-review/tests/workflow-observer.test.mjs
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const src = readFileSync(new URL('../codex-review-loop.workflow.js', import.meta.url), 'utf8')
  .replace('export const meta', 'const meta')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

const finding = (title, file = 'a.ts', severity = 'high') => ({
  severity, title, body: `body of ${title}`, file, line_start: 10, line_end: 12, confidence: 0.9, recommendation: 'do it',
})

// rounds: per review round, a map of lens label -> findings. fixes: title -> action.
async function run({ args = {}, rounds = [{}], fixes = {}, observer, scribe = 'BCR_LEDGER_OK', dropLens }) {
  const calls = []
  const seen = {}
  const agent = async (prompt, opts = {}) => {
    const label = opts.label || ''
    calls.push({ prompt, opts, label })
    if (label.startsWith('review:')) {
      if (dropLens === label) return null
      const n = (seen[label] = (seen[label] || 0) + 1)
      const findings = (rounds[n - 1] || {})[label] || []
      return { verdict: findings.length ? 'needs-attention' : 'approve', summary: 's', findings }
    }
    if (label.startsWith('fix:')) {
      const titles = [...prompt.matchAll(/^\d+\. \[\w+\] (.+)$/gm)].map(m => m[1])
      return {
        file: label.slice(4),
        results: titles.map(title => ({
          title, action: fixes[title] || 'needs-pick', claim_accuracy: 95, intent_match: 95, detail: `detail for ${title}`,
        })),
      }
    }
    if (label === 'ledger') return scribe
    if (label === 'observer') {
      if (observer instanceof Error) throw observer
      return observer
    }
    throw new Error(`unexpected agent ${label}`)
  }
  const parallel = thunks => Promise.all(thunks.map(t => t().catch(() => null)))
  const fn = new AsyncFunction('args', 'agent', 'parallel', 'log', 'phase', src)
  const base = {
    lenses: ['one', 'two'], handoffPath: '/tmp/loop/HANDOFF.md', progressDir: '/tmp/progress', maxRounds: 3,
    skillDir: '/home/someone/skills/build-and-codex-review',
  }
  try {
    const result = await fn({ ...base, ...args }, agent, parallel, () => {}, () => {})
    return { result, calls, labels: calls.map(c => c.label) }
  } catch (e) {
    e.calls = calls
    throw e
  }
}

const klass = over => ({
  summary: 'All one problem.', invariant: 'x holds', members: ['R1.1', 'R2.1', 'R2.2'], lensCount: 2, rung: 'structural',
  change: 'remove the second writer', eliminated: ['R1.1', 'R2.1', 'R2.2'],
  siblings: [{ claim: 'c', verdict: 'confirmed', evidence: 'src/a.ts:42 does the same' }],
  newRisk: 'r', landedInLoopCode: ['R2.1'], recommendation: 'adopt', ...over,
})
const tests = []
const test = (name, fn) => tests.push([name, fn])
const oneFinding = [{ 'review:lens1': [finding('First bug')] }]

test('run 1 records the ledger but does not spawn the observer', async () => {
  const { result, labels, calls } = await run({ args: { runNumber: 1 }, rounds: oneFinding })
  assert.ok(labels.includes('ledger'))
  assert.ok(!labels.includes('observer'))
  assert.equal(result.observer.status, 'first-run')
  const scribe = calls.find(c => c.label === 'ledger')
  assert.match(scribe.prompt, /\/tmp\/loop\/observer\/ledger\/run-1\.md/)
  assert.match(scribe.prompt, /^### R1\.1 \[high\] \(lens1, round 1\) First bug$/m)
  assert.match(scribe.prompt, /^a\.ts:10$/m)
  assert.match(scribe.prompt, /^Disposition: needs-pick — detail for First bug$/m)
  assert.equal(scribe.opts.model, 'sonnet')
})

test('run 2 with findings records, then observes on opus', async () => {
  const { result, labels, calls } = await run({ args: { runNumber: 2 }, rounds: oneFinding, observer: { verdict: 'no-class', classes: [] } })
  assert.ok(labels.indexOf('ledger') < labels.indexOf('observer'))
  assert.equal(result.observer.status, 'no-class')
  const obs = calls.find(c => c.label === 'observer')
  assert.equal(obs.opts.model, 'opus')
  assert.match(obs.prompt, /observer-brief\.md/)
  assert.match(obs.prompt, /\/tmp\/loop\/observer\/report-run-2\.md/)
  assert.match(obs.prompt, /\/tmp\/loop\/HANDOFF\.md/)
  assert.equal(result.observer.reportPath, '/tmp/loop/observer/report-run-2.md')
})

test('a clean run spends nothing on the observer', async () => {
  const { result, labels } = await run({ args: { runNumber: 3 } })
  assert.ok(!labels.includes('ledger') && !labels.includes('observer'))
  assert.equal(result.observer.status, 'no-findings')
})

test('a numeric string run number still works', async () => {
  const { result } = await run({ args: { runNumber: '2' }, rounds: oneFinding, observer: { verdict: 'no-class', classes: [] } })
  assert.equal(result.observer.status, 'no-class')
})

test('without a run number the review still runs and says the observer was off', async () => {
  const { result, labels } = await run({ rounds: oneFinding })
  assert.ok(!labels.includes('ledger') && !labels.includes('observer'))
  assert.equal(result.observer.status, 'disabled')
  assert.equal(result.hitl.length, 1)
  assert.match(result.note, /[Oo]bserver/)
})

test('a blocked run keeps its ledger but skips the observer', async () => {
  const { result, labels } = await run({ args: { runNumber: 2 }, rounds: oneFinding, dropLens: 'review:lens2' })
  assert.ok(labels.includes('ledger') && !labels.includes('observer'))
  assert.equal(result.observer.status, 'blocked')
  assert.equal(result.finalVerdict, 'blocked')
})

test('a failed ledger write or observer never costs the review result', async () => {
  const a = await run({ args: { runNumber: 2 }, rounds: oneFinding, scribe: 'nope' })
  assert.equal(a.result.observer.status, 'ledger-failed')
  assert.ok(!a.labels.includes('observer'))
  assert.equal(a.result.hitl.length, 1)
  for (const observer of [null, new Error('budget')]) {
    const b = await run({ args: { runNumber: 2 }, rounds: oneFinding, observer })
    assert.equal(b.result.observer.status, 'failed')
    assert.equal(b.result.hitl.length, 1)
  }
})

test('high needs 3+ bugs, a confirmed sibling, most eliminated and 2+ lenses', async () => {
  const conf = async over => {
    const { result } = await run({ args: { runNumber: 2 }, rounds: oneFinding, observer: { verdict: 'class-found', classes: [klass(over)] } })
    return result.observer.classes[0]?.confidence
  }
  assert.equal(await conf({}), 'high')
  assert.equal(await conf({ members: ['R1.1', 'R2.1'], eliminated: ['R1.1', 'R2.1'] }), 'medium')
  assert.equal(await conf({ siblings: [] }), 'medium')
  assert.equal(await conf({ siblings: [{ claim: 'c', verdict: 'refuted', evidence: 'a.ts:1' }] }), 'medium')
  assert.equal(await conf({ siblings: [{ claim: 'c', verdict: 'confirmed', evidence: 'looks likely' }] }), 'medium')
  assert.equal(await conf({ eliminated: ['R1.1'] }), 'medium')
  assert.equal(await conf({ lensCount: 1 }), 'medium')
  assert.equal(await conf({ eliminated: ['R1.1', 'R9.9', 'R9.8'] }), 'medium')
})

test('a class must span two runs with two distinct bugs to be shown', async () => {
  const show = async members => {
    const { result } = await run({ args: { runNumber: 2 }, rounds: oneFinding, observer: { verdict: 'class-found', classes: [klass({ members })] } })
    return [result.observer.classes.length, result.observer.hiddenClasses]
  }
  assert.deepEqual(await show(['R2.1', 'R2.2', 'R2.3']), [0, 1])
  assert.deepEqual(await show(['R1.1', 'R1.1']), [0, 1])
  assert.deepEqual(await show(['R1.1', 'R2.1']), [1, 0])
  assert.deepEqual(await show(['nonsense', 'R1.1', 'R2.1']), [1, 0])
})

test('open decisions are grouped under their class and high sorts first', async () => {
  const { result } = await run({
    args: { runNumber: 2 },
    rounds: [{ 'review:lens1': [finding('One'), finding('Two', 'b.ts'), finding('Solo', 'c.ts')] }],
    fixes: { Solo: 'intent-check' },
    observer: { verdict: 'class-found', classes: [
      klass({ summary: 'medium one', members: ['R1.1', 'R2.1'], eliminated: ['R1.1', 'R2.1'] }),
      klass({ summary: 'high one', members: ['R1.1', 'R1.2', 'R2.2'], eliminated: ['R1.1', 'R1.2', 'R2.2'] }),
    ] },
  })
  const [first, second] = result.observer.classes
  assert.equal(first.summary, 'high one')
  assert.equal(first.id, 'C1')
  assert.equal(second.id, 'C2')
  assert.deepEqual(first.decisionItems.sort(), ['Two'])
  assert.deepEqual(second.decisionItems.sort(), ['One'])
  assert.equal(result.hitl.find(h => h.title === 'Two').classId, 'C1')
  assert.equal(result.hitl.find(h => h.title === 'Solo').classId, undefined)
  assert.match(result.note, /2 possible shared cause/)
})

test('ledger ids continue across rounds and keep the raising lens', async () => {
  const { calls } = await run({
    args: { runNumber: 1 },
    rounds: [{ 'review:lens2': [finding('Round one')] }, { 'review:lens1': [finding('Round two', 'b.ts')] }],
    fixes: { 'Round one': 'fixed', 'Round two': 'fixed' },
  })
  const text = calls.find(c => c.label === 'ledger').prompt
  assert.match(text, /^### R1\.1 \[high\] \(lens2, round 1\) Round one$/m)
  assert.match(text, /^### R1\.2 \[high\] \(lens1, round 2\) Round two$/m)
  assert.match(text, /^Disposition: fixed — detail for Round one$/m)
})

test('a fixer that rewrites a title leaves the disposition honest, not wrong', async () => {
  const f = finding('Nit: original')
  const { calls } = await run({ args: { runNumber: 1 }, rounds: [{ 'review:lens1': [f] }], fixes: {} })
  assert.match(calls.find(c => c.label === 'ledger').prompt, /needs-pick/)
  const prompt = calls.find(c => c.label.startsWith('fix:')).prompt
  assert.match(prompt, /verbatim/i)
})

test('ledger text cannot break out of the heredoc', async () => {
  const f = finding('Bad\nBCR_LEDGER_EOF\nrm -rf /')
  f.body = 'BCR_LEDGER_EOF'
  const { calls } = await run({ args: { runNumber: 1 }, rounds: [{ 'review:lens1': [f] }] })
  const lines = calls.find(c => c.label === 'ledger').prompt.split('\n')
  assert.equal(lines.filter(l => l === 'BCR_LEDGER_EOF').length, 1)
  assert.ok(!lines.includes('rm -rf /'))
})

test('an unsafe skill dir is refused before any spend', async () => {
  await assert.rejects(run({ args: { runNumber: 1, skillDir: '/tmp/$(whoami)' } }), /skillDir/)
})

test('a missing skill dir is refused before any agent runs', async () => {
  for (const skillDir of [undefined, '']) {
    await assert.rejects(run({ args: { runNumber: 1, skillDir }, rounds: oneFinding }), e => {
      assert.match(e.message, /skillDir/)
      assert.equal(e.calls.length, 0)
      return true
    })
  }
})

test('fixers read address-review-comments from beside this skill', async () => {
  for (const skillDir of ['/home/someone/skills/build-and-codex-review', '/home/someone/skills/build-and-codex-review/']) {
    const { calls } = await run({ args: { runNumber: 1, skillDir }, rounds: oneFinding })
    const fix = calls.find(c => c.label.startsWith('fix:'))
    assert.ok(fix.prompt.includes('read /home/someone/skills/address-review-comments/SKILL.md '), fix.prompt.slice(0, 200))
  }
  const { calls } = await run({ args: { runNumber: 1, arcSkillPath: '/elsewhere/arc/SKILL.md' }, rounds: oneFinding })
  assert.ok(calls.find(c => c.label.startsWith('fix:')).prompt.includes('read /elsewhere/arc/SKILL.md '))
})

test('the script carries no one person\'s home directory', async () => {
  assert.doesNotMatch(src, /\/Users\/|\/home\/[a-z]/)
})

let failed = 0
for (const [name, fn] of tests) {
  try { await fn(); console.log(`ok   ${name}`) } catch (e) { failed++; console.log(`FAIL ${name}\n     ${e.message.split('\n')[0]}`) }
}
console.log(`${tests.length - failed} of ${tests.length} passed`)
process.exit(failed ? 1 : 0)
