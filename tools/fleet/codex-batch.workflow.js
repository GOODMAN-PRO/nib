// Codex batch: args {root, worktrees, logs, prompts, base, tasks: [{name, branch, subject}]}; the prompt for task <name> is <prompts>/<name>.md and its worktree <worktrees>/<name> (branch based on <base>). Launch with the Workflow tool: scriptPath = this file.
export const meta = {
  name: 'nib-codex-batch-c',
  description: 'Codex (gpt-6-astra) fixes three audited gaps in parallel worktrees (assistant full-screen via F017 host, dockable flip-back guard, folder tile wrapping), each with an independent Claude review and up to two Codex fix rounds',
  phases: [
    { title: 'Codex', detail: 'three implementation jobs via tools/fleet/codex-job.sh' },
    { title: 'Review', detail: 'independent review of each branch diff against integration' },
    { title: 'Fix', detail: 'Codex applies review findings; re-review; at most 2 rounds' },
  ],
}
const A = args
const ROOT = A.root, WT = A.worktrees, LOGS = A.logs, PROMPTS = A.prompts, BASE = A.base
const M = 'sonnet'
const RESULT = { type: 'object', properties: {
  status: { type: 'string', enum: ['ok', 'green', 'red', 'blocked'] },
  details: { type: 'array', items: { type: 'string' } },
  filesChanged: { type: 'array', items: { type: 'string' } },
  commit: { type: 'string' }, notes: { type: 'string' } }, required: ['status', 'details', 'notes'] }
