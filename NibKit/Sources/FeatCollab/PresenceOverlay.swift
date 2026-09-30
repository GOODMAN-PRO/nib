import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - Wire format

/// One F108 presence payload, sent through `CollabHooks.sendPresence` (the host relays it to everyone). Page refs on
/// the wire use the HOST's document id (`CollabHooks.remotePageRef` / `localPageRef`). A payload of an unknown kind
/// (a newer Nib) decodes to nil and is ignored.
enum PresenceMessage: Equatable {
    /// Where someone points or writes; nil = the pointer left the page.
    case cursor(page: String, point: Point?)
    /// The part of a page someone looks at (page points) and their zoom.
    case viewport(page: String, rect: Rect?, zoom: Double?)
    /// Someone's lasso selection: its outline, or its bounds when it has none; nil page = the selection was cleared.
    case lasso(page: String?, outline: [Point]?, bounds: Rect?)
    /// Someone's laser pointer (`laser.moved`, contracts-v2 G3): nil point = lifted.
    case laser(page: String, point: Point?, mode: String, color: RGBA?)
    /// Follow Me (S-113): everyone follows the sender (on) or stops following them (off).
    case followMe(on: Bool)
    /// The sender just went live (joined, or re-joined after a suspend): everyone answers with their own state.
    case hello

    static let version = 1
    /// Lasso outlines travel with at most this many points.
    static let maxOutlinePoints = 256

    /// The throttle key: one pending message per kind.
    var kind: String {
        switch self {
        case .cursor: return "cursor"
        case .viewport: return "view"
        case .lasso: return "lasso"
        case .laser: return "laser"
        case .followMe: return "followMe"
        case .hello: return "hello"
        }
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["t": .string(kind), "v": .number(Double(PresenceMessage.version))]
        switch self {
        case let .cursor(page, point):
            o["page"] = .string(page)
            if let p = point { o["at"] = PresenceMessage.encode(p) }
        case let .viewport(page, rect, zoom):
            o["page"] = .string(page)
            if let r = rect { o["rect"] = PresenceMessage.encode(r) }
            if let z = zoom { o["zoom"] = .number(z) }
        case let .lasso(page, outline, bounds):
            if let page = page { o["page"] = .string(page) }
            if let outline = outline { o["outline"] = .array(outline.map { PresenceMessage.encode($0) }) }
            if let b = bounds { o["rect"] = PresenceMessage.encode(b) }
        case let .laser(page, point, mode, color):
            o["page"] = .string(page)
            o["mode"] = .string(mode)
            if let p = point { o["at"] = PresenceMessage.encode(p) }
            if let c = color, let value = try? JSONValue.from(c) { o["color"] = value }
        case .followMe(let on):
            o["on"] = .bool(on)
        case .hello:
            break
        }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let kind = json["t"]?.stringValue else { return nil }
        let page = json["page"]?.stringValue
        switch kind {
        case "cursor":
            guard let page = page else { return nil }
            self = .cursor(page: page, point: json["at"].flatMap(PresenceMessage.point))
        case "view":
            guard let page = page else { return nil }
            let zoom = json["zoom"]?.doubleValue.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self = .viewport(page: page, rect: json["rect"].flatMap(PresenceMessage.rect), zoom: zoom)
        case "lasso":
            let outline = (json["outline"]?.arrayValue?.compactMap(PresenceMessage.point))
                .map { PresenceMessage.downsample($0) }
            let bounds = json["rect"].flatMap(PresenceMessage.rect)
            guard let page = page, (outline?.count ?? 0) >= 3 || bounds != nil else {
                self = .lasso(page: nil, outline: nil, bounds: nil)
                return
            }
            self = .lasso(page: page, outline: (outline?.count ?? 0) >= 3 ? outline : nil, bounds: bounds)
        case "laser":
            guard let page = page else { return nil }
            let color = json["color"].flatMap { try? $0.decode(RGBA.self) }
            self = .laser(page: page, point: json["at"].flatMap(PresenceMessage.point),
                          mode: json["mode"]?.stringValue ?? "dot", color: color)
        case "followMe":
            guard let on = json["on"]?.boolValue else { return nil }
            self = .followMe(on: on)
        case "hello":
            self = .hello
        default:
            return nil
        }
    }

