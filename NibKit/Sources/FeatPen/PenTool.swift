import UIKit
import NibContracts
import NibDesign

/// Solid ink stays on PencilKit. Patterned ink uses samples and an unanimated vector preview.
@MainActor
final class PenTool: CanvasTool {
    let id: String
    let pencil: Bool
    private let settings: SettingsStore
    var inputMode: CanvasInputMode { settings.get(NibSettings.presets(id)).pattern == .solid ? .pencilKit : .samples }
    private var pendingLoop: PendingLoop?
    private var samples: [StrokePoint] = []
    private var samplePage: PageID?
    private var sampleStyle: InkStyle?
    private var sampleStart: TimeInterval = 0
    private var preview: CAShapeLayer?
    private var holdTimer: Task<Void, Never>?
    private var holdReference: Point?
    private struct Press {
        let page: PageID
        let location: Point
        let at: TimeInterval
        let isPencil: Bool
    }
    private var consumedPress: Press?
    private var hold: Hold?

    private final class Hold {
        let page: PageID
        var stroke: Stroke
        let grab: Point
        var current: Point
        var result: PenShapeResult?
        var recognition: Task<Void, Never>?
        var lastTimestamp: TimeInterval?
        init(stroke: Stroke, page: PageID) {
            self.stroke = stroke; self.page = page
            grab = stroke.points.last?.location ?? .zero
            current = grab
        }
    }

    init(pencil: Bool, settings: SettingsStore) {
        self.pencil = pencil; self.settings = settings
        id = pencil ? "pencil" : "pen"
    }

    func inkStyle(_ host: CanvasHost) -> InkStyle? { PenSettings.ink(settings, pencil: pencil) }
    func deactivate(_ host: CanvasHost) { touchesCancelled(host: host); pendingLoop = nil }

    func strokeFinished(_ stroke: Stroke, page: PageID, host: CanvasHost) {
        if let press = consumedPress {
            consumedPress = nil
            let elapsed = ProcessInfo.processInfo.systemUptime - press.at
            if press.page == page, press.isPencil || settings.get(NibSettings.stylusMode) == .anyInput,
               elapsed >= 0, elapsed <= 1.5,
               LoopDetector.isDot(stroke.polyline, scale: host.zoomScale),
               let location = stroke.points.first?.location,
               location.distance(to: press.location) * host.zoomScale <= 16 {
                host.cancelWetStroke()
                return
            }
        }
        guard hold == nil else { return }
        pendingLoop = nil
        let outline = PenGeometry.thinned(stroke.polyline, limit: NibLimits.maxErasePathPoints)
        let app = host.app, session = host.session, doc = host.documentID
        if settings.get(PenSettings.scribbleErase), ScribbleDetector.isScribble(outline, scale: host.zoomScale) {
            host.cancelWetStroke()
            Task { @MainActor [weak host] in
                do {
                    let result = try await app.bus.execute(CommandIDs.inkScribbleErase,
                        ["page": .string(NodeRef.page(doc, page).description), "points": try JSONValue.from(outline)], session: session)
                    guard let removed = result["removed"]?.doubleValue else {
                        throw NibError.invalid("scribble erase must return a removed count")
                    }
                    if removed == 0 { host?.commitStroke(stroke, page: page) }
                } catch {
                    Self.report(error, command: CommandIDs.inkScribbleErase, app: app)
                    host?.commitStroke(stroke, page: page)
                }
            }
            return
        }
        if settings.get(PenSettings.circleLasso), LoopDetector.isClosedLoop(outline, scale: host.zoomScale) {
            let id = NibID.make(), group = NibID.make().raw
            var processed = stroke
            for entry in app.content.strokeProcessors.all {
                guard entry.processor.process(&processed, page: page, session: session) else { host.cancelWetStroke(); return }
            }
            let saved = processed
            host.cancelWetStroke()
            drawStroke(saved, page: page, host: host)
            let layer = preview; preview = nil
            let committed = Task { @MainActor [weak host] () -> Bool in
                do {
                    _ = try await app.bus.execute(Invocation(command: CommandIDs.inkAddStrokes,
                        params: ["page": .string(NodeRef.page(doc, page).description),
                                 "strokes": .array([try JSONValue.from(saved)]), "ids": .array([.string(id.raw)])],
                        session: session, group: group))
                    if let host { host.afterNextRender(page: page) { layer?.removeFromSuperlayer() } }
                    else { layer?.removeFromSuperlayer() }
                    return true
                } catch {
                    Self.report(error, command: CommandIDs.inkAddStrokes, app: app)
                    layer?.removeFromSuperlayer()
                    return false
                }
            }
            pendingLoop = PendingLoop(id: id, page: page, outline: outline, finishedAt: ProcessInfo.processInfo.systemUptime,
                                      group: group, committed: committed)
            return
        }
        host.commitStroke(stroke, page: page)
    }

