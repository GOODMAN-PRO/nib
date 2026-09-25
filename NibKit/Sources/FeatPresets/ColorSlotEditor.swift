import SwiftUI
import UIKit
import ImageIO
import NibContracts
import NibDesign

// MARK: - Colour helpers

/// One colour the editor offers: an ink, or a highlighter for the highlighter tool.
struct PaletteInk: Identifiable {
    let id: String
    let colour: RGBA
    let name: String
}

/// Conversions between the model's `RGBA` and the platform's colours, names for VoiceOver and the swatch ring rule.
enum PresetColour {
    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    static func color(_ c: RGBA) -> Color { Color(cgColor: cgColor(c)) }

    static func uiColor(_ c: RGBA) -> UIColor { UIColor(cgColor: cgColor(c)) }

    static func rgba<C: NibHexColour>(_ c: C) -> RGBA {
        RGBA(UInt8((c.hex >> 16) & 0xFF), UInt8((c.hex >> 8) & 0xFF), UInt8(c.hex & 0xFF))
    }

    /// Any UIColor (the system picker may hand back Display P3 or grey) as 8-bit sRGB.
    static func rgba(_ color: UIColor) -> RGBA {
        let source = color.cgColor
        let srgb = CGColorSpace(name: CGColorSpace.sRGB).flatMap { source.converted(to: $0, intent: .defaultIntent, options: nil) }
        let c = (srgb ?? source).components ?? []
        let v: [CGFloat]
        switch c.count {
        case 4...: v = Array(c.prefix(4))
        case 2: v = [c[0], c[0], c[0], c[1]]
        default:
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            v = [r, g, b, a]
        }
        func byte(_ x: CGFloat) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
        return RGBA(byte(v[0]), byte(v[1]), byte(v[2]), byte(v[3]))
    }

    /// "#RRGGBB": the colour without its alpha (commands give highlighters their own opacity).
    static func rgbHex(_ c: RGBA) -> String { String(c.hex.prefix(7)) }

