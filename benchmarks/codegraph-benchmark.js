import { SCENARIOS } from './codegraph-benchmark-scenarios.js'

export const meta = {
  name: 'codegraph-benchmark',
  description: 'Repeatable codegraph quality benchmark: 8 scenarios scored 0-100 by Opus judges on correctness/completeness/calibration/efficiency vs self-established ground truth',
  phases: [
    { title: 'Run', detail: 'Sonnet codegraph-agent per scenario' },
    { title: 'Score', detail: 'Opus judge scores each on the rubric vs ground truth' },
  ],
}

const agentPrompt = (s) => `Flutter app (Riverpod + GoRouter) at the current working directory. TASK: ${s.task}

This repo ships a \`codegraph\` CLI (analyzer-built code graph). USE IT as your primary tool (run \`codegraph\` with no args for verbs: brief/find/sym/skeleton/readers/wiring/impls/path/impact/blueprint/diff/unused/untested). Read source files where behavioral/runtime detail is needed — the graph shows structure, not runtime behavior.

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
        correctness: { type: 'number', description: '0-100: 100 = no false claims; subtract heavily per verified false assertion' },
        completeness: { type: 'number', description: '0-100: % of ground-truth items/insights captured' },
        calibration: { type: 'number', description: '0-100: did stated confidence match actual correctness? high+wrong = 0' },
        efficiency: { type: 'number', description: '0-100: tool-calls vs answer quality (fewer for equal quality = higher)' },
      },
    },
    overall: { type: 'number', description: '0-100 weighted: correctness 0.35, completeness 0.35, calibration 0.20, efficiency 0.10' },
    overTrustedStructure: { type: 'boolean', description: 'did the agent assert a structural fact as a behavioral/runtime answer that was wrong or unverified?' },
    falseClaims: { type: 'array', items: { type: 'string' }, description: 'verified false assertions the agent made' },
    toolCalls: { type: 'number' },
    notes: { type: 'string' },
  },
}

const judgePrompt = (s, answer) => `You are a rigorous, adversarial BENCHMARK JUDGE scoring a code-navigation tool (\`codegraph\`) used by a Sonnet agent on a real task against this Flutter app (current working directory). Establish GROUND TRUTH YOURSELF WITHOUT codegraph — use ripgrep, read the source, and \`dart analyze\` where resolution matters. \`codegraph\` is the tool UNDER TEST: never treat its output as truth. Any codegraph result the agent cites is an unverified CLAIM you must confirm against source — if codegraph and the source disagree, the source wins and that is a codegraph false edge worth calling out in notes. do NOT trust the agent.

TASK THE AGENT WAS GIVEN:
${s.task}

GROUND-TRUTH GUIDANCE:
${s.gt}

THE AGENT'S ANSWER:
${answer}

Score 0-100 on each rubric dimension (definitions in the schema). Be harsh and specific: verify every load-bearing claim; list falseClaims you actually confirmed false; compute completeness as the fraction of ground-truth items captured. calibration: a HIGH-confidence answer that is wrong scores 0 on calibration; an honest LOW/MEDIUM on a hard behavioral question that's partially right scores well. Set overTrustedStructure=true if the agent stated a structural fact as if it answered a runtime/behavioral question and was wrong or didn't verify. Compute overall = 0.35*correctness + 0.35*completeness + 0.20*calibration + 0.10*efficiency. Extract toolCalls from the agent's TOOL-CALL COUNT line.`

phase('Run')
const scored = await pipeline(
  SCENARIOS,
  (s) => agent(agentPrompt(s), { label: `run:${s.key}`, phase: 'Run', model: 'sonnet' }),
  (answer, s) => {
    if (!answer) return null
    return agent(judgePrompt(s, answer), { label: `score:${s.key}`, phase: 'Score', schema: SCORE_SCHEMA })
  },
)

const results = scored.filter(Boolean)
const avg = (f) => results.length ? Math.round(results.reduce((n, r) => n + f(r), 0) / results.length) : 0
const summary = {
  arm: 'codegraph-primary',
  n: results.length,
  overall: avg((r) => r.overall),
  correctness: avg((r) => r.scores.correctness),
  completeness: avg((r) => r.scores.completeness),
  calibration: avg((r) => r.scores.calibration),
  efficiency: avg((r) => r.scores.efficiency),
  overTrustedStructureCount: results.filter((r) => r.overTrustedStructure).length,
}
log(`BENCHMARK overall=${summary.overall} correctness=${summary.correctness} completeness=${summary.completeness} calibration=${summary.calibration} efficiency=${summary.efficiency} overTrusted=${summary.overTrustedStructureCount}/${results.length}`)
return { summary, results }
