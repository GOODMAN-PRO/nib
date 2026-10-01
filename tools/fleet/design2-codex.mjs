#!/usr/bin/env node
// Design pass 2 + ship, run entirely by Codex (GPT-6 Astra) — no Claude agents.
// Claude plans and launches this; every step (review, fix, build, capture, ship) is a `codex exec` job through
// ~/Projects/Nib-tools/nib-codex.sh. Commits are plain git. Progress goes to stdout (one line per event).
//
// Usage: node tools/fleet/design2-codex.mjs <args.json>
//   args: { root, wt, logs, tools, codexTool, prompts, shots, known: [..], testFix, rounds }
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import fs from 'node:fs'

const sh = promisify(execFile)
const A = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const { root: ROOT, wt: DIR, logs: LOGS, tools: TOOLS, codexTool: CX, prompts: PROMPTS } = A
const ROUNDS = A.rounds || 2
const REPO = 'GOODMAN-PRO/nib'
const BR = 'integration'
const TRAILER = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01GpZ3Q12FGHi43JsYU8aD5F'
const TRAILER_RULE = `every commit message ends with a blank line then exactly these two adjacent lines:\n${TRAILER}`
const say = (m) => console.log(`[${new Date().toTimeString().slice(0, 8)}] ${m}`)

const PREAMBLE = `You are GPT-6 Astra running as Codex CLI (non-interactive, full access) on the user's Mac, doing one step of the Nib build (native iPadOS/iOS note app; docs/DESIGN.md is the binding design spec). Long commands (builds, simulators, gh run watch) take a long time: use long timeouts or background + poll. Never skip, weaken or delete tests. Work autonomously to completion, then answer with the JSON object the output schema asks for.\n\n`

async function codex (name, prompt, schema, effort = 'high', cwd = DIR) {
  const pfile = `${PROMPTS}/${A.tag || 'd2x'}-${name}.md`
  fs.writeFileSync(pfile, PREAMBLE + prompt)
  let { stdout } = await sh(CX, ['run', `${A.tag || 'd2x'}-${name}`, cwd, pfile, schema, effort], { maxBuffer: 1 << 24 })
  while (stdout.startsWith('RUNNING')) ({ stdout } = await sh(CX, ['wait', `${A.tag || 'd2x'}-${name}`], { maxBuffer: 1 << 24 }).catch((e) => ({ stdout: e.stdout || 'CODEX_FAILED wait error' })))
  if (stdout.startsWith('RESULT ')) return JSON.parse(stdout.slice(7))
  throw new Error(`${name}: ${stdout.trim().slice(0, 300)}`)
}
const git = (...a) => sh('git', ['-C', DIR, ...a]).then((r) => r.stdout.trim())
async function commit (msg) {
  if (!(await git('status', '--porcelain'))) return null
  await git('add', '-A')
  await git('commit', '-q', '-m', msg, '-m', TRAILER)
  return git('log', '-1', '--format=%h')
}
const normOwner = (o) => (/F\d{3}/.exec(o || '') || ['shared'])[0]

const OWNERS = 'Owner = the feature id (exactly "Fxxx") whose "files"/"tests" in docs/forge-spec.json contain the view code to change, or exactly "shared" for NibDesign/NibContracts/Nib/App/docs.'
const BUILD_RULE = `Build ONLY through \`${TOOLS} full ${DIR}\` (waits for a machine-wide build slot; 30-90 min; log ${LOGS}/local-integration-full.log, exit code in the matching .exit file).`
const SIM = `Use the iPad Pro 13-inch simulator on the newest iOS 26 runtime (xcrun simctl list devices available), plus an iPhone 17 Pro simulator for compact layouts. Build the app for the simulator from ${DIR} (xcodegen generate; xcodebuild build -project Nib.xcodeproj -scheme Nib -configuration Debug -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath ${ROOT}-dd-sim; ad-hoc sign for Keychain access if needed), install and launch it, and drive it through the MCP bridge (tools/smoke/run.mjs or curl to F090's endpoint) to reach states. Delete ${ROOT}-dd-sim when you are done (the disk is nearly full).`
const LENSES = [
  ['glass', 'MATERIAL + LIQUID GLASS: DESIGN.md §2, §7, §10 and the glass lines of §16; rims, refraction, a glass body behind every floating control (bars, capsules, the library chrome), merged/split glass, bud-offs; iOS 26 glass vs fallbacks.'],
  ['layout', 'LAYOUT + TYPOGRAPHY + COLOUR: DESIGN.md §3-§6 and §14 per-screen specs: spacing grid, metrics, radii, type scale, truncation, colour tokens in light AND dark (including placeholder/empty states), overlaps between panels/bars and page content, iPad vs iPhone.'],
  ['slop', 'SLOP + ACCESSIBILITY: every line of the DESIGN.md §16 Slop checklist and §12 (44 pt targets, Dynamic Type, contrast, labels, Reduce Motion/Transparency); duplicated or stray UI, anything templated or generic.'],
]

