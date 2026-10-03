import SwiftUI
import UIKit
import ImageIO
import ObjectiveC
import NibContracts
import NibDesign

// MARK: - Colour helpers

/// One colour the editor offers: an ink, or a highlighter for the highlighter tool, with its NibDesign swatch.
struct PaletteInk: Identifiable {
    let colour: RGBA
    let swatch: NibSwatch
    var id: String { swatch.id }
    var name: String { swatch.name }
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
        if let h = NibHighlighter.allCases.first(where: { sameRGB(rgba($0), c) }) { return h.name }
        return String(localized: "Custom colour \(rgbHex(c))")
    }

    static func swatch(_ c: RGBA, id: String, name: String, pattern: NibSwatchPattern? = nil) -> NibSwatch {
        NibSwatch(id: id, color: color(c), name: name, ringsLight: needsRing(c, dark: false), ringsDark: needsRing(c, dark: true),
                  pattern: pattern)
    }

    /// The colours offered for a tool: the six highlighters for the highlighter, the twelve inks for every other tool.
    static func palette(for tool: String) -> [PaletteInk] {
        if tool == "highlighter" {
            return NibHighlighter.allCases.map { PaletteInk(colour: rgba($0), swatch: NibSwatch(highlighter: $0)) }
        }
        return NibInk.allCases.map { PaletteInk(colour: rgba($0), swatch: NibSwatch(ink: $0)) }
    }
}

// MARK: - Colour editor (the options bar's popover while one colour slot is edited or a colour is added)

/// What the colour editor changes: one existing slot, or a new one.
enum ColourTarget: Equatable {
    case slot(Int)
    case add
}

/// The options bar's popover while a colour slot is edited (tap the selected colour again) or a colour is added (+):
/// for tape its patterns, the tool's colours (the six highlighters for the highlighter, the twelve inks otherwise),
/// Custom (the system colour picker: grid, spectrum, sliders with hex and the system eyedropper), From Page (the
/// in-document loupe) and, for an existing slot, Remove.
struct ColourEditor: View {
    let model: PresetMenuModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var inks: [PaletteInk] { PresetColour.palette(for: model.tool) }

