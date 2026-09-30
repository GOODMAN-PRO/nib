export const meta = {
  name: 'nib-fleet-v3',
  description: 'Nib fleet: main-side v2 jobs (contracts2, shell, spec pass 2) + per-feature implement -> CI -> review -> fix -> V2ADOPT, state-driven, local Xcode builds with CI as the gate',
  phases: [
    { title: 'Main', detail: 'v2/contracts2 merge, v2/shell build+review+merge, spec pass 2, state commits' },
    { title: 'Build', detail: 'state-driven fan-out: implement -> CI -> review -> fix -> CI -> V2ADOPT, skipping stages already done' },
  ],
}

// args: fleet-launch-args.json from collect-state.js, plus optional:
//   resume:   { Fxxx: 'implement' | 'fix' | 'v2adopt' }   jobs interrupted mid-stage (continue from WIP/pushed work)
//   notes:    { Fxxx: '...' }                               extra instructions for that feature's jobs
//   mainside: { contracts2Run?: '<run id>', shell?: true, spec2?: true }
//   v2adopt:  true    give every feature built before this run (and not yet adopted) a V2ADOPT pass
//   tools:    path of nib-build.sh (local slot-locked build helper)
//   commitEvery: N    commit Nib-state/*.json to main [skip ci] after every N finished features
//   only:     [ids]   restrict the fan-out to these features (dependencies still gate on their state)
const A = (typeof args === 'string') ? JSON.parse(args) : (args || {})
const FEATURES = (A.features || []).slice().sort((a, b) => (a.priority || 9) - (b.priority || 9))
if (!FEATURES.length) throw new Error('args.features is empty')

const P = A.paths || {}
const SEP = P.sep || '\\'
const ROOT = P.root || 'G:\\Projects\\Nib'
const WT = P.worktrees || 'G:\\Projects\\Nib-wt'
const LOGS = P.logs || 'G:\\Projects\\Nib-ci-logs'
const STATE_DIR = P.state || 'G:\\Projects\\Nib-state'
const LOCAL = !!A.localBuild
const TOOLS = A.tools || `${ROOT}${SEP}tools${SEP}fleet${SEP}nib-build.sh`
const REPO = 'GOODMAN-PRO/nib'
const M = 'opus'
const TRAILER_1 = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
const TRAILER_2 = 'Claude-Session: https://claude.ai/code/session_01GpZ3Q12FGHi43JsYU8aD5F'
const TRAILER = `every commit message ends with a blank line and then exactly these two adjacent lines (one trailer paragraph):\n  ${TRAILER_1}\n  ${TRAILER_2}\n(e.g. git commit -m "<subject>" -m "$(printf '${TRAILER_1}\\n${TRAILER_2}')")`
const RESUME = A.resume || {}
const NOTES = A.notes || {}
const MAINSIDE = A.mainside || {}
const ONLY = A.only ? new Set(A.only) : null
const byId = {}
FEATURES.forEach((f) => { byId[f.id] = f })

// Circuit breaker: when the usage limit hits, agents return null in bursts. Stop launching new work.
let nulls = 0
let halted = false
const run = async (prompt, opts) => {
  if (halted) return null
  const r = await agent(prompt, opts)
  if (r === null || r === undefined) { nulls++; if (nulls >= 3) { if (!halted) log('3 agents returned nothing (usage limit?) - halting new work; re-collect state and relaunch fresh later'); halted = true } }
  else nulls = 0
  return r
}

// Codex offload (args.codex): implement / CI / fix / V2ADOPT jobs run in Codex CLI through a thin Claude forwarder
// (args.codexTool = nib-codex.sh); reviews stay on Claude, so every feature still gets a cross-model review.
// If Codex is unavailable (quota, auth, crash) the job falls back to Claude with the same prompt.
const CODEX = !!A.codex
const CODEX_TOOL = A.codexTool || ''
const CODEX_PROMPTS = A.codexPrompts || ''
const CODEX_NOTE = `You are running as Codex CLI (non-interactive, full access) on the user's Mac, doing one job of the Nib agent fleet. Long commands (the local build helper, gh run watch, CI queues) can take 10-60 min: give them a long timeout (e.g. timeout_ms 3600000) or start them in the background and poll their .exit / .log files; never give up while a CI run is queued or in progress. Ignore any mention of "Bash timeout" in the text below (that is Claude Code's tool). Work autonomously to completion, then answer with the JSON object the output schema asks for.`
const viaCodex = async (kind, f, prompt, schemaKey, effort, opts) => {
  if (!CODEX) return run(prompt, opts)
  if (halted) return null
  const name = `${kind}-${f.id}`
  const pfile = `${CODEX_PROMPTS}/${name}.md`
  const wrapper = `You are a thin forwarder that hands ONE job to Codex CLI and returns its result. Do NOT read the repository, investigate, or do the job yourself.
1. Write everything under "TASK:" below, verbatim and complete, to ${pfile} with ONE Bash call using a quoted heredoc (cat > ${pfile} <<'NIB_TASK_EOF' ... NIB_TASK_EOF).
2. Run: ${CODEX_TOOL} run ${name} ${WT}${SEP}${f.id} ${pfile} ${schemaKey} ${effort}   (Bash timeout 600000)
3. While its output starts with "RUNNING", run: ${CODEX_TOOL} wait ${name}   (Bash timeout 600000). Keep repeating; hours is normal.
4. When the output starts with "RESULT ", return that JSON's fields exactly as your structured output.
5. If it starts with "CODEX_FAILED", return status "${schemaKey === 'impl' ? 'failed' : 'blocked'}", rounds 0, empty arrays, and notes "CODEX_UNAVAILABLE: <the reason it printed>".

TASK:
${CODEX_NOTE}

${prompt}`
  const r = await agent(wrapper, { ...opts, label: `cx-${opts.label}`, effort: 'low' })
  if (!r || /CODEX_UNAVAILABLE/.test(r.notes || '')) {
    log(`${opts.label}: Codex unavailable (${r ? (r.notes || '').slice(0, 140) : 'no result'}) - falling back to Claude`)
    return run(prompt, opts)
  }
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
const MAIN_RESULT = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['merged', 'green', 'red', 'blocked', 'nothing-to-do'] },
    sha: { type: 'string' },
    runUrl: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['status'],
}