    static func encode(_ p: Point) -> JSONValue { .array([.number(p.x), .number(p.y)]) }

    static func encode(_ r: Rect) -> JSONValue {
        .array([.number(r.x), .number(r.y), .number(r.width), .number(r.height)])
    }

    static func point(_ v: JSONValue) -> Point? {
        guard let a = v.arrayValue, a.count == 2, let x = a[0].doubleValue, let y = a[1].doubleValue,
              x.isFinite, y.isFinite else { return nil }
        return Point(x, y)
    }

    static func rect(_ v: JSONValue) -> Rect? {
        guard let a = v.arrayValue, a.count == 4 else { return nil }
        let n = a.compactMap { $0.doubleValue }
        guard n.count == 4, n.allSatisfy({ $0.isFinite }), n[2] >= 0, n[3] >= 0 else { return nil }
        return Rect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// Thins a long outline to `maxOutlinePoints`, keeping its first and last points.
    static func downsample(_ points: [Point], limit: Int = maxOutlinePoints) -> [Point] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[min(points.count - 1, Int((Double($0) * step).rounded()))] }
    }
}

// MARK: - Collaborators' presence (pure state)

/// What every other participant shows on the page, in this library's page ids. A value type, so the rules (expiry,
/// laser trails, clearing) are unit-tested without a canvas.
struct PresenceState: Equatable {
    struct Cursor: Equatable {
        var page: PageID
        var point: Point
        var at: TimeInterval
    }

    struct Viewport: Equatable {
        var page: PageID
        var rect: Rect?
        var zoom: Double?
        var at: TimeInterval
    }

    struct Lasso: Equatable {
        var page: PageID
        var outline: [Point]?
        var bounds: Rect?
    }

    struct Laser: Equatable {
        var page: PageID
        /// Recent positions, oldest first, with when each arrived.
        var points: [Point]
        var times: [TimeInterval]
        var mode: String
        var color: RGBA?
        var at: TimeInterval

        var isTrail: Bool { mode == "trail" }
    }

    struct Person: Equatable {
        var cursor: Cursor?
        var viewport: Viewport?
        var lasso: Lasso?
        var laser: Laser?

        var isEmpty: Bool { cursor == nil && viewport == nil && lasso == nil && laser == nil }
    }

    private(set) var people: [String: Person] = [:]

    /// Applies one message from `pid`. `localPage` maps a wire page ref to this library's page (nil = a page outside
    /// the shared document, which is ignored). Returns whether anything visible changed.
    @discardableResult
    mutating func apply(_ message: PresenceMessage, from pid: String, now: TimeInterval, trail: TimeInterval,
                        localPage: (String) -> PageID?) -> Bool {
        var person = people[pid] ?? Person()
        let before = person
        switch message {
        case let .cursor(ref, point):
            if let point = point, let page = localPage(ref) {
                person.cursor = Cursor(page: page, point: point, at: now)
            } else {
                person.cursor = nil
            }
        case let .viewport(ref, rect, zoom):
            guard let page = localPage(ref) else { return false }
            person.viewport = Viewport(page: page, rect: rect, zoom: zoom, at: now)
        case let .lasso(ref, outline, bounds):
            if let ref = ref, let page = localPage(ref), outline != nil || bounds != nil {
                person.lasso = Lasso(page: page, outline: outline, bounds: bounds)
            } else {
                person.lasso = nil
            }
        case let .laser(ref, point, mode, color):
            guard let page = localPage(ref) else { return false }
            guard let point = point else {
                person.laser = nil
                break
            }
            var laser = person.laser.flatMap { $0.page == page && $0.mode == mode ? $0 : nil }
                ?? Laser(page: page, points: [], times: [], mode: mode, color: color, at: now)
            laser.color = color
            laser.at = now
            if laser.isTrail {
                laser.points.append(point)
                laser.times.append(now)
                PresenceState.trim(&laser, now: now, trail: trail)
            } else {
                laser.points = [point]
                laser.times = [now]
            }
            person.laser = laser
        case .followMe, .hello:
            return false
        }
        people[pid] = person.isEmpty ? nil : person
        return person != before
    }

