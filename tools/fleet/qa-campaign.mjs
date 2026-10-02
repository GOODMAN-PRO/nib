#!/usr/bin/env node
// Functional QA campaign, run entirely by Codex (GPT-6 Astra): make every button, zoom and pen function provably work,
// fix every bug found, then ship. Claude only planned this file; every step is a `codex exec` job via nib-codex.sh.
//
// Phases: scaffold (XCUITest target + fixture launch mode + accessibility ids + QA state probe)
//         -> matrix (inventory of every user-facing control, grouped by area)
//         -> write (one XCUITest file per area, run it, report failures as bugs)
//         -> fix loop (owner-grouped fixers, unit suite + full UI suite, until green or the ship deadline)
//         -> design check (capture + review + fix, only if time allows) -> ship (CI, main, IPA, tag nib-1.0).
// Usage: node tools/fleet/qa-campaign.mjs <args.json>
//   args: { root, wt, logs, tools, codexTool, prompts, shipBy: "HH:MM", designBy: "HH:MM", rcTag, maxWriters, fixRounds }
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import fs from 'node:fs'

const sh = promisify(execFile)
const A = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const { root: ROOT, wt: DIR, logs: LOGS, tools: TOOLS, codexTool: CX, prompts: PROMPTS } = A
const REPO = 'GOODMAN-PRO/nib'
const BR = 'integration'
const TAG = A.jobTag || 'qa'
const TRAILER = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01GpZ3Q12FGHi43JsYU8aD5F'
const TRAILER_RULE = `every commit message ends with a blank line then exactly these two adjacent lines:\n${TRAILER}`
const say = (m) => console.log(`[${new Date().toTimeString().slice(0, 8)}] ${m}`)
// Deadlines are "HH:MM" (today) or "YYYY-MM-DD HH:MM" (local time).
const parseWhen = (w) => { const d = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}):(\d{2})$/.exec(w); if (d) return new Date(`${d[1]}T${d[2]}:${d[3]}:00`); const [h, m] = w.split(':').map(Number); const t = new Date(); t.setHours(h, m, 0, 0); return t }
const minutesUntil = (w) => (parseWhen(w) - Date.now()) / 60000
const STATE = `${LOGS}/qa-state.json`
const state = fs.existsSync(STATE) ? JSON.parse(fs.readFileSync(STATE, 'utf8')) : {}
const save = () => fs.writeFileSync(STATE, JSON.stringify(state, null, 1))