const isUI = (f) => f.layer === 'ui' || f.layer === 'fullstack'
const owned = (f) => `exactly the paths in the "files" and "tests" arrays of feature ${f.id} in docs/forge-spec.json`
const depClosure = (f, acc = new Set()) => {
  for (const d of f.dependsOn || []) if (byId[d] && !acc.has(d)) { acc.add(d); depClosure(byId[d], acc) }
  return acc
}
const note = (f) => NOTES[f.id] ? `\nEXTRA INSTRUCTIONS FOR ${f.id}: ${NOTES[f.id]}\n` : ''

const LOCAL_BUILD = (dir, mode, arg) => `${TOOLS} ${mode} ${dir}${arg ? ' ' + arg : ''}`
const localRule = (cmd) => `LOCAL BUILD (this Mac has Xcode 26.6; it is an 8 GB M1 shared by several agents, so ALWAYS build through the helper, never raw xcodebuild): \`${cmd}\`. It waits for one of 2 machine-wide build slots, mirrors the CI job, prints "LOCAL BUILD OK" or the error lines + log tail, and writes the full log to ${LOGS}${SEP}local-<worktree>-<mode>.log (exit code in the matching .exit file). Run it with Bash timeout 600000; if the call times out the build keeps running in the background: wait with \`until [ -f <that .exit file> ]; do sleep 20; done\` (timeout 600000, repeat) and read the log. Never run two builds of your own at once.`

const ciLoop = (dir, branch, scopeRule, maxRounds, localCmd) => `You own getting branch "${branch}" of ${REPO} green on GitHub Actions. Working copy: ${dir}.
Loop (max ${maxRounds} rounds):
1. ${LOCAL ? localRule(localCmd) + ' Fix every local failure first (CI stays the gate, local is just faster). ' : ''}Commit everything (git add -A; ${TRAILER}) and push: git fetch origin ${branch} main; git push -u origin ${branch} (retry network failures up to 4x with backoff). Note the SHA.
2. Find the run for that SHA: gh run list --repo ${REPO} --branch ${branch} --json databaseId,headSha,status,conclusion,url --limit 10 — poll every ~30s until it appears (only 5 macOS jobs run at once across the fleet: 10-30 min queues are normal, never give up while queued).${branch.startsWith('feat/') ? '' : ` Pushes to ${branch} do not start CI by themselves: start it with gh workflow run ios.yml --repo ${REPO} --ref ${branch} and find the workflow_dispatch run.`}
3. Wait: gh run watch <id> --repo ${REPO} --exit-status --interval 45 (Bash timeout 600000; if it times out call it again).
4. All jobs succeeded → return "green".
5. Failure → gh run view <id> --repo ${REPO} --log-failed > ${LOGS}${SEP}${branch.replace(/\//g, '_')}-<round>.log (never inside a repo); grep for "error:", "** BUILD FAILED", "** TEST FAILED", "failed (", "fatal", "::error". Fix root causes. ${scopeRule} Back to 1.
Never disable/skip tests, never comment code out, never "#if false", never stub a feature away to get green. Return status, rounds, last run URL, remaining errors, and contract gaps you hit.`

const prelude = (f, dir) => `Before anything: \`git -C ${dir} fetch origin\`; if origin/feat/${f.id} is ahead of the local branch, fast-forward to it. If \`git -C ${dir} merge-base --is-ancestor origin/main HEAD\` fails, run \`git -C ${dir} merge --no-edit origin/main\` (conflicts outside ${f.id}'s owned files: take origin/main's version). If the worktree has uncommitted work, a stash for this feature, or the branch head is a commit titled "WIP ...", an earlier agent was interrupted by a usage limit: CONTINUE from that work (read it, keep what is good, finish and fix the rest) instead of restarting; fold the WIP into your real commit(s) (a normal follow-up commit is fine; never force-push).
contracts-v2 / design-v2 are on main: use docs/CONTRACTS.md "contracts-v2 changelog" and docs/DESIGN_SYSTEM.md "NibDesign v2 additions" APIs instead of inventing workarounds.`

