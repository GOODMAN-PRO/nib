export const meta = {
  name: 'nib-design-pass-2',
  description: 'Second design pass on the integrated Nib build: multi-lens review of real screenshots + known leftovers, owner-normalized Codex fixes, full build, re-capture and verify (up to 2 rounds), then CI, merge to main and the unsigned IPA',
  phases: [
    { title: 'Review', detail: 'three Claude design lenses on the latest captures + known issues' },
    { title: 'Fix', detail: 'one Codex fixer per owner, full local build' },
    { title: 'Verify', detail: 're-capture touched screens, re-review, loop' },
    { title: 'Ship', detail: 'CI on integration, merge to main, main CI, IPA' },
  ],
}

// args: { paths: {root, worktrees, logs}, tools, codexTool, codexPrompts, shots, known: [string], rounds? }
const A = (typeof args === 'string') ? JSON.parse(args) : (args || {})
const ROOT = A.paths.root
const DIR = `${A.paths.worktrees}/integration`
const LOGS = A.paths.logs
const TOOLS = A.tools
const CODEX_TOOL = A.codexTool
const CODEX_PROMPTS = A.codexPrompts
const BR = 'integration'
const REPO = 'GOODMAN-PRO/nib'
const M = 'opus'
const ROUNDS = A.rounds || 2
const T1 = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
const T2 = 'Claude-Session: https://claude.ai/code/session_01GpZ3Q12FGHi43JsYU8aD5F'
const TRAILER = `every commit message ends with a blank line then exactly these two adjacent lines (one trailer paragraph):\n  ${T1}\n  ${T2}`
const OWNERS = `Owner = the feature id (exactly "Fxxx") whose "files"/"tests" in docs/forge-spec.json contain the view code to change, or exactly "shared" for NibDesign/NibContracts/Nib/App/docs. Use ONLY those two forms.`
const BUILD_RULE = `Build ONLY through \`${TOOLS} full ${DIR}\` (waits for a build slot; 30-90 min; log ${LOGS}/local-integration-full.log, exit code in the .exit file): use a long timeout or background + poll.`
const SIM = `Use the iPad Pro 13-inch simulator (xcrun simctl list devices available) on the newest iOS 26 runtime, plus an iPhone 17 Pro simulator for compact layouts. Build the app for the simulator from ${DIR} (xcodegen generate; xcodebuild build -project Nib.xcodeproj -scheme Nib -configuration Debug -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath ${ROOT}-dd-sim; ad-hoc sign for Keychain access if needed), install and launch it, and drive it through the MCP bridge (tools/smoke/run.mjs or curl to F090's endpoint) to reach states.`

