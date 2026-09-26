#!/usr/bin/env node
// Derive per-feature build state from git + GitHub Actions + marker files, then write the complete
// args for tools/fleet/fleet.workflow.js. Fresh runs skip every finished stage, so nothing is redone
// (the Workflow replay cache is NOT reliable for this concurrent script — always relaunch fresh).
//
// Usage (from anywhere):
//   node tools/fleet/collect-state.js                 # Windows defaults (G:\Projects\...)
//   NIB_ROOT=~/Projects/Nib NIB_WT=~/Projects/Nib-wt NIB_STATE=~/Projects/Nib-state NIB_LOGS=~/Projects/Nib-ci-logs \
//   NIB_LOCAL_BUILD=1 NIB_MAX_IMPL=3 node tools/fleet/collect-state.js   # Mac
// Output: tools/fleet/fleet-launch-args.json  -> pass its contents as the Workflow `args`.
const { execSync } = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')

const expand = (p) => p && p.replace(/^~(?=$|\/)/, os.homedir())
const isWin = process.platform === 'win32'
const ROOT = expand(process.env.NIB_ROOT) || (isWin ? 'G:\\Projects\\Nib' : path.resolve(__dirname, '../..'))
const WT = expand(process.env.NIB_WT) || (isWin ? 'G:\\Projects\\Nib-wt' : path.join(path.dirname(ROOT), 'Nib-wt'))
const STATE = expand(process.env.NIB_STATE) || (isWin ? 'G:\\Projects\\Nib-state' : path.join(path.dirname(ROOT), 'Nib-state'))
const LOGS = expand(process.env.NIB_LOGS) || (isWin ? 'G:\\Projects\\Nib-ci-logs' : path.join(path.dirname(ROOT), 'Nib-ci-logs'))
const REPO = 'GOODMAN-PRO/nib'
const sh = (cmd, cwd) => { try { return execSync(cmd, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() } catch { return '' } }

sh('git fetch origin --quiet', ROOT)
const spec = JSON.parse(fs.readFileSync(path.join(ROOT, 'docs', 'forge-spec.json'), 'utf8'))
// Page through the runs API by owner/repo path: `gh run list --limit >100` follows next-links that use numeric
// repository ids, which the cloud egress proxy rejects.
const runs = []
for (let page = 1; page <= 10; page++) {
  const batch = JSON.parse(sh(`gh api "repos/${REPO}/actions/runs?per_page=100&page=${page}" --jq "[.workflow_runs[] | {headSha: .head_sha, status, conclusion}]"`) || '[]')
  runs.push(...batch)
  if (batch.length < 100) break
}
const bySha = {}
for (const r of runs) if (!bySha[r.headSha] || r.status === 'completed') bySha[r.headSha] = r
const marker = (id, kind) => { try { return JSON.parse(fs.readFileSync(path.join(STATE, `${id}.${kind}.json`), 'utf8')) } catch { return null } }

const state = {}
const report = { impl: 0, ciGreen: 0, ciRed: [], reviewed: 0, fixed: 0, fullyDone: [], missingWorktree: [], dirty: [] }
for (const f of spec.features) {
  const wt = path.join(WT, f.id)
  if (!fs.existsSync(wt)) { report.missingWorktree.push(f.id); continue }
  const impl = sh('git log main..HEAD --format=%s', wt).split('\n').some((s) => s.startsWith(`${f.id}:`))
  if (sh('git status --porcelain', wt)) report.dirty.push(f.id)
  const head = sh('git rev-parse HEAD', wt)
  const run = bySha[head]
  const pushed = head && head === sh(`git rev-parse origin/feat/${f.id}`, wt)
  const ci = impl && pushed && run && run.status === 'completed' ? (run.conclusion === 'success' ? 'green' : 'red') : null
  const review = marker(f.id, 'review')
  const fixed = marker(f.id, 'fixed')
  const s = {}
  if (impl) { s.impl = 1; report.impl++ }
  if (ci) { s.ci = ci; if (ci === 'green') report.ciGreen++; else report.ciRed.push(f.id) }
  if (review && review.verdict) { s.review = review.verdict; report.reviewed++ }
  if (fixed && fixed.status) { s.fixed = fixed.status; report.fixed++ }
  if (s.ci === 'green' && (s.review === 'pass' || s.fixed === 'green')) report.fullyDone.push(f.id)
  if (Object.keys(s).length) state[f.id] = s
}

const features = spec.features.map((f) => ({ id: f.id, name: f.name, module: f.module, layer: f.layer, complexity: f.complexity, priority: f.priority, dependsOn: f.dependsOn || [], inventory: f.inventory || [] }))
const args = {
  paths: { root: ROOT, worktrees: WT, logs: LOGS, state: STATE, sep: isWin ? '\\' : '/' },
  localBuild: process.env.NIB_LOCAL_BUILD === '1',
  maxImpl: Number(process.env.NIB_MAX_IMPL) || 5,
  state,
  features,
}
fs.writeFileSync(path.join(__dirname, 'fleet-launch-args.json'), JSON.stringify(args))
report.fullyDoneCount = report.fullyDone.length
console.log(JSON.stringify(report, null, 1))
console.log(`wrote ${path.join(__dirname, 'fleet-launch-args.json')}`)