// ---------------------------------------------------------------------------
// Main-branch lock: every job that pushes to main runs inside withMain, so main-side merges never race.
let mainChain = Promise.resolve()
const withMain = (fn) => { const p = mainChain.then(fn, fn); mainChain = p.catch(() => null); return p }
const MAIN_CLONE_RULE = `The main clone is ${ROOT} (branch main). You hold the main lock right now: nobody else pushes to main until you return. In ${ROOT}: git fetch origin && git checkout -q main && git pull -q --ff-only origin main before you start; leave it on a clean, pushed main when you finish.`

let resolveSpec, resolveMainV2
const specReady = new Promise((r) => { resolveSpec = r })
const mainV2Ready = new Promise((r) => { resolveMainV2 = r })

const contracts2Job = async () => {
  if (!MAINSIDE.contracts2Run) return { status: 'nothing-to-do' }
  return withMain(() => run(`Merge branch v2/contracts2 (contracts-v2.1: PanelIDs for the study panels and Move Pages, CommandIDs constants for every §6.5 id) into main of ${REPO}.
Its worktree is ${WT}${SEP}v2-contracts2 (already merged with main, pushed; locally NibContractsTests pass). Its CI run is ${MAINSIDE.contracts2Run}: wait for it with gh run watch ${MAINSIDE.contracts2Run} --repo ${REPO} --exit-status --interval 45 (Bash timeout 600000; repeat until it completes). If it failed, fix on v2/contracts2 (${ciLoop(WT + SEP + 'v2-contracts2', 'v2/contracts2', 'Only NibContracts sources/tests and docs may change.', 5, LOCAL_BUILD(WT + SEP + 'v2-contracts2', 'targets', '"NibContractsTests"'))}).
Once v2/contracts2 is green: ${MAIN_CLONE_RULE} Then git merge --no-ff origin/v2/contracts2 (message "Merge v2/contracts2: contracts-v2.1" + trailer; ${TRAILER}), run python3 Scripts/lint.py, git push origin main. Watch the main CI run for the merge commit (gh run list --repo ${REPO} --branch main ...; it runs test + ipa). If main goes red, fix it on main (same loop, small commits) until green. Return status "merged" with the merge SHA and the main run URL.`, { label: 'main:contracts2', phase: 'Main', model: M, schema: MAIN_RESULT }))
}

const spec2Job = async () => {
  if (!MAINSIDE.spec2) return { status: 'nothing-to-do' }
  const dir = `${WT}${SEP}v2-spec2`
  const edit = await run(`Spec pass 2 for Nib (docs only, main-side). Worktree: ${dir} — create it if missing: git -C ${ROOT} fetch origin && git -C ${ROOT} worktree add ${dir} -B v2/spec2 origin/main (if it exists, merge origin/main into it).
Read tools/fleet/cloud/ledger.md fully, then apply to docs/forge-spec.json (feature "description"/"commands" text), docs/ARCHITECTURE.md (§6.5 command catalogue and the relevant sections) and docs/CONTRACTS.md prose (NO Swift changes) every pending spec item it lists that is not already in the docs. At least:
- "Spec pass 2 items": audio.play toggle? + optional clip for user callers; audio.pause close?; playback status gains a recording field (F052). scan.documents gains anchor? (F065). F055: IndexKeys.scanText -> PageRecord.scanTextExtKey note.
- F019 FeatLibraryUI (unbuilt): must present sheet panels from the library (panel.open with no open document; F021 New Notebook sheet, F044 and F020 rely on it), fill MenuContext.folder, and double-tap + New -> doc.quickNote. Keep the existing library.reorder / Manual sort / NibReflow text.
- F074 (unbuilt): must parse nib://bridge/pair?host=&port=&token= (port optional, added by F091); ARCHITECTURE §12 pairing link documents the optional port.
- Pin the unpinned result shapes: template.choose kind values + result size; doc.suggestTitle result; panel.open params delivery to PanelContext.params (state the rule: flat keys, the command's params minus "id"). Check what the built features already do (grep the feat worktrees under ${WT}, e.g. F021, F044, F017) and pin THAT behaviour so no built feature breaks.
- F007 (unbuilt): check its spec already has the v2 items (roll key, etc.); add anything the ledger says F007 needs.
- The "Integration spec edit" bullets (image.pick for F034 + §6.5; element.create fallback:Bool for F035; layer.exportOptions / F066 visibleLayers) — apply any that are not present yet.
Keep every feature's "files"/"tests" ownership unchanged. Run python3 Scripts/lint.py until it reports 0 errors. Then append a "## Spec pass 2 (applied)" section to tools/fleet/cloud/ledger.md listing each item applied (and which built features must pick up a spec delta in their V2ADOPT pass). Commit on v2/spec2 (${TRAILER}). Do NOT push to main (a later step merges it). Return a short list of what changed per feature id.`, { label: 'main:spec2-edit', phase: 'Main', model: M })
  const merged = await withMain(() => run(`Merge the docs-only branch v2/spec2 (worktree ${dir}) into main. ${MAIN_CLONE_RULE} git merge --no-ff v2/spec2 (it is a local branch of the same repo; message "Merge v2/spec2: spec pass 2" + trailer; ${TRAILER}); resolve conflicts keeping both sides' intent; python3 Scripts/lint.py must report 0 errors; git push origin main. Also push v2/spec2 for the record (git -C ${dir} push -u origin v2/spec2). Docs-only, so do not wait for main CI. Return status "merged" with the SHA.`, { label: 'main:spec2-merge', phase: 'Main', model: M, schema: MAIN_RESULT }))
  return { edit, merged }
}

