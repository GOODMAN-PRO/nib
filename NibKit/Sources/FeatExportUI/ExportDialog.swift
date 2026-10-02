import Foundation
import SwiftUI
import NibContracts
import NibDesign

enum ExportPageScope: String, CaseIterable {
    case current, selected, all
    static func parse(_ value: String) throws -> Self {
        guard let scope = Self(rawValue: value) else { throw NibError.invalid("unknown page scope", path: "$.scope") }
        return scope
    }
    func title(board: Bool) -> String {
        switch self {
        case .current: return board ? String(localized: "This board") : String(localized: "This page")
        case .selected: return String(localized: "Selected")
        case .all: return String(localized: "All")
        }
    }
}

struct ExportPage: Identifiable, Equatable {
    var ref: String
    var title: String
    var index: Int
    var id: String { ref }
}
struct ExportDocument {
    var ref: String
    var title: String
    var kind: DocumentKind
    var pages: [ExportPage]
    var hasSource: Bool
    var sourceName: String? = nil
}
struct ExportSelection {
    /// Keep folder refs so export.run retains their directory tree for ZIP exports.
    var refs: [String]
    var documents: [ExportDocument]
    var selectedPages: [String]
    var currentPage: String?
    var formats: [ExporterDescriptor]
    var folderExport: Bool
    var folderTitle: String? = nil
    var title: String { folderTitle ?? (documents.count == 1 ? documents[0].title : String(localized: "\(documents.count) documents")) }
    var isBoard: Bool { documents.count == 1 && documents[0].kind == .whiteboard }
    var pageScopes: [ExportPageScope] {
        var scopes: [ExportPageScope] = []
        if currentPage != nil && documents.count == 1 && !folderExport { scopes.append(.current) }
        if documents.contains(where: { !$0.pages.isEmpty }) && !folderExport { scopes.append(.selected) }
        scopes.append(.all)
        return scopes
    }
    @MainActor
    static func requireUnlocked(_ doc: DocumentID, _ ctx: CommandContext) throws {
        if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, String(localized: "Unlock to export"), hint: "call doc.unlock before exporting") }
    }
    @MainActor
    func requireUnlocked(_ ctx: CommandContext) throws {
        for doc in documents { try Self.requireUnlocked(NodeRef.documentID(from: doc.ref), ctx) }
    }
    @MainActor
    static func load(docs: [String]?, pages: [String]?, ctx: CommandContext) async throws -> Self {
        let refs = try docs ?? [NodeRef.document(ctx.documentOrSession(nil)).description]
        guard !refs.isEmpty else { throw NibError.invalid("Choose documents to export.", path: "$.docs") }
        var documentRefs: [String] = []
        var normalized: [String] = []
        var folderExport = false
        for raw in refs {
            let ref: NodeRef
            if let parsed = NodeRef(raw) { ref = parsed }
            else if NibID.isValid(raw) { ref = .document(NibID(raw)) }
            else { throw NibError.invalid("Expected a document or folder ref.", path: "$.docs") }
            normalized.append(ref.description)
            switch ref {
            case .document(let doc):
                try requireUnlocked(doc, ctx)
                documentRefs.append(ref.description)
            case .folder(let folder):
                folderExport = true
                guard let library = ctx.services.library else { throw NibError.unavailable("the library") }
                var queue = [folder]
                var visited = Set<FolderID>()
                while let next = queue.popLast() {
                    guard visited.insert(next).inserted else { continue }
                    for node in library.children(of: next) {
                        switch node.kind {
                        case .document: documentRefs.append(NodeRef.document(node.id).description)
                        case .folder: queue.append(node.id)
                        }
                    }
                }
            case .library:
                folderExport = true
                guard let library = ctx.services.library else { throw NibError.unavailable("the library") }
                documentRefs += library.allNodes().filter { $0.kind == .document }.map { NodeRef.document($0.id).description }
            default: throw NibError.invalid("Expected a document or folder ref.", path: "$.docs")
            }
        }
        var used = Set<String>()
        documentRefs = documentRefs.filter { used.insert($0).inserted }
        guard !documentRefs.isEmpty else { throw NibError.invalid("There are no documents to export.", path: "$.docs") }
        var documents: [ExportDocument] = []
        for ref in documentRefs {
            let doc = NodeRef.documentID(from: ref)
            try requireUnlocked(doc, ctx)
            let content = try ctx.workspace.peekContent(doc)
            let bookmark = content.meta.sourceBookmark
            let sourceName: String?
            if let bookmark { sourceName = try? await ExportFiles.work { try SourceOverwrite.resolve(bookmark).lastPathComponent } }
            else { sourceName = nil }
            let pages = content.livePages.enumerated().map { index, page in
                ExportPage(ref: NodeRef.page(doc, page.id).description,
                           title: page.title ?? String(localized: "Page \(index + 1)"), index: index)
            }
            documents.append(ExportDocument(ref: ref, title: ctx.services.library?.node(doc)?.title ?? String(localized: "Untitled"),
                                            kind: content.meta.kind, pages: pages, hasSource: bookmark != nil, sourceName: sourceName))
        }
        let allPages = Set(documents.flatMap { $0.pages.map(\.ref) })
        let selected = pages ?? []
        if pages != nil && selected.isEmpty { throw NibError.invalid("Select at least one page.", path: "$.pages") }
        for page in selected where !allPages.contains(page) { throw NibError(.invalidParams, "Selected page does not belong to these documents.", path: "$.pages", hint: "list pages with query.get") }
        let current = ctx.activeSession.flatMap { s -> String? in
            guard let doc = s.document, let page = s.page else { return nil }
            let ref = NodeRef.page(doc, page).description
            return allPages.contains(ref) ? ref : nil
        }
        let kinds = Set(documents.map(\.kind))
        let exporters = ctx.content.exporters.all
        var formats: [ExporterDescriptor] = []
        var seenFormats = Set<String>()
        for exporter in exporters {
            // Package and folder archive are distinct choices even though both are ZIP containers.
            let candidate = ["nibnote", "zip"].contains(exporter.id) ? exporter.id : exporter.fileExtension.lowercased()
            guard seenFormats.insert(candidate).inserted else { continue }
            guard kinds.allSatisfy({ kind in
                exporters.contains { e in
                    (e.id.lowercased() == candidate || e.fileExtension.lowercased() == candidate) &&
                    (e.docKinds?.contains(kind) ?? true)
                }
            }) else { continue }
            var format = exporters.first { $0.id == candidate } ?? exporter
            format.id = candidate
            formats.append(format)
        }
        guard !formats.isEmpty else { throw NibError.unavailable("an exporter for this document kind") }
        var normalizedUsed = Set<String>()
        return ExportSelection(refs: normalized.filter { normalizedUsed.insert($0).inserted }, documents: documents,
                               selectedPages: selected, currentPage: current, formats: formats, folderExport: folderExport,
                               folderTitle: normalized.count == 1 ? NodeRef(normalized[0]).flatMap { ref in
                                   if case .folder(let id) = ref { return ctx.services.library?.node(id)?.title }
                                   return nil
                               } : nil)
    }
}