const PREAMBLE = `You are GPT-6 Astra running as Codex CLI (non-interactive, full access) on the user's Mac, doing one step of the Nib build (native iPadOS/iOS note app, GoodNotes-class; docs/DESIGN.md, docs/ARCHITECTURE.md, docs/CONTRACTS.md and docs/forge-spec.json are binding). Repo worktree: ${DIR} (branch ${BR}). Long commands (builds, simulator UI tests) take a long time: use long timeouts or background + poll. Never skip, weaken, comment out or delete tests to get green; a test may only change when it contradicts the spec, and then say so explicitly. Shared machine rules: never create, delete or edit anything under ~/Projects/Nib-locks, never kill/stop/continue processes you did not start, never pause (SIGSTOP) any build or test process — not even your own (a paused run holds a shared lane or slot idle; let it run or end it), and never run UI tests outside the nib-build.sh uitest command — the lanes are shared with other jobs. The disk is nearly full: never copy result bundles or export attachments into /tmp; if you must export, use ${LOGS}/scratch-<your job> and delete it before you answer. Work autonomously to completion, then answer with the JSON object the output schema asks for.\n\n`
const BUILD = `Unit/package build: \`${TOOLS} full ${DIR}\` (waits for a build slot; 30-90 min; log ${LOGS}/local-integration-full.log, exit code in the .exit file).`
const uiTag = (filter) => (filter || 'all').replace(/NibUITests\//g, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/-$/, '').slice(0, 60)
const UIRUN = (filter, budget) => `UI tests: \`${TOOLS} uitest ${DIR}${filter ? ` "${filter}"` : ''}\` (xcodegen + XCUITest; the machine has TWO simulator lanes that run two UI runs IN PARALLEL by design — that is correct and expected, do not try to make your run exclusive or serial; your run may queue for a free lane; log ${LOGS}/local-integration-uitest-${uiTag(filter)}.log, exit code in the matching .exit file, result bundle ${LOGS}/ui-${uiTag(filter)}.xcresult — read failures with \`xcrun xcresulttool get test-results tests --path ${LOGS}/ui-${uiTag(filter)}.xcresult\`). Every UI test file compiles into one target: if the run fails to COMPILE because of another file, report that in notes instead of editing it.${budget ? ` HARD BUDGET: this job may start at most ${budget} UI run(s) (the tool refuses more), so make each one count — write and review the whole file before running.` : ''}`

async function codex (name, prompt, schema, effort = 'high', uiMax = 0, retried = false) {
  const id = `${TAG}-${name}`
  const pfile = `${PROMPTS}/${id}.md`
  fs.writeFileSync(pfile, PREAMBLE + prompt)
  // A job that already finished in an earlier orchestrator run is reused, never re-run (nib-codex.sh would restart it).
  const base = `${LOGS}/codex-${id}`
  if (!alive(id) && fs.existsSync(`${base}.exit`) && fs.readFileSync(`${base}.exit`, 'utf8').trim() === '0') {
    try { return JSON.parse(fs.readFileSync(`${base}.json`, 'utf8')) } catch {}
  }
  const env = { ...process.env, NIB_UI_MAX: uiMax ? String(uiMax) : '' }
  if (!alive(id)) fs.writeFileSync(`${LOGS}/uiruns-${id}`, '0')   // fresh job -> fresh UI-run budget
  let { stdout } = await sh(CX, ['run', id, DIR, pfile, schema, effort], { maxBuffer: 1 << 24, env })
  while (stdout.startsWith('RUNNING')) ({ stdout } = await sh(CX, ['wait', id], { maxBuffer: 1 << 24 }).catch((e) => ({ stdout: e.stdout || 'CODEX_FAILED wait error' })))
  if (stdout.startsWith('RESULT ')) return JSON.parse(stdout.slice(7))
  if (!retried) {   // infrastructure deaths (disk full, OOM, killed) get one fresh attempt
    say(`  ${name}: ${stdout.trim().slice(0, 160)} — retrying once`)
    fs.rmSync(`${base}.exit`, { force: true })
    return codex(name, prompt, schema, effort, uiMax, true)
  }
  throw new Error(`${name}: ${stdout.trim().slice(0, 300)}`)
}
const alive = (id) => { try { process.kill(Number(fs.readFileSync(`${LOGS}/codex-${id}.pid`, 'utf8')), 0); return !fs.existsSync(`${LOGS}/codex-${id}.exit`) } catch { return false } }
const git = (...a) => sh('git', ['-C', DIR, ...a]).then((r) => r.stdout.trim())
let commitChain = Promise.resolve()
function commit (msg) {   // serialized: several areas commit into the same worktree
  const run = async () => {
    // Never commit into someone else's in-progress merge (a Codex merge job), and never commit conflict markers.
    for (let i = 0; i < 240 && await git('rev-parse', '-q', '--verify', 'MERGE_HEAD').then(() => true, () => false); i++) await new Promise((r) => setTimeout(r, 15000))
    if (await git('rev-parse', '-q', '--verify', 'MERGE_HEAD').then(() => true, () => false)) return 'skipped: merge in progress'
    if (!(await git('status', '--porcelain'))) return null
    await git('add', '-A')
    const markers = await git('diff', '--cached', '-G', '^(<<<<<<< |>>>>>>> )', '--name-only').catch(() => '')
    if (markers) { await git('reset', '-q'); return `skipped: conflict markers in ${markers.split('\n').join(', ')}` }
    await git('commit', '-q', '-m', msg, '-m', TRAILER)
    return git('log', '-1', '--format=%h')
  }
  const p = commitChain.then(run, run); commitChain = p.catch(() => null); return p.catch((e) => `commit failed: ${e.message.slice(0, 120)}`)
}
const normOwner = (o) => (/F\d{3}/.exec(o || '') || ['shared'])[0]
async function pool (items, n, fn) {
  const out = new Array(items.length); let i = 0
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => { while (i < items.length) { const k = i++; out[k] = await fn(items[k], k).catch((e) => ({ status: 'blocked', error: e.message })) } }))
  return out
}