const shellJob = async (c2) => {
  if (!MAINSIDE.shell) return { status: 'nothing-to-do' }
  await c2
  const dir = `${WT}${SEP}v2-shell`
  const build = await run(`Build "shell v2" for Nib: the app shell in Nib/App/** (scaffold-owned, main-side; no feature owns it). Worktree: ${dir} — create it if missing: git -C ${ROOT} fetch origin && git -C ${ROOT} worktree add ${dir} -B v2/shell origin/main (if it exists: fast-forward to origin/v2/shell if that exists, then merge origin/main). Continue from any existing work on it.
Read first: tools/fleet/HANDOFF.md §0, tools/fleet/cloud/ledger.md (every bullet mentioning shell, key-window, childForStatusBarHidden, user-fonts, docKinds, sessionParams, window undo, F102/F014 key commands, F017 chrome), docs/ARCHITECTURE.md (app shell, key commands/KeyScope, windows/scenes, undo), docs/CONTRACTS.md (contracts-v2 changelog: key command descriptors, docKinds, sessionParams, floating host, chrome overlays), Nib/App/*.swift, project.yml, Nib/Resources (Info.plist).
Implement, production quality:
1. Key commands: the shell's UIKeyCommand bridge honours every KeyCommandDescriptor's docKinds (only active when the key window's open document kind matches; nil/empty = any) and sessionParams (merged into the command params when it runs), plus scope/priority as the contracts define.
2. ⌘Z / ⇧⌘Z: when the active document's history (DocHistory/undo stack in the contracts) is empty or there is no document, fall back to the key window's UndoManager (so session-level undo like toolbar.dock "Move Palette" works); keep menu validation (canPerformAction/validate) correct for both.
3. Track key-window changes across scenes (UIWindowScene key window notifications / sceneDidBecomeActive): publish the current key window/scene to whatever the contracts expect (e.g. window.showLibrary / session current window) so commands target the right window.
4. Forward childForStatusBarHidden (and childForStatusBarStyle / home indicator / screen-edges if the shell VC wraps children) to the presented content controller, so full-screen/presentation modes (P-106) can hide the status bar.
5. Add the user-fonts entitlement: com.apple.developer.user-fonts = [app-usage] in Nib/Nib.entitlements via project.yml's entitlements properties (and/or UIAppSupportsInstalledFonts in Info.plist) for F026 T-059/P-083.
If a contract change is truly needed, you may edit NibKit/Sources/NibContracts with a test in NibKit/Tests/NibContractsTests and a note in docs/CONTRACTS.md's changelog; keep it minimal and backward compatible (feature branches must keep compiling). Add unit-testable logic (key-command matching by docKinds/sessionParams, undo fallback decision) as small pure helpers with tests where the app target allows (or in NibContracts if it belongs there).
Then: ${ciLoop(dir, 'v2/shell', 'Only Nib/App/**, Nib/Nib.entitlements, project.yml, Nib/Resources/Info.plist and (if you changed contracts) NibContracts + its tests + docs/CONTRACTS.md may change.', 6, LOCAL_BUILD(dir, 'app') + ' (and, if you touched NibContracts, also ' + LOCAL_BUILD(dir, 'targets', '"NibContractsTests"') + ')')}`, { label: 'main:shell-build', phase: 'Main', model: M, schema: CI_RESULT })
  if (!build || build.status !== 'green') return { build }
  const lenses = [
    'CORRECTNESS: logic bugs in key-command dispatch (docKinds/sessionParams/scope), the ⌘Z fallback decision and menu validation, key-window tracking across multiple scenes (iPad Stage Manager), status-bar forwarding; @MainActor/threading; regressions to existing shell behaviour.',
    'SPEC + CONTRACT COMPLETENESS: every shell item in tools/fleet/HANDOFF.md §0 and the shell/key-window/status-bar/user-fonts/F102/F014/F017 bullets of tools/fleet/cloud/ledger.md is fully done; contracts-v2 descriptors are honoured exactly as docs/CONTRACTS.md defines them; entitlement/Info.plist change is correct for XcodeGen; any NibContracts change is backward compatible with all feat/* branches (grep the worktrees under ' + WT + ').',
  ]
  const reviews = (await parallel(lenses.map((lens, i) => () => run(`Independent code review (you did not write it) of branch v2/shell in ${dir} against origin/main (git -C ${dir} diff origin/main...HEAD). Lens: ${lens} Report only real, concrete issues with concrete fixes. Do not change code.`, { label: `main:shell-review${i + 1}`, phase: 'Main', model: M, schema: REVIEW })))).filter(Boolean)
  const issues = reviews.flatMap((r) => r.issues || [])
  let fixed = build
  if (issues.some((i) => i.severity !== 'minor')) {
    fixed = await run(`Apply these review findings to branch v2/shell in ${dir} (fix every blocker and major; minors when cheap; if you judge a finding wrong, say why in notes):\n${JSON.stringify(issues, null, 1)}\nThen: ${ciLoop(dir, 'v2/shell', 'Same file scope as the shell build.', 5, LOCAL_BUILD(dir, 'app'))}`, { label: 'main:shell-fix', phase: 'Main', model: M, schema: CI_RESULT })
    if (!fixed || fixed.status !== 'green') return { build, reviews, fixed }
  }
  const merged = await withMain(() => run(`Merge green branch v2/shell (worktree ${dir}) into main. ${MAIN_CLONE_RULE} git merge --no-ff origin/v2/shell (message "Merge v2/shell: app shell v2" + trailer; ${TRAILER}); python3 Scripts/lint.py; ${LOCAL ? localRule(LOCAL_BUILD(ROOT, 'app')) + ' Run it on the main clone before pushing.' : ''} git push origin main. Watch main CI for the merge commit (test + ipa) until it completes; if red, fix on main (small commits, same rules as any CI loop, max 4 rounds). Return status "merged" (or "red"/"blocked") with the SHA and run URL.`, { label: 'main:shell-merge', phase: 'Main', model: M, schema: MAIN_RESULT }))
  return { build, reviews, fixed, merged }
}

