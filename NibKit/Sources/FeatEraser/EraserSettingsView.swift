import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Copy

extension EraserMode {
    var title: String {
        switch self {
        case .precision: return String(localized: "Precision")
        case .standard: return String(localized: "Standard")
        case .stroke: return String(localized: "Whole stroke")
        }
    }

    var detail: String {
        switch self {
        case .precision: return String(localized: "Cuts ink exactly where the eraser passes.")
        case .standard: return String(localized: "Removes the parts of strokes you touch.")
        case .stroke: return String(localized: "Removes every stroke you touch, whole.")
        }
    }
}

extension InkTool {
    var eraserFilterTitle: String {
        switch self {
        case .pen: return String(localized: "Pen")
        case .pencil: return String(localized: "Pencil")
        case .highlighter: return String(localized: "Highlighter")
        case .tape: return String(localized: "Tape")
        }
    }
}

enum EraserSizeFormat {
    static func label(_ size: Double) -> String {
        String(localized: "\(Int(size.rounded())) pt")
    }

    static func presetName(_ index: Int, _ size: Double) -> String {
        let points = Int(size.rounded())
        switch index {
        case 0: return String(localized: "Small eraser, \(points) points")
        case 1: return String(localized: "Medium eraser, \(points) points")
        default: return String(localized: "Large eraser, \(points) points")
        }
    }
}

// MARK: - Settings model

/// The eraser settings as the popover and the options bar see them. Reads come from `SettingsStore`; every change the
/// user makes goes through `settings.set`, the same command plugins and the AI use.
@MainActor
final class EraserOptions: ObservableObject {
    private let app: NibApp
    /// True while values are being read back from the store, so reading never writes.
    private var isReloading = false
    /// Slider drags are written once the finger rests (~120 ms), not on every frame.
    private var sizeWrite: Task<Void, Never>?
    private var subscription: AnyCancellable?

    @Published var mode = EraserMode.standard {
        didSet { if !isReloading && mode != oldValue { write(EraserSettings.mode.name, .string(mode.rawValue)) } }
    }
    @Published var size = 14.0 {
        didSet { if !isReloading && size != oldValue { scheduleSizeWrite() } }
    }
    @Published var autoDeselect = false {
        didSet { if !isReloading && autoDeselect != oldValue { write(EraserSettings.autoDeselect.name, .bool(autoDeselect)) } }
    }
    @Published private(set) var filter: Set<InkTool> = Set(InkTool.allCases) {
        didSet {
            guard !isReloading else { return }
            for tool in InkTool.allCases where filter.contains(tool) != oldValue.contains(tool) {
                write(EraserSettings.filterKey(tool).name, .bool(filter.contains(tool)))
            }
        }
    }

    init(app: NibApp) {
        self.app = app
        reload()
        subscription = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let name = note.userInfo?["name"] as? String, name.hasPrefix("eraser.") else { return }
                MainActor.assumeIsolated { self?.reload() }
            }
    }

    func reload() {
        let s = app.settings
        isReloading = true
        mode = s.get(EraserSettings.mode)
        if sizeWrite == nil { size = EraserSettings.clamped(s.get(EraserSettings.size)) }
        filter = EraserSettings.filter(s)
        autoDeselect = s.get(EraserSettings.autoDeselect)
        isReloading = false
    }

    /// Turns one ink tool on or off in the Erase Filter; the last one left stays on (an eraser that erases nothing
    /// would look broken).
    func toggle(_ tool: InkTool) {
        if filter.contains(tool) {
            guard filter.count > 1 else { return }
            filter.remove(tool)
        } else {
            filter.insert(tool)
        }
    }

    /// "Highlighter only" (Goodnotes' Erase Highlighter Only) and the like: exactly one ink tool.
    func only(_ tool: InkTool) {
        filter = [tool]
    }

    private func scheduleSizeWrite() {
        sizeWrite?.cancel()
        sizeWrite = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self.sizeWrite = nil
            self.write(EraserSettings.size.name, .number(EraserSettings.clamped(self.size)))
        }
    }

    private func write(_ name: String, _ value: JSONValue) {
        app.perform(CommandIDs.settingsSet, ["name": .string(name), "value": value])
    }
}

// MARK: - Tool popover

