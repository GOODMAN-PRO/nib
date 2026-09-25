import SwiftUI
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// The page sheets: Go to Page (⌥⌘G, More › Go to Page…), Move Pages (Move to Another Notebook…) and Add Page ›
// Import… (the system document picker). All are opened with panel.open, act through commands, and are opaque sheets:
// no droplets on sheets (DESIGN.md §2.4, §10.15).

@MainActor
enum PageDialogs {
    static let goToPageID = "pages.goToPage"
    static let movePagesID = "pages.movePages"
    static let importPositions: [PagePosition] = [.before, .after, .end]

    /// One picker sheet per Add Page position.
    static func importID(_ position: PagePosition) -> String { "pages.import." + position.rawValue }

    static func register(_ app: NibApp) {
        app.ui.panels.register(PanelDescriptor(
            id: goToPageID, title: String(localized: "Go to Page"), icon: NibSymbol.pages.name, placement: .sheet,
            order: 900, owner: FeatPagesFeature.id, docKinds: [.notebook]) { context in
                AnyView(GoToPageDialog(context: context))
            })
        app.ui.panels.register(PanelDescriptor(
            id: movePagesID, title: String(localized: "Move Pages"), icon: NibSymbol.notebook.name, placement: .sheet,
            order: 901, owner: FeatPagesFeature.id, docKinds: [.notebook, .whiteboard]) { context in
                AnyView(MovePagesSheet(context: context))
            })
        for (i, position) in importPositions.enumerated() {
            app.ui.panels.register(PanelDescriptor(
                id: importID(position), title: String(localized: "Import"), icon: NibSymbol.importFile.name,
                placement: .sheet, order: 902 + i, owner: FeatPagesFeature.id, docKinds: [.notebook]) { context in
                    AnyView(ImportPagesSheet(context: context, position: position))
                })
        }
    }
}

// MARK: - Go to Page

/// What the Go to Page field means: a 1-based page number, else the start (then any part) of a page title.
enum GoToPageResolver {
    enum Outcome: Equatable {
        case empty
        case page(Int)
        case outOfRange
        case noMatch

        /// 0-based index of the page to show.
        var index: Int? {
            if case .page(let i) = self { return i }
            return nil
        }
    }

    static func resolve(_ input: String, titles: [String?]) -> Outcome {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        if let number = Int(text) {
            return number >= 1 && number <= titles.count ? .page(number - 1) : .outOfRange
        }
        let needle = text.lowercased()
        if let i = titles.firstIndex(where: { $0?.lowercased().hasPrefix(needle) == true }) { return .page(i) }
        if let i = titles.firstIndex(where: { $0?.localizedCaseInsensitiveContains(text) == true }) { return .page(i) }
        return .noMatch
    }
}

@MainActor
struct GoToPageDialog: View {
    let context: PanelContext
    private let doc: DocumentID?
    private let pages: [PageRecord]
    private let current: Int?
    @State private var input = ""
    @FocusState private var fieldFocused: Bool

    init(context: PanelContext) {
        self.context = context
        let doc = context.session?.document
        let pages = doc.flatMap { try? context.app.workspace.content($0) }?.livePages ?? []
        self.doc = doc
        self.pages = pages
        self.current = context.session?.page.flatMap { page in pages.firstIndex { $0.id == page } }
    }

    var body: some View {
        let outcome = GoToPageResolver.resolve(input, titles: pages.map { $0.title })
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Go to Page"), primaryTitle: String(localized: "Go"),
                           isPrimaryEnabled: outcome.index != nil, onCancel: { context.dismiss() }, onPrimary: { go() })
            if pages.isEmpty {
                NibEmptyState(symbol: .pages, title: String(localized: "No pages to go to"),
                              message: String(localized: "Open a notebook, then choose Go to Page."))
            } else {
                VStack(spacing: NibSpacing.l) {
                    HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                        NibField(text: $input, prompt: String(localized: "Page"))
                            .multilineTextAlignment(.center)
                            .keyboardType(.numbersAndPunctuation)
                            .submitLabel(.go)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($fieldFocused)
                            .onSubmit { go() }
                            .onChange(of: input) { _, text in
                                // NibField grows vertically, so Return can arrive as a line break instead of a submit.
                                guard text.contains("\n") else { return }
                                input = text.replacingOccurrences(of: "\n", with: "")
                                go()
                            }
                            .accessibilityLabel(String(localized: "Page number or title"))
                            .accessibilityHint(String(localized: "\(pages.count) pages"))
                        Text(String(localized: "of \(pages.count)"))
                            .font(NibFont.title3)
                            .foregroundStyle(NibColor.labelSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(message(outcome))
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: NibSpacing.s) {
                        NibButton(String(localized: "First Page"), size: .compact) { jump(to: 0) }
                        NibButton(String(localized: "Last Page"), size: .compact) { jump(to: pages.count - 1) }
                    }
                }
                .padding(NibSpacing.xl)
            }
            Spacer(minLength: 0)
        }
        .presentationDetents([.medium, .large])
        .onAppear { fieldFocused = true }
    }

    private func message(_ outcome: GoToPageResolver.Outcome) -> String {
        switch outcome {
        case .empty:
            if let current {
                return String(localized: "You are on page \(current + 1). Enter a number from 1 to \(pages.count), or a page title.")
            }
            return String(localized: "Enter a number from 1 to \(pages.count), or a page title.")
        case .page(let index):
            if let title = pages[index].title, !title.isEmpty { return String(localized: "Page \(index + 1): \(title)") }
            return String(localized: "Page \(index + 1)")
        case .outOfRange:
            return String(localized: "This notebook has \(pages.count) pages. Enter a number from 1 to \(pages.count).")
        case .noMatch:
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(localized: "No page title matches \u{201C}\(text)\u{201D}.")
        }
    }

    private func go() {
        guard let index = GoToPageResolver.resolve(input, titles: pages.map { $0.title }).index else { return }
        jump(to: index)
    }

    private func jump(to index: Int) {
        guard let doc, pages.indices.contains(index) else { return }
        context.app.perform(CommandIDs.viewGoToPage, ["page": .string(NodeRef.page(doc, pages[index].id).description)],
                            session: context.session)
        context.dismiss()
    }
}

