import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - State

/// What the format controls show: resolved character attributes plus paragraph and box settings.
struct TextFormatState: Equatable {
    var attrs = TextLayout.resolved(TextAttributes())
    var align: ParagraphAlignment = .natural
    var list: ListKind = .plain
    var indent = 0
    var lineSpacing: Double? = nil
    /// nil for sticky notes (no box style).
    var box: TextBoxStyle? = nil
    /// Lists and indents need a text to act on (off for the default style).
    var canEditParagraphs = true
    var enabled = true

    var family: String { attrs.font ?? RichTextBridge.defaultFontFamily }
    var size: Double { attrs.size ?? RichTextBridge.defaultFontSize }
    var colour: RGBA { attrs.color ?? .black }
    var highlight: RGBA? { attrs.highlight.flatMap { $0.a == 0 ? nil : $0 } }
    var lineSpacingOption: LineSpacingOption { LineSpacingOption.nearest(points: lineSpacing, fontSize: size) }

    func isOn(_ t: TextBoxEditor.Toggle) -> Bool {
        switch t {
        case .bold: return attrs.bold ?? false
        case .italic: return attrs.italic ?? false
        case .underline: return attrs.underline ?? false
        case .strikethrough: return attrs.strikethrough ?? false
        }
    }
}

/// Line spacing offered in the UI, as multiples of the line height (stored as extra points between lines).
enum LineSpacingOption: CaseIterable, Hashable {
    case automatic, relaxed, wide, double

    var multiple: Double {
        switch self {
        case .automatic: return 1
        case .relaxed: return 1.15
        case .wide: return 1.5
        case .double: return 2
        }
    }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Auto")
        case .relaxed: return "1.15"
        case .wide: return "1.5"
        case .double: return "2"
        }
    }

    func points(fontSize: Double) -> Double {
        self == .automatic ? 0 : ((multiple - 1) * fontSize * 1.2 * 10).rounded() / 10
    }

    static func nearest(points: Double?, fontSize: Double) -> LineSpacingOption {
        guard let p = points, p > 0 else { return .automatic }
        return allCases.min { abs($0.points(fontSize: fontSize) - p) < abs($1.points(fontSize: fontSize) - p) } ?? .automatic
    }
}

/// Labels, glyphs and colour choices shared by the inspector and the keyboard bar.
enum TextFormatOptions {
    static let alignments: [ParagraphAlignment] = [.left, .center, .right, .justified]

    static func alignmentTitle(_ a: ParagraphAlignment) -> String {
        switch a {
        case .natural: return String(localized: "Natural")
        case .left: return String(localized: "Left")
        case .center: return String(localized: "Centre")
        case .right: return String(localized: "Right")
        case .justified: return String(localized: "Justify")
        }
    }

    static func alignmentSymbol(_ a: ParagraphAlignment) -> NibSymbol {
        switch a {
        case .center: return symbol("text.aligncenter")
        case .right: return symbol("text.alignright")
        case .justified: return symbol("text.justify")
        case .left, .natural: return symbol("text.alignleft")
        }
    }

    static func listTitle(_ l: ListKind) -> String {
        switch l {
        case .plain: return String(localized: "No List")
        case .bullet: return String(localized: "Bullets")
        case .number: return String(localized: "Numbered (1.)")
        case .numberParen: return String(localized: "Numbered (1))")
        case .todo: return String(localized: "Checklist")
        }
    }

    static func listSymbol(_ l: ListKind) -> NibSymbol {
        switch l {
        case .number, .numberParen: return symbol("list.number")
        case .todo: return symbol("checklist")
        case .bullet, .plain: return symbol("list.bullet")
        }
    }

    /// A formatting glyph by SF Symbol name (NibSymbol has no text-formatting tokens), falling back to the text glyph.
    static func symbol(_ name: String, fallback: NibSymbol = .text) -> NibSymbol {
        NibSymbol(systemName: name) ?? fallback
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

    /// Text highlight: the highlighter hue at its light-paper strength.
    static func highlight(_ h: NibHighlighter) -> RGBA {
        RGBA(nibHex: h.hex, alpha: NibHighlighter.lightPaperOpacity)
    }

    struct Fill: Identifiable {
        let id: String
        let name: String
        let value: RGBA
    }

    /// Box fills: the papers, then the highlighter hues washed out.
    static let fills: [Fill] = [NibPaper.white, .ivory, .legal, .grey].map { p in
        Fill(id: p.rawValue, name: TextFormatOptions.paperName(p), value: RGBA(nibHex: p.hex))
    } + NibHighlighter.allCases.map { h in
        Fill(id: "wash." + h.rawValue, name: TextFormatOptions.highlighterName(h), value: RGBA(nibHex: h.hex, alpha: 0.35))
    }

    static func paperName(_ p: NibPaper) -> String {
        switch p {
        case .white: return String(localized: "White")
        case .ivory: return String(localized: "Ivory")
        case .legal: return String(localized: "Legal Pad")
        case .grey: return String(localized: "Grey")
        case .slate: return String(localized: "Slate")
        case .night: return String(localized: "Night")
        case .board: return String(localized: "Board")
        }
    }

    enum Border: CaseIterable, Hashable {
        case none, thin, thick
        var width: Double {
            switch self {
            case .none: return 0
            case .thin: return 1
            case .thick: return 2.5
            }
        }
        var title: String {
            switch self {
            case .none: return String(localized: "None")
            case .thin: return String(localized: "Thin")
            case .thick: return String(localized: "Thick")
            }
        }
        static func of(_ s: TextBoxStyle) -> Border {
            guard s.borderWidth > 0, s.borderColor != nil else { return .none }
            return s.borderWidth < 1.75 ? .thin : .thick
        }
    }

    enum Corners: CaseIterable, Hashable {
        case square, rounded
        var radius: Double { self == .square ? 0 : 8 }
        var title: String { self == .square ? String(localized: "Square") : String(localized: "Rounded") }
        static func of(_ s: TextBoxStyle) -> Corners { s.cornerRadius > 0 ? .rounded : .square }
    }

    enum Padding: CaseIterable, Hashable {
        case tight, regular, loose
        var points: Double {
            switch self {
            case .tight: return 4
            case .regular: return 8
            case .loose: return 16
            }
        }
        var title: String {
            switch self {
            case .tight: return String(localized: "Tight")
            case .regular: return String(localized: "Regular")
            case .loose: return String(localized: "Loose")
            }
        }
        static func of(_ s: TextBoxStyle) -> Padding {
            allCases.min { abs($0.points - s.padding) < abs($1.points - s.padding) } ?? .tight
        }
    }

    /// Point sizes the size stepper walks through.
    static let sizes: [Double] = [8, 9, 10, 11, 12, 13, 14, 16, 17, 18, 20, 22, 24, 28, 32, 36, 42, 48, 60, 72, 96]
}

/// Font families offered first; any installed family (including user-installed fonts) comes from the font picker.
enum TextFonts {
    static let preferred = ["Helvetica", "Helvetica Neue", "Avenir Next", "Georgia", "Times New Roman", "Palatino",
                            "Baskerville", "Gill Sans", "Futura", "American Typewriter", "Courier New", "Noteworthy",
                            "Marker Felt", "Chalkboard SE", "Bradley Hand", "Snell Roundhand"]