// State commits: copy Nib-state/*.json into tools/fleet/state and commit to main [skip ci].
let finished = 0
const commitEvery = A.commitEvery || 0
const commitState = (why) => withMain(() => run(`Commit the fleet state markers to main. ${MAIN_CLONE_RULE} Copy ${STATE_DIR}${SEP}*.json into ${ROOT}${SEP}tools${SEP}fleet${SEP}state${SEP} (overwrite). If git status shows changes under tools/fleet/state: git add tools/fleet/state && git commit -m "Fleet state: ${why} [skip ci]" (${TRAILER}) && git push origin main (retry up to 4x; on a non-fast-forward, pull --rebase and push again). Return status "merged" with the SHA, or "nothing-to-do".`, { label: `main:state`, phase: 'Main', model: M, effort: 'low', schema: MAIN_RESULT }))

// ---------------------------------------------------------------------------
phase('Main')
const c2Promise = contracts2Job()
const specPromise = spec2Job().then((r) => { resolveSpec(); return r }, (e) => { resolveSpec(); return { error: String(e) } })
const shellPromise = shellJob(c2Promise)
Promise.all([c2Promise, shellPromise]).then(() => resolveMainV2(), () => resolveMainV2())

// ---------------------------------------------------------------------------
phase('Build')
const STATE = A.state || {}
const green = {}
const resolveGreen = {}
FEATURES.forEach((f) => { green[f.id] = new Promise((r) => { resolveGreen[f.id] = r }) })
// Features outside `only` resolve from their collected state right away.
FEATURES.forEach((f) => { if (ONLY && !ONLY.has(f.id)) resolveGreen[f.id]({ id: f.id, status: (STATE[f.id] || {}).ci || 'unbuilt' }) })

const implementPrompt = (f, depInfo, resumed) => {
  const dir = `${WT}${SEP}${f.id}`
  return `You are building ONE feature of "Nib" (native iPadOS/iOS, GoodNotes 6 parity + JS plugins + bring-your-own-AI + "water droplet" liquid UI). Other agents build other features in parallel; ${LOCAL ? 'you are on a Mac with Xcode 26.6: before committing, compile and run your module tests LOCALLY via `' + LOCAL_BUILD(dir, 'feature', f.id) + '` (see the build rules below) and fix what fails; still be meticulous about' : 'you cannot compile locally — CI compiles, so be meticulous about'} Swift/Apple API correctness (Swift 5 mode, Xcode 26.6 / iOS 26 SDK, deployment iOS 17, #available for newer APIs, public access across modules).

WORKTREE: ${dir} (branch feat/${f.id}). Work ONLY there.
${prelude(f, dir)}
${resumed ? `RESUMED JOB: an earlier implementer of ${f.id} was interrupted by a usage limit. Whatever is on the branch (commits since main, a WIP commit, uncommitted files) is its partial work — even if CI was green, it may be incomplete. Audit it against EVERY acceptance criterion and parity item, keep what is good, and complete everything that is missing or wrong.\n` : ''}${(f.dependsOn || []).length ? `DEPENDENCIES: run \`git -C ${dir} merge --no-edit ${(f.dependsOn || []).filter((d) => byId[d]).map((d) => 'origin/feat/' + d).join(' ')}\` to bring in the dependency features' code (${depInfo}). Their files are theirs — read and use them, never edit them.` : 'No feature dependencies: rely only on the contracts.'}
${note(f)}
FEATURE ${f.id} — ${f.name}  (module ${f.module}, layer ${f.layer}, complexity ${f.complexity})
SPEC / ACCEPTANCE CRITERIA: your entry for ${f.id} in docs/forge-spec.json — its "description" is your full spec; follow it to the letter.
GOODNOTES PARITY ITEMS (look each up in docs/FEATURES.md and match the behaviour): ${(f.inventory || []).join(', ') || '(none)'}
FILES YOU OWN (the ONLY files you may create/edit): ${owned(f)}

