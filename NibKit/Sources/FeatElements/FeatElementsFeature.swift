import SwiftUI
import UIKit
import NibContracts
import NibDesign

/// F035 Elements (stickers) & GIF search: the Elements tool (M, non-sticky) with its Stickers / GIFs popover,
/// element collections stored as fragments in the library's elements folder, content-pack collections, `.nibcollection`
/// import and export, "Create Element" in the object menu, and GIPHY search with the user's own key.
public enum FeatElementsFeature: NibFeature {
    public static let id = "elements"

    public static func register(_ app: NibApp) {
        ElementSettings.declare(app.settings, owner: id)
        app.services.set(ElementsRuntime(content: app.content), for: ElementsRuntime.key)
        ElementCommandSet.register(app.commands)

        app.ui.canvasTools.register(CanvasToolDescriptor(id: ElementsTool.toolID, title: String(localized: "Elements"),
                                                         order: 800, owner: id) { ElementsTool() })
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: ElementsTool.toolID, title: String(localized: "Elements"), icon: NibSymbol.elements.name, group: .tools,
            order: 800, owner: id, toolID: ElementsTool.toolID, shortcut: KeyShortcut("m"),
            settings: { session in AnyView(ElementsPopover(app: app, session: session)) }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "elements.createElement", title: String(localized: "Create Element"), icon: NibSymbol.elements.name,
            location: .objectMenu, order: 760, owner: id, command: "element.create",
            params: { ctx in ElementMenu.createParams(ctx) }, isVisible: { ctx in ElementMenu.canCreate(ctx) }))
        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: ElementsSettingsPage.id, title: String(localized: "Elements and GIFs"), icon: NibSymbol.elements.name,
            section: .editing, order: 700, owner: id, makeView: { app in AnyView(ElementsSettingsView(app: app)) }))
        // `import.files` (F064) hands .nibcollection files here.
        app.content.importers.register(ImporterDescriptor(
            id: "elements.nibcollection", title: String(localized: "Element Collection"),
            fileExtensions: [ElementArchive.fileExtension], utTypes: [ElementArchive.typeIdentifier], owner: id) { url, _, ctx in
                _ = try await ElementImport.importCollection(from: url, ctx: ctx)
                return []
            })
    }

    /// First launch of a library on this device: write the starter collections off the main actor, so the first
    /// popover opens on ready content.
    public static func start(_ app: NibApp) async {
        guard app.services.library != nil else { return }
        let catalog = ElementCatalog(services: app.services, clock: app.clock)
        _ = try? await ElementIO.run { catalog.prepare() }
    }
}

// MARK: - Tool

/// The Elements canvas tool: its popover (the toolbar item's `settings`, budded from the palette) does the work. It is
/// non-sticky: an insert hands the palette back to the previous tool, and so does a tap on the page.
@MainActor
final class ElementsTool: CanvasTool {
    static let toolID = "elements"

    var id: String { ElementsTool.toolID }
    var inputMode: CanvasInputMode { .taps }
    var isSticky: Bool { false }

    func tap(_ sample: CanvasSample, host: CanvasHost) {
        let session = host.session
        guard let previous = session.previousTool, previous != id else { return }
        host.app.perform(CommandIDs.toolSelect, ["tool": .string(previous)], session: session)
    }
}

// MARK: - Object menu

/// "Create Element" in the object menu: saves the selection into the collection the popover showed last when it is
/// one of yours, otherwise into My Elements. No file I/O here (this runs on the main actor): `element.create`
/// checks the collection on its I/O queue and falls back (`fallback: true`).
@MainActor
enum ElementMenu {
    static func canCreate(_ ctx: MenuContext) -> Bool {
        guard !ctx.selection.isEmpty, ctx.selection.doc != nil, ctx.selection.page != nil else { return false }
        return ctx.itemKinds.isEmpty || !ctx.itemKinds.isSubset(of: [.comment])
    }

    static func createParams(_ ctx: MenuContext) -> JSONValue {
        let last = ctx.app.settings.get(ElementSettings.lastCollection)
        let collection = NibID.isValid(last) ? last : ElementStore.defaultCollectionID
        return ["refs": .array(ctx.selection.refs.map { .string($0) }), "collection": .string(collection),
                "fallback": .bool(true)]
    }
}

// MARK: - Starter collections

/// The collections a fresh library starts with (T-068): SF Symbol stickers, labels, arrows and planner icons. Fixed
/// ids, so two devices that both start fresh write the same records and merge; a deleted one stays deleted.
enum StarterElements {
    static let stickers = "starter-stickers"
    static let labels = "starter-labels"
    static let arrows = "starter-arrows"
    static let planner = "starter-planner"
    static let ids = [stickers, labels, arrows, planner]

