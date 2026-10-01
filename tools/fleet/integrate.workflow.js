export const meta = {
  name: 'nib-integrate',
  description: 'Integrate all 111 Nib feat/* branches in dependency order, full local + CI build with a fix loop, cross-feature follow-up checks, F111 smoke scripts on the simulator, design review of real screens, ship main + unsigned IPA',
  phases: [
    { title: 'Merge', detail: 'merge feat/* into the integration branch in dependency order' },
    { title: 'Green', detail: 'local full build + full CI (test + ipa) with parallel per-owner fixers' },
    { title: 'Followups', detail: 'verify and close cross-feature integration follow-ups' },
    { title: 'Smoke', detail: 'F111 bridge smoke scripts on the iPad simulator' },
    { title: 'Design', detail: 'screenshot real screens, multi-lens review vs DESIGN.md + Slop checklist, fix' },
    { title: 'Ship', detail: 'merge to main, main CI green, download the unsigned IPA, device install' },
  ],
}

// args: { paths: {root, worktrees, logs}, tools (nib-build.sh), codexTool, codexPrompts, features: [{id, name, priority, dependsOn}],
//         followups: [string], maxRounds? }
// Heavy work (merging, fixing, triage, smoke runs, screen capture, shipping) runs in Codex CLI through a thin Claude forwarder;
// the design-review lenses stay on Claude. Codex unavailable -> the same prompt runs on Claude.
const A = (typeof args === 'string') ? JSON.parse(args) : (args || {})
const P = A.paths
const ROOT = P.root
const WT = P.worktrees
const LOGS = P.logs
const TOOLS = A.tools
const CODEX_TOOL = A.codexTool
const CODEX_PROMPTS = A.codexPrompts
const DIR = `${WT}/integration`
const BR = 'integration'
const REPO = 'GOODMAN-PRO/nib'
const M = 'opus'
const T1 = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
const T2 = 'Claude-Session: https://claude.ai/code/session_01GpZ3Q12FGHi43JsYU8aD5F'
const TRAILER = `every commit message ends with a blank line then exactly these two adjacent lines (one trailer paragraph):\n  ${T1}\n  ${T2}`
const MAX_ROUNDS = A.maxRounds || 8
const FEATURES = A.features || []
const byId = {}
FEATURES.forEach((f) => { byId[f.id] = f })

const order = []
const seen = new Set()
const visit = (id) => { if (seen.has(id) || !byId[id]) return; seen.add(id); for (const d of byId[id].dependsOn || []) visit(d); order.push(id) }
FEATURES.slice().sort((a, b) => (a.priority || 9) - (b.priority || 9) || a.id.localeCompare(b.id)).forEach((f) => visit(f.id))

const BUILD_RULE = `Build ONLY through the helper \`${TOOLS} <mode> ${DIR}\` (modes: full = lint + xcodegen + every package test + app build; app; archive; targets "<T1 T2>"). It waits for one of 2 machine-wide build slots (8 GB M1 shared with other jobs), writes the log to ${LOGS}/local-integration-<mode>.log and the exit code to the matching .exit file. A full build can take 30-90 min: run it with a long timeout or in the background and poll the .exit file; never run raw xcodebuild for the package.`
const OWNERS = `Map each failing file to its owner with docs/forge-spec.json (the feature whose "files"/"tests" list contains the path); anything not owned by a feature (NibContracts, NibDesign, NibTesting, ConformanceTests, Nib/App, project.yml, Scripts, docs) is owner "shared".`

