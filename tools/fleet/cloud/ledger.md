# Orchestration ledger (session 2026-09-26)

Workflow cap = 2 concurrent (4 CPUs) -> using background Agent calls; me as scheduler.

## v2 pass (main-side), branches v2/*
- v2/contracts  contracts-v2 (C1)            running
- v2/glass      Liquid Glass redo (D1a)       GREEN (run 36221916103, 8b0ef70)
- v2/mockup     mockup.html update            running
- v2/physics    toolbar dock/bead + reflow    GREEN (run 36222900495, 9ecd6b1; includes v2/glass). dstokens asked to merge it.
- v2/dstokens   NibDesign gap tokens/comps    GREEN (run 36223679248, 63aba8b; = glass+physics+tokens)
- main: merged design v2 as 0bce516; main CI 36224117203 GREEN (test+ipa). Tag push is blocked by the cloud proxy (git tag push + API refs both 403) -> branch marker/design-v2 = 0bce516. User must create real tags (design-v2, contracts-v2) from a machine with normal GitHub access.
- F016 dock adoption agent running
Next: integrator merges 4 branches -> main, CI green, tag contracts-v2 + design-v2, merge main into all feat/*; then F016 dock adoption; mockup update + republish.

## Fleet jobs launched
- FIX: F001 F012 F028 (red), F022 F030 F037 (WIP), F017 F026
FIX done green: F012 F017 F022 F026 F028 F029 F030 F032 F034 F035 F036 F037 F038 F039 F041
FIX running: F001 F043 F044 F046 F051 F055 F059 F063 F090. Queue empty.
Blocked on contracts-v2: F031 (revert bug), all IMPLEMENT (61 features incl. F064/F065 WIP)

## Follow-ups (not in any agent yet)
- F009: highlighter live preview treats 3-point curves as passing through the middle point; F030/F031 use control points. Needs a FIX pass after contracts-v2.
- F036: drop-to-attach criterion removed pending undo coalescing fix; restore after contracts-v2 (FIX pass). Update F036 line in contract-gaps.md.
- App target: add user-fonts entitlement (com.apple.developer.user-fonts=[app-usage]) or UIAppSupportsInstalledFonts for F026 T-059/P-083 (owner of Nib/ Info.plist or integration).
- Integration spec edit: add image.pick {source, page?|doc?|ref?|refs?, point?, position?, anchor?, ids?} (edit, user presence, sensitive) to F034 commands in forge-spec.json + ARCHITECTURE §6.5.
- Integration spec edit: ARCHITECTURE catalogue: element.create gains optional fallback:Bool (F035).
- Integration spec edit (BEFORE F066 is built): forge-spec F041 commands add layer.exportOptions {command, params} (read; hook on export.run and render.page) + ARCHITECTURE §6.5; F066 export.run options add visibleLayersOnly: Bool and visibleLayers: {docRaw: [Int]}, and F066's description must honour them.
- F001: WAL risk FIXED (e6ce770, run 36223033046).
- F016 (after main integration): register toolbar.dock {dock, along?} (session, returns previous), persist dock setting, route NibToolPalette dock binding through it; remove workarounds.
- F019 spec now has library.reorder {refs, folder?, after?|before?} + Manual sort + NibReflow.
- F052 FIX: HOLD until contracts-v2 on main (HUD overlay, playback bar, live toolbar state, typed events), then FIX with the review (3 majors incl. audio.delete path traversal).