    static var families: [String] {
        let installed = Set(UIFont.familyNames)
        return preferred.filter { installed.contains($0) }
    }
}

extension RGBA {
    /// 0xRRGGBB, ignoring alpha (matching a colour against a palette entry).
    var rgbHex: UInt32 { (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b) }
}

// MARK: - Model

/// Holds the format controls' state and turns every control into a command: `text.format`, `text.setParagraph` and
/// `text.setBoxStyle` for selected boxes (one undo step per action; box styles go to text boxes only, and sticky notes
/// take a style's character and paragraph settings through `text.setText`), the editing overlay for the box being
/// typed in, and `text.saveDefaultStyle` for the style of new boxes.
@MainActor
final class TextFormatModel: ObservableObject {
    enum Kind {
        case items(doc: DocumentID, page: PageID, ids: [ElementID])
        case editing
        case defaults
    }

    let app: NibApp
    weak var session: EditorSession?
    let kind: Kind
    weak var editor: TextBoxEditor?
    @Published private(set) var state = TextFormatState()
    @Published private(set) var styleNames: [String] = []
    @Published private(set) var pinned = false
    private var cancellables = Set<AnyCancellable>()
    private let subscriptions = SubscriptionBag()
    /// The last queued batch of commands (batches run in order).
    private var pending: Task<Void, Never>?

