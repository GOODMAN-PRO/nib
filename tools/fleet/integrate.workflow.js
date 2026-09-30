export const meta = {
  name: 'nib-integrate',
  description: 'Integrate all 111 Nib feat/* branches into main in dependency order, full CI with a fix loop, F111 smoke scripts on the simulator, unsigned IPA, and a design review of real screens',
  phases: [
    { title: 'Merge', detail: 'merge feat/* into the integration branch in dependency order' },
    { title: 'Green', detail: 'local full build + full CI (test + ipa) with parallel per-feature fixers' },
    { title: 'Smoke', detail: 'F111 bridge smoke scripts on the iPad simulator' },
    { title: 'Design', detail: 'screenshot real screens, multi-lens review vs DESIGN.md + Slop checklist, fix' },
    { title: 'Ship', detail: 'fast-forward main, main CI green, download the unsigned IPA, device install' },
  ],
}

// args: { paths: {root, worktrees, logs, state, sep}, tools, features: [{id, name, dependsOn}], maxRounds? }
const A = (typeof args === 'string') ? JSON.parse(args) : (args || {})
const P = A.paths
const ROOT = P.root
const WT = P.worktrees
const LOGS = P.logs
const TOOLS = A.tools
const DIR = `${WT}/integration`
const BR = 'integration'
const REPO = 'GOODMAN-PRO/nib'
const M = 'opus'
const T1 = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
const T2 = 'Claude-Session: https://claude.ai/code/session_01GpZ3Q12FGHi43JsYU8aD5F'
const TRAILER = `every commit message ends with a blank line then exactly these two adjacent lines:\n  ${T1}\n  ${T2}`
const MAX_ROUNDS = A.maxRounds || 8
const FEATURES = A.features || []
const byId = {}
FEATURES.forEach((f) => { byId[f.id] = f })

// Dependency order (stable: priority, then id).
const order = []
const seen = new Set()
const visit = (id) => { if (seen.has(id) || !byId[id]) return; seen.add(id); for (const d of byId[id].dependsOn || []) visit(d); order.push(id) }
FEATURES.slice().sort((a, b) => (a.priority || 9) - (b.priority || 9) || a.id.localeCompare(b.id)).forEach((f) => visit(f.id))

const BUILD_RULE = `Build ONLY through the helper \`${TOOLS} <mode> ${DIR}\` (modes: full = lint + every package test + app build; app; archive; targets "<T1 T2>"). It waits for a machine-wide slot, writes the log to ${LOGS}/local-integration-<mode>.log and the exit code to the matching .exit file. Use Bash timeout 600000; if the call times out the build keeps running: wait with \`until [ -f ${LOGS}/local-integration-<mode>.exit ]; do sleep 30; done\` (timeout 600000, repeat), then read the log.`

const FAILURES = {
  type: 'object',
  properties: {
    green: { type: 'boolean' },
    groups: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          owner: { type: 'string', description: 'feature id (Fxxx) that owns the failing files, or "shared" for scaffold/contracts/design/app-shell files' },
          files: { type: 'array', items: { type: 'string' } },
          errors: { type: 'array', items: { type: 'string' } },
        },
        required: ['owner', 'files', 'errors'],
      },
    },
    notes: { type: 'string' },
  },
  required: ['green', 'groups'],
}
const RESULT = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['ok', 'green', 'red', 'blocked'] },
    runUrl: { type: 'string' },
    sha: { type: 'string' },
    details: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
  required: ['status'],
}
const REVIEW = {
  type: 'object',
  properties: {
    issues: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          screen: { type: 'string' },
          owner: { type: 'string', description: 'feature id owning the code to change, or "shared"' },
          problem: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['severity', 'owner', 'problem', 'fix'],
      },
    },
  },
  required: ['issues'],
}

