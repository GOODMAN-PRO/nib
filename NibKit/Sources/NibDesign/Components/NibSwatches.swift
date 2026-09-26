import SwiftUI
import UIKit
import NibContracts

/// A tape pattern tile for a swatch (DESIGN.md §14.3 Tape): the feature loads the tile (a `TapePatternDescriptor`'s
/// image) and the swatch tiles it over the colour, `tilePoints` wide per tile. Equal by `id`, size and name, so a
/// reloaded image does not count as a new swatch.
public struct NibSwatchPattern: Hashable {
    public let id: String
    public let image: UIImage
    /// One tile spans this many points inside the swatch.
    public let tilePoints: CGFloat
    /// Read after the colour by VoiceOver ("Cobalt, Dots"); nil reads the colour only.
    public let name: String?

    public init(id: String, image: UIImage, tilePoints: CGFloat = 11, name: String? = nil) {
        self.id = id
        self.image = image
        self.tilePoints = tilePoints
        self.name = name
    }

    public static func == (a: NibSwatchPattern, b: NibSwatchPattern) -> Bool {
        a.id == b.id && a.tilePoints == b.tilePoints && a.name == b.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(tilePoints)
        hasher.combine(name)
    }

    /// The tile's scale: its width in the swatch over its width as an image.
    var tileScale: CGFloat { tilePoints / max(image.size.width, 1) }

    var paint: ImagePaint { ImagePaint(image: Image(uiImage: image), scale: tileScale) }
}

public extension NibSwatch {
    /// A colour from the palette tables, ringed the way `NibInk.needsRing` rings inks: a colour that vanishes against
    /// the chrome (very light in light mode, very dark in dark mode) keeps a permanent 1 pt `swatchRing`.
    init(id: String, hex: UInt32, name: String, pattern: NibSwatchPattern? = nil) {
        self.init(id: id, color: Color(uiColor: UIColor.nibHex(hex)), name: name,
                  ringsLight: NibSwatch.needsRing(hex: hex, dark: false),
                  ringsDark: NibSwatch.needsRing(hex: hex, dark: true), pattern: pattern)
    }

    /// An ink carrying a tape pattern (tape swatches).
    init(ink: NibInk, pattern: NibSwatchPattern?) {
        self.init(id: ink.rawValue, color: ink.color, name: ink.name, ringsLight: ink.needsRing(dark: false),
                  ringsDark: ink.needsRing(dark: true), pattern: pattern)
    }

    init(highlighter: NibHighlighter) {
        self.init(id: highlighter.rawValue, hex: highlighter.hex, name: highlighter.name)
    }

    /// A paper colour (the New Notebook options row, board paper, text-box fills).
    init(paper: NibPaper) {
        self.init(id: paper.rawValue, hex: paper.hex, name: paper.name)
    }

    init(cloth: NibCoverCloth) {
        self.init(id: cloth.rawValue, hex: cloth.hex, name: cloth.name)
    }

    init(folder: NibFolderColor) {
        self.init(id: folder.rawValue, hex: folder.ink.hex, name: folder.name)
    }
}