    private func selectLoop(at sample: CanvasSample, host: CanvasHost) -> Bool {
        guard settings.get(PenSettings.circleLasso), let loop = pendingLoop, loop.page == sample.page,
              loop.accepts(sample.location, at: ProcessInfo.processInfo.systemUptime, scale: host.zoomScale) else { return false }
        pendingLoop = nil
        let app = host.app, session = host.session, doc = host.documentID
        Task { @MainActor in
            guard await loop.committed.value else { return }
            do {
                _ = try await app.bus.execute(Invocation(command: CommandIDs.selectionFromLoop,
                    params: ["page": .string(NodeRef.page(doc, loop.page).description),
                             "stroke": .string(NodeRef.item(doc, loop.page, loop.id).description)], session: session, group: loop.group))
            } catch { Self.report(error, command: CommandIDs.selectionFromLoop, app: app) }
        }
        return true
    }

    func longPress(_ sample: CanvasSample, host: CanvasHost) {
        if selectLoop(at: sample, host: host) { recordPress(sample); clearPreview() }
    }

    private func recordPress(_ sample: CanvasSample) {
        consumedPress = Press(page: sample.page, location: sample.location,
                              at: ProcessInfo.processInfo.systemUptime, isPencil: sample.isPencil)
    }

    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool {
        if LoopDetector.isDot(stroke.polyline, scale: host.zoomScale), let point = stroke.points.last?.location,
           selectLoop(at: CanvasSample(page: page, location: point), host: host) {
            recordPress(CanvasSample(page: page, location: point, isPencil: true)); return true
        }
        guard hold == nil, settings.get(NibSettings.drawAndHold), stroke.points.count >= 2,
              !LoopDetector.isDot(stroke.polyline, scale: host.zoomScale),
              host.app.commands.entry(CommandIDs.shapeRecognize) != nil else { return false }
        // Transfer the touch to samples while the read command runs. A no-match retains the original ink.
        let state = Hold(stroke: stroke, page: page)
        hold = state
        drawStroke(stroke, page: page, host: host)
        let app = host.app, session = host.session, doc = host.documentID
        state.recognition = Task { @MainActor [weak self, weak host, weak state] in
            guard let state else { return }
            do {
                let json = try await app.bus.execute(CommandIDs.shapeRecognize,
                    ["points": try JSONValue.from(PenGeometry.thinned(stroke.polyline, limit: 50_000)),
                     "neighbors": .string(NodeRef.page(doc, page).description)], session: session)
                guard !Task.isCancelled else { return }
                state.result = try PenShapeResult.parse(json, ink: stroke.style, doc: doc, page: page)
                if let result = state.result {
                    if let self, let host, self.hold === state {
                        self.drawShape(result.shape, grab: state.grab, at: state.current, page: page, host: host)
                    }
                    app.events.emit(ShapeSnappedPayload(page: NodeRef.page(doc, page).description,
                        shape: result.shape.shape.rawValue, point: state.current, session: session.id.raw), doc: doc)
                    UIAccessibility.post(notification: .announcement, argument: String(localized: "Snapped to shape"))
                }
            } catch {
                if !Task.isCancelled { Self.report(error, command: CommandIDs.shapeRecognize, app: app) }
            }
        }
        return true
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        consumedPress = nil
        guard inputMode == .samples, !sample.isPredicted else { return }
        samplePage = sample.page; sampleStyle = inkStyle(host); sampleStart = sample.timestamp
        samples = [point(sample, location: sample.location)]
        scheduleHold(host); drawSamples(host: host)
    }

