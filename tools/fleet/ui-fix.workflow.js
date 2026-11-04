// UI fix loop: args {root, worktrees, logs, prompts, base, resultsDir: <folder of tools/qa/ui-results.py for one run>, classes: results.json classes with failures}. One Codex job per failing class in <worktrees>/ui-<class> (branch work/ui-<class> from <base>), review, fix rounds; merge the branches into <base> afterwards and re-run ui.yml for those classes.
export const meta = {
  name: 'nib-ui-fix',
  description: 'For each failing UI test class: Codex (gpt-6-astra) fixes the app at the root in its own worktree from the CI failure list and screenshots, an independent Claude review checks it, Codex applies review fixes (max 2 rounds)',
  phases: [
    { title: 'Codex', detail: 'one fix job per failing UI test class, each in worktree Nib-wt/ui-<class> on branch work/ui-<class>' },
    { title: 'Review', detail: 'independent review of each branch diff against integration' },
    { title: 'Fix', detail: 'Codex applies review findings; re-review; at most 2 rounds' },
  ],
}
// args: { root, worktrees, logs, prompts, base, resultsDir, classes: [{class, owners, failures: [{test, message}], shots: [relative paths], infrastructureError}] }
const A = args
const ROOT = A.root, WT = A.worktrees, LOGS = A.logs, PROMPTS = A.prompts, BASE = A.base, RES = A.resultsDir
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

const slug = (cls) => cls.replace(/UITests$/, '').toLowerCase()
const forwarder = (name, wt, branch, promptFile, schema, effort, promptText) => `You are a thin forwarder for one Codex CLI job. Do not solve the task yourself and do not inspect the repository beyond these steps.
0. Make sure the worktree exists: run in Bash: test -d ${wt} || git -C ${ROOT} worktree add -b ${branch} ${wt} ${BASE}
${promptText ? `1. Create the prompt file ${promptFile} with EXACTLY the text between the markers (use Bash: cat > '${promptFile}' <<'NIBPROMPT' ... NIBPROMPT ; the markers themselves are not part of the file):
PROMPT-BEGIN
${promptText}
PROMPT-END
` : `1. The prompt file already exists at ${promptFile}; do not change it.`}
2. Run in Bash: NIB_LOGS=${LOGS} bash ${ROOT}/tools/fleet/codex-job.sh run ${name} ${wt} ${promptFile} ${schema} ${effort}
3. Each call returns within ~90 s. While its output starts with "RUNNING", call again: NIB_LOGS=${LOGS} bash ${ROOT}/tools/fleet/codex-job.sh wait ${name}
   Keep looping as long as it says RUNNING, however many calls it takes (a job can run 20-90 minutes). Never give up while it is RUNNING; never kill it; never start it twice.
4. When it prints "RESULT <json>", return that JSON object as your structured output (same fields). When it prints "CODEX_FAILED ...", return status "blocked" with the full message in notes and empty arrays elsewhere.`

