import Foundation
import os
import NibContracts

// MARK: - a11y.describePage

/// `a11y.describePage {page}` (read): what is on a page, in reading order, for people who cannot see it (VoiceOver's
/// Page Contents tab), the assistant and plugins. Every entry carries its recognised or typed text and the commands
/// that act on it (select, go to, open a link, reveal or hide tape), so the panel is a thin view over this result.
struct A11yDescribePage: NibCommand {
    struct Params: Codable {
        /// "page:D/P". The user may omit it: the invoking window's current page.
        var page: String?
        /// From a previous truncated result.
        var cursor: String?
    }

    typealias Output = PageDescription

    static let descriptor = CommandDescriptor(
        id: "a11y.describePage", title: "Describe Page",
        summary: "Spoken summary of a page: its items in reading order with recognised handwriting, typed and PDF text, "
            + "and the commands each offers (select, go to, open link, reveal tape).",
        params: .obj(["page": .ref, "cursor": .str("from a previous truncated result")], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"], ["page": "page:FIXTUREDOC04/FIXTUREBRD01"]],
        effect: .read)

    private static let log = Logger(subsystem: "app.nib", category: "a11y")

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try ctx.pageOrSession(p.page)
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "the document is locked", hint: "unlock the document, then describe the page again")
        }
        let content = try ctx.workspace.content(doc)
        guard let record = content.page(page), !record.deleted else { throw NibError.notFound("page \(page)") }
        let items = try ctx.workspace.items(doc, page: page)
        let pageRef = NodeRef.page(doc, page).description

        let hidden = hiddenLayers(for: doc, ctx: ctx)
        let customTitles = Dictionary(ctx.content.customItemTypes.all.map { ($0.id, $0) },
                                      uniquingKeysWith: { a, _ in a })
        let available = Set(PageDescriber.commands.filter { ctx.app?.commands.entry($0) != nil })
        let snapshot = DescriptionCache.Snapshot(page: pageRef, content: content,
            revisions: items.map { "\($0.id):\($0.rev)" }, hiddenLayers: hidden,
            commands: available, customTypes: customTitles.values.map { "\($0.id):\($0.title):\($0.textPath ?? "")" }.sorted())
        let cache: DescriptionCache
        if let existing: DescriptionCache = ctx.services.get(DescriptionCache.serviceKey) {
            cache = existing
        } else {
            cache = DescriptionCache()
            ctx.services.set(cache, for: DescriptionCache.serviceKey)
        }
        if let cursor = p.cursor {
            guard cache.snapshot == snapshot, cursor.hasPrefix(cache.version + ":"), let result = cache.result else {
                throw NibError(.invalidParams, "page changed since the previous result", path: "$.cursor",
                               hint: "restart with no cursor")
            }
            return try resultPage(result, entries: cache.entries, cursor: cursor, version: cache.version)
        }
        if cache.snapshot == snapshot, let result = cache.result {
            return try resultPage(result, entries: cache.entries, cursor: nil, version: cache.version)
        }

        let recognition = await recognise(pageRef: pageRef, record: record, items: items, doc: doc,
                                          language: content.meta.language, ctx: ctx)
        let links = pdfLinks(record: record, doc: doc, ctx: ctx)
        try Task.checkCancellation()
        // Recognition can suspend while a commit lands. Never publish that obsolete snapshot.
        guard try ctx.workspace.content(doc) == content,
              try ctx.workspace.items(doc, page: page).map({ "\($0.id):\($0.rev)" }) == snapshot.revisions,
              hiddenLayers(for: doc, ctx: ctx) == hidden else {
            throw NibError(.invalidParams, "page changed during recognition", hint: "restart with no cursor")
        }
        let input = PageDescriber.Input(doc: doc, page: page, items: items, blocks: recognition.blocks,
                                        pdfLinks: links, hiddenLayers: hidden, customTypes: customTitles,
                                        availableCommands: available)
        let entries = PageDescriber.entries(input)
        let live = content.livePages
        let index = live.firstIndex { $0.id == page }.map { $0 + 1 }
        let title = PageDescriber.title(record: record, index: index, count: live.count)
        let result = PageDescription(
            page: pageRef, index: index, pageCount: live.count, title: title,
            summary: PageDescriber.summary(title: title, entries: entries), language: content.meta.language,
            recognition: recognition.status.rawValue, counts: PageDescriber.counts(entries), items: [],
            total: entries.count, truncated: false, cursor: nil)
        cache.snapshot = snapshot
        cache.entries = entries
        cache.result = result
        cache.version = UUID().uuidString
        return try resultPage(result, entries: entries, cursor: nil, version: cache.version)
    }

    private static func resultPage(_ result: PageDescription, entries: [PageEntry], cursor: String?,
                                   version: String) throws -> PageDescription {
        let paged = try PageDescriber.page(entries, cursor: cursor, version: version)
        var output = result
        output.items = paged.items
        output.truncated = paged.next != nil
        output.cursor = paged.next
        return output
    }

    /// App-scoped, bounded to the most recently described page. Snapshot checks include the head, item revisions
    /// and window visibility, so edits, undo, remote merges and a different window cannot reuse stale entries.
    @MainActor
    private final class DescriptionCache {
        static let serviceKey = "a11y.descriptionCache"
        struct Snapshot: Equatable {
            var page: String
            var content: DocumentContent
            var revisions: [String]
            var hiddenLayers: Set<Int>
            var commands: Set<String>
            var customTypes: [String]
        }
        var snapshot: Snapshot?
        var version = ""
        var entries: [PageEntry] = []
        var result: PageDescription?
    }

    // MARK: Recognition

    struct Recognition {
        var blocks: [TextRecognition]
        var status: RecognitionStatus
    }

    /// Handwriting, PDF and scan text of the page: the index's cached `recognize.pageText` (F055) when it is
    /// installed, else the recogniser service on the page's ink (and the PDF service for a PDF background).
    static func recognise(pageRef: String, record: PageRecord, items: [Item], doc: DocumentID, language: String,
                          ctx: CommandContext) async -> Recognition {
        do {
            var blocks: [TextRecognition] = []
            var cursor: String?
            for _ in 0..<PageDescriber.maxRecognitionPages {
                if Task.isCancelled { return Recognition(blocks: [], status: .unavailable) }
                var params: [String: JSONValue] = ["page": .string(pageRef)]
                if let c = cursor { params["cursor"] = .string(c) }
                let value = try await ctx.execute(CommandIDs.recognizePageText, .object(params))
                blocks += (value["blocks"]?.arrayValue ?? []).compactMap { try? $0.decode(TextRecognition.self) }
                guard value["truncated"]?.boolValue == true, let next = value["cursor"]?.stringValue else { break }
                cursor = next
            }
            return Recognition(blocks: blocks, status: .recognised)
        } catch let error as NibError where error.code == .unavailable || error.code == .notFound {
            // The index feature is not installed (or disabled): recognise here.
        } catch {
            log.error("recognize.pageText failed: \(String(describing: error), privacy: .public)")
        }
        var blocks: [TextRecognition] = []
        var status = RecognitionStatus.unavailable
        let ink = items.filter { PageDescriber.isWriting($0) }
        if let recognizer = ctx.services.recognizer {
            if ink.isEmpty {
                status = .recognised
            } else {
                do {
                    blocks += try await recognizer.recognize(strokes: ink, language: language).map { block in
                        var b = block
                        b.source = "ink"
                        return b
                    }
                    status = .recognised
                } catch {
                    log.error("handwriting recognition failed: \(String(describing: error), privacy: .public)")
                }
            }
        } else if ink.isEmpty {
            status = .recognised
        }
        if record.background.kind == .pdf, let asset = record.background.asset,
           let url = ctx.services.assets?.url(asset, doc: doc), let pdf = ctx.services.pdf {
            let pdfPage = record.background.pdfPage ?? 0
            let transform = pdf.pageSize(url, page: pdfPage).map { record.backgroundTransform(sourceSize: $0) }
            blocks += pdf.textBlocks(url, page: pdfPage).map { block in
                var b = block
                b.source = "pdf"
                if let t = transform { b.bbox = PageDescriber.apply(t, to: b.bbox) }
                return b
            }
        }
        return Recognition(blocks: blocks, status: status)
    }

    /// URL links of a PDF background, in page points.
    static func pdfLinks(record: PageRecord, doc: DocumentID, ctx: CommandContext) -> [PDFLinkInfo] {
        guard record.background.kind == .pdf, let asset = record.background.asset,
              let url = ctx.services.assets?.url(asset, doc: doc), let pdf = ctx.services.pdf else { return [] }
        let pdfPage = record.background.pdfPage ?? 0
        let transform = pdf.pageSize(url, page: pdfPage).map { record.backgroundTransform(sourceSize: $0) }
        return pdf.links(url, page: pdfPage).filter { $0.url != nil }.map { link in
            var l = link
            if let t = transform { l.rect = PageDescriber.apply(t, to: l.rect) }
            return l
        }
    }

    /// Layers the invoking window hides for this document (their entries are marked, and the panel leaves them out).
    static func hiddenLayers(for doc: DocumentID, ctx: CommandContext) -> Set<Int> {
        guard let session = ctx.session, session.document == doc else { return [] }
        return session.hiddenLayers
    }
}

