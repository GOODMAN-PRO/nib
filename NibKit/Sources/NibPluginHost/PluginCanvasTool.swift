import Foundation
import UIKit
import NibContracts

// Canvas input for plugins (docs/PLUGIN_API.md §5.4, §5.9). JavaScript never runs per Pencil sample: the host captures
// the input and draws the preview, then calls the plugin's command once. Stroke processors run the plugin once per
// finished stroke with a 50 ms budget and keep the raw stroke when the plugin is late or fails.

enum PluginToolInput: String, Equatable {
    /// {page, pts: [x, y, …], fmt: "xy", bbox} when the pen lifts.
    case stroke
    /// {page, point}.
    case tap
    /// {page, rect} of the dragged rectangle.
    case rect
}

enum PluginToolPreview: String, Equatable {
    case ink, lasso, none
    /// Dashed rectangle (rect input).
    case rect

    static func resolve(_ raw: String?, input: PluginToolInput) -> PluginToolPreview {
        switch input {
        case .rect: return .rect
        case .tap: return .none
        case .stroke: return raw.flatMap(PluginToolPreview.init(rawValue:)) ?? .ink
        }
    }
}

struct PluginToolSpec: Equatable {
    var id: String
    var pluginID: String
    var command: String
    var input: PluginToolInput
    var preview: PluginToolPreview
    var sticky: Bool
}

/// The page points of one tool gesture (pure, tested): de-duplicated samples on the page the gesture started on.
struct ToolGesture: Equatable {
    static let minSpacing = 0.5
    let page: PageID
    private(set) var points: [Point]

    init(page: PageID, start: Point) {
        self.page = page
        self.points = [start]
    }

    mutating func add(_ p: Point) {
        if let last = points.last, last.distance(to: p) < ToolGesture.minSpacing { return }
        points.append(p)
    }

    /// The dragged rectangle (first to last point), normalised.
    var rect: Rect? {
        guard let a = points.first, let b = points.last else { return nil }
        let r = Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        return r.width >= 1 && r.height >= 1 ? r : nil
    }

    /// The command params for `input` (nil = nothing to send, e.g. a rectangle without area).
    func params(for input: PluginToolInput, doc: DocumentID) -> JSONValue? {
        let page = JSONValue.string(NodeRef.page(doc, self.page).description)
        switch input {
        case .stroke:
            guard let box = Rect.bounding(points) else { return nil }
            return ["page": page, "fmt": "xy", "pts": .array(points.flatMap { [JSONValue.number($0.x), .number($0.y)] }),
                    "bbox": [.number(box.x), .number(box.y), .number(box.width), .number(box.height)]]
        case .rect:
            guard let r = rect else { return nil }
            return ["page": page, "rect": [.number(r.x), .number(r.y), .number(r.width), .number(r.height)]]
        case .tap:
            guard let p = points.first else { return nil }
            return ["page": page, "point": [.number(p.x), .number(p.y)]]
        }
    }
}

/// A plugin canvas tool (`ui.canvasTools`, selected with `tool.select`): stroke, tap or rectangle input with a
/// host-drawn preview; on lift (or tap) the plugin's command runs as the user in the window's session.
@MainActor
final class PluginCanvasTool: CanvasTool {
    let spec: PluginToolSpec
    private var gesture: ToolGesture?
    private var preview: CAShapeLayer?

    init(_ spec: PluginToolSpec) {
        self.spec = spec
    }

    var id: String { spec.id }
    var isSticky: Bool { spec.sticky }
    var inputMode: CanvasInputMode { spec.input == .tap ? .taps : .samples }