// ---------------------------------------------------------------------------
phase('Merge')
const merged = await agent(`Integrate every Nib feature branch into one branch.
1. git -C ${ROOT} fetch origin --prune. Create the worktree if missing: git -C ${ROOT} worktree add ${DIR} -B ${BR} origin/main (if it exists: git -C ${DIR} checkout ${BR} && git -C ${DIR} merge --no-edit origin/main, and skip branches already merged — git merge-base --is-ancestor origin/feat/<id> HEAD).
2. Merge, in EXACTLY this dependency order, each origin/feat/<id> that exists: ${order.join(' ')}
   For each: git -C ${DIR} merge --no-ff --no-edit origin/feat/<id> -m "Integrate <id>: <feature name from docs/forge-spec.json>" (${TRAILER}).
   Files are exclusively owned (docs/forge-spec.json "files"/"tests"), so conflicts should be rare. On a conflict: a file owned by <id> → take the incoming side; a file owned by another feature → keep ours (already integrated); shared files (NibContracts, NibDesign, docs, scaffold, Nib/App) → take origin/main's content (git checkout origin/main -- <file>) unless the incoming change is a deliberate contract/spec change that main lacks, in which case merge both by hand. Record every conflict and how you resolved it.
3. python3 Scripts/lint.py in ${DIR}; fix lint errors caused by the merge (not by features — report those).
4. git -C ${DIR} push -u origin ${BR} (retry 4x).
Return status "ok", the list of merged ids and every conflict (details).`, { label: 'merge', phase: 'Merge', model: M, schema: RESULT })
if (!merged || merged.status !== 'ok') return { stage: 'merge', merged }

// ---------------------------------------------------------------------------
phase('Green')
const ownersHint = `Map each failing file to its owner with docs/forge-spec.json (the feature whose "files"/"tests" list contains the path); anything not owned by a feature (NibContracts, NibDesign, NibTesting, ConformanceTests, Nib/App, project.yml, Scripts, docs) is owner "shared".`

const fixGroups = async (groups, round, source) => {
  // Parallel fixers on disjoint files in the same worktree; nobody builds or commits here.
  const results = await parallel(groups.map((g, i) => () => agent(`Integration fix, round ${round} (${source}). Worktree ${DIR} (branch ${BR}) contains ALL Nib features merged. Other agents are fixing OTHER files in this same worktree right now: edit ONLY these files and files owned by ${g.owner === 'shared' ? 'no feature (shared scaffold/contracts/design/app files — keep changes minimal and backward compatible)' : g.owner + ' (docs/forge-spec.json)'}; do not run git commit, stash, checkout or any build.
Failing files: ${g.files.join(', ')}
Errors:\n${g.errors.slice(0, 40).join('\n')}
Read the code and the surrounding contracts (docs/CONTRACTS.md, NibKit/Sources/NibContracts) and fix the ROOT cause (cross-feature integration problems: duplicate symbols, command id or registry collisions, conflicting settings keys, missing imports, broken assumptions about another feature's API — adapt to the other feature's real, spec-conforming API). Never disable/skip tests, comment code out or stub behaviour away. Return what you changed.`, { label: `fix:${g.owner}:${round}.${i}`, phase: 'Green', model: M, schema: RESULT })))
  await agent(`In ${DIR}: git add -A && git commit -m "Integration fixes, round ${round} (${source})" (${TRAILER}) if there are changes. Do not push yet. Return status "ok".`, { label: `commit:${round}`, phase: 'Green', model: M, effort: 'low', schema: RESULT })
  return results
}

let localGreen = false
let ciGreen = false
let ciRun = null
for (let round = 1; round <= MAX_ROUNDS && !ciGreen; round++) {
  if (!localGreen) {
    const f = await agent(`Run the full local build of the integration branch and triage it. ${BUILD_RULE} Run \`${TOOLS} full ${DIR}\`. If it prints "LOCAL BUILD OK" return green=true. Otherwise read ${LOGS}/local-integration-full.log fully enough to collect EVERY distinct compile error, lint error and failing test (xcodebuild stops a target at its first failing file set; list all you can see), and group them by owner. ${ownersHint} Do not change code.`, { label: `local:${round}`, phase: 'Green', model: M, schema: FAILURES })
    if (!f) break
    if (f.green) { localGreen = true } else {
      log(`round ${round}: local build red — ${f.groups.length} owner group(s)`)
      await fixGroups(f.groups, round, 'local build')
      continue
    }
  }
  const ci = await agent(`Push the integration branch and run the full CI on it. In ${DIR}: git push -u origin ${BR} (retry 4x). Start CI: gh workflow run ios.yml --repo ${REPO} --ref ${BR}; find the workflow_dispatch run for HEAD's SHA (gh run list --repo ${REPO} --branch ${BR} --json databaseId,headSha,status,conclusion,url --limit 10; poll every 30 s). Wait: gh run watch <id> --repo ${REPO} --exit-status --interval 60 (Bash timeout 600000; repeat until complete; queues of 30 min are normal). Both jobs (test, ipa) must succeed → green=true. Otherwise gh run view <id> --repo ${REPO} --log-failed > ${LOGS}/integration-ci-${round}.log and collect every distinct error / failing test, grouped by owner. ${ownersHint} Put the run URL in notes. Do not change code.`, { label: `ci:${round}`, phase: 'Green', model: M, schema: FAILURES })
  if (!ci) break
  ciRun = ci.notes
  if (ci.green) { ciGreen = true; break }
  log(`round ${round}: CI red — ${ci.groups.length} owner group(s)`)
  await fixGroups(ci.groups, round, 'CI')
  localGreen = false
}
if (!ciGreen) return { stage: 'green', merged, ciGreen, ciRun }