// MARK: - Result

enum RecognitionStatus: String, Codable {
    /// Handwriting was read (by the index or the recogniser); entries carry its text.
    case recognised
    /// No recogniser is installed: handwriting is listed without its text.
    case unavailable
}

/// What `a11y.describePage` returns.
struct PageDescription: Codable, Equatable {
    var page: String
    /// 1-based position among the live pages.
    var index: Int?
    var pageCount: Int
    /// "Page 3 of 12", or the board's name.
    var title: String
    /// A short spoken summary: the title and what the page holds.
    var summary: String
    var language: String
    var recognition: String
    /// Entries per kind on visible layers (not only this page of the result).
    var counts: [String: Int]
    var items: [PageEntry]
    var total: Int
    var truncated: Bool
    var cursor: String?
}

/// One readable thing on a page: an item, a line of handwriting, a cluster of drawing, a PDF text block or link.
struct PageEntry: Codable, Equatable, Identifiable {
    /// Stable within one page version: the first ref, or "pdf:<n>" / "link:<n>" for background content.
    var id: String
    var kind: EntryKind
    /// The kind's name ("Handwriting", "Text box").
    var title: String
    /// What VoiceOver reads: the kind and the text.
    var label: String
    /// Recognised, typed or alternative text (nil when there is none, or while tape covers it).
    var text: String?
    /// The items this entry stands for (empty for PDF text and links).
    var refs: [String]
    /// Total group size, including refs omitted to keep tool results bounded.
    var refCount: Int = 0
    var bbox: Rect
    var layer: Int?
    /// On a layer the invoking window hides.
    var hidden: Bool?
    /// Hidden tape covers it: its text is withheld (the point of tape is to hide answers).
    var coveredByTape: Bool?
    /// Tape only: whether it is revealed.
    var revealed: Bool?
    var actions: [EntryAction]
}