    mutating func remove(_ pid: String) { people[pid] = nil }

    /// Keeps only these participants (the others left or dropped out).
    mutating func retain(_ ids: Set<String>) { people = people.filter { ids.contains($0.key) } }

    mutating func reset() { people = [:] }

    /// A cursor that moved within `ttl`.
    func cursor(of pid: String, now: TimeInterval, ttl: TimeInterval) -> Cursor? {
        guard let c = people[pid]?.cursor, now - c.at <= ttl else { return nil }
        return c
    }

    /// A laser that moved within `ttl`, with its trail cut to the last `trail` seconds.
    func laser(of pid: String, now: TimeInterval, ttl: TimeInterval, trail: TimeInterval) -> Laser? {
        guard var l = people[pid]?.laser, now - l.at <= ttl else { return nil }
        if l.isTrail { PresenceState.trim(&l, now: now, trail: trail) }
        return l.points.isEmpty ? nil : l
    }

    /// When the next cursor or laser disappears (one redraw then, instead of a timer that never stops).
    func nextExpiry(now: TimeInterval, cursorTTL: TimeInterval, laserTTL: TimeInterval) -> TimeInterval? {
        var next: TimeInterval?
        for person in people.values {
            if let c = person.cursor, c.at + cursorTTL > now { next = min(next ?? .infinity, c.at + cursorTTL) }
            if let l = person.laser, l.at + laserTTL > now { next = min(next ?? .infinity, l.at + laserTTL) }
        }
        return next
    }

    private static func trim(_ laser: inout Laser, now: TimeInterval, trail: TimeInterval) {
        // Keep the newest point always; drop the ones older than the trail.
        while laser.times.count > 1, let first = laser.times.first, now - first > trail {
            laser.times.removeFirst()
            laser.points.removeFirst()
        }
    }
}

// MARK: - Sending

/// Sends this device's presence: at most one message per kind per interval, the latest one winning; a message equal
/// to the last one sent is dropped.
@MainActor
final class PresenceBroadcaster {
    typealias Sender = @MainActor (JSONValue, String?) -> Bool

    private let send: Sender
    private let clock: () -> TimeInterval
    private var lastAt: [String: TimeInterval] = [:]
    private var lastSent: [String: JSONValue] = [:]
    private var pending: [String: JSONValue] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    init(send: @escaping Sender, clock: @escaping () -> TimeInterval) {
        self.send = send
        self.clock = clock
    }

    /// Queues `message` for everyone. Returns false when it was dropped as unchanged or could not be sent.
    @discardableResult
    func post(_ message: PresenceMessage, interval: TimeInterval) -> Bool {
        let key = message.kind
        let json = message.json
        if pending[key] == nil, lastSent[key] == json { return false }
        let wait = (lastAt[key].map { $0 + interval } ?? -Double.infinity) - clock()
        if wait <= 0 {
            timers[key]?.cancel()
            timers[key] = nil
            pending[key] = nil
            return transmit(key, json)
        }
        pending[key] = json
        guard timers[key] == nil else { return true }
        timers[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.timers[key] = nil
            if let json = self.pending.removeValue(forKey: key) { _ = self.transmit(key, json) }
        }
        return true
    }

    /// Sends now, to one participant (a newcomer's catch-up) or everyone, outside the throttle.
    @discardableResult
    func sendNow(_ message: PresenceMessage, to pid: String?) -> Bool {
        let json = message.json
        guard send(json, pid) else { return false }
        if pid == nil {
            lastAt[message.kind] = clock()
            lastSent[message.kind] = json
        }
        return true
    }

    func reset() {
        for t in timers.values { t.cancel() }
        timers = [:]
        pending = [:]
        lastAt = [:]
        lastSent = [:]
    }

    private func transmit(_ key: String, _ json: JSONValue) -> Bool {
        guard send(json, nil) else { return false }
        lastAt[key] = clock()
        lastSent[key] = json
        return true
    }
}