// MARK: - Move Pages

/// The documents pages can move to: other notebooks and whiteboards, most recently changed first.
enum MovePagesTargets {
    static func candidates(_ nodes: [LibraryNode], excluding doc: DocumentID?) -> [LibraryNode] {
        nodes.filter { node in
            node.kind == .document && node.id != doc && node.trashedAt == nil
                && (node.documentKind == .notebook || node.documentKind == .whiteboard)
        }
        .sorted { $0.modified > $1.modified }
    }

    static func filter(_ nodes: [LibraryNode], query: String) -> [LibraryNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nodes }
        return nodes.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q) }
    }
}

/// Move Pages (D-056): pick the notebook; the open page lands at its end in one undoable step (page.moveTo).
/// ponytail: the open page only, because panel.open carries just the panel id; moving a sidebar selection through this
/// sheet needs panel.open params in PanelContext (a contract request).
@MainActor
struct MovePagesSheet: View {
    let context: PanelContext
    private let pages: [String]
    private let candidates: [LibraryNode]
    @State private var query = ""

    init(context: PanelContext) {
        self.context = context
        let doc = context.session?.document
        if let doc, let page = context.session?.page {
            pages = [NodeRef.page(doc, page).description]
        } else {
            pages = []
        }
        candidates = MovePagesTargets.candidates(context.app.services.library?.allNodes() ?? [], excluding: doc)
    }

    var body: some View {
        let shown = MovePagesTargets.filter(candidates, query: query)
        VStack(spacing: 0) {
            NibSheetHeader(title, onCancel: { context.dismiss() })
            if pages.isEmpty {
                NibEmptyState(symbol: .pages, title: String(localized: "No page open"),
                              message: String(localized: "Open a page, then choose Move to Another Notebook."))
                Spacer(minLength: 0)
            } else if candidates.isEmpty {
                NibEmptyState(symbol: .notebook, title: String(localized: "No other notebooks"),
                              message: String(localized: "Create another notebook to move pages into."))
                Spacer(minLength: 0)
            } else {
                NibSearchField(text: $query, prompt: String(localized: "Search notebooks"))
                    .padding(.horizontal, NibSpacing.l)
                    .padding(.bottom, NibSpacing.s)
                if shown.isEmpty {
                    Text(String(localized: "No notebooks match \u{201C}\(query)\u{201D}."))
                        .font(NibFont.callout)
                        .foregroundStyle(NibColor.labelSecondary)
                        .padding(NibSpacing.xl)
                    Spacer(minLength: 0)
                } else {
                    List {
                        ForEach(shown) { node in
                            Button {
                                move(to: node)
                            } label: {
                                NibRow(node.title, subtitle: subtitle(node),
                                       icon: node.documentKind == .whiteboard ? NibSymbol.whiteboard : NibSymbol.notebook) {
                                    if node.locked {
                                        Image(nib: .lock)
                                            .foregroundStyle(NibColor.labelSecondary)
                                            .accessibilityLabel(String(localized: "Locked"))
                                    }
                                }
                            }
                            .accessibilityHint(String(localized: "Moves the pages to the end of this document"))
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        pages.count == 1 ? String(localized: "Move Page") : String(localized: "Move \(pages.count) Pages")
    }

    private func subtitle(_ node: LibraryNode) -> String {
        let folder = (node.path as NSString).deletingLastPathComponent
        let place = folder.isEmpty ? String(localized: "Library") : folder.replacingOccurrences(of: "/", with: " › ")
        guard let count = node.pageCount else { return place }
        return count == 1 ? String(localized: "\(place) · 1 page") : String(localized: "\(place) · \(count) pages")
    }

    private func move(to node: LibraryNode) {
        let app = context.app
        let session = context.session
        let refs = pages
        let dismiss = context.dismiss
        Task { @MainActor in
            if let lock = app.services.lock, lock.isLocked(node.id) {
                guard await lock.unlock(node.id) else { return }
            }
            app.perform("page.moveTo", ["pages": .array(refs.map { JSONValue.string($0) }),
                                        "doc": .string(NodeRef.document(node.id).description)], session: session)
            dismiss()
        }
    }
}

// MARK: - Import (Add Page › Import…)

/// Add Page › Import… (D-091): the system document picker; the chosen files go into the open notebook before or after
/// the open page, or at its end, through import.files (F064).
@MainActor
struct ImportPagesSheet: View {
    static let types: [UTType] = [.pdf, .image, .presentation, .compositeContent]

    let context: PanelContext
    let position: PagePosition

    var body: some View {
        PagesDocumentPicker(types: ImportPagesSheet.types, onPick: { urls in
            if let doc = context.session?.document, !urls.isEmpty {
                let plan = AddPagePlan(position: position, doc: doc, page: context.session?.page)
                context.app.perform(CommandIDs.importFiles, plan.importFiles(urls), session: context.session)
            }
            context.dismiss()
        }, onCancel: { context.dismiss() })
        .ignoresSafeArea()
    }
}

/// `UIDocumentPickerViewController` as a sheet's content: a system component, used as it is (DESIGN.md §13.7).
/// Files are copied into the app's Inbox, so import.files can read them without security scopes.
struct PagesDocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: PagesDocumentPicker

        init(_ parent: PagesDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
