import Foundation
import UIKit
import NibContracts

// Service fakes shared by every feature's tests, so nobody writes their own. Install what you need:
//   let h = Harness(); let ai = FakeAIService(); h.app.services.ai = ai

/// Secrets in memory (hostless tests have no Keychain entitlement). `Harness` installs one as `Keychain.store`.
public final class InMemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func set(_ data: Data?, service: String, account: String) -> Bool {
        lock.lock()
        values[service + "/" + account] = data
        lock.unlock()
        return true
    }

    public func get(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[service + "/" + account]
    }
}

/// Renders blank images of the requested size; `marks` is returned verbatim when requested.
public final class FakeRenderer: PageRenderer {
    public var marks: [String: String] = [:]
    public private(set) var requests: [RenderRequest] = []
    public private(set) var invalidations: [(DocumentID, PageID, Rect?)] = []
    public var pageSize = PageSize.a4

    public init() {}

    public func render(_ request: RenderRequest) async throws -> RenderResult {
        requests.append(request)
        let region = request.region ?? Rect(x: 0, y: 0, width: pageSize.width, height: pageSize.height)
        let size = CGSize(width: max(1, region.width * request.scale), height: max(1, region.height * request.scale))
        return RenderResult(image: FakeRenderer.blank(size), region: region, scale: request.scale,
                            marks: request.marks ? marks : [:])
    }

    public func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        FakeRenderer.blank(CGSize(width: maxPixelSize, height: maxPixelSize))
    }

    public func invalidate(doc: DocumentID, page: PageID, rect: Rect?) { invalidations.append((doc, page, rect)) }
    public func purgeCaches() {}

    public static func blank(_ size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.cgImage!
    }
}

/// Returns `script` for every recognition call (set it per test); records calls.
public final class FakeRecognizer: TextRecognizer {
    public var script: [TextRecognition] = []
    public private(set) var strokeCalls = 0
    public private(set) var imageCalls = 0

    public init(_ script: [TextRecognition] = []) { self.script = script }

    public func recognize(strokes: [Item], language: String) async throws -> [TextRecognition] {
        strokeCalls += 1
        return script
    }

    public func recognize(image: CGImage, language: String) async throws -> [TextRecognition] {
        imageCalls += 1
        return script
    }
}

/// Scripted AI: each turn pops the next `responses` entry (else echoes), first running its `toolCalls` through the
/// bus as the request's principal in the turn's undo group (so "one turn = one undo step" is testable).
@MainActor
public final class FakeAIService: AIService {
    public struct Turn {
        public var text: String
        public var toolCalls: [(command: String, params: JSONValue)]
        public init(text: String, toolCalls: [(command: String, params: JSONValue)] = []) {
            self.text = text
            self.toolCalls = toolCalls
        }
    }

    public var isConfigured = true
    public var supportsVision = true
    public var responses: [Turn] = []
    public var transcript: [TranscriptSegment] = []
    public private(set) var requests: [AIRequest] = []
    /// Needed only when turns carry tool calls.
    public weak var bus: CommandBus?
    private var store: [String: [AIMessage]] = [:]

    public init(responses: [Turn] = [], bus: CommandBus? = nil) {
        self.responses = responses
        self.bus = bus
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        requests.append(request)
        let turn = responses.isEmpty ? Turn(text: request.messages.last?.text ?? "") : responses.removeFirst()
        let group = request.group ?? NibID.make().raw
        var changes = ChangeSummary()
        for call in turn.toolCalls {
            guard let bus = bus else { throw NibError.unavailable("FakeAIService.bus") }
            let r = try await bus.execute(Invocation(command: call.command, params: call.params, principal: request.principal,
                                                     group: group, readOnly: request.mode == .ask))
            changes.merge(r.changes)
        }
        let chat = request.chatID ?? "fake-chat"
        store[chat, default: []] += request.messages + [AIMessage(role: "assistant", text: turn.text)]
        return AIResponse(text: turn.text, changes: changes, group: group, chatID: chat)
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let r = try await self.complete(request)
                    continuation.yield(.text(r.text))
                    continuation.yield(.finished(r))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancel(chatID: String) {}
    public func chats(doc: DocumentID?) -> [AIChatSummary] {
        store.keys.sorted().map { AIChatSummary(id: $0, title: $0, doc: doc, updated: 0) }
    }
    public func messages(chatID: String) -> [AIMessage] { store[chatID] ?? [] }
    public func deleteChat(_ chatID: String) { store[chatID] = nil }
    public func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] { transcript }
    public func generateImage(prompt: String) async throws -> Data { Fixtures.pngData }
}