const REVIEW = {
  type: 'object',
  properties: { issues: { type: 'array', items: { type: 'object', properties: { severity: { type: 'string', enum: ['blocker', 'major', 'minor'] }, screen: { type: 'string' }, owner: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' } }, required: ['severity', 'owner', 'problem', 'fix'] } } },
  required: ['issues'],
}
const RESULT = {
  type: 'object',
  properties: { status: { type: 'string', enum: ['ok', 'green', 'red', 'blocked'] }, runUrl: { type: 'string' }, sha: { type: 'string' }, details: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } },
  required: ['status'],
}

let halted = false
let nulls = 0
const run = async (prompt, opts) => {
  if (halted) return null
  const r = await agent(prompt, opts)
  if (r === null || r === undefined) { if (++nulls >= 3) { halted = true; log('3 agents returned nothing - halting') } } else nulls = 0
  return r
}
const cx = async (name, prompt, effort, opts) => {
  if (halted) return null
  const pfile = `${CODEX_PROMPTS}/d2-${name}.md`
  const wrapper = `You are a thin forwarder that hands ONE job to Codex CLI and returns its result. Do NOT read the repository, investigate, or do the job yourself.
1. Write everything under "TASK:" below, verbatim and complete, to ${pfile} with ONE Bash call using a quoted heredoc (cat > ${pfile} <<'NIB_TASK_EOF' ... NIB_TASK_EOF).
2. Run: ${CODEX_TOOL} run d2-${name} ${DIR} ${pfile} result ${effort}   (Bash timeout 600000)
3. While its output starts with "RUNNING", run: ${CODEX_TOOL} wait d2-${name}   (Bash timeout 600000). Keep repeating; hours is normal.
4. When the output starts with "RESULT ", return that JSON's fields exactly as your structured output.
5. If it starts with "CODEX_FAILED", return status "blocked", empty fields, and notes "CODEX_UNAVAILABLE: <the reason it printed>".

TASK:
You are running as Codex CLI (non-interactive, full access) on the user's Mac, doing one step of the Nib design pass. Long commands need long timeouts or background + poll. Work autonomously to completion, then answer with the JSON object the output schema asks for.

${prompt}`
  const r = await agent(wrapper, { ...opts, label: `cx-${opts.label}`, effort: 'low' })
  if (!r || /CODEX_UNAVAILABLE/.test(r.notes || '')) { log(`${opts.label}: Codex unavailable - running on Claude`); return run(prompt, opts) }
  return r
}
const normOwner = (o) => { const m = /F\d{3}/.exec(o || ''); return m ? m[0] : 'shared' }

const LENSES = [
  'MATERIAL + LIQUID GLASS: DESIGN.md §2, §7, §10 and the glass lines of §16; rims, refraction, glass bodies behind every floating control (bars, capsules, the library chrome), merged/split glass, bud-offs; iOS 26 glass vs fallbacks.',
  'LAYOUT + TYPOGRAPHY + COLOUR: DESIGN.md §3-§6 and §14 per-screen specs: spacing grid, metrics, radii, type scale, truncation, colour tokens in light AND dark (including placeholder/empty states), alignment, iPad vs iPhone.',
  'SLOP + ACCESSIBILITY: every line of the DESIGN.md §16 Slop checklist and §12 (44 pt targets, Dynamic Type, contrast, labels, Reduce Motion/Transparency); duplicated or stray UI, anything templated or generic.',
]

let shots = A.shots
let lastIssues = []
const history = []
for (let round = 1; round <= ROUNDS && !halted; round++) {
  phase('Review')
  const known = round === 1 ? (A.known || []) : []
  const reviews = (await parallel(LENSES.map((lens, i) => () => run(`Design review (pass 2, round ${round}) of the real Nib app. Read docs/DESIGN.md fully, then look at EVERY screenshot in ${shots} (index.md / manifest.json explain each; use the Read tool on the PNGs). Lens: ${lens}
${known.length ? 'Already-known leftovers to confirm and include if still visible (keep their wording precise):\n' + known.map((k) => '- ' + k).join('\n') + '\n' : ''}For each real problem you can SEE, name the screen/file, the DESIGN.md rule, the owner (${OWNERS} - find the view code in ${DIR}) and the concrete code fix. Severity: blocker, major, minor. No speculation. Do not change code.`, { label: `review-${round}-${i + 1}`, phase: 'Review', model: M, schema: REVIEW })))).filter(Boolean)
  const issues = reviews.flatMap((r) => r.issues || []).filter((i) => i.severity !== 'minor')
  lastIssues = issues
  history.push({ round, issues: issues.length, blockers: issues.filter((i) => i.severity === 'blocker').length })
  log(`round ${round}: ${issues.length} blocker/major issue(s)`)
  const extra = round === 1 && A.testFix ? [{ owner: 'shared', text: A.testFix }] : []
  if (!issues.length && !extra.length) break

  phase('Fix')
  const groups = {}
  for (const i of issues) { const o = normOwner(i.owner); (groups[o] = groups[o] || []).push(`[${i.severity}] ${i.screen || ''}: ${i.problem} -> ${i.fix}`) }
  for (const e of extra) (groups[e.owner] = groups[e.owner] || []).push(e.text)
  await parallel(Object.keys(groups).map((o) => () => cx(`fix-${round}-${o}`, `Design fixes, pass 2 round ${round}. Worktree ${DIR} (branch ${BR}) contains ALL Nib features merged. Other agents are fixing OTHER owners' files at the same time: edit ONLY files owned by ${o === 'shared' ? 'no feature (NibDesign, NibContracts, Nib/App, docs; keep changes backward compatible)' : o + ' (docs/forge-spec.json)'}; do NOT run git commit/stash/checkout/reset or any build.
Findings:\n${groups[o].join('\n')}
Fix each at the root, using only NibDesign tokens/components/liquid modifiers, per docs/DESIGN.md. Update or add tests for changed behaviour; never skip or weaken tests. Return status "ok" and details = what you changed per finding.`, 'high', { label: `fix-${round}-${o}`, phase: 'Fix', model: M, schema: RESULT })))
  await run(`In ${DIR}: if git status shows changes, git add -A && git commit -m "Design pass 2, round ${round}" (${TRAILER}). Do not push. Return status "ok".`, { label: `commit-${round}`, phase: 'Fix', model: M, effort: 'low', schema: RESULT })
  const b = await cx(`build-${round}`, `${BUILD_RULE} Run it on ${DIR}. If it fails, fix the regressions at the root (never skip, weaken or delete tests) and repeat until "LOCAL BUILD OK", committing on ${BR} (${TRAILER}). Return status "green" or "red".`, 'high', { label: `build-${round}`, phase: 'Fix', model: M, schema: RESULT })
  if (!b || b.status !== 'green') return { stage: 'build', round, history, build: b }

  phase('Verify')
  const next = `${ROOT}-design/pass2-r${round}`
  const cap = await cx(`capture-${round}`, `Re-capture the screens the design fixes touched, plus the library (grid, list, folder) and one document canvas, for verification. ${SIM}
Save PNGs (xcrun simctl io <udid> screenshot) to ${next}/<n>-<screen>-<light|dark>-<orientation>.png in light AND dark, iPad portrait AND landscape, plus the iPhone 17 Pro for the library and canvas. Write ${next}/index.md listing each file, screen, state and how you reached it. The findings that were fixed:\n${Object.keys(groups).map((o) => o + ': ' + groups[o].length + ' finding(s)').join(', ')}\nReturn status "ok", details = the file list.`, 'medium', { label: `capture-${round}`, phase: 'Verify', model: M, schema: RESULT })
  if (!cap || cap.status === 'blocked') break
  shots = next
}

phase('Ship')
const ship = await cx('ship', `Ship the design pass.
1. In ${DIR}: git push origin ${BR}; run and watch the full CI on ${BR} (gh workflow run ios.yml --repo ${REPO} --ref ${BR}; find the workflow_dispatch run for HEAD; gh run watch <id> --repo ${REPO} --exit-status --interval 60). If red, fix root causes on ${BR} (${BUILD_RULE}) and repeat (max 4 rounds).
2. When green: in the main clone ${ROOT}: git fetch origin && git checkout -q main && git pull -q --ff-only origin main && git merge --no-ff origin/${BR} -m "Design pass 2" (${TRAILER}) && python3 Scripts/lint.py && git push origin main.
3. Watch main's CI for that SHA (test + ipa) to green (fix on main if red, max 3 rounds). Download the IPA: gh run download <id> --repo ${REPO} -n Nib-unsigned-ipa -D ${ROOT}-dist/<short-sha>/.
4. Tag: git tag nib-1.0-rc2 <sha> && git push origin nib-1.0-rc2.
5. Device: xcrun devicectl list devices; if an iPad/iPhone is connected and trusted and a signing identity exists, build/install with automatic signing and launch; otherwise report the IPA path.
Return status "green", sha, runUrl, details = IPA path(s) and the device result.`, 'high', { label: 'ship', phase: 'Ship', model: M, schema: RESULT })

return { history, remaining: lastIssues.length, shots, ship }