/// A command an entry offers. `available` is false when the feature that owns the command is not installed.
struct EntryAction: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var command: String
    var params: JSONValue
    var available: Bool
}

enum EntryKind: String, Codable, CaseIterable {
    case handwriting, drawing, highlight, tape, text, sticky, shape, connector, image, math, comment, custom, pdf, scan,
         link

    var title: String {
        switch self {
        case .handwriting: return String(localized: "Handwriting")
        case .drawing: return String(localized: "Drawing")
        case .highlight: return String(localized: "Highlight")
        case .tape: return String(localized: "Tape")
        case .text: return String(localized: "Text box")
        case .sticky: return String(localized: "Sticky note")
        case .shape: return String(localized: "Shape")
        case .connector: return String(localized: "Connector")
        case .image: return String(localized: "Image")
        case .math: return String(localized: "Maths")
        case .comment: return String(localized: "Comment")
        case .custom: return String(localized: "Item")
        case .pdf: return String(localized: "PDF text")
        case .scan: return String(localized: "Scanned text")
        case .link: return String(localized: "Link")
        }
    }

    /// "3 images" (plural forms come from the string catalog).
    func count(_ n: Int) -> String {
        switch self {
        case .handwriting: return String(localized: "\(n) lines of handwriting")
        case .drawing: return String(localized: "\(n) drawings")
        case .highlight: return String(localized: "\(n) highlights")
        case .tape: return String(localized: "\(n) pieces of tape")
        case .text: return String(localized: "\(n) text boxes")
        case .sticky: return String(localized: "\(n) sticky notes")
        case .shape: return String(localized: "\(n) shapes")
        case .connector: return String(localized: "\(n) connectors")
        case .image: return String(localized: "\(n) images")
        case .math: return String(localized: "\(n) formulas")
        case .comment: return String(localized: "\(n) comments")
        case .custom: return String(localized: "\(n) other items")
        case .pdf: return String(localized: "\(n) blocks of PDF text")
        case .scan: return String(localized: "\(n) blocks of scanned text")
        case .link: return String(localized: "\(n) links")
        }
    }
}