async function main () {
  let shots = A.shots
  const history = []
  for (let round = 1; round <= ROUNDS; round++) {
    const known = round === 1 ? (A.known || []) : []
    const preset = round === 1 && A.issues ? [{ issues: A.issues }] : null
    if (!preset) say(`round ${round}: reviewing ${shots}`)
    const reviews = preset || await Promise.all(LENSES.map(([key, lens]) => codex(`review-${round}-${key}`, `Design review (pass 2, round ${round}) of the real Nib app. Read docs/DESIGN.md fully, then open EVERY screenshot in ${shots} with your image viewing tool (index.md / manifest.json explain each). Lens: ${lens}
${known.length ? 'Already-known leftovers: confirm each against the screenshots and include it if still visible:\n' + known.map((k) => '- ' + k).join('\n') + '\n' : ''}For each real problem you can SEE: screen/file, the DESIGN.md rule, owner (${OWNERS} — find the view code in ${DIR}) and the concrete code fix. Severity blocker / major / minor. No speculation. Do not change any file.`, 'review', 'high')))
    const issues = reviews.flatMap((r) => r.issues || []).filter((i) => i.severity !== 'minor')
    history.push({ round, issues: issues.length, blockers: issues.filter((i) => i.severity === 'blocker').length })
    say(`round ${round}: ${issues.length} blocker/major (${history.at(-1).blockers} blockers)`)
    const groups = {}
    for (const i of issues) (groups[normOwner(i.owner)] ||= []).push(`[${i.severity}] ${i.screen}: ${i.problem} -> ${i.fix}`)
    if (round === 1 && A.testFix) (groups.shared ||= []).push(A.testFix)
    if (!Object.keys(groups).length) break

    say(`round ${round}: fixing ${Object.keys(groups).join(', ')}`)
    const fixes = await Promise.allSettled(Object.keys(groups).map((o) => codex(`fix-${round}-${o}`, `Design fixes, pass 2 round ${round}. Worktree ${DIR} (branch ${BR}) contains ALL Nib features merged. Other Codex jobs are fixing OTHER owners' files at the same time: edit ONLY files owned by ${o === 'shared' ? 'no feature (NibDesign, NibContracts, Nib/App, docs; keep changes backward compatible)' : o + ' (docs/forge-spec.json)'}; do NOT run git commit/stash/checkout/reset or any build.
Findings:\n${groups[o].join('\n')}
Fix each at the root with NibDesign tokens/components/liquid modifiers per docs/DESIGN.md; update or add tests for changed behaviour. Answer status "ok", details = what you changed per finding.`, 'result', 'high')))
    fixes.forEach((f, k) => say(`  fix ${Object.keys(groups)[k]}: ${f.status === 'fulfilled' ? f.value.status : 'FAILED ' + f.reason.message}`))
    say(`round ${round}: committed ${await commit(`Design pass 2, round ${round}`)}`)

    const b = await codex(`build-${round}`, `${BUILD_RULE} Run it on ${DIR}. If it fails, fix the regressions at the root and repeat until "LOCAL BUILD OK", committing on ${BR} (${TRAILER_RULE}). Answer status "green" or "red".`, 'result', 'high')
    say(`round ${round}: full local build ${b.status}`)
    if (b.status !== 'green') return { stage: 'build', history, build: b }

    const next = `${ROOT}-design/${A.pass || 'pass2'}-r${round}`
    const cap = await codex(`capture-${round}`, `Re-capture for verification: the screens the fixes touched (owners ${Object.keys(groups).join(', ')}), plus the library (grid, list, folder), the document canvas with the palette docked left and top, the AI assistant panel and one sheet. ${SIM}
Save PNGs (xcrun simctl io <udid> screenshot) to ${next}/<n>-<screen>-<light|dark>-<orientation>.png in light AND dark, iPad portrait AND landscape, plus the iPhone 17 Pro for the library and canvas. Write ${next}/index.md listing each file, screen, state and how you reached it. Answer status "ok", details = the file list.`, 'result', 'medium')
    say(`round ${round}: capture ${cap.status} (${(cap.details || []).length} files)`)
    if (cap.status === 'blocked') break
    shots = next
  }

  say('ship: CI on integration, merge to main, main CI, IPA, tag rc2')
  const ship = await codex('ship', `Ship design pass 2.
1. In ${DIR}: git push origin ${BR}; run and watch the full CI on ${BR} (gh workflow run ios.yml --repo ${REPO} --ref ${BR}; find the workflow_dispatch run for HEAD; gh run watch <id> --repo ${REPO} --exit-status --interval 60). If red, fix root causes on ${BR} (${BUILD_RULE}) and repeat (max 4 rounds).
2. When green: in the main clone ${ROOT}: git fetch origin && git checkout -q main && git pull -q --ff-only origin main && git merge --no-ff origin/${BR} -m "${A.passName || 'Design pass 2'}" (${TRAILER_RULE}) && python3 Scripts/lint.py && git push origin main.
3. Watch main's CI for that SHA (test + ipa) to green (fix on main if red, max 3 rounds). Download the IPA: gh run download <id> --repo ${REPO} -n Nib-unsigned-ipa -D ${ROOT}-dist/<short-sha>/.
4. Tag: git tag ${A.rcTag || 'nib-1.0-rc2'} <sha> && git push origin ${A.rcTag || 'nib-1.0-rc2'}.
5. Device: xcrun devicectl list devices; if an iPad/iPhone is connected and trusted and a signing identity exists, build/install with automatic signing and launch; otherwise report the IPA path.
Answer status "green", sha, runUrl, details = IPA path(s) and the device result.`, 'result', 'high')
  say(`ship: ${ship.status} ${ship.sha || ''} ${ship.runUrl || ''}`)
  return { history, ship }
}

main().then((r) => { say('DONE ' + JSON.stringify(r)); process.exit(0) }, (e) => { say('FAILED ' + e.message); process.exit(1) })