async function main () {
  // ---------------------------------------------------------------- scaffold
  if (!state.scaffold) {
    say('scaffold: XCUITest target, fixture launch mode, accessibility ids, QA state probe')
    const r = await codex('scaffold', `Build the UI-test infrastructure so every button, gesture and tool of the real app can be exercised automatically on the iPad simulator.
1. project.yml (XcodeGen): add a UI-testing bundle target "NibUITests" (sources NibUITests/, host/target app Nib, iOS 17 deployment, same signing settings as the app for the simulator) and a scheme "NibUITests" that builds Nib and runs NibUITests. CI must keep working (the existing ios.yml jobs must not start running UI tests).
2. App launch mode for tests: when launched with the argument "-NibUITestFixture" the app (Nib/App, shared shell code) uses a fresh temporary library, skips onboarding and any first-run sheets, disables animations where Reduce Motion would (to keep tests fast and deterministic), and seeds a fixture library: folder "Semester Notes" with a notebook inside; a 4-page notebook "Physics — Motion" (text, a shape, a sticky note, some ink); a whiteboard "Concept map" with a few items; a text document; a study set with 3 cards. Reuse NibTesting fixtures or the existing seed code where possible. Production behaviour is unchanged without the argument.
3. Accessibility identifiers: every control that runs a registered command (toolbar/palette items, nav-bar buttons, menu items, context/object-menu actions, sheet buttons, library buttons) gets accessibilityIdentifier "cmd.<command id>" (and tool palette items "tool.<tool id>") — do this generically where the control is built from a descriptor (NibDesign components, the toolbar/menu/registry renderers, the shell), plus targeted ids for important controls that are not descriptor-built. Keep existing labels for VoiceOver.
4. QA state probe: in fixture mode only, expose an invisible accessibility element with identifier "nib.qa.state" whose accessibilityValue is compact JSON of the live session: {screen, document, page, pageCount, tool, zoom (canvas zoom scale), contentOffset, itemCountOnPage, strokeCountOnPage, selectionCount, undoAvailable, redoAvailable, openPanels, paletteDock}. It updates on every change (no polling in production).
5. NibUITests/Support: a small helper library — launch with the fixture, open a document by title, wait for the state probe, read it as a decoded struct, draw a stroke with XCUICoordinate press-and-drag along a path, pinch-zoom, double-tap, two-finger scroll, tap a "cmd.<id>" control (with overflow-menu fallback), dismiss sheets.
6. One smoke test NibUITests/SmokeUITests.swift: launches, opens "Physics — Motion", selects the pen, draws a stroke (strokeCountOnPage +1), undoes it, pinch-zooms (zoom changes), returns to the library.
Run ${UIRUN('NibUITests/SmokeUITests')} until it passes, and ${BUILD} until LOCAL BUILD OK (the package tests must stay green). Commit on ${BR} (${TRAILER_RULE}) with message "QA: XCUITest target, fixture mode, accessibility ids, state probe". Answer status "ok"/"red", details = what you built and how to use the helpers.`, 'result', 'high')
    say(`scaffold: ${r.status}`)
    if (r.status !== 'ok') throw new Error('scaffold not ok: ' + (r.notes || '').slice(0, 300))
    state.scaffold = r; save()
  }

  // ---------------------------------------------------------------- matrix
  if (!state.matrix) {
    say('matrix: inventory of every user-facing control')
    const m = await codex('matrix', `Produce the functional test inventory for the whole app. Read docs/ARCHITECTURE.md (§6.5 command catalogue, UI registries, key commands), docs/DESIGN.md §14 (every screen), docs/FEATURES.md, NibKit/Sources/NibContracts (CommandIDs, PanelIDs, ToolIDs, registries), and grep the feature modules for registered toolbar items, menu items, object-menu actions, panels, sheets, gestures and key commands.
Group EVERY user-facing control/function into these areas (keys exactly): library (browser, folders, favourites, trash, sort, select, drag reorder, search entry, new menu), create (new notebook/whiteboard/text doc/study set sheets, templates, covers, QuickNote), canvas (scroll, pinch zoom, double-tap zoom, fit/width/page zoom commands, page layout modes, page navigation, minimap, zoom window, rotation), ink (pen, pencil, highlighter, eraser modes, shape recognition/draw-and-hold, colour/width presets, eyedropper, undo/redo of strokes), selection (lasso, object menu actions, transform, duplicate, copy/paste, delete, arrange, convert), insert (text box, shapes, images, stickers/elements, sticky notes, tape, links, comments, audio), pages (sidebar, add/move/duplicate/delete pages, outline, bookmarks, templates per page), chrome (tool palette docking at every edge, options bar, nav bar buttons, tabs, panels, read-only, presentation, laser, ruler, timekeeper), search (document search, library search, match navigation, handwriting recognition/convert), share (export, import, print, backup, sync status), study_ai (study sessions, AI assistant/actions/math, plugins, collaboration, bridge settings, settings screens, keyboard shortcuts).
For each control: id (command/tool id or a stable slug), control (what the user sees/does), trigger (how a UI test reaches it: accessibility id "cmd.<id>"/"tool.<id>", menu path, gesture), expected (observable result, preferably via the nib.qa.state probe fields or visible UI). owners = feature ids implementing that area. Be exhaustive — this list is the definition of "every button works". Also save it to tools/qa/matrix.json in the repo (do not commit). Answer with the JSON.`, 'matrix', 'high')
    say(`matrix: ${m.areas.length} areas, ${m.areas.reduce((n, a) => n + a.controls.length, 0)} controls`)
    state.matrix = m; save()
  }

  // ---------------------------------------------------------------- write -> fix -> verify, pipelined per area
  // Each area flows on its own: its UI tests are written and run, then its failures go straight to owner fixers and a
  // targeted verify run, while other areas are still being written. Same-owner fixers serialize via nib-codex.sh locks.
  state.written ||= {}; state.fixed ||= {}
  const qual = (r, f) => { const t = String(f.test || ''); if (t.includes('/')) return t.startsWith('NibUITests/') ? t : `NibUITests/${t}`; const c = (r.file || '').match(/(\w+UITests)\.swift/)?.[1]; return c ? `NibUITests/${c}/${t}` : t }
  const clsOf = (key) => key.replace(/(^|_)(\w)/g, (_, __, c) => c.toUpperCase()) + 'UITests'

  const writeArea = async (a) => {
    const cls = clsOf(a.key)
    const exists = fs.existsSync(`${DIR}/NibUITests/${cls}.swift`)
    if (state.written[a.key] && !state.written[a.key].tests) fs.rmSync(`${LOGS}/codex-${TAG}-write-${a.key}.exit`, { force: true })   // rerun an unrun writer
    const r = await codex(`write-${a.key}`, `${exists ? `NibUITests/${cls}.swift already exists from an earlier writer whose UI run never executed: keep its good tests, add whatever controls below are still missing (quickly), delete any placeholder test that only XCTFails for "DEVICE COVERAGE" (device-only checks go in notes instead), then RUN it — the run is the point of this job. ` : ''}Write the XCUITest coverage for area "${a.title}" (key ${a.key}). File: NibUITests/${cls}.swift (only this file; use the helpers in NibUITests/Support and the "nib.qa.state" probe; do not edit app code, other test files or project.yml — other jobs work in parallel).
Cover EVERY control in this list with at least one test that performs the real user action (tap the button / menu item, perform the gesture, draw the stroke) and asserts the observable expected result (state probe fields, visible UI, undo/redo where applicable). Pen/ink tools must actually draw strokes and check stroke counts; zoom must check the zoom value changes and is bounded; buttons must check their effect, not just that they exist.
Controls:\n${JSON.stringify(a.controls)}
Things XCUITest on the simulator genuinely cannot do (Apple Pencil pressure/tilt/hover/squeeze/double-tap, camera, VoiceOver audio, real hardware keyboards beyond typeKey) are NOT tests: list them in notes as device-only; never add XCTFail placeholders for them.
Spend at most ~45 minutes writing. The UI run may wait in a queue for a long time: wait for it to finish however long it takes (never give up on a queued run). Then run ${UIRUN(`NibUITests/${cls}`, 2)} If a test fails because the TEST is wrong (wrong identifier, timing, wrong expectation vs the spec), fix the test. If it fails because the APP is wrong (button missing/not wired, wrong behaviour, crash, zoom/pen broken), keep the test as the spec says and report it as a failure with owner (feature id from docs/forge-spec.json whose files implement it, or "shared"), problem and evidence (assertion message / screenshot attachment name). Do not commit. Answer status "green" (all pass) or "red", file, tests, passed, failed, failures, notes.`, 'uiwrite', 'high', 2)
    say(`  write ${a.key}: ${r.status} ${r.passed ?? '?'}/${r.tests ?? '?'} pass, ${r.failed ?? '?'} fail`)
    state.written[a.key] = r; save()
    return r
  }

  const mergeEarly = async () => {
    say('library: waiting for the early library fix lane')
    let ef; let { stdout } = await sh(CX, ['wait', A.earlyFix.job], { maxBuffer: 1 << 24 }).catch((e) => ({ stdout: e.stdout || '' }))
    while (stdout.startsWith('RUNNING')) ({ stdout } = await sh(CX, ['wait', A.earlyFix.job], { maxBuffer: 1 << 24 }).catch((e) => ({ stdout: e.stdout || '' })))
    if (stdout.startsWith('RESULT ')) ef = JSON.parse(stdout.slice(7))
    say(`library: early lane ${ef ? `${ef.status} ${ef.passed}/${ef.tests} pass, ${ef.failed} fail` : 'gave no result'}`)
    const mergeJob = `${TAG}-merge-earlyfix`
    const mergeStarted = alive(mergeJob) || fs.existsSync(`${LOGS}/codex-${mergeJob}.exit`)
    if (!mergeStarted) await commit('QA: work in progress before merging the library lane')
    const ahead = Number(await git('rev-list', '--count', `HEAD..${A.earlyFix.branch}`).catch(() => '0'))
    if (ahead > 0) {
      const ok = mergeStarted ? false : await git('merge', '--no-ff', '-q', A.earlyFix.branch, '-m', 'QA: library fixes (early lane)', '-m', TRAILER).then(() => true, async () => { await git('merge', '--abort').catch(() => {}); return false })
      if (!ok) {
        const m = await codex('merge-earlyfix', `Merge branch ${A.earlyFix.branch} (library fixes) into ${BR} in ${DIR}: git merge --no-ff ${A.earlyFix.branch}, then resolve every conflict keeping BOTH sides' intent (e.g. integration's idle/parking fixes in NibDesign/Liquid AND the library lane's fixes), never dropping either. Other jobs edit files in this worktree concurrently: touch only conflicted files. Check it compiles: \`${TOOLS} targets ${DIR} "<test targets of the conflicted modules>"\`. Commit the merge with message "QA: library fixes (early lane)" (${TRAILER_RULE}). Answer status "ok" or "red", details = how each conflict was resolved.`, 'result', 'high')
        say(`library: merge via Codex ${m.status}`)
      } else say(`library: merged ${A.earlyFix.branch} (${ahead} commit(s))`)
    }
    const lf = `${A.earlyFix.wt}/NibUITests/LibraryUITests.swift`
    if (fs.existsSync(lf)) fs.copyFileSync(lf, `${DIR}/NibUITests/LibraryUITests.swift`)
    state.earlyFixMerged = true
    if (ef) state.written.library = ef
    save()
    return ef || state.written.library
  }

  const fixArea = async (a, r) => {
    const cls = clsOf(a.key)
    const st = (state.fixed[a.key] ||= { rounds: [] })
    let failures = st.rounds.length ? (st.remaining || []) : (r.failures || []).map((f) => ({ ...f, test: qual(r, f) }))
    for (let round = st.rounds.length + 1; round <= (A.fixRounds || 3); round++) {
      if (!failures.length) break
      const roundGate = 60   // fixers need no simulator lane; verifies are gated separately (150 min) and the final verify re-runs the critical classes
      if (minutesUntil(A.shipBy) < roundGate) { say(`fix ${a.key}: no time for round ${round} (final verify + ship by ${A.shipBy})`); break }
      const groups = {}
      for (const f of failures) (groups[normOwner(f.owner)] ||= []).push(`${f.test}: ${f.problem} [evidence: ${f.evidence}]`)
      say(`fix ${a.key} r${round}: ${failures.length} failure(s) -> ${Object.keys(groups).join(', ')}`)
      await pool(Object.keys(groups), 6, (o) => codex(`fix-${a.key}-${round}-${o}`, `Fix these functional bugs found by the ${cls} UI tests (round ${round}). Edit ONLY files owned by ${o === 'shared' ? 'no feature (Nib/App shell, NibDesign, NibContracts, NibUITests/Support, project.yml; keep changes backward compatible)' : o + ' (docs/forge-spec.json files/tests)'}; other Codex jobs edit other files and run UI tests from this same worktree right now, so keep the code compiling at every moment (make each file edit complete and self-consistent) and NEVER run git add/commit/stash/checkout/reset.
Failures:\n${groups[o].join('\n')}
The tests live in NibUITests/${cls}.swift (read them to see exactly what the user action and expectation are). Find the root cause in the app (button not wired to its command, command failing, gesture not reaching the canvas, keyboard shortcut not routed to the focused scene, zoom limits, pen/stroke pipeline, state not updating, crash) and fix it per the spec — for real users, not just for the test. Add/extend unit tests in the owner's test files for the logic you fix and check them with \`${TOOLS} targets ${DIR} "<the owner's test targets>"\` (waits for a build slot). If the root cause provably sits in another owner's files (e.g. the shared canvas input / wet-ink path, the shell's focus or scene routing), make the minimal root-cause fix there too and say exactly which file and why — never answer "blocked" just because of the ownership boundary. Only if a UI test itself is wrong per the spec may you correct that test (say which and why). Do not run UI tests (the verify step does). Answer status "ok", details = root cause + fix per failure.`, 'result', 'high').catch((e) => ({ status: 'blocked', details: [e.message] })))
      say(`fix ${a.key} r${round}: committed ${await commit(`QA: ${a.key} fixes, round ${round}`)}`)
      const ids = [...new Set(failures.map((f) => String(f.test || '')).filter((t) => /^NibUITests\/\w+UITests\/\w+$/.test(t)))]
      // If the area's first run executed only part of the class (queue kills, time boxes), verify the WHOLE class.
      const declared = (fs.readFileSync(`${DIR}/NibUITests/${cls}.swift`, 'utf8').match(/func test\w+\s*\(/g) || []).length
      const lastTests = round === 1 ? (r.tests || 0) : (st.lastTests ?? 0)
      const partial = lastTests < declared * 0.8
      const target = ids.length && !partial ? ids.join(' ') : `NibUITests/${cls}`
      if (minutesUntil(A.shipBy) < 150 && !alive(`${TAG}-verify-${a.key}-${round}`)) { say(`verify ${a.key} r${round}: skipped — out of time; the final verify covers the critical classes`); st.remaining = failures; save(); break }
      const verifyPrompt = `Verify the ${a.key} fixes (round ${round}). Run ${UIRUN(target, 2)} (${target.includes('/test') ? `the ${cls} tests that failed before the fixes` : `the WHOLE ${cls} class — most of it has never run yet`}; identifiers are NibUITests/<Class>/<testMethod>). If the build fails, report the compile errors as a failure with the owning feature. For every failing test decide: test wrong per spec -> fix the test in NibUITests/${cls}.swift (and rerun once if budget allows); app wrong -> report it (do not change app code here). Never git add/commit/stash/checkout/reset. Answer status "green" (all those tests pass) or "red", file "NibUITests/${cls}.swift", tests/passed/failed, failures (test = "${cls}/<testMethod>", owner = feature id or "shared", problem, evidence), notes.`
      let v = await codex(`verify-${a.key}-${round}`, verifyPrompt, 'uiwrite', 'high', 2).catch((e) => ({ status: 'blocked', failures, notes: e.message }))
      if (!v.tests && minutesUntil(A.shipBy) > 150) {   // nothing executed (build broken by a concurrent edit, runner death): run the verify again
        say(`verify ${a.key} r${round}: no tests executed — running the verify again`)
        v = await codex(`verify-${a.key}-${round}b`, verifyPrompt, 'uiwrite', 'high', 2).catch((e) => ({ status: 'blocked', failures, notes: e.message }))
      }
      say(`verify ${a.key} r${round}: ${v.status} — ${v.passed ?? '?'}/${v.tests ?? '?'} pass, ${v.failed ?? '?'} fail`)
      failures = (v.failures || []).map((f) => ({ ...f, test: qual(v, f) }))
      st.lastTests = v.tests || 0
      st.rounds.push({ round, before: Object.values(groups).flat().length, after: failures.length, status: v.status }); st.remaining = failures; save()
      if (v.status === 'green') break
    }
    st.remaining = failures; save()
    say(`area ${a.key}: done, ${failures.length} failure(s) left`)
  }

  const todo = state.matrix.areas.filter((a) => !(state.fixed[a.key] && state.fixed[a.key].done))
  // Order: writers already running, then areas whose results are in (straight to fixing), then the library lane, then the rest.
  const PRIORITY = ['ink', 'chrome', 'pages', 'search', 'share', 'study_ai']   // pen + toolbar buttons first
  const rank = (a) => alive(`${TAG}-write-${a.key}`) ? 0 : (state.written[a.key]?.tests ? 1 : (a.key === 'library' ? 2 : 3 + (PRIORITY.indexOf(a.key) + 1 || 9)))
  todo.sort((x, y) => rank(x) - rank(y))
  if (todo.length) say(`areas: ${todo.map((a) => a.key).join(', ')}`)
  const areasP = pool(todo, A.maxWriters || 3, async (a) => {
    let r = state.written[a.key]
    if (a.key === 'library' && A.earlyFix && !state.earlyFixMerged) r = await mergeEarly()
    else if (!r || !r.tests) {
      if (minutesUntil(A.shipBy) < 210 && !alive(`${TAG}-write-${a.key}`)) {   // a new area needs ~3.5 h for write + fix + verify
        say(`area ${a.key}: NOT COVERED — no time left to write, fix and verify it before ${A.shipBy}`)
        state.fixed[a.key] = { rounds: [], remaining: [], done: true, notCovered: true }; save(); return
      }
      r = await writeArea(a)
    }
    await fixArea(a, r)
    state.fixed[a.key].done = true; save()
  })

  const LENSES = [
      ['glass', 'MATERIAL + LIQUID GLASS: DESIGN.md §2, §7, §10 and the glass lines of §16 — rims, refraction, doubled edges, shading, glass bodies behind every floating control, dark-mode legibility, iOS 26 glass vs fallbacks.'],
      ['layout', 'LAYOUT + TYPOGRAPHY + COLOUR: DESIGN.md §3-§6 and §14 per screen — spacing grid, alignment, radii, type scale, truncation, colour tokens light AND dark, overlaps between chrome/panels and page content or ink, portrait vs landscape.'],
      ['slop', 'SLOP + ACCESSIBILITY: every line of DESIGN.md §16 and §12 — 44 pt targets, Dynamic Type, contrast, VoiceOver labels, Reduce Motion/Transparency; anything templated, generic, cluttered, duplicated or stray.'],
      ['ux', 'UX + COPY + STATES: the product feel — empty states, error and confirmation messages, button and menu wording (consistent, specific, sentence case, no jargon), loading/progress states, disabled states, selection feedback, consistency of icons and terminology across screens, anything that feels unfinished.'],
    ]
  const capturePrompt = (dir) => `Capture the real app for the final polish review, through the UI-test lanes (no extra simulators: the Mac is out of memory).
1. Write (or, if it already exists, finish and reuse) NibUITests/CaptureUITests.swift (only this file, plus — if missing — a fixture-only launch argument "-NibUITestAppearance light|dark" in the app's UI-test fixture code that sets the windows' overrideUserInterfaceStyle). One test per screen group: drive the real app into each state with the NibUITests/Support helpers (verify via the nib.qa.state probe), then attach XCTAttachment(screenshot: XCUIScreen.main.screenshot()) named "<nn>-<screen>-<light|dark>-<portrait|landscape>" with lifetime .keepAlways. Screens: library grid, list and an open folder; library search; new menu; new-notebook sheet; canvas with the palette docked left, top and bottom; the options bar; each tool's options (pen, highlighter, eraser, lasso, shapes, text); a lasso selection with its object menu; page sidebar; outline; document search with matches; AI assistant; plugin manager; settings (2-3 screens); export sheet; whiteboard; text document; study session; presentation mode; tabs with 3 documents; an empty folder; an empty/error state. Light AND dark, portrait AND landscape (XCUIDevice.shared.orientation). A capture test should not fail on cosmetic details — only when a state cannot be reached.
2. Run ${UIRUN('NibUITests/CaptureUITests', 2)}
3. Export: xcrun xcresulttool export attachments --path ${LOGS}/ui-CaptureUITests.xcresult --output-path ${dir} ; rename each exported file to its attachment name (the export's manifest.json maps them) as .png; write ${dir}/index.md listing each file, screen and state, and any state you could not reach and why.
Answer status "ok", details = the file list (or "blocked" with the reason).`
  // ---------------------------------------------------------------- polish, concurrently with the area pipeline
  const polishP = (async () => {
    if (state.design?.done) return
    const shots = `${ROOT}-design/qa-final`
    say('polish: capture through XCUITest + 4-lens review + fix everything (incl. minor)')
    const pngs = () => { try { return fs.readdirSync(shots).filter((f) => f.endsWith('.png')).length } catch { return 0 } }
    let cap = { status: 'blocked', details: [] }
    for (const name of ['capture', 'capture-2']) {
      if (pngs() > 0) break
      cap = await codex(name, capturePrompt(shots), 'result', 'high', 2).catch((e) => ({ status: 'blocked', details: [e.message] }))
      say(`polish: ${name} ${cap.status}, ${pngs()} screenshot(s)`)
    }
    let reviewShots = shots
    let shotNote = ''
    if (!pngs()) {   // live capture did not finish in time: review the latest design-pass screenshots, checked against the current code
      reviewShots = A.fallbackShots
      shotNote = ` These screenshots are from the last design pass (this morning) — today's functional fixes changed some screens since, so CHECK EVERY FINDING AGAINST THE CURRENT CODE before reporting it, and also read the current view code of the screens shown for problems the screenshots cannot show.`
      say(`polish: no fresh screenshots — reviewing ${reviewShots} + the current code`)
    }
    const reviews = await Promise.all(LENSES.map(([key, lens]) => codex(`polish-review-${key}`, `Final polish review of the real Nib app. Read docs/DESIGN.md fully, open EVERY screenshot in ${reviewShots} with your image viewer (index.md explains each).${shotNote} Lens: ${lens}
Report every real, visible problem — blocker, major AND minor polish — each with screen, owner (feature id from docs/forge-spec.json whose files draw it, or "shared"), problem and the concrete fix. No speculation. Do not change files.`, 'review', 'high').catch(() => ({ issues: [] }))))
    const issues = reviews.flatMap((r) => r.issues || [])
    say(`polish: ${issues.length} issue(s) (${issues.filter((i) => i.severity !== 'minor').length} blocker/major)`)
    const groups = {}
    for (const i of issues) (groups[normOwner(i.owner)] ||= []).push(`[${i.severity}] ${i.screen}: ${i.problem} -> ${i.fix}`)
    state.polishSkipped = []
    await pool(Object.keys(groups), 3, (o) => minutesUntil(A.shipBy) < 35 ? (state.polishSkipped.push(o), save(), Promise.resolve({ status: 'skipped' })) : codex(`polish-fix-${o}`, `Polish fixes. Edit ONLY files owned by ${o === 'shared' ? 'no feature (NibDesign, NibContracts, Nib/App, docs; keep changes backward compatible)' : o + ' (docs/forge-spec.json)'}; other jobs edit other files and run UI tests from this worktree right now, so keep the code compiling at every moment and never run git add/commit/stash/checkout/reset.
Findings (fix ALL of them, including minor):
${groups[o].join('\n')}
This is the last change before shipping tonight: keep every fix low-risk and visual/copy-level (tokens, spacing, wording, states, accessibility labels) — no behaviour or navigation changes; if a finding would need a risky change, skip it and say so.
Fix each at the root per docs/DESIGN.md with NibDesign tokens/components; keep copy consistent with the rest of the app; update/add unit tests for changed behaviour and check them with \`${TOOLS} targets ${DIR} "<the owner's test targets>"\`. Do not run UI tests. Answer status "ok", details = what you changed per finding.`, 'result', 'high').catch((e) => ({ status: 'blocked', details: [e.message] })))
    say(`polish: committed ${await commit('QA: final polish')}`)
    state.design = { done: true, issues: issues.length, majors: issues.filter((i) => i.severity !== 'minor').length }; save()
  })()

  await Promise.all([areasP, polishP])
  say(`areas + polish: committed ${await commit('QA: UI test coverage for every area')}`)
  const failures = Object.values(state.fixed).flatMap((f) => f.remaining || [])
  state.remainingFailures = failures; save()
  const notCovered = Object.entries(state.fixed).filter(([k, f]) => f.notCovered || !(state.written[k]?.tests)).map(([k]) => k)
  if (notCovered.length) say(`not covered by UI tests: ${notCovered.join(', ')}`)

  // ---------------------------------------------------------------- polish pass 2: real screenshots of the fixed app
  if (!state.design2?.done) {
    const shots2 = `${ROOT}-design/qa-final-2`
    const n2 = () => { try { return fs.readdirSync(shots2).filter((f) => f.endsWith('.png')).length } catch { return 0 } }
    for (const name of ['capture-p2', 'capture-p2b']) {
      if (n2() > 0 || minutesUntil(A.shipBy) < 300) break
      const c = await codex(name, capturePrompt(shots2), 'result', 'high', 2).catch((e) => ({ status: 'blocked', details: [e.message] }))
      say(`polish 2: ${name} ${c.status}, ${n2()} screenshot(s)`)
    }
    if (n2() > 0) {
      const reviews = await Promise.all(LENSES.map(([key, lens]) => codex(`polish2-review-${key}`, `Second polish review of the real Nib app, after today's functional fixes and a first polish pass. Read docs/DESIGN.md fully, open EVERY screenshot in ${shots2} with your image viewer (index.md explains each). Lens: ${lens}
Report every real, visible problem — blocker, major AND minor — each with screen, owner (feature id from docs/forge-spec.json whose files draw it, or "shared"), problem and the concrete fix. Check each against the current code. No speculation. Do not change files.`, 'review', 'high').catch(() => ({ issues: [] }))))
      const issues = reviews.flatMap((r) => r.issues || [])
      say(`polish 2: ${issues.length} issue(s) (${issues.filter((i) => i.severity !== 'minor').length} blocker/major)`)
      const groups = {}
      for (const i of issues) (groups[normOwner(i.owner)] ||= []).push(`[${i.severity}] ${i.screen}: ${i.problem} -> ${i.fix}`)
      await pool(Object.keys(groups), 4, (o) => codex(`polish2-fix-${o}`, `Polish fixes (pass 2). Edit ONLY files owned by ${o === 'shared' ? 'no feature (NibDesign, NibContracts, Nib/App, docs; keep changes backward compatible)' : o + ' (docs/forge-spec.json)'}; other jobs edit other files right now, so keep the code compiling at every moment and never run git add/commit/stash/checkout/reset.
Findings (fix ALL of them, including minor):
${groups[o].join('\n')}
Fix each at the root per docs/DESIGN.md with NibDesign tokens/components; keep copy consistent; update/add unit tests for changed behaviour and check them with \`${TOOLS} targets ${DIR} "<the owner's test targets>"\`. Do not run UI tests. Answer status "ok", details = what you changed per finding.`, 'result', 'high').catch((e) => ({ status: 'blocked', details: [e.message] })))
      say(`polish 2: committed ${await commit('QA: polish pass 2 (real screenshots)')}`)
      state.design2 = { done: true, issues: issues.length, majors: issues.filter((i) => i.severity !== 'minor').length }
    } else { say('polish 2: no screenshots captured'); state.design2 = { done: true, noScreenshots: true } }
    save()
  }

  // ---------------------------------------------------------------- final verify (unit suite + critical UI classes)
  if (!state.finalVerify2) {
    const inkIds = ((state.written.ink && state.written.ink.failures) || []).map((f) => qual(state.written.ink, f)).filter((t) => /^NibUITests\/\w+UITests\/\w+$/.test(t))
    const canvasSrc = fs.readFileSync(`${DIR}/NibUITests/CanvasUITests.swift`, 'utf8')
    const canvasIds = [...canvasSrc.matchAll(/func (test\w*(?:Zoom|Pinch|DoubleTap|Fit|Pan|Keyboard|Rotation)\w*)\s*\(/g)].map((m) => `NibUITests/CanvasUITests/${m[1]}`)
    const latest = (k) => ((state.fixed[k] && state.fixed[k].remaining) || []).map((f) => String(f.test || '')).filter((t) => /^NibUITests\/\w+UITests\/\w+$/.test(t))
    const inkNow = latest('ink').length ? latest('ink') : inkIds
    const laneA = ['NibUITests/SmokeUITests', ...inkNow].join(' ')   // smoke + every pen/ink test still failing at the last verify
    const selIds = ((state.written.selection && state.fixed.selection && state.fixed.selection.remaining) || []).map((f) => String(f.test || '')).filter((t) => /^NibUITests\/SelectionUITests\/\w*(Lasso|Move|Resize|Delete|Copy|Paste|Duplicate|Undo)\w*$/.test(t)).slice(0, 15)
    const selNow = latest('selection').slice(0, 25)
    const laneB = [...new Set([...canvasIds, ...latest('canvas'), ...selNow])].join(' ')   // canvas zoom/pan/keyboard + canvas/selection still failing
    const v = await codex('final-verify-2', `Final verification before shipping (the unit/package suite runs on GitHub CI during the ship step, so do NOT run the local full build). The critical UI regression set — start BOTH runs at the same time in the background (they take the two simulator lanes): (A) smoke + the pen/ink tests still failing at the last verify: ${UIRUN(laneA, 3)} and (B) the canvas zoom/pan/keyboard tests plus canvas/selection tests still failing: \`${TOOLS} uitest ${DIR} "${laneB}"\` (log and result bundle named after the first identifiers, under ${LOGS}). Report by ${A.shipBy} at the latest. For each failure decide test-wrong (fix the test) or app-wrong (fix the app at the root if it is small and safe, otherwise report it), commit fixes on ${BR} (${TRAILER_RULE}). Before running, make sure the worktree compiles (no half-finished edits are expected now; if the UI build fails, fix the compile error at the root). Fix anything the recent fixes or the polish broke (test wrong per spec -> fix the test; app wrong -> fix the app at the root), within the UI-run budget, and commit on ${BR} (${TRAILER_RULE}). Answer status "green"/"red", file "NibUITests", tests/passed/failed, failures (test = "<Class>/<testMethod>", owner, problem, evidence), notes.`, 'uiwrite', 'high', 3).catch((e) => ({ status: 'blocked', failures: [], notes: e.message }))
    say(`final verify: ${v.status} — UI ${v.passed}/${v.tests} pass`)
    state.finalVerify2 = v; save()
  }

  // ---------------------------------------------------------------- ship
  say(`ship: CI on ${BR}, merge to main, main CI, IPA, tag ${A.rcTag}`)
  const ship = await codex('ship', `Ship the QA campaign.
Time is short (midnight deadline), so main's CI is the single gate — do not run a separate CI pass on ${BR}.
1. In ${DIR}: commit anything left (${TRAILER_RULE}), python3 Scripts/lint.py must pass, git push origin ${BR}.
2. In the main clone ${ROOT} (it may have unrelated uncommitted tool files under tools/ — leave them alone): git fetch origin && git checkout -q main && git pull -q --ff-only origin main && git merge --no-ff origin/${BR} -m "QA campaign: functional fixes and polish" (${TRAILER_RULE}) && git push origin main.
3. Watch main's CI for that SHA (gh run list --repo ${REPO} --branch main; gh run watch <id> --repo ${REPO} --exit-status --interval 60). If red: read the failing log (gh run view <id> --log-failed), fix the root cause on main (commit, push) and watch again — max 3 rounds; never skip or weaken tests. Download the IPA from the green run: gh run download <id> --repo ${REPO} -n Nib-unsigned-ipa -D ${ROOT}-dist/<short-sha>/ (also the no-extensions variant if the run has it).
4. Tag: git tag ${A.rcTag} <sha> && git push origin ${A.rcTag}.
Answer status "green", sha, runUrl, details = IPA path(s).`, 'result', 'high')
  say(`ship: ${ship.status} ${ship.sha || ''} ${ship.runUrl || ''}`)
  state.ship = ship; save()
  return { areas: state.fixed, remainingFailures: (state.remainingFailures || []).length, design: state.design, ship }
}

main().then((r) => { say('DONE ' + JSON.stringify(r)); process.exit(0) }, (e) => { say('FAILED ' + e.message); process.exit(1) })
