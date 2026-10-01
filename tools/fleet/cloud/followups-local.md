# Follow-ups for the next fleet launch (session 2026-09-30)

- F017: spec pass 2 delta — with no open document, panel.open / panel.close forward to `library.setView {panel: id, params}` / `{panel: id, close: true}` (F019) instead of throwing unavailable. F017 already has v2adopt=true, so run 1 skips it: relaunch with resume F017: 'v2adopt' + this note (after F019 is built).
- F020 / F044 (optional): one sheet panel reading PanelContext.params["folder"] / MenuContext.folder instead of per-folder panel ids.
- Local Metal Toolchain was missing until ~21:30; agents that finished before then relied on CI only (F031 fix, F064 impl, F091 fix first rounds).
- Commit tools/fleet/integrate.workflow.js + nib-build.sh affinity change to main at a quiet moment (main lock is inside the running workflow).
- F070 (Codex, partial by ownership): status button/banners are registered as overlays; verify they appear in F019's library host during integration. F002 lacks a public full-rebuild API (F070 invalidates the derived cache instead) — contract gap.
- F086 (Codex, partial by ownership): AI max-steps preference is saved; verify F084's agent loop enforces it in integration. Reduce Transparency / Increase Contrast snapshots unverified (design pass).
- F054 ↔ F089: F054's embedded Summary subtab shows F089's summary JSON as plain text; it must render it the way F089's Summary sidebar does (fix in F054's files).
- F085 COMPLETION PASS (before integration): Codex left out (in F085's own scope) the inline per-block AI button; selective proposal toggles + on-page proofreader previews; historical attachment/tool-trace/cross-device token restoration; end-to-end nav/sidebar/floating verification with F017's host. The review didn't flag them. Run resume implement for F085 with these as the note, then CI + review.
- F002/F070 ↔ F111 (BUG): library.repair returns catalogRebuilt=false — repair does not recreate a deleted catalogue (doc.create -> FolderLibrary.changed -> scheduleCacheSave debounce race). F111's IntegrationTests repairCatalog scenario now asserts it and fails until F002/F070 fix the rebuild path.