/// Where the Pencil tip is while writing, from the stroke's growing bounds (the inking signal carries bounds only):
/// the edge that just moved is where the tip is; an edge that did not move keeps the last estimate.
enum InkTip {
    static func estimate(previous: CGRect?, current: CGRect, lastTip: CGPoint?) -> CGPoint {
        guard let p = previous, let t = lastTip else { return CGPoint(x: current.midX, y: current.midY) }
        var x = min(max(t.x, current.minX), current.maxX)
        var y = min(max(t.y, current.minY), current.maxY)
        if current.maxX > p.maxX {
            x = current.maxX
        } else if current.minX < p.minX {
            x = current.minX
        }
        if current.maxY > p.maxY {
            y = current.maxY
        } else if current.minY < p.minY {
            y = current.minY
        }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Canvas attachment ("collab.presence")

/// Draws collaborators on the canvas of the live document: their viewports (a thin outline in their colour), lasso
/// outlines (the dashed marquee in their colour), lasers (dot, glow and trail) and live cursors (a 10 pt bead with a
/// name capsule, DESIGN.md §14.14), plus the 6 pt unseen-change dot on pages others changed. Never takes a touch;
/// reports hover and the Pencil's position so the others see this device's cursor. Everything recedes to 22 % while
/// the Pencil is down here, and nothing moves under it.
@MainActor
final class PresenceAttachment: CanvasAttachment {
    private weak var hub: PresenceHub?
    private weak var host: CanvasHost?
    private let canvas = PresenceCanvasView()
    private let viewports = CALayer()
    private let lassos = CALayer()
    private let lasers = CALayer()
    private let dots = CALayer()
    private var shapes: [String: CAShapeLayer] = [:]
    private var dotLayers: [PageID: CAShapeLayer] = [:]
    private var cursors: [String: PresenceCursorView] = [:]
    private var inking: EventSubscription?
    private var lastStroke: CGRect?
    private var lastTip: CGPoint?
    private var expiry: Task<Void, Never>?
    private var expiryAt: TimeInterval?
    /// Something changed while the Pencil was down here: drawn when it lifts (nothing moves under the Pencil).
    private var pendingRender = false

    init(hub: PresenceHub, host: CanvasHost) {
        self.hub = hub
        self.host = host
        for group in [viewports, lassos, lasers, dots] { canvas.layer.addSublayer(group) }
    }

    func attach(to host: CanvasHost) {
        self.host = host
        canvas.frame = .zero
        host.canvasView.addSubview(canvas)
        hub?.attachmentAttached(self)
        inking = host.session.inking.observe { [weak self] signal in self?.inkingChanged(signal) }
        render(animated: false)
    }

    func detach(from host: CanvasHost) {
        inking?.cancel()
        inking = nil
        expiry?.cancel()
        expiry = nil
        canvas.removeFromSuperview()
        hub?.attachmentDetached(self)
    }

    /// What is drawn now (tests): participants with a cursor, shape layers ("view.", "lasso.", "laserDot." … + id),
    /// pages with an unseen-change dot.
    var drawnCursors: Set<String> { Set(cursors.keys) }
    var drawnShapes: Set<String> { Set(shapes.keys) }
    var drawnDots: Set<PageID> { Set(dotLayers.keys) }
    var isReceded: Bool { canvas.alpha < 1 }

    func canvasDidChange(_ host: CanvasHost) {
        if host.canvasView.subviews.last !== canvas { host.canvasView.bringSubviewToFront(canvas) }
        render(animated: false)
        hub?.canvasChanged(host)
    }

    func hover(_ sample: CanvasSample?, host: CanvasHost) {
        hub?.localHover(sample, host: host)
    }

    // MARK: Pencil down

    private func inkingChanged(_ signal: InkingSignal) {
        canvas.alpha = signal.isInking ? CGFloat(NibOpacity.recede) : 1
        guard let host = host else { return }
        guard signal.isInking, let bounds = signal.strokeBounds else {
            lastStroke = nil
            lastTip = nil
            if !signal.isInking, pendingRender { render(animated: false) }
            return
        }
        let rect = host.canvasView.convert(bounds, from: nil)
        let tip = InkTip.estimate(previous: lastStroke, current: rect, lastTip: lastTip)
        lastStroke = rect
        lastTip = tip
        hub?.localInk(at: tip, host: host)
    }

    // MARK: Drawing

    func render(animated: Bool) {
        guard let host = host, let hub = hub else { return }
        guard !host.session.inking.isInking else {
            pendingRender = true
            return
        }
        pendingRender = false
        // Layers change without implicit animations; cursor moves run after the transaction (a UIKit animation inside
        // a transaction that disables actions would not run).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let now = hub.now()
        let timing = hub.timing
        let showsPeople = hub.showsCursors
        var keepShapes = Set<String>()
        var keepCursors = Set<String>()
        var moves: [(view: PresenceCursorView, point: CGPoint)] = []
        let glides = animated && !hub.environment.reduceMotion

        if showsPeople {
            for (p, person) in hub.people(on: host.documentID) {
                let color = UIColor(cgColor: NibPalette.cgColor(NibPresenceColour.hex(p.colorIndex)))
                if let v = person.viewport, hub.state.following != p.id, let rect = v.rect,
                   let path = polygon(corners(rect), page: v.page, host: host, closed: true) {
                    let layer = shape("view." + p.id, in: viewports)
                    layer.path = path
                    layer.strokeColor = color.cgColor
                    layer.fillColor = nil
                    layer.lineWidth = NibStroke.thin
                    layer.lineDashPattern = nil
                    keepShapes.insert("view." + p.id)
                }
                if let l = person.lasso {
                    let points = l.outline ?? l.bounds.map(corners) ?? []
                    if let path = polygon(points, page: l.page, host: host, closed: true) {
                        let layer = shape("lasso." + p.id, in: lassos)
                        layer.path = path
                        layer.strokeColor = color.cgColor
                        layer.fillColor = nil
                        layer.lineWidth = NibStroke.thin
                        layer.lineDashPattern = NibStroke.layerDash
                        layer.lineJoin = .round
                        keepShapes.insert("lasso." + p.id)
                    }
                }
                if let laser = hub.presence.laser(of: p.id, now: now, ttl: timing.laserTTL, trail: timing.laserTrail),
                   let last = laser.points.last, host.pageFrame(laser.page) != nil {
                    let tint = laser.color?.uiColor ?? color
                    let centre = host.viewPoint(last, page: laser.page)
                    let glow = shape("laserGlow." + p.id, in: lasers)
                    let glowSize = NibMetrics.laserDot + NibMetrics.laserGlow * 2
                    glow.path = UIBezierPath(ovalIn: square(centre, glowSize)).cgPath
                    glow.fillColor = tint.withAlphaComponent(CGFloat(NibOpacity.laserGlow)).cgColor
                    glow.strokeColor = nil
                    let dot = shape("laserDot." + p.id, in: lasers)
                    dot.path = UIBezierPath(ovalIn: square(centre, NibMetrics.laserDot)).cgPath
                    dot.fillColor = tint.cgColor
                    dot.strokeColor = nil
                    keepShapes.formUnion(["laserGlow." + p.id, "laserDot." + p.id])
                    if laser.isTrail, laser.points.count > 1,
                       let path = polygon(laser.points, page: laser.page, host: host, closed: false) {
                        let trail = shape("laserTrail." + p.id, in: lasers)
                        trail.path = path
                        trail.strokeColor = tint.withAlphaComponent(CGFloat(NibOpacity.laserGlow)).cgColor
                        trail.fillColor = nil
                        trail.lineWidth = NibMetrics.laserTrail
                        trail.lineCap = .round
                        trail.lineJoin = .round
                        trail.lineDashPattern = nil
                        keepShapes.insert("laserTrail." + p.id)
                    }
                }
                if let c = hub.presence.cursor(of: p.id, now: now, ttl: timing.cursorTTL), host.pageFrame(c.page) != nil {
                    let view = cursors[p.id] ?? makeCursor(p.id)
                    view.update(name: p.name, color: color)
                    moves.append((view, host.viewPoint(c.point, page: c.page)))
                    keepCursors.insert(p.id)
                }
            }
        }

        // Until thumbnails support decoration providers, show the 6 pt dot in the gutter outside the page.
        var keepDots = Set<PageID>()
        for page in hub.unseen.unseenPages(host.documentID) {
            guard let frame = host.pageFrame(page) else { continue }
            let layer = dotLayers[page] ?? {
                let l = CAShapeLayer()
                dots.addSublayer(l)
                dotLayers[page] = l
                return l
            }()
            let inset = NibSpacing.m
            let centre = CGPoint(x: frame.maxX + inset, y: frame.minY + inset)
            layer.path = UIBezierPath(ovalIn: square(centre, NibMetrics.statusDot)).cgPath
            layer.fillColor = NibUIColor.accent.cgColor
            keepDots.insert(page)
        }

        for (key, layer) in shapes where !keepShapes.contains(key) {
            layer.removeFromSuperlayer()
            shapes[key] = nil
        }
        for (pid, view) in cursors where !keepCursors.contains(pid) {
            view.removeFromSuperview()
            cursors[pid] = nil
        }
        for (page, layer) in dotLayers where !keepDots.contains(page) {
            layer.removeFromSuperlayer()
            dotLayers[page] = nil
        }
        CATransaction.commit()
        for move in moves { move.view.move(to: move.point, animated: glides) }
        scheduleExpiry(now: now)
    }

    /// One redraw when the next cursor or laser expires (kept when that time has not changed: scrolling renders
    /// every frame).
    private func scheduleExpiry(now: TimeInterval) {
        let next = hub.flatMap { $0.presence.nextExpiry(now: now, cursorTTL: $0.timing.cursorTTL,
                                                         laserTTL: $0.timing.laserTTL) }
        if let next = next, next == expiryAt, expiry != nil { return }
        expiry?.cancel()
        expiry = nil
        expiryAt = next
        guard let next = next else { return }
        let delay = max(0.05, next - now + 0.01)
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.expiry = nil
            self.expiryAt = nil
            self.render(animated: false)
        }
    }

    private func shape(_ key: String, in group: CALayer) -> CAShapeLayer {
        if let s = shapes[key] { return s }
        let s = CAShapeLayer()
        group.addSublayer(s)
        shapes[key] = s
        return s
    }

    private func makeCursor(_ pid: String) -> PresenceCursorView {
        let view = PresenceCursorView()
        canvas.addSubview(view)
        cursors[pid] = view
        return view
    }

    private func corners(_ r: Rect) -> [Point] {
        [Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.maxX, r.maxY), Point(r.minX, r.maxY)]
    }