const fixJobPrompt = (c) => `<role>
You are GPT-6 Astra running as Codex CLI (non-interactive) on the user's Windows PC, doing one job of the Nib QA campaign. Nib is a native iPadOS/iOS note-taking app (Swift 5 language mode, Xcode 26.6 / iOS 26 SDK, deployment target iOS 17). There is NO Swift toolchain and no simulator on this PC: GitHub Actions compiles and runs the XCUITests later, so be meticulous about Swift correctness and reason carefully from the test code, the failure messages and the screenshots. docs/ARCHITECTURE.md, docs/CONTRACTS.md, docs/DESIGN.md and docs/forge-spec.json are binding; NibUITests/README.md explains the test helpers, the fixture launch mode and the nib.qa.state probe. Work autonomously to completion, then answer with the JSON object the output schema asks for.
</role>
<task>
Worktree: the current directory (branch work/ui-${slug(c.class)}, based on ${BASE}). Make the failing XCUITests in NibUITests/${c.class}.swift pass by fixing the APP at the root, for real users, not just for the test.
${c.infrastructureError ? 'This class ended with an infrastructure/build error on CI: read ' + RES + '/ui-' + c.class + '/ui.log first (search for "error:", "** TEST FAILED", "** BUILD FAILED", "Testing failed") and fix the root cause (a compile error in the test file or app, a crash at launch, a fixture seed failure).\n' : ''}Failures on CI (test: message; file:line when known):
${c.failures.map((f) => `- ${f.test}: ${f.message}`).join('\n')}
Screenshots from the run (JPEG; open them with your image viewing capability): ${c.shots.length ? c.shots.map((s) => RES + '/' + s).join(', ') : '(none exported)'}
Full xcodebuild log: ${RES}/ui-${c.class}/ui.log (grep the test names to see what happened around each failure).
Feature owners of this area (docs/forge-spec.json "files" tell you which files each owns): ${c.owners.join(', ') || 'see matrix'}.

For each failing test: read the test method and the helpers it uses, find what user action and expected state it exercises, then find the root cause in the app (button not wired to its command, command failing or returning the wrong result, gesture not reaching the canvas, keyboard shortcut not routed, zoom limits, pen/stroke pipeline, state probe not updated, accessibility identifier missing or different, sheet/menu not dismissed, timing that needs a deterministic state change rather than a sleep). Fix it in the owning feature's files, or in the shared app shell / NibDesign / NibUITests/Support helpers when the root cause provably sits there (say exactly which file and why in notes). Add or extend a unit test in the owner's test target for logic you fix.
Only if a test is wrong per the spec (wrong identifier, wrong expectation versus docs/ARCHITECTURE.md, DESIGN.md or the feature's forge-spec description) may you correct that test, and then say so explicitly per test in notes. Never delete a test, never weaken an assertion to make it pass, never add sleeps as the fix, never mark tests skipped.
Other Codex jobs fix OTHER test classes in other worktrees in parallel and all branches merge into ${BASE} afterwards: keep every edit minimal and self-contained, do not reformat files, do not rename shared symbols.
Checks: python Scripts/lint.py (0 errors), python Scripts/a11y_lint.py (no new warnings), python -X utf8 Scripts/extract_strings.py --dry-run (new UI strings use String(localized:)), git diff --check.
Commit on branch work/ui-${slug(c.class)} with one commit: subject "QA: ${slug(c.class)} fixes from the CI baseline", a blank line, then exactly these two lines: "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" and "Codex: gpt-6-astra". Do not push.
</task>
<default_follow_through_policy>
Do not ask questions; decide and record the decision in notes. When a failure cannot be diagnosed from the evidence, say which test and why in notes instead of guessing; a plausible-but-unverified change must be labelled as such.
</default_follow_through_policy>
<verification_loop>
Before you finish: re-read every changed Swift file for compile errors you cannot test here; confirm every symbol you call exists with that signature (grep); run the Python checks; git status clean except your commit.
</verification_loop>
<output_contract>
status "ok" when every failing test has a committed root-cause fix or an explicit explanation, else "blocked". details: one line per failing test (root cause and fix, or why not fixed). filesChanged: paths. commit: short SHA. notes: test-side corrections with their justification, unverified changes, compile risks for the reviewer.
</output_contract>`

const reviewPrompt = (c, round) => `Independent code review (you did not write this) of branch work/ui-${slug(c.class)} in the git worktree ${WT}/ui-${slug(c.class)}. Codex implemented it from the job prompt ${PROMPTS}/ui-${slug(c.class)}.md (read it: it lists the failing XCUITests, the screenshots and the rules). This is review round ${round}.
First run: git -C ${WT}/ui-${slug(c.class)} status --porcelain ; git -C ${WT}/ui-${slug(c.class)} log --oneline ${BASE}..HEAD ; git -C ${WT}/ui-${slug(c.class)} diff ${BASE}...HEAD --stat ; then read the FULL diff and the code it touches (callers, contracts, the test methods named in the prompt).
Check strictly (no Swift compiler here; CI compiles later, so a compile risk is a blocker):
1. For each failing test in the prompt: does the change plausibly make the test pass by fixing the APP behaviour at the root (trace the test's actions and assertions against the changed code)? A test-side edit is acceptable only with an explicit per-test justification in the commit or notes that the test contradicted the spec; a weakened assertion, a deleted test, an added sleep or a skipped test is a blocker.
2. Compile risks: every symbol called exists with that signature in the current sources (grep to confirm), imports, access levels, @MainActor isolation, SwiftUI state rules, optionals, exhaustive switches, test files import what they use.
3. Scope and safety: edits stay minimal and inside the owning feature's files or a justified shared file; no reformatting, no renamed shared symbols, no behaviour regressions for real users (think beyond the test).
4. Run cd ${WT}/ui-${slug(c.class)} && python Scripts/lint.py (0 errors required) and python Scripts/a11y_lint.py (no new warnings versus ${WT}/integration).
5. Commits end with the two trailer lines "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" and "Codex: gpt-6-astra"; git status --porcelain is empty.
Return verdict "pass" only when there is no blocker and no major. Each issue: severity, where (path:line), problem, concrete fix. Do not edit any file.`

