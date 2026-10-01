import UIKit
import os
import NibContracts

/// One route per touch, retained through its whole lifetime even when registries or the active tool change.
@MainActor
final class GestureRouter {
    enum Route {
        case attachment(CanvasAttachment)
        case tool(CanvasTool)
        case navigation
        case rejected
    }

    private weak var host: CanvasHost?
    var attachments: () -> [CanvasAttachment]
    var activeTool: () -> CanvasTool?
    var isReadOnly: () -> Bool
    var topmostItem: (CanvasSample) -> Item?
    private var routes: [Int: Route] = [:]
    private static let log = Logger(subsystem: "app.nib", category: "canvasinput")

    init(host: CanvasHost, attachments: @escaping () -> [CanvasAttachment],
         activeTool: @escaping () -> CanvasTool?, isReadOnly: @escaping () -> Bool,
         topmostItem: @escaping (CanvasSample) -> Item?) {
        self.host = host
        self.attachments = attachments
        self.activeTool = activeTool
        self.isReadOnly = isReadOnly
        self.topmostItem = topmostItem
    }

    /// Hit-testing uses the v2 input-kind overload. The caller caches this result before PencilKit sees the touch.
    func route(at point: CGPoint, isPencil: Bool, canDraw: Bool) -> Route {
        guard let host = host else { return .rejected }
        for attachment in attachments() where attachment.hitTest(point, isPencil: isPencil, host: host) {
            return .attachment(attachment)
        }
        guard !isReadOnly(), let tool = activeTool(), canDraw || tool.inputMode == .taps else { return .navigation }
        return .tool(tool)
    }

    func begin(_ sample: CanvasSample, route: Route) {
        guard let host = host else { return }
        routes[sample.touchID] = route
        switch route {
        case .attachment(let attachment): attachment.touchesBegan(sample, host: host)
        case .tool(let tool) where tool.inputMode == .samples: tool.touchesBegan(sample, host: host)
        default: break
        }
    }

    func move(_ samples: [CanvasSample]) {
        guard let host = host, let id = samples.first?.touchID else { return }
        switch routes[id] {
        case .attachment(let attachment): attachment.touchesMoved(samples, host: host)
        case .tool(let tool) where tool.inputMode == .samples: tool.touchesMoved(samples, host: host)
        default: break
        }
    }

    @discardableResult
    func end(_ sample: CanvasSample) -> Route? {
        let route = routes.removeValue(forKey: sample.touchID)
        guard let host = host else { return route }
        switch route {
        case .attachment(let attachment): attachment.touchesEnded(sample, host: host)
        case .tool(let tool) where tool.inputMode == .samples: tool.touchesEnded(sample, host: host)
        default: break
        }
        return route
    }

    func cancel(_ touchID: Int) {
        let route = routes.removeValue(forKey: touchID)
        guard let host = host else { return }
        switch route {
        case .attachment(let attachment): attachment.touchesCancelled(host: host)
        case .tool(let tool): tool.touchesCancelled(host: host)
        default: break
        }
    }

    func cancelAll() { for id in Array(routes.keys) { cancel(id) } }

    /// Attachments get first refusal even in read-only mode; only fingers enter the command tap chain.
    /// A touch that was claimed never becomes a canvas pan/zoom, even if its attachment passes on its tap.
    @discardableResult
    func gesture(_ gesture: CanvasGesture, sample: CanvasSample, route: Route? = nil) async -> Bool {
        guard let host = host else { return false }
        if case .rejected? = route { return true }
        let claimed: CanvasAttachment?
        if case .attachment(let attachment)? = route {
            claimed = attachment
        } else if route == nil {
            claimed = attachments().first { $0.hitTest(host.viewPoint(sample.location, page: sample.page),
                                                       isPencil: sample.isPencil, host: host) }
        } else {
            claimed = nil
        }
        if claimed?.gesture(gesture, at: sample, host: host) == true { return true }
        if !sample.isPencil {
            let item = topmostItem(sample)
            var params: [String: JSONValue] = ["page": .string(NodeRef.page(host.documentID, sample.page).description),
                                     "point": .array([.number(sample.location.x), .number(sample.location.y)]),
                                     "gesture": .string(gesture.rawValue)]
            if let item = item { params["ref"] = .string(NodeRef.item(host.documentID, sample.page, item.id).description) }
            for handler in host.app.content.tapHandlers.all {
                guard !Task.isCancelled else { return true }
                guard handler.gesture == gesture, !isReadOnly() || handler.worksInReadOnly else { continue }
                if let kinds = handler.itemKinds, !(item.map { kinds.contains($0.kind) } ?? false) { continue }
                if let keys = handler.drawKeys, !(item.map { keys.contains($0.drawKey) } ?? false) { continue }
                do {
                    let result = try await host.app.bus.execute(handler.command, .object(params), session: host.session)
                    if result["handled"]?.boolValue == true { return true }
                } catch {
                    Self.log.error("Tap handler \(handler.command, privacy: .public): \(NibError.wrap(error).description, privacy: .public)")
                }
            }
        }
        guard !Task.isCancelled else { return true }
        guard !isReadOnly(), let tool = activeTool() else { return claimed != nil }
        if gesture == .longPress { tool.longPress(sample, host: host) }
        else { tool.tap(sample, host: host) }
        return claimed != nil || tool.inputMode != .pencilKit
    }

    func hover(_ sample: CanvasSample?, isPencil: Bool = true) {
        guard let host = host else { return }
        for attachment in attachments() { attachment.hover(sample, host: host) }
        if !isReadOnly() { activeTool()?.hover(sample, host: host) }
        if isPencil { host.app.ui.pencilHandler?.pencilHover(sample, session: host.session, host: host) }
    }
}

// Contract requests owned by F101 (F010 deferred gaps): CanvasHost needs a render-matched partial-stroke preview
// API and an items-in-rect per-page spatial index. The shared protocol cannot be extended within F101's owned files;
// current tools can use PKBridge.drawing + their overlayLayer and Workspace.items as the contract permits.