// ---------------------------------------------------------------------------
phase('Smoke')
const SMOKE_RUN = `Boot an iPad simulator (xcrun simctl list devices available; prefer an iPad Pro 13-inch on the newest iOS 26 runtime; boot it and open Simulator.app). Build the app for the simulator from ${DIR} (xcodegen generate; xcodebuild build -project Nib.xcodeproj -scheme Nib -configuration Debug -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath ${P.root}-dd-sim CODE_SIGNING_ALLOWED=NO — wait for any running ${TOOLS} build first: ls ~/Projects/Nib-locks must show at most one slot held), install (xcrun simctl install) and launch it. Enable the MCP/HTTP bridge the way F090/F091 define (read their code and tools/smoke/README.md: a launch argument, a setting you can write with xcrun simctl spawn defaults, or the Bridge settings screen), get its port and token, and run every tools/smoke/*.json script with node tools/smoke/run.mjs (see its README for flags). Device-only checks (real Pencil latency, palm rejection, AirPlay) cannot run on a simulator: report them as "needs device" with the reason, not as failures.`
const smoke = []
for (let round = 1; round <= 4; round++) {
  const s = await agent(`F111 smoke tests, round ${round}. ${SMOKE_RUN}
Also confirm the IntegrationTests scenarios passed in the last full build (grep ${LOGS}/local-integration-full.log for IntegrationTests).
Return green=true when every simulator-runnable script passes; otherwise group the failures by owner (${ownersHint}) with the script step, expected vs actual, and the relevant log. Do not change code. Put the "needs device" list in notes.`, { label: `smoke:${round}`, phase: 'Smoke', model: M, schema: FAILURES })
  if (!s) break
  smoke.push(s)
  if (s.green) break
  await fixGroups(s.groups, `smoke${round}`, 'smoke scripts')
  const b = await agent(`${BUILD_RULE} Run \`${TOOLS} full ${DIR}\` after the smoke fixes; if it fails, fix the regressions (same rules: root causes, no skipping) and repeat until "LOCAL BUILD OK", committing on ${BR} (${TRAILER}). Return status green/red.`, { label: `rebuild:smoke${round}`, phase: 'Smoke', model: M, schema: RESULT })
  if (!b || b.status !== 'green') break
}