const REVIEW = { type: 'object', properties: {
  verdict: { type: 'string', enum: ['pass', 'needs-fix'] },
  issues: { type: 'array', items: { type: 'object', properties: {
    severity: { type: 'string', enum: ['blocker', 'major', 'minor'] }, where: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' } },
    required: ['severity', 'where', 'problem', 'fix'] } },
  notes: { type: 'string' } }, required: ['verdict', 'issues', 'notes'] }

const forwarder = (name, wt, promptFile, schema, effort, promptText) => `You are a thin forwarder for one Codex CLI job. Do not solve the task yourself and do not inspect the repository.
${promptText ? `1. Create the prompt file ${promptFile} with EXACTLY the text between the markers (use Bash: cat > '${promptFile}' <<'NIBPROMPT' ... NIBPROMPT ; the markers themselves are not part of the file):
PROMPT-BEGIN
${promptText}
PROMPT-END
` : `1. The prompt file already exists at ${promptFile}; do not change it.`}
2. Run in Bash: NIB_LOGS=${LOGS} bash ${ROOT}/tools/fleet/codex-job.sh run ${name} ${wt} ${promptFile} ${schema} ${effort}
3. Each call returns within ~90 s. While its output starts with "RUNNING", call again: NIB_LOGS=${LOGS} bash ${ROOT}/tools/fleet/codex-job.sh wait ${name}
   Keep looping as long as it says RUNNING, however many calls it takes (a job can run 20-60 minutes). Never give up while it is RUNNING; never kill it; never start it twice.
4. When it prints "RESULT <json>", return that JSON object as your structured output (same fields). When it prints "CODEX_FAILED ...", return status "blocked" with the full message in notes and empty arrays elsewhere.`

const reviewPrompt = (t, round) => `Independent code review (you did not write this) of branch ${t.branch} in the git worktree ${WT}/${t.name}. Codex implemented it from the job prompt ${PROMPTS}/${t.name}.md (read it: its numbered "Deliver" list is the acceptance criteria). This is review round ${round}.
First run: git -C ${WT}/${t.name} status --porcelain ; git -C ${WT}/${t.name} log --oneline ${BASE}..HEAD ; git -C ${WT}/${t.name} diff ${BASE}...HEAD --stat ; then read the FULL diff (git -C ${WT}/${t.name} diff ${BASE}...HEAD) and open the changed files where the diff lacks context. Read the surrounding code the change relies on (callers, the contracts it uses) so you can judge correctness, not just style.
Check strictly (there is no Swift compiler on this PC and CI compiles later, so a compile risk is a blocker):
1. Every numbered deliverable is actually done; nothing stubbed, no TODO, no fatalError placeholder, no test skipped or weakened.
2. Compile risks: every symbol called exists with that signature in the current sources (grep to confirm), imports, access levels across modules, @MainActor isolation, SwiftUI state mutation rules, optionals, exhaustive switches, Swift 5 language mode, iOS 17 deployment target with #available for newer APIs, test files import what they use.
3. Scope: only the files the job prompt allowed were changed (git diff --name-only); any other file is a blocker unless the prompt allowed a justified exception and notes explain it.
4. Behaviour: the change fixes the gap at the root per docs/DESIGN.md / ARCHITECTURE.md as the prompt describes, keeps existing behaviour otherwise, and the tests would fail without the fix.
5. Run cd ${WT}/${t.name} && python Scripts/lint.py (0 errors required) and python Scripts/a11y_lint.py (compare with the same command in ${WT}/integration: no new warnings).
6. One or more commits exist on the branch, each ending with the two trailer lines "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" and "Codex: gpt-6-astra"; git status --porcelain is empty.
Return verdict "pass" only when there is no blocker and no major. Each issue: severity, where (path:line), problem, concrete fix. Do not edit any file.`

const fixPrompt = (t, issues, round) => `<role>
You are GPT-6 Astra running as Codex CLI (non-interactive) on the user's Windows PC (no Swift toolchain; GitHub Actions compiles later, so be meticulous about Swift correctness), continuing your work on branch ${t.branch} in the current worktree. Your original job prompt is the file ${PROMPTS}/${t.name}.md; its file-scope rules still apply.
</role>
<task>
An independent review of your commit(s) found these issues (round ${round}). Fix every blocker and major, and the minors when cheap, at the root:
${JSON.stringify(issues, null, 1)}
Never stub, skip or weaken tests. Then run python Scripts/lint.py (0 errors), python Scripts/a11y_lint.py, python -X utf8 Scripts/extract_strings.py --dry-run, git diff --check. Commit the fixes as one new commit "${t.subject}: review fixes (round ${round})" followed by a blank line and exactly these two lines: "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" and "Codex: gpt-6-astra". Do not push. Do not amend or rewrite earlier commits.
</task>
<output_contract>
status "ok" when every blocker and major is fixed and committed, else "blocked". details: one line per issue. filesChanged: paths. commit: short SHA. notes: remaining risks.
</output_contract>`

const buildOne = async (t) => {
  const impl = await agent(forwarder(t.name, `${WT}/${t.name}`, `${PROMPTS}/${t.name}.md`, 'result', 'high'), { label: `codex:${t.name}`, phase: 'Codex', model: M, schema: RESULT })
  if (!impl || impl.status === 'blocked') return { task: t.name, impl, reviews: [], final: 'blocked' }
  const reviews = []
  let round = 1
  let review = await agent(reviewPrompt(t, round), { label: `review:${t.name}-${round}`, phase: 'Review', model: M, schema: REVIEW })
  reviews.push(review)
  while (review && review.verdict === 'needs-fix' && round <= 2) {
    const serious = review.issues.filter((i) => i.severity !== 'minor')
    if (!serious.length) break
    log(`${t.name}: review round ${round} found ${serious.length} blocker/major issue(s); Codex fixes`)
    const fix = await agent(forwarder(`${t.name}-fix-${round}`, `${WT}/${t.name}`, `${PROMPTS}/${t.name}-fix-${round}.md`, 'result', 'high', fixPrompt(t, review.issues, round)), { label: `codex:${t.name}-fix-${round}`, phase: 'Fix', model: M, schema: RESULT })
    reviews.push({ fix })
    if (!fix || fix.status === 'blocked') return { task: t.name, impl, reviews, final: 'fix-blocked' }
    round++
    review = await agent(reviewPrompt(t, round), { label: `review:${t.name}-${round}`, phase: 'Fix', model: M, schema: REVIEW })
    reviews.push(review)
  }
  const final = review ? (review.verdict === 'pass' || !review.issues.some((i) => i.severity !== 'minor') ? 'reviewed-pass' : 'reviewed-needs-fix') : 'unreviewed'
  return { task: t.name, impl, reviews, final }
}

phase('Codex')
const results = await parallel(A.tasks.map((t) => () => buildOne(t)))
log(`batch C: ${results.filter(Boolean).map((r) => `${r.task}=${r.final}`).join(', ')}`)
return results