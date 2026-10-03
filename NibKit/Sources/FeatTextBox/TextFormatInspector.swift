import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - State

/// The emphasis toggles' glyphs (NibDesign v2 text-formatting tokens) and names.
extension TextBoxEditor.Toggle {
    var symbol: NibSymbol {
        switch self {
        case .bold: return .bold
        case .italic: return .italic
        case .underline: return .underline
        case .strikethrough: return .strikethrough
        }
    }

    var title: String {
        switch self {
        case .bold: return String(localized: "Bold")
        case .italic: return String(localized: "Italic")
        case .underline: return String(localized: "Underline")
        case .strikethrough: return String(localized: "Strikethrough")
        }
    }

    static let all: [TextBoxEditor.Toggle] = [.bold, .italic, .underline, .strikethrough]
}

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
        case .center: return .alignCentre
        case .right: return .alignRight
        case .justified: return .justify
        case .left, .natural: return .alignLeft
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
        case .number, .numberParen: return .listNumbered
        case .todo: return .checklist
        case .bullet, .plain: return .listBulleted
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
        Fill(id: p.rawValue, name: p.name, value: RGBA(nibHex: p.hex))
    } + NibHighlighter.allCases.map { h in
        Fill(id: "wash." + h.rawValue, name: h.name, value: RGBA(nibHex: h.hex, alpha: 0.35))
    }

    /// A box fill as a swatch (papers ringed where they vanish against the chrome).
    static func swatch(_ fill: Fill) -> NibSwatch {
        if let paper = NibPaper(rawValue: fill.id) { return NibSwatch(paper: paper) }
        return NibSwatch(id: fill.id, color: Color(uiColor: fill.value.uiColor), name: fill.name)
    }

    /// The text colour as a swatch: its ink, else a custom colour.
    static func swatch(colour: RGBA) -> NibSwatch {
        if let ink = NibInk.allCases.first(where: { $0.hex == colour.rgbHex }) { return NibSwatch(ink: ink) }
        return NibSwatch(id: "text.colour", hex: colour.rgbHex, name: String(localized: "Custom Colour"))
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
                (CommandIDs.textFormat, ["ref": ref, "attrs": attrs])
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
                return (CommandIDs.textSetParagraph, .object(f))
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
            run([(CommandIDs.textSetBoxStyle, ["refs": .array(boxes), "style": .object(fields)])])
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
        if !boxes.isEmpty { calls.append((CommandIDs.textSetBoxStyle, ["refs": .array(boxes), "style": .object(boxFields)])) }
        for item in found where item.kind != .text {
            guard let text = TextItems.richText(item), let styled = try? JSONValue.from(s.styling(text)) else { continue }
            calls.append((CommandIDs.textSetText, ["ref": .string(NodeRef.item(doc, page, item.id).description), "text": styled]))
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
        run([(CommandIDs.textSaveDefaultStyle, ["name": .string(name), "style": currentStyle().json])])
    }

    func deleteStyle(named name: String) {
        run([(CommandIDs.settingsSet, ["name": .string(TextSettings.stylesPrefix + name), "value": .null])])
    }

    func setPinned(_ on: Bool) {
        run([(CommandIDs.settingsSet, ["name": .string(TextSettings.pinned.name), "value": .bool(on)])])
    }

    private func saveDefault(_ s: SavedTextStyle) {
        run([(CommandIDs.textSaveDefaultStyle, ["style": s.json])])
    }

    /// Changes the style of new boxes. `change` runs when the batch does, on the default saved by then, so quick
    /// successive changes build on each other instead of the last one restoring what the first removed.
    private func changeDefault(_ change: @escaping (inout SavedTextStyle) -> Void) {
        enqueue { [weak self] in
            guard let self = self else { return }
            var s = TextStyles.defaultStyle(self.app.settings)
            change(&s)
            await self.execute([(CommandIDs.textSaveDefaultStyle, ["style": s.json])])
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
        .background(TextStyleNamePrompt(model: model, isPresented: $naming))
    }
}

/// SwiftUI's alert builder can discard TextField accessibility modifiers when it creates
/// the native alert. Configure the actual input so its name survives typing and VoiceOver focus.
struct TextStyleNamePrompt: UIViewControllerRepresentable {
    let model: TextFormatModel
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> Controller {
        Controller(model: model, isPresented: $isPresented)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isPresented = $isPresented
        controller.updatePresentation()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.dismissPrompt()
    }

    final class Controller: UIViewController {
        let model: TextFormatModel
        var isPresented: Binding<Bool>
        private weak var prompt: UIAlertController?
        private weak var save: UIAlertAction?

        init(model: TextFormatModel, isPresented: Binding<Bool>) {
            self.model = model
            self.isPresented = isPresented
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { return nil }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updatePresentation()
        }

        func updatePresentation() {
            // Wait until SwiftUI finishes attaching/updating the containing controller.
            DispatchQueue.main.async { [weak self] in self?.presentIfNeeded() }
        }

        func dismissPrompt() {
            prompt?.dismiss(animated: false)
            prompt = nil
        }

        private func presentIfNeeded() {
            guard isPresented.wrappedValue else {
                prompt?.dismiss(animated: true)
                return
            }
            guard viewIfLoaded?.window != nil, prompt == nil, presentedViewController == nil else { return }
            let alert = UIAlertController(title: String(localized: "Save Text Style"),
                message: String(localized: "Saved styles appear in the Style row of every text box. Names use up to 40 letters, digits, spaces, hyphens or underscores."),
                preferredStyle: .alert)
            alert.addTextField { [weak self] field in
                field.placeholder = String(localized: "Name")
                field.accessibilityLabel = String(localized: "Name")
                field.accessibilityIdentifier = "text.style.name"
                field.addAction(UIAction { [weak self, weak field] _ in
                    guard let field else { return }
                    self?.nameChanged(field)
                }, for: .editingChanged)
            }
            let save = UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
                guard let self else { return }
                self.model.saveStyle(named: alert?.textFields?.first?.text ?? "")
                self.isPresented.wrappedValue = false
            }
            save.isEnabled = false
            alert.addAction(save)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
                self?.isPresented.wrappedValue = false
            })
            self.save = save
            prompt = alert
            present(alert, animated: true)
        }

        private func nameChanged(_ field: UITextField) {
            save?.isEnabled = TextSettings.isValidName((field.text ?? "").trimmingCharacters(in: .whitespaces))
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

/// Ids of the keyboard bar's More popover in the window's droplet container.
enum TextPopoverIDs {
    static let popover = "text.format.popover"
    /// The bud source: the More button's rect.
    static let source = "text.format.more"
}

/// Paragraph pickers use the same above-keyboard presentation as More. Native UIButton menus
/// in an input accessory can be positioned underneath the keyboard's separate window.
enum TextFormatPanel {
    case inspector, alignment, list, lineSpacing, styles

    var title: String {
        switch self {
        case .inspector: return String(localized: "Format")
        case .alignment: return String(localized: "Alignment")
        case .list: return String(localized: "List")
        case .lineSpacing: return String(localized: "Line Spacing")
        case .styles: return String(localized: "Text Style")
        }
    }

    var choices: [TextParagraphChoice] {
        switch self {
        case .inspector, .styles: return []
        case .alignment: return TextFormatOptions.alignments.map(TextParagraphChoice.alignment)
        case .list: return ListKind.allCases.map(TextParagraphChoice.list)
        case .lineSpacing: return LineSpacingOption.allCases.map(TextParagraphChoice.spacing)
        }
    }
}

enum TextParagraphChoice: Hashable {
    case alignment(ParagraphAlignment), list(ListKind), spacing(LineSpacingOption)

    var title: String {
        switch self {
        case .alignment(let value): return TextFormatOptions.alignmentTitle(value)
        case .list(let value): return TextFormatOptions.listTitle(value)
        case .spacing(let value): return value.title
        }
    }

    func isSelected(in state: TextFormatState) -> Bool {
        switch self {
        case .alignment(let value): return value == (state.align == .natural ? .left : state.align)
        case .list(let value): return value == state.list
        case .spacing(let value): return value == state.lineSpacingOption
        }
    }

    @MainActor func apply(to model: TextFormatModel) {
        switch self {
        case .alignment(let value): model.setAlign(value)
        case .list(let value): model.setList(value)
        case .spacing(let value): model.setLineSpacing(value)
        }
    }
}

struct TextFormatPanelContent: View {
    let panel: TextFormatPanel
    @ObservedObject var model: TextFormatModel
    var onChoose: () -> Void

    var body: some View {
        if panel == .inspector {
            TextFormatInspector(model: model)
        } else if panel == .styles {
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                ForEach(TextPresets.ids, id: \.self) { id in
                    NibButton(TextPresets.title(id), kind: .plain) {
                        model.applyPreset(id)
                        onChoose()
                    }
                }
                ForEach(model.styleNames, id: \.self) { name in
                    NibButton(name, kind: .plain) {
                        model.applyNamed(name)
                        onChoose()
                    }
                }
                NibButton(String(localized: "Set as Default for New Text"), kind: .plain) {
                    model.saveAsDefault()
                    onChoose()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                ForEach(panel.choices, id: \.self) { choice in
                    NibButton(choice.title, symbol: choice.isSelected(in: model.state) ? .checkmark : nil, kind: .plain) {
                        choice.apply(to: model)
                        onChoose()
                    }
                    .accessibilityAddTraits(choice.isSelected(in: model.state) ? .isSelected : [])
                }
            }
        }
    }
}

/// The More popover's open state. The floating host keeps the popover while a box is edited; this opens it, and a tap
/// outside or Escape closes it (`onClose` gives the text view the keyboard back).
@MainActor
final class TextPopoverState: ObservableObject {
    @Published var panel: TextFormatPanel = .inspector
    @Published var isPresented = false {
        didSet { if oldValue && !isPresented { onClose?() } }
    }
    /// Available content height above the keyboard; the editor uses this budget to select its presentation.
    @Published var contentHeight: CGFloat = NibMetrics.popoverMaxHeight - TextFormatPopover.chromeHeight
    /// The usable window ends above the accessory, even when the floating host ignores keyboard safe areas.
    @Published var viewportHeight: CGFloat = NibMetrics.popoverMaxHeight
    var onClose: (() -> Void)?
}

/// The format inspector as a Deep popover budded from the keyboard bar's More button (DESIGN.md §14.3: tool popovers
/// are Deep `NibPopoverPanel`s budded from their control), shown through the window's floating host.
struct TextFormatPopover: View {
    @ObservedObject var state: TextPopoverState
    let model: TextFormatModel

    /// The popover's title row and the padding around the inspector.
    static let chromeHeight: CGFloat = 2 * NibSpacing.l + NibSpacing.m + NibMetrics.hitTarget
    /// With less room than this above the keyboard, a system popover shows the inspector instead.
    static let minimumHeight: CGFloat = NibMetrics.popoverMaxHeight / 2

    var body: some View {
        NibBudPopover(id: TextPopoverIDs.popover, source: TextPopoverIDs.source, isPresented: $state.isPresented,
                      title: state.panel.title, placement: .above) {
            // NibBudPopover owns the vertical scroll view. Nesting a fixed-height scroll view
            // here traps edge drags in the outer panel and strands the lower box controls.
            TextFormatPanelContent(panel: state.panel, model: model) { state.isPresented = false }
        }
        .frame(height: state.viewportHeight)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct TextStylesSection: View {
    @ObservedObject var model: TextFormatModel
    @Binding var naming: Bool

    var body: some View {
        NibInspectorSection(String(localized: "Style"), action: NibAction(String(localized: "Save Style…")) { naming = true }) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NibSpacing.s) {
                        ForEach(TextPresets.ids, id: \.self) { id in
                            NibChip(TextPresets.title(id), style: .filter(isSelected: false), action: { model.applyPreset(id) })
                        }
                        ForEach(model.styleNames, id: \.self) { name in
                            NibChip(name, style: .filter(isSelected: false), action: { model.applyNamed(name) })
                                .id("saved." + name)
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
                .onChange(of: model.styleNames) { before, after in
                    if let added = after.first(where: { !before.contains($0) }) {
                        proxy.scrollTo("saved." + added, anchor: .trailing)
                    }
                }
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
                ForEach(TextBoxEditor.Toggle.all, id: \.self) { t in
                    NibIconButton(t.symbol, label: t.title, size: .panel, isOn: model.state.isOn(t)) { model.toggle(t) }
                }
                Spacer(minLength: 0)
            }
        }
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
                        NibIconButton(.outdent, label: String(localized: "Decrease Indent"), size: .panel) { model.indent(-1) }
                            .disabled(model.state.indent == 0)
                        NibIconButton(.indent, label: String(localized: "Increase Indent"), size: .panel) { model.indent(1) }
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
                        NibPenSwatch(NibSwatch(highlighter: h), isSelected: model.state.highlight?.rgbHex == h.hex) {
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
                        NibPenSwatch(TextFormatOptions.swatch(fill), isSelected: box.background == fill.value) {
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
    var onParagraph: ((TextFormatPanel, UIView) -> Void)?

    private let model: TextFormatModel
    private var cancellables = Set<AnyCancellable>()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var toggles: [TextBoxEditor.Toggle: UIButton] = [:]
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
        routeParagraphButton(style, to: .styles)
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

        let emphasis = TextBoxEditor.Toggle.all.map { toggleButton($0) }

        let colour = button(symbol: nil, label: String(localized: "Text Colour"))
        colour.showsMenuAsPrimaryAction = true
        colourButton = colour
        let highlight = button(symbol: .highlighter, label: String(localized: "Highlight"))
        highlight.showsMenuAsPrimaryAction = true
        highlightButton = highlight
        let align = button(symbol: TextFormatOptions.alignmentSymbol(.left), label: String(localized: "Alignment"))
        routeParagraphButton(align, to: .alignment)
        alignButton = align
        let list = button(symbol: TextFormatOptions.listSymbol(.bullet), label: String(localized: "List"))
        routeParagraphButton(list, to: .list)
        listButton = list
        let outdent = button(symbol: .outdent, label: String(localized: "Decrease Indent")) { [weak self] in self?.model.indent(-1) }
        let indent = button(symbol: .indent, label: String(localized: "Increase Indent")) { [weak self] in self?.model.indent(1) }
        let spacing = button(symbol: .lineSpacing, label: String(localized: "Line Spacing"))
        routeParagraphButton(spacing, to: .lineSpacing)
        spacingButton = spacing
        let more = button(symbol: .moreCircle, label: String(localized: "More Formatting"))
        more.addAction(UIAction { [weak self, weak more] _ in
            if let self = self, let more = more { self.onMore?(more) }
        }, for: .primaryActionTriggered)

        var views: [UIView] = [style, font, smaller, sizeLabel, larger, separator()]
        views += emphasis as [UIView]
        views += [separator(), colour, highlight, separator(), align, list, outdent, indent, spacing, separator(), more]
        for view in views {
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

    private func toggleButton(_ t: TextBoxEditor.Toggle) -> UIButton {
        let b = button(symbol: t.symbol, label: t.title) { [weak self] in self?.model.toggle(t) }
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
        colourButton?.configuration?.image = UIImage.nibSwatch(TextFormatOptions.swatch(colour: s.colour))
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
            UIAction(title: ink.name, image: UIImage.nibSwatch(NibSwatch(ink: ink)),
                     state: ink.hex == s.colour.rgbHex ? .on : .off) { [weak self] _ in
                self?.model.setColour(RGBA(nibHex: ink.hex))
            }
        })
        highlightButton?.menu = UIMenu(children: [UIAction(title: String(localized: "No Highlight"),
                                                           state: s.highlight == nil ? .on : .off) { [weak self] _ in
            self?.model.setHighlight(nil)
        }] + NibHighlighter.allCases.map { h in
            UIAction(title: h.name, image: UIImage.nibSwatch(NibSwatch(highlighter: h)),
                     state: s.highlight?.rgbHex == h.hex ? .on : .off) { [weak self] _ in
                self?.model.setHighlight(TextFormatOptions.highlight(h))
            }
        })

    }

    private func routeParagraphButton(_ button: UIButton, to panel: TextFormatPanel) {
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let button else { return }
            self?.onParagraph?(panel, button)
        }, for: .primaryActionTriggered)
    }

}