    init(app: NibApp, session: EditorSession?, kind: Kind, editor: TextBoxEditor? = nil) {
        self.app = app
        self.session = session
        self.kind = kind
        self.editor = editor
        switch kind {
        case let .items(doc, page, ids):
            let watched = Set(ids)
            subscriptions.add(app.bus.observeCommits { [weak self] cs in
                let touched = cs.mutations.contains { m in
                    if case let .item(d, p, _, after) = m { return d == doc && p == page && watched.contains(after.id) }
                    return false
                }
                if touched { self?.refresh() }
            })
        case .editing:
            editor?.changes.sink { [weak self] in self?.refresh() }.store(in: &cancellables)
        case .defaults:
            break
        }
        NotificationCenter.default.publisher(for: SettingsStore.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    convenience init(app: NibApp, session: EditorSession?, editor: TextBoxEditor) {
        self.init(app: app, session: session, kind: .editing, editor: editor)
    }

    func refresh() {
        let names = TextSettings.savedNames(app.settings)
        if names != styleNames { styleNames = names }
        let pin = app.settings.get(TextSettings.pinned)
        if pin != pinned { pinned = pin }
        let next: TextFormatState
        switch kind {
        case .editing:
            guard let s = editor?.formatState() else { return }
            next = s
        case .defaults:
            let s = TextStyles.defaultStyle(app.settings)
            next = TextFormatState(attrs: TextLayout.resolved(s.box.defaults), align: s.align ?? .natural, list: .plain,
                                   indent: 0, lineSpacing: s.lineSpacing, box: s.box, canEditParagraphs: false)
        case let .items(doc, page, ids):
            let found = textItems(doc, page, ids)
            guard let item = found.first, let text = TextItems.richText(item) else {
                var off = state
                off.enabled = false
                next = off
                break
            }
            let p = text.paragraphs.first ?? Paragraph()
            let defaults = item.text?.style.defaults ?? TextAttributes()
            // The Text Box section shows when any selected item is a text box, and edits only those.
            next = TextFormatState(attrs: TextLayout.resolved(RichTextEdit.merged(defaults, p.runs.first?.attrs ?? TextAttributes())),
                                   align: p.align, list: p.list, indent: p.indent, lineSpacing: p.lineSpacing,
                                   box: found.first(where: { $0.kind == .text })?.text?.style, canEditParagraphs: true,
                                   enabled: !item.locked)
        }
        if next != state { state = next }
    }

    /// The selected items that carry text, in selection order.
    private func textItems(_ doc: DocumentID, _ page: PageID, _ ids: [ElementID]) -> [Item] {
        ids.compactMap { try? app.workspace.item(doc, page: page, id: $0) }.filter { TextItems.richText($0) != nil }
    }

    private func refs(_ doc: DocumentID, _ page: PageID, _ items: [Item]) -> [JSONValue] {
        items.map { .string(NodeRef.item(doc, page, $0.id).description) }
    }

    // MARK: Character

    func toggle(_ t: TextBoxEditor.Toggle) {
        if case .editing = kind {
            editor?.toggle(t)
            return
        }
        var a = TextAttributes()
        switch t {
        case .bold: a.bold = !state.isOn(.bold)
        case .italic: a.italic = !state.isOn(.italic)
        case .underline: a.underline = !state.isOn(.underline)
        case .strikethrough: a.strikethrough = !state.isOn(.strikethrough)
        }
        setAttributes(a)
    }

    func setFont(_ family: String) { setAttributes(TextAttributes(font: family, code: false)) }

    func setSize(_ size: Double) { setAttributes(TextAttributes(size: min(max(4, size), 400))) }

    /// One step up or down the size list.
    func stepSize(_ direction: Int) {
        let current = state.size
        let larger = TextFormatOptions.sizes.first(where: { $0 > current + 0.01 }) ?? min(400, current + 12)
        let smaller = TextFormatOptions.sizes.last(where: { $0 < current - 0.01 }) ?? max(4, current - 1)
        setSize(direction > 0 ? larger : smaller)
    }

    func setColour(_ c: RGBA) { setAttributes(TextAttributes(color: c)) }

    /// nil removes the highlight.
    func setHighlight(_ c: RGBA?) { setAttributes(TextAttributes(highlight: c ?? .clear)) }

    func setAttributes(_ a: TextAttributes) {
        switch kind {
        case .editing:
            editor?.applyAttributes(a)
        case .defaults:
            changeDefault { $0.box.defaults = RichTextEdit.merged($0.box.defaults, a) }
        case let .items(doc, page, ids):
            let attrs = (try? JSONValue.from(a)) ?? [:]
            run(refs(doc, page, textItems(doc, page, ids)).map { ref -> (String, JSONValue) in
                ("text.format", ["ref": ref, "attrs": attrs])
            })
        }
    }

    // MARK: Paragraph

    func setAlign(_ a: ParagraphAlignment) { setParagraph(align: a) }
    func setList(_ l: ListKind) { setParagraph(list: l) }
    func indent(_ by: Int) { setParagraph(indentBy: by) }
    func setLineSpacing(_ o: LineSpacingOption) { setParagraph(lineSpacing: o.points(fontSize: state.size)) }

    func setParagraph(align: ParagraphAlignment? = nil, list: ListKind? = nil, indentBy: Int? = nil, lineSpacing: Double? = nil) {
        switch kind {
        case .editing:
            editor?.applyParagraph(align: align, list: list, indentBy: indentBy, lineSpacing: lineSpacing)
        case .defaults:
            changeDefault { s in
                if let a = align { s.align = a == .natural ? nil : a }
                if let l = lineSpacing { s.lineSpacing = l > 0 ? min(l, 100) : nil }
            }
        case let .items(doc, page, ids):
            var fields: [String: JSONValue] = [:]
            if let a = align { fields["align"] = .string(a.rawValue) }
            if let l = list { fields["list"] = .string(l.rawValue) }
            if let d = indentBy { fields["indentBy"] = .number(Double(d)) }
            if let l = lineSpacing { fields["lineSpacing"] = .number(l) }
            guard !fields.isEmpty else { return }
            run(refs(doc, page, textItems(doc, page, ids)).map { ref -> (String, JSONValue) in
                var f = fields
                f["ref"] = ref
                return ("text.setParagraph", .object(f))
            })
        }
    }

    // MARK: Box

    /// Box style fields (merged over the current style). Selected sticky notes have no box style and are left alone.
    func setBox(_ fields: [String: JSONValue]) {
        switch kind {
        case .editing:
            editor?.applyBoxStyle(.object(fields))
        case .defaults:
            changeDefault { s in
                if let merged = try? SavedTextStyle(json: s.json.merging(.object(fields))) { s = merged }
            }
        case let .items(doc, page, ids):
            let boxes = refs(doc, page, textItems(doc, page, ids).filter { $0.kind == .text })
            guard !boxes.isEmpty else { return }
            run([("text.setBoxStyle", ["refs": .array(boxes), "style": .object(fields)])])
        }
    }

    func setBorder(_ b: TextFormatOptions.Border) {
        setBox(["borderWidth": .number(b.width), "borderColor": b == .none ? .null : .string(state.colour.hex)])
    }

    // MARK: Styles

    /// A preset (Title, Heading, Body, Caption): the paragraphs being edited, or the whole of each selected item.
    func applyPreset(_ id: String) {
        guard let s = TextPresets.apply(id, to: TextStyles.defaultStyle(app.settings)) else { return }
        switch kind {
        case .editing:
            editor?.applyParagraphStyle(s)
        case .defaults:
            changeDefault { current in current = TextPresets.apply(id, to: current) ?? current }
        case let .items(doc, page, ids):
            var defaults = s.box.defaults
            defaults.link = nil
            defaults.attachment = nil
            let fields: [String: JSONValue] = ["defaults": (try? JSONValue.from(defaults)) ?? [:],
                                               "align": .string((s.align ?? .natural).rawValue),
                                               "lineSpacing": .number(s.lineSpacing ?? 0)]
            applyStyle(s, boxFields: fields, doc: doc, page: page, ids: ids)
        }
    }

    /// A saved named style: the whole box takes its look.
    func applyNamed(_ name: String) {
        guard let s = TextStyles.named(name, app.settings), case .object(let fields) = s.json else { return }
        switch kind {
        case .defaults:
            saveDefault(s)
        case .editing:
            setBox(fields)
        case let .items(doc, page, ids):
            applyStyle(s, boxFields: fields, doc: doc, page: page, ids: ids)
        }
    }

    /// A style on the selected items, as one undo step: text boxes take `boxFields` as their box style
    /// (`text.setBoxStyle`); sticky notes and other items without a box style take the style's character and paragraph
    /// settings on all of their text (`text.setText`, one write per item).
    private func applyStyle(_ s: SavedTextStyle, boxFields: [String: JSONValue], doc: DocumentID, page: PageID,
                            ids: [ElementID]) {
        let found = textItems(doc, page, ids)
        var calls: [(String, JSONValue)] = []
        let boxes = refs(doc, page, found.filter { $0.kind == .text })
        if !boxes.isEmpty { calls.append(("text.setBoxStyle", ["refs": .array(boxes), "style": .object(boxFields)])) }
        for item in found where item.kind != .text {
            guard let text = TextItems.richText(item), let styled = try? JSONValue.from(s.styling(text)) else { continue }
            calls.append(("text.setText", ["ref": .string(NodeRef.item(doc, page, item.id).description), "text": styled]))
        }
        run(calls)
    }

    /// The current look as a style.
    func currentStyle() -> SavedTextStyle {
        switch kind {
        case .editing:
            return editor?.currentSavedStyle() ?? TextStyles.defaultStyle(app.settings)
        case .defaults:
            return TextStyles.defaultStyle(app.settings)
        case let .items(doc, page, ids):
            guard let item = ids.compactMap({ try? self.app.workspace.item(doc, page: page, id: $0) }).first,
                  let text = TextItems.richText(item) else { return TextStyles.defaultStyle(app.settings) }
            var box = item.text?.style ?? TextStyles.defaultStyle(app.settings).box
            let p = text.paragraphs.first ?? Paragraph()
            box.defaults = RichTextEdit.merged(box.defaults, p.runs.first?.attrs ?? TextAttributes())
            box.defaults.link = nil
            box.defaults.attachment = nil
            return SavedTextStyle(box: box, align: p.align == .natural ? nil : p.align, lineSpacing: p.lineSpacing)
        }
    }

    func saveAsDefault() { saveDefault(currentStyle()) }

    func saveStyle(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard TextSettings.isValidName(name) else { return }
        run([("text.saveDefaultStyle", ["name": .string(name), "style": currentStyle().json])])
    }

    func deleteStyle(named name: String) {
        run([(CommandIDs.settingsSet, ["name": .string(TextSettings.stylesPrefix + name), "value": .null])])
    }

    func setPinned(_ on: Bool) {
        run([(CommandIDs.settingsSet, ["name": .string(TextSettings.pinned.name), "value": .bool(on)])])
    }

    private func saveDefault(_ s: SavedTextStyle) {
        run([("text.saveDefaultStyle", ["style": s.json])])
    }

    /// Changes the style of new boxes. `change` runs when the batch does, on the default saved by then, so quick
    /// successive changes build on each other instead of the last one restoring what the first removed.
    private func changeDefault(_ change: @escaping (inout SavedTextStyle) -> Void) {
        enqueue { [weak self] in
            guard let self = self else { return }
            var s = TextStyles.defaultStyle(self.app.settings)
            change(&s)
            await self.execute([("text.saveDefaultStyle", ["style": s.json])])
        }
    }

    // MARK: Running commands

    /// Runs the calls in order as one undo step (after any batch still running), then refreshes.
    private func run(_ calls: [(String, JSONValue)]) {
        guard !calls.isEmpty else { return }
        enqueue { [weak self] in await self?.execute(calls) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = pending
        pending = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func execute(_ calls: [(String, JSONValue)]) async {
        let group = NibID.make().raw
        for (command, params) in calls {
            do {
                _ = try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                                                         session: session, group: group))
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
                break
            }
        }
        refresh()
    }

    /// Waits for the queued commands (tests).
    func flush() async {
        await pending?.value
    }
}

/// Cancels commit observers when the model goes away.
final class SubscriptionBag {
    private var items: [EventSubscription] = []

    func add(_ s: EventSubscription) { items.append(s) }

    deinit {
        for s in items { s.cancel() }
    }
}

// MARK: - Inspector

/// The text format inspector (T-056): style presets and saved styles, font and size, emphasis, paragraph, colour,
/// highlight and box style. Shown for selected text boxes and sticky notes (`InspectorDescriptor`), in the text tool's
/// settings (the style of new boxes) and from the keyboard bar while typing.
struct TextFormatInspector: View {
    @ObservedObject var model: TextFormatModel
    var showsPin = false
    @State var showsFontPicker = false
    @State var naming = false
    @State var styleName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            TextStylesSection(model: model, naming: $naming)
            TextFontSection(model: model, showsFontPicker: $showsFontPicker)
            TextEmphasisSection(model: model)
            TextParagraphSection(model: model)
            TextColourSection(model: model)
            if model.state.box != nil {
                TextBoxStyleSection(model: model)
            }
            if showsPin {
                NibToggle(String(localized: "Keep Text Tool Selected"),
                          isOn: Binding(get: { model.pinned }, set: { model.setPinned($0) }))
            }
        }
        .disabled(!model.state.enabled)
        .nibSheet(isPresented: $showsFontPicker) {
            FontPickerSheet { family in model.setFont(family) }
        }
        .alert(String(localized: "Save Text Style"), isPresented: $naming) {
            TextField(String(localized: "Name"), text: $styleName)
            Button(String(localized: "Save")) {
                model.saveStyle(named: styleName)
                styleName = ""
            }
            .disabled(!TextSettings.isValidName(styleName.trimmingCharacters(in: .whitespaces)))
            Button(String(localized: "Cancel"), role: .cancel) { styleName = "" }
        } message: {
            Text(String(localized: "Saved styles appear in the Style row of every text box. Names use up to 40 letters, digits, spaces, hyphens or underscores."))
        }
    }
}

/// The inspector for selected items, owning its model. `identity` gives each selection its own view (and model):
/// a `@StateObject` built from init parameters would otherwise outlive the selection it was made for.
@MainActor
struct TextItemsInspector: View {
    @StateObject private var model: TextFormatModel

