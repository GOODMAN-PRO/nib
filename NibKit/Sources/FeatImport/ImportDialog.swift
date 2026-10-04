import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// MARK: - Choice logic (pure)

/// What the user chose in the import dialog: where the files go and the order they are imported in.
struct ImportChoice: Equatable {
    var destination: ImportDestination
    var order: [Int]
}

/// How the import dialog ended.
enum ImportDialogOutcome: Equatable {
    case chosen(ImportChoice)
    /// The person closed it: Open In and share copies are removed, loose files are left alone.
    case cancelled
    /// It could not be shown (no window, another presentation in the way): nothing is removed, so the inbox scan
    /// offers the files again.
    case notShown
}

/// One row of the dialog's folder picker (nil folder = the library root).
struct ImportFolderOption: Identifiable, Hashable {
    var folder: FolderID?
    var title: String
    var depth: Int
    var id: String { folder?.raw ?? "lib" }
}

/// The notebook open in the invoking window, offered as "Current Document".
struct ImportCurrentDocument: Equatable {
    var id: DocumentID
    var title: String
    var page: PageID?
    var pageNumber: Int?
    var pageCount: Int
}

enum ImportDialogMode: Hashable {
    case newDocument, currentDocument

    var title: String {
        switch self {
        case .newDocument: return String(localized: "New Document")
        case .currentDocument: return String(localized: "Current Document")
        }
    }
}

enum ImportDialogLogic {
    /// The library root, then every folder depth-first, siblings by name (Finder order).
    static func folderOptions(_ nodes: [LibraryNode], rootTitle: String) -> [ImportFolderOption] {
        let folders = nodes.filter { $0.kind == .folder && $0.trashedAt == nil }
        let children = Dictionary(grouping: folders, by: { $0.parent })
        var out = [ImportFolderOption(folder: nil, title: rootTitle, depth: 0)]
        func visit(_ parent: FolderID?, depth: Int) {
            let sorted = (children[parent] ?? []).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            for node in sorted {
                out.append(ImportFolderOption(folder: node.id, title: node.title, depth: depth))
                if depth < NibLimits.maxNesting * 2 { visit(node.id, depth: depth + 1) }
            }
        }
        visit(nil, depth: 1)
        return out
    }

    /// Before / after the open page when there is one, otherwise the start or the end.
    static func positions(hasPage: Bool) -> [PagePosition] {
        hasPage ? [.before, .after, .end] : [.start, .end]
    }

    static func destination(mode: ImportDialogMode, folder: FolderID?, current: ImportCurrentDocument?,
                            position: PagePosition, preset: ImportDestination?) -> ImportDestination {
        if let preset = preset { return preset }
        guard mode == .currentDocument, let current = current else { return ImportDestination(folder: folder) }
        let anchored = position == .before || position == .after
        if anchored, let page = current.page {
            return ImportDestination(doc: current.id, position: position, anchor: page)
        }
        return ImportDestination(doc: current.id, position: anchored ? .end : position)
    }

    /// Moves the file at `index` (an entry of `order`) one step up (-1) or down (+1).
    static func moved(_ order: [Int], _ index: Int, by step: Int) -> [Int] {
        guard let from = order.firstIndex(of: index) else { return order }
        let to = from + step
        guard order.indices.contains(to) else { return order }
        var out = order
        out.swapAt(from, to)
        return out
    }

    static func title(names: [String]) -> String {
        names.count == 1 ? String(localized: "Import “\(names[0])”?") : String(localized: "Import \(names.count) files?")
    }

    static func importingTitle(names: [String]) -> String {
        names.count == 1 ? String(localized: "Importing “\(names[0])”") : String(localized: "Importing \(names.count) files")
    }

    /// Pages can go into the open notebook only when every file is a page format (PDF, image, Office, web page).
    static func allowsCurrentDocument(names: [String]) -> Bool {
        !names.isEmpty && names.allSatisfy { ImportFormats.isPageFormat($0) }
    }

    static func positionTitle(_ position: PagePosition, pageNumber: Int?) -> String {
        switch position {
        case .before:
            return pageNumber.map { String(localized: "Before Page \($0)") } ?? String(localized: "Before This Page")
        case .after:
            return pageNumber.map { String(localized: "After Page \($0)") } ?? String(localized: "After This Page")
        case .start: return String(localized: "At the Beginning")
        case .end: return String(localized: "At the End")
        }
    }
}

