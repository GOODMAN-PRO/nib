import SwiftUI
import NibContracts
import NibDesign

/// Document chrome (F017): `ui.screens.documentContainer` wraps every editor with the window's one droplet container:
/// the nav bar, the tool palette (`ui.screens.toolbarView`), the sidebar host, floating panels, chrome overlays
/// (`ui.chromeOverlays`) and the window's floating host (`EditorSession.floatingHost`), plus sheets. Panels, nav-bar
/// items, overlays and menu entries come from the registries, so features and plugins add theirs without touching
/// this module.
public enum FeatDocChromeFeature: NibFeature {
    public static let id = "chrome"

    public static func register(_ app: NibApp) {
        app.services.set(ChromeStateStore(app: app), for: ChromeStateStore.serviceKey)
        app.commands.register(PanelOpen.self)
        app.commands.register(PanelClose.self)
        app.commands.register(SidebarToggle.self)
        app.commands.register(DocSetScrollDirection.self)
        app.settings.declarePrefix(ChromeSettings.placementPrefix, synced: false,
                                   summary: "Where one panel shows in documents on this device: left, right or floating (null = its default).",
                                   owner: id, schema: .str(choices: PanelSpot.overrides.map { $0.rawValue }))
        app.ui.screens.documentContainer = { editor, doc, hostApp, navigator in
            DocumentContainerViewController(editor: editor, document: doc, app: hostApp, navigator: navigator)
        }
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: ChromeShortcuts.sidebarKeyCommand, title: String(localized: "Show or Hide Sidebar"),
            shortcut: ChromeShortcuts.sidebar, command: "sidebar.toggle", scope: .document, owner: id))
        registerMenus(app)
        registerPanels(app)
    }

    /// More-menu base items (D-080) and the title menu entries that belong to no other feature.
    private static func registerMenus(_ app: NibApp) {
        // Read-only mode: tapping the title offers Edit (DESIGN.md §14.2).
        app.ui.menus.register(MenuItemDescriptor(
            id: "chrome.title.edit", title: String(localized: "Edit"), icon: "lock.open",
            location: .documentTitle, order: 0, owner: id, command: "view.setReadOnly",
            params: { _ in ["on": false] },
            isVisible: { ctx in
                ctx.session?.readOnly == true && ctx.app.commands.entry("view.setReadOnly") != nil
            }))
        // Scrolling Direction (D-080): both directions for notebooks, the current one ticked (contracts-v2 isChecked).
        for direction in ScrollDirection.allCases {
            let horizontal = direction == .horizontal
            var entry = MenuItemDescriptor(
                id: horizontal ? "chrome.more.scrollHorizontal" : "chrome.more.scrollVertical",
                title: horizontal ? String(localized: "Horizontal") : String(localized: "Vertical"),
                icon: horizontal ? "arrow.left.and.right" : "arrow.up.and.down",
                location: .documentMore, order: horizontal ? 110 : 100, owner: id, command: "doc.setScrollDirection",
                params: { ctx in
                    ["doc": .string(ChromeMenuSupport.docRef(ctx)), "direction": .string(direction.rawValue)]
                },
                isVisible: { ChromeMenuSupport.scrollDirection($0) != nil },
                submenu: String(localized: "Scrolling Direction"))
            entry.isChecked = { ChromeMenuSupport.scrollDirection($0) == direction }
            app.ui.menus.register(entry)
        }
        app.ui.menus.register(MenuItemDescriptor(
            id: "chrome.more.editingSettings", title: String(localized: "Document Editing Settings"), icon: "gearshape",
            location: .documentMore, order: 900, owner: id, command: "panel.open",
            params: { _ in ["id": .string(ChromePanels.editingSettings)] }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "chrome.title.rename", title: String(localized: "Rename"), icon: "pencil",
            location: .documentTitle, order: 100, owner: id, command: "panel.open",
            params: { _ in ["id": .string(ChromePanels.rename)] },
            isVisible: { ChromeMenuSupport.canChangeLibrary($0, with: "library.rename") }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "chrome.title.move", title: String(localized: "Move to Folder"), icon: "folder",
            location: .documentTitle, order: 300, owner: id, command: "panel.open",
            params: { _ in ["id": .string(ChromePanels.move)] },
            isVisible: { ChromeMenuSupport.canChangeLibrary($0, with: "library.move") }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "chrome.title.closeOthers", title: String(localized: "Close Other Tabs"), icon: "xmark.square",
            location: .documentTitle, order: 400, owner: id, command: "tab.closeOthers",
            isVisible: { ctx in
                // The active navigator can belong to another window: count tabs only when it is this one's.
                guard ctx.app.commands.entry("tab.closeOthers") != nil, let navigator = ctx.app.ui.activeNavigator,
                      navigator.session === ctx.session else { return false }
                return navigator.openDocuments.count > 1
            }))
    }

    /// The title and More sheets draw their own `NibSheetHeader` (contracts-v2 `providesHeader`).
    private static func registerPanels(_ app: NibApp) {
        func sheet(_ panelID: String, _ title: String, _ icon: String, order: Int,
                   _ make: @escaping @MainActor (PanelContext) -> AnyView) {
            var panel = PanelDescriptor(id: panelID, title: title, icon: icon, placement: .sheet, order: order, owner: id,
                                        makeView: make)
            panel.providesHeader = true
            app.ui.panels.register(panel)
        }
        sheet(ChromePanels.editingSettings, String(localized: "Document Editing"), "gearshape", order: 900) {
            AnyView(EditingSettingsSheet(context: $0))
        }
        sheet(ChromePanels.rename, String(localized: "Rename Document"), "pencil", order: 910) {
            AnyView(RenameDocumentSheet(context: $0))
        }
        sheet(ChromePanels.move, String(localized: "Move to Folder"), "folder", order: 920) {
            AnyView(MoveDocumentSheet(context: $0))
        }
    }
}