    func touchesMoved(_ incoming: [CanvasSample], host: CanvasHost) {
        if let state = hold {
            for sample in incoming where !sample.isPredicted {
                guard let p = host.convert(sample.location, from: sample.page, to: state.page) else { continue }
                state.current = p
                if state.result == nil { appendFallback(sample, point: p, state: state) }
            }
            if let result = state.result {
                drawShape(result.shape, grab: state.grab, at: state.current, page: state.page, host: host)
            } else { drawStroke(state.stroke, page: state.page, host: host) }
            return
        }
        guard consumedPress == nil, let page = samplePage else { return }
        var moved = false
        for sample in incoming where !sample.isPredicted {
            guard let p = host.convert(sample.location, from: sample.page, to: page) else { continue }
            if let reference = holdReference, reference.distance(to: p) * host.zoomScale > 2 { moved = true }
            samples.append(point(sample, location: p))
        }
        if moved { scheduleHold(host) }
        let predicted = settings.get(NibSettings.reduceLatency) ? incoming.filter(\.isPredicted).compactMap { sample in
            host.convert(sample.location, from: sample.page, to: page).map { point(sample, location: $0) }
        } : []
        drawSamples(predicted: predicted, host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        holdTimer?.cancel(); holdTimer = nil
        if let press = consumedPress {
            consumedPress = nil
            let elapsed = ProcessInfo.processInfo.systemUptime - press.at
            if press.page == sample.page, press.isPencil == sample.isPencil,
               elapsed >= 0, elapsed <= 1.5,
               press.location.distance(to: sample.location) * host.zoomScale <= 16,
               LoopDetector.isDot(samples.map(\.location) + [sample.location], scale: host.zoomScale) {
                resetSamples(); clearPreview(); host.cancelWetStroke(); return
            }
        }
        if let state = hold {
            if let p = host.convert(sample.location, from: sample.page, to: state.page) {
                state.current = p
                if state.result == nil, state.stroke.points.last?.location != p { appendFallback(sample, point: p, state: state) }
            }
            hold = nil
            let layer = preview; preview = nil
            let app = host.app, session = host.session, doc = host.documentID
            Task { @MainActor [weak host] in
                await state.recognition?.value
                if let result = state.result {
                    let shape = PenShapeAdjustment.adjust(result.shape, grab: state.grab, current: state.current)
                    do {
                        let group = NibID.make().raw
                        // Create first so a failed creation preserves both the stroke and every neighbour.
                        let created = try await app.bus.execute(Invocation(command: CommandIDs.shapeCreate,
                            params: try PenShapeResult.createParams(shape, doc: doc, page: state.page), session: session, group: group))
                        if !result.mergeWith.isEmpty {
                            do {
                                _ = try await app.bus.execute(Invocation(command: CommandIDs.itemDelete,
                                    params: ["refs": .array(result.mergeWith.map(JSONValue.string))], session: session, group: group))
                            } catch {
                                Self.report(error, command: CommandIDs.itemDelete, app: app)
                                if app.bus.history.entries(doc).last?.group == group {
                                    _ = try await app.bus.execute(CommandIDs.undo,
                                        ["doc": .string(NodeRef.document(doc).description)], session: session)
                                } else if let ref = created.value["ref"]?.stringValue {
                                    _ = try await app.bus.execute(CommandIDs.itemDelete,
                                        ["refs": .array([.string(ref)])], session: session)
                                }
                                await Self.preserve(state.stroke, page: state.page, doc: doc, app: app, session: session, host: host)
                            }
                        }
                    } catch {
                        Self.report(error, command: CommandIDs.shapeCreate, app: app)
                        await Self.preserve(state.stroke, page: state.page, doc: doc, app: app, session: session, host: host)
                    }
                } else { await Self.preserve(state.stroke, page: state.page, doc: doc, app: app, session: session, host: host) }
                if let host { host.afterNextRender(page: state.page) { layer?.removeFromSuperlayer() } }
                else { layer?.removeFromSuperlayer() }
            }
            resetSamples(); return
        }
        guard let page = samplePage, let style = sampleStyle else { return }
        if let p = host.convert(sample.location, from: sample.page, to: page) { samples.append(point(sample, location: p)) }
        let stroke = Stroke(style: style, points: samples, t0: Date().timeIntervalSince1970 - max(0, sample.timestamp - sampleStart))
        resetSamples()
        let layer = preview; preview = nil
        strokeFinished(stroke, page: page, host: host)
        host.afterNextRender(page: page) { layer?.removeFromSuperlayer() }
    }

    func touchesCancelled(host: CanvasHost) {
        holdTimer?.cancel(); holdTimer = nil
        if let state = hold {
            state.recognition?.cancel(); hold = nil
            host.commitStroke(state.stroke, page: state.page)
        }
        resetSamples(); consumedPress = nil; clearPreview()
    }

    private func point(_ sample: CanvasSample, location: Point) -> StrokePoint {
        StrokePoint(x: Float(location.x), y: Float(location.y), t: Float(max(0, sample.timestamp - sampleStart)),
                    force: Float(sample.force), azimuth: Float(sample.azimuth), altitude: Float(sample.altitude),
                    roll: Float(settings.get(NibSettings.penReactsToRoll) ? sample.roll : 0))
    }

    private func scheduleHold(_ host: CanvasHost) {
        holdTimer?.cancel()
        holdReference = samples.last?.location
        holdTimer = Task { @MainActor [weak self, weak host] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, let host, let page = self.samplePage, let style = self.sampleStyle else { return }
            _ = self.strokeHeld(Stroke(style: style, points: self.samples), page: page, host: host)
        }
    }

    private func resetSamples() { samples = []; samplePage = nil; sampleStyle = nil; holdReference = nil }
    private func clearPreview() { preview?.removeFromSuperlayer(); preview = nil }
    private func drawSamples(predicted: [StrokePoint] = [], host: CanvasHost) {
        guard let page = samplePage, let style = sampleStyle else { return }
        drawStroke(Stroke(style: style, points: samples + predicted), page: page, host: host)
    }
    private func drawStroke(_ stroke: Stroke, page: PageID, host: CanvasHost) {
        let path = CGMutablePath(), points = stroke.polyline.map { host.viewPoint($0, page: page) }
        if let first = points.first {
            path.move(to: first)
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            else { path.addLines(between: points) }
        }
        draw(path, style: stroke.style, host: host)
    }
    private func drawShape(_ shape: ShapeItem, grab: Point, at current: Point, page: PageID, host: CanvasHost) {
        let s = PenShapeAdjustment.adjust(shape, grab: grab, current: current), path = PenShapeResult.path(s)
        var transform = host.pageTransform(page) ?? .identity
        draw(path.copy(using: &transform) ?? path,
             style: InkStyle(color: s.style.strokeColor ?? .black, width: s.style.strokeWidth, pattern: s.style.pattern), host: host)
    }
    private func draw(_ path: CGPath, style: InkStyle, host: CanvasHost) {
        let layer = preview ?? CAShapeLayer()
        if preview == nil { host.overlayLayer.addSublayer(layer); preview = layer }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.path = path; layer.fillColor = nil; layer.strokeColor = style.color.cgColor
        layer.lineWidth = style.width * host.zoomScale; layer.lineCap = .round; layer.lineJoin = .round
        switch style.pattern {
        case .solid: layer.lineDashPattern = nil
        case .dashed:
            layer.lineCap = .butt
            layer.lineDashPattern = [NSNumber(value: max(3 * style.width, 3) * host.zoomScale),
                                     NSNumber(value: max(2 * style.width, 2.5) * host.zoomScale)]
        case .dotted:
            layer.lineDashPattern = [NSNumber(value: 0.01 * host.zoomScale),
                                     NSNumber(value: max(2.5 * style.width, 2.5) * host.zoomScale)]
        }
        CATransaction.commit()
    }
    private static func report(_ error: Error, command: String, app: NibApp) {
        NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                       userInfo: ["command": command, "error": NibError.wrap(error)])
    }