    var body: some View {
        let slot = model.colourSlot
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            if sizeClass == .compact {
                NibInspectorSection(String(localized: "Saved Colours")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: NibMetrics.hitTarget), spacing: 0)],
                              alignment: .leading, spacing: NibSpacing.s) {
                        ForEach(Array(model.presets.swatches.enumerated()), id: \.offset) { index, swatch in
                            SwatchSlot(tool: model.tool, swatch: swatch, name: PresetColour.name(swatch.color),
                                       isSelected: index == model.presets.selectedSwatch,
                                       registry: model.app?.content.tapePatterns) {
                                model.tapSwatch(index)
                            }
                            .accessibilityIdentifier("cmd.preset.select")
                        }
                        if model.presets.swatches.count < ToolPresets.maxSwatches {
                            NibIconButton(.plus, label: String(localized: "Add Colour")) { model.addColour() }
                                .nibNativeAction { model.addColour() }
                        }
                    }
                }
            }
            if model.tool == "tape", let registry = model.app?.content.tapePatterns {
                NibInspectorSection(String(localized: "Pattern")) {
                    TapePatternGrid(model: model, registry: registry)
                }
            }
            NibInspectorSection(slot == nil ? String(localized: "New Colour") : String(localized: "Colour")) {
                NibSwatchGrid(swatches: inks.map(\.swatch), selection: inkSelection(slot: slot))
                    .accessibilityIdentifier(slot == nil ? "cmd.preset.addSwatch" : "cmd.preset.setSwatch")
            }
            HStack(spacing: NibSpacing.s) {
                NibButton(String(localized: "Custom"), symbol: .customColour, size: .compact) { model.openPicker() }
                    .nibNativeAction { model.openPicker() }
                    .accessibilityLabel(String(localized: "Custom Colour"))
                if model.canPickFromPage {
                    NibButton(String(localized: "From Page"), symbol: .eyedropper, size: .compact) { model.pickFromPage() }
                        .accessibilityLabel(String(localized: "Pick Colour from Page"))
                }
                Spacer(minLength: 0)
                if slot != nil, model.presets.swatches.count > 1 {
                    NibIconButton(.trash, label: String(localized: "Remove Colour")) { model.removeEdited() }
                        .accessibilityIdentifier("cmd.preset.removeSwatch")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(slot == nil ? String(localized: "Add a colour") : String(localized: "Change colour"))
    }

    /// The ink matching the edited slot (none while adding); choosing one sets the slot or adds it.
    private func inkSelection(slot: Int?) -> Binding<String?> {
        let inks = self.inks, model = self.model
        return Binding(get: {
            guard slot != nil else { return nil }
            return inks.first { PresetColour.sameRGB($0.colour, model.editedSwatch.color) }?.id
        }, set: { id in
            guard let ink = inks.first(where: { $0.id == id }) else { return }
            model.pick(ink.colour)
        })
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
}

// MARK: - Tape patterns

/// The tape patterns (`content.tapePatterns`) in the edited slot's colour, No Pattern first.
struct TapePatternGrid: View {
    let model: PresetMenuModel
    let registry: Registry<TapePatternDescriptor>
    @State private var tiles: [String: NibSwatchPattern] = [:]

    var body: some View {
        let descriptors = registry.all
        let colour = PresetColour.display(model.editedSwatch.color, tool: model.tool)
        let name = PresetColour.name(colour)
        // Until its tile has loaded a swatch reads as its pattern's title; then as "Lemon, Dots".
        let swatches = descriptors.map { d in
            PresetColour.swatch(colour, id: d.id, name: tiles[d.id] == nil ? d.title : name, pattern: tiles[d.id])
        }
        NibSwatchGrid(swatches: swatches, selection: selection, noneLabel: String(localized: "No Pattern"))
            .accessibilityIdentifier(model.colourSlot == nil ? "cmd.preset.addSwatch" : "cmd.preset.setSwatch")
            .task(id: descriptors.map(\.id)) {
                for d in descriptors where tiles[d.id] == nil {
                    if let tile = await TapePatternCache.pattern(d.id, registry: registry) { tiles[d.id] = tile }
                }
            }
    }

    /// The edited slot's pattern (No Pattern while adding); choosing one sets it, or adds a slot that carries it.
    private var selection: Binding<String?> {
        let model = self.model
        return Binding(get: { model.colourSlot == nil ? nil : model.editedPatternID },
                       set: { model.setTapePattern($0) })
    }
}

/// Tape pattern tiles for swatches, decoded once per pattern off the main actor. NibDesign tiles them over the colour
/// (`NibSwatchPattern`); loading the image stays here.
@MainActor
enum TapePatternCache {
    /// One tile spans this many points inside a swatch.
    static let tilePoints: CGFloat = 11
    private static var images: [String: UIImage] = [:]

    /// A `TapePatternDescriptor.id` as a swatch pattern, named for VoiceOver ("Lemon, Dots").
    static func pattern(_ id: String, registry: Registry<TapePatternDescriptor>) async -> NibSwatchPattern? {
        guard let image = await image(id, registry: registry) else { return nil }
        return NibSwatchPattern(id: id, image: image, tilePoints: tilePoints, name: registry.get(id)?.title)
    }

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
final class SystemColourPicker: NSObject, UIColorPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    private static var coordinatorKey: UInt8 = 0
    private let commitsOnFinishOnly: Bool
    private let onPick: @MainActor (RGBA) -> Void
    private var latest: RGBA?
    private var lastPickerSelection: RGBA?
    private var committed: RGBA?
    private var finished = false

    init(initial: RGBA, commitsOnFinishOnly: Bool, onPick: @escaping @MainActor (RGBA) -> Void) {
        self.committed = initial
        self.commitsOnFinishOnly = commitsOnFinishOnly
        self.onPick = onPick
        super.init()
    }

    static func present(title: String, initial: RGBA, supportsAlpha: Bool, commitsOnFinishOnly: Bool, app: NibApp,
                        session: EditorSession, onPick: @escaping @MainActor (RGBA) -> Void) {
        // Keep UIKit's concrete picker and its native presentation/remote-view setup.
        // Subclassing just to retain a delegate changes the controller UIKit presents.
        let picker = UIColorPickerViewController()
        picker.title = title
        picker.supportsAlpha = supportsAlpha
        picker.selectedColor = PresetColour.uiColor(initial)
        let coordinator = SystemColourPicker(initial: initial, commitsOnFinishOnly: commitsOnFinishOnly, onPick: onPick)
        picker.delegate = coordinator
        // UIKit's delegate is weak. Its own controller, not a process-global slot, keeps
        // it alive so opening a picker in another window cannot detach this one.
        objc_setAssociatedObject(picker, &coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        picker.modalPresentationStyle = .formSheet
        picker.presentationController?.delegate = coordinator
        if let sheet = picker.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        PresetPresenter.present(picker, app: app, session: session)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard !finished else { return }
        latest = PresetColour.rgba(color)
        lastPickerSelection = PresetColour.rgba(viewController.selectedColor)
        if !continuously && !commitsOnFinishOnly { commitLatest() }
    }

    // UIKit's HEX field can use the original delegate callback, whereas grid
    // and spectrum gestures use didSelect:continuously:. Both commit the slot.
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        colorPickerViewController(viewController, didSelect: viewController.selectedColor, continuously: false)
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        viewController.viewIfLoaded?.endEditing(true)
        let finalSelection = PresetColour.rgba(viewController.selectedColor)
        // HEX editing can settle after the last selection callback. A previous
        // grid/slider callback must not mask a newer authoritative picker value.
        if latest == nil || finalSelection != lastPickerSelection { latest = finalSelection }
        finish()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let picker = presentationController.presentedViewController as? UIColorPickerViewController {
            colorPickerViewControllerDidFinish(picker)
        } else {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        commitLatest()
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
            // A colour command may arrive while UIKit retracts the swatch's
            // context menu. Present only after that transition has released its
            // controller; otherwise UIKit silently drops the picker presentation.
            let root = navigator.rootViewController
            var top = root
            while let presented = top?.presentedViewController { top = presented }
            if let transition = top?.transitionCoordinator ?? root?.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in
                    navigator.presentModal(viewController)
                }
            } else {
                navigator.presentModal(viewController)
            }
            return
        }
        var top = (session.editor as? UIViewController) ?? session.editor?.canvasHost?.canvasView.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(viewController, animated: true)
    }
}
