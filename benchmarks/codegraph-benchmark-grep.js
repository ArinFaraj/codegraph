import { ALL_SCENARIOS } from './codegraph-benchmark-scenarios.js'

export const meta = {
  name: 'codegraph-benchmark-grep',
  description:
    'Grep-only control arm: same tasks as codegraph-benchmark, but the agent may NOT use codegraph.',
  phases: [
    { title: 'Run', detail: 'Sonnet grep-agent per scenario' },
    { title: 'Score', detail: 'Opus judge (may use codegraph to verify)' },
  ],
}

const SCENARIOS = ALL_SCENARIOS

const agentPrompt = (s) => `Flutter app (Riverpod + GoRouter) at the current working directory. TASK: ${s.task}

IMPORTANT: You do NOT have access to \`codegraph\`. Use ONLY ripgrep (\`rg\`), grep, find, and reading source files.

End with exactly:
TOOL-CALL COUNT: <n>
CONFIDENCE: high|medium|low — <one sentence on your biggest uncertainty>`

const SCORE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['scenario', 'kind', 'scores', 'overall', 'overTrustedStructure', 'falseClaims', 'toolCalls', 'notes'],
  properties: {
    scenario: { type: 'string' },
    kind: { type: 'string' },
    scores: {
      type: 'object', additionalProperties: false,
      required: ['correctness', 'completeness', 'calibration', 'efficiency'],
      properties: {
        correctness: { type: 'number' },
        completeness: { type: 'number' },
        calibration: { type: 'number' },
        efficiency: { type: 'number' },
      },
    },
    overall: { type: 'number' },
    overTrustedStructure: { type: 'boolean' },
    falseClaims: { type: 'array', items: { type: 'string' } },
    toolCalls: { type: 'number' },
    notes: { type: 'string' },
  },
}

const judgePrompt = (s, answer) => `BENCHMARK JUDGE — GREP-ONLY control arm. Establish ground truth with codegraph + rg + reads. Agent did NOT have codegraph.

TASK: ${s.task}
GUIDANCE: ${s.gt}
ANSWER: ${answer}

Score harshly. overall = 0.35*correctness + 0.35*completeness + 0.20*calibration + 0.10*efficiency.`

phase('Run')
const scored = await pipeline(
  SCENARIOS,
  (s) => agent(agentPrompt(s), { label: `grep-run:${s.key}`, phase: 'Run', model: 'sonnet' }),
  (answer, s) => {
    if (!answer) return null
    return agent(judgePrompt(s, answer), { label: `grep-score:${s.key}`, phase: 'Score', schema: SCORE_SCHEMA })
  },
)

const results = scored.filter(Boolean)
const avg = (f) => (results.length ? Math.round(results.reduce((n, r) => n + f(r), 0) / results.length) : 0)
const summary = {
  arm: 'grep-only',
  n: results.length,
  overall: avg((r) => r.overall),
  correctness: avg((r) => r.scores.correctness),
  completeness: avg((r) => r.scores.completeness),
  calibration: avg((r) => r.scores.calibration),
  efficiency: avg((r) => r.scores.efficiency),
  overTrustedStructureCount: results.filter((r) => r.overTrustedStructure).length,
}
log(`GREP BENCHMARK overall=${summary.overall} correctness=${summary.correctness} completeness=${summary.completeness} calibration=${summary.calibration} efficiency=${summary.efficiency} overTrusted=${summary.overTrustedStructureCount}/${results.length}`)
return { summary, results }