    private func polygon(_ points: [Point], page: PageID, host: CanvasHost, closed: Bool) -> CGPath? {
        guard points.count >= 2, host.pageFrame(page) != nil else { return nil }
        let path = UIBezierPath()
        path.move(to: host.viewPoint(points[0], page: page))
        for p in points.dropFirst() { path.addLine(to: host.viewPoint(p, page: page)) }
        if closed { path.close() }
        return path.cgPath
    }

    private func square(_ centre: CGPoint, _ side: CGFloat) -> CGRect {
        CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }
}

/// The attachment's own layer on the canvas: scrolls with the pages, never takes a touch, hidden from VoiceOver (the
/// beads after the title say who is here).
final class PresenceCanvasView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// A collaborator's live cursor: a 10 pt bead in their presence colour with a caption2 name capsule beside it. Its
/// frame's origin sits on the point it marks.
final class PresenceCursorView: UIView {
    private let bead = UIView()
    private let capsule = UIView()
    private let label = UILabel()
    private var name: String?
    private var category: UIContentSizeCategory?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false
        bead.layer.borderColor = NibUIColor.onAccent.cgColor
        bead.layer.borderWidth = NibStroke.thin
        label.font = NibUIFont.caption2
        label.textColor = NibUIColor.onAccent
        label.lineBreakMode = .byTruncatingTail
        capsule.addSubview(label)
        addSubview(bead)
        addSubview(capsule)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func update(name: String, color: UIColor) {
        bead.backgroundColor = color
        capsule.backgroundColor = color
        let size = traitCollection.preferredContentSizeCategory
        guard name != self.name || size != category else { return }
        self.name = name
        category = size
        label.font = NibUIFont.caption2
        label.text = name
        let side = NibMetrics.liveCursorBead
        let pad = NibSpacing.xs
        let maxLabel = NibMetrics.presenceBead * 6
        let fit = label.sizeThatFits(CGSize(width: maxLabel, height: .greatestFiniteMagnitude))
        let labelSize = CGSize(width: min(ceil(fit.width), maxLabel), height: ceil(fit.height))
        let capsuleSize = CGSize(width: labelSize.width + pad * 2, height: labelSize.height + NibSpacing.xxs * 2)
        bead.frame = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        bead.layer.cornerRadius = NibRadius.capsule(side)
        capsule.frame = CGRect(x: side / 2 + NibSpacing.xxs, y: side / 2, width: capsuleSize.width, height: capsuleSize.height)
        capsule.layer.cornerRadius = NibRadius.capsule(capsuleSize.height)
        label.frame = CGRect(x: pad, y: NibSpacing.xxs, width: labelSize.width, height: labelSize.height)
    }