    init(app: NibApp, session: EditorSession, doc: DocumentID, page: PageID, ids: [ElementID]) {
        _model = StateObject(wrappedValue: TextFormatModel(app: app, session: session, kind: .items(doc: doc, page: page, ids: ids)))
    }

    static func identity(doc: DocumentID, page: PageID, ids: [ElementID]) -> String {
        ([doc.raw, page.raw] + ids.map { $0.raw }).joined(separator: "/")
    }

    var body: some View {
        TextFormatInspector(model: model)
    }
}

/// The text tool's settings popover: formats the box being edited, else sets the style of new boxes; plus Pin.
/// `identity` tells the two apart, so a view made before editing started never keeps editing the defaults.
@MainActor
struct TextToolSettingsView: View {
    @StateObject private var model: TextFormatModel

    init(app: NibApp, session: EditorSession) {
        let editing = TextBoxEditor.editor(for: session)?.editingState?.model
        _model = StateObject(wrappedValue: editing ?? TextFormatModel(app: app, session: session, kind: .defaults))
    }

    static func identity(_ session: EditorSession) -> String {
        TextBoxEditor.editor(for: session)?.editingRef ?? "defaults"
    }

    var body: some View {
        TextFormatInspector(model: model, showsPin: true)
    }
}

private struct TextStylesSection: View {
    @ObservedObject var model: TextFormatModel
    @Binding var naming: Bool

