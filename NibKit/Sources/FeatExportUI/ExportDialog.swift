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
    var title: String { documents.count == 1 ? documents[0].title : String(localized: "\(documents.count) documents") }
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
            case .folder, .library:
                folderExport = true
                var cursor: String?
                var seen = Set<String>()
                repeat {
                    var params: JSONValue = ["root": .string(ref.description)]
                    if let cursor { params.set("cursor", .string(cursor)) }
                    let result = try await ctx.execute(CommandIDs.queryTree, params)
                    for row in result["nodes"]?.arrayValue ?? [] where row["kind"]?.stringValue == "document" {
                        if row["locked"]?.boolValue == true { throw NibError(.locked, String(localized: "Unlock every document in this folder to export it.")) }
                        if let doc = row["ref"]?.stringValue { documentRefs.append(doc) }
                    }
                    cursor = result["cursor"]?.stringValue
                    if let cursor, !seen.insert(cursor).inserted { throw NibError(.internalError, "The library query repeated its cursor.") }
                } while cursor != nil
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
            var cursor: String?
            var seen = Set<String>()
            var record: ExportDocument?
            var pageRefs = Set<String>()
            repeat {
                var params: JSONValue = ["ref": .string(ref), "depth": 1]
                if let cursor { params.set("cursor", .string(cursor)) }
                let result = try await ctx.execute(CommandIDs.queryGet, params)
                if result["locked"]?.boolValue == true { throw NibError(.locked, String(localized: "Unlock to export")) }
                if record == nil {
                    guard let raw = result["documentKind"]?.stringValue ?? result["meta"]?["kind"]?.stringValue,
                          let kind = DocumentKind(rawValue: raw) else { throw NibError(.internalError, "The document query omitted its kind.") }
                    // The source capability is intentionally not part of the public query JSON.
                    let bookmark = try ctx.workspace.peekContent(doc).meta.sourceBookmark
                    let sourceName: String?
                    if let bookmark { sourceName = try? await ExportFiles.work { try SourceOverwrite.resolve(bookmark).lastPathComponent } }
                    else { sourceName = nil }
                    record = ExportDocument(ref: ref, title: result["title"]?.stringValue ?? String(localized: "Untitled"),
                                            kind: kind, pages: [], hasSource: bookmark != nil, sourceName: sourceName)
                }
                for row in result["pages"]?.arrayValue ?? [] {
                    guard let page = row["ref"]?.stringValue, case .page(let d, _)? = NodeRef(page), d == doc,
                          pageRefs.insert(page).inserted else { continue }
                    let index = row["index"]?.intValue ?? record?.pages.count ?? 0
                    record?.pages.append(ExportPage(ref: page, title: row["title"]?.stringValue ?? String(localized: "Page \(index + 1)"), index: index))
                }
                cursor = result["cursor"]?.stringValue
                if let cursor, !seen.insert(cursor).inserted { throw NibError(.internalError, "The document query repeated its cursor.") }
            } while cursor != nil
            if var record { record.pages.sort { $0.index < $1.index }; documents.append(record) }
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
        let formats = ctx.content.exporters.all.filter { exporter in
            exporter.docKinds.map { kinds.isSubset(of: $0) } ?? true
        }
        guard !formats.isEmpty else { throw NibError.unavailable("an exporter for this document kind") }
        var normalizedUsed = Set<String>()
        return ExportSelection(refs: normalized.filter { normalizedUsed.insert($0).inserted }, documents: documents,
                               selectedPages: selected, currentPage: current, formats: formats, folderExport: folderExport)
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
        options = [ExportOptionKeys.visibleLayersOnly: false, ExportOptionKeys.annotations: true,
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
                    if selection.formats.count <= 4 && !typeSize.isAccessibilitySize {
                        NibSegmentedControl(selection: $draft.format, options: selection.formats.map(\.id)) { id in
                            selection.formats.first(where: { $0.id == id })?.title ?? id
                        }
                    } else {
                        Picker(String(localized: "Format"), selection: $draft.format) {
                            ForEach(selection.formats, id: \.id) { format in Text(format.title).tag(format.id) }
                        }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
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
                        ForEach(doc.pages) { page in
                            NibToggle(page.title, isOn: Binding(get: { draft.selectedPages.contains(page.ref) }, set: { on in
                                if on { draft.selectedPages.insert(page.ref) } else { draft.selectedPages.remove(page.ref) }
                            }))
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
            if !printing && selection.formats.first(where: { $0.id == draft.format })?.fileExtension == "pdf" {
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
            if working { NibTraceRow(String(localized: "Preparing export…"), phase: .running) }
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
                }
                if app.commands.descriptor(CommandIDs.collabHost) != nil && selection.documents.count == 1 {
                    NibButton(String(localized: "Share live…"), symbol: .share, kind: .plain, expands: true) {
                        app.perform(CommandIDs.collabHost, ["doc": .string(selection.documents[0].ref)], session: session)
                        dismiss()
                    }
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
            TextField(label, text: text).font(NibFont.body)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, NibSpacing.m).frame(minHeight: NibMetrics.hitTarget)
                .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.field))
                .accessibilityLabel(label)
        }
    }
    private func option(_ key: String) -> Binding<Bool> {
        Binding(get: { draft.options[key]?.boolValue ?? true }, set: { draft.options.set(key, .bool($0)) })
    }
    private func openPrint() {
        do {
            let run = try draft.runParams(selection: selection)
            var params: JSONValue = ["doc": .string(selection.documents[0].ref)]
            params.set("pages", run["pages"])
            app.perform(CommandIDs.printPresent, params, session: session)
        } catch { self.error = NibError.wrap(error).message }
    }
    private func submit(_ destination: String) {
        do {
            let run = try draft.runParams(selection: selection)
            var params = run
            let command: String
            if destination == "print" {
                command = CommandIDs.printPresent
                params = ["doc": .string(selection.documents[0].ref), "ready": true, "options": draft.options,
                          "range": .string(draft.printRange), "exclude": .string(draft.printExclusions)]
                params.set("pages", run["pages"])
                _ = try PrintPageSelection.resolve(pages: run["pages"]?.arrayValue?.compactMap(\.stringValue),
                    range: draft.printRange, exclusions: draft.printExclusions, document: selection.documents[0])
            } else {
                command = CommandIDs.exportPresent
                params.set("scope", .string(draft.scope.rawValue))
                params.set("destination", .string(destination))
            }
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
struct ExportPopover: View {
    let selection: ExportSelection
    let draft: ExportDraft
    let printing: Bool
    let app: NibApp
    let session: EditorSession?
    let host: FloatingHosting
    let source: String
    let instant: Bool
    @State private var presented = true
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ZStack {
            // Capture outside touches before they reach the canvas.
            Rectangle().fill(NibColor.background.opacity(0)).contentShape(Rectangle())
                .onTapGesture { close() }.accessibilityHidden(true)
            if instant {
                // The keyboard has no spatial bud transition. This remains in the host's single container.
                VStack {
                    NibPopoverPanel(title: title, width: NibMetrics.panelWidth(typeSize)) { contents }
                        .droplet("exportui.popover", style: .popover)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(NibMetrics.chromeInset)
            } else {
                NibBudPopover(id: "exportui.popover", source: source, isPresented: $presented,
                              title: title, width: NibMetrics.panelWidth(typeSize)) { contents }
            }
        }
        .onChange(of: presented) { _, value in
            // NibBudPopover also closes through Escape and VoiceOver, so release the outside-touch shield.
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
            .disabled(unlocking).padding(.horizontal, NibSpacing.xl)
            Spacer(minLength: 0)
        }.background(NibColor.backgroundSecondary)
    }
}