// ---------------------------------------------------------------------------
phase('Design')
const SHOTS = `${P.root}-design`
const capture = await agent(`Capture the real app for a design review. ${SMOKE_RUN.split('Enable the MCP')[0]}
Then drive the app to every key screen and save PNG screenshots (xcrun simctl io <udid> screenshot) to ${SHOTS}/<n>-<screen>.png, in light AND dark appearance (xcrun simctl ui <udid> appearance dark|light), iPad landscape AND portrait, plus the same core screens on an iPhone 17 Pro simulator. Use the bridge (nib_run / nib_context via tools/smoke/run.mjs or curl) to reach states quickly (open a document, select a tool, open panels, dock the palette at each edge, open menus, sheets, the assistant, settings, library with folders, search, study sets, text documents, whiteboard, presentation). Screens: library (grid, list, folder, drag reorder mid-drag if reachable), new-notebook sheet, document canvas with the tool palette docked left/top/bottom/right and the tool options bar, lasso selection + object menu, page sidebar, outline, search, settings, AI assistant panel, plugin manager, export sheet, study session, text document, whiteboard, presentation mode, onboarding. Write ${SHOTS}/index.md listing each file, the screen, the state and how you reached it. Return the list (details).`, { label: 'design:capture', phase: 'Design', model: M, schema: RESULT })
const LENSES = [
  'MATERIAL + LIQUID GLASS: DESIGN.md §2 (droplet material), §7, §10 (droplet physics, dock, meniscus), §16 lines about glass; rims, refraction, double rims, merged/split glass, bud-offs; iOS 26 glass vs pre-26 fallbacks.',
  'LAYOUT + TYPOGRAPHY + COLOUR: DESIGN.md §3–§6 and §14 (per-screen specs): spacing grid, fixed metrics, radii, type scale, colour tokens in light and dark, alignment, density, iPad vs iPhone layouts, canvas-first calm.',
  'SLOP + ACCESSIBILITY: every line of DESIGN.md §16 Slop checklist and §12 accessibility (44 pt targets, Dynamic Type, contrast, VoiceOver-visible labels, Reduce Motion/Transparency fallbacks); anything that looks templated or generic.',
]
let design = []
if (capture && capture.status !== 'blocked') {
  const reviews = (await parallel(LENSES.map((lens, i) => () => agent(`Design review of the real Nib app. Read docs/DESIGN.md fully, then look at EVERY screenshot in ${SHOTS} (index.md explains each). Lens: ${lens}
For each real problem you can SEE, name the screen/file, the DESIGN.md rule it breaks, the owning feature (${ownersHint} — find the view code in ${DIR} that draws it) and the concrete code fix. Severity: blocker (broken/unusable), major (clearly violates the spec or the Slop checklist), minor. No speculation about things not visible. Do not change code.`, { label: `design:review${i + 1}`, phase: 'Design', model: M, schema: REVIEW })))).filter(Boolean)
  const issues = reviews.flatMap((r) => r.issues || []).filter((i) => i.severity !== 'minor')
  design = issues
  if (issues.length) {
    const groups = {}
    for (const i of issues) (groups[i.owner] = groups[i.owner] || []).push(i)
    await fixGroups(Object.keys(groups).map((o) => ({ owner: o, files: [], errors: groups[o].map((i) => `[${i.severity}] ${i.screen || ''}: ${i.problem} → ${i.fix}`) })), 'design', 'design review')
    const b = await agent(`${BUILD_RULE} Run \`${TOOLS} full ${DIR}\` after the design fixes; fix regressions until "LOCAL BUILD OK", committing on ${BR} (${TRAILER}). Then re-capture the screens the design fixes touched into ${SHOTS}/after/ (same method as ${SHOTS}/index.md) so the user can compare. Return status green/red.`, { label: 'design:rebuild', phase: 'Design', model: M, schema: RESULT })
    if (!b || b.status !== 'green') return { stage: 'design', ciGreen, smoke, design, rebuild: b }
  }
}

// ---------------------------------------------------------------------------
phase('Ship')
const ship = await agent(`Ship the integrated build.
1. In ${DIR}: git push origin ${BR}; start and watch the full CI on ${BR} (gh workflow run ios.yml --repo ${REPO} --ref ${BR}; gh run watch ... --exit-status). If red, fix root causes on ${BR} with the local helper (${BUILD_RULE}) and repeat (max 4 rounds).
2. When ${BR} is green: in the main clone ${ROOT}: git fetch origin && git checkout -q main && git pull -q --ff-only origin main && git merge --ff-only origin/${BR} (if main moved, git merge --no-ff origin/${BR} with ${TRAILER}) && git push origin main.
3. Watch main's CI run for that SHA (test + ipa) to green. Download the IPA: gh run download <id> --repo ${REPO} -n Nib-unsigned-ipa -D ${P.root}-dist/<short-sha>/.
4. Tag it: git tag nib-integration-1 <sha> && git push origin nib-integration-1.
5. Device: xcrun devicectl list devices. If an iPad/iPhone is connected and trusted and Xcode has a signing team (security find-identity -v -p codesigning shows an "Apple Development" identity), build and install with automatic signing (xcodebuild -allowProvisioningUpdates ... DEVELOPMENT_TEAM=<team>) and launch it; otherwise report that the IPA is at ${P.root}-dist/<short-sha>/ for sideloading.
Return status green with the main SHA, the run URL, the IPA path(s) and the device result (details).`, { label: 'ship', phase: 'Ship', model: M, schema: RESULT })

return { order, merged, ciRun, smoke: smoke.map((s) => ({ green: s.green, notes: s.notes, groups: s.groups.length })), designIssues: design.length, ship }