    var body: some View {
        NibInspectorSection(String(localized: "Style"), action: NibAction(String(localized: "Save Style…")) { naming = true }) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NibSpacing.s) {
                    ForEach(TextPresets.ids, id: \.self) { id in
                        NibChip(TextPresets.title(id), style: .filter(isSelected: false), action: { model.applyPreset(id) })
                    }
                    ForEach(model.styleNames, id: \.self) { name in
                        NibChip(name, style: .filter(isSelected: false), action: { model.applyNamed(name) })
                            .contextMenu {
                                Button(role: .destructive) {
                                    model.deleteStyle(named: name)
                                } label: {
                                    Text(String(localized: "Delete Style"))
                                }
                            }
                            .accessibilityAction(named: String(localized: "Delete Style")) {
                                model.deleteStyle(named: name)
                            }
                    }
                }
                .padding(.vertical, NibSpacing.xs)
            }
            NibButton(String(localized: "Set as Default for New Text"), kind: .plain, size: .compact) {
                model.saveAsDefault()
            }
        }
    }
}

private struct TextFontSection: View {
    @ObservedObject var model: TextFormatModel
    @Binding var showsFontPicker: Bool

    var body: some View {
        NibInspectorSection(String(localized: "Font"), value: String(localized: "\(Int(model.state.size.rounded())) pt")) {
            HStack(spacing: NibSpacing.xs) {
                Menu {
                    ForEach(TextFonts.families, id: \.self) { family in
                        Button(family) { model.setFont(family) }
                    }
                    Divider()
                    Button(String(localized: "All Fonts…")) { showsFontPicker = true }
                } label: {
                    HStack(spacing: NibSpacing.xs) {
                        Text(model.state.family)
                            .font(NibFont.body)
                            .foregroundStyle(NibColor.label)
                            .lineLimit(1)
                        Spacer(minLength: NibSpacing.xs)
                        Image(nib: .chevronDown)
                            .font(NibFont.footnote)
                            .foregroundStyle(NibColor.labelSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, NibSpacing.m)
                    .frame(minHeight: NibMetrics.hitTarget)
                    .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
                }
                .accessibilityLabel(String(localized: "Font"))
                .accessibilityValue(model.state.family)
                NibIconButton(.minus, label: String(localized: "Smaller Text"), size: .panel) { model.stepSize(-1) }
                    .accessibilityValue(String(localized: "\(Int(model.state.size.rounded())) pt"))
                NibIconButton(.plus, label: String(localized: "Larger Text"), size: .panel) { model.stepSize(1) }
                    .accessibilityValue(String(localized: "\(Int(model.state.size.rounded())) pt"))
            }
        }
    }
}

private struct TextEmphasisSection: View {
    @ObservedObject var model: TextFormatModel