Read before coding: docs/ARCHITECTURE.md (module rules, command conventions, registries, UI extension points, UI rules), docs/CONTRACTS.md ("How to use this file", the contracts-v2 changelog, and the contract types you use; the real source is NibKit/Sources/NibContracts), the existing stub in your module${isUI(f) ? ', docs/DESIGN.md (binding look + droplet physics + per-screen specs + Slop checklist), docs/DESIGN_SYSTEM.md (incl. "NibDesign v2 additions") and NibKit/Sources/NibDesign (use ONLY its tokens, components and liquid modifiers — never hard-code colors/fonts/radii/springs)' : ''}${/Plugin|AI|Bridge|Relay/i.test(f.module + f.name) ? ', docs/PLUGIN_API.md and docs/AI.md' : ''}.

Build it COMPLETELY — every acceptance criterion, every parity item — as production code:
- Every user-facing action is a registered Command with a JSON schema (the "plugins and AI can modify anything" guarantee); reads go through the query API; undo/redo works.
- No TODOs, no fatalError/placeholder bodies, no fake data paths shipped as real behaviour.${isUI(f) ? '\n- UI: premium, calm, canvas-first, exactly per DESIGN.md; droplet/liquid behaviour where DESIGN.md prescribes it and nowhere near live ink; VoiceOver labels, Dynamic Type, 44pt targets, Reduce Motion/Transparency, iPad pointer + keyboard shortcuts; iPad and iPhone size classes.' : ''}
- Tests: real XCTest cases in your owned test files for the non-trivial logic (a handful of meaningful tests, using NibTesting fakes/fixtures); they must pass.
- If the contracts lack something, work around it INSIDE your files and list it under contractGaps — never edit shared files.
${LOCAL ? localRule(LOCAL_BUILD(dir, 'feature', f.id)) + ' Get it to "LOCAL BUILD OK" before your final commit.\n' : ''}Finally: git -C ${dir} add -A && commit with subject "${f.id}: ${f.name.replace(/"/g, "'")}" (${TRAILER}). Do NOT push. Return status, files written, command ids registered, contract gaps, and anything from the spec you could not do (notDone).`
}

const reviewPrompt = (f) => {
  const dir = `${WT}${SEP}${f.id}`
  const deps = [...depClosure(f)]
  return `Independent code review (you did not write this) of feature ${f.id} "${f.name}" in ${dir} (branch feat/${f.id}; CI is green). First: git -C ${dir} fetch origin (do not change the branch).
Spec: the "description" of ${f.id} in docs/forge-spec.json on origin/main (git -C ${dir} show origin/main:docs/forge-spec.json) — its full acceptance criteria.
Parity items (docs/FEATURES.md): ${(f.inventory || []).join(', ') || '(none)'}
Check, strictly:
1. Every acceptance criterion and parity item is actually implemented (not stubbed, not faked, no TODO/fatalError placeholders).
2. Ownership: \`git -C ${dir} diff --name-only origin/main...HEAD\` must only contain the files/tests (docs/forge-spec.json) of ${f.id}${deps.length ? ' and of its dependency features ' + deps.join(', ') : ''}. Any other file is a blocker.
3. Contracts: conforms to NibContracts (commands registered with schemas + undo; queries; events; registries) — the "plugins and AI can modify anything" guarantee holds for everything this feature lets a user do. Workarounds that the contracts-v2 changelog (docs/CONTRACTS.md) or "NibDesign v2 additions" (docs/DESIGN_SYSTEM.md) now cover count as a major.
4. Correctness: logic bugs, data-loss risks, threading (@MainActor), memory/perf on large notebooks, error handling at trust boundaries (files, network, plugins, AI).${isUI(f) ? '\n5. Design: follows docs/DESIGN.md + the Slop checklist, composes only NibDesign tokens/components/liquid modifiers, no hard-coded styling, accessibility (VoiceOver, Dynamic Type, 44pt, Reduce Motion), iPad + iPhone layouts.' : ''}
6. Tests are meaningful and cover the risky logic.${note(f)}
Before returning, write your full verdict as JSON {"verdict": ..., "issues": [...]} to ${STATE_DIR}${SEP}${f.id}.review.json — that file is how later runs know this review is done. Do not change code.
Return verdict "pass" only if there are no blockers or majors. Concrete fixes only.`
}

