import SwiftUI

/// The 4 pt spacing scale (2 pt only inside controls).
public enum NibSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let x3: CGFloat = 32
    public static let x4: CGFloat = 40
    public static let x5: CGFloat = 48
    public static let x6: CGFloat = 64
}

/// Continuous-corner radii (DESIGN.md §6). A shape inside a shape uses `concentric(outer, inset:)`.
public enum NibRadius {
    public static let popover: CGFloat = 26
    public static let panel: CGFloat = 28
    public static let sheet: CGFloat = 28
    public static let composer: CGFloat = 22
    public static let studyCard: CGFloat = 20
    public static let zoomFrame: CGFloat = 18
    public static let tile: CGFloat = 14
    public static let proposal: CGFloat = 12
    public static let field: CGFloat = 10
    public static let sidebarRow: CGFloat = 10
    public static let segment: CGFloat = 9
    /// A lifted cover's 3 pt water envelope, concentric with its 5 pt spine.
    public static let cardEnvelope: CGFloat = 8
    public static let segmentKnob: CGFloat = 7
    /// A lifted thumbnail's 3 pt envelope (4 + 3), the same radius as the current-page ring.
    public static let thumbnailEnvelope: CGFloat = 7
    public static let icon: CGFloat = 7
    public static let badge: CGFloat = 6
    public static let coverSpine: CGFloat = 5
    public static let coverEdge: CGFloat = 8
    public static let thumbnail: CGFloat = 4
    /// v2: the on-page ruler body, an opaque object like a badge.
    public static let ruler: CGFloat = 6
    /// v2: search hits and citations washed on the page (`accentWash`, DESIGN.md §14.5).
    public static let pageWash: CGFloat = 4

    public static func capsule(_ height: CGFloat) -> CGFloat { height / 2 }
    public static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat { max(outer - inset, 8) }
}

/// Fixed metrics (DESIGN.md §5).
public enum NibMetrics {
    public static let hitTarget: CGFloat = 44
    public static let barHeight: CGFloat = 44
    public static let barHeightMax: CGFloat = 52
    /// Every HUD: page counter, zoom, ruler angle, recording, follow, presenter.
    public static let hudHeight: CGFloat = 40
    public static let chromeInset: CGFloat = 16
    public static let barTopGap: CGFloat = 8
    public static let paletteThickness: CGFloat = 56
    public static let paletteThicknessMax: CGFloat = 64
    public static let palettePitch: CGFloat = 44
    public static let palettePitchMax: CGFloat = 52
    public static let palettePitchCompact: CGFloat = 46
    public static let palettePitchCompactMax: CGFloat = 54
    public static let paletteEndPadding: CGFloat = 6
    public static let paletteSwatchPitch: CGFloat = 44
    public static let paletteDividerGap: CGFloat = 17
    public static let popoverWidth: CGFloat = 312
    public static let popoverGap: CGFloat = 20
    public static let popoverGapCompact: CGFloat = 16
    public static let popoverMaxHeight: CGFloat = 520
    public static let panelWidth: CGFloat = 344
    /// Panels (assistant, plugins, search results) widen at AX1 and larger.
    public static let panelWidthAccessibility: CGFloat = 420
    public static let navigatorWidth: CGFloat = 240
    public static let thumbnailWidth: CGFloat = 176
    public static let sidebarWidth: CGFloat = 320
    public static let coverSize = CGSize(width: 140, height: 182)
    public static let coverSizeCompact = CGSize(width: 110, height: 143)
    /// Every library measure sits on this gutter: covers (164 pt pitch) and folder tiles.
    public static let libraryGutter: CGFloat = 24
    /// Folder tiles are this tall; their width comes from the grid: (content width − 3 × gutter) / 4.
    public static let folderTileHeight: CGFloat = 78
    public static let folderTileMinWidth: CGFloat = 160
    public static let compactBreakpoint: CGFloat = 600
    public static let beadRadius: CGFloat = 20
    public static let minimumGlyphGap: CGFloat = 8
    public static let minimumRestingGap: CGFloat = 16
    /// iPhone: the canvas's bottom content inset, so the last line always scrolls above the palette (56 + 8 + 16).
    public static let canvasBottomInsetCompact: CGFloat = 80

    public static func panelWidth(_ size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? panelWidthAccessibility : panelWidth
    }

    // v2 additions (DESIGN.md §5 and the screens of §14 that set them)