    var body: some View {
        NibInspectorSection(String(localized: "Emphasis")) {
            HStack(spacing: NibSpacing.s) {
                FormatToggleButton(label: Text(verbatim: "B").font(NibFont.bodyEmphasis), name: String(localized: "Bold"),
                                   isOn: model.state.isOn(.bold)) { model.toggle(.bold) }
                FormatToggleButton(label: Text(verbatim: "I").font(NibFont.body.italic()), name: String(localized: "Italic"),
                                   isOn: model.state.isOn(.italic)) { model.toggle(.italic) }
                FormatToggleButton(label: Text(verbatim: "U").font(NibFont.body).underline(), name: String(localized: "Underline"),
                                   isOn: model.state.isOn(.underline)) { model.toggle(.underline) }
                FormatToggleButton(label: Text(verbatim: "S").font(NibFont.body).strikethrough(),
                                   name: String(localized: "Strikethrough"),
                                   isOn: model.state.isOn(.strikethrough)) { model.toggle(.strikethrough) }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct FormatToggleButton: View {
    let label: Text
    let name: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(NibColor.label)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .background(isOn ? NibColor.fill3 : Color.clear,
                            in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct TextParagraphSection: View {
    @ObservedObject var model: TextFormatModel

    var body: some View {
        NibInspectorSection(String(localized: "Paragraph")) {
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                NibSegmentedControl(selection: Binding(get: { model.state.align == .natural ? .left : model.state.align },
                                                       set: { model.setAlign($0) }),
                                    options: TextFormatOptions.alignments,
                                    title: { TextFormatOptions.alignmentTitle($0) })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(localized: "Alignment"))
                NibSegmentedControl(selection: Binding(get: { model.state.lineSpacingOption }, set: { model.setLineSpacing($0) }),
                                    options: LineSpacingOption.allCases,
                                    title: { $0.title })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(localized: "Line Spacing"))
                if model.state.canEditParagraphs {
                    HStack(spacing: NibSpacing.xs) {
                        Menu {
                            ForEach(ListKind.allCases, id: \.self) { kind in
                                Button(TextFormatOptions.listTitle(kind)) { model.setList(kind) }
                            }
                        } label: {
                            HStack(spacing: NibSpacing.xs) {
                                Image(nib: TextFormatOptions.listSymbol(model.state.list))
                                    .font(NibFont.body)
                                    .accessibilityHidden(true)
                                Text(TextFormatOptions.listTitle(model.state.list))
                                    .font(NibFont.body)
                                    .lineLimit(1)
                                Spacer(minLength: NibSpacing.xs)
                                Image(nib: .chevronDown)
                                    .font(NibFont.footnote)
                                    .foregroundStyle(NibColor.labelSecondary)
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(NibColor.label)
                            .padding(.horizontal, NibSpacing.m)
                            .frame(minHeight: NibMetrics.hitTarget)
                            .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
                        }
                        .accessibilityLabel(String(localized: "List"))
                        .accessibilityValue(TextFormatOptions.listTitle(model.state.list))
                        NibIconButton(TextFormatOptions.symbol("decrease.indent", fallback: .back),
                                      label: String(localized: "Decrease Indent"), size: .panel) { model.indent(-1) }
                            .disabled(model.state.indent == 0)
                        NibIconButton(TextFormatOptions.symbol("increase.indent", fallback: .forward),
                                      label: String(localized: "Increase Indent"), size: .panel) { model.indent(1) }
                            .disabled(model.state.indent >= AutoList.maxIndent)
                    }
                }
            }
        }
    }
}

private struct TextColourSection: View {
    @ObservedObject var model: TextFormatModel
    let columns = Array(repeating: GridItem(.fixed(NibMetrics.hitTarget), spacing: 0), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            NibInspectorSection(String(localized: "Colour")) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(NibInk.allCases, id: \.self) { ink in
                        NibPenSwatch(NibSwatch(ink: ink), isSelected: model.state.colour.rgbHex == ink.hex) {
                            model.setColour(RGBA(nibHex: ink.hex))
                        }
                    }
                }
                ColorPicker(String(localized: "Custom Colour"),
                            selection: Binding(get: { Color(uiColor: model.state.colour.uiColor) },
                                               set: { model.setColour(RGBA(UIColor($0))) }),
                            supportsOpacity: false)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                    .frame(minHeight: NibMetrics.hitTarget)
            }
            NibInspectorSection(String(localized: "Highlight"),
                                action: NibAction(String(localized: "Remove Highlight")) { model.setHighlight(nil) }) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(NibHighlighter.allCases, id: \.self) { h in
                        NibPenSwatch(NibSwatch(id: h.rawValue, color: h.color, name: TextFormatOptions.highlighterName(h)),
                                     isSelected: model.state.highlight?.rgbHex == h.hex) {
                            model.setHighlight(TextFormatOptions.highlight(h))
                        }
                    }
                }
            }
        }
    }
}

private struct TextBoxStyleSection: View {
    @ObservedObject var model: TextFormatModel
    let columns = Array(repeating: GridItem(.fixed(NibMetrics.hitTarget), spacing: 0), count: 6)

    var body: some View {
        let box = model.state.box ?? TextBoxStyle()
        return NibInspectorSection(String(localized: "Text Box"),
                                   action: NibAction(String(localized: "Remove Fill")) { model.setBox(["background": .null]) }) {
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(TextFormatOptions.fills) { fill in
                        NibPenSwatch(NibSwatch(id: fill.id, color: Color(uiColor: fill.value.uiColor), name: fill.name),
                                     isSelected: box.background == fill.value) {
                            model.setBox(["background": .string(fill.value.hex)])
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Fill"))
                NibSegmentedControl(selection: Binding(get: { TextFormatOptions.Border.of(box) }, set: { model.setBorder($0) }),
                                    options: TextFormatOptions.Border.allCases, title: { $0.title })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(localized: "Border"))
                NibSegmentedControl(selection: Binding(get: { TextFormatOptions.Corners.of(box) },
                                                       set: { model.setBox(["cornerRadius": .number($0.radius)]) }),
                                    options: TextFormatOptions.Corners.allCases, title: { $0.title })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(localized: "Corners"))
                NibSegmentedControl(selection: Binding(get: { TextFormatOptions.Padding.of(box) },
                                                       set: { model.setBox(["padding": .number($0.points)]) }),
                                    options: TextFormatOptions.Padding.allCases, title: { $0.title })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(localized: "Padding"))
                NibToggle(String(localized: "Shadow"),
                          isOn: Binding(get: { box.shadow }, set: { model.setBox(["shadow": .bool($0)]) }))
                NibToggle(String(localized: "Fit Height to Text"),
                          isOn: Binding(get: { box.autoGrow }, set: { model.setBox(["autoGrow": .bool($0)]) }))
            }
        }
    }
}

/// The system font picker (installed and user-installed families).
struct FontPickerSheet: UIViewControllerRepresentable {
    let onPick: (String) -> Void

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let config = UIFontPickerViewController.Configuration()
        config.includeFaces = false
        let picker = UIFontPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIFontPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let onPick: (String) -> Void

        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }

        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            if let family = viewController.selectedFontDescriptor?.object(forKey: .family) as? String, !family.hasPrefix(".") {
                onPick(family)
            }
            viewController.dismiss(animated: true)
        }

        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
            viewController.dismiss(animated: true)
        }
    }
}

