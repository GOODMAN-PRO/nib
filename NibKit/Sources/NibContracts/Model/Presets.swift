import Foundation

/// One color (or tape pattern) slot of a writing tool.
public struct PresetSwatch: Codable, Hashable {
    public var color: RGBA
    /// Tape only: tiled pattern stored in `.nib-library/tape/`; copied into a document's assets on use.
    public var pattern: AssetRef?

    public init(color: RGBA, pattern: AssetRef? = nil) {
        self.color = color
        self.pattern = pattern
    }
}

/// Per-tool presets: up to 12 color slots and exactly 3 thickness slots (each with its own line pattern).
/// Stored as the synced setting `NibSettings.presets(<toolId>)`; edited by the Tool Presets feature,
/// read by pen, pencil, highlighter, tape and shape tools.
public struct ToolPresets: Codable, Equatable {
    public static let maxSwatches = 12

    public var swatches: [PresetSwatch]
    public var widths: [Double]
    public var patterns: [StrokePattern]
    public var selectedSwatch: Int
    public var selectedWidth: Int

    public init(swatches: [PresetSwatch], widths: [Double], patterns: [StrokePattern]? = nil,
                selectedSwatch: Int = 0, selectedWidth: Int = 1) {
        self.swatches = swatches
        self.widths = widths
        self.patterns = patterns ?? widths.map { _ in StrokePattern.solid }
        self.selectedSwatch = selectedSwatch
        self.selectedWidth = selectedWidth
    }

    public var color: RGBA { swatches.indices.contains(selectedSwatch) ? swatches[selectedSwatch].color : .black }
    public var width: Double { widths.indices.contains(selectedWidth) ? widths[selectedWidth] : 1.2 }
    public var pattern: StrokePattern { patterns.indices.contains(selectedWidth) ? patterns[selectedWidth] : .solid }
    public var tapePattern: AssetRef? { swatches.indices.contains(selectedSwatch) ? swatches[selectedSwatch].pattern : nil }

    public static func defaults(for tool: String) -> ToolPresets {
        switch tool {
        case "highlighter":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0xFF, 0xE0, 0x3D, 0x80)), PresetSwatch(color: RGBA(0x7C, 0xE3, 0x8B, 0x80)),
                                          PresetSwatch(color: RGBA(0xFF, 0x8F, 0xB1, 0x80))], widths: [8, 12, 18])
        case "tape":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0xF4, 0xC4, 0x30)), PresetSwatch(color: RGBA(0x8E, 0xC5, 0xFF)),
                                          PresetSwatch(color: RGBA(0xFF, 0xA8, 0xA8))], widths: [12, 18, 26])
        case "pencil":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0x3A, 0x3A, 0x3C)), PresetSwatch(color: RGBA(0x5B, 0x6B, 0x7F)),
                                          PresetSwatch(color: RGBA(0x8A, 0x5A, 0x3C))], widths: [1.0, 1.6, 2.4])
        case "shape":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0x1A, 0x1A, 0x1A)), PresetSwatch(color: RGBA(0x1F, 0x5F, 0xD1)),
                                          PresetSwatch(color: RGBA(0xD1, 0x3B, 0x2F))], widths: [1.0, 1.5, 3.0])
        default:
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0x1A, 0x1A, 0x1A)), PresetSwatch(color: RGBA(0x1F, 0x5F, 0xD1)),
                                          PresetSwatch(color: RGBA(0xD1, 0x3B, 0x2F))], widths: [0.6, 1.2, 2.0])
        }
    }
}