// MARK: - Dialog model

@MainActor
final class ImportDialogModel: ObservableObject {
    enum Phase: Equatable { case choosing, importing, finished }

    let names: [String]
    let folders: [ImportFolderOption]
    let current: ImportCurrentDocument?
    let preset: ImportDestination?
    let presetSummary: String?

    @Published var mode: ImportDialogMode = .newDocument
    @Published var folder: FolderID?
    @Published var position: PagePosition
    @Published var order: [Int]
    @Published var phase: Phase = .choosing
    @Published var progress: Double = 0
    @Published var progressLabel = ""
    @Published var cancelRequested = false
    @Published private(set) var failures: [ImportFailure] = []
    @Published private(set) var importedCount = 0

    var onChoose: ((ImportChoice?) -> Void)?
    var onClose: (() -> Void)?

    init(names: [String], folders: [ImportFolderOption], current: ImportCurrentDocument?, preset: ImportDestination?,
         presetSummary: String?) {
        self.names = names
        self.folders = folders
        self.current = current
        self.preset = preset
        self.presetSummary = presetSummary
        self.folder = preset?.folder
        self.position = current?.page == nil ? .end : .after
        self.order = Array(names.indices)
    }

    static func make(library: LibraryService?, workspace: Workspace, session: EditorSession?, names: [String],
                     preset: ImportDestination?) -> ImportDialogModel {
        var current: ImportCurrentDocument?
        if ImportDialogLogic.allowsCurrentDocument(names: names), let s = session, let doc = s.document,
           let content = try? workspace.content(doc), content.meta.kind == .notebook, !workspace.isReadOnly(doc) {
            let index = s.page.flatMap { content.pageIndex($0) }
            current = ImportCurrentDocument(id: doc, title: library?.node(doc)?.title ?? String(localized: "This notebook"),
                                            page: index == nil ? nil : s.page, pageNumber: index.map { $0 + 1 },
                                            pageCount: content.livePages.count)
        }
        var summary: String?
        if let preset = preset {
            if let doc = preset.doc {
                let title = library?.node(doc)?.title ?? String(localized: "the notebook")
                summary = String(localized: "The pages go into “\(title)”.")
            } else if let folder = preset.folder {
                let title = library?.node(folder)?.title ?? String(localized: "the folder")
                summary = String(localized: "New documents go into “\(title)”.")
            } else {
                summary = String(localized: "New documents go into the library.")
            }
        }
        let folders = ImportDialogLogic.folderOptions(library?.allNodes() ?? [], rootTitle: String(localized: "Library"))
        return ImportDialogModel(names: names, folders: folders, current: current, preset: preset, presetSummary: summary)
    }

    var positions: [PagePosition] { ImportDialogLogic.positions(hasPage: current?.page != nil) }

    var title: String {
        switch phase {
        case .choosing: return ImportDialogLogic.title(names: names)
        case .importing: return ImportDialogLogic.importingTitle(names: names)
        case .finished: return String(localized: "\(importedCount) of \(names.count) imported")
        }
    }

    var primaryTitle: String? {
        guard phase == .choosing else { return nil }
        return names.count == 1 ? String(localized: "Import File") : String(localized: "Import \(names.count) Files")
    }

    var cancelTitle: String? {
        switch phase {
        case .choosing: return nil
        case .importing: return String(localized: "Stop")
        case .finished: return String(localized: "Close")
        }
    }

    func confirm() {
        guard phase == .choosing else { return }
        let destination = ImportDialogLogic.destination(mode: mode, folder: folder, current: current,
                                                        position: position, preset: preset)
        onChoose?(ImportChoice(destination: destination, order: order))
    }

    func cancel() {
        switch phase {
        case .choosing: onChoose?(nil)
        case .importing: cancelRequested = true
        case .finished: onClose?()
        }
    }

    func move(_ index: Int, by step: Int) {
        order = ImportDialogLogic.moved(order, index, by: step)
    }

    /// `imported` counts files, so it can be less than the files minus the failures when the import was stopped.
    func showResult(imported: Int, failures: [ImportFailure]) {
        importedCount = min(max(imported, 0), names.count)
        self.failures = failures
        phase = .finished
    }
}

// MARK: - Dialog view