struct ExportDraft {
    var scope: ExportPageScope
    var format: String
    var name: String
    var selectedPages: Set<String>
    var options: JSONValue
    var printRange = ""
    var printExclusions = ""
    init(selection: ExportSelection) {
        scope = selection.selectedPages.isEmpty ? .all : .selected
        format = (selection.folderExport ? selection.formats.first(where: { $0.id == "zip" }) : nil)?.id ?? selection.formats[0].id
        name = selection.title
        selectedPages = Set(selection.selectedPages)
        options = [ExportOptionKeys.annotations: true,
                   ExportOptionKeys.background: true, "mode": "flattened", "audio": true, "board": "single"]
    }
    func runParams(selection: ExportSelection) throws -> JSONValue {
        guard selection.formats.contains(where: { $0.id == format }) else { throw NibError.invalid("Choose an available export format.", path: "$.format") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ExportFiles.isSafeName(name) else { throw NibError.invalid("Enter a file name without slashes.", path: "$.name") }
        var result: JSONValue = ["docs": .array(selection.refs.map(JSONValue.string)), "format": .string(format),
                                 "options": options, "name": .string(name)]
        switch scope {
        case .all: break
        case .current:
            guard selection.documents.count == 1, !selection.folderExport, let page = selection.currentPage else {
                throw NibError.invalid("There is no current page in this selection.", path: "$.scope")
            }
            result.set("pages", .array([.string(page)]))
        case .selected:
            guard !selection.folderExport, !selectedPages.isEmpty else { throw NibError.invalid("Select at least one page.", path: "$.pages") }
            let pages = selection.documents.flatMap { $0.pages.map(\.ref) }.filter { selectedPages.contains($0) }
            guard pages.count == selectedPages.count else { throw NibError.invalid("A selected page is no longer available.", path: "$.pages") }
            // F066 exports a document whole if it has no page in the page filter. Omit such documents altogether.
            let docs = selection.documents.filter { doc in doc.pages.contains { selectedPages.contains($0.ref) } }.map(\.ref)
            result.set("docs", .array(docs.map(JSONValue.string)))
            result.set("pages", .array(pages.map(JSONValue.string)))
        }
        return result
    }
    func printParams(selection: ExportSelection, ready: Bool) throws -> JSONValue {
        guard selection.documents.count == 1 else { throw NibError.invalid("Choose one document to print.") }
        let run = try runParams(selection: selection)
        let document = selection.documents[0]
        if ready && !document.pages.isEmpty {
            _ = try PrintPageSelection.resolve(pages: run["pages"]?.arrayValue?.compactMap(\.stringValue),
                range: printRange, exclusions: printExclusions, document: document)
        }
        var params: JSONValue = ["doc": .string(document.ref), "options": options,
                                 "range": .string(printRange), "exclude": .string(printExclusions)]
        if ready { params.set("ready", true) }
        params.set("pages", run["pages"])
        return params
    }
    func submitParams(destination: String, selection: ExportSelection) throws -> JSONValue {
        if destination == "print" { return try printParams(selection: selection, ready: true) }
        var params = try runParams(selection: selection)
        // The current page was captured when the dialog opened. Keep that explicit selection.
        params.set("scope", .string(scope == .current ? "selected" : scope.rawValue))
        params.set("destination", .string(destination))
        return params
    }

}

@MainActor
struct ExportDialog: View {
    let selection: ExportSelection
    let printing: Bool
    let app: NibApp
    let session: EditorSession?
    let dismiss: () -> Void
    @State var draft: ExportDraft
    @State private var working = false
    @State private var error: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            if !printing {
                NibInspectorSection(String(localized: "Format")) {
                    if formatGroups.count <= 4 && !typeSize.isAccessibilitySize {
                        NibSegmentedControl(selection: formatGroup, options: formatGroups) { formatTitle($0) }
                    } else {
                        Picker(String(localized: "Format"), selection: formatGroup) {
                            ForEach(formatGroups, id: \.self) { id in Text(formatTitle(id)).tag(id) }
                        }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                    }
                    if formatGroup.wrappedValue == "images" {
                        NibSegmentedControl(selection: $draft.format, options: imageFormats.map(\.id)) { $0.uppercased() }
                    }
                }
                field(String(localized: "File name"), text: $draft.name)
            }
            if selection.pageScopes.count > 1 {
                NibInspectorSection(String(localized: "Pages")) {
                    if typeSize.isAccessibilitySize {
                        Picker(String(localized: "Pages"), selection: $draft.scope) {
                            ForEach(selection.pageScopes, id: \.self) { scope in Text(scope.title(board: selection.isBoard)).tag(scope) }
                        }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                    } else {
                        NibSegmentedControl(selection: $draft.scope, options: selection.pageScopes) { $0.title(board: selection.isBoard) }
                    }
                }
            }
            if draft.scope == .selected {
                ForEach(selection.documents, id: \.ref) { doc in
                    NibInspectorSection(doc.title) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: NibSpacing.m) {
                            ForEach(doc.pages) { page in
                                ExportPageChoice(page: page, app: app, selected: draft.selectedPages.contains(page.ref)) {
                                    if !draft.selectedPages.insert(page.ref).inserted { draft.selectedPages.remove(page.ref) }
                                }
                            }
                        }
                    }
                }
            }
            if printing {
                field(String(localized: "Page range, for example 1–3, 5"), text: $draft.printRange)
                field(String(localized: "Exclude pages, for example 2, 4"), text: $draft.printExclusions)
            }
            NibToggle(String(localized: "Include page backgrounds"), isOn: option(ExportOptionKeys.background))
            NibToggle(String(localized: "Include annotations"), isOn: option(ExportOptionKeys.annotations))
            NibToggle(String(localized: "Visible layers only"), isOn: option(ExportOptionKeys.visibleLayersOnly))
            if printing || fileExtension == "pdf" {
                NibInspectorSection(String(localized: "Sticky notes")) {
                    NibSegmentedControl(selection: stringOption("stickyNotes", fallback: "asIs"), options: ["asIs", "expanded", "icon"]) {
                        switch $0 {
                        case "expanded": return String(localized: "Expanded")
                        case "icon": return String(localized: "Icon")
                        default: return String(localized: "As on page")
                        }
                    }
                }
                NibToggle(String(localized: "Include comments"), isOn: option("comments"))
                if printing || draft.options["mode"]?.stringValue == "flattened" {
                    NibToggle(String(localized: "Searchable text"), isOn: option("searchableText"))
                }
            }
            if !printing && ["png", "jpg", "jpeg"].contains(fileExtension) {
                NibInspectorSection(String(localized: "Image scale")) {
                    NibSegmentedControl(selection: Binding(get: { draft.options["scale"]?.intValue ?? 2 },
                        set: { draft.options.set("scale", .number(Double($0))) }), options: [2, 3]) { "\($0)x" }
                }
            }
            if !printing && fileExtension == "pdf" {
                NibToggle(String(localized: "Flatten"), isOn: Binding(get: { draft.options["mode"]?.stringValue == "flattened" },
                    set: { draft.options.set("mode", .string($0 ? "flattened" : "editable")) }))
            }
            if !printing && (draft.format == "nibnote" || draft.format == "zip") {
                NibToggle(String(localized: "Include audio"), isOn: option("audio"))
            }
            if selection.isBoard {
                NibToggle(String(localized: "Tile board onto paper pages"), isOn: Binding(get: { draft.options["board"]?.stringValue == "tiled" },
                    set: { draft.options.set("board", .string($0 ? "tiled" : "single")) }))
            }
            if let error { NibBanner(error, style: .warning) }
            if working { ExportProgress() }
            if printing {
                NibButton(String(localized: "Print…"), symbol: .print, kind: .primary, expands: true, shortcut: .defaultAction) { submit("print") }
            } else {
                NibButton(String(localized: "Share…"), symbol: .share, kind: .primary, expands: true, shortcut: .defaultAction) { submit("share") }
                NibButton(String(localized: "Save to Files"), symbol: .saveToFiles, expands: true) { submit("files") }
                Text(String(localized: "For multiple files in cloud storage, use Save to Files."))
                    .font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary).fixedSize(horizontal: false, vertical: true)
                if selection.documents.count == 1 && selection.formats.contains(where: { $0.fileExtension == "pdf" }) {
                    NibButton(String(localized: "Print…"), symbol: .print, expands: true) { openPrint() }
                }
                if selection.documents.count == 1 && selection.documents[0].hasSource {
                    NibButton(String(localized: "Save changes to \(selection.documents[0].sourceName ?? String(localized: "source"))…"), symbol: .saveToFiles, kind: .plain, expands: true) {
                        app.perform(CommandIDs.exportSaveToSource, ["doc": .string(selection.documents[0].ref)], session: session)
                    }
                    .accessibilityIdentifier("cmd." + CommandIDs.exportSaveToSource)
                }
                if app.commands.descriptor(CommandIDs.collabHost) != nil && selection.documents.count == 1 {
                    NibButton(String(localized: "Share live…"), symbol: .share, kind: .plain, expands: true) {
                        app.perform(CommandIDs.collabHost, ["doc": .string(selection.documents[0].ref)], session: session)
                        dismiss()
                    }
                    .accessibilityIdentifier("cmd." + CommandIDs.collabHost)
                }
            }
        }
        .foregroundStyle(NibColor.label)
        .tint(NibColor.accent)
        .disabled(working)
        .accessibilityElement(children: .contain)
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(label).font(NibFont.footnoteEmphasis).foregroundStyle(NibColor.labelSecondary)
            NibField(text: text, prompt: label)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel(label)
        }
    }
    private var fileExtension: String { selection.formats.first { $0.id == draft.format }?.fileExtension.lowercased() ?? "" }
    private var imageFormats: [ExporterDescriptor] { selection.formats.filter { ["png", "jpg", "jpeg"].contains($0.fileExtension.lowercased()) } }
    private var formatGroups: [String] {
        var seen = Set<String>()
        return selection.formats.map { ["png", "jpg", "jpeg"].contains($0.fileExtension.lowercased()) ? "images" : $0.id }
            .filter { seen.insert($0).inserted }
    }
    private var formatGroup: Binding<String> {
        Binding(get: { imageFormats.contains { $0.id == draft.format } ? "images" : draft.format }, set: { value in
            draft.format = value == "images" ? (imageFormats.first?.id ?? draft.format) : value
        })
    }
    private func formatTitle(_ id: String) -> String {
        switch id {
        case "images": return String(localized: "Images")
        case "pdf": return "PDF"
        case "nibnote": return String(localized: "Nib file")
        default: return selection.formats.first { $0.id == id }?.title ?? id
        }
    }
    private func stringOption(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: { draft.options[key]?.stringValue ?? fallback }, set: { draft.options.set(key, .string($0)) })
    }
    private func option(_ key: String) -> Binding<Bool> {
        Binding(get: { draft.options[key]?.boolValue ?? true }, set: { draft.options.set(key, .bool($0)) })
    }
    private func openPrint() {
        do {
            let params = try draft.printParams(selection: selection, ready: false)
            app.perform(CommandIDs.printPresent, params, session: session)
        } catch { self.error = NibError.wrap(error).message }
    }
    private func submit(_ destination: String) {
        do {
            let params = try draft.submitParams(destination: destination, selection: selection)
            let command = destination == "print" ? CommandIDs.printPresent : CommandIDs.exportPresent
            working = true
            error = nil
            Task { @MainActor in
                do {
                    _ = try await app.bus.execute(command, params, session: session)
                    working = false
                    dismiss()
                } catch {
                    working = false
                    self.error = NibError.wrap(error).message
                }
            }
        } catch { self.error = NibError.wrap(error).message }
    }
}