    /// Builds every starter collection (renders the symbol stickers; call off the main actor).
    static func make() -> [StarterCollection] {
        let order = FractionalIndex.sequence(after: nil, count: ids.count)
        return [
            StarterCollection(id: stickers, title: String(localized: "Stickers"), order: order[0],
                              elements: stickerSpecs.compactMap(symbolSticker)),
            StarterCollection(id: labels, title: String(localized: "Labels"), order: order[1],
                              elements: labelSpecs.map(label)),
            StarterCollection(id: arrows, title: String(localized: "Arrows"), order: order[2], elements: arrowElements()),
            StarterCollection(id: planner, title: String(localized: "Planner"), order: order[3],
                              elements: plannerSpecs.compactMap(symbolSticker)),
        ]
    }

    struct SymbolSpec {
        let id: String
        let symbol: String
        let title: String
        let ink: NibInk
    }

    static var stickerSpecs: [SymbolSpec] {
        [
            SymbolSpec(id: "star", symbol: "star.fill", title: String(localized: "Star"), ink: .ochre),
            SymbolSpec(id: "heart", symbol: "heart.fill", title: String(localized: "Heart"), ink: .crimson),
            SymbolSpec(id: "bolt", symbol: "bolt.fill", title: String(localized: "Lightning"), ink: .ochre),
            SymbolSpec(id: "flame", symbol: "flame.fill", title: String(localized: "Flame"), ink: .vermilion),
            SymbolSpec(id: "leaf", symbol: "leaf.fill", title: String(localized: "Leaf"), ink: .moss),
            SymbolSpec(id: "sun", symbol: "sun.max.fill", title: String(localized: "Sun"), ink: .ochre),
            SymbolSpec(id: "moon", symbol: "moon.stars.fill", title: String(localized: "Moon"), ink: .midnight),
            SymbolSpec(id: "cloud", symbol: "cloud.fill", title: String(localized: "Cloud"), ink: .cobalt),
            SymbolSpec(id: "thumbs-up", symbol: "hand.thumbsup.fill", title: String(localized: "Thumbs Up"), ink: .cobalt),
            SymbolSpec(id: "clap", symbol: "hands.clap.fill", title: String(localized: "Applause"), ink: .sienna),
            SymbolSpec(id: "trophy", symbol: "trophy.fill", title: String(localized: "Trophy"), ink: .ochre),
            SymbolSpec(id: "crown", symbol: "crown.fill", title: String(localized: "Crown"), ink: .ochre),
            SymbolSpec(id: "rosette", symbol: "rosette", title: String(localized: "Rosette"), ink: .crimson),
            SymbolSpec(id: "seal", symbol: "checkmark.seal.fill", title: String(localized: "Approved"), ink: .moss),
            SymbolSpec(id: "flag", symbol: "flag.fill", title: String(localized: "Flag"), ink: .vermilion),
            SymbolSpec(id: "bell", symbol: "bell.fill", title: String(localized: "Bell"), ink: .ochre),
            SymbolSpec(id: "gift", symbol: "gift.fill", title: String(localized: "Gift"), ink: .plum),
            SymbolSpec(id: "lightbulb", symbol: "lightbulb.fill", title: String(localized: "Idea"), ink: .ochre),
            SymbolSpec(id: "music", symbol: "music.note", title: String(localized: "Music"), ink: .plum),
            SymbolSpec(id: "paw", symbol: "pawprint.fill", title: String(localized: "Paw Print"), ink: .sienna),
            SymbolSpec(id: "graduation", symbol: "graduationcap.fill", title: String(localized: "Graduation"), ink: .midnight),
            SymbolSpec(id: "brain", symbol: "brain.head.profile", title: String(localized: "Think"), ink: .plum),
            SymbolSpec(id: "globe", symbol: "globe.europe.africa.fill", title: String(localized: "Globe"), ink: .lagoon),
            SymbolSpec(id: "smile", symbol: "face.smiling.inverse", title: String(localized: "Smile"), ink: .ochre),
        ]
    }

