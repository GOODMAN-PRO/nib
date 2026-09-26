# Rules every Nib agent follows (read fully)

Repo: GOODMAN-PRO/nib (public). Main clone: /home/user/nib. You run in a Linux cloud container: there is NO Swift/Xcode here, so GitHub Actions (macos-26, Xcode 26.6) is the only compiler. Be meticulous about Swift/Apple API correctness: Swift 5 language mode, iOS 26 SDK, deployment target iOS 17, every iOS 26+ API (Liquid Glass: glassEffect, GlassEffectContainer, Glass, glassEffectID/Union, etc.) behind `#available(iOS 26, *)`, `public` access across modules.

Standing rules:
- Commit messages end with a blank line then exactly: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- Never disable/skip tests, comment code out, use `#if false`, or stub features away to get green.
- `gh` works for repo operations (`gh run list/watch/view --repo GOODMAN-PRO/nib`). `gh auth status` reports the token invalid; ignore that, the repo calls work. Bash `sleep` in the foreground may be blocked: poll with `gh run watch <id> --repo GOODMAN-PRO/nib --exit-status --interval 45` (Bash timeout 600000; call again if it times out) or `timeout 60 tail -f /dev/null` as a wait.
- Before pushing a branch: `git fetch origin <branch> main` then push with `git push -u origin <branch>`. Retry network failures up to 4 times with backoff.

CI loop (for "get branch X green"):
1. Commit everything and push. Note the SHA.
2. Find the run: `gh run list --repo GOODMAN-PRO/nib --branch <branch> --json databaseId,headSha,status,conclusion,url --limit 10`; poll until the run for your SHA appears. Only 5 macOS jobs run at once across the whole fleet, so 10-30 min queue waits are normal. Never give up while queued.
3. `gh run watch <id> --repo GOODMAN-PRO/nib --exit-status --interval 45`.
4. On failure: `gh run view <id> --repo GOODMAN-PRO/nib --log-failed > /home/user/Nib-ci-logs/<branch-with-slashes-as-_>-<round>.log` and grep for `error:`, `** BUILD FAILED`, `** TEST FAILED`, `failed (`, `fatal`, `::error`. Fix root causes, go to 1. Branches other than feat/* run the full `test` job (all package tests + lint + conformance) and the `ipa` job. Feature branches (feat/Fxxx) run only that feature's lint, tests and app build.