    static func sameRGB(_ a: RGBA, _ b: RGBA) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }

    /// WCAG relative luminance.
    static func luminance(_ c: RGBA) -> Double {
        func linear(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// The permanent 1 pt ring on colours that vanish against the chrome: the inks' own rule, and for custom colours
    /// anything nearly white (light mode) or nearly black (dark mode).
    static func needsRing(_ c: RGBA, dark: Bool) -> Bool {
        if let ink = NibInk.allCases.first(where: { sameRGB(rgba($0), c) }) { return ink.needsRing(dark: dark) }
        let l = luminance(c)
        return dark ? l < 0.05 : l > 0.8
    }

    /// Highlighter slots are shown as flat, opaque colour (the stroke itself multiplies beneath ink).
    static func display(_ c: RGBA, tool: String) -> RGBA { tool == "highlighter" ? RGBA(c.r, c.g, c.b) : c }

    static func name(_ c: RGBA) -> String {
        if let ink = NibInk.allCases.first(where: { sameRGB(rgba($0), c) }) { return ink.name }
        if let h = NibHighlighter.allCases.first(where: { sameRGB(rgba($0), c) }) { return highlighterName(h) }
        return String(localized: "Custom colour \(rgbHex(c))")
    }

    static func highlighterName(_ h: NibHighlighter) -> String {
        switch h {
        case .lemon: return String(localized: "Lemon")
        case .apricot: return String(localized: "Apricot")
        case .mint: return String(localized: "Mint")
        case .sky: return String(localized: "Sky")
        case .lilac: return String(localized: "Lilac")
        case .blush: return String(localized: "Blush")
        }
    }

    static func swatch(_ c: RGBA, id: String, name: String) -> NibSwatch {
        NibSwatch(id: id, color: color(c), name: name, ringsLight: needsRing(c, dark: false), ringsDark: needsRing(c, dark: true))
    }

    /// The colours offered for a tool: the six highlighters for the highlighter, the twelve inks for every other tool.
    static func palette(for tool: String) -> [PaletteInk] {
        if tool == "highlighter" {
            return NibHighlighter.allCases.map { PaletteInk(id: $0.rawValue, colour: rgba($0), name: highlighterName($0)) }
        }
        return NibInk.allCases.map { PaletteInk(id: $0.rawValue, colour: rgba($0), name: $0.name) }
    }
}

/// Glyphs NibSymbol has no token for yet (contract gap): validated through `NibSymbol(systemName:)` with a token fallback.
// ponytail: stand-ins until contract request F008-pattern-swatch-and-symbols adds NibSymbol.customColour and
// NibSymbol.eyedropper (filed in the F008 feature summary); switch to the tokens and delete this enum then.
enum PresetSymbols {
    static let customColour = NibSymbol(systemName: "paintpalette") ?? .plus
    static let eyedropper = NibSymbol(systemName: "eyedropper") ?? .search
}

// MARK: - Colour editor (the options bar while one colour slot is edited or a colour is added)

/// What the colour editor changes: one existing slot, or a new one.
enum ColourTarget: Equatable {
    case slot(Int)
    case add
}

/// The options bar while a colour slot is edited (tap the selected colour again) or a colour is added (+): the tool's
/// colours (the six highlighters for the highlighter), the tape patterns for tape, Custom (the system colour picker:
/// grid, spectrum, sliders with hex and the system eyedropper), Pick Colour from Page (the in-document loupe) and
/// Remove. It lives in the same Clear bar droplet, which re-forms around the new row.
struct ColourEditorRow: View {
    let app: NibApp
    let session: EditorSession
    let tool: String
    let presets: ToolPresets
    let target: ColourTarget
    let stripWidth: (Int) -> CGFloat
    let onDone: () -> Void

    private var slot: Int? {
        if case .slot(let i) = target, presets.swatches.indices.contains(i) { return i }
        return nil
    }

    /// The slot being edited, or the selected one when adding (its colour seeds the picker and the patterns).
    private var current: PresetSwatch { presets.swatches[slot ?? presets.selectedSwatch] }
    private var inks: [PaletteInk] { PresetColour.palette(for: tool) }
    private var patterns: [TapePatternDescriptor] { tool == "tape" ? app.content.tapePatterns.all : [] }

    var body: some View {
        HStack(spacing: 0) {
            NibIconButton(.back, label: String(localized: "Back to Presets"), shortcut: .cancelAction, action: onDone)
            strip
            NibBarSeparator()
            NibIconButton(PresetSymbols.customColour, label: String(localized: "Custom Colour"), action: openPicker)
            if EyedropperAttachment.canPick(session: session, app: app) {
                NibIconButton(PresetSymbols.eyedropper, label: String(localized: "Pick Colour from Page"), action: pickFromPage)
            }
            if let slot, presets.swatches.count > 1 {
                NibIconButton(.trash, label: String(localized: "Remove Colour")) { remove(slot) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(slot == nil ? String(localized: "Add a colour") : String(localized: "Change colour"))
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                if tool == "tape" {
                    patternItems
                    NibBarSeparator()
                }
                ForEach(inks) { ink in
                    NibPenSwatch(PresetColour.swatch(ink.colour, id: ink.id, name: ink.name),
                                 isSelected: slot != nil && PresetColour.sameRGB(ink.colour, current.color), size: .palette) {
                        pick(ink.colour)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(width: stripWidth(inks.count + (tool == "tape" ? patterns.count + 1 : 0)), height: NibMetrics.hitTarget)
    }

    @ViewBuilder private var patternItems: some View {
        let colour = PresetColour.display(current.color, tool: tool)
        NibPenSwatch(PresetColour.swatch(colour, id: "none", name: String(localized: "No Pattern")),
                     isSelected: slot != nil && current.pattern == nil, size: .palette) {
            setPattern(nil)
        }
        ForEach(patterns, id: \.id) { d in
            PatternSwatch(colour: colour, patternID: d.id, registry: app.content.tapePatterns, name: d.title,
                          isSelected: slot != nil && current.pattern?.name == d.id) {
                setPattern(d.id)
            }
        }
    }

    // MARK: Actions (every one is a preset command)

    private func pick(_ colour: RGBA) {
        let hex = PresetColour.rgbHex(colour)
        if let slot {
            PresetActions.run(app, session: session, [PresetActions.call("preset.setSwatch", tool,
                                                                          ["index": .number(Double(slot)), "color": .string(hex)])])
        } else {
            PresetActions.run(app, session: session, [PresetActions.call("preset.addSwatch", tool, ["color": .string(hex)])])
        }
        onDone()
    }

    private func setPattern(_ id: String?) {
        PresetActions.run(app, session: session, Self.patternCalls(tool: tool, slot: slot, count: presets.swatches.count,
                                                                   hex: current.color.hex, pattern: id))
        onDone()
    }

    /// The commands a pattern choice runs. nil = plain colour. Adding a pattern adds a slot in the current colour, then
    /// gives it the pattern: the new slot's index is the old slot count.
    static func patternCalls(tool: String, slot: Int?, count: Int, hex: String, pattern id: String?) -> [PresetActions.Call] {
        if let slot {
            return [PresetActions.call("preset.setSwatch", tool, ["index": .number(Double(slot)), "color": .string(hex),
                                                                  "pattern": .string(id ?? "")])]
        }
        var calls = [PresetActions.call("preset.addSwatch", tool, ["color": .string(hex)])]
        if let id {
            calls.append(PresetActions.call("preset.setSwatch", tool, ["index": .number(Double(count)), "color": .string(hex),
                                                                       "pattern": .string(id)]))
        }
        return calls
    }

    private func openPicker() {
        let app = self.app, session = self.session, tool = self.tool, slot = self.slot
        let title = String(localized: "\(PresetText.toolName(tool)) Colour")
        SystemColourPicker.present(title: title, initial: current.color, supportsAlpha: tool != "highlighter",
                                   commitsOnFinishOnly: slot == nil, app: app, session: session) { colour in
            let hex = tool == "highlighter" ? PresetColour.rgbHex(colour) : colour.hex
            if let slot {
                PresetActions.run(app, session: session, [PresetActions.call("preset.setSwatch", tool,
                                                                              ["index": .number(Double(slot)), "color": .string(hex)])])
            } else {
                PresetActions.run(app, session: session, [PresetActions.call("preset.addSwatch", tool, ["color": .string(hex)])])
            }
        }
        onDone()
    }

    private func pickFromPage() {
        let target: ColourTarget = slot.map { ColourTarget.slot($0) } ?? .add
        EyedropperAttachment.begin(EyedropperAttachment.Request(tool: tool, target: target), session: session)
        onDone()
    }

    private func remove(_ index: Int) {
        PresetActions.run(app, session: session, [PresetActions.call("preset.removeSwatch", tool, ["index": .number(Double(index))])])
        onDone()
    }
}

// MARK: - Tape pattern swatches

/// A tape slot that carries a pattern: the tile over the slot's colour, drawn like `NibPenSwatch` (flat, a 0.5 pt
/// hairline, the 2 pt label ring 2.5 pt outside when selected, a 44 pt hit target).
// ponytail: mirrors NibPenSwatch(size: .palette) metrics line for line because NibDesign has no pattern overlay yet;
// contract request F008-pattern-swatch-and-symbols (filed in the F008 feature summary) asks NibPenSwatch for one.
// Replace this view with NibPenSwatch(pattern:) once it lands.
struct PatternSwatch: View {
    let colour: RGBA
    let patternID: String
    let registry: Registry<TapePatternDescriptor>
    let name: String
    let isSelected: Bool
    let action: () -> Void

    private static let diameter: CGFloat = 22

    var body: some View {
        let diameter = Self.diameter
        Button(action: action) {
            Circle()
                .fill(PresetColour.color(colour))
                .overlay { PatternTile(patternID: patternID, registry: registry).clipShape(Circle()) }
                .overlay { Circle().strokeBorder(NibColor.swatchHairline, lineWidth: 0.5) }
                .frame(width: diameter, height: diameter)
                .overlay {
                    if isSelected {
                        Circle()
                            .stroke(NibColor.label, lineWidth: 2)
                            .frame(width: diameter + 7, height: diameter + 7)
                    }
                }
                .animation(NibMotion.colorChange, value: isSelected)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A tape pattern tile, tiled at swatch scale. Loaded off the main actor once per pattern.
struct PatternTile: View {
    let patternID: String
    let registry: Registry<TapePatternDescriptor>
    @State private var image: UIImage?

    init(patternID: String, registry: Registry<TapePatternDescriptor>) {
        self.patternID = patternID
        self.registry = registry
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable(resizingMode: .tile)
            } else {
                Color.clear
            }
        }
        .accessibilityHidden(true)
        .task(id: patternID) { image = await TapePatternCache.image(patternID, registry: registry) }
    }
}

@MainActor
enum TapePatternCache {
    /// One tile spans this many points inside a swatch.
    static let tilePoints: CGFloat = 11
    private static var images: [String: UIImage] = [:]

    static func image(_ id: String, registry: Registry<TapePatternDescriptor>) async -> UIImage? {
        if let cached = images[id] { return cached }
        guard let descriptor = registry.get(id) else { return nil }
        let load = descriptor.load
        let size = tilePoints
        let tile = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            // Custom and plugin patterns are untrusted, possibly huge images: decode a tile-sized thumbnail only.
            guard let data = try? load(), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceThumbnailMaxPixelSize: Int((size * 3).rounded(.up))] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return UIImage(cgImage: cg, scale: max(1, CGFloat(cg.width) / size), orientation: .up)
        }.value
        if let tile { images[id] = tile }
        return tile
    }
}

// MARK: - System colour picker

/// Presents `UIColorPickerViewController` (grid, spectrum, sliders with hex, and the system eyedropper) and reports
/// the chosen colour. A slot changes with every settled choice; a new slot is added once, when the picker closes.
@MainActor
final class SystemColourPicker: NSObject, UIColorPickerViewControllerDelegate {
    private static var active: SystemColourPicker?
    private let commitsOnFinishOnly: Bool
    private let onPick: @MainActor (RGBA) -> Void
    private var latest: RGBA?
    private var committed: RGBA?

    init(initial: RGBA, commitsOnFinishOnly: Bool, onPick: @escaping @MainActor (RGBA) -> Void) {
        self.committed = initial
        self.commitsOnFinishOnly = commitsOnFinishOnly
        self.onPick = onPick
        super.init()
    }

    static func present(title: String, initial: RGBA, supportsAlpha: Bool, commitsOnFinishOnly: Bool, app: NibApp,
                        session: EditorSession, onPick: @escaping @MainActor (RGBA) -> Void) {
        let picker = UIColorPickerViewController()
        picker.title = title
        picker.supportsAlpha = supportsAlpha
        picker.selectedColor = PresetColour.uiColor(initial)
        let coordinator = SystemColourPicker(initial: initial, commitsOnFinishOnly: commitsOnFinishOnly, onPick: onPick)
        picker.delegate = coordinator
        active = coordinator
        picker.modalPresentationStyle = .formSheet
        if let sheet = picker.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        PresetPresenter.present(picker, app: app, session: session)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        latest = PresetColour.rgba(color)
        if !continuously && !commitsOnFinishOnly { commitLatest() }
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        commitLatest()
        if Self.active === self { Self.active = nil }
    }

    private func commitLatest() {
        guard let c = latest, c != committed else { return }
        committed = c
        onPick(c)
    }
}

/// Presents system view controllers from the window the tool menu lives in (never another window's navigator: two
/// iPad windows side by side are both foreground-active).
@MainActor
enum PresetPresenter {
    static func present(_ viewController: UIViewController, app: NibApp, session: EditorSession) {
        if let navigator = app.ui.activeNavigator, navigator.session === session {
            navigator.presentModal(viewController)
            return
        }
        var top = (session.editor as? UIViewController) ?? session.editor?.canvasHost?.canvasView.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(viewController, animated: true)
    }
}