/// The eraser's settings popover (DESIGN.md §14.3): mode, size presets and slider, Erase Filter, Auto-deselect and
/// Clear Page. The palette wraps it in a Deep `NibPopoverPanel` budded from the tool.
struct EraserSettingsView: View {
    private let app: NibApp
    @ObservedObject private var session: EditorSession
    @StateObject private var model: EraserOptions
    @State private var confirmingClear = false

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self._session = ObservedObject(wrappedValue: session)
        self._model = StateObject(wrappedValue: EraserOptions(app: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xl) {
            NibInspectorSection(String(localized: "Mode")) {
                NibSegmentedControl(selection: $model.mode, options: EraserMode.allCases, title: { $0.title })
                Text(model.mode.detail)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NibInspectorSection(String(localized: "Size"), value: EraserSizeFormat.label(model.size)) {
                HStack(spacing: NibSpacing.s) {
                    EraserSizePresets(model: model)
                }
                NibSlider(value: $model.size, in: EraserSettings.sizeRange,
                          label: String(localized: "Eraser size"), detents: EraserSettings.presets)
            }
            NibInspectorSection(String(localized: "Erase filter"),
                                action: NibAction(String(localized: "Erase Highlighter Only")) { model.only(.highlighter) }) {
                EraserFilterChips(model: model)
            }
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                NibToggle(String(localized: "Auto-deselect"), isOn: $model.autoDeselect)
                Text(String(localized: "Go back to the previous tool when you lift the eraser."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NibButton(String(localized: "Clear Page"), symbol: .trash, kind: .destructive, expands: true) {
                confirmingClear = true
            }
            .disabled(session.document == nil || session.page == nil || session.readOnly)
            .confirmationDialog(String(localized: "Clear this page?"), isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button(String(localized: "Clear Page"), role: .destructive) { clearPage() }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "Everything on this page is removed. You can undo this."))
            }
        }
    }

    private func clearPage() {
        guard let doc = session.document, let page = session.page else { return }
        app.perform("page.clear", ["page": .string(NodeRef.page(doc, page).description)], session: session)
    }
}

/// Three size presets drawn as dots of growing size (T-093); the slider covers everything in between.
struct EraserSizePresets: View {
    @ObservedObject var model: EraserOptions

    var body: some View {
        ForEach(Array(EraserSettings.presets.enumerated()), id: \.offset) { index, preset in
            let selected = abs(model.size - preset) < 0.5
            Button {
                model.size = preset
            } label: {
                Circle()
                    .fill(NibColor.label)
                    .frame(width: dot(index), height: dot(index))
                    .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                    .background(selected ? NibColor.fill3 : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(NibPressStyle(shape: Circle()))
            .accessibilityLabel(EraserSizeFormat.presetName(index, preset))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func dot(_ index: Int) -> CGFloat {
        switch index {
        case 0: return 6
        case 1: return 11
        default: return 17
        }
    }
}

/// Erase Filter chips (T-019). Four chips fit one row at the default size; at large type they wrap to two rows of
/// two, so no chip ever wraps its label.
struct EraserFilterChips: View {
    @ObservedObject var model: EraserOptions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NibSpacing.s) { chips(InkTool.allCases) }
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                HStack(spacing: NibSpacing.s) { chips(Array(InkTool.allCases.prefix(2))) }
                HStack(spacing: NibSpacing.s) { chips(Array(InkTool.allCases.dropFirst(2))) }
            }
        }
    }

    private func chips(_ tools: [InkTool]) -> some View {
        ForEach(tools, id: \.self) { tool in
            let on = model.filter.contains(tool)
            // A checkmark carries the on state too: never shade alone.
            NibChip(tool.eraserFilterTitle, symbol: on ? NibSymbol.checkmark : nil, style: .filter(isSelected: on),
                    action: { model.toggle(tool) })
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint(String(localized: "Chooses whether the eraser erases this ink."))
        }
    }
}

// MARK: - Options bar

/// The eraser's contextual options (`activeToolMenu`), fused to the palette in a `NibToolOptionsBar`: size presets and
/// the mode.
struct EraserOptionsBar: View {
    @StateObject private var model: EraserOptions

    init(app: NibApp) {
        self._model = StateObject(wrappedValue: EraserOptions(app: app))
    }

    var body: some View {
        HStack(spacing: 0) {
            EraserSizePresets(model: model)
            NibBarSeparator()
            Menu {
                Picker(String(localized: "Eraser mode"), selection: $model.mode) {
                    ForEach(EraserMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } label: {
                Text(model.mode.title)
                    .font(NibFont.button)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1)
                    .padding(.horizontal, NibSpacing.m)
                    .frame(minHeight: NibMetrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "Eraser mode"))
            .accessibilityValue(model.mode.title)
        }
    }
}

// MARK: - Delete Specific Items

enum DeleteItemsScope: String, CaseIterable, Hashable {
    case page, document

    var title: String {
        switch self {
        case .page: return String(localized: "This page")
        case .document: return String(localized: "Whole document")
        }
    }
}

/// The rows of the Delete Specific Items sheet (T-022) and the `page.deleteItems` kinds each one stands for.
enum DeleteItemsGroup: String, CaseIterable, Hashable, Identifiable {
    case handwriting, highlighter, tape, shapes, text, images, sticky, maths, comments, plugin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .handwriting: return String(localized: "Handwriting")
        case .highlighter: return String(localized: "Highlighter")
        case .tape: return String(localized: "Tape")
        case .shapes: return String(localized: "Shapes and connectors")
        case .text: return String(localized: "Text boxes")
        case .images: return String(localized: "Images")
        case .sticky: return String(localized: "Sticky notes")
        case .maths: return String(localized: "Maths")
        case .comments: return String(localized: "Comments")
        case .plugin: return String(localized: "Plugin items")
        }
    }