    static var plannerSpecs: [SymbolSpec] {
        [
            SymbolSpec(id: "calendar", symbol: "calendar", title: String(localized: "Calendar"), ink: .cobalt),
            SymbolSpec(id: "clock", symbol: "clock.fill", title: String(localized: "Time"), ink: .graphite),
            SymbolSpec(id: "alarm", symbol: "alarm.fill", title: String(localized: "Alarm"), ink: .vermilion),
            SymbolSpec(id: "done", symbol: "checkmark.circle.fill", title: String(localized: "Done"), ink: .moss),
            SymbolSpec(id: "open", symbol: "circle", title: String(localized: "To Do"), ink: .graphite),
            SymbolSpec(id: "important", symbol: "exclamationmark.circle.fill", title: String(localized: "Important"), ink: .vermilion),
            SymbolSpec(id: "question", symbol: "questionmark.circle.fill", title: String(localized: "Question"), ink: .cobalt),
            SymbolSpec(id: "pin", symbol: "pin.fill", title: String(localized: "Pin"), ink: .crimson),
            SymbolSpec(id: "bookmark", symbol: "bookmark.fill", title: String(localized: "Bookmark"), ink: .cobalt),
            SymbolSpec(id: "study", symbol: "book.fill", title: String(localized: "Study"), ink: .sienna),
            SymbolSpec(id: "homework", symbol: "pencil.and.list.clipboard", title: String(localized: "Homework"), ink: .midnight),
            SymbolSpec(id: "shopping", symbol: "cart.fill", title: String(localized: "Shopping"), ink: .lagoon),
            SymbolSpec(id: "home", symbol: "house.fill", title: String(localized: "Home"), ink: .sienna),
            SymbolSpec(id: "work", symbol: "briefcase.fill", title: String(localized: "Work"), ink: .graphite),
            SymbolSpec(id: "exercise", symbol: "figure.run", title: String(localized: "Exercise"), ink: .moss),
            SymbolSpec(id: "coffee", symbol: "cup.and.saucer.fill", title: String(localized: "Break"), ink: .sienna),
            SymbolSpec(id: "travel", symbol: "airplane", title: String(localized: "Travel"), ink: .cobalt),
            SymbolSpec(id: "call", symbol: "phone.fill", title: String(localized: "Call"), ink: .moss),
            SymbolSpec(id: "mail", symbol: "envelope.fill", title: String(localized: "Mail"), ink: .cobalt),
            SymbolSpec(id: "meeting", symbol: "person.2.fill", title: String(localized: "Meeting"), ink: .plum),
            SymbolSpec(id: "water", symbol: "drop.fill", title: String(localized: "Water"), ink: .lagoon),
            SymbolSpec(id: "sleep", symbol: "bed.double.fill", title: String(localized: "Sleep"), ink: .midnight),
            SymbolSpec(id: "medicine", symbol: "pills.fill", title: String(localized: "Medicine"), ink: .crimson),
            SymbolSpec(id: "birthday", symbol: "birthday.cake.fill", title: String(localized: "Birthday"), ink: .plum),
            SymbolSpec(id: "money", symbol: "banknote.fill", title: String(localized: "Money"), ink: .moss),
        ]
    }