/// Scripted PDF facts keyed by file name (`url.lastPathComponent`).
public final class FakePDFService: PDFService {
    public var pages: [String: Int] = [:]
    public var texts: [String: String] = [:]
    public var linkMap: [String: [PDFLinkInfo]] = [:]
    public var outlines: [String: [PDFOutlineNode]] = [:]
    /// contracts-v2: words per file name for `word(_:page:at:)` (the first whose rect contains the point).
    public var words: [String: [(text: String, rect: Rect)]] = [:]

    public init() {}

    public func pageCount(_ url: URL) -> Int { pages[url.lastPathComponent] ?? 1 }
    public func pageSize(_ url: URL, page: Int) -> PageSize? { .a4 }
    public func text(_ url: URL, page: Int) -> String? { texts[url.lastPathComponent] }
    public func textBlocks(_ url: URL, page: Int) -> [TextRecognition] {
        texts[url.lastPathComponent].map { [TextRecognition(text: $0, bbox: Rect(x: 72, y: 72, width: 400, height: 20), source: "pdf")] } ?? []
    }
    public func links(_ url: URL, page: Int) -> [PDFLinkInfo] { linkMap[url.lastPathComponent] ?? [] }
    public func outline(_ url: URL) -> [PDFOutlineNode] { outlines[url.lastPathComponent] ?? [] }
    public func selection(_ url: URL, page: Int, from: Point, to: Point) -> (text: String, rects: [Rect]) {
        (texts[url.lastPathComponent] ?? "", [Rect(x: from.x, y: from.y, width: max(1, to.x - from.x), height: 18)])
    }
    public func word(_ url: URL, page: Int, at point: Point) -> (text: String, rect: Rect)? {
        words[url.lastPathComponent]?.first { $0.rect.contains(point) }
    }
}

/// Locks the documents in `locked`; `unlock` succeeds when `unlockSucceeds`.
@MainActor
public final class FakeLockService: LockService {
    public var locked: Set<DocumentID> = []
    public var unlockSucceeds = true

    public init(locked: Set<DocumentID> = []) { self.locked = locked }

    public func isLocked(_ doc: DocumentID) -> Bool { locked.contains(doc) }
    public func unlock(_ doc: DocumentID) async -> Bool {
        if unlockSucceeds { locked.remove(doc) }
        return unlockSucceeds
    }
}

public extension PluginManifest {
    /// Builds a manifest from JSON (the manifest types have no public memberwise inits by design).
    static func fixture(id: String = "dev.test.plugin", permissions: [String] = ["document:read", "document:write"],
                        contributes: JSONValue = [:], entry: String = "main.js") throws -> PluginManifest {
        let json: JSONValue = ["id": .string(id), "name": .string(id), "version": "1.0.0", "api": 1, "entry": .string(entry),
                               "permissions": .array(permissions.map { .string($0) }), "contributes": contributes]
        return try json.decode(PluginManifest.self)
    }
}

/// A view-less canvas for tool, attachment and gesture tests: `pages` stacked top to bottom (`pageSize`, `gap`, page
/// points) and scaled by `zoomScale` into view coordinates. Records what the code under test asked of the canvas.
/// `commitStroke` only records (register a stand-in `ink.addStrokes` if a test needs the real commit path).
@MainActor
public final class FakeCanvasHost: CanvasHost {
    public let app: NibApp
    public let session: EditorSession
    public let documentID: DocumentID
    public var zoomScale: Double = 1
    public var pages: [PageID]
    public var pageSize = PageSize.a4
    public var gap: Double = 20
    public let canvasView: UIView
    public let overlayLayer = CALayer()
    public private(set) var hidden: [PageID: Set<ElementID>] = [:]
    public private(set) var invalidations: [(page: PageID, rect: Rect?)] = []
    public private(set) var committed: [(stroke: Stroke, page: PageID)] = []
    public private(set) var wetStrokeCancels = 0
    public private(set) var liveViews: [ElementID: UIView] = [:]
    /// contracts-v2: pages passed to `afterNextRender` (the fake runs the body at once).
    public private(set) var renderWaits: [PageID] = []