extension NibSwatch {
    /// Relative luminance (WCAG) of a 0xRRGGBB colour.
    static func luminance(hex: UInt32) -> Double {
        func linear(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(hex >> 16) + 0.7152 * linear(hex >> 8) + 0.0722 * linear(hex)
    }

    /// Light mode rings colours brighter than 0.8 (Chalk, light papers); dark mode rings colours darker than 0.035
    /// (Carbon, Midnight, dark papers). The same answer as `NibInk.needsRing(dark:)` for every ink.
    static func needsRing(hex: UInt32, dark: Bool) -> Bool {
        let l = luminance(hex: hex)
        return dark ? l < 0.035 : l > 0.8
    }
}

// MARK: - Names

// Colour names for pickers and VoiceOver (DESIGN.md §3.5, §3.6), next to `NibInk.name`.

public extension NibHighlighter {
    var name: String {
        switch self {
        case .lemon: return String(localized: "Lemon", bundle: .module)
        case .apricot: return String(localized: "Apricot", bundle: .module)
        case .mint: return String(localized: "Mint", bundle: .module)
        case .sky: return String(localized: "Sky", bundle: .module)
        case .lilac: return String(localized: "Lilac", bundle: .module)
        case .blush: return String(localized: "Blush", bundle: .module)
        }
    }
}

public extension NibPaper {
    var name: String {
        switch self {
        case .white: return String(localized: "White", bundle: .module)
        case .ivory: return String(localized: "Ivory", bundle: .module)
        case .legal: return String(localized: "Legal", bundle: .module)
        case .grey: return String(localized: "Grey", bundle: .module)
        case .slate: return String(localized: "Slate", bundle: .module)
        case .night: return String(localized: "Night", bundle: .module)
        case .board: return String(localized: "Board", bundle: .module)
        }
    }
}

public extension NibCoverCloth {
    var name: String {
        switch self {
        case .moss: return String(localized: "Moss", bundle: .module)
        case .carbon: return String(localized: "Carbon", bundle: .module)
        case .terracotta: return String(localized: "Terracotta", bundle: .module)
        case .sand: return String(localized: "Sand", bundle: .module)
        case .navy: return String(localized: "Navy", bundle: .module)
        case .oxblood: return String(localized: "Oxblood", bundle: .module)
        case .stone: return String(localized: "Stone", bundle: .module)
        case .paper: return String(localized: "Paper", bundle: .module)
        }
    }
}

public extension NibFolderColor {
    /// Folder colours are inks, so they share the ink's name.
    var name: String { ink.name }
}

// MARK: - Swatch grid

/// Colour wells in a grid (DESIGN.md §14.3: the pen popover's 12 inks in 44 pt cells, 6 × 2; the highlighter's six;
/// shape fills with None first; sticky-note and laser colours). Selection is by swatch id; with `noneLabel` the first
/// well is None and selects nil. Put it in a `NibInspectorSection` whose action is "Custom…".
public struct NibSwatchGrid: View {
    let swatches: [NibSwatch]
    @Binding var selection: String?
    let columns: Int
    let noneLabel: String?
    let size: NibPenSwatch.Size

    public init(swatches: [NibSwatch], selection: Binding<String?>, columns: Int = 6, noneLabel: String? = nil,
                size: NibPenSwatch.Size = .popover) {
        self.swatches = swatches
        self._selection = selection
        self.columns = columns
        self.noneLabel = noneLabel
        self.size = size
    }