    /// An SF Symbol rendered once as a PNG image item (56 pt on the long side, 3× pixels so it stays sharp when zoomed).
    /// Symbols this OS does not have are skipped.
    static func symbolSticker(_ s: SymbolSpec) -> StarterElement? {
        guard let symbol = NibSymbol(systemName: s.symbol), let base = UIImage(nib: symbol),
              let glyph = base.applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 96, weight: .regular)) else {
            return nil
        }
        let tinted = glyph.withTintColor(s.ink.uiColor, renderingMode: .alwaysOriginal)
        let size = tinted.size
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            tinted.draw(in: CGRect(origin: .zero, size: size))
        }
        let k = 56 / Double(max(size.width, size.height))
        let name = "starter-\(s.id).png"
        let frame = Frame(x: 0, y: 0, w: Double(size.width) * k, h: Double(size.height) * k)
        let item = Item.makeImage(ImageItem(frame: frame, asset: AssetRef(name), altText: s.title))
        return StarterElement(id: s.id, title: s.title, fragment: ElementFragment(items: [item], assets: [name: png]))
    }

    struct LabelSpec {
        let id: String
        let title: String
        let ink: NibInk
    }

    static var labelSpecs: [LabelSpec] {
        [
            LabelSpec(id: "important", title: String(localized: "Important"), ink: .vermilion),
            LabelSpec(id: "to-do", title: String(localized: "To do"), ink: .cobalt),
            LabelSpec(id: "done", title: String(localized: "Done"), ink: .moss),
            LabelSpec(id: "in-progress", title: String(localized: "In progress"), ink: .ochre),
            LabelSpec(id: "review", title: String(localized: "Review"), ink: .plum),
            LabelSpec(id: "exam", title: String(localized: "Exam"), ink: .crimson),
            LabelSpec(id: "homework", title: String(localized: "Homework"), ink: .midnight),
            LabelSpec(id: "due", title: String(localized: "Due"), ink: .sienna),
            LabelSpec(id: "idea", title: String(localized: "Idea"), ink: .lagoon),
            LabelSpec(id: "question", title: String(localized: "Question"), ink: .cobalt),
            LabelSpec(id: "note", title: String(localized: "Note"), ink: .graphite),
            LabelSpec(id: "urgent", title: String(localized: "Urgent"), ink: .crimson),
        ]
    }

    /// A capsule text box: bold ink text on a 14 % wash of the same ink, with a thin border.
    static func label(_ s: LabelSpec) -> StarterElement {
        let colour = s.ink.rgba
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun(s.title, TextAttributes(size: 15, color: colour, bold: true))],
                                                   align: .center)])
        let measured = RichTextBridge.attributed(text).boundingRect(with: CGSize(width: 1_000, height: 200),
                                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                                     context: nil)
        let pad = 7.0
        let w = ceil(Double(measured.width)) + 2 * pad + 16
        let h = ceil(Double(measured.height)) + 2 * pad
        let style = TextBoxStyle(background: colour.withAlpha(0.14), borderColor: colour, borderWidth: 1.2,
                                 cornerRadius: h / 2, padding: pad, autoGrow: false)
        let item = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: w, h: h), text: text, style: style))
        return StarterElement(id: s.id, title: s.title, fragment: ElementFragment(items: [item]))
    }

    /// Editable shape arrows (lines, curves and elbows with arrowheads) in Carbon.
    static func arrowElements() -> [StarterElement] {
        func arrow(_ id: String, _ title: String, _ kind: ShapeKind, _ points: [Point], start: Bool = false,
                   pattern: StrokePattern = .solid) -> StarterElement {
            let style = ShapeItemStyle(strokeColor: NibInk.carbon.rgba, strokeWidth: 2.5, fillColor: nil, cornerRadius: 0,
                                       pattern: pattern, arrowStart: start, arrowEnd: true)
            let frame = Frame(Rect.bounding(points) ?? .zero)
            let item = Item.makeShape(ShapeItem(shape: kind, frame: frame, points: points, style: style))
            return StarterElement(id: id, title: title, fragment: ElementFragment(items: [item]))
        }
        return [
            arrow("arrow-right", String(localized: "Arrow Right"), .line, [Point(0, 0), Point(120, 0)]),
            arrow("arrow-left", String(localized: "Arrow Left"), .line, [Point(120, 0), Point(0, 0)]),
            arrow("arrow-up", String(localized: "Arrow Up"), .line, [Point(0, 120), Point(0, 0)]),
            arrow("arrow-down", String(localized: "Arrow Down"), .line, [Point(0, 0), Point(0, 120)]),
            arrow("arrow-up-right", String(localized: "Arrow Up Right"), .line, [Point(0, 100), Point(100, 0)]),
            arrow("arrow-down-right", String(localized: "Arrow Down Right"), .line, [Point(0, 0), Point(100, 100)]),
            arrow("arrow-both", String(localized: "Two-Way Arrow"), .line, [Point(0, 0), Point(140, 0)], start: true),
            arrow("arrow-both-vertical", String(localized: "Two-Way Arrow Vertical"), .line, [Point(0, 0), Point(0, 140)],
                  start: true),
            arrow("arrow-curve", String(localized: "Curved Arrow"), .curve, [Point(0, 60), Point(60, 0), Point(120, 60)]),
            arrow("arrow-curve-down", String(localized: "Curved Arrow Down"), .curve, [Point(0, 0), Point(90, 10), Point(100, 100)]),
            arrow("arrow-u-turn", String(localized: "U-Turn Arrow"), .curve, [Point(0, 80), Point(40, -40), Point(80, 80)]),
            arrow("arrow-elbow", String(localized: "Elbow Arrow"), .polyline, [Point(0, 0), Point(0, 80), Point(110, 80)]),
            arrow("arrow-step", String(localized: "Step Arrow"), .polyline, [Point(0, 80), Point(60, 80), Point(60, 0), Point(120, 0)]),
            arrow("arrow-dashed", String(localized: "Dashed Arrow"), .line, [Point(0, 0), Point(120, 0)], pattern: .dashed),
        ]
    }
}

extension NibInk {
    /// The ink as page content colour (inks are never themed).
    var rgba: RGBA { RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF)) }
}