    func deactivate(_ host: CanvasHost) {
        gesture = nil
        clearPreview()
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        guard spec.input != .tap else { return }
        gesture = ToolGesture(page: sample.page, start: sample.location)
        drawPreview(host)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard var g = gesture else { return }
        for s in samples where !s.isPredicted {
            guard let p = s.page == g.page ? s.location : host.convert(s.location, from: s.page, to: g.page) else { continue }
            g.add(p)
        }
        gesture = g
        drawPreview(host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard var g = gesture else { return }
        if let p = sample.page == g.page ? sample.location : host.convert(sample.location, from: sample.page, to: g.page) {
            g.add(p)
        }
        gesture = nil
        guard let params = g.params(for: spec.input, doc: host.documentID) else {
            clearPreview()
            return
        }
        drawPreview(host, gesture: g)
        run(params, host: host)
    }

    func touchesCancelled(host: CanvasHost) {
        gesture = nil
        clearPreview()
    }

    func tap(_ sample: CanvasSample, host: CanvasHost) {
        guard spec.input == .tap else { return }
        let g = ToolGesture(page: sample.page, start: sample.location)
        guard let params = g.params(for: .tap, doc: host.documentID) else { return }
        run(params, host: host)
    }

    /// Runs the tool's command once; the preview stays until the result is on screen.
    private func run(_ params: JSONValue, host: CanvasHost) {
        let app = host.app
        let session = host.session
        let command = spec.command
        let page = gestureParamsPage(params) ?? session.page
        Task { @MainActor [weak self] in
            do {
                _ = try await app.bus.execute(Invocation(command: command, params: params, principal: .user, session: session))
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
            }
            guard let self = self else { return }
            if let p = page {
                host.afterNextRender(page: p) { [weak self] in self?.clearPreview() }
            } else {
                self.clearPreview()
            }
            host.finishToolUse(self)
        }
    }

    private func gestureParamsPage(_ params: JSONValue) -> PageID? {
        guard case let .page(_, p)? = NodeRef(params["page"]?.stringValue ?? "") else { return nil }
        return p
    }

    // MARK: Preview

    private func drawPreview(_ host: CanvasHost, gesture explicit: ToolGesture? = nil) {
        guard spec.preview != .none, let g = explicit ?? gesture else { return }
        let layer = preview ?? {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            host.overlayLayer.addSublayer(l)
            preview = l
            return l
        }()
        layer.strokeColor = UIColor.tintColor.cgColor
        let path = CGMutablePath()
        let points: [Point]
        switch spec.preview {
        case .rect:
            guard let r = g.rect else {
                layer.path = nil
                return
            }
            points = [Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.maxX, r.maxY), Point(r.minX, r.maxY)]
        default:
            points = g.points
        }
        let view = points.map { host.viewPoint($0, page: g.page) }
        guard let first = view.first else { return }
        path.move(to: first)
        for p in view.dropFirst() { path.addLine(to: p) }
        switch spec.preview {
        case .ink:
            layer.lineWidth = 2
            layer.lineDashPattern = nil
        case .lasso, .rect:
            path.closeSubpath()
            layer.lineWidth = 1.5
            layer.lineDashPattern = [6, 4]
        case .none:
            break
        }
        layer.path = path
    }

    private func clearPreview() {
        preview?.removeFromSuperlayer()
        preview = nil
    }
}

// MARK: - Stroke processors

/// A plugin stroke processor in `content.strokeProcessors`. Processors run synchronously while a stroke is committed,
/// but plugin JavaScript is asynchronous, so the first plugin processor in the registry takes the stroke over: it drops
/// it from the synchronous chain (the built-in processors, ordered before plugins, have already run) and runs every
/// applicable plugin processor in registry order, each once with {page, stroke} and a 50 ms budget, then commits the
/// result with `ink.addStrokes` as the user. `{stroke}` replaces the stroke, `{drop: true}` removes it, and a late
/// answer or an error keeps the stroke as it was.
@MainActor
final class PluginStrokeRunner: StrokeProcessor {
    /// After every built-in processor (stabilisation, straight highlighter, ruler projection).
    static let order = 100_000

    private weak var app: NibApp?
    private weak var host: PluginHost?
    let pluginID: String
    let id: String
    let command: String
    let tools: Set<InkTool>

