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
const minutesUntil = (hhmm) => { const [h, m] = hhmm.split(':').map(Number); const t = new Date(); t.setHours(h, m, 0, 0); return (t - Date.now()) / 60000 }
const STATE = `${LOGS}/qa-state.json`
const state = fs.existsSync(STATE) ? JSON.parse(fs.readFileSync(STATE, 'utf8')) : {}
const save = () => fs.writeFileSync(STATE, JSON.stringify(state, null, 1))

const PREAMBLE = `You are GPT-6 Astra running as Codex CLI (non-interactive, full access) on the user's Mac, doing one step of the Nib build (native iPadOS/iOS note app, GoodNotes-class; docs/DESIGN.md, docs/ARCHITECTURE.md, docs/CONTRACTS.md and docs/forge-spec.json are binding). Repo worktree: ${DIR} (branch ${BR}). Long commands (builds, simulator UI tests) take a long time: use long timeouts or background + poll. Never skip, weaken, comment out or delete tests to get green; a test may only change when it contradicts the spec, and then say so explicitly. Work autonomously to completion, then answer with the JSON object the output schema asks for.\n\n`
const BUILD = `Unit/package build: \`${TOOLS} full ${DIR}\` (waits for a build slot; 30-90 min; log ${LOGS}/local-integration-full.log, exit code in the .exit file).`
const uiTag = (filter) => (filter || 'all').replace(/NibUITests\//g, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/-$/, '').slice(0, 60)
const UIRUN = (filter, budget) => `UI tests: \`${TOOLS} uitest ${DIR}${filter ? ` "${filter}"` : ''}\` (xcodegen + XCUITest on a dedicated iPad simulator; ONE UI run at a time machine-wide, so it may queue behind other jobs; log ${LOGS}/local-integration-uitest-${uiTag(filter)}.log, exit code in the matching .exit file, result bundle ${LOGS}/ui-${uiTag(filter)}.xcresult — read failures with \`xcrun xcresulttool get test-results tests --path ${LOGS}/ui-${uiTag(filter)}.xcresult\`). Every UI test file compiles into one target: if the run fails to COMPILE because of another file, report that in notes instead of editing it.${budget ? ` HARD BUDGET: this job may start at most ${budget} UI run(s) (the tool refuses more), so make each one count — write and review the whole file before running.` : ''}`

async function codex (name, prompt, schema, effort = 'high', uiMax = 0) {
  const id = `${TAG}-${name}`
  const pfile = `${PROMPTS}/${id}.md`
  fs.writeFileSync(pfile, PREAMBLE + prompt)
  const env = { ...process.env, NIB_UI_MAX: uiMax ? String(uiMax) : '' }
  let { stdout } = await sh(CX, ['run', id, DIR, pfile, schema, effort], { maxBuffer: 1 << 24, env })
  while (stdout.startsWith('RUNNING')) ({ stdout } = await sh(CX, ['wait', id], { maxBuffer: 1 << 24 }).catch((e) => ({ stdout: e.stdout || 'CODEX_FAILED wait error' })))
  if (stdout.startsWith('RESULT ')) return JSON.parse(stdout.slice(7))
  throw new Error(`${name}: ${stdout.trim().slice(0, 300)}`)
}
const git = (...a) => sh('git', ['-C', DIR, ...a]).then((r) => r.stdout.trim())
async function commit (msg) {
  if (!(await git('status', '--porcelain'))) return null
  await git('add', '-A'); await git('commit', '-q', '-m', msg, '-m', TRAILER)
  return git('log', '-1', '--format=%h')
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

  // ---------------------------------------------------------------- write
  state.written ||= {}
  const areas = state.matrix.areas.filter((a) => !state.written[a.key])
  if (areas.length) {
    say(`write: UI tests for ${areas.map((a) => a.key).join(', ')}`)
    await pool(areas, A.maxWriters || 4, async (a) => {
      const cls = a.key.replace(/(^|_)(\w)/g, (_, __, c) => c.toUpperCase()) + 'UITests'
      const exists = fs.existsSync(`${DIR}/NibUITests/${cls}.swift`)
      const r = await codex(`write-${a.key}`, `${exists ? `NibUITests/${cls}.swift already exists from an earlier, interrupted writer: keep its good tests, add whatever controls below are still missing, delete any placeholder test that only XCTFails for "DEVICE COVERAGE" (device-only checks go in notes instead), then run it. ` : ''}Write the XCUITest coverage for area "${a.title}" (key ${a.key}). File: NibUITests/${cls}.swift (only this file; use the helpers in NibUITests/Support and the "nib.qa.state" probe; do not edit app code, other test files or project.yml — other writers work in parallel).
Cover EVERY control in this list with at least one test that performs the real user action (tap the button / menu item, perform the gesture, draw the stroke) and asserts the observable expected result (state probe fields, visible UI, undo/redo where applicable). Pen/ink tools must actually draw strokes and check stroke counts; zoom must check the zoom value changes and is bounded; buttons must check their effect, not just that they exist.
Controls:\n${JSON.stringify(a.controls)}
Things XCUITest on the simulator genuinely cannot do (Apple Pencil pressure/tilt/hover/squeeze/double-tap, camera, VoiceOver audio, real hardware keyboards beyond typeKey) are NOT tests: list them in notes as device-only; never add XCTFail placeholders for them.
Time box: about 60 minutes in total. Then run ${UIRUN(`NibUITests/${cls}`, 2)} If a test fails because the TEST is wrong (wrong identifier, timing, wrong expectation vs the spec), fix the test. If it fails because the APP is wrong (button missing/not wired, wrong behaviour, crash, zoom/pen broken), keep the test as the spec says and report it as a failure with owner (feature id from docs/forge-spec.json whose files implement it, or "shared"), problem and evidence (assertion message / screenshot attachment name). Do not commit. Answer status "green" (all pass) or "red", file, tests, passed, failed, failures, notes.`, 'uiwrite', 'high', 2)
      say(`  write ${a.key}: ${r.status} ${r.passed ?? '?'}/${r.tests ?? '?'} pass, ${r.failed ?? '?'} fail`)
      state.written[a.key] = r; save()
    })
    say(`write: committed ${await commit('QA: UI test coverage for every area')}`)
  }

  // ---------------------------------------------------------------- early library fix lane (qa-fix worktree) -> integration
  if (A.earlyFix && !state.earlyFixMerged) {
    say('fix: waiting for the early library fix lane')
    let ef; let { stdout } = await sh(CX, ['wait', A.earlyFix.job], { maxBuffer: 1 << 24 }).catch((e) => ({ stdout: e.stdout || '' }))
    while (stdout.startsWith('RUNNING')) ({ stdout } = await sh(CX, ['wait', A.earlyFix.job], { maxBuffer: 1 << 24 }).catch((e) => ({ stdout: e.stdout || '' })))
    if (stdout.startsWith('RESULT ')) ef = JSON.parse(stdout.slice(7))
    say(`fix: early lane ${ef ? `${ef.status} ${ef.passed}/${ef.tests} pass, ${ef.failed} fail` : 'gave no result'}`)
    const ahead = await git('rev-list', '--count', `HEAD..${A.earlyFix.branch}`).catch(() => '0')
    if (Number(ahead) > 0) { await git('merge', '--no-ff', '-q', A.earlyFix.branch, '-m', 'QA: library fixes (early lane)', '-m', TRAILER); say(`fix: merged ${A.earlyFix.branch} (${ahead} commit(s))`) }
    const lf = `${A.earlyFix.wt}/NibUITests/LibraryUITests.swift`
    if (fs.existsSync(lf)) fs.copyFileSync(lf, `${DIR}/NibUITests/LibraryUITests.swift`)
    if (ef) state.written.library = ef
    state.earlyFixMerged = true; save()
    say(`fix: committed ${await commit('QA: library UI tests after the early fix lane')}`)
  }

  // ---------------------------------------------------------------- fix loop
  state.rounds ||= []
  const qual = (r, f) => { const t = String(f.test || ''); if (t.includes('/')) return t.startsWith('NibUITests/') ? t : `NibUITests/${t}`; const c = (r.file || '').match(/(\w+UITests)\.swift/)?.[1]; return c ? `NibUITests/${c}/${t}` : t }
  let failures = Object.values(state.written).flatMap((r) => (r.failures || []).map((f) => ({ ...f, test: qual(r, f) })))
  for (let round = state.rounds.length + 1; round <= (A.fixRounds || 4); round++) {
    if (!failures.length) break
    if (minutesUntil(A.shipBy) < 150 || minutesUntil(A.designBy) < 110) { say(`fix: stopping before round ${round} — polish phase starts by ${A.designBy}, ship by ${A.shipBy}`); break }
    const groups = {}
    for (const f of failures) (groups[normOwner(f.owner)] ||= []).push(`${f.test}: ${f.problem} [evidence: ${f.evidence}]`)
    say(`fix round ${round}: ${failures.length} failure(s) across ${Object.keys(groups).join(', ')}`)
    await Promise.allSettled(Object.keys(groups).map((o) => codex(`fix-${round}-${o}`, `Fix these functional bugs found by the UI tests (round ${round}). Edit ONLY files owned by ${o === 'shared' ? 'no feature (Nib/App shell, NibDesign, NibContracts, NibUITests/Support, project.yml; keep changes backward compatible)' : o + ' (docs/forge-spec.json files/tests)'}; other Codex jobs are fixing other owners' files right now; do NOT run git commit/stash/checkout/reset or any build/test.
Failures:\n${groups[o].join('\n')}
Find the root cause in the app (button not wired to its command, command failing, gesture not reaching the canvas, zoom limits, pen/stroke pipeline, state not updating, crash) and fix it per the spec. Add/extend unit tests in the owner's test files for the logic you fix. Only if a UI test itself is wrong per the spec may you correct that test (say which and why). Answer status "ok", details = root cause + fix per failure.`, 'result', 'high')))
    say(`fix round ${round}: committed ${await commit(`QA fix round ${round}`)}`)
    const ids = [...new Set(failures.map((f) => String(f.test || '')).filter((t) => /^NibUITests\/\w+UITests\/\w+$/.test(t)))]
    const classes = [...new Set(Object.values(state.written).map((r) => (r.file || '').match(/(\w+UITests)\.swift/)?.[1]).filter(Boolean))]
    const target = ids.length && ids.length === failures.length ? ids.join(' ') : classes.map((c) => `NibUITests/${c}`).join(' ')
    const v = await codex(`verify-${round}`, `Verify fix round ${round}. 1) ${BUILD} — if it fails, fix the regressions at the root and repeat until LOCAL BUILD OK, committing on ${BR} (${TRAILER_RULE}). 2) ${UIRUN(target, 3)} (the UI tests that failed before this round${ids.length && ids.length === failures.length ? '' : ' — the failing classes'}; identifiers are NibUITests/<Class>/<testMethod>). For every failing UI test decide: test wrong per spec -> fix the test and rerun it; app wrong -> report it (do not fix app code in this step). Commit test fixes on ${BR}. Answer status "green" (unit build OK and every UI test passes) or "red", file "NibUITests", tests/passed/failed for the UI suite, failures (test = "<Class>/<testMethod>", owner = feature id or "shared", problem, evidence), notes.`, 'uiwrite', 'high', 3)
    say(`verify round ${round}: ${v.status} — UI ${v.passed}/${v.tests} pass, ${v.failed} fail`)
    state.rounds.push({ round, failures: failures.length, after: v.failed, status: v.status }); save()
    failures = (v.failures || []).map((f) => ({ ...f, test: qual(v, f) }))
    if (v.status === 'green') break
  }
  state.remainingFailures = failures; save()

  // ---------------------------------------------------------------- polish (mandatory, time-boxed)
  if (!state.design && minutesUntil(A.shipBy) > 150) {
    say('polish: capture + 4-lens review + fix everything (incl. minor)')
    const shots = `${ROOT}-design/qa-final`
    await codex('capture', `Capture the real app for the final polish review. Build and run the app on the iPad Pro 13-inch simulator (and an iPhone 17 Pro) with the "-NibUITestFixture" launch argument; drive states with the NibUITests helpers, the MCP bridge or simctl, and verify each state through the nib.qa.state probe before capturing. Save PNGs to ${shots}/<n>-<screen>-<light|dark>-<orientation>.png for: library grid/list/folder, library search, new menu, new-notebook sheet, canvas with the palette docked left/top/bottom/right, options bar, each tool's options (pen, highlighter, eraser, lasso, shapes, text), lasso selection with object menu, page sidebar, outline, document search with matches, AI assistant, plugin manager, settings (2-3 screens), export sheet, whiteboard, text document, study session, presentation mode, tabs with 3 documents, an empty folder, an error/empty state — light and dark, iPad portrait + landscape, plus iPhone portrait + landscape for library, canvas and search. Write ${shots}/index.md. Delete ${ROOT}-dd-sim afterwards. Answer status "ok", details = file list.`, 'result', 'medium')
    const LENSES = [
      ['glass', 'MATERIAL + LIQUID GLASS: DESIGN.md §2, §7, §10 and the glass lines of §16 — rims, refraction, doubled edges, shading, glass bodies behind every floating control, dark-mode legibility, iOS 26 glass vs fallbacks.'],
      ['layout', 'LAYOUT + TYPOGRAPHY + COLOUR: DESIGN.md §3-§6 and §14 per screen — spacing grid, alignment, radii, type scale, truncation, colour tokens light AND dark, overlaps between chrome/panels and page content or ink, iPad vs iPhone, portrait vs landscape.'],
      ['slop', 'SLOP + ACCESSIBILITY: every line of DESIGN.md §16 and §12 — 44 pt targets, Dynamic Type, contrast, VoiceOver labels, Reduce Motion/Transparency; anything templated, generic, cluttered, duplicated or stray.'],
      ['ux', 'UX + COPY + STATES: the product feel — empty states, error and confirmation messages, button and menu wording (consistent, specific, sentence case, no jargon), loading/progress states, disabled states, selection feedback, consistency of icons and terminology across screens, anything that feels unfinished.'],
    ]
    const reviews = await Promise.all(LENSES.map(([key, lens]) => codex(`polish-review-${key}`, `Final polish review of the real Nib app. Read docs/DESIGN.md fully, open EVERY screenshot in ${shots} (index.md explains each). Lens: ${lens}
Report every real, visible problem — blocker, major AND minor polish — each with screen, owner (feature id from docs/forge-spec.json whose files draw it, or "shared"), problem and the concrete fix. No speculation. Do not change files.`, 'review', 'high').catch(() => ({ issues: [] }))))
    const issues = reviews.flatMap((r) => r.issues || [])
    say(`polish: ${issues.length} issue(s) (${issues.filter((i) => i.severity !== 'minor').length} blocker/major)`)
    if (issues.length) {
      const groups = {}
      for (const i of issues) (groups[normOwner(i.owner)] ||= []).push(`[${i.severity}] ${i.screen}: ${i.problem} -> ${i.fix}`)
      await Promise.allSettled(Object.keys(groups).map((o) => codex(`polish-fix-${o}`, `Polish fixes. Edit ONLY files owned by ${o === 'shared' ? 'no feature (NibDesign, NibContracts, Nib/App, docs)' : o}; others edit other owners' files now; no git commit/stash/checkout/reset, no builds or tests.\nFindings (fix ALL of them, including minor):\n${groups[o].join('\n')}\nFix each at the root per docs/DESIGN.md with NibDesign tokens/components; keep copy consistent with the rest of the app; update/add tests for changed behaviour. Answer status "ok", details.`, 'result', 'high')))
      say(`polish: committed ${await commit('QA: final polish')}`)
      const v = await codex('polish-verify', `${BUILD} — fix regressions until LOCAL BUILD OK. Then ${UIRUN('', 2)} (the WHOLE NibUITests suite, every area); fix any UI test the polish changes broke (test wrong per spec -> fix the test; app wrong -> fix the app at the root). Repeat until both are green, committing on ${BR} (${TRAILER_RULE}). Answer status "green"/"red", file "NibUITests", tests/passed/failed, failures, notes.`, 'uiwrite', 'high', 2)
      say(`polish verify: ${v.status} — UI ${v.passed}/${v.tests}`)
      state.remainingFailures = v.failures || state.remainingFailures
    }
    state.design = { issues: issues.length }; save()
  }

  // ---------------------------------------------------------------- ship
  say(`ship: CI on ${BR}, merge to main, main CI, IPA, tag ${A.rcTag}`)
  const ship = await codex('ship', `Ship the QA campaign.
1. In ${DIR}: git push origin ${BR}; run and watch the full CI on ${BR} (gh workflow run ios.yml --repo ${REPO} --ref ${BR}; find the workflow_dispatch run for HEAD; gh run watch <id> --repo ${REPO} --exit-status --interval 60). If red, fix root causes on ${BR} (${BUILD}) and repeat (max 4 rounds).
2. When green: in the main clone ${ROOT}: git fetch origin && git checkout -q main && git pull -q --ff-only origin main && git merge --no-ff origin/${BR} -m "QA campaign: every control tested, bugs fixed" (${TRAILER_RULE}) && python3 Scripts/lint.py && git push origin main.
3. Watch main's CI for that SHA (test + ipa) to green (fix on main if red, max 3 rounds). Download the IPA: gh run download <id> --repo ${REPO} -n Nib-unsigned-ipa -D ${ROOT}-dist/<short-sha>/.
4. Tag: git tag ${A.rcTag} <sha> && git push origin ${A.rcTag}.
Answer status "green", sha, runUrl, details = IPA path(s).`, 'result', 'high')
  say(`ship: ${ship.status} ${ship.sha || ''} ${ship.runUrl || ''}`)
  state.ship = ship; save()
  return { rounds: state.rounds, remainingFailures: (state.remainingFailures || []).length, design: state.design, ship }
}

main().then((r) => { say('DONE ' + JSON.stringify(r)); process.exit(0) }, (e) => { say('FAILED ' + e.message); process.exit(1) })
