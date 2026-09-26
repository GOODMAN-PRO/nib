export const meta = {
  name: 'nib-fleet-v2',
  description: 'Install the locked design system, then build all Nib features in parallel on feat/* branches: implement -> CI green -> independent review -> fix -> CI green',
  phases: [
    { title: 'Build', detail: 'state-driven fan-out: implement -> CI -> review -> fix -> CI, skipping stages already done' },
  ],
}

// args: { features: [...forge-spec features...] }  (passed verbatim from docs/forge-spec.json)
const A = (typeof args === 'string') ? JSON.parse(args) : (args || {})
const FEATURES = (A.features || []).slice().sort((a, b) => (a.priority || 9) - (b.priority || 9))
if (!FEATURES.length) throw new Error('args.features is empty')

// Paths + host come from args so the same script runs on Windows (CI-only) or a Mac (local Xcode builds).
const P = A.paths || {}
const SEP = P.sep || '\\'
const ROOT = P.root || 'G:\\Projects\\Nib'
const WT = P.worktrees || 'G:\\Projects\\Nib-wt'
const LOGS = P.logs || 'G:\\Projects\\Nib-ci-logs'
const LOCAL = !!A.localBuild // true on a Mac with Xcode 26.6: agents compile + test locally before pushing
const REPO = 'GOODMAN-PRO/nib'
const M = 'opus'
const COAUTHOR = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
const byId = {}
FEATURES.forEach((f) => { byId[f.id] = f })

// Circuit breaker: when the usage limit hits, agents return null in bursts. Stop launching new work
// so finished features stay cached and the run can be resumed after the limit resets.
let nulls = 0
let halted = false
const run = async (prompt, opts) => {
  if (halted) return null
  const r = await agent(prompt, opts)
  if (r === null || r === undefined) { nulls++; if (nulls >= 3) { if (!halted) log("3 agents returned nothing (usage limit?) - halting new work; resume this run later"); halted = true } }
  else nulls = 0
  return r
}

const CI_RESULT = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['green', 'red', 'blocked'] },
    rounds: { type: 'number' },
    runUrl: { type: 'string' },
    remainingErrors: { type: 'array', items: { type: 'string' } },
    contractGaps: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
  required: ['status', 'rounds', 'remainingErrors'],
}
const IMPL_RESULT = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['done', 'partial', 'failed'] },
    files: { type: 'array', items: { type: 'string' } },
    commands: { type: 'array', items: { type: 'string' } },
    contractGaps: { type: 'array', items: { type: 'string' } },
    notDone: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
  required: ['status', 'files', 'notDone'],
}
const REVIEW = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['pass', 'needs-fix'] },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          where: { type: 'string' },
          problem: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['severity', 'problem', 'fix'],
      },
    },
  },
  required: ['verdict', 'issues'],
}

const isUI = (f) => f.layer === 'ui' || f.layer === 'fullstack'
const owned = (f) => `exactly the paths in the "files" and "tests" arrays of feature ${f.id} in docs/forge-spec.json`
const depClosure = (f, acc = new Set()) => {
  for (const d of f.dependsOn || []) if (byId[d] && !acc.has(d)) { acc.add(d); depClosure(byId[d], acc) }
  return acc
}

const ciLoop = (dir, branch, scopeRule, maxRounds) => `You own getting branch "${branch}" of ${REPO} green on GitHub Actions. Working copy: ${dir}.
Loop (max ${maxRounds} rounds):
1. ${LOCAL ? 'First run the same build + tests locally (commands from the feat/** job in .github/workflows/ios.yml, -derivedDataPath inside the worktree and excluded from git) and fix failures before pushing — CI stays the gate. ' : ''}Commit everything (git add -A; commit if changes; message ends with the line "${COAUTHOR}") and push: git push -u origin ${branch}. Note the SHA.
2. Find the run for that SHA: gh run list --repo ${REPO} --branch ${branch} --json databaseId,headSha,status,conclusion,url --limit 10 — poll every ~30s until it appears (runs queue: only 5 macOS jobs run at once across ~14 agents, so waits of 10-30 min are normal).
3. Wait: gh run watch <id> --repo ${REPO} --exit-status --interval 45 (Bash timeout 600000; if it times out call it again — never give up while queued/in progress).
4. All jobs succeeded → return "green".
5. Failure → gh run view <id> --repo ${REPO} --log-failed > ${LOGS}${SEP}${branch.replace(/\//g, '_')}-<round>.log (mkdir; never inside the repo); grep for "error:", "** BUILD FAILED", "** TEST FAILED", "failed (", "fatal", "::error". Fix root causes. ${scopeRule} Back to 1.
Never disable/skip tests, never comment code out, never "#if false", never stub a feature away to get green. Return status, rounds, last run URL, remaining errors, and contract gaps you hit.`