    public init(app: NibApp, session: EditorSession, doc: DocumentID = Fixtures.docID,
                pages: [PageID] = [Fixtures.page1, Fixtures.page2]) {
        self.app = app
        self.session = session
        self.documentID = doc
        self.pages = pages
        canvasView = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        canvasView.layer.addSublayer(overlayLayer)
    }

    /// The Harness's app and session on the fixture document.
    public convenience init(_ harness: Harness) { self.init(app: harness.app, session: harness.session) }

    public func pageFrame(_ page: PageID) -> CGRect? {
        guard let i = pages.firstIndex(of: page) else { return nil }
        return CGRect(x: 0, y: Double(i) * (pageSize.height + gap) * zoomScale,
                      width: pageSize.width * zoomScale, height: pageSize.height * zoomScale)
    }

    public func viewPoint(_ p: Point, page: PageID) -> CGPoint {
        let o = pageFrame(page)?.origin ?? .zero
        return CGPoint(x: Double(o.x) + p.x * zoomScale, y: Double(o.y) + p.y * zoomScale)
    }

    public func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)? {
        for page in pages {
            if let f = pageFrame(page), f.contains(v) {
                return (page, Point(Double(v.x - f.minX) / zoomScale, Double(v.y - f.minY) / zoomScale))
            }
        }
        return nil
    }

    public func setHidden(_ ids: Set<ElementID>, page: PageID) { hidden[page] = ids.isEmpty ? nil : ids }
    public func invalidate(page: PageID, rect: Rect?) { invalidations.append((page, rect)) }
    public func commitStroke(_ stroke: Stroke, page: PageID) { committed.append((stroke, page)) }
    public func cancelWetStroke() { wetStrokeCancels += 1 }
    public func attachLiveView(_ view: UIView?, item: ElementID, page: PageID) { liveViews[item] = view }

    /// Runs `body` immediately (tests need no render delay) and records the page.
    public func afterNextRender(page: PageID, _ body: @escaping @MainActor () -> Void) {
        renderWaits.append(page)
        body()
    }
}

/// Collaboration transport inside one process: transports sharing a `Hub` that host/join the same code exchange
/// messages synchronously (two-Harness collaboration tests). `leave()` then `join` simulates suspend and rejoin.
@MainActor
public final class InMemoryCollabTransport: CollabTransport {
    /// Switchboard shared by the transports of one test: code → transports in that session.
    @MainActor
    public final class Hub {
        fileprivate var rooms: [String: [InMemoryCollabTransport]] = [:]
        public init() {}
    }

    public let id = "memory"
    public let hub: Hub
    /// This participant as the other transports see it.
    public private(set) var me: CollabPeer
    public var displayName: String { me.name }
    public var maxPeers = 8
    public var onMessage: ((CollabPeer, Data) -> Void)?
    public var onPeersChanged: (([CollabPeer]) -> Void)?
    /// Every payload this transport sent, in order.
    public private(set) var sent: [Data] = []
    private var code: String?

    public init(hub: Hub, peerID: String = NibID.make().raw) {
        self.hub = hub
        self.me = CollabPeer(id: peerID, name: "")
    }

    private var room: [InMemoryCollabTransport] { code.flatMap { hub.rooms[$0] } ?? [] }
    public var peers: [CollabPeer] { room.filter { $0 !== self }.map(\.me) }

    public func host(code: String, displayName: String) async throws { try enter(code, displayName) }

    public func join(code: String, displayName: String) async throws {
        guard hub.rooms[code]?.isEmpty == false else { throw NibError.notFound("collaboration session \(code)") }
        try enter(code, displayName)
    }

    public func send(_ data: Data, to peers: [CollabPeer]?) throws {
        guard code != nil else { throw NibError.unavailable("collaboration session") }
        sent.append(data)
        for t in room where t !== self && (peers?.contains(t.me) ?? true) { t.onMessage?(me, data) }
    }

    public func leave() {
        guard let c = code else { return }
        hub.rooms[c]?.removeAll { $0 === self }
        code = nil
        for t in hub.rooms[c] ?? [] { t.onPeersChanged?(t.peers) }
    }

    private func enter(_ code: String, _ name: String) throws {
        leave()
        guard (hub.rooms[code]?.count ?? 0) < maxPeers else { throw NibError.unavailable("collaboration session is full") }
        me.name = name
        self.code = code
        hub.rooms[code, default: []].append(self)
        for t in room { t.onPeersChanged?(t.peers) }
    }
}