    private func appendFallback(_ sample: CanvasSample, point p: Point, state: Hold) {
        // Recognition can take longer than a frame; unmatched strokes retain their real continuation samples.
        let last = state.stroke.points.last
        var fallback = point(sample, location: p)
        fallback.t = (last?.t ?? 0) + Float(max(0, sample.timestamp - (state.lastTimestamp ?? sample.timestamp)))
        var segment = [fallback]
        InkModel.fillSizes(&segment, style: state.stroke.style)
        state.lastTimestamp = sample.timestamp
        state.stroke.points.append(segment[0])
    }

    private static func preserve(_ stroke: Stroke, page: PageID, doc: DocumentID, app: NibApp,
                                 session: EditorSession, host: CanvasHost?) async {
        if let host { host.commitStroke(stroke, page: page); return }
        var processed = stroke
        for entry in app.content.strokeProcessors.all {
            guard entry.processor.process(&processed, page: page, session: session) else { return }
        }
        do {
            _ = try await app.bus.execute(CommandIDs.inkAddStrokes,
                ["page": .string(NodeRef.page(doc, page).description), "strokes": .array([try JSONValue.from(processed)])], session: session)
        } catch { report(error, command: CommandIDs.inkAddStrokes, app: app) }
    }
}

struct PenShapeResult {
    var shape: ShapeItem
    var mergeWith: [String]
    var confidence: Double?