    /// Cells of popover choice grids (pen types, shape kinds, tape patterns, More): `NibOptionTile`.
    public static let optionTileHeight: CGFloat = 52
    /// What a popover's content has to lay out in: its width less 16 pt padding each side (sliders, grids).
    public static let popoverContentWidth: CGFloat = 280
    /// Selection and frame handles (DESIGN.md §14.3): 12 pt beads in 44 pt hit areas (`NibHandleView`); the rotation
    /// bead sits 24 pt above the top edge on a hairline.
    public static let handleBead: CGFloat = 12
    public static let rotationHandleOffset: CGFloat = 24
    /// Status dots: unseen changes on a thumbnail, the bridge's connected dot, the recording dot (`NibStatusDot`).
    public static let statusDot: CGFloat = 6
    /// Collaborator initials after the document title; at most `presenceMaxShown` before "+N".
    public static let presenceBead: CGFloat = 22
    public static let presenceMaxShown = 3
    /// A collaborator's live cursor on the page.
    public static let liveCursorBead: CGFloat = 10
    /// Document tabs between the chrome bars: capsules 32 pt tall, up to five before the overflow menu.
    public static let tabCapsuleHeight: CGFloat = 32
    public static let maxVisibleTabs = 5
    /// Bookmark and outline rows carry a 40 pt page thumbnail (`NibMiniPageThumbnail`).
    public static let rowThumbnailWidth: CGFloat = 40
    /// Outline rows indent 16 pt per level and stop indenting after `outlineMaxDepth` (a 240 pt navigator).
    public static let outlineIndent: CGFloat = 16
    public static let outlineMaxDepth = 4
    /// Settings on iPad: a 760 × 706 form sheet with a 220 pt section list.
    public static let settingsSheetSize = CGSize(width: 760, height: 706)
    public static let settingsSectionListWidth: CGFloat = 220
    /// The New Notebook sheet on iPad, its live cover preview, the cover strip and the paper grid tiles.
    public static let newDocumentSheetSize = CGSize(width: 720, height: 640)
    public static let coverPreviewSize = CGSize(width: 104, height: 136)
    public static let coverStripSize = CGSize(width: 88, height: 116)
    public static let paperTileSize = CGSize(width: 104, height: 135)
    /// The plugin manager sheet on iPad (list `sidebarWidth` wide) and the developer console.
    public static let pluginManagerSheetSize = CGSize(width: 780, height: 690)
    public static let developerConsoleSize = CGSize(width: 480, height: 320)
    /// A floating Deep panel (assistant, plugin panels, the Elements panel's maximum).
    public static let floatingPanelSize = CGSize(width: 344, height: 560)
    /// Global search: the 560 pt field and results panel (up to 600 tall) and the handwriting snippets in it.
    public static let searchWidth: CGFloat = 560
    public static let searchResultsMaxHeight: CGFloat = 600
    public static let searchSnippetSize = CGSize(width: 120, height: 60)
    /// The ⌘K command bar.
    public static let commandBarWidth: CGFloat = 560
    /// Onboarding's one Deep card per step (iPhone: the width − 32).
    public static let onboardingCardWidth: CGFloat = 480
    /// Study cards: the practice card and the editor's preview (`NibFlashcard`).
    public static let studyCardSize = CGSize(width: 560, height: 360)
    /// The Zoom Window's writing pane, docked at the bottom (full width − 32).
    public static let zoomPaneHeight: CGFloat = 240
    /// The audio playback bar (bottom centre; above the palette on iPhone).
    public static let audioBarWidth: CGFloat = 320
    /// Text documents: the reading column.
    public static let textColumnWidth: CGFloat = 680
    /// The laser (DESIGN.md §14.12): a 12 pt dot with a 12 pt glow and a 4 pt trail.
    public static let laserDot: CGFloat = 12
    public static let laserGlow: CGFloat = 12
    public static let laserTrail: CGFloat = 4
    /// The assistant's numbered margin badges sit at this x on the page (page points).
    public static let proposalBadgeX: CGFloat = 52
}

/// Line widths (DESIGN.md §5.1). Nothing strokes at another width.
public enum NibStroke {
    /// Separators, dividers, the swatch hairline.
    public static let hairline: CGFloat = 0.5
    /// A droplet's outline (`waterLine`) and the opaque Reduce Transparency outline.
    public static let outline: CGFloat = 0.8
    /// The permanent swatch ring, guides, the lasso marquee, template rules, ruler ticks.
    public static let thin: CGFloat = 1
    /// The Zoom Window box, the dashed addition rule (Differentiate Without Colour).
    public static let emphasis: CGFloat = 1.5
    /// Focus rings, selection rings (current page, chosen paper, selected swatch) and drop-target borders.
    public static let ring: CGFloat = 2
    /// Progress bars and illustration pen strokes.
    public static let thick: CGFloat = 3
    /// How far outside its shape a selection ring sits (`nibSelectionRing`).
    public static let ringOutset: CGFloat = 3
    /// The one dash, 4 on and 4 off, at `thin` width: the lasso marquee, a text box's editing outline, spacing
    /// guides (DESIGN.md §14.3).
    public static let dash: [CGFloat] = [4, 4]
    /// `dash` for SwiftUI shapes: `.stroke(NibColor.accent, style: NibStroke.dashed)`.
    public static let dashed = StrokeStyle(lineWidth: 1, dash: [4, 4])
    /// `dash` for `CAShapeLayer.lineDashPattern`.
    public static var layerDash: [NSNumber] { dash.map { NSNumber(value: Double($0)) } }
}

/// Opacities with a meaning (DESIGN.md §5.2). Colour tokens carry their own alpha; these are for content.
public enum NibOpacity {
    /// Disabled controls.
    public static let disabled: Double = 0.4
    /// Unselected palette tools (the selected one is 1).
    public static let unselectedTool: Double = 0.74
    /// A droplet over the page while the Pencil is down (`NibLiquid.recedeOpacity`).
    public static let recede: Double = 0.22
    /// The assistant's proposed additions, written as ghost ink in the user's pen.
    public static let ghostInk: Double = 0.42
    /// Note replay: strokes the audio has not reached yet.
    public static let replayPending: Double = 0.30
    /// The laser dot's glow.
    public static let laserGlow: Double = 0.45
}
