import SwiftUI
import NibContracts
import NibDesign

/// Settings › Editing › Document Editing (D-081). The defaults new documents start from and how the editor behaves:
/// scrolling direction (D-074, P-028), tabs, undo and redo position (P-030), sidebar side, the status bar (P-106),
/// finger-tap object selection (T-116), alignment guides, grid snapping and Zoom Window auto advance (P-029).
/// Every control writes one `NibSettings` key through `settings.set`; the canvas, chrome, lasso and Zoom Window read them.
@MainActor
struct DocumentEditingPage: View {
    @StateObject private var model: SettingsModel

    init(app: NibApp) {
        _model = StateObject(wrappedValue: SettingsModel(app: app))
    }

    var body: some View {
        List {
            Section {
                SettingsChoiceRow(title: String(localized: "Scrolling direction"),
                                  selection: model.binding(NibSettings.scrollDirection),
                                  options: ScrollDirection.allCases, label: { $0.title })
            } header: {
                SettingsHeader(String(localized: "Pages"))
            } footer: {
                SettingsFooter(String(localized: "New documents scroll this way. Documents you already have keep their own direction."))
            }

            Section {
                SettingsToggleRow(spec: DocumentEditingRows.tabs, model: model)
            } header: {
                SettingsHeader(String(localized: "Documents"))
            }

            Section {
                SettingsChoiceRow(title: String(localized: "Undo and redo buttons"),
                                  selection: sideBinding(NibSettings.undoButtonsOnRight),
                                  options: SettingsSide.allCases, label: { $0.title })
                SettingsChoiceRow(title: String(localized: "Sidebar"),
                                  selection: sideBinding(NibSettings.sidebarOnRight),
                                  options: SettingsSide.allCases, label: { $0.title })
                SettingsToggleRow(spec: DocumentEditingRows.hideStatusBar, model: model)
            } header: {
                SettingsHeader(String(localized: "Layout"))
            }

            Section {
                ForEach(DocumentEditingRows.objects) { spec in
                    SettingsToggleRow(spec: spec, model: model)
                }
            } header: {
                SettingsHeader(String(localized: "Objects"))
            }

            Section {
                SettingsToggleRow(spec: DocumentEditingRows.zoomAutoAdvance, model: model)
            } header: {
                SettingsHeader(String(localized: "Zoom Window"))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sideBinding(_ key: SettingKey<Bool>) -> Binding<SettingsSide> {
        model.binding(key, get: { $0 ? SettingsSide.right : SettingsSide.left }, set: { $0 == .right })
    }
}

/// The page's switches, one per `NibSettings` key (the tests walk `toggles` to check every one round-trips).
enum DocumentEditingRows {
    static var tabs: SettingsToggle {
        SettingsToggle(key: NibSettings.openAsTabs, title: String(localized: "Open documents in tabs"),
                       detail: String(localized: "A document you open gets its own tab instead of replacing the one you're in."))
    }

    static var hideStatusBar: SettingsToggle {
        SettingsToggle(key: NibSettings.hideStatusBar, title: String(localized: "Hide status bar"),
                       detail: String(localized: "Hides the time and battery at the top of the screen while a document is open."))
    }

    static var objects: [SettingsToggle] {
        [
            SettingsToggle(key: NibSettings.objectTapSelection, title: String(localized: "Select objects by tapping"),
                           detail: String(localized: "Tap an image, shape, text box or sticky note with your finger to select it. Turn this off to scroll past objects without selecting them.")),
            SettingsToggle(key: NibSettings.alignObjects, title: String(localized: "Align objects"),
                           detail: String(localized: "Show guides and line objects up with each other while you move them.")),
            SettingsToggle(key: NibSettings.snapToGrid, title: String(localized: "Snap to grid"),
                           detail: String(localized: "Moved objects snap to the lines and squares of the page template.")),
        ]
    }

    static var zoomAutoAdvance: SettingsToggle {
        SettingsToggle(key: NibSettings.zoomAutoAdvance, title: String(localized: "Auto advance"),
                       detail: String(localized: "The Zoom Window moves on by itself when your writing reaches the end of the box."))
    }

    static var toggles: [SettingsToggle] { [tabs, hideStatusBar] + objects + [zoomAutoAdvance] }
}

/// Left / Right for settings stored as "on the right" Bools (undo and redo buttons, sidebar).
enum SettingsSide: CaseIterable, Hashable {
    case left, right

    var title: String {
        switch self {
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        }
    }
}

extension ScrollDirection {
    var title: String {
        switch self {
        case .vertical: return String(localized: "Vertical")
        case .horizontal: return String(localized: "Horizontal")
        }
    }
}