    static func parse(_ json: JSONValue, ink: InkStyle, doc: DocumentID, page: PageID) throws -> PenShapeResult? {
        // v2 wraps ShapeItem; F030's first build returned a flat ShapeItem with a kind string in `shape`.
        if json == .null || json["shape"] == .null { return nil }
        let value = json["shape"]?.objectValue != nil ? json["shape"]! : json
        var shape = try value.decode(ShapeItem.self)
        let confidence = json["confidence"]?.doubleValue
        if let confidence, !confidence.isFinite || !(0...1).contains(confidence) {
            throw NibError.invalid("shape confidence must be between 0 and 1", path: "$.confidence")
        }
        shape.style = ShapeItemStyle(strokeColor: ink.color, strokeWidth: ink.width, fillColor: nil, cornerRadius: 0,
                                    pattern: ink.pattern, drawnWith: ink.tool, arrowEnd: shape.style.arrowEnd)
        let refs = (json["mergeWith"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard refs.allSatisfy({ ref in
            if case let .item(d, p, _)? = NodeRef(ref) { return d == doc && p == page }
            return false
        }) else { throw NibError.invalid("merged shapes must be item refs on the drawing page", path: "$.mergeWith") }
        return PenShapeResult(shape: shape, mergeWith: Array(Set(refs)).sorted(), confidence: confidence)
    }

    static func createParams(_ shape: ShapeItem, doc: DocumentID, page: PageID) throws -> JSONValue {
        var params: [String: JSONValue] = ["page": .string(NodeRef.page(doc, page).description),
                                 "shape": .string(shape.shape.rawValue), "style": try JSONValue.from(shape.style)]
        if shape.points.isEmpty { params["frame"] = .array(shape.frame.array.map(JSONValue.number)) }
        else { params["points"] = try JSONValue.from(shape.points) }
        return .object(params)
    }

    static func path(_ shape: ShapeItem) -> CGPath {
        let p = CGMutablePath()
        if !shape.points.isEmpty {
            let points = shape.points.map(\.cg)
            p.move(to: points[0])
            if shape.shape == .arc || shape.shape == .curve {
                if points.count == 3 { p.addQuadCurve(to: points[2], control: points[1]) }
                else if points.count == 4 { p.addCurve(to: points[3], control1: points[1], control2: points[2]) }
                else { p.addLines(between: points) }
            } else { p.addLines(between: points) }
            if [.polygon, .triangle, .diamond].contains(shape.shape) { p.closeSubpath() }
        } else {
            let f = shape.frame, rect = CGRect(x: shape.frame.x, y: shape.frame.y, width: shape.frame.w, height: shape.frame.h)
            if shape.shape == .ellipse { p.addEllipse(in: rect) }
            else { p.addRect(rect) }
            var rotation = CGAffineTransform(translationX: f.center.x, y: f.center.y)
                .rotated(by: f.rotation).translatedBy(x: -f.center.x, y: -f.center.y)
            return p.copy(using: &rotation) ?? p
        }
        return p
    }
}

enum PenShapeAdjustment {
    static func adjust(_ shape: ShapeItem, grab: Point, current: Point) -> ShapeItem {
        let open = [.line, .arrow, .arc, .curve, .polyline].contains(shape.shape)
        let anchor = open ? shape.points.first ?? shape.frame.center : shape.frame.center
        let a = grab - anchor, b = current - anchor
        let initial = hypot(a.x, a.y), distance = hypot(b.x, b.y)
        guard initial > 1, distance > 0.5 else { return shape }
        let scale = min(max(distance / initial, 0.05), 20), angle = atan2(b.y, b.x) - atan2(a.y, a.x)
        let transform = Affine.scale(scale, scale, about: anchor).concatenating(Affine.rotation(angle, about: anchor))
        var out = shape
        out.frame = shape.frame.applying(transform); out.points = shape.points.map { transform.apply($0) }
        return out
    }
}
