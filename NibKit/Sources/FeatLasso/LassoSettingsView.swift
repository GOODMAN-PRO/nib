import SwiftUI
import NibContracts
import NibDesign

/// The lasso's settings popover (DESIGN.md §14.3), shown when the selected lasso is tapped again; the palette wraps it in
/// a Deep `NibPopoverPanel` titled "Lasso". Type segmented (Freehand · Rectangle), the "Included in selection" toggle
/// rows, and finger-tap object selection. Every change goes through `settings.set`, so the AI and plugins can do the
/// same thing.
struct LassoSettingsView: View {
    let app: NibApp
    let session: EditorSession

    @State private var type: LassoType
    /// One flag per `LassoCategory.allCases`, in order.
    @State private var included: [Bool]
    @State private var tapSelects: Bool

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
        let current = LassoSettings.included(app.settings)
        _type = State(initialValue: app.settings.get(LassoSettings.type))
        _included = State(initialValue: LassoCategory.allCases.map { current.contains($0) })
        _tapSelects = State(initialValue: app.settings.get(NibSettings.objectTapSelection))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            NibInspectorSection(String(localized: "Type")) {
                NibSegmentedControl(selection: $type, options: LassoType.allCases) { $0.title }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(localized: "Lasso type"))
            }
            NibInspectorSection(String(localized: "Included in selection")) {
                VStack(spacing: 0) {
                    ForEach(Array(LassoCategory.allCases.enumerated()), id: \.element) { index, category in
                        NibToggle(category.title, isOn: $included[index])
                            .frame(minHeight: NibMetrics.hitTarget)
                    }
                }
            }
            NibInspectorSection(String(localized: "Tap to select")) {
                NibToggle(String(localized: "Select objects with a finger tap"), isOn: $tapSelects)
                    .frame(minHeight: NibMetrics.hitTarget)
                Text(String(localized: "Tap an image, shape or text box with any tool to select it."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: type) { _, value in
            write(LassoSettings.type, value)
        }
        .onChange(of: included) { _, flags in
            write(LassoSettings.include, zip(LassoCategory.allCases, flags).filter { $0.1 }.map { $0.0.rawValue })
        }
        .onChange(of: tapSelects) { _, value in
            write(NibSettings.objectTapSelection, value)
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)) { _ in
            reload()
        }
    }

    /// Settings changed elsewhere (another window, the AI, a synced device): show them.
    private func reload() {
        let t = app.settings.get(LassoSettings.type)
        let current = LassoSettings.included(app.settings)
        let flags = LassoCategory.allCases.map { current.contains($0) }
        let tap = app.settings.get(NibSettings.objectTapSelection)
        if t != type { type = t }
        if flags != included { included = flags }
        if tap != tapSelects { tapSelects = tap }
    }

    private func write<V: Codable & Equatable>(_ key: SettingKey<V>, _ value: V) {
        guard app.settings.get(key) != value, let json = try? JSONValue.from(value) else { return }
        app.perform(CommandIDs.settingsSet, ["name": .string(key.name), "value": json], session: session)
    }
}

extension LassoType {
    var title: String {
        switch self {
        case .freehand: return String(localized: "Freehand")
        case .rectangle: return String(localized: "Rectangle")
        }
    }
}

extension LassoCategory {
    var title: String {
        switch self {
        case .handwriting: return String(localized: "Handwriting")
        case .highlighter: return String(localized: "Highlighter")
        case .tape: return String(localized: "Tape")
        case .shapes: return String(localized: "Shapes")
        case .images: return String(localized: "Images")
        case .text: return String(localized: "Text")
        case .sticky: return String(localized: "Sticky notes")
        case .comments: return String(localized: "Comments")
        case .math: return String(localized: "Maths")
        case .custom: return String(localized: "Other items")
        }
    }
}