// MARK: - Describer (pure logic)

/// Turns a page's items and recognised text into entries. Pure, so it is unit-tested without a recogniser.
enum PageDescriber {
    static let maxRefs = 64
    static let maxTextLength = 600
    static let maxRecognitionPages = 20
    /// Strokes closer than this (page points) form one drawing or highlight.
    static let clusterGap = 24.0
    /// Result pages stay under the 20 KB tool-result cap.
    static let resultBudget = 18_000

    /// Commands entries may offer (the panel shows an action only when its command is installed).
    static let commands = [CommandIDs.selectionSet, CommandIDs.selectionFromRect, CommandIDs.viewReveal, CommandIDs.viewGoToPage, CommandIDs.linkFollow,
                           CommandIDs.tapeSetRevealed, CommandIDs.commentTapAt]

    struct Input {
        var doc: DocumentID
        var page: PageID
        var items: [Item]
        var blocks: [TextRecognition]
        var pdfLinks: [PDFLinkInfo]
        var hiddenLayers: Set<Int>
        var customTypes: [String: CustomItemTypeDescriptor]
        var availableCommands: Set<String>
    }

    /// Pen and pencil strokes: what handwriting recognition reads.
    static func isWriting(_ item: Item) -> Bool {
        guard item.kind == .stroke, let s = item.stroke else { return false }
        return s.style.tool == .pen || s.style.tool == .pencil
    }