/// The import sheet: an opaque grouped surface (no glass in sheets), one Tinted primary in the header.
struct ImportDialogView: View {
    @ObservedObject var model: ImportDialogModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(model.title, cancelTitle: model.cancelTitle, primaryTitle: model.primaryTitle,
                           onCancel: { model.cancel() }, onPrimary: { model.confirm() })
            switch model.phase {
            case .choosing: choosing
            case .importing: importing
            case .finished: finished
            }
        }
        .modifier(ImportSheetSurface())
        .interactiveDismissDisabled(true)
    }

    private var choosing: some View {
        List {
            if let summary = model.presetSummary {
                Section {
                    Text(summary)
                        .font(NibFont.callout)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            } else {
                if model.current != nil { modeSection }
                if model.mode == .currentDocument, let current = model.current {
                    positionSection(current)
                } else {
                    folderSection
                }
            }
            filesSection
        }
        .listStyle(.insetGrouped)
    }

    /// New Document / Current Document: a segmented control, or two rows at accessibility sizes so neither truncates.
    @ViewBuilder
    private var modeSection: some View {
        if typeSize.isAccessibilitySize {
            Section {
                ForEach([ImportDialogMode.newDocument, .currentDocument], id: \.self) { mode in
                    choiceRow(mode.title, icon: mode == .newDocument ? NibSymbol.notebook : NibSymbol.pdf,
                              selected: model.mode == mode) {
                        model.mode = mode
                    }
                }
            }
        } else {
            Section {
                NibSegmentedControl(selection: $model.mode, options: [.newDocument, .currentDocument]) { $0.title }
                    .accessibilityLabel(String(localized: "Import as"))
            }
        }
    }

    /// The library and its folders as an outline: `NibOutlineRow` indents per level (capped), marks the selected
    /// folder (emphasis title, fill, Selected trait) and keeps 44 pt rows.
    private var folderSection: some View {
        Section {
            ForEach(model.folders) { option in
                Button {
                    model.folder = option.folder
                } label: {
                    NibOutlineRow(option.title, depth: option.depth + 1, isSelected: model.folder == option.folder,
                                  reservesDisclosure: false) {
                        Image(nib: option.folder == nil ? .library : .folder)
                            .foregroundStyle(NibColor.labelSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        } header: {
            Text(String(localized: "Folder"))
        }
    }

    private func positionSection(_ current: ImportCurrentDocument) -> some View {
        Section {
            ForEach(model.positions, id: \.self) { position in
                choiceRow(ImportDialogLogic.positionTitle(position, pageNumber: current.pageNumber), icon: nil,
                          selected: model.position == position) {
                    model.position = position
                }
            }
        } header: {
            Text(String(localized: "Add pages to “\(current.title)”"))
        } footer: {
            if let number = current.pageNumber {
                Text(String(localized: "Page \(number) of \(current.pageCount) is open."))
            }
        }
    }

    /// A selectable row of a flat list (mode, position): the checkmark and the Selected trait carry the choice (never
    /// colour alone).
    private func choiceRow(_ title: String, icon: NibSymbol?, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NibRow(title, icon: icon) {
                if selected {
                    Image(nib: .checkmark)
                        .font(NibFont.bodyEmphasis)
                        .foregroundStyle(NibColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var filesSection: some View {
        Section {
            ForEach(model.order, id: \.self) { index in
                NibRow(model.names[index], icon: ImportUI.symbol(forName: model.names[index]))
                    .accessibilityAction(named: Text(String(localized: "Move Up"))) { model.move(index, by: -1) }
                    .accessibilityAction(named: Text(String(localized: "Move Down"))) { model.move(index, by: 1) }
                    .contextMenu {
                        if model.order.count > 1 {
                            Button(String(localized: "Move Up")) { model.move(index, by: -1) }
                            Button(String(localized: "Move Down")) { model.move(index, by: 1) }
                        }
                    }
            }
            .onMove(perform: reorder)
        } header: {
            Text(model.order.count > 1 ? String(localized: "Order") : String(localized: "File"))
        } footer: {
            if model.order.count > 1 {
                Text(String(localized: "Touch and hold a file, then drag it to change the order."))
            }
        }
    }

    /// Drag to reorder, when there is more than one file.
    private var reorder: ((IndexSet, Int) -> Void)? {
        guard model.order.count > 1 else { return nil }
        let model = self.model
        return { from, to in model.order.move(fromOffsets: from, toOffset: to) }
    }

    private var importing: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            Text(model.progressLabel)
                .font(NibFont.callout)
                .foregroundStyle(NibColor.label)
                .lineLimit(3)
            NibProgressBar(value: model.progress)
                .accessibilityLabel(String(localized: "Import progress"))
                .accessibilityValue(Text(model.progress, format: .percent.precision(.fractionLength(0))))
            if model.cancelRequested {
                Text(String(localized: "Stopping after this file."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .padding(NibSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var finished: some View {
        List {
            Section {
                ForEach(Array(model.failures.enumerated()), id: \.offset) { entry in
                    NibRow(entry.element.title, subtitle: entry.element.message, icon: .warningTriangle)
                        .accessibilityElement(children: .combine)
                }
            } header: {
                Text(String(localized: "Not imported"))
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// The sheet's surface: the opaque grouped background below iOS 26; iOS 26 keeps the system sheet material, as
/// `.nibSheet` does.
private struct ImportSheetSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.background(NibColor.groupedBackground)
        }
    }
}

// MARK: - Dialog session

/// Presents the import dialog for Open In, the share sheet, the inbox scan, drops and the Files picker, returns the
/// user's choice, then shows progress until the import finishes (and any files that could not be imported).
@MainActor
final class ImportDialogSession {
    let model: ImportDialogModel
    private weak var navigator: SceneNavigator?
    private var controller: UIViewController?
    private var pending: CheckedContinuation<ImportDialogOutcome, Never>?
    /// Watches the dialog's window while it waits for a choice: closing that window (app switcher, Stage Manager)
    /// never calls `onChoose`.
    private var disconnectObserver: NSObjectProtocol?

    init(navigator: SceneNavigator, library: LibraryService?, workspace: Workspace, session: EditorSession?,
         sources: [ImportSource], preset: ImportDestination?) {
        self.navigator = navigator
        self.model = ImportDialogModel.make(library: library, workspace: workspace, session: session,
                                            names: sources.map { $0.name }, preset: preset)
    }

    var isCancelled: Bool { model.cancelRequested }

    /// Shows the sheet straight at its progress (nothing to ask: the destination is known). False when it could not
    /// be shown; the import then runs without it.
    func showProgress() async -> Bool {
        guard let navigator = navigator, navigator.rootViewController?.view.window != nil else { return false }
        await ImportUI.waitUntilPresentable(navigator)
        model.phase = .importing
        model.onClose = { [weak self] in self?.dismiss() }
        let host = UIHostingController(rootView: ImportDialogView(model: model))
        host.modalPresentationStyle = .formSheet
        host.isModalInPresentation = true
        ImportUI.applySheetChrome(host)
        navigator.presentModal(host)
        guard host.presentingViewController != nil else { return false }
        controller = host
        return true
    }

    func choose() async -> ImportDialogOutcome {
        guard let navigator = navigator, navigator.rootViewController?.view.window != nil else { return .notShown }
        await ImportUI.waitUntilPresentable(navigator)
        return await withCheckedContinuation { (continuation: CheckedContinuation<ImportDialogOutcome, Never>) in
            pending = continuation
            model.onChoose = { [weak self] choice in self?.resolve(choice.map { .chosen($0) } ?? .cancelled) }
            model.onClose = { [weak self] in self?.dismiss() }
            watchScene(of: navigator)
            let host = UIHostingController(rootView: ImportDialogView(model: model))
            host.modalPresentationStyle = .formSheet
            host.isModalInPresentation = true
            ImportUI.applySheetChrome(host)
            navigator.presentModal(host)
            controller = host
            if host.presentingViewController == nil {
                controller = nil
                resolve(.notShown)
            }
        }
    }

    func progress(_ value: Double, label: String) {
        model.progress = min(max(value, 0), 1)
        model.progressLabel = label
    }

    /// Closes the dialog after a clean import; keeps it open with the list of failures otherwise.
    func finish(imported: Int, failures: [ImportFailure], stopped: Bool) {
        let message: String
        if !failures.isEmpty {
            // Files skipped inside a zip or folder count too, so this is not "n of the files chosen".
            message = failures.count == 1 ? String(localized: "1 file was not imported.")
                                          : String(localized: "\(failures.count) files were not imported.")
        } else if stopped {
            message = String(localized: "Import stopped. \(imported) of \(model.names.count) files imported.")
        } else {
            message = String(localized: "Import finished.")
        }
        UIAccessibility.post(notification: .announcement, argument: message)
        guard !failures.isEmpty else {
            if imported > 0 { NibHaptics.play(.success) }
            dismiss()
            return
        }
        model.showResult(imported: imported, failures: failures)
    }

    /// Dismisses the dialog unless it is showing failures for the person to read.
    func close() {
        if model.phase == .finished && !model.failures.isEmpty { return }
        dismiss()
    }

    private func resolve(_ outcome: ImportDialogOutcome) {
        guard let continuation = pending else { return }
        pending = nil
        stopWatchingScene()
        if case .chosen = outcome { model.phase = .importing } else { dismiss() }
        continuation.resume(returning: outcome)
    }

    private func dismiss() {
        controller?.dismiss(animated: true)
        controller = nil
        stopWatchingScene()
        if let continuation = pending {
            pending = nil
            continuation.resume(returning: .cancelled)
        }
    }

    /// When the window showing the dialog goes away before the person chose, the call ends as `.notShown`: nothing is
    /// removed, the claimed files are released and the inbox scan offers them again.
    private func watchScene(of navigator: SceneNavigator) {
        stopWatchingScene()
        guard let scene = navigator.rootViewController?.view.window?.windowScene else { return }
        disconnectObserver = NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification,
                                                                    object: scene, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sceneDisconnected() }
        }
    }

    func sceneDisconnected() {
        controller = nil
        resolve(.notShown)
    }

    private func stopWatchingScene() {
        if let observer = disconnectObserver { NotificationCenter.default.removeObserver(observer) }
        disconnectObserver = nil
    }
}

// MARK: - Files picker

/// `UIDocumentPickerViewController` in open-in-place mode (not a copy), so files from Files providers keep a
/// bookmark for "Save changes to source". Several files and folders can be picked.
@MainActor
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<[URL], Never>?

    static func pick(types: [UTType], navigator: SceneNavigator) async -> [URL] {
        await ImportUI.waitUntilPresentable(navigator)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        let delegate = DocumentPicker()
        picker.delegate = delegate
        // Each window retains its own delegate until the selection resolves.
        // A process-global slot lets a second picker release the first one's delegate.
        defer { withExtendedLifetime(delegate) {} }
        var presentationCheck: Task<Void, Never>?
        let urls = await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
            delegate.continuation = continuation
            navigator.presentModal(picker)
            // UIKit may attach a presented controller on the next main turn.
            // Do not report cancellation while its presentation is still starting.
            presentationCheck = Task { @MainActor [weak delegate, weak picker, weak root = navigator.rootViewController] in
                guard let picker else { delegate?.finish([]); return }
                let attached = await waitForPresentation(of: picker, in: root)
                if !Task.isCancelled && !attached { delegate?.finish([]) }
            }
        }
        presentationCheck?.cancel()
        await ImportUI.waitUntilPresentable(navigator)             // the picker finishes dismissing first
        return urls
    }

    static func waitForPresentation(of controller: UIViewController, in root: UIViewController?, attempts: Int = 30) async -> Bool {
        guard let root else { return false }
        for _ in 0..<attempts {
            guard !Task.isCancelled else { return false }
            if controller.presentingViewController != nil || controller.viewIfLoaded?.window != nil { return true }
            var presented: UIViewController? = root
            while let current = presented {
                if current === controller { return true }
                presented = current.presentedViewController
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        }
        return false
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish([])
    }

    private func finish(_ urls: [URL]) {
        continuation?.resume(returning: urls)
        continuation = nil
    }
}

// MARK: - UI helpers

@MainActor
enum ImportUI {
    /// The window that asks the user, waiting briefly for it: an Open In at launch arrives before the window is active.
    /// The shell makes the window the user works in the active one (key window, Open In, key commands), so that is
    /// `ctx.navigator`; a call from another window (a drop into a window that is not key, in Split View or Stage
    /// Manager) is asked in its own window.
    static func navigator(_ ctx: CommandContext) async -> SceneNavigator? {
        guard !NibApp.isHostlessTest, ctx.app != nil else { return nil }
        for _ in 0..<40 {
            if let nav = navigator(for: ctx.session, active: ctx.navigator), nav.rootViewController?.view.window != nil {
                return nav
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// The navigator of the window running `session`: the active one when it runs it (or no session was given), else
    /// the window found by its session, else the active one.
    static func navigator(for session: EditorSession?, active: SceneNavigator?) -> SceneNavigator? {
        guard let session = session, active?.session !== session else { return active }
        return navigator(showing: session) ?? active
    }

    /// The navigator whose window runs `session` (a window other than the active one).
    static func navigator(showing session: EditorSession?) -> SceneNavigator? {
        guard let session = session else { return nil }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                if let nav = window.rootViewController as? SceneNavigator, nav.session === session { return nav }
            }
        }
        return nil
    }

    /// Waits (up to 3 s) until nothing is being presented or dismissed, so the next sheet can appear.
    static func waitUntilPresentable(_ navigator: SceneNavigator) async {
        for _ in 0..<30 {
            guard let root = navigator.rootViewController else { return }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            if !top.isBeingPresented && !top.isBeingDismissed { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The sheet surface below iOS 26 (opaque grouped background, sheet radius); iOS 26 keeps the system material.
    static func applySheetChrome(_ controller: UIViewController) {
        if #unavailable(iOS 26) {
            controller.view.backgroundColor = NibUIColor.groupedBackground
            controller.sheetPresentationController?.preferredCornerRadius = NibRadius.sheet
        }
    }

    /// The line above the progress bar: which file, and how far through the list.
    static func progressLabel(_ name: String, index: Int, count: Int) -> String {
        count > 1 ? String(localized: "\(index + 1) of \(count): “\(name)”") : String(localized: "“\(name)”")
    }

    /// Imports that take a moment (several files, folders, archives, conversions, big files) show the sheet's
    /// progress even when nothing needs asking. Reads file sizes.
    nonisolated static func isLong(_ urls: [URL]) -> Bool {
        if urls.count > 1 { return true }
        let slow = Set(["zip"] + ImportFormats.officeExtensions + ImportFormats.webExtensions)
        var bytes = 0
        for url in urls {
            if StagingIO.isDirectory(url) || slow.contains(url.pathExtension.lowercased()) { return true }
            bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return bytes > longImportBytes
    }

    nonisolated static let longImportBytes = 20 * 1_048_576

    /// Files that failed while others were imported, as a toast in the invoking window.
    static func reportPartialFailure(_ failures: [ImportFailure], ctx: CommandContext) {
        guard let first = failures.first else { return }
        let name = first.title
        let message = failures.count == 1
            ? String(localized: "“\(name)” wasn't imported: \(first.message)")
            : String(localized: "\(failures.count) files weren't imported. First: “\(name)”: \(first.message)")
        let error = NibError(NibError.Code(rawValue: first.code) ?? .unsupported, message)
        report(error, navigator: ctx.navigator, app: ctx.app)
    }

    /// A toast in the window's floating host; the shell's toast (`nibCommandFailed`) where the window has none.
    static func report(_ error: NibError, navigator: SceneNavigator?, app: NibApp?) {
        if let host = navigator?.floatingHost {
            host.postToast(error.message)
            return
        }
        guard let app = app else { return }
        NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                        userInfo: ["command": CommandIDs.importFiles, "error": error])
    }

    /// Everything the picker may choose: registered importers' types and extensions, folders and Nib packages. With
    /// `pagesOnly` (a notebook target), the formats that become pages: images, and PDF, Word, PowerPoint and web
    /// pages when a PDF importer is there to take them.
    static func pickerTypes(_ content: ContentRegistries, pagesOnly: Bool = false) -> [UTType] {
        var types: [UTType]
        if pagesOnly {
            types = [.image]
            if content.importer(forExtension: "pdf") != nil {
                types.append(.pdf)
                let converted = ImportFormats.officeExtensions + ImportFormats.webExtensions
                types += converted.compactMap { UTType(filenameExtension: $0) }
            }
        } else {
            types = [.pdf, .image, .folder, .zip]
            if let package = UTType(NibFormat.packageUTType) { types.append(package) }
            for d in content.importers.all {
                types += d.utTypes.compactMap { UTType($0) }
                types += d.fileExtensions.compactMap { UTType(filenameExtension: $0) }
            }
        }
        var seen = Set<String>()
        return types.filter { !$0.isDynamic && seen.insert($0.identifier).inserted }
    }

    static func symbol(forName name: String) -> NibSymbol {
        let ext = ImportFormats.ext(name)
        if ext == "pdf" { return .pdf }
        if ImportFormats.imageExtensions.contains(ext) { return .image }
        if ImportFormats.packageExtensions.contains(ext) { return .notebook }
        if ImportFormats.webExtensions.contains(ext) { return .network }
        if ext.isEmpty || ext == "zip" { return .folder }
        return .textDocument
    }
}
