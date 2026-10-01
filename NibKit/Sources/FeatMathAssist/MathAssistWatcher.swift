import Foundation
import CryptoKit
import NibContracts
import os

/// Query summaries keep OCR independent of the canvas and never request live PencilKit ink.
struct AssistInk: Equatable {
    var ref: String
    var bounds: Rect
    var revision: String
    var layer: Int
}

struct AssistLine: Equatable {
    var ink: [AssistInk]
    var latex: String
    var warning: String?
    var answer: MathAnswer?
    var failure: String?
    var context: [String] = []
    var key: String { ink.map(\.ref).sorted().first ?? "" }
    var bounds: Rect { ink.dropFirst().reduce(ink.first?.bounds ?? .zero) { $0.union($1.bounds) } }
    var refs: [String] { ink.map(\.ref) }
    var isQuestion: Bool { latex.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("=") }
}

/// Stored in PageRecord.ext, so linked answers survive reopening, sync and undo.
struct AssistAnswerLink: Codable, Equatable {
    var source: [String]
    var latex: String
    var corrected: Bool
    var format: String
    var answer: String
    var refs: [String]
    var revisions: [String]
    var signatures: [String]? = nil
    var sourceRevisions: [String]? = nil
}

@MainActor
final class MathAssistWatcher {
    static let serviceKey = "mathassistoverlay.runtime"
    static let linksKey = "mathassistoverlay.answers"
    private weak var app: NibApp?
    private var subscriptions: [EventSubscription] = []
    private var settingsObserver: NSObjectProtocol?
    var writing = Set<String>()
    private var updating = Set<String>()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: Int] = [:]
    private var pending: [String: (update: Bool, group: String?)] = [:]
    private var recognitionCache: [String: (ink: [AssistInk], latex: String, warning: String?)] = [:]
    private var pageRevisions: [String: Rev] = [:]
    private(set) var pages: [String: [AssistLine]] = [:]
    private let logger = Logger(subsystem: "app.nib", category: "mathassistoverlay")

    init(app: NibApp) { self.app = app }
    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        subscriptions.forEach { $0.cancel() }
        tasks.values.forEach { $0.cancel() }
    }

    static func runtime(_ app: NibApp) -> MathAssistWatcher {
        if let existing = app.services.get(serviceKey, as: MathAssistWatcher.self) { return existing }
        let watcher = MathAssistWatcher(app: app)
        app.services.set(watcher, for: serviceKey)
        return watcher
    }

    func start() {
        guard subscriptions.isEmpty, let app else { return }
        subscriptions.append(app.bus.observeCommits { [weak self, weak app] changes in
            guard let self, let app else { return }
            var affected = Set<String>()
            for mutation in changes.mutations {
                switch mutation {
                case let .item(d, p, _, _): affected.insert(NodeRef.page(d, p).description)
                case let .page(d, _, p): affected.insert(NodeRef.page(d, p.id).description)
                case let .meta(d, _, _):
                    for session in app.services.sessions.sessions where session.document == d {
                        if let p = session.page { affected.insert(NodeRef.page(d, p).description) }
                    }
                default: break
                }
            }
            // An undo must never manufacture a new undo step or immediately reinsert a removed answer.
            let update = ![CommandIDs.undo, CommandIDs.redo, CommandIDs.mathAssist, "mathassist.reconcileLinks"].contains(changes.command)
            for page in affected {
                if self.writing.contains(page) {
                    if update {
                        self.pending[page] = (true, changes.group)
                    }
                } else { self.schedule(page, updateAnswers: update, group: changes.group) }
            }
        })
        subscriptions.append(app.events.subscribe { [weak self] event in
            guard [NibEventType.pageChanged, NibEventType.sessionDocument, NibEventType.docOpened,
                   NibEventType.sessionActivated, NibEventType.docClosed].contains(event.type) else { return }
            Task { @MainActor [weak self] in
                guard let self, let app = self.app else { return }
                if event.type == NibEventType.docClosed, let d = event.doc {
                    for key in self.tasks.keys where NodeRef(key)?.documentID == d {
                        self.tasks[key]?.cancel(); self.tasks[key] = nil
                        self.pending[key] = nil; self.generations[key] = nil
                    }
                    self.recognitionCache = self.recognitionCache.filter { NodeRef($0.key)?.documentID != d }
                    self.pageRevisions = self.pageRevisions.filter { NodeRef($0.key)?.documentID != d }
                    self.pages = self.pages.filter { NodeRef($0.key)?.documentID != d }
                    self.notify()
                }
                for session in app.services.sessions.sessions {
                    if let d = session.document, let p = session.page {
                        self.schedule(NodeRef.page(d, p).description)
                    }
                }
            }
        })
        settingsObserver = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings, queue: .main) { [weak self] notification in
            guard notification.userInfo?["name"] as? String == NibSettings.mathAssistSuggestions.name else { return }
            Task { @MainActor [weak self] in
                guard let self, let app = self.app else { return }
                for session in app.services.sessions.sessions {
                    if let d = session.document, let p = session.page { self.schedule(NodeRef.page(d, p).description) }
                }
            }
        }
        for session in app.services.sessions.sessions {
            if let d = session.document, let p = session.page { schedule(NodeRef.page(d, p).description) }
        }
    }

    func observe(_ body: @escaping () -> Void) -> EventSubscription? {
        app?.events.subscribe { event in
            if event.type == "mathassistoverlay.changed" { Task { @MainActor in body() } }
        }
    }

    private func notify() { app?.events.emit("mathassistoverlay.changed") }

    func schedule(_ page: String, updateAnswers: Bool? = nil, group: String? = nil) {
        let request = (update: updateAnswers ?? pending[page]?.update ?? false,
                       group: updateAnswers != nil ? group : pending[page]?.group)
        pending[page] = request
        if writing.contains(page) { return }
        generations[page, default: 0] += 1
        let generation = generations[page, default: 0]
        tasks[page]?.cancel()
        tasks[page] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
                guard let self else { return }
                while self.app?.services.sessions.sessions.contains(where: {
                    $0.document == NodeRef(page)?.documentID && $0.inking.isInking
                }) == true { try await Task.sleep(nanoseconds: 100_000_000) }
                let lines = try await self.scan(page)
                try Task.checkCancellation()
                guard self.generations[page] == generation else { return }
                self.pages[page] = lines
                self.notify()
                if request.update { try await self.updateAnswers(page, lines: lines, group: request.group) }
                if self.generations[page] == generation { self.pending[page] = nil }
            } catch is CancellationError { }
            catch {
                guard let self, self.generations[page] == generation else { return }
                self.pages[page] = []
                self.pageRevisions[page] = nil
                self.notify()
                self.logger.debug("Math Assist scan failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Vertical bands join the equals sign's short strokes to the expression; layers and distant columns stay separate.
    nonisolated static func group(_ input: [AssistInk]) -> [[AssistInk]] {
        // Keep union bounds once per component. The vertical sweep retires groups which cannot
        // touch a later stroke; a bridging stroke merges every compatible active component.
        var active: [Int: (ink: [AssistInk], bounds: Rect, layer: Int)] = [:]
        var finished: [[AssistInk]] = []
        var next = 0
        for item in input.sorted(by: { ($0.bounds.y, $0.bounds.x, $0.ref) < ($1.bounds.y, $1.bounds.x, $1.ref) }) {
            for id in Array(active.keys) {
                guard let group = active[id] else { continue }
                if group.bounds.maxY + max(2, group.bounds.height * 0.4) < item.bounds.minY {
                    finished.append(group.ink); active[id] = nil
                }
            }
            var joined = [item], bounds = item.bounds
            var merged: Bool
            repeat {
                merged = false
                for id in active.keys.sorted() {
                    guard let group = active[id], group.layer == item.layer else { continue }
                    let box = group.bounds
                    let overlap = min(box.maxY, bounds.maxY) - max(box.minY, bounds.minY)
                    let tolerance = max(2, min(box.height, bounds.height) * 0.4)
                    let gap = max(0, max(bounds.minX - box.maxX, box.minX - bounds.maxX))
                    if overlap >= -tolerance && gap <= max(40, max(box.height, bounds.height) * 3) {
                        joined += group.ink; bounds = bounds.union(box); active[id] = nil; merged = true
                    }
                }
            } while merged
            active[next] = (joined, bounds, item.layer); next += 1
        }
        finished += active.values.map(\.ink)
        return finished.map { $0.sorted { ($0.bounds.x, $0.ref) < ($1.bounds.x, $1.ref) } }
            .sorted {
                let a = $0.dropFirst().reduce($0[0].bounds) { $0.union($1.bounds) }
                let b = $1.dropFirst().reduce($1[0].bounds) { $0.union($1.bounds) }
                return (a.y, a.x, $0[0].ref) < (b.y, b.x, $1[0].ref)
            }
    }

    func links(doc: DocumentID, page: PageID) throws -> [String: AssistAnswerLink] {
        guard let app else { return [:] }
        let record = try app.workspace.content(doc).livePages.first { $0.id == page }
        guard let json = record?.ext?[Self.linksKey] else { return [:] }
        return try json.decode([String: AssistAnswerLink].self)
    }

    func scan(_ page: String, force: Bool = false, context: CommandContext? = nil) async throws -> [AssistLine] {
        guard let app, case let .page(doc, pageID)? = NodeRef(page) else {
            throw NibError.invalid("Pass a page ref", path: "$.page")
        }
        if app.services.lock?.isLocked(doc) == true { throw NibError(.locked, "Unlock the document to use Math Assist") }
        // The query API does not promise raw meta/ext records. Only feature-owned link state and the document's
        // opt-in are read from Workspace; all handwriting/content reads go through query.get.
        let execute: (String, JSONValue) async throws -> JSONValue = { command, params in
            if let context { return try await context.execute(command, params) }
            return try await app.bus.execute(command, params)
        }
        let content = try app.workspace.content(doc)
        guard content.livePages.contains(where: { $0.id == pageID }) else { throw NibError.notFound(page) }
        guard force || (content.meta.mathAssist && app.settings.get(NibSettings.mathAssistSuggestions)) else {
            pages[page] = []; pageRevisions[page] = nil
            return []
        }
        let revision = app.workspace.contentRevision(doc, page: pageID)
        if let revision, pageRevisions[page] == revision, let cached = pages[page] { return cached }
        let links = try links(doc: doc, page: pageID)
        let generated = Set(links.values.flatMap(\.refs))
        var ink: [AssistInk] = [], cursor: String?, seen = Set<String>(), cursors = Set<String>()
        var typedDefinitions: [String] = []
        repeat {
            var object: [String: JSONValue] = ["ref": .string(page), "fields": ["bbox", "layer", "tool", "rev", "math"]]
            if let cursor { object["cursor"] = .string(cursor) }
            let params = JSONValue.object(object)
            let response = try await execute(CommandIDs.queryGet, params)
            guard let items = response["items"]?.arrayValue else { throw NibError.unavailable("query.get did not return page items") }
            for item in items {
                guard let ref = item["ref"]?.stringValue, seen.insert(ref).inserted, !generated.contains(ref) else { continue }
                if item["kind"]?.stringValue == "math" {
                    if let text = item["text"]?.stringValue {
                        typedDefinitions += text.components(separatedBy: .newlines)
                    } else if let latex = item["math"]?["latex"]?.arrayValue {
                        typedDefinitions += latex.compactMap(\.stringValue)
                    }
                }
                guard item["kind"]?.stringValue == "stroke", ["pen", "pencil"].contains(item["tool"]?.stringValue ?? ""),
                      let bbox = item["bbox"]?.arrayValue, bbox.count == 4 else { continue }
                let v = bbox.compactMap(\.doubleValue)
                guard v.count == 4, v.allSatisfy(\.isFinite), v[2] >= 0, v[3] >= 0 else { continue }
                ink.append(AssistInk(ref: ref, bounds: Rect(x: v[0], y: v[1], width: v[2], height: v[3]),
                                     revision: item["rev"]?.stringValue ?? "", layer: item["layer"]?.intValue ?? 0))
            }
            cursor = response["cursor"]?.stringValue
            if let cursor, !cursors.insert(cursor).inserted { throw NibError.unavailable("query.get repeated its page cursor") }
            guard ink.count <= 10_000 else { throw NibError.unsupported("Math Assist supports up to 10,000 handwriting items per page") }
        } while cursor != nil
        var lines: [AssistLine] = []
        recognitionCache = recognitionCache.filter { key, _ in
            NodeRef(key)?.documentID != doc || NodeRef(key)?.pageID != pageID || seen.contains(key)
        }
        for group in Self.group(ink) {
            try Task.checkCancellation()
            guard !app.services.sessions.sessions.contains(where: { $0.document == doc && $0.inking.isInking }) else {
                throw NibError.unavailable("Finish writing before recognising maths")
            }
            let key = group.map(\.ref).sorted().first ?? ""
            let latex: String, warning: String?
            var recognizedInk = group
            if let cache = recognitionCache[key], Self.sameRevisions(cache.ink, group), group.allSatisfy({ !$0.revision.isEmpty }) {
                latex = cache.latex; warning = cache.warning
            } else {
                do {
                    let result = try await execute(CommandIDs.mathRecognize, ["refs": .array(group.map { .string($0.ref) })])
                    guard let recognized = result["lines"]?.arrayValue?.compactMap(\.stringValue), recognized.count == 1 else { continue }
                    latex = recognized[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    warning = result["warning"]?.stringValue
                    guard latex.count <= 8192 else { continue }
                    if let revs = result["revs"]?.arrayValue?.compactMap(\.stringValue), revs.count == group.count {
                        for i in recognizedInk.indices where recognizedInk[i].revision.isEmpty { recognizedInk[i].revision = revs[i] }
                    }
                    recognitionCache[key] = (recognizedInk, latex, warning)
                } catch is CancellationError { throw CancellationError() }
                catch { continue } // Non-mathematical writing is expected on a notebook page.
            }
            lines.append(AssistLine(ink: recognizedInk, latex: latex, warning: warning))
        }
        let reconciled = try reconcile(links, lines: lines, doc: doc, page: pageID)
        for i in lines.indices {
            if let link = reconciled[lines[i].key], link.corrected,
               Self.sameRefs(link.source, lines[i].refs) { lines[i].latex = link.latex }
        }
        let context = await Self.definitions(lines.map(\.latex) + typedDefinitions)
        for index in lines.indices { lines[index].context = context }
        for index in lines.indices where lines[index].isQuestion {
            do {
                let expression = (context + [lines[index].latex]).joined(separator: "\n")
                let value = try await execute(CommandIDs.mathEvaluate, ["expression": .string(expression)])
                lines[index].answer = try value.decode(MathAnswer.self)
            } catch is CancellationError { throw CancellationError() }
            catch { lines[index].failure = NibError.wrap(error).message }
        }
        try Task.checkCancellation()
        if revision == app.workspace.contentRevision(doc, page: pageID) {
            pages[page] = lines
            pageRevisions[page] = revision
        }
        return lines
    }

    nonisolated static func sameRefs(_ a: [String], _ b: [String]) -> Bool { Set(a) == Set(b) }

    nonisolated static func sameRevisions(_ a: [AssistInk], _ b: [AssistInk]) -> Bool {
        a.count == b.count && Dictionary(uniqueKeysWithValues: a.map { ($0.ref, $0.revision) }) ==
            Dictionary(uniqueKeysWithValues: b.map { ($0.ref, $0.revision) })
    }

    /// Source identity can change when an equation is erased and rewritten. Prefer shared source
    /// strokes, then the old answer's writing position. Each link belongs to at most one question.
    func reconcile(_ saved: [String: AssistAnswerLink], lines: [AssistLine], doc: DocumentID,
                   page: PageID) throws -> [String: AssistAnswerLink] {
        guard let app else { return [:] }
        var result: [String: AssistAnswerLink] = [:]
        for key in saved.keys.sorted() {
            guard var link = saved[key] else { continue }
            let source = Set(link.source)
            let anchor = link.refs.compactMap { ref -> Rect? in
                guard case let .item(d, p, id)? = NodeRef(ref), d == doc, p == page,
                      let item = try? app.workspace.item(d, page: p, id: id), !item.deleted else { return nil }
                return item.bounds
            }.first
            let candidates = lines.filter { line in
                if !source.isDisjoint(with: line.refs) { return true }
                guard let anchor else { return false }
                let box = line.bounds
                let margin = max(12, box.height * 0.5)
                return anchor.minY >= box.minY - margin && anchor.minY <= box.maxY + margin &&
                    abs(anchor.minX - box.maxX) <= max(40, box.height)
            }.sorted { a, b in
                let ac = source.intersection(a.refs).count, bc = source.intersection(b.refs).count
                if ac != bc { return ac > bc }
                let ax = abs((anchor?.minX ?? a.bounds.maxX) - a.bounds.maxX)
                let bx = abs((anchor?.minX ?? b.bounds.maxX) - b.bounds.maxX)
                return ax == bx ? a.key < b.key : ax < bx
            }
            guard let line = candidates.first, line.isQuestion, result[line.key] == nil else { continue }
            let revisions = line.ink.map(\.revision)
            if !Self.sameRefs(link.source, line.refs) ||
                (link.sourceRevisions != nil && link.sourceRevisions != revisions) {
                link.corrected = false; link.latex = line.latex
            }
            link.source = line.refs
            result[line.key] = link
        }
        return result
    }

    nonisolated static func definitions(_ lines: [String]) async -> [String] {
        (try? await MathStack.perform {
            var engine = MathEngine(), result: [String] = []
            for line in lines where line.count <= 8192 {
                guard let statements = try? MathParser.statements(line), statements.count == 1 else { continue }
                if engine.define(statements[0]) { result.append(line) }
            }
            return result
        }) ?? []
    }

    static func signature(_ item: Item) throws -> String {
        var normalized = item
        normalized.rev = .zero
        let json = try JSONValue.from(normalized).jsonString()
        return SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ item: Item, link: AssistAnswerLink, index: Int) -> Bool {
        if let signatures = link.signatures, index < signatures.count {
            // Existing documents may contain the original full JSON signature. New writes always
            // migrate to a fixed-size digest; revision fallback remains for links without signatures.
            if signatures[index].hasPrefix("{") {
                var normalized = item; normalized.rev = .zero
                return (try? JSONValue.from(normalized).jsonString()) == signatures[index]
            }
            return (try? signature(item)) == signatures[index]
        }
        return index < link.revisions.count && item.rev.description == link.revisions[index]
    }

    func didWrite(_ page: String) {
        writing.remove(page)
        pageRevisions[page] = nil
        if !updating.contains(page) || pending[page]?.update == true { schedule(page) }
    }

    func updateAnswers(_ page: String, lines: [AssistLine], group: String? = nil) async throws {
        guard let app, case let .page(doc, pageID)? = NodeRef(page), !app.isReadOnly(doc) else { return }
        updating.insert(page)
        defer { updating.remove(page) }
        let saved = try reconcile(links(doc: doc, page: pageID), lines: lines, doc: doc, page: pageID)
        for (index, line) in lines.enumerated() {
            guard let link = saved[line.key], line.answer != nil, Self.sameRefs(link.source, line.refs) else { continue }
            let value = try await app.bus.execute(CommandIDs.mathEvaluate,
                ["expression": .string((line.context + [line.latex]).joined(separator: "\n")), "format": .string(link.format)])
            let answer = try value.decode(MathAnswer.self)
            guard answer.answer != link.answer else { continue }
            // Never overwrite an answer the user has edited or erased since it was generated.
            var unchanged = true
            for (i, ref) in link.refs.enumerated() {
                guard case let .item(d, p, id)? = NodeRef(ref), i < link.revisions.count,
                      let item = try? app.workspace.item(d, page: p, id: id), !item.deleted,
                      Self.matches(item, link: link, index: i) else { unchanged = false; break }
            }
            if unchanged {
                var params: [String: JSONValue] = ["page": .string(page), "line": .number(Double(index)),
                    "format": .string(link.format), "refs": .array(line.refs.map(JSONValue.string))]
                if link.corrected { params["latex"] = .string(line.latex) }
                _ = try await app.bus.execute(Invocation(command: CommandIDs.mathAssist, params: .object(params), group: group))
            }
        }
        _ = try await app.bus.execute(Invocation(command: "mathassist.reconcileLinks", params: ["page": .string(page)], group: group))
    }
}
