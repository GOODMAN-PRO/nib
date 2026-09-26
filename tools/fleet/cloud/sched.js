#!/usr/bin/env node
// Next jobs for the cloud fleet. Reads tools/fleet/fleet-launch-args.json (run collect-state.js first)
// and /home/user/nib-orchestration/inflight.txt (one feature id per line = has a running agent).
// Prints JSON {implReady, ci, review, fix, blocked, done}.
const fs = require('fs')
const a = JSON.parse(fs.readFileSync('/home/user/nib/tools/fleet/fleet-launch-args.json', 'utf8'))
let inflight = new Set()
try { inflight = new Set(fs.readFileSync('/home/user/nib-orchestration/inflight.txt', 'utf8').split(/\s+/).filter(Boolean)) } catch {}
const S = a.state, by = {}
a.features.forEach((f) => { by[f.id] = f })
const green = (id) => S[id] && S[id].ci === 'green'
const out = { implReady: [], ci: [], review: [], fix: [], waitingDeps: [], done: [], inflight: [...inflight] }
for (const f of a.features.slice().sort((x, y) => (x.priority || 9) - (y.priority || 9))) {
  if (inflight.has(f.id)) continue
  const s = S[f.id] || {}
  if (s.ci === 'green' && (s.review === 'pass' || s.fixed === 'green')) { out.done.push(f.id); continue }
  if (!s.impl) {
    const deps = (f.dependsOn || []).filter((d) => by[d])
    if (deps.every(green)) out.implReady.push(f.id); else out.waitingDeps.push(`${f.id}<-${deps.filter((d) => !green(d)).join(',')}`)
    continue
  }
  if (s.review && !s.fixed && s.review === 'needs-fix') { out.fix.push(f.id); continue }
  if (s.fixed && s.fixed !== 'green') { out.fix.push(f.id); continue }
  if (s.ci !== 'green') { out.ci.push(f.id); continue }
  if (!s.review) { out.review.push(f.id); continue }
}
console.log(JSON.stringify(out, null, 1))