const fixPrompt = (c, issues, round) => `<role>
You are GPT-6 Astra running as Codex CLI (non-interactive) on the user's Windows PC (no Swift toolchain; GitHub Actions compiles later), continuing your work on branch work/ui-${slug(c.class)} in the current worktree. Your original job prompt is ${PROMPTS}/ui-${slug(c.class)}.md; its rules still apply.
</role>
<task>
An independent review found these issues (round ${round}). Fix every blocker and major, and the minors when cheap, at the root:
${JSON.stringify(issues, null, 1)}
Then run python Scripts/lint.py (0 errors), python Scripts/a11y_lint.py, python -X utf8 Scripts/extract_strings.py --dry-run, git diff --check. Commit as one new commit "QA: ${slug(c.class)} review fixes (round ${round})" followed by a blank line and exactly these two lines: "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" and "Codex: gpt-6-astra". Do not push. Do not amend earlier commits.
</task>
<output_contract>
status "ok" when every blocker and major is fixed and committed, else "blocked". details: one line per issue. filesChanged: paths. commit: short SHA. notes: remaining risks.
</output_contract>`

const buildOne = async (c) => {
  const name = `ui-${slug(c.class)}`
  const wt = `${WT}/${name}`
  const impl = await agent(forwarder(name, wt, `work/${name}`, `${PROMPTS}/${name}.md`, 'result', 'high', fixJobPrompt(c)), { label: `codex:${name}`, phase: 'Codex', model: M, schema: RESULT })
  if (!impl || impl.status === 'blocked') return { class: c.class, impl, reviews: [], final: 'blocked' }
  const reviews = []
  let round = 1
  let review = await agent(reviewPrompt(c, round), { label: `review:${name}-${round}`, phase: 'Review', model: M, schema: REVIEW })
  reviews.push(review)
  while (review && review.verdict === 'needs-fix' && round <= 2) {
    const serious = review.issues.filter((i) => i.severity !== 'minor')
    if (!serious.length) break
    log(`${name}: review round ${round} found ${serious.length} blocker/major issue(s); Codex fixes`)
    const fix = await agent(forwarder(`${name}-fix-${round}`, wt, `work/${name}`, `${PROMPTS}/${name}-fix-${round}.md`, 'result', 'high', fixPrompt(c, review.issues, round)), { label: `codex:${name}-fix-${round}`, phase: 'Fix', model: M, schema: RESULT })
    reviews.push({ fix })
    if (!fix || fix.status === 'blocked') return { class: c.class, impl, reviews, final: 'fix-blocked' }
    round++
    review = await agent(reviewPrompt(c, round), { label: `review:${name}-${round}`, phase: 'Fix', model: M, schema: REVIEW })
    reviews.push(review)
  }
  const final = review ? (review.verdict === 'pass' || !review.issues.some((i) => i.severity !== 'minor') ? 'reviewed-pass' : 'reviewed-needs-fix') : 'unreviewed'
  return { class: c.class, impl, reviews, final }
}

phase('Codex')
const results = await parallel(A.classes.map((c) => () => buildOne(c)))
log(`ui-fix: ${results.filter(Boolean).map((r) => `${r.class}=${r.final}`).join(', ')}`)
return results
