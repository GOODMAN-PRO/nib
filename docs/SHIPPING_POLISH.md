# Shared chrome shipping polish

Changes are confined to NibDesign, its unit tests, Nib/App, and docs. Feature files are being edited by other jobs.

- UIKit handles and the zoom frame use the shared normal-based light lobes: a 0.8 pt key rim and half-strength counter-rim. The app shell propagates Liquid mode through an inherited UIKit trait. Solid fallback removes rim and shadow, preserving the body and outline.
- Standalone solid glass has no elevation. Deep frost is inset 1.5 pt with a concentric radius, while body and optics keep their bounds.
- Clear search icons use the 21 pt bar glyph role and full-strength labels.
- Secondary text uses stronger neutral tokens (light 94%, dark 80%, high contrast 100%) and has contrast coverage for opaque and worst-case Deep backgrounds. Clear still requires primary labels.
- Chips own 44 × 44 pt button targets; removable context controls retain the 28 × 44 pt exception. Selected filters carry a checkmark and Selected trait. Chips and segments use the shared focus/hover style.
- Paper labels wrap and grow vertically inside existing feature-owned grid columns. Panel headers stack when needed and allow unlimited provider/key text. Segments become multiline vertical options when labels cannot fit or accessibility sizes are enabled.
- Shared menu/gallery labels and the app's confirmation action use sentence case.

## Copy changes requiring feature owners

These literal strings cannot be corrected in shared components without unsafe global text rewriting. They remain unchanged under this job's explicit file-ownership restriction:

| Owner file | Existing wording | Required wording |
|---|---|---|
| FeatLibraryUI/LibraryItemMenu.swift | More Selection Actions | More selection actions |
| FeatToolbar/ToolbarCustomization.swift | Save Current Layout | Save current layout |
| FeatOutline/OutlinePanel.swift | Show Thumbnails | Show thumbnails |
| FeatAIChat/ChatPanel.swift | Delete Conversation (confirmation, action, accessibility) | Delete conversation |
| NibAIAgent/ChatCommands.swift | Delete Conversation | Delete conversation |
| FeatBridgeUI/BridgeSettingsPage.swift | Rotate Token (confirmation and action) | Rotate token |

Preserve proper names and acronyms in the same screens. No navigation or command behavior changes are needed.

## Verification

`NibDesignTests` covers contrast, layout growth/reflow, chip bounds and selection cue, and UIKit rim/fallback rendering. The old frame test expected the retired (1.1, 1.5) offset; its assertion is replaced because it contradicts DESIGN.md §10.9. No tests are skipped, weakened, commented out, or deleted. No UI tests are run by this job.

Validated with `nib-build.sh targets /Users/Nice/Projects/Nib-wt/integration "NibDesignTests"`: 154 tests passed, zero failures (2026-10-02). The new trait test uses a window-attached hierarchy to exercise real UIKit inheritance and live updates.

The unsigned Debug app build also passed via `nib-build.sh app /Users/Nice/Projects/Nib-wt/integration`, including the app-shell trait propagation. `git diff --check` passed.