@MainActor
private struct ExportPageChoice: View {
    let page: ExportPage
    let app: NibApp
    let selected: Bool
    let action: () -> Void
    @State private var thumbnail: CGImage?
    var body: some View {
        Button(action: action) {
            VStack(spacing: NibSpacing.xs) {
                NibMiniPageThumbnail(width: 64) {
                    if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit() }
                    else { NibColor.background }
                }
                .overlay(alignment: .topTrailing) {
                    Image(nib: selected ? .checkCircleFill : .circle)
                        .foregroundStyle(selected ? NibColor.accent : NibColor.labelSecondary)
                        .background(NibColor.background, in: Circle())
                }
                Text(page.title).font(NibFont.caption1).lineLimit(2)
            }.frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page.title)
        .accessibilityValue(selected ? String(localized: "Selected") : String(localized: "Not selected"))
        .task(id: page.ref) {
            guard case let .page(doc, id)? = NodeRef(page.ref) else { return }
            thumbnail = await app.services.renderer?.thumbnail(doc: doc, page: id, maxPixelSize: 192)
        }
    }
}

private struct ExportProgress: View {
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(String(localized: "Preparing export…")).font(NibFont.caption1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Preparing export…"))
    }
}

@MainActor
struct ExportPopover: View {
    let selection: ExportSelection
    let draft: ExportDraft
    let printing: Bool
    let app: NibApp
    let session: EditorSession?
    let host: FloatingHosting
    let source: String
    /// The registered source rect, in the floating container's coordinate space.
    let sourceRect: CGRect
    let updateSourceRect: @MainActor () -> CGRect?
    let instant: Bool
    @State private var presented = true
    @State private var currentSourceRect: CGRect?
    @State private var popoverSize = CGSize(width: NibMetrics.popoverWidth, height: 200)
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        ZStack {
            // Capture outside touches before they reach the canvas.
            Rectangle().fill(NibColor.background.opacity(0)).contentShape(Rectangle())
                .onTapGesture { close() }.accessibilityHidden(true)
            GeometryReader { geometry in
                let bounds = geometry.frame(in: NibLiquid.space)
                let anchor = currentSourceRect ?? sourceRect
                let gap = sizeClass == .compact ? NibMetrics.popoverGapCompact : NibMetrics.popoverGap
                // NibBudPopover's .below rule: retain the source gap and clamp only horizontally.
                let inset = bounds.insetBy(dx: NibMetrics.chromeInset, dy: NibMetrics.chromeInset)
                let halfWidth = popoverSize.width / 2
                let centreX = min(max(anchor.midX, inset.minX + halfWidth),
                                  max(inset.minX + halfWidth, inset.maxX - halfWidth))
                NibPopoverPanel(title: title, width: NibMetrics.popoverWidth) { contents }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { popoverSize = $0 }
                    .droplet("exportui.popover", style: .popover)
                    .budsFrom(source, isPresented: $presented, instant: instant)
                    .position(x: centreX - bounds.minX,
                              y: anchor.maxY + gap + popoverSize.height / 2 - bounds.minY)
                    .onGeometryChange(for: CGRect.self) { _ in bounds } action: { _ in
                        currentSourceRect = updateSourceRect()
                    }
            }
        }
        .onChange(of: presented) { _, value in
            // Buds also close through Escape and VoiceOver, so release the outside-touch shield.
            if !value { close() }
        }
    }
    private var title: String { printing ? String(localized: "Print") : String(localized: "Share & Export") }
    @ViewBuilder private var contents: some View {
        NibIconButton(.xmark, label: String(localized: "Close export options"), size: .round, shortcut: .cancelAction) { close() }
        ExportDialog(selection: selection, printing: printing, app: app, session: session, dismiss: close, draft: draft)
    }
    private func close() { host.dismiss("exportui.dialog"); host.removeAnchor("exportui.source") }
}