    var kinds: [String] {
        switch self {
        case .handwriting: return [InkTool.pen.rawValue, InkTool.pencil.rawValue]
        case .highlighter: return [InkTool.highlighter.rawValue]
        case .tape: return [InkTool.tape.rawValue]
        case .shapes: return [ItemKind.shape.rawValue, ItemKind.connector.rawValue]
        case .text: return [ItemKind.text.rawValue]
        case .images: return [ItemKind.image.rawValue]
        case .sticky: return [ItemKind.sticky.rawValue]
        case .maths: return [ItemKind.math.rawValue]
        case .comments: return [ItemKind.comment.rawValue]
        case .plugin: return [ItemKind.custom.rawValue]
        }
    }

    /// `page.deleteItems` params for a choice in the sheet; nil when nothing is chosen or there is no page.
    static func params(doc: DocumentID?, page: PageID?, groups: Set<DeleteItemsGroup>, scope: DeleteItemsScope) -> JSONValue? {
        let kinds = Set(groups.flatMap { $0.kinds }).sorted()
        guard !kinds.isEmpty, let doc = doc else { return nil }
        let list = JSONValue.array(kinds.map { JSONValue.string($0) })
        switch scope {
        case .page:
            guard let page = page else { return nil }
            return ["page": .string(NodeRef.page(doc, page).description), "kinds": list, "scope": "page"]
        case .document:
            return ["doc": .string(NodeRef.document(doc).description), "kinds": list, "scope": "document"]
        }
    }
}

/// Delete Specific Items (opened from More through `panel.open`): an opaque sheet with the scope, one switch per kind
/// of item and a primary button that says how many items go (counted from reads with `PageDeleteItems.resolve`).
struct DeleteItemsSheet: View {
    let context: PanelContext
    @State private var scope = DeleteItemsScope.page
    @State private var groups: Set<DeleteItemsGroup> = []
    @State private var count = 0

    private struct Choice: Equatable {
        var scope: DeleteItemsScope
        var groups: Set<DeleteItemsGroup>
    }

    private var params: JSONValue? {
        DeleteItemsGroup.params(doc: context.session?.document, page: context.session?.page, groups: groups, scope: scope)
    }

    private var primaryTitle: String {
        switch count {
        case 0: return String(localized: "Delete")
        case 1: return String(localized: "Delete 1 Item")
        default: return String(localized: "Delete \(count) Items")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Delete Specific Items"), primaryTitle: primaryTitle,
                           isPrimaryEnabled: count > 0, onCancel: { context.dismiss() }, onPrimary: { delete() })
            List {
                Section {
                    NibSegmentedControl(selection: $scope, options: DeleteItemsScope.allCases, title: { $0.title })
                } footer: {
                    Text(scope == .page ? String(localized: "Deletes from the page you are on.")
                                        : String(localized: "Deletes from every page of this document."))
                }
                Section(String(localized: "Items to delete")) {
                    ForEach(DeleteItemsGroup.allCases) { group in
                        NibToggle(group.title, isOn: $groups[dynamicMember: \.[member: group]])
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .task(id: Choice(scope: scope, groups: groups)) { await recount() }
    }

    private func recount() async {
        count = DeleteItemsSheet.count(params, app: context.app, session: context.session)
    }

    /// How many items `page.deleteItems` would remove, from reads only (no dry-run transaction).
    @MainActor static func count(_ params: JSONValue?, app: NibApp, session: EditorSession?) -> Int {
        guard let params = params, let p = try? params.decode(PageDeleteItems.Params.self),
              let work = try? PageDeleteItems.resolve(p, workspace: app.workspace, session: session) else { return 0 }
        return work.reduce(0) { $0 + $1.ids.count }
    }

    private func delete() {
        guard let params = params, count > 0 else { return }
        let app = context.app
        let session = context.session
        Task { @MainActor in
            // Announce what was actually removed, once it has been.
            do {
                let r = try await app.bus.execute(Invocation(command: "page.deleteItems", params: params, session: session))
                let n = r.value["removed"]?.intValue ?? 0
                UIAccessibility.post(notification: .announcement,
                                     argument: n == 1 ? String(localized: "Deleted 1 item. Undo is available.")
                                                      : String(localized: "Deleted \(n) items. Undo is available."))
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": "page.deleteItems", "error": NibError.wrap(error)])
            }
        }
        context.dismiss()
    }
}

extension Set {
    /// Membership as a settable Bool, so a switch can bind to "is this in the set" (`$set[dynamicMember: \.[member: x]]`).
    subscript(member element: Element) -> Bool {
        get { contains(element) }
        set {
            if newValue { insert(element) } else { remove(element) }
        }
    }
}
