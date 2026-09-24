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
}