// MARK: - Keyboard bar

/// The formatting bar above the keyboard while a text box is edited (system input-accessory style, opaque): style,
/// font and size, B / I / U / S, colour and highlight, alignment, lists and indent, line spacing, More, Done.
final class TextKeyboardBar: UIInputView {
    var onDone: (() -> Void)?
    var onMore: ((UIView) -> Void)?
    var onFonts: ((UIView) -> Void)?

    private let model: TextFormatModel
    private var cancellables = Set<AnyCancellable>()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var toggles: [TextBoxEditor.Toggle: UIButton] = [:]
    private var styleButton: UIButton?
    private var fontButton: UIButton?
    private var smallerButton: UIButton?
    private var largerButton: UIButton?
    private var sizeLabel = UILabel()
    private var colourButton: UIButton?
    private var highlightButton: UIButton?
    private var alignButton: UIButton?
    private var listButton: UIButton?
    private var spacingButton: UIButton?

    init(model: TextFormatModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: NibMetrics.hitTarget + NibSpacing.xs), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
        model.$state.sink { [weak self] s in self?.update(s) }.store(in: &cancellables)
        model.$styleNames.sink { [weak self] _ in self?.updateStyleMenu() }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func build() {
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = NibSpacing.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)

        let style = button(symbol: .text, label: String(localized: "Text Style"))
        style.showsMenuAsPrimaryAction = true
        styleButton = style
        let font = button(title: model.state.family, label: String(localized: "Font"))
        font.showsMenuAsPrimaryAction = true
        fontButton = font
        let smaller = button(symbol: .minus, label: String(localized: "Smaller Text")) { [weak self] in self?.model.stepSize(-1) }
        let larger = button(symbol: .plus, label: String(localized: "Larger Text")) { [weak self] in self?.model.stepSize(1) }
        smallerButton = smaller
        largerButton = larger
        sizeLabel.font = NibUIFont.hud
        sizeLabel.textColor = NibUIColor.label
        sizeLabel.adjustsFontForContentSizeCategory = true
        // VoiceOver hears the size as the value of Smaller Text and Larger Text.
        sizeLabel.isAccessibilityElement = false