// ---------------------------------------------------------------------------
// State-driven build: args.state (from collect-state.js: git + GitHub Actions + marker files) says
// what is already done, so a fresh run skips finished stages instead of trusting the replay cache.
const STATE = A.state || {}
const STATE_DIR = P.state || 'G:\\Projects\\Nib-state'
phase('Build')
const green = {}
const resolveGreen = {}
FEATURES.forEach((f) => { green[f.id] = new Promise((r) => { resolveGreen[f.id] = r }) })

const implementPrompt = (f, depInfo) => {
  const dir = `${WT}${SEP}${f.id}`
  return `You are building ONE feature of "Nib" (native iPadOS/iOS, GoodNotes 6 parity + JS plugins + bring-your-own-AI + "water droplet" liquid UI). ~110 agents build other features in parallel; ${LOCAL ? 'you are on a Mac with Xcode 26.6: before committing, compile and run your module tests LOCALLY with the same commands as the feat/** job in .github/workflows/ios.yml (put -derivedDataPath inside your worktree, e.g. .dd, and add it to .git/info/exclude) and fix what fails; still be meticulous about' : 'you cannot compile locally (Windows) — CI will compile later, so be meticulous about'} Swift/Apple API correctness (Swift 5 mode, Xcode 26.6 / iOS 26 SDK, deployment iOS 17, #available for newer APIs, public access across modules).

WORKTREE: ${dir} (branch feat/${f.id}, based on main which has the green contracts + design system). Work ONLY there.
An earlier attempt may have been interrupted by a usage limit: if the worktree already has uncommitted work for this feature, CONTINUE from it (read it, keep what is good, complete and fix the rest) instead of starting over.
${(f.dependsOn || []).length ? `DEPENDENCIES: first run \`git -C ${dir} merge --no-edit ${(f.dependsOn || []).filter((d) => byId[d]).map((d) => 'feat/' + d).join(' ')}\` to bring in the dependency features' code (${depInfo}). Their files are theirs — read and use them, never edit them.` : 'No feature dependencies: rely only on the contracts.'}

FEATURE ${f.id} — ${f.name}  (module ${f.module}, layer ${f.layer}, complexity ${f.complexity})
SPEC / ACCEPTANCE CRITERIA: read your entry for ${f.id} in docs/forge-spec.json — its "description" is your full spec and acceptance criteria; follow it to the letter.
GOODNOTES PARITY ITEMS (look each up in docs/FEATURES.md and match the behaviour): ${(f.inventory || []).join(', ') || '(none)'}
FILES YOU OWN (the ONLY files you may create/edit): ${owned(f)}

Read before coding: docs/ARCHITECTURE.md (module rules, command conventions, registries, UI extension points, UI rules), docs/CONTRACTS.md ("How to use this file" + the contract types you use; the real source is in NibKit/Sources/NibContracts), the existing stub in your module${isUI(f) ? ', docs/DESIGN.md (binding look + droplet physics + per-screen specs + Slop checklist) and NibKit/Sources/NibDesign (use ONLY its tokens, components and liquid modifiers — never hard-code colors/fonts/radii/springs)' : ''}${/Plugin|AI|Bridge|Relay/i.test(f.module + f.name) ? ', docs/PLUGIN_API.md and docs/AI.md' : ''}.