const FAILURES = {
  type: 'object',
  properties: {
    green: { type: 'boolean' },
    groups: { type: 'array', items: { type: 'object', properties: { owner: { type: 'string' }, files: { type: 'array', items: { type: 'string' } }, errors: { type: 'array', items: { type: 'string' } } }, required: ['owner', 'files', 'errors'] } },
    notes: { type: 'string' },
  },
  required: ['green', 'groups'],
}
const RESULT = {
  type: 'object',
  properties: { status: { type: 'string', enum: ['ok', 'green', 'red', 'blocked'] }, runUrl: { type: 'string' }, sha: { type: 'string' }, details: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } },
  required: ['status'],
}
const REVIEW = {
  type: 'object',
  properties: { issues: { type: 'array', items: { type: 'object', properties: { severity: { type: 'string', enum: ['blocker', 'major', 'minor'] }, screen: { type: 'string' }, owner: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' } }, required: ['severity', 'owner', 'problem', 'fix'] } } },
  required: ['issues'],
}

let nulls = 0
let halted = false
const run = async (prompt, opts) => {
  if (halted) return null
  const r = await agent(prompt, opts)
  if (r === null || r === undefined) { if (++nulls >= 3) { halted = true; log('3 agents returned nothing (usage limit?) - halting') } } else nulls = 0
  return r
}
const CODEX_NOTE = `You are running as Codex CLI (non-interactive, full access) on the user's Mac, doing one step of the Nib integration. Long commands (the build helper, gh run watch, simulator work) can take a long time: use long timeouts or background + poll. Ignore any mention of "Bash timeout" (Claude Code's tool). Work autonomously to completion, then answer with the JSON object the output schema asks for.`
// cx: run a step in Codex (schemaKey: result | failures), falling back to Claude with the same prompt.
const cx = async (name, prompt, schemaKey, effort, opts) => {
  if (halted) return null
  const pfile = `${CODEX_PROMPTS}/integ-${name}.md`
  const wrapper = `You are a thin forwarder that hands ONE job to Codex CLI and returns its result. Do NOT read the repository, investigate, or do the job yourself.
1. Write everything under "TASK:" below, verbatim and complete, to ${pfile} with ONE Bash call using a quoted heredoc (cat > ${pfile} <<'NIB_TASK_EOF' ... NIB_TASK_EOF).
2. Run: ${CODEX_TOOL} run integ-${name} ${DIR} ${pfile} ${schemaKey} ${effort}   (Bash timeout 600000)
3. While its output starts with "RUNNING", run: ${CODEX_TOOL} wait integ-${name}   (Bash timeout 600000). Keep repeating; hours is normal.
4. When the output starts with "RESULT ", return that JSON's fields exactly as your structured output.
5. If it starts with "CODEX_FAILED", return ${schemaKey === 'failures' ? 'green false, groups []' : 'status "blocked", empty fields'} and notes "CODEX_UNAVAILABLE: <the reason it printed>".

TASK:
${CODEX_NOTE}

${prompt}`
  const r = await agent(wrapper, { ...opts, label: `cx-${opts.label}`, effort: 'low' })
  if (!r || /CODEX_UNAVAILABLE/.test(r.notes || '')) {
    log(`${opts.label}: Codex unavailable - running on Claude`)
    return run(prompt, opts)
  }
  return r
}

// ---------------------------------------------------------------------------
phase('Merge')
const merged = await cx('merge', `Integrate every Nib feature branch into one branch.
1. git -C ${ROOT} fetch origin --prune. The integration worktree is ${DIR}: create it if missing (git -C ${ROOT} worktree add ${DIR} -B ${BR} origin/main); if it exists, check out ${BR}, merge origin/main, and skip branches already merged (git merge-base --is-ancestor origin/feat/<id> HEAD).
2. Merge, in EXACTLY this dependency order, each origin/feat/<id> that exists: ${order.join(' ')}
   For each: git -C ${DIR} merge --no-ff --no-edit origin/feat/<id> -m "Integrate <id>: <feature name from docs/forge-spec.json>" (${TRAILER}).
   Files are exclusively owned (docs/forge-spec.json "files"/"tests"), so conflicts should be rare. On a conflict: a file owned by <id> -> take the incoming side; a file owned by another feature -> keep ours (already integrated); shared files (NibContracts, NibDesign, docs, scaffold, Nib/App) -> take origin/main's content unless the incoming change is a deliberate contract/spec change main lacks, then merge both by hand. Record every conflict and its resolution.
3. python3 Scripts/lint.py in ${DIR}; fix lint errors the merge caused (report feature-caused ones).
4. git -C ${DIR} push -u origin ${BR} (retry 4x).
Return status "ok", details = merged ids + every conflict and resolution.`, 'result', 'medium', { label: 'merge', phase: 'Merge', model: M, schema: RESULT })
if (!merged || merged.status !== 'ok') return { stage: 'merge', merged }

// ---------------------------------------------------------------------------
phase('Green')
const fixGroups = async (groups, round, source) => {
  const results = await parallel(groups.map((g, i) => () => cx(`fix-${round}-${i}`, `Integration fix, round ${round} (${source}). Worktree ${DIR} (branch ${BR}) contains ALL Nib features merged. Other agents are fixing OTHER files in this same worktree at the same time: edit ONLY these files and files owned by ${g.owner === 'shared' ? 'no feature (shared scaffold/contracts/design/app files; keep changes minimal and backward compatible)' : g.owner + ' (docs/forge-spec.json)'}; do NOT run git commit/stash/checkout/reset or any build.
Failing files: ${g.files.join(', ') || '(see errors)'}
Errors / findings:\n${g.errors.slice(0, 40).join('\n')}
Read the code and the contracts (docs/CONTRACTS.md, NibKit/Sources/NibContracts) and fix the ROOT cause (cross-feature integration problems: duplicate symbols, command id / registry / settings key collisions, missing imports, wrong assumptions about another feature's API - adapt to the other feature's real, spec-conforming API). Never disable/skip tests, comment code out or stub behaviour away. Return status "ok" and details = what you changed.`, 'result', 'high', { label: `fix-${g.owner}-${round}.${i}`, phase: 'Green', model: M, schema: RESULT })))
  await run(`In ${DIR}: if git status shows changes, git add -A && git commit -m "Integration fixes, round ${round} (${source})" (${TRAILER}). Do not push. Return status "ok".`, { label: `commit-${round}`, phase: 'Green', model: M, effort: 'low', schema: RESULT })
  return results
}

let ciGreen = false
let ciRun = null
let localGreen = false
for (let round = 1; round <= MAX_ROUNDS && !ciGreen && !halted; round++) {
  if (!localGreen) {
    const f = await cx(`local-${round}`, `Run the full local build of the integration branch and triage it. ${BUILD_RULE} Run \`${TOOLS} full ${DIR}\`. If it prints "LOCAL BUILD OK" answer green=true, groups []. Otherwise read ${LOGS}/local-integration-full.log fully enough to collect EVERY distinct compile error, lint error and failing test (list all you can see; xcodebuild stops a target at its first failing files), grouped by owner. ${OWNERS} Do not change code.`, 'failures', 'medium', { label: `local-${round}`, phase: 'Green', model: M, schema: FAILURES })
    if (!f) break
    if (f.green) localGreen = true
    else { log(`round ${round}: local build red - ${f.groups.length} owner group(s)`); await fixGroups(f.groups, round, 'local build'); continue }
  }
  const ci = await cx(`ci-${round}`, `Push the integration branch and run the full CI on it. In ${DIR}: git push -u origin ${BR} (retry 4x). Start CI: gh workflow run ios.yml --repo ${REPO} --ref ${BR}; find the workflow_dispatch run for HEAD's SHA (gh run list --repo ${REPO} --branch ${BR} --json databaseId,headSha,status,conclusion,url --limit 10; poll every 30 s). Wait: gh run watch <id> --repo ${REPO} --exit-status --interval 60 (repeat until complete; 30 min queues are normal). Both jobs (test, ipa) must succeed -> green=true. Otherwise gh run view <id> --repo ${REPO} --log-failed > ${LOGS}/integration-ci-${round}.log and collect every distinct error / failing test grouped by owner. ${OWNERS} Put the run URL in notes. Do not change code.`, 'failures', 'medium', { label: `ci-${round}`, phase: 'Green', model: M, schema: FAILURES })
  if (!ci) break
  ciRun = ci.notes
  if (ci.green) { ciGreen = true; break }
  log(`round ${round}: CI red - ${ci.groups.length} owner group(s)`)
  await fixGroups(ci.groups, round, 'CI')
  localGreen = false
}
if (!ciGreen) return { stage: 'green', merged, ciGreen, ciRun, halted }

// ---------------------------------------------------------------------------
phase('Followups')
const FOLLOW = (A.followups || []).filter(Boolean)
let followups = null
if (FOLLOW.length) {
  const check = await run(`Cross-feature follow-ups recorded while the features were built separately. For EACH item, inspect the integrated code in ${DIR} (read-only) and decide whether it is satisfied now that every feature is merged. Items:\n${FOLLOW.map((x, i) => `${i + 1}. ${x}`).join('\n')}\nReturn green=true only if all are satisfied; otherwise one group per unsatisfied item: owner = the feature that must change (${OWNERS}), files = the files to edit, errors = [the concrete gap and the concrete fix]. Do not change code.`, { label: 'followups-check', phase: 'Followups', model: M, schema: FAILURES })
  followups = check
  if (check && !check.green && check.groups.length) {
    await fixGroups(check.groups, 'fu', 'follow-ups')
    const b = await cx('fu-build', `${BUILD_RULE} Run \`${TOOLS} full ${DIR}\` after the follow-up fixes; if it fails, fix the regressions (root causes, no skipping) and repeat until "LOCAL BUILD OK", committing on ${BR} (${TRAILER}). Return status green/red.`, 'result', 'high', { label: 'followups-build', phase: 'Followups', model: M, schema: RESULT })
    if (!b || b.status !== 'green') return { stage: 'followups', followups, build: b }
  }
}

// ---------------------------------------------------------------------------
phase('Smoke')
const SIM = `Boot an iPad simulator (xcrun simctl list devices available; prefer an iPad Pro 13-inch on the newest iOS 26 runtime; create one with xcrun simctl create if none exists). Build the app for the simulator from ${DIR}: wait until ~/Projects/Nib-locks has at most one slot held, then xcodegen generate && xcodebuild build -project Nib.xcodeproj -scheme Nib -configuration Debug -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath ${ROOT}-dd-sim CODE_SIGNING_ALLOWED=NO. Install (xcrun simctl install) and launch (xcrun simctl launch) it.`
const smoke = []
for (let round = 1; round <= 4 && !halted; round++) {
  const s = await cx(`smoke-${round}`, `F111 smoke tests, round ${round}. ${SIM} Enable the MCP/HTTP bridge the way F090/F091 define (read their code and tools/smoke/README.md: launch argument, a default you can write with xcrun simctl spawn <udid> defaults write, or the Bridge settings screen), get its port and token, and run every tools/smoke/*.json script with node tools/smoke/run.mjs (see its README for flags). Device-only checks (real Pencil latency, palm rejection, AirPlay) cannot run on a simulator: list them as "needs device" in notes, not as failures. Also confirm the IntegrationTests scenarios passed in ${LOGS}/local-integration-full.log. Return green=true when every simulator-runnable script passes; otherwise group failures by owner (${OWNERS}) with the script step, expected vs actual and the relevant log lines. Do not change code.`, 'failures', 'high', { label: `smoke-${round}`, phase: 'Smoke', model: M, schema: FAILURES })
  if (!s) break
  smoke.push(s)
  if (s.green) break
  await fixGroups(s.groups, `smoke${round}`, 'smoke scripts')
  const b = await cx(`smoke-build-${round}`, `${BUILD_RULE} Run \`${TOOLS} full ${DIR}\` after the smoke fixes; fix regressions until "LOCAL BUILD OK", committing on ${BR} (${TRAILER}). Return status green/red.`, 'result', 'high', { label: `smoke-build-${round}`, phase: 'Smoke', model: M, schema: RESULT })
  if (!b || b.status !== 'green') break
}

// ---------------------------------------------------------------------------
phase('Design')
const SHOTS = `${ROOT}-design`
const CAPTURE = (dir, which) => `Capture the real app for a design review. ${SIM}
Drive the app to ${which} and save PNG screenshots (xcrun simctl io <udid> screenshot) to ${dir}/<n>-<screen>-<light|dark>-<orientation>.png, in light AND dark appearance (xcrun simctl ui <udid> appearance dark|light) and iPad landscape AND portrait, plus the core screens on an iPhone 17 Pro simulator. Use the bridge (tools/smoke/run.mjs or curl to F090's endpoint; nib_run / nib_context) to reach states quickly: open a document, select tools, open panels, dock the palette at each edge, open menus and sheets, the assistant, settings, the library with folders, search, study sets, text documents, a whiteboard, presentation mode. Write ${dir}/index.md listing each file, the screen, the state and how you reached it. Return status "ok", details = the file list.`
const capture = await cx('design-capture', CAPTURE(SHOTS, 'every key screen: library (grid, list, folder; mid-drag reorder if reachable), new-notebook sheet, document canvas with the tool palette docked left/top/bottom/right and the tool options bar, lasso selection + object menu, page sidebar, outline, search, settings, AI assistant panel, plugin manager, export sheet, study session, text document, whiteboard, presentation mode, onboarding'), 'result', 'high', { label: 'design-capture', phase: 'Design', model: M, schema: RESULT })
const LENSES = [
  'MATERIAL + LIQUID GLASS: DESIGN.md §2 (droplet material), §7, §10 (droplet physics, dock, meniscus) and the glass lines of §16; rims, refraction, double rims, merged/split glass, bud-offs; iOS 26 glass vs pre-26 fallbacks.',
  'LAYOUT + TYPOGRAPHY + COLOUR: DESIGN.md §3-§6 and §14 (per-screen specs): spacing grid, fixed metrics, radii, type scale, colour tokens in light and dark, alignment, density, iPad vs iPhone layouts, canvas-first calm.',
  'SLOP + ACCESSIBILITY: every line of the DESIGN.md §16 Slop checklist and §12 accessibility (44 pt targets, Dynamic Type, contrast, VoiceOver-visible labels, Reduce Motion/Transparency fallbacks); anything that looks templated or generic.',
]
let design = []
if (capture && capture.status !== 'blocked') {
  const reviews = (await parallel(LENSES.map((lens, i) => () => run(`Design review of the real Nib app. Read docs/DESIGN.md fully, then look at EVERY screenshot in ${SHOTS} (index.md explains each; use the Read tool on the PNGs). Lens: ${lens}
For each real problem you can SEE, name the screen/file, the DESIGN.md rule it breaks, the owning feature (${OWNERS} - find the view code in ${DIR} that draws it) and the concrete code fix. Severity: blocker (broken/unusable), major (clearly violates the spec or the Slop checklist), minor. No speculation about things not visible. Do not change code.`, { label: `design-review-${i + 1}`, phase: 'Design', model: M, schema: REVIEW })))).filter(Boolean)
  design = reviews.flatMap((r) => r.issues || []).filter((i) => i.severity !== 'minor')
  if (design.length) {
    const groups = {}
    for (const i of design) (groups[i.owner] = groups[i.owner] || []).push(i)
    await fixGroups(Object.keys(groups).map((o) => ({ owner: o, files: [], errors: groups[o].map((i) => `[${i.severity}] ${i.screen || ''}: ${i.problem} -> ${i.fix}`) })), 'design', 'design review')
    const b = await cx('design-build', `${BUILD_RULE} Run \`${TOOLS} full ${DIR}\` after the design fixes; fix regressions until "LOCAL BUILD OK", committing on ${BR} (${TRAILER}). Then ${CAPTURE(SHOTS + '/after', 'the screens the design fixes touched (see ' + SHOTS + '/index.md)')}`, 'result', 'high', { label: 'design-build', phase: 'Design', model: M, schema: RESULT })
    if (!b || b.status === 'red' || b.status === 'blocked') return { stage: 'design', ciGreen, smoke, design, rebuild: b }
  }
}

// ---------------------------------------------------------------------------
phase('Ship')
const ship = await cx('ship', `Ship the integrated build.
1. In ${DIR}: git push origin ${BR}; run and watch the full CI on ${BR} (gh workflow run ios.yml --repo ${REPO} --ref ${BR}; gh run watch <id> --repo ${REPO} --exit-status). If red, fix root causes on ${BR} (${BUILD_RULE}) and repeat (max 4 rounds).
2. When ${BR} is green: in the main clone ${ROOT}: git fetch origin && git checkout -q main && git pull -q --ff-only origin main && git merge --no-ff origin/${BR} -m "Integrate all 111 features" (${TRAILER}) && python3 Scripts/lint.py && git push origin main.
3. Watch main's CI run for that SHA (test + ipa) to green (fix on main if red, max 3 rounds). Download the IPA: gh run download <id> --repo ${REPO} -n Nib-unsigned-ipa -D ${ROOT}-dist/<short-sha>/.
4. Tag it: git tag nib-1.0-integration <sha> && git push origin nib-1.0-integration.
5. Device: xcrun devicectl list devices. If an iPad/iPhone is connected and trusted and a signing identity exists (security find-identity -v -p codesigning shows "Apple Development"), build and install with automatic signing (xcodebuild -allowProvisioningUpdates ... DEVELOPMENT_TEAM=<team>) and launch it; otherwise report that the IPA is at ${ROOT}-dist/<short-sha>/ for sideloading.
Return status "green" with sha = main SHA, runUrl, details = IPA path(s) and the device result.`, 'result', 'high', { label: 'ship', phase: 'Ship', model: M, schema: RESULT })

return { order: order.length, merged: merged.details && merged.details.length, ciRun, followups: followups && { green: followups.green, gaps: followups.groups.length }, smoke: smoke.map((s) => ({ green: s.green, notes: s.notes, groups: s.groups.length })), designIssues: design.length, ship }