    public var body: some View {
        let grid = Array(repeating: GridItem(.flexible(minimum: NibMetrics.hitTarget), spacing: 0), count: max(columns, 1))
        LazyVGrid(columns: grid, alignment: .leading, spacing: 0) {
            if let noneLabel {
                NibNoneSwatch(label: noneLabel, isSelected: selection == nil, size: size) { selection = nil }
            }
            ForEach(swatches) { swatch in
                NibPenSwatch(swatch, isSelected: swatch.id == selection, size: size) { selection = swatch.id }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "No colour": an empty well with a diagonal hairline, the same size, ring and hit target as a swatch.
struct NibNoneSwatch: View {
    let label: String
    let isSelected: Bool
    let size: NibPenSwatch.Size
    let action: () -> Void

    var body: some View {
        let d = size.diameter
        Button(action: action) {
            Circle()
                .strokeBorder(NibColor.swatchHairline, lineWidth: NibStroke.hairline)
                .overlay {
                    Path { p in
                        let inset = d * 0.15
                        p.move(to: CGPoint(x: d - inset, y: inset))
                        p.addLine(to: CGPoint(x: inset, y: d - inset))
                    }
                    .stroke(NibColor.labelSecondary, lineWidth: NibStroke.thin)
                }
                .frame(width: d, height: d)
                .overlay {
                    if isSelected {
                        Circle()
                            .stroke(NibColor.label, lineWidth: NibStroke.ring)
                            .frame(width: d + 7, height: d + 7)
                    }
                }
                .animation(NibMotion.colorChange, value: isSelected)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Option tile

/// One choice in a popover grid (DESIGN.md §14.3: pen types in 4 × 52 pt cells, shape kinds, tape patterns, the
/// palette's More grid): a glyph or small preview over a caption2 label, at least 52 pt tall; the selected one sits on
/// `fill3` with the field radius (10). Lay them out in a `LazyVGrid` with 6 pt spacing.
public struct NibOptionTile<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    let preview: Preview

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void, @ViewBuilder preview: () -> Preview) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
        self.preview = preview()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)
        Button(action: action) {
            VStack(spacing: 3) {
                preview
                Text(title)
                    .font(NibFont.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? NibColor.label : NibColor.labelSecondary)
            .padding(.horizontal, NibSpacing.xs)
            .frame(maxWidth: .infinity, minHeight: NibMetrics.optionTileHeight)
            .background(isSelected ? NibColor.fill3 : Color.clear, in: shape)
            .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: shape))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The glyph of a symbol-only `NibOptionTile` (22 pt, the More grid's size).
public struct NibOptionGlyph: View {
    let symbol: NibSymbol

    public init(_ symbol: NibSymbol) { self.symbol = symbol }

    public var body: some View {
        Image(nib: symbol)
            .font(NibFont.glyph(.panel, size: 22))
            .accessibilityHidden(true)
    }
}

public extension NibOptionTile where Preview == NibOptionGlyph {
    init(_ title: String, symbol: NibSymbol, isSelected: Bool, action: @escaping () -> Void) {
        self.init(title, isSelected: isSelected, action: action) { NibOptionGlyph(symbol) }
    }
}

// MARK: - UIKit

public extension UIImage {
    /// `NibPenSwatch` for UIKit (the keyboard formatting bar, `UIMenu` images): the flat well with its hairline, or the
    /// permanent `swatchRing` where the colour vanishes, the tape pattern if any, and the 2 pt `label` ring when
    /// selected. Light and dark are drawn into one image asset, so an image view follows the appearance. The image is
    /// the well plus room for the ring (`size.diameter + 10` points square), so selecting never changes its size.
    static func nibSwatch(_ swatch: NibSwatch, size: NibPenSwatch.Size = .palette, isSelected: Bool = false) -> UIImage {
        let asset = UIImageAsset()
        let light = NibSwatchImage.draw(swatch, diameter: size.diameter, isSelected: isSelected, dark: false)
        let dark = NibSwatchImage.draw(swatch, diameter: size.diameter, isSelected: isSelected, dark: true)
        asset.register(light.withRenderingMode(.alwaysOriginal), with: UITraitCollection(userInterfaceStyle: .light))
        asset.register(dark.withRenderingMode(.alwaysOriginal), with: UITraitCollection(userInterfaceStyle: .dark))
        return asset.image(with: UITraitCollection.current)
    }
}

enum NibSwatchImage {
    static func imageSide(diameter: CGFloat) -> CGFloat { diameter + 10 }

    static func draw(_ swatch: NibSwatch, diameter: CGFloat, isSelected: Bool, dark: Bool) -> UIImage {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let side = imageSide(diameter: diameter)
        let format = UIGraphicsImageRendererFormat.preferred()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { context in
            traits.performAsCurrent {
                let ringed = dark ? swatch.ringsDark : swatch.ringsLight
                let well = CGRect(x: 5, y: 5, width: diameter, height: diameter)
                let circle = UIBezierPath(ovalIn: well)
                UIColor(swatch.color).resolvedColor(with: traits).setFill()
                circle.fill()
                if let pattern = swatch.pattern {
                    context.cgContext.saveGState()
                    circle.addClip()
                    let tileWidth = pattern.tilePoints
                    let tileHeight = tileWidth * pattern.image.size.height / max(pattern.image.size.width, 1)
                    var y = well.minY
                    while y < well.maxY, tileHeight > 0 {
                        var x = well.minX
                        while x < well.maxX, tileWidth > 0 {
                            pattern.image.draw(in: CGRect(x: x, y: y, width: tileWidth, height: tileHeight))
                            x += tileWidth
                        }
                        y += tileHeight
                    }
                    context.cgContext.restoreGState()
                }
                let lineWidth = ringed ? NibStroke.thin : NibStroke.hairline
                let outline = UIBezierPath(ovalIn: well.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
                outline.lineWidth = lineWidth
                (ringed ? NibUIColor.swatchRing : NibUIColor.swatchHairline).resolvedColor(with: traits).setStroke()
                outline.stroke()
                if isSelected {
                    // The 2 pt ring centred 3.5 pt outside the well: 2.5 pt clear, as `NibPenSwatch` draws it.
                    let ring = UIBezierPath(ovalIn: well.insetBy(dx: -3.5, dy: -3.5))
                    ring.lineWidth = NibStroke.ring
                    NibUIColor.label.resolvedColor(with: traits).setStroke()
                    ring.stroke()
                }
            }
        }
    }
}