Build it COMPLETELY — every acceptance criterion, every parity item — as production code:
- Every user-facing action is a registered Command with a JSON schema (the "plugins and AI can modify anything" guarantee); reads go through the query API; undo/redo works.
- No TODOs, no fatalError/placeholder bodies, no fake data paths shipped as real behaviour.${isUI(f) ? '\n- UI: premium, calm, canvas-first, exactly per DESIGN.md; droplet/liquid behaviour where DESIGN.md prescribes it and nowhere near live ink; VoiceOver labels, Dynamic Type, 44pt targets, Reduce Motion/Transparency, iPad pointer + keyboard shortcuts; iPad and iPhone size classes.' : ''}
- Tests: real XCTest cases in your owned test files for the non-trivial logic (a handful of meaningful tests, using NibTesting fakes/fixtures); they must pass.
- If the contracts lack something, work around it INSIDE your files and list it under contractGaps — never edit shared files.
Finally: git -C ${dir} add -A && git -C ${dir} commit -m "${f.id}: ${f.name.replace(/"/g, "'")}" -m "${COAUTHOR}". Do NOT push. Return status, files written, command ids registered, contract gaps, and anything from the spec you could not do (notDone).`
}

const reviewPrompt = (f) => {
  const dir = `${WT}${SEP}${f.id}`
  const deps = [...depClosure(f)]
  return `Independent code review (you did not write this) of feature ${f.id} "${f.name}" in ${dir} (branch feat/${f.id}; CI is green).
Spec: the "description" of ${f.id} in docs/forge-spec.json (its full acceptance criteria).
Parity items (docs/FEATURES.md): ${(f.inventory || []).join(', ') || '(none)'}
Check, strictly:
1. Every acceptance criterion and parity item is actually implemented (not stubbed, not faked, no TODO/fatalError placeholders).
2. Ownership: \`git -C ${dir} diff --name-only main...HEAD\` must only contain the files/tests (docs/forge-spec.json) of ${f.id}${deps.length ? ' and of its dependency features ' + deps.join(', ') : ''}. Any other file is a blocker.
3. Contracts: conforms to NibContracts (commands registered with schemas + undo; queries; events; registries) — the "plugins and AI can modify anything" guarantee holds for everything this feature lets a user do.
4. Correctness: logic bugs, data-loss risks, threading (@MainActor), memory/perf on large notebooks, error handling at trust boundaries (files, network, plugins, AI).${isUI(f) ? '\n5. Design: follows docs/DESIGN.md + the Slop checklist, composes only NibDesign tokens/components/liquid modifiers, no hard-coded styling, accessibility (VoiceOver, Dynamic Type, 44pt, Reduce Motion), iPad + iPhone layouts.' : ''}
6. Tests are meaningful and cover the risky logic.
Before returning, write your full verdict as JSON {"verdict": ..., "issues": [...]} to ${STATE_DIR}${SEP}${f.id}.review.json (create the folder if needed) — that file is how later runs know this review is done.
Return verdict "pass" only if there are no blockers or majors. Concrete fixes only.`
}

const fixPrompt = (f, issues) => `Apply the code-review fixes to feature ${f.id} "${f.name}" in ${WT}${SEP}${f.id} (branch feat/${f.id}). ${issues ? 'ISSUES:\n' + JSON.stringify(issues, null, 1) : `The review is in ${STATE_DIR}${SEP}${f.id}.review.json — read its "issues".`}
An earlier fix attempt may have been interrupted: check git status/stash and the current code before re-applying anything. Fix every blocker and major; minors when cheap. Only edit files ${f.id} owns: ${owned(f)} (if the review flags files outside that list, revert those changes: git checkout main -- <file>).

Then: ${ciLoop(`${WT}${SEP}${f.id}`, `feat/${f.id}`, `Only edit files ${f.id} owns.`, 6)}
Finally write {"status": "<green|red|blocked>", "runUrl": "..."} to ${STATE_DIR}${SEP}${f.id}.fixed.json.`