        let bold = toggleButton(.bold, title: "B", font: NibUIFont.font(.body, weight: .bold), label: String(localized: "Bold"))
        let italicFont = NibUIFont.body.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: 0) } ?? NibUIFont.body
        let italic = toggleButton(.italic, title: "I", font: italicFont, label: String(localized: "Italic"))
        let underline = toggleButton(.underline, title: "U", font: NibUIFont.body, label: String(localized: "Underline"),
                                     extra: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        let strike = toggleButton(.strikethrough, title: "S", font: NibUIFont.body, label: String(localized: "Strikethrough"),
                                  extra: [.strikethroughStyle: NSUnderlineStyle.single.rawValue])

        let colour = button(symbol: nil, label: String(localized: "Text Colour"))
        colour.showsMenuAsPrimaryAction = true
        colourButton = colour
        let highlight = button(symbol: .highlighter, label: String(localized: "Highlight"))
        highlight.showsMenuAsPrimaryAction = true
        highlightButton = highlight
        let align = button(symbol: TextFormatOptions.alignmentSymbol(.left), label: String(localized: "Alignment"))
        align.showsMenuAsPrimaryAction = true
        alignButton = align
        let list = button(symbol: TextFormatOptions.listSymbol(.bullet), label: String(localized: "List"))
        list.showsMenuAsPrimaryAction = true
        listButton = list
        let outdent = button(symbol: TextFormatOptions.symbol("decrease.indent", fallback: .back),
                             label: String(localized: "Decrease Indent")) { [weak self] in self?.model.indent(-1) }
        let indent = button(symbol: TextFormatOptions.symbol("increase.indent", fallback: .forward),
                            label: String(localized: "Increase Indent")) { [weak self] in self?.model.indent(1) }
        let spacing = button(symbol: TextFormatOptions.symbol("arrow.up.and.down.text.horizontal", fallback: .sort),
                             label: String(localized: "Line Spacing"))
        spacing.showsMenuAsPrimaryAction = true
        spacingButton = spacing
        let more = button(symbol: .moreCircle, label: String(localized: "More Formatting"))
        more.addAction(UIAction { [weak self, weak more] _ in
            if let self = self, let more = more { self.onMore?(more) }
        }, for: .primaryActionTriggered)

        for view in [style, font, smaller, sizeLabel, larger, separator(), bold, italic, underline, strike, separator(),
                     colour, highlight, separator(), align, list, outdent, indent, spacing, separator(), more] as [UIView] {
            stack.addArrangedSubview(view)
        }

        let done = button(title: String(localized: "Done"), label: String(localized: "Finish Editing")) { [weak self] in
            self?.onDone?()
        }
        done.translatesAutoresizingMaskIntoConstraints = false
        addSubview(done)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: NibSpacing.xs),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: NibSpacing.xxs),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -NibSpacing.xxs),
            scroll.heightAnchor.constraint(equalToConstant: NibMetrics.hitTarget),
            scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -NibSpacing.xs),
            done.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -NibSpacing.xs),
            done.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        update(model.state)
        updateStyleMenu()
    }

    private func button(symbol: NibSymbol? = nil, title: String? = nil, label: String,
                        action: (() -> Void)? = nil) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = NibUIColor.label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: NibSpacing.s, bottom: 0, trailing: NibSpacing.s)
        config.background.cornerRadius = NibRadius.field
        if let symbol = symbol {
            config.image = UIImage(nib: symbol)
            config.preferredSymbolConfigurationForImage = NibUIFont.glyph(.panel)
        }
        if let title = title {
            config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: NibUIFont.barTitle]))
            config.titleLineBreakMode = .byTruncatingTail
        }
        let b = UIButton(configuration: config, primaryAction: action.map { run in UIAction { _ in run() } })
        b.accessibilityLabel = label
        b.isPointerInteractionEnabled = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: NibMetrics.hitTarget).isActive = true
        b.heightAnchor.constraint(equalToConstant: NibMetrics.hitTarget).isActive = true
        return b
    }

    private func toggleButton(_ t: TextBoxEditor.Toggle, title: String, font: UIFont, label: String,
                              extra: [NSAttributedString.Key: Any] = [:]) -> UIButton {
        let b = button(label: label) { [weak self] in self?.model.toggle(t) }
        var attrs = extra
        attrs[.font] = font
        b.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer(attrs))
        toggles[t] = b
        return b
    }

    private func separator() -> UIView {
        let v = UIView()
        v.backgroundColor = NibUIColor.separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)).isActive = true
        v.heightAnchor.constraint(equalToConstant: NibSpacing.xxl).isActive = true
        v.isAccessibilityElement = false
        return v
    }

    private static func swatchImage(_ colour: UIColor) -> UIImage {
        let d: CGFloat = 22
        return UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { _ in
            let rect = CGRect(x: 0.5, y: 0.5, width: d - 1, height: d - 1)
            colour.setFill()
            UIBezierPath(ovalIn: rect).fill()
            NibUIColor.swatchHairline.setStroke()
            let ring = UIBezierPath(ovalIn: rect)
            ring.lineWidth = 0.5
            ring.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    private func update(_ s: TextFormatState) {
        for (t, b) in toggles {
            let on = s.isOn(t)
            b.configuration?.background.backgroundColor = on ? NibUIColor.fill3 : .clear
            b.accessibilityTraits = on ? [.button, .selected] : [.button]
        }
        fontButton?.configuration?.attributedTitle = AttributedString(s.family, attributes: AttributeContainer([.font: NibUIFont.barTitle]))
        fontButton?.accessibilityValue = s.family
        let size = String(localized: "\(Int(s.size.rounded())) pt")
        sizeLabel.text = size
        smallerButton?.accessibilityValue = size
        largerButton?.accessibilityValue = size
        colourButton?.configuration?.image = TextKeyboardBar.swatchImage(s.colour.uiColor)
        colourButton?.accessibilityValue = NibInk.allCases.first { $0.hex == s.colour.rgbHex }?.name
        alignButton?.configuration?.image = UIImage(nib: TextFormatOptions.alignmentSymbol(s.align))
        alignButton?.accessibilityValue = TextFormatOptions.alignmentTitle(s.align)
        listButton?.configuration?.image = UIImage(nib: TextFormatOptions.listSymbol(s.list))
        listButton?.accessibilityValue = TextFormatOptions.listTitle(s.list)
        spacingButton?.accessibilityValue = s.lineSpacingOption.title

        let fonts: [UIMenuElement] = TextFonts.families.map { family in
            UIAction(title: family, state: family == s.family ? .on : .off) { [weak self] _ in self?.model.setFont(family) }
        }
        fontButton?.menu = UIMenu(children: fonts + [UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "All Fonts…")) { [weak self] _ in
                if let self = self, let button = self.fontButton { self.onFonts?(button) }
            }
        ])])
        colourButton?.menu = UIMenu(children: NibInk.allCases.map { ink in
            UIAction(title: ink.name, image: TextKeyboardBar.swatchImage(ink.uiColor),
                     state: ink.hex == s.colour.rgbHex ? .on : .off) { [weak self] _ in
                self?.model.setColour(RGBA(nibHex: ink.hex))
            }
        })
        highlightButton?.menu = UIMenu(children: [UIAction(title: String(localized: "No Highlight"),
                                                           state: s.highlight == nil ? .on : .off) { [weak self] _ in
            self?.model.setHighlight(nil)
        }] + NibHighlighter.allCases.map { h in
            UIAction(title: TextFormatOptions.highlighterName(h), image: TextKeyboardBar.swatchImage(h.uiColor),
                     state: s.highlight?.rgbHex == h.hex ? .on : .off) { [weak self] _ in
                self?.model.setHighlight(TextFormatOptions.highlight(h))
            }
        })
        alignButton?.menu = UIMenu(children: TextFormatOptions.alignments.map { a in
            UIAction(title: TextFormatOptions.alignmentTitle(a), image: UIImage(nib: TextFormatOptions.alignmentSymbol(a)),
                     state: (s.align == .natural ? .left : s.align) == a ? .on : .off) { [weak self] _ in self?.model.setAlign(a) }
        })
        listButton?.menu = UIMenu(children: ListKind.allCases.map { l in
            UIAction(title: TextFormatOptions.listTitle(l), image: UIImage(nib: TextFormatOptions.listSymbol(l)),
                     state: s.list == l ? .on : .off) { [weak self] _ in self?.model.setList(l) }
        })
        spacingButton?.menu = UIMenu(title: String(localized: "Line Spacing"), children: LineSpacingOption.allCases.map { o in
            UIAction(title: o.title, state: s.lineSpacingOption == o ? .on : .off) { [weak self] _ in self?.model.setLineSpacing(o) }
        })
    }

    private func updateStyleMenu() {
        let presets = TextPresets.ids.map { id in
            UIAction(title: TextPresets.title(id)) { [weak self] _ in self?.model.applyPreset(id) }
        }
        let named = model.styleNames.map { name in
            UIAction(title: name) { [weak self] _ in self?.model.applyNamed(name) }
        }
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: presets)]
        if !named.isEmpty { children.append(UIMenu(options: .displayInline, children: named)) }
        children.append(UIAction(title: String(localized: "Set as Default for New Text")) { [weak self] _ in
            self?.model.saveAsDefault()
        })
        styleButton?.menu = UIMenu(children: children)
    }
}