@MainActor
struct ExportSheet: View {
    let selection: ExportSelection
    let draft: ExportDraft
    let printing: Bool
    let app: NibApp
    let session: EditorSession?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(printing ? String(localized: "Print") : String(localized: "Share & Export"),
                           cancelTitle: String(localized: "Close"), onCancel: { dismiss() })
            ScrollView {
                ExportDialog(selection: selection, printing: printing, app: app, session: session, dismiss: { dismiss() }, draft: draft)
                    .padding(NibSpacing.xl)
            }.scrollBounceBehavior(.basedOnSize)
        }.background(NibColor.backgroundSecondary)
    }
}


@MainActor
struct LockedExportSheet: View {
    let doc: DocumentID
    let app: NibApp
    let session: EditorSession?
    let onUnlocked: () -> Void
    @State private var unlocking = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            NibSheetHeader(String(localized: "Unlock to export"), cancelTitle: String(localized: "Close"), onCancel: { dismiss() })
            Text(String(localized: "Unlock this document before sharing, printing or saving a copy."))
                .font(NibFont.body).foregroundStyle(NibColor.label)
                .padding(.horizontal, NibSpacing.xl)
            if let error { NibBanner(error).padding(.horizontal, NibSpacing.xl) }
            NibButton(String(localized: "Unlock document"), symbol: .faceID, kind: .primary, expands: true) {
                unlocking = true
                Task { @MainActor in
                    do {
                        _ = try await app.bus.execute(CommandIDs.docUnlock, ["doc": .string(NodeRef.document(doc).description)], session: session)
                        guard app.services.lock?.isLocked(doc) != true else { throw NibError(.locked, String(localized: "The document is still locked.")) }
                        unlocking = false
                        onUnlocked()
                    } catch { unlocking = false; self.error = NibError.wrap(error).message }
                }
            }
            .accessibilityIdentifier("cmd." + CommandIDs.docUnlock)
            .disabled(unlocking).padding(.horizontal, NibSpacing.xl)
            Spacer(minLength: 0)
        }.background(NibColor.backgroundSecondary)
    }
}
