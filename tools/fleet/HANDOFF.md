# Nib: handoff (any machine)

## 0. Read first: where Nib stands (4 Nov 2026, Windows session)

**Shipped.** Nib 1.0.1 (tag `nib-1.0.1`, main `9c41914`, 4 Oct 2026): all 111 features merged, main CI green (package tests + unsigned IPA). The QA campaign (`tools/fleet/qa-campaign.mjs`, run by Codex on the Mac) wrote 10 XCUITest classes (`NibUITests/`, 508 tests) and fixed hundreds of bugs, but ended with the UI lane red for 8 of the 10 classes; the 60 `qa-ci/*` branches are its disposable CI snapshots.

**This session** ran on Windows (no Swift toolchain; GitHub Actions is the only compiler) with Codex CLI (`gpt-6-astra`, the user's own `~/.codex/config.toml`) doing the Swift work and Claude reviewing. Work lands on `integration` first, then fast-forwards to `main`. Done on `integration`:
- `tools/fleet/codex-job.sh` + `tools/fleet/schemas/`: cross-platform Codex job runner (the Mac's `nib-codex.sh` and its per-machine schema folder are superseded). `tools/qa/ui-results.py`: parses one `ui.yml` run into PASS/FAIL per class with owners and a `FAIL Class/test: message` list (the Mac-only `ui-ci.sh` tail, for any platform).
- `ios.yml` runs `Scripts/a11y_lint.py` and `Scripts/extract_strings.py --check --sources` (warnings only; closes the F095 request, issue #1). The a11y lint no longer flags a lowercase view reference as an icon-only label; the repo lint is at 0 warnings.
- contracts-v2.5: `PrintRendererDescriptor` + `ContentRegistries.printRenderers`, `NibPrint` tokens, F103 registers its text-document renderer and F067's `print.present` routes to it (both `docs/contract-requests` resolved and removed). Implemented by Codex, independently reviewed.
- `docs/SHIPPING_POLISH.md` copy table applied (sentence case, translations carried over); the applied width-presets patch file removed.
- String catalog refreshed from the sources (1477 new keys, 27 stale) and the 20,622 missing translations produced by Claude agents (per-locale QA + redo; `tools/fleet/i18n.workflow.js`, `i18n-check.py`); `extract_strings.py --check --sources` passes; `--module-catalogs` filled NibDesign's catalog (172 keys x 14 locales; closes issue #2).
- Codex audit of every follow-up in `tools/fleet/cloud/ledger.md` and `followups-local.md` against the code: all done except three, fixed on `work/*` branches and merged: assistant full-screen through F017's panel host (F085), `.dropletDockable` replays a dock requested during an in-flight reshape (NibDesign), folder tiles wrap long names (NibDesign). All three passed independent review and are merged.
- UI lane baseline on main (`gh workflow run ui.yml --ref main`, run 41817269947) -> `tools/qa/ui-results.py` -> per-class Codex fix jobs (`tools/fleet/ui-fix.workflow.js`) -> review -> merge -> re-run the affected classes. IN PROGRESS: the baseline found 149 failures in the first 5 classes; a Codex triage (`G:\Projects\Nib-ci-logs\codex-ui-triage.json`) clustered them into about ten root causes, mostly test-support (a palette drag that displaces the simulator window, keyboard-chord delivery, selectors, allowances) plus one app bug (F008 preset slot hit targets); fixes run on `work/ui-support` and `work/ui-presets`.

**How to continue (any machine):**
1. `git fetch origin && git checkout integration` (or merge `origin/main` into it). Worktrees: `git worktree add ../Nib-wt/<name> -b work/<name> integration`.
2. Codex job: write a prompt file (style of the prompts in `G:\Projects\Nib-prompts`: role, task, follow-through policy, verification loop, output contract), then `bash tools/fleet/codex-job.sh run <name> <worktree> <prompt> <schema: result|review|audit> [effort]`, and `wait <name>` while it prints RUNNING. The Workflow scripts in `tools/fleet/*.workflow.js` wrap this with Claude forwarder + reviewer agents (Sonnet).
3. CI: `gh workflow run ios.yml --repo GOODMAN-PRO/nib --ref integration` (package tests + IPA) and `gh workflow run ui.yml --repo GOODMAN-PRO/nib --ref integration -f only="NibUITests/<Class> ..." -f label=<name>` (UI lane; `only` empty = all 10 classes), then `python tools/qa/ui-results.py <run-id>`. Runs are cold when the DerivedData cache has expired (7 days unused): 30-45 min per job.
4. Ship: `git checkout main && git merge --ff-only integration && git push origin main` (main's push runs the full CI and saves the cache); tag `nib-1.0.x`; the unsigned IPA is the `Nib-unsigned-ipa` artifact of main's run.

**Left for the user to decide:** delete the 60 `qa-ci/*` and 10 merged `v2/*` remote branches; remove the 111 stale `../Nib-wt/F###` worktrees (646 MB, all merged); the study-set window keeps FeatKeyboard's global Command-P (F067's key covers notebooks, whiteboards and text documents).

## 0a. Earlier: cloud session results (26-30 Sept 2026)

A cloud session continued the build after this handoff was written, then stopped on the weekly usage limit. This section supersedes the state in §3; the rest of the file still applies.

**Done on `main`** (full CI green: package tests + unsigned IPA):
- **Design v2** (`marker/design-v2` = 0bce516, plus v2.1 d319c8c): Liquid Glass redo (thin light-directional rim, no double rim on iOS 26), the water dock engine for the palette (`.dropletDockable`, snap, fling, meniscus, held bead), `NibReflow` for library drag reorder (with a 180 ms combine dwell), and ~20 new components and 72 symbols.
- **Contracts v2** (`marker/contracts-v2` = 1741651): 368 gaps triaged (220 resolved, 67 rejected, 81 deferred). This fixes `DocTransaction.revert` and adds the chrome overlay extension point, floating host and inking signal. See `docs/CONTRACTS.md` › "contracts-v2 changelog" and the `[v2: …]` notes in `contract-gaps.md`.
- **Spec v2** (f7da15b): the command catalogue matches what features register; unbuilt features' specs point at v2 APIs.
- **Mockup v2**, republished at https://claude.ai/artifact/XQKSP4QSMTHuwFZRPxTLMm.
- **Tags:** the cloud proxy blocked tag pushes. Create the real tags locally:
  `git tag design-v2 0bce516 && git tag contracts-v2 1741651 && git push origin design-v2 contracts-v2` (then delete the `marker/*` branches).

**Fleet state:**
- 58 of 111 features written, 52 CI-green, 45 fully done (green + reviewed + fixed).
- CI red: F006 and F064, both interrupted mid-implementation.

**Interrupted by the usage limit.** Each job's worktree state is pushed as a `WIP …` commit or was already on its branch; relaunch the same job and it continues from there.
- **IMPLEMENT:** F002, F006, F048, F050, F064, F066, F103.
- **FIX:** F021, F023, F031, F091. Their reviews are in `tools/fleet/state/*.review.json`.
- **V2ADOPT:** F015 (⌘Z window-undo fallback) and F022 (Move Pages reads `params["pages"]`, multi-page PDF cut merge).
- **REVIEW:** F013, F065 and F102 still need an independent review.
- **Main-side branches** (not merged):
  - `v2/contracts2`: PanelIDs for the study panels and Move Pages, plus CommandIDs constants for new ids.
  - `v2/shell`: app shell; key commands honour `docKinds`, ⌘Z fallback, key-window tracking, status-bar forwarding, user-fonts entitlement. It had not started coding.

**Open follow-ups** are listed in `tools/fleet/cloud/ledger.md` under "Follow-ups" and the later bullets: spec pass 2 items, V2ADOPT for the remaining built features, and NibDesign and contract gaps.

**How the cloud session ran the fleet.** A Linux container allows only 2 concurrent Workflow agents, so the cloud session used background agents with per-feature job prompts. Those prompts are in `tools/fleet/cloud/FEATURE.md` (jobs IMPLEMENT, CI, REVIEW, FIX, V2ADOPT) and `COMMON.md`. `fleet.workflow.js` still works locally: run `collect-state.js` with local paths first. `collect-state.js` now pages GitHub runs through the owner/repo API path, which works everywhere.

**Commit trailer:** now two lines, as one paragraph: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` then `Claude-Session: https://claude.ai/code/session_01GpZ3Q12FGHi43JsYU8aD5F`.

This file is for the Claude Code session that continues the build on the user's Mac. The previous session ran on Windows, which has no Swift toolchain, so every compile went through GitHub Actions. On a Mac with Xcode 26.x you can compile and run locally. That makes each fix loop much faster, and you can install straight onto the user's iPad.

## What Nib is

A native iPadOS/iOS note-taking app with the full GoodNotes 6 feature set (493 items in `docs/FEATURES.md`). It adds three things GoodNotes doesn't have:
- JS plugins that can read and change anything (`docs/PLUGIN_API.md`).
- Bring-your-own AI with tool access to every command (`docs/AI.md`).
- An MCP/HTTP bridge, so an outside agent can drive the app.

The look is locked as "Clear Water": floating chrome that behaves like water droplets. The spec is `docs/DESIGN.md`. The code is the `NibKit/Sources/NibDesign` module, whose API is described in `docs/DESIGN_SYSTEM.md`. The interactive mockup is `design/mockup.html`, published at https://claude.ai/artifact/XQKSP4QSMTHuwFZRPxTLMm; republish it with the Artifact tool's `url` after you update it.

Architecture:
- `docs/ARCHITECTURE.md`: the architecture as a whole.
- `docs/CONTRACTS.md`: the shared contracts in `NibKit/Sources/NibContracts`.
- `docs/forge-spec.json`: the 111 features, each with the files it exclusively owns.

Every user action is a registered Command, which is why plugins and the AI can change anything the user can.

## Standing rules

- Every subagent and workflow agent runs on Opus (`model: 'opus'`).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- The repo is public on GitHub: GOODMAN-PRO/nib.
- CI runs on `macos-26` with Xcode 26.6 pinned.
- The deployment target is iOS 17, in Swift 5 language mode. Every Liquid Glass API goes behind `#available(iOS 26, *)`.
- A feature agent may edit only the files `forge-spec.json` assigns to its feature.

## 1. User's priority requests. Do these first.

The user tried the mockup and asked for these fixes in their own words:

> "fix all the liquid glass things and also the move notebooks when i drag it it doesnt affect the other notebooks and also when i drag the tool bar i want it to snap into position and when im holding it i want to feel like its a bead of water that im dragging"

### 1a. Liquid Glass audit

1. Open the **DesignGallery** in the iOS 26 simulator, or better on the iPad: Settings › Developer › Design Gallery, in `NibKit/Sources/NibDesign/Gallery`.
2. Go through every liquid component against `docs/DESIGN.md`: the materials (Clear, Deep, Tinted and Bead), merging and splitting in `GlassEffectContainer`, the bud-off popovers, the selection bead, refraction and the rim.
3. "All the liquid glass things" is vague, so ask the user which effects look wrong before you change the spec. Show them simulator screenshots.
4. The fixes go into NibDesign on `main`.
5. Tag `design-v2`, then merge `main` into every `feat/*` branch.

### 1b. The toolbar docks and feels like a bead of water

This touches three places:
- `docs/DESIGN.md` (Droplet physics).
- NibDesign's droplet drag primitive (`.droplet` / DropletPhysics).
- F016 FeatToolbar, which is already built and green, but needs this added.

**Snapping.** Define dock targets for the floating tool palette: top-centre, bottom-centre, and the left and right edges (vertical palette), plus any others the user wants.
- On release, the palette snaps magnetically to the nearest dock within a capture radius. It settles with the `snap` spring (0.50 s response, 0.80 damping) and one plip haptic.
- A fling projects the palette's path along its release velocity and snaps to the dock it would reach.
- The chosen dock persists. Make it a command (e.g. `toolbar.dock`), so plugins and the AI can move the palette too.

**While it's held, it's a bead of water:**
- It lifts slightly: about 1.03 scale plus a stronger rim highlight.
- It follows the finger with the `follow` spring (0.085 s / 1.0), so it lags a little.
- It stretches along the velocity vector with its volume preserved, and the stretch starts from the grab point.
- Its surface wobbles subtly when it slows down.
- It bends the page underneath (refraction).
- As it nears a dock, it grows a meniscus neck towards that dock, then fuses and pinches as it snaps.

It must read as water, not jelly. Update `design/mockup.html` so the user can feel it, then republish.

### 1c. Other notebooks move when you drag one

This goes in F019 FeatLibraryUI, which isn't built yet, so put it in its spec before an agent builds it. It also needs a reflow helper in NibDesign.

- While a notebook card is dragged, its neighbours slide aside with a spring and open a gap at the insertion point. They reflow live as the card moves, like home-screen icons, but with water-like easing.
- Dropping inserts the card at the gap and records an undoable `library.move` / reorder command.
- Dragging onto a folder still fills the folder with a film of water and absorbs the notebook (already in the spec).

Update the mockup and republish.

## 2. Setting up on the Mac

```bash
git clone https://github.com/GOODMAN-PRO/nib.git ~/Projects/Nib   # or pull if already cloned
cd ~/Projects/Nib
brew install xcodegen gh node    # if missing; also: gh auth login
bash tools/fleet/setup-mac.sh
```

`setup-mac.sh` does the following:
- Creates `~/Projects/Nib-wt/<FeatureID>` worktrees, from `origin/feat/<id>` where that branch exists and from `main` otherwise.
- Copies the review/fix markers from `tools/fleet/state` to `~/Projects/Nib-state`.
- Runs `collect-state.js`, which writes `tools/fleet/fleet-launch-args.json`.

To try the app: run `xcodegen generate`, open `Nib.xcodeproj`, then pick the iPad simulator or the user's iPad. A free Apple ID works for personal signing, and it expires every 7 days.

## 3. State when the handoff was written (25 Sept 2026)

| | Count |
|---|---|
| Features written | 48 of 111. F064 and F065 also have partial WIP commits (subject `WIP …`), which the agent will continue. |
| Feature CI green | 42 |
| Fully done (green, reviewed, fixes applied) | 17: F003 F004 F005 F008 F009 F010 F011 F014 F015 F016 F018 F020 F024 F027 F033 F040 F042 |
| Reviewed, fixes pending | about 21. Their review JSON is in `tools/fleet/state/<id>.review.json`. |
| CI red | F001, F012, F028, F031 |
| Not started | 61 |

F031 is red because of a contract bug: `DocTransaction.revert` doesn't undo an item move made in the same step as an attach.

**Shared-contract debt.** Feature agents reported 368 contract gaps across 46 features (`tools/fleet/contract-gaps.md`), each worked around inside the feature's own files. Before building the remaining 61 features, do a **contracts-v2 pass**:
1. Group the gaps.
2. Add the missing extension points, services and registries to NibContracts on `main`. The chrome extension point for floating HUDs, for example, blocked F052.
3. Fix the `DocTransaction.revert` bug.
4. Update `docs/CONTRACTS.md` and tag `contracts-v2`.
5. Merge `main` into every `feat/*` branch.
6. Let the fix and CI agents remove their workarounds.

This stops the next 61 agents from inventing more workarounds.

## 4. Continuing the build

The build is orchestrated by `tools/fleet/fleet.workflow.js`, a Workflow tool script. Per feature it runs: implement → CI green → independent review → fix → CI green. Features start once their dependencies are green, and at most `maxImpl` implementers run at once.

It is state-driven. `args.state` comes from `collect-state.js`, built from git, GitHub Actions and the marker files, and the script skips every stage already done. **Always launch it fresh. Never use `resumeFromRunId`.** The replay cache breaks when agent order changes, and in the Windows runs it re-implemented finished features.

```bash
cd ~/Projects/Nib
NIB_LOCAL_BUILD=1 NIB_MAX_IMPL=3 NIB_ROOT=$PWD NIB_WT=~/Projects/Nib-wt NIB_STATE=~/Projects/Nib-state node tools/fleet/collect-state.js
```

Then call the Workflow tool with `scriptPath: tools/fleet/fleet.workflow.js` and `args` set to the JSON contents of `tools/fleet/fleet-launch-args.json`. With `localBuild: true`, agents compile and test locally before pushing, and CI stays the gate. Keep `maxImpl` at about 3 on a laptop, because parallel xcodebuilds are heavy.

- **Usage limits:** when one hits, agents return nothing and the script's circuit breaker halts. After the reset, run `collect-state.js` again and launch fresh.
- **Review and fix records:** each review writes `<state>/<id>.review.json`, and each fix writes `<id>.fixed.json`. Copy them back into `tools/fleet/state/` and commit now and then, so the record survives across machines.

## 5. After every feature is green: integration

This hasn't been written yet. Author it as a workflow when the time comes:
1. Merge `feat/*` into `main` in dependency order. Files are exclusively owned, so conflicts should be rare. Dependent branches already contain their dependencies' commits.
2. Run the full `main` CI (all 102 package test bundles plus the app archive), with a fix loop.
3. Run the integration and on-device smoke tests from F111.
4. Get an unsigned IPA from CI, or install directly from Xcode on the Mac.
5. Do a final design review of real screens against `docs/DESIGN.md` and the Slop checklist, on device.
