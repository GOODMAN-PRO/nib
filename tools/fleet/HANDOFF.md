# Nib: handoff to the Mac

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