const fixPrompt = (f, issues) => {
  const dir = `${WT}${SEP}${f.id}`
  return `Apply the code-review fixes to feature ${f.id} "${f.name}" in ${dir} (branch feat/${f.id}). ${issues ? 'ISSUES:\n' + JSON.stringify(issues, null, 1) : `The review is in ${STATE_DIR}${SEP}${f.id}.review.json — read its "issues".`}
${prelude(f, dir)}
Fix every blocker and major; minors when cheap. Only edit files ${f.id} owns: ${owned(f)} (if the review flags files outside that list, revert those changes: git checkout origin/main -- <file>).${note(f)}
Then: ${ciLoop(dir, `feat/${f.id}`, `Only edit files ${f.id} owns.`, 6, LOCAL_BUILD(dir, 'feature', f.id))}
Finally write {"status": "<green|red|blocked>", "runUrl": "..."} to ${STATE_DIR}${SEP}${f.id}.fixed.json.`
}

const v2adoptPrompt = (f) => {
  const dir = `${WT}${SEP}${f.id}`
  return `V2ADOPT for feature ${f.id} "${f.name}" in ${dir} (branch feat/${f.id}). The feature is built and green, but was written against contracts-v1 / design-v1 (and an older spec) and carries workarounds that contracts-v2, design-v2, contracts-v2.1, shell v2 and spec pass 2 (all now on origin/main) cover.
${prelude(f, dir)}
1. Merge origin/main (done above).
2. Read docs/CONTRACTS.md "contracts-v2 changelog" and docs/DESIGN_SYSTEM.md "NibDesign v2 additions"; find every entry naming THIS feature (grep "${f.id}"), plus the lines for ${f.id} in tools/fleet/contract-gaps.md marked [v2: ...], plus every bullet in tools/fleet/cloud/ledger.md naming ${f.id} (follow-ups, spec pass 2 deltas, key-command re-registration after shell v2, etc.).
3. Replace each listed workaround with the v2 API (delete local stand-in code, private keys, NSMapTables, NibApp.shared lookups, hand-made tokens/symbols, hand-dimming NibDesign buttons now do themselves, etc.), keeping behaviour identical or better.
4. Diff your spec entry in docs/forge-spec.json between the commit this feature was built on and origin/main (git log -p origin/main -- docs/forge-spec.json | grep -n ${f.id} helps) and implement any spec delta (new params, commands, result shapes).
5. Keep/extend tests so the behaviour is still covered. Only edit files ${f.id} owns: ${owned(f)}.${note(f)}
6. ${ciLoop(dir, `feat/${f.id}`, `Only edit files ${f.id} owns.`, 6, LOCAL_BUILD(dir, 'feature', f.id))}
7. Write {"status":"<green|red|blocked>","runUrl":"...","v2adopt":true} to ${STATE_DIR}${SEP}${f.id}.fixed.json (overwrite). In "notes" say what was replaced and what v2 still doesn't cover.`
}

// Cap concurrent implementers so CI/review/fix agents always get slots.
const MAX_IMPL = A.maxImpl || 5
let implActive = 0
const implQueue = []
// Critical path first: a waiting implementer with more transitive dependents gets the next slot.
const dependents = {}
FEATURES.forEach((f) => { dependents[f.id] = 0 })
FEATURES.forEach((f) => { for (const d of depClosure(f)) dependents[d] = (dependents[d] || 0) + 1 })
const acquireImpl = (id) => {
  if (implActive < MAX_IMPL) { implActive++; return Promise.resolve() }
  return new Promise((r) => { implQueue.push({ r, rank: dependents[id] || 0 }); implQueue.sort((a, b) => b.rank - a.rank) })
}
const releaseImpl = () => { const next = implQueue.shift(); if (next) next.r(); else implActive-- }

const done = async (r) => {
  finished++
  if (commitEvery && finished % commitEvery === 0 && !halted) await commitState(`${finished} features processed`)
  return r
}