// Cap concurrent implementers so CI/review/fix agents always get slots.
const MAX_IMPL = A.maxImpl || 5
let implActive = 0
const implQueue = []
const acquireImpl = () => { if (implActive < MAX_IMPL) { implActive++; return Promise.resolve() } return new Promise((r) => implQueue.push(r)) }
const releaseImpl = () => { const next = implQueue.shift(); if (next) next(); else implActive-- }

const buildOne = async (f) => {
  const st = STATE[f.id] || {}
  const deps = (f.dependsOn || []).filter((d) => byId[d])
  const depResults = await Promise.all(deps.map((d) => green[d]))
  const depInfo = depResults.map((r) => `${r.id}: ${r.status}`).join(', ')
  let impl = st.impl ? { status: 'done', files: [], notDone: [], fromState: true } : null
  let ci = st.ci === 'green' ? { status: 'green', rounds: 0, remainingErrors: [], fromState: true } : null
  try {
    if (!impl) {
      await acquireImpl()
      try { impl = await run(implementPrompt(f, depInfo), { label: `impl:${f.id}`, phase: 'Build', model: M, schema: IMPL_RESULT }) } finally { releaseImpl() }
    }
    if (impl && !ci) {
      ci = await run(ciLoop(`${WT}${SEP}${f.id}`, `feat/${f.id}`,
        `Only edit files feature ${f.id} owns: ${owned(f)}. If an error is in a dependency's file or a shared contract, work around it inside your own files where possible and report it under contractGaps.`, 8),
        { label: `ci:${f.id}`, phase: 'Build', model: M, schema: CI_RESULT })
    }
  } finally {
    resolveGreen[f.id]({ id: f.id, status: (ci && ci.status) || (impl ? 'unbuilt' : 'failed') })
  }
  if (halted && !ci) return { id: f.id, impl, ci, review: null, final: 'halted' }
  if (!ci || ci.status !== 'green') return { id: f.id, impl, ci, review: null, final: ci && ci.status }

  if (st.fixed) return { id: f.id, impl, ci, review: { verdict: st.review || 'needs-fix', issues: [] }, final: st.fixed }
  let review = st.review ? { verdict: st.review, issues: null, fromState: true } : null
  if (!review) review = await run(reviewPrompt(f), { label: `review:${f.id}`, phase: 'Build', model: M, schema: REVIEW })
  if (!review) return { id: f.id, impl, ci, review: null, final: halted ? 'halted' : 'unreviewed' }
  let finalCi = ci
  const serious = (review.issues || []).filter((i) => i.severity !== 'minor')
  if (review.verdict === 'needs-fix' || serious.length) {
    finalCi = await run(fixPrompt(f, review.issues), { label: `fix:${f.id}`, phase: 'Build', model: M, schema: CI_RESULT })
    if (!finalCi) return { id: f.id, impl, ci, review, final: halted ? 'halted' : 'unfixed' }
  }
  return { id: f.id, impl, ci, review, final: finalCi && finalCi.status }
}

const results = (await parallel(FEATURES.map((f) => () => buildOne(f)))).map((r, i) => r || { id: FEATURES[i].id, final: 'crashed' })

const summary = {
  total: FEATURES.length,
  halted,
  green: results.filter((r) => r.final === 'green').map((r) => r.id),
  notGreen: results.filter((r) => r.final !== 'green').map((r) => ({ id: r.id, final: r.final, errors: (r.ci && r.ci.remainingErrors || []).slice(0, 5) })),
  notDone: results.filter((r) => r.impl && (r.impl.notDone || []).length).map((r) => ({ id: r.id, notDone: r.impl.notDone })),
  contractGaps: results.flatMap((r) => [...((r.impl && r.impl.contractGaps) || []), ...((r.ci && r.ci.contractGaps) || [])].map((g) => `${r.id}: ${g}`)),
  reviewedNeedsFix: results.filter((r) => r.review && r.review.verdict === 'needs-fix').map((r) => r.id),
}
log(`Fleet: ${summary.green.length}/${summary.total} green${halted ? ' (halted at usage limit — re-collect state and relaunch)' : ''}`)
return summary