@MainActor
enum ChromeMenuSupport {
    static func docRef(_ ctx: MenuContext) -> String {
        ctx.doc.map { NodeRef.document($0).description } ?? ""
    }

    /// The current direction of a notebook (nil for other kinds: only notebooks scroll by page).
    static func scrollDirection(_ ctx: MenuContext) -> ScrollDirection? {
        guard let doc = ctx.doc, let content = try? ctx.app.workspace.content(doc),
              content.meta.kind == .notebook else { return nil }
        return content.meta.scrollDirection
    }

    static func canChangeLibrary(_ ctx: MenuContext, with command: String) -> Bool {
        ctx.doc != nil && ctx.app.services.library != nil && ctx.app.commands.entry(command) != nil
    }
}

// MARK: - Sheets

/// More › Document Editing Settings: the Settings pages of the Editing section (F027 and any plugin), in a sheet.
struct EditingSettingsSheet: View {
    let context: PanelContext

    var body: some View {
        let pages = context.app.ui.settingsPages.all.filter { $0.section == .editing }
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Document Editing"), cancelTitle: String(localized: "Done"),
                           onCancel: { context.dismiss() })
            NavigationStack {
                content(pages)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
    }

    /// Settings pages push with their own navigation bar; the root sits under the sheet header.
    @ViewBuilder
    private func content(_ pages: [SettingsPageDescriptor]) -> some View {
        if pages.isEmpty {
            NibEmptyState(symbol: .settings, title: String(localized: "No editing settings"),
                          message: String(localized: "Document editing settings appear here once the Settings feature is installed."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pages.count == 1, let page = pages.first {
            page.makeView(context.app)
        } else {
            List {
                ForEach(pages, id: \.id) { page in
                    NavigationLink {
                        page.makeView(context.app)
                            .navigationTitle(page.title)
                    } label: {
                        NibRow(page.title, icon: NibSymbol(systemName: page.icon))
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

/// Title menu › Rename: a title field that runs `library.rename`.
struct RenameDocumentSheet: View {
    let context: PanelContext
    @State private var title: String

    init(context: PanelContext) {
        self.context = context
        let doc = context.session?.document
        _title = State(initialValue: doc.flatMap { context.app.services.library?.node($0)?.title } ?? "")
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Rename Document"), primaryTitle: String(localized: "Rename"),
                           isPrimaryEnabled: !trimmed.isEmpty, onCancel: { context.dismiss() }, onPrimary: rename)
            NibField(text: $title, prompt: String(localized: "Title"))
                .onSubmit(rename)
                .padding(.horizontal, NibSpacing.xl)
                .padding(.vertical, NibSpacing.l)
            Spacer(minLength: 0)
        }
        .presentationDetents([.medium])
    }

    private func rename() {
        guard !trimmed.isEmpty, let doc = context.session?.document else { return }
        context.app.perform("library.rename", ["ref": .string(NodeRef.document(doc).description), "title": .string(trimmed)],
                            session: context.session)
        context.dismiss()
    }
}

/// Title menu › Move to Folder: every folder of the library, running `library.move`.
struct MoveDocumentSheet: View {
    let context: PanelContext

    var body: some View {
        let library = context.app.services.library
        let doc = context.session?.document
        let current = doc.flatMap { library?.node($0)?.parent }
        let folders = (library?.allNodes() ?? []).filter { $0.kind == .folder }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Move to Folder"), onCancel: { context.dismiss() })
            List {
                row(String(localized: "Library"), subtitle: nil, symbol: .library, folder: nil, current: current)
                ForEach(folders) { folder in
                    row(folder.title, subtitle: parentPath(folder.path), symbol: .folderFill, folder: folder.id, current: current)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func row(_ title: String, subtitle: String?, symbol: NibSymbol, folder: FolderID?,
                     current: FolderID?) -> some View {
        Button {
            move(to: folder)
        } label: {
            NibRow(title, subtitle: subtitle, icon: symbol) {
                if folder == current {
                    Image(nib: .checkmark)
                        .foregroundStyle(NibColor.accent)
                        .accessibilityLabel(String(localized: "Current folder"))
                }
            }
        }
        .disabled(folder == current)
    }

    private func parentPath(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: " / ") : nil
    }

    private func move(to folder: FolderID?) {
        guard let doc = context.session?.document else { return }
        var params: [String: JSONValue] = ["refs": .array([.string(NodeRef.document(doc).description)])]
        if let folder { params["folder"] = .string(NodeRef.folder(folder).description) }
        context.app.perform("library.move", .object(params), session: context.session)
        context.dismiss()
    }
}