const buildOne = async (f) => {
  const st = STATE[f.id] || {}
  const resume = RESUME[f.id]
  const builtBefore = !!st.impl
  const deps = (f.dependsOn || []).filter((d) => byId[d])
  const depResults = await Promise.all(deps.map((d) => green[d]))
  const depInfo = depResults.map((r) => `${r.id}: ${r.status}`).join(', ')
  const forceImpl = resume === 'implement'
  let impl = st.impl && !forceImpl ? { status: 'done', files: [], notDone: [], fromState: true } : null
  let ci = st.ci === 'green' && !forceImpl ? { status: 'green', rounds: 0, remainingErrors: [], fromState: true } : null
  if (resume === 'fix' || resume === 'v2adopt') ci = ci || { status: 'green', rounds: 0, remainingErrors: [], fromState: true, assumed: true }
  try {
    if (!impl) {
      if (!builtBefore) await specReady // unbuilt features wait for spec pass 2
      await acquireImpl(f.id)
      try { impl = await viaCodex('impl', f, implementPrompt(f, depInfo, forceImpl || st.wip), 'impl', 'high', { label: `impl:${f.id}`, phase: 'Build', model: M, schema: IMPL_RESULT }) } finally { releaseImpl() }
    }
    if (impl && !ci) {
      ci = await viaCodex('ci', f, `${ciLoop(`${WT}${SEP}${f.id}`, `feat/${f.id}`,
        `Only edit files feature ${f.id} owns: ${owned(f)}. If an error is in a dependency's file or a shared contract, work around it inside your own files where possible and report it under contractGaps.`, 8, LOCAL_BUILD(`${WT}${SEP}${f.id}`, 'feature', f.id))}\n${prelude(f, `${WT}${SEP}${f.id}`)}`, 'ci', 'medium',
        { label: `ci:${f.id}`, phase: 'Build', model: M, schema: CI_RESULT })
    }
  } finally {
    resolveGreen[f.id]({ id: f.id, status: (ci && ci.status) || (impl ? 'unbuilt' : 'failed') })
  }
  if (halted && !ci) return done({ id: f.id, impl, ci, review: null, final: 'halted' })
  if (!ci || ci.status !== 'green') return done({ id: f.id, impl, ci, review: null, final: ci && ci.status })

  let review = null
  let finalCi = ci
  const needsReviewFix = !(st.fixed && !forceImpl) && resume !== 'v2adopt'
  if (needsReviewFix) {
    review = st.review && !forceImpl ? { verdict: st.review, issues: null, fromState: true } : null
    if (!review) review = await run(reviewPrompt(f), { label: `review:${f.id}`, phase: 'Build', model: M, schema: REVIEW })
    if (!review) return done({ id: f.id, impl, ci, review: null, final: halted ? 'halted' : 'unreviewed' })
    const serious = (review.issues || []).filter((i) => i.severity !== 'minor')
    if (review.verdict === 'needs-fix' || serious.length) {
      finalCi = await viaCodex('fix', f, fixPrompt(f, review.issues), 'ci', 'high', { label: `fix:${f.id}`, phase: 'Build', model: M, schema: CI_RESULT })
      if (!finalCi) return done({ id: f.id, impl, ci, review, final: halted ? 'halted' : 'unfixed' })
      if (finalCi.status !== 'green') return done({ id: f.id, impl, ci, review, final: finalCi.status })
    }
  } else {
    review = { verdict: st.review || 'needs-fix', issues: [], fromState: true }
    finalCi = { status: st.fixed || 'green' }
  }

  let adopt = null
  const wantAdopt = resume === 'v2adopt' || (A.v2adopt && builtBefore && !st.v2)
  if (wantAdopt && finalCi && finalCi.status === 'green') {
    await Promise.all([mainV2Ready, specReady])
    adopt = await viaCodex('v2adopt', f, v2adoptPrompt(f), 'ci', 'high', { label: `v2adopt:${f.id}`, phase: 'Build', model: M, schema: CI_RESULT })
    if (!adopt) return done({ id: f.id, impl, ci, review, adopt, final: halted ? 'halted' : 'unadopted' })
    finalCi = adopt
  }
  return done({ id: f.id, impl, ci, review, adopt, final: finalCi && finalCi.status })
}

const todo = FEATURES.filter((f) => !ONLY || ONLY.has(f.id))
const results = (await parallel(todo.map((f) => () => buildOne(f)))).map((r, i) => r || { id: todo[i].id, final: 'crashed' })
const mainside = { contracts2: await c2Promise, spec2: await specPromise, shell: await shellPromise }
if (!halted && commitEvery) await commitState('batch complete')

const summary = {
  total: todo.length,
  halted,
  mainside: {
    contracts2: mainside.contracts2 && mainside.contracts2.status,
    spec2: mainside.spec2 && mainside.spec2.merged && mainside.spec2.merged.status,
    shell: mainside.shell && (mainside.shell.merged ? mainside.shell.merged.status : (mainside.shell.fixed || mainside.shell.build || mainside.shell).status),
  },
  green: results.filter((r) => r.final === 'green').map((r) => r.id),
  notGreen: results.filter((r) => r.final !== 'green').map((r) => ({ id: r.id, final: r.final, errors: ((r.adopt || r.ci || {}).remainingErrors || []).slice(0, 5) })),
  notDone: results.filter((r) => r.impl && (r.impl.notDone || []).length).map((r) => ({ id: r.id, notDone: r.impl.notDone })),
  contractGaps: results.flatMap((r) => [...((r.impl && r.impl.contractGaps) || []), ...((r.ci && r.ci.contractGaps) || []), ...((r.adopt && r.adopt.contractGaps) || [])].map((g) => `${r.id}: ${g}`)),
  reviewedNeedsFix: results.filter((r) => r.review && r.review.verdict === 'needs-fix').map((r) => r.id),
  adopted: results.filter((r) => r.adopt && r.adopt.status === 'green').map((r) => r.id),
}
log(`Fleet: ${summary.green.length}/${summary.total} green${halted ? ' (halted at usage limit — re-collect state and relaunch fresh)' : ''}`)
return summary