    /// Puts the bead on `point` (canvas coordinates): a collaborator's move glides there; scrolling and zooming here
    /// move it at once.
    func move(to point: CGPoint, animated: Bool) {
        let target = CGRect(origin: point, size: .zero)
        guard frame != target else { return }
        if animated && superview != nil && frame != .zero {
            NibMotion.animateUIKit(NibMotion.glide) { self.frame = target }
        } else {
            frame = target
        }
    }
}

// MARK: - Beads after the title (DESIGN.md §14.14)

/// Collaborators' initial beads (up to three, then "+N"; one bead with the count on iPhone). With one collaborator a
/// tap follows them (or stops); a long press, or a tap with several collaborators, opens the menu: follow someone,
/// stop following, Follow Me, Share Live.
struct PresenceBeadsView: View {
    @ObservedObject var hub: PresenceHub
    let context: ChromeContext

    private var canFollow: Bool { context.kind == .notebook || context.kind == .whiteboard }

    var body: some View {
        let state = hub.state
        let people = state.others.map {
            NibPresenceStack.Person(id: $0.id, name: $0.name, initials: $0.initials, colorIndex: $0.colorIndex)
        }
        Group {
            if canFollow, state.others.count == 1, let only = state.others.first {
                Menu {
                    menu(state)
                } label: {
                    stack(people)
                } primaryAction: {
                    follow(state.following == only.id ? nil : only)
                }
            } else {
                Menu {
                    menu(state)
                } label: {
                    stack(people)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(String(localized: "Collaborators: \(ListFormatter.localizedString(byJoining: state.others.map(\.name)))"))
        .accessibilityValue(state.followed.map { String(localized: "Following \($0.name)") } ?? "")
        .accessibilityHint(canFollow ? String(localized: "Follow someone, or have everyone follow you.") : "")
    }

    private func stack(_ people: [NibPresenceStack.Person]) -> some View {
        NibPresenceStack(people, compact: context.isCompact)
            .padding(.horizontal, NibSpacing.s)
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Capsule())
            .nibChromeTypeCap()
    }

    @ViewBuilder private func menu(_ state: PresenceUIState) -> some View {
        if canFollow {
            Section(String(localized: "Follow")) {
                ForEach(state.others) { p in
                    Button {
                        follow(state.following == p.id ? nil : p)
                    } label: {
                        Label {
                            Text(p.name)
                        } icon: {
                            Image(nib: state.following == p.id ? .checkmark : .eye)
                        }
                    }
                }
            }
            if let followed = state.followed {
                Button {
                    follow(nil)
                } label: {
                    Label {
                        Text(String(localized: "Stop Following \(followed.name)"))
                    } icon: {
                        Image(nib: .xmark)
                    }
                }
            }
            Toggle(isOn: Binding(get: { state.leading }, set: { on in
                hub.run(CommandIDs.collabFollowMe, ["on": .bool(on)], session: context.session)
            })) {
                Text(String(localized: "Follow Me"))
            }
        }
        Button {
            hub.run(CommandIDs.panelOpen, ["id": .string(CollabIDs.sharePanel)], session: context.session)
        } label: {
            Label {
                Text(String(localized: "Collaborators"))
            } icon: {
                Image(nib: .shared)
            }
        }
    }

    private func follow(_ p: CollabParticipant?) {
        let params: JSONValue = p.map { ["participant": .string($0.id)] } ?? [:]
        hub.run(CommandIDs.collabFollow, params, session: context.session)
    }
}
