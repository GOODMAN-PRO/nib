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
- F036: drop-to-attach RESTORED (36aa13d, run 36227055835).
- App target: add user-fonts entitlement (com.apple.developer.user-fonts=[app-usage]) or UIAppSupportsInstalledFonts for F026 T-059/P-083 (owner of Nib/ Info.plist or integration).
- Integration spec edit: add image.pick {source, page?|doc?|ref?|refs?, point?, position?, anchor?, ids?} (edit, user presence, sensitive) to F034 commands in forge-spec.json + ARCHITECTURE §6.5.
- Integration spec edit: ARCHITECTURE catalogue: element.create gains optional fallback:Bool (F035).
- Integration spec edit (BEFORE F066 is built): forge-spec F041 commands add layer.exportOptions {command, params} (read; hook on export.run and render.page) + ARCHITECTURE §6.5; F066 export.run options add visibleLayersOnly: Bool and visibleLayers: {docRaw: [Int]}, and F066's description must honour them.
- F001: WAL risk FIXED (e6ce770, run 36223033046).
- F016 (after main integration): register toolbar.dock {dock, along?} (session, returns previous), persist dock setting, route NibToolPalette dock binding through it; remove workarounds.
- F019 spec now has library.reorder {refs, folder?, after?|before?} + Manual sort + NibReflow.
- F052 FIX: HOLD until contracts-v2 on main (HUD overlay, playback bar, live toolbar state, typed events), then FIX with the review (3 majors incl. audio.delete path traversal).

## Contracts-v2 landed (session 2026-09-26)
- v2/contracts green (run 36224576545); merged to main as 1741651; main CI 36225011717 GREEN -> marker/contracts-v2 = 1741651. Main is merged into feat/* by each V2ADOPT job (saves ~35 CI runs vs a blanket merge).
- 368 gaps: 220 resolved, 67 rejected, 81 deferred; see docs/CONTRACTS.md changelog.
- v2/spec agent: catalogue rows + unbuilt-feature spec edits (F066 layers export, F007 roll key, etc.)
- IMPLEMENT launched: F002 F006 F013 F021 F023 F091 F102 F103; CI: F031; F052 FIX held -> launch now that v2 is on main (after spec).
- TODO after main CI green: merge main into all feat/* branches (only those not being worked on by an agent; agents merge it themselves).
- contract gap (minor): ChromeOverlayDescriptor has no 'instant/no-motion' show option (F062 K key, DESIGN §9.3). Custom sound token missing (F062 uses system sound 1005).
- No PRs for feat/* or v2/* branches: ios.yml also triggers on pull_request, so a PR per branch would double the macOS CI load. Integration merges branches directly. Marker branches point at main commits (no diff).
- contract gap: docked assistant side/width for reservedTrailing (F016); per-tool disabled/on appearance in NibToolPalette.
- Mockup v2 merged to main (9e7dfb4) and REPUBLISHED to https://claude.ai/artifact/XQKSP4QSMTHuwFZRPxTLMm (version 1790407236-34b6). Publish copy = design/mockup.html with skeleton adaptations (title 'Nib Clear Water', :root light tokens, body bg, theme detection keeps data-theme, no doctype/head/body tags).
- Spec v2 merged to main (f7da15b). Follow-ups for fix/V2ADOPT passes:
  - F030: shape.recognize must return wrapped {shape: ShapeItem?, confidence?, mergeWith?: [ref]} (F007 accepts both; F009 already does).
  - F009: preview curves use control points (F030/F031 convention).
  - F046: register outline.list {doc, source?} (read).
  - F014: register clipboard.copyText {text?, url?} (read) (F037 needs it).
  - F041: if moved to a G26 closure hook, remove layer.exportOptions row in the same change.
  - F036: restore drop-to-attach (running).
  - NibContracts (v2/contracts2): PanelIDs.studyLearn -> studysession.smartLearn + practice; CommandIDs constants for new ids.
- F074 (unbuilt) must parse nib://bridge/pair?host=&port=&token= (port param added by F091). Add to F074 spec before its build.
- F019 (unbuilt) must present sheet panels from the library (panel.open without an open document: F021 New Notebook sheet, F044, F020 rely on it), fill MenuContext.folder, and double-tap + New -> doc.quickNote. Add to F019 spec before build.
- Unpinned result shapes to pin (spec owner): template.choose kind values + result size; doc.suggestTitle result; panel.open params delivery to PanelContext.params (flat vs nested).
- design v2.1 merged (palette re-form on external dock change; reflow 180 ms dwell). Known edge: .dropletDockable orientation flip-back within ~190 ms mislays; could reuse palette logic.
- F022 V2ADOPT: Move Pages sheet must read PanelContext.params["pages"] (F023 multi-page move). F022/F023 duplicate the nib-pages/1 payload encoder: a shared contract type would remove it.
- NibSymbol: rotate glyph; 3 pt drag-preview border token (F023).
- contract gap: bridge per-call event (F090 emits bridge.status only on state/session change); ARCHITECTURE §12 pairing link should document optional port (F074 spec already says so).
- F017 V2ADOPT green (d0849c6): overlays hosted, floatingHost published, toolbarView full-window, openPanels, PanelContext params/presentation.
- Remaining chrome gaps: DropletStyle per-droplet recede opt-out (NibDesign); overlay 'instant' show; contract for palette dock location so bottom overlays avoid a bottom-docked palette on iPad; toast bud swallows first outside touch; shell must track key-window changes (window.showLibrary) and forward childForStatusBarHidden (P-106).