    static func entries(_ input: Input) -> [PageEntry] {
        let doc = input.doc, page = input.page
        let byID = Dictionary(input.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func ref(_ id: ElementID) -> String { NodeRef.item(doc, page, id).description }
        let pageRef = NodeRef.page(doc, page).description
        let hiddenTape = input.items.filter { $0.stroke?.style.tool == .tape && $0.stroke?.tapeRevealed == false }

        var entries: [PageEntry] = []
        var covered = Set<ElementID>()

        // Handwriting lines (and OCR of images and scans) from recognition.
        var imageText: [ElementID: String] = [:]
        var pdfIndex = 0
        for block in input.blocks {
            let text = clean(block.text)
            guard !text.isEmpty else { continue }
            switch block.source {
            case "ink":
                let ids = block.itemIDs.filter { byID[$0].map(isWriting) ?? false }
                let strokes = ids.compactMap { byID[$0] }
                guard !strokes.isEmpty || block.itemIDs.isEmpty else { continue }
                ids.forEach { covered.insert($0) }
                let bbox = strokes.isEmpty ? block.bbox : strokes.map { $0.bounds }.reduce(strokes[0].bounds) { $0.union($1) }
                entries.append(entry(kind: .handwriting, text: text, refs: ids.map(ref), bbox: bbox,
                                     layer: strokes.first?.layer, input: input, pageRef: pageRef))
            case "image":
                for id in block.itemIDs where byID[id]?.kind == .image {
                    imageText[id] = [imageText[id], text].compactMap { $0 }.joined(separator: "\n")
                }
            case "pdf", "scan":
                let kind: EntryKind = block.source == "pdf" ? .pdf : .scan
                var e = entry(kind: kind, text: text, refs: [], bbox: block.bbox, layer: nil, input: input, pageRef: pageRef)
                e.id = "\(block.source):\(pdfIndex)"
                pdfIndex += 1
                entries.append(e)
            default:
                continue  // typed text is read from the items themselves
            }
        }

        // Ink the recogniser did not read: drawings and highlights, clustered.
        let loose = input.items.filter { isWriting($0) && !covered.contains($0.id) }
        for group in clusters(loose) {
            entries.append(entry(kind: .drawing, text: nil, refs: group.map { ref($0.id) }, bbox: bounds(group),
                                 layer: group.first?.layer, input: input, pageRef: pageRef))
        }
        let highlights = input.items.filter { $0.stroke?.style.tool == .highlighter }
        for group in clusters(highlights) {
            let area = bounds(group)
            let written = entries.filter { e in
                e.kind == .handwriting && overlaps(e.bbox, area)
                    && !hiddenTape.contains { $0.bounds.insetBy(-2).contains(e.bbox.center) }
            }.compactMap { $0.text }
            let typed = input.items.filter { item in
                item.kind == .text && overlaps(item.bounds, area)
                    && !hiddenTape.contains { $0.bounds.insetBy(-2).contains(item.bounds.center) }
            }
                .compactMap { $0.text?.text.plainText }
            let text = clean((written + typed).joined(separator: " "))
            entries.append(entry(kind: .highlight, text: text.isEmpty ? nil : text, refs: group.map { ref($0.id) },
                                 bbox: area, layer: group.first?.layer, input: input, pageRef: pageRef))
        }

        // Everything else, one entry per item.
        for item in input.items {
            var text: String?
            var links: [(String, TextLink)] = []
            let kind: EntryKind
            var title: String?
            switch item.kind {
            case .stroke:
                guard item.stroke?.style.tool == .tape else { continue }
                kind = .tape
            case .text:
                kind = .text
                text = item.text.map { $0.text.plainText }
                links = item.text.map { self.links(in: $0.text) } ?? []
            case .sticky:
                kind = .sticky
                text = item.sticky.map { $0.text.plainText }
                links = item.sticky.map { self.links(in: $0.text) } ?? []
            case .shape:
                kind = .shape
                title = item.shape.map { shapeName($0.shape) }
                text = item.shape?.text?.plainText
            case .connector:
                kind = .connector
                text = item.connector?.label?.plainText
            case .image:
                kind = .image
                text = [item.image?.altText, imageText[item.id]].compactMap { $0 }.first { !$0.isEmpty }
            case .math:
                kind = .math
                text = item.math?.latex.joined(separator: "\n")
            case .comment:
                kind = .comment
                text = item.comment?.messages.first.map { $0.author.isEmpty ? $0.text : "\($0.author): \($0.text)" }
                if item.comment?.resolved == true { title = String(localized: "Resolved comment") }
            case .custom:
                kind = .custom
                let type = item.custom.flatMap { input.customTypes["custom." + $0.owner + "." + $0.type] }
                title = type?.title
                if let path = type?.textPath, let data = item.custom?.data { text = value(at: path, in: data) }
            }
            var e = entry(kind: kind, text: text.map(clean).flatMap { $0.isEmpty ? nil : $0 }, refs: [ref(item.id)],
                          bbox: item.bounds, layer: item.layer, input: input, pageRef: pageRef, title: title)
            if kind == .tape {
                let revealed = item.stroke?.tapeRevealed ?? false
                e.revealed = revealed
                e.label = revealed ? String(localized: "Tape, revealed") : String(localized: "Tape, hidden")
                e.actions.insert(tapeAction(refs: [ref(item.id)], reveal: !revealed, input: input), at: 0)
            }
            if kind == .comment, let anchor = item.comment?.anchor {
                e.actions.insert(action("openComment", String(localized: "Open Comment"), CommandIDs.commentTapAt,
                                        ["page": .string(pageRef), "point": [.number(anchor.x), .number(anchor.y)],
                                         "ref": .string(ref(item.id)), "gesture": "tap"], input), at: 0)
            }
            for (label, link) in links {
                e.actions.append(linkAction(label: label, link: link, doc: doc, input: input))
            }
            entries.append(e)
        }

        // URL links of a PDF background.
        for (i, link) in input.pdfLinks.enumerated() {
            guard let url = link.url else { continue }
            var e = entry(kind: .link, text: url, refs: [], bbox: link.rect, layer: nil, input: input, pageRef: pageRef)
            e.id = "link:\(i)"
            e.actions.insert(linkAction(label: url, link: TextLink(url: url), doc: doc, input: input), at: 0)
            entries.append(e)
        }

        // Hidden tape withholds what it covers.
        if !hiddenTape.isEmpty {
            for i in entries.indices where entries[i].kind != .tape {
                let tapes = hiddenTape.filter { $0.bounds.insetBy(-2).contains(entries[i].bbox.center) }
                guard !tapes.isEmpty else { continue }
                entries[i].coveredByTape = true
                entries[i].text = nil
                entries[i].label = String(localized: "\(entries[i].title), covered by tape")
                entries[i].actions.insert(tapeAction(refs: tapes.map { ref($0.id) }, reveal: true, input: input), at: 0)
                entries[i].actions.removeAll { $0.id == "openLink" }
            }
        }
        var usedIDs = Set<String>()
        for i in entries.indices {
            let base = entries[i].id
            var suffix = 1
            while !usedIDs.insert(entries[i].id).inserted {
                entries[i].id = base + "#\(suffix)"
                suffix += 1
            }
        }
        return ReadingOrder.sorted(entries)
    }

    static func entry(kind: EntryKind, text: String?, refs: [String], bbox: Rect, layer: Int?, input: Input,
                      pageRef: String, title: String? = nil) -> PageEntry {
        let name = title ?? kind.title
        // Long caller-supplied node IDs also need a byte bound, not just a reference count.
        var refsBytes = 0
        let boundedRefs = Array(refs.prefix(maxRefs).prefix { ref in
            refsBytes += ref.utf8.count + 3
            return refsBytes <= 4_000
        })
        var actions: [EntryAction] = []
        if let first = refs.first {
            actions.append(action("goTo", String(localized: "Show on Page"), CommandIDs.viewReveal,
                                  ["ref": .string(first)], input))
            if refs.count > boundedRefs.count {
                actions.append(action("select", String(localized: "Select"), CommandIDs.selectionFromRect,
                                      ["page": .string(pageRef), "rect": (try? JSONValue.from(bbox)) ?? .null], input))
            } else {
                actions.append(action("select", String(localized: "Select"), CommandIDs.selectionSet,
                                      ["refs": .array(refs.map { .string($0) })], input))
            }
        } else {
            actions.append(action("goTo", String(localized: "Show on Page"), CommandIDs.viewGoToPage,
                                  ["page": .string(pageRef)], input))
        }
        let hidden = layer.map { input.hiddenLayers.contains($0) } ?? false
        return PageEntry(id: refs.first ?? pageRef, kind: kind, title: name, label: label(kind: kind, title: name, text: text),
                         text: text, refs: boundedRefs, refCount: refs.count, bbox: bbox, layer: layer,
                         hidden: hidden ? true : nil,
                         coveredByTape: nil, revealed: nil, actions: actions)
    }

    static func label(kind: EntryKind, title: String, text: String?) -> String {
        guard let t = text, !t.isEmpty else { return title }
        switch kind {
        case .handwriting: return String(localized: "Handwriting: \(t)")
        case .highlight: return String(localized: "Highlight: \(t)")
        case .text: return String(localized: "Text box: \(t)")
        case .sticky: return String(localized: "Sticky note: \(t)")
        case .image: return String(localized: "Image: \(t)")
        case .math: return String(localized: "Maths: \(t)")
        case .comment:
            return title == kind.title ? String(localized: "Comment: \(t)") : String(localized: "Resolved comment: \(t)")
        case .pdf: return String(localized: "PDF text: \(t)")
        case .scan: return String(localized: "Scanned text: \(t)")
        case .link: return String(localized: "Link: \(t)")
        case .connector: return String(localized: "Connector labelled \(t)")
        case .shape, .custom, .drawing, .tape: return String(localized: "\(title) with the text \(t)")
        }
    }

    static func action(_ id: String, _ title: String, _ command: String, _ params: JSONValue, _ input: Input) -> EntryAction {
        EntryAction(id: id, title: title, command: command, params: params,
                    available: input.availableCommands.contains(command))
    }

    static func tapeAction(refs: [String], reveal: Bool, input: Input) -> EntryAction {
        action(reveal ? "revealTape" : "hideTape", reveal ? String(localized: "Reveal Tape") : String(localized: "Hide Tape"),
               CommandIDs.tapeSetRevealed, ["refs": .array(refs.map { .string($0) }), "revealed": .bool(reveal)], input)
    }

    /// `link.follow` params for a text link: a URL, a page of a document, or an audio moment.
    static func linkAction(label: String, link: TextLink, doc: DocumentID, input: Input) -> EntryAction {
        var params: [String: JSONValue] = [:]
        if let url = link.url {
            params["url"] = .string(url)
        } else if let target = link.document ?? (link.page != nil ? doc : nil) {
            params["doc"] = .string(NodeRef.document(target).description)
            if let p = link.page { params["page"] = .string(NodeRef.page(target, p).description) }
        } else if let clip = link.audioClip {
            params["clip"] = .string(NodeRef.audio(doc, clip).description)
            if let t = link.audioTime { params["t"] = .number(t) }
        }
        let text = clean(label)
        return action("openLink", text.isEmpty ? String(localized: "Open Link") : String(localized: "Open Link: \(text)"),
                      CommandIDs.linkFollow, .object(params), input)
    }

    /// The linked runs of rich text: (the linked words, the link), adjacent runs with one link joined.
    static func links(in text: RichText) -> [(String, TextLink)] {
        var out: [(String, TextLink)] = []
        for paragraph in text.paragraphs {
            for run in paragraph.runs {
                guard let link = run.attrs.link else { continue }
                if let last = out.last, last.1 == link {
                    out[out.count - 1].0 += run.text
                } else {
                    out.append((run.text, link))
                }
            }
        }
        return out
    }

    static func shapeName(_ kind: ShapeKind) -> String {
        switch kind {
        case .line: return String(localized: "Line")
        case .polyline: return String(localized: "Polyline")
        case .polygon: return String(localized: "Polygon")
        case .rectangle: return String(localized: "Rectangle")
        case .roundedRectangle: return String(localized: "Rounded rectangle")
        case .ellipse: return String(localized: "Ellipse")
        case .triangle: return String(localized: "Triangle")
        case .diamond: return String(localized: "Diamond")
        case .arc: return String(localized: "Arc")
        case .curve: return String(localized: "Curve")
        case .arrow: return String(localized: "Arrow")
        }
    }

    /// Collapses whitespace and clips very long text.
    static func clean(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > maxTextLength else { return collapsed }
        return String(collapsed.prefix(maxTextLength)) + "…"
    }

    /// A string at a dot path in custom item data ("title", "series.label").
    static func value(at path: String, in data: JSONValue) -> String? {
        var v: JSONValue? = data
        for key in path.split(separator: ".") { v = v?[String(key)] }
        if let s = v?.stringValue { return s }
        if let n = v?.intValue { return String(n) }
        if let n = v?.doubleValue { return String(n) }
        return nil
    }

    static func bounds(_ items: [Item]) -> Rect {
        guard let first = items.first else { return .zero }
        return items.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    /// Groups strokes whose bounds come within `clusterGap` of each other (transitively), in first-seen order.
    static func clusters(_ items: [Item]) -> [[Item]] {
        var groups: [(rect: Rect, items: [Item])] = []
        for item in items.sorted(by: { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }) {
            let area = item.bounds.insetBy(-clusterGap / 2)
            if let i = groups.lastIndex(where: { $0.rect.insetBy(-clusterGap / 2).intersects(area) }) {
                groups[i].rect = groups[i].rect.union(item.bounds)
                groups[i].items.append(item)
            } else {
                groups.append((item.bounds, [item]))
            }
        }
        // Merge groups that grew into each other.
        var merged = true
        while merged && groups.count > 1 {
            merged = false
            outer: for i in groups.indices {
                for j in groups.indices where j > i {
                    if groups[i].rect.insetBy(-clusterGap / 2).intersects(groups[j].rect.insetBy(-clusterGap / 2)) {
                        groups[i].rect = groups[i].rect.union(groups[j].rect)
                        groups[i].items += groups[j].items
                        groups.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return groups.map { $0.items }
    }

    /// Whether a highlight and some text are mostly on top of each other (either way round: a highlight over one line
    /// of a text box, or a short word inside a long highlight).
    static func overlaps(_ a: Rect, _ b: Rect) -> Bool {
        max(overlapFraction(a, b), overlapFraction(b, a)) >= 0.5
    }

    /// Share of `a`'s area inside `b`.
    static func overlapFraction(_ a: Rect, _ b: Rect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard w > 0, h > 0, a.width > 0, a.height > 0 else {
            return a.width <= 0 || a.height <= 0 ? (b.contains(a.center) ? 1 : 0) : 0
        }
        return (w * h) / (a.width * a.height)
    }

    static func apply(_ t: Affine, to r: Rect) -> Rect {
        let corners = [Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.minX, r.maxY), Point(r.maxX, r.maxY)]
        return Rect.bounding(corners.map { t.apply($0) }) ?? r
    }

    // MARK: Title, summary, counts, paging

    static func title(record: PageRecord, index: Int?, count: Int) -> String {
        if record.size == nil { return record.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Board") }
        if let i = index { return String(localized: "Page \(i) of \(count)") }
        return record.title ?? String(localized: "Page")
    }

    static func counts(_ entries: [PageEntry]) -> [String: Int] {
        var out: [String: Int] = [:]
        for e in entries where e.hidden != true { out[e.kind.rawValue, default: 0] += 1 }
        return out
    }

    /// "Page 3 of 12" and, on the next line, what the page holds in reading-list order of kinds.
    static func summary(title: String, entries: [PageEntry]) -> String {
        let counts = counts(entries)
        guard !counts.isEmpty else { return title + "\n" + String(localized: "Nothing on this page yet.") }
        let parts = EntryKind.allCases.compactMap { kind in counts[kind.rawValue].map { kind.count($0) } }
        let list = ListFormatter.localizedString(byJoining: parts)
        return title + "\n" + String(localized: "This page has \(list).")
    }

    static func page(_ entries: [PageEntry], cursor: String?, version: String = "test") throws -> (items: [PageEntry], next: String?) {
        var start = 0
        if let c = cursor, !c.isEmpty {
            let parts = c.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == version, let n = Int(parts[1]), n >= 0, n <= entries.count else {
                throw NibError(.invalidParams, "invalid cursor '\(c)'", path: "$.cursor",
                               hint: "pass the cursor of the previous result unchanged")
            }
            start = n
        }
        var used = 0
        var end = start
        while end < entries.count {
            let size = entrySize(entries[end])
            if end > start && used + size > resultBudget { break }
            used += size
            end += 1
        }
        return (Array(entries[start..<end]), end < entries.count ? "\(version):\(end)" : nil)
    }

    /// Count encoded bytes, including escaping and field names, with room for the result envelope.
    static func entrySize(_ e: PageEntry) -> Int {
        ((try? JSONEncoder().encode(e).count) ?? resultBudget) + 1
    }
}

// MARK: - Reading order

/// Top-to-bottom lines, left to right within a line: an entry joins the current line when they overlap vertically by
/// at least half the shorter one's height. Tall entries (a drawing or a sticky note several lines high) are read where
/// they start and never gather the lines beside them into one.
enum ReadingOrder {
    static func sorted(_ entries: [PageEntry]) -> [PageEntry] {
        let heights = entries.map { $0.bbox.height }.sorted()
        let median = heights.isEmpty ? 0 : heights[heights.count / 2]
        let tallLimit = max(median * 3, 60)
        let byTop = entries.enumerated().sorted { a, b in
            (a.element.bbox.minY, a.element.bbox.minX, a.offset) < (b.element.bbox.minY, b.element.bbox.minX, b.offset)
        }
        var lines: [(top: Double, bottom: Double, tall: Bool, members: [(Int, PageEntry)])] = []
        for (offset, e) in byTop {
            let r = e.bbox
            let tall = r.height > tallLimit
            if !tall, var line = lines.last, !line.tall {
                let overlap = min(line.bottom, r.maxY) - max(line.top, r.minY)
                let shorter = max(1, min(line.bottom - line.top, r.height))
                if overlap >= shorter / 2 {
                    line.members.append((offset, e))
                    line.bottom = max(line.bottom, r.maxY)
                    lines[lines.count - 1] = line
                    continue
                }
            }
            lines.append((r.minY, r.maxY, tall, [(offset, e)]))
        }
        return lines.flatMap { line in
            line.members.sorted { ($0.1.bbox.minX, $0.0) < ($1.1.bbox.minX, $1.0) }.map { $0.1 }
        }
    }
}