    init(app: NibApp, host: PluginHost?, pluginID: String, id: String, command: String, tools: Set<InkTool>) {
        self.app = app
        self.host = host
        self.pluginID = pluginID
        self.id = id
        self.command = command
        self.tools = tools
    }

    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool {
        guard let app = app, let doc = session.document, tools.contains(stroke.style.tool) else { return true }
        let chain = PluginStrokeRunner.chain(app.content.strokeProcessors.all, tool: stroke.style.tool)
        guard chain.first === self else { return true }
        let raw = stroke
        let budget = host?.strokeProcessorBudget ?? 0.05
        Task { @MainActor in
            guard let result = await PluginStrokeRunner.run(chain, stroke: raw, page: page, doc: doc, app: app,
                                                               session: session, budget: budget) else { return }
            await PluginStrokeRunner.commit(result, page: page, doc: doc, app: app, session: session)
        }
        return false
    }

    /// Plugin processors that apply to `tool`, in registry order.
    static func chain(_ entries: [StrokeProcessorEntry], tool: InkTool) -> [PluginStrokeRunner] {
        entries.compactMap { $0.processor as? PluginStrokeRunner }.filter { $0.tools.contains(tool) }
    }

    /// Runs the chain; nil = a processor dropped the stroke.
    static func run(_ chain: [PluginStrokeRunner], stroke: Stroke, page: PageID, doc: DocumentID, app: NibApp,
                    session: EditorSession, budget: TimeInterval) async -> Stroke? {
        var current = stroke
        for processor in chain {
            let params: JSONValue
            do {
                params = ["page": .string(NodeRef.page(doc, page).description), "stroke": try JSONValue.from(current)]
            } catch {
                continue
            }
            let command = processor.command
            let outcome = await Deadline.run(seconds: budget) {
                try await app.bus.execute(Invocation(command: command, params: params, principal: .user, session: session)).value
            }
            switch outcome {
            case .finished(.success(let value)):
                switch StrokeProcessorResult(value) {
                case .keep: break
                case .drop: return nil
                case .replace(let s): current = s
                }
            case .finished(.failure(let error)):
                hostLog.error("stroke processor \(processor.id, privacy: .public) failed, raw stroke kept: \(NibError.wrap(error).message, privacy: .public)")
            case .timedOut:
                hostLog.error("stroke processor \(processor.id, privacy: .public) took longer than \(Int(budget * 1000)) ms, raw stroke kept")
            }
        }
        return current
    }

    static func commit(_ stroke: Stroke, page: PageID, doc: DocumentID, app: NibApp, session: EditorSession) async {
        do {
            let params: JSONValue = ["page": .string(NodeRef.page(doc, page).description), "strokes": [try JSONValue.from(stroke)]]
            _ = try await app.bus.execute(Invocation(command: CommandIDs.inkAddStrokes, params: params, principal: .user,
                                                     session: session))
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": CommandIDs.inkAddStrokes, "error": NibError.wrap(error)])
        }
    }
}

/// What a stroke processor answered: {stroke} replaces, {drop: true} removes, anything else keeps the stroke.
enum StrokeProcessorResult: Equatable {
    case keep
    case drop
    case replace(Stroke)

    init(_ value: JSONValue) {
        if value["drop"]?.boolValue == true {
            self = .drop
        } else if let s = value["stroke"], s != .null, let stroke = try? s.decode(Stroke.self), !stroke.points.isEmpty {
            self = .replace(stroke)
        } else {
            self = .keep
        }
    }
}

/// Races an operation against a deadline (the operation keeps running after a timeout; its result is ignored).
enum Deadline {
    enum Outcome<T> {
        case finished(Result<T, Error>)
        case timedOut
    }

    @MainActor
    static func run<T>(seconds: TimeInterval, _ operation: @escaping @MainActor () async throws -> T) async -> Outcome<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
            let gate = OnceGate()
            Task { @MainActor in
                let result: Result<T, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                if gate.open() { continuation.resume(returning: .finished(result)) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.open() { continuation.resume(returning: .timedOut) }
            }
        }
    }
}

/// Lets exactly one of several racing finishers through (used from main-actor tasks only).
final class OnceGate {
    private var opened = false

    func open() -> Bool {
        guard !opened else { return false }
        opened = true
        return true
    }
}
