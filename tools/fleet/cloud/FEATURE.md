# Per-feature job instructions (Nib fleet, cloud edition)

Read /home/user/nib-orchestration/COMMON.md first and follow it. Your prompt names ONE feature id (Fxxx) and ONE job: IMPLEMENT, CI, REVIEW or FIX.

Paths:
- Worktree for feature Fxxx: /home/user/Nib-wt/Fxxx (branch feat/Fxxx). Work ONLY there. If the worktree is missing: `git -C /home/user/nib worktree add /home/user/Nib-wt/Fxxx -B feat/Fxxx origin/feat/Fxxx` (or `main` if that branch does not exist).
- Feature spec: the entry for Fxxx in docs/forge-spec.json. Its "description" is the full spec and acceptance criteria; "inventory" lists GoodNotes parity items (look each up in docs/FEATURES.md); "files" + "tests" are the ONLY files the feature may create/edit ("owned files"); "dependsOn" lists dependency features.
- State markers: /home/user/nib/tools/fleet/state/Fxxx.review.json and Fxxx.fixed.json (write them exactly as described below; never commit them from the worktree).
- CI logs: /home/user/Nib-ci-logs (never inside a repo).
- Before starting any job: `git -C /home/user/Nib-wt/Fxxx fetch origin` and, if `origin/feat/Fxxx` is ahead of the local branch, fast-forward to it. If the worktree has uncommitted work or the branch head is a commit titled `WIP ...`, an earlier agent was interrupted: CONTINUE from that work (read it, keep what is good, finish and fix the rest), don't restart.
- If `git merge-base --is-ancestor origin/main HEAD` fails, merge origin/main in first (`git merge --no-edit origin/main`); conflicts outside your owned files are resolved by taking origin/main's version.
- Contracts-v2: if docs/CONTRACTS.md on origin/main has a "contracts-v2 changelog" section, and docs/DESIGN_SYSTEM.md a "NibDesign v2 additions" section, use those APIs instead of inventing workarounds, and when you touch code that carries a workaround listed there for this feature, replace it with the v2 API.

## IMPLEMENT
You are building ONE feature of "Nib" (native iPadOS/iOS, GoodNotes 6 parity + JS plugins + bring-your-own-AI + "water droplet" liquid UI). You cannot compile locally, so be meticulous about Swift/Apple API correctness.
1. If the feature has dependencies: `git merge --no-edit feat/<dep> ...` for each dependency listed in dependsOn (use origin/feat/<dep>). Their files are theirs: read and use them, never edit them.
2. Read before coding: docs/ARCHITECTURE.md (module rules, command conventions, registries, UI extension points, UI rules), docs/CONTRACTS.md ("How to use this file" + the contract types you use; the real source is NibKit/Sources/NibContracts), the existing stub in your module; for layer ui/fullstack also docs/DESIGN.md (binding look + droplet physics + per-screen specs + Slop checklist) and NibKit/Sources/NibDesign (use ONLY its tokens, components and liquid modifiers; never hard-code colours/fonts/radii/springs); for plugin/AI/bridge/relay features also docs/PLUGIN_API.md and docs/AI.md.
3. Build it COMPLETELY: every acceptance criterion and parity item, as production code. Every user-facing action is a registered Command with a JSON schema (the "plugins and AI can modify anything" guarantee); reads go through the query API; undo/redo works. No TODOs, no fatalError/placeholder bodies, no fake data paths. UI: premium, calm, canvas-first, exactly per DESIGN.md; droplet behaviour where DESIGN.md prescribes it and never near live ink; VoiceOver labels, Dynamic Type, 44 pt targets, Reduce Motion/Transparency, iPad pointer + keyboard shortcuts; iPad and iPhone size classes. Real XCTest cases for the non-trivial logic in your owned test files.
4. If the contracts lack something, work around it INSIDE your files and list it under contractGaps. Never edit shared files.
5. Commit: `git add -A && git commit -m "Fxxx: <feature name>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.
6. Then run the CI loop (COMMON.md) on feat/Fxxx until green (max 8 rounds), editing only owned files; errors in a dependency's file or a shared contract get worked around in your own files and reported.
Return: status (green/red/blocked), files written, command ids registered, contract gaps, anything from the spec not done, last run URL.

## CI
Get feat/Fxxx green: run the COMMON.md CI loop (max 8 rounds), editing only owned files. Return status, rounds, run URL, remaining errors, contract gaps.

## REVIEW
Independent code review (you did not write this) of feature Fxxx on branch feat/Fxxx (CI is green). Check strictly:
1. Every acceptance criterion and parity item is actually implemented (not stubbed, faked, TODO or fatalError).
2. Ownership: `git diff --name-only origin/main...HEAD` contains only files owned by Fxxx or by its (transitive) dependency features. Any other file is a blocker.
3. Contracts: conforms to NibContracts (commands registered with schemas + undo, queries, events, registries); the plugins-and-AI-can-modify-anything guarantee holds for everything this feature lets a user do. Workarounds that the contracts-v2 changelog now covers count as a major.
4. Correctness: logic bugs, data-loss risks, threading (@MainActor), memory/perf on large notebooks, error handling at trust boundaries (files, network, plugins, AI).
5. (ui/fullstack) Design: follows docs/DESIGN.md + the Slop checklist, only NibDesign tokens/components/liquid modifiers, accessibility (VoiceOver, Dynamic Type, 44 pt, Reduce Motion), iPad + iPhone layouts.
6. Tests are meaningful and cover the risky logic.
Write the verdict JSON `{"verdict": "pass"|"needs-fix", "issues": [{"severity": "blocker"|"major"|"minor", "where": "...", "problem": "...", "fix": "..."}]}` to /home/user/nib/tools/fleet/state/Fxxx.review.json. Verdict "pass" only if there are no blockers or majors. Concrete fixes only. Do not change code. Return the verdict and issue counts.

## FIX
Apply the review in /home/user/nib/tools/fleet/state/Fxxx.review.json to feat/Fxxx. An earlier fix attempt may have been interrupted: check git status, stash and a head `WIP` commit before re-applying anything. Fix every blocker and major; minors when cheap. Only edit owned files (if the review flags files outside them, revert those: `git checkout origin/main -- <file>`). Then run the COMMON.md CI loop (max 6 rounds). Finally write `{"status": "green"|"red"|"blocked", "runUrl": "..."}` to /home/user/nib/tools/fleet/state/Fxxx.fixed.json. Return status, run URL, remaining errors, contract gaps.
