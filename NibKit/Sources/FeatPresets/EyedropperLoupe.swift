import UIKit
import Combine
import os
import NibContracts
import NibDesign

// MARK: - Sampling

/// Reads the colour under a page point from `services.renderer`: the page exactly as it is drawn, so PDF
/// backgrounds, images, templates and ink all count.
enum EyedropperSampler {
    /// Page points shown across the loupe's lens, and how much the lens magnifies them.
    static let span: Double = 20
    static let magnification: Double = 5

    struct Sample {
        var page: PageID
        var point: Point
        var image: CGImage
        /// The page region the image covers (the renderer's own, which may differ from the one asked for).
        var region: Rect
        var colour: RGBA
    }

    static func region(around p: Point, span: Double) -> Rect {
        Rect(x: p.x - span / 2, y: p.y - span / 2, width: span, height: span)
    }

    /// The image pixel (top-left origin) under a page point, from the image's real size and the region it covers.
    static func pixel(for p: Point, width: Int, height: Int, region: Rect) -> (x: Int, y: Int) {
        let sx = Double(width) / max(region.width, .ulpOfOne)
        let sy = Double(height) / max(region.height, .ulpOfOne)
        let x = Int(((p.x - region.x) * sx).rounded(.down))
        let y = Int(((p.y - region.y) * sy).rounded(.down))
        return (min(max(x, 0), max(width - 1, 0)), min(max(y, 0), max(height - 1, 0)))
    }

    /// One pixel of an image as un-premultiplied 8-bit sRGB (x, y from the top-left).
    static func colour(in image: CGImage, x: Int, y: Int) -> RGBA? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            // The context's one pixel covers [0, 1]²; shift the image so pixel (x, y) lands on it (CG's y points up).
            ctx.draw(image, in: CGRect(x: -x, y: y + 1 - image.height, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        let a = bytes[3]
        guard a > 0 else { return RGBA(0, 0, 0, 0) }
        func straight(_ v: UInt8) -> UInt8 {
            a == 255 ? v : UInt8(min(255, (Double(v) * 255 / Double(a)).rounded()))
        }
        return RGBA(straight(bytes[0]), straight(bytes[1]), straight(bytes[2]), a)
    }

    /// Renders the lens region around `p` (with the paper, PDF and every visible layer) and reads the pixel under `p`.
    static func sample(_ renderer: PageRenderer, doc: DocumentID, page: PageID, at p: Point, scale: Double) async throws -> Sample {
        let request = RenderRequest(doc: doc, page: page, region: region(around: p, span: span), scale: scale,
                                    background: true, annotations: true)
        let result = try await renderer.render(request)
        let px = pixel(for: p, width: result.image.width, height: result.image.height, region: result.region)
        guard let picked = colour(in: result.image, x: px.x, y: px.y) else {
            throw NibError(.internalError, "could not read the rendered colour")
        }
        return Sample(page: page, point: p, image: result.image, region: result.region, colour: picked)
    }
}

// MARK: - The in-document eyedropper

/// "Pick Colour from Page": a loupe over the canvas that follows the finger or Pencil and magnifies the rendered page;
/// lifting sets the colour slot (or adds one) through `preset.setSwatch` / `preset.addSwatch`. It is a canvas
/// attachment, so while it is open it claims touches before tap handlers and the active tool; switching tools
/// closes it.
@MainActor
final class EyedropperAttachment: CanvasAttachment {
    struct Request: Equatable {
        var tool: String
        var target: ColourTarget
    }

    static let descriptorID = "presets.eyedropper"
    private static let log = Logger(subsystem: "app.nib", category: "presets")

    private final class Entry {
        weak var value: EyedropperAttachment?
        init(_ value: EyedropperAttachment) { self.value = value }
    }

    /// Every attached eyedropper (one per open canvas), so the tool menu of a window can find its own.
    private static var live: [Entry] = []

    static func attachment(for session: EditorSession) -> EyedropperAttachment? {
        live.removeAll { $0.value == nil }
        let mine = live.compactMap { $0.value }.filter { $0.host?.session === session }
        return mine.first { $0.host?.canvasView.window != nil } ?? mine.first
    }

    /// True when the window has a canvas and a renderer to sample.
    static func canPick(session: EditorSession, app: NibApp) -> Bool {
        app.services.renderer != nil && attachment(for: session) != nil
    }

    @discardableResult
    static func begin(_ request: Request, session: EditorSession) -> Bool {
        guard let attachment = attachment(for: session) else { return false }
        attachment.begin(request)
        return true
    }

    private(set) weak var host: CanvasHost?
    private(set) var request: Request?
    private(set) var current: EyedropperSampler.Sample?
    /// The last pick: the final sample and the preset command it runs.
    private(set) var commitTask: Task<Void, Never>?
    let loupe: EyedropperLoupeView
    private var pending: (page: PageID, point: Point)?
    private var sampling: Task<Void, Never>?
    private var generation = 0
    private var toolWatch: AnyCancellable?

    var isActive: Bool { request != nil }

    init() {
        loupe = EyedropperLoupeView()
        loupe.onUse = { [weak self] in self?.commit(at: nil) }
        loupe.onCancel = { [weak self] in self?.end() }
    }

    func attach(to host: CanvasHost) {
        self.host = host
        loupe.isHidden = true
        host.canvasView.addSubview(loupe)
        Self.live.append(Entry(self))
    }

    func detach(from host: CanvasHost) {
        end()
        loupe.removeFromSuperview()
        Self.live.removeAll { $0.value == nil || $0.value === self }
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        guard isActive, let s = current else { return }
        place(page: s.page, point: s.point)
    }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool { isActive }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        track(page: sample.page, point: sample.location)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let s = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        track(page: s.page, point: s.location)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        commit(at: (page: sample.page, point: sample.location))
    }

    /// A touch the system took over (a scroll, a system gesture) leaves the eyedropper open: the next touch picks.
    func touchesCancelled(host: CanvasHost) {}

    /// Opens the loupe in the middle of what is on screen.
    func begin(_ request: Request) {
        guard let host else { return }
        end()
        self.request = request
        toolWatch = host.session.$tool.dropFirst().sink { [weak self] _ in self?.end() }
        host.canvasView.bringSubviewToFront(loupe)
        loupe.isHidden = false
        let bounds = host.canvasView.bounds
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        if let hit = host.pagePoint(middle) {
            track(page: hit.page, point: hit.point)
        } else {
            loupe.place(focus: middle, within: bounds)
        }
        // VoiceOver moves to the loupe, which reads its colour and offers Use This Colour and Cancel.
        UIAccessibility.post(notification: .layoutChanged, argument: loupe)
    }

    /// Closes the loupe without changing anything.
    func end() {
        request = nil
        toolWatch = nil
        pending = nil
        current = nil
        generation += 1
        sampling?.cancel()
        sampling = nil
        loupe.isHidden = true
    }

    private var renderScale: Double {
        Double(max(1, host?.canvasView.traitCollection.displayScale ?? 1)) * EyedropperSampler.magnification
    }

    private func place(page: PageID, point: Point) {
        guard let host else { return }
        loupe.place(focus: host.viewPoint(point, page: page), within: host.canvasView.bounds)
    }

    /// Moves the loupe at once and renders the newest point; renders never queue up behind a fast finger.
    private func track(page: PageID, point: Point) {
        guard isActive else { return }
        place(page: page, point: point)
        pending = (page: page, point: point)
        guard sampling == nil else { return }
        let gen = generation
        sampling = Task { @MainActor [weak self] in
            while let strong = self, strong.generation == gen, let next = strong.pending {
                strong.pending = nil
                await strong.sample(page: next.page, point: next.point, generation: gen)
            }
            if let strong = self, strong.generation == gen { strong.sampling = nil }
        }
    }

    private func sample(page: PageID, point: Point, generation gen: Int) async {
        guard let host, let renderer = host.app.services.renderer else { return }
        do {
            let s = try await EyedropperSampler.sample(renderer, doc: host.documentID, page: page, at: point, scale: renderScale)
            guard generation == gen else { return }
            current = s
            loupe.show(s)
        } catch {
            Self.log.error("eyedropper render failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Samples the release point once more (the last render may be a frame behind) and applies the colour.
    private func commit(at spot: (page: PageID, point: Point)?) {
        guard let request, let host else { return }
        let app = host.app, session = host.session, doc = host.documentID, scale = renderScale
        let target: (page: PageID, point: Point)? = spot ?? current.map { (page: $0.page, point: $0.point) }
        let fallback = current?.colour
        end()
        commitTask = Task { @MainActor in
            var colour = fallback
            if let target, let renderer = app.services.renderer,
               let s = try? await EyedropperSampler.sample(renderer, doc: doc, page: target.page, at: target.point, scale: scale) {
                colour = s.colour
            }
            guard let picked = colour else { return }
            await EyedropperAttachment.apply(picked, request: request, app: app, session: session)
        }
    }

    /// The page colour is opaque, so it goes in as #RRGGBB (a highlighter slot then gets its own opacity).
    static func apply(_ colour: RGBA, request: Request, app: NibApp, session: EditorSession) async {
        let hex = PresetColour.rgbHex(colour)
        let call: PresetActions.Call
        switch request.target {
        case .slot(let i):
            call = PresetActions.call("preset.setSwatch", request.tool, ["index": .number(Double(i)), "color": .string(hex)])
        case .add:
            call = PresetActions.call("preset.addSwatch", request.tool, ["color": .string(hex)])
        }
        await PresetActions.run(app, session: session, [call]).value
        NibHaptics.play(.select)
    }
}

// MARK: - The loupe

/// A rigid, opaque magnifier (a precision affordance: no water, no stretch). The lens shows the rendered page at 5×
/// with the picked pixel framed in the middle; the ring around it is the colour under the reticle. It sits above the
/// finger, or below it at the top edge.
final class EyedropperLoupeView: UIView {
    static let diameter: CGFloat = 112
    static let ringWidth: CGFloat = 6

    var onUse: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var colour: RGBA?

    private let lens = CALayer()
    private let lensMask = CAShapeLayer()
    private let imageLayer = CALayer()
    private let ring = CAShapeLayer()
    private let edge = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let reticle = CAShapeLayer()
    private var circle: CGPath { UIBezierPath(ovalIn: bounds).cgPath }

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isUserInteractionEnabled = false
        lens.frame = bounds
        lensMask.path = circle
        lens.mask = lensMask
        imageLayer.magnificationFilter = .nearest
        imageLayer.contentsGravity = .resize
        lens.addSublayer(imageLayer)
        layer.addSublayer(lens)

        let inset = Self.ringWidth / 2
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).cgPath
        ring.fillColor = nil
        ring.lineWidth = Self.ringWidth
        layer.addSublayer(ring)
        edge.path = circle
        edge.fillColor = nil
        edge.lineWidth = 1
        layer.addSublayer(edge)

        // One page point under the reticle, framed twice so it reads on any colour.
        let cell = CGFloat(EyedropperSampler.magnification) + 2
        let square = UIBezierPath(rect: CGRect(x: bounds.midX - cell / 2, y: bounds.midY - cell / 2, width: cell, height: cell)).cgPath
        halo.path = square
        halo.fillColor = nil
        halo.lineWidth = 3
        reticle.path = square
        reticle.fillColor = nil
        reticle.lineWidth = 1
        layer.addSublayer(halo)
        layer.addSublayer(reticle)

        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Colour picker loupe")
        accessibilityHint = String(localized: "Drag on the page to pick a colour, then lift to use it.")
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Use This Colour")) { [weak self] _ in
                self?.onUse?()
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Cancel")) { [weak self] _ in
                self?.onCancel?()
                return true
            }
        ]
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: EyedropperLoupeView, _: UITraitCollection) in
            view.applyColours()
        }
        applyColours()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func accessibilityActivate() -> Bool {
        onUse?()
        return true
    }

    /// Centres the loupe above `focus` (below it when there is no room), inside `bounds`.
    func place(focus: CGPoint, within bounds: CGRect) {
        let d = Self.diameter
        let lift = d / 2 + NibSpacing.x4
        var c = CGPoint(x: focus.x, y: focus.y - lift)
        if c.y - d / 2 < bounds.minY + NibSpacing.s { c.y = focus.y + lift }
        let minX = bounds.minX + d / 2 + NibSpacing.s
        let maxX = bounds.maxX - d / 2 - NibSpacing.s
        c.x = maxX >= minX ? min(max(c.x, minX), maxX) : bounds.midX
        center = c
    }

    func show(_ s: EyedropperSampler.Sample) {
        colour = s.colour
        // Loupe points per page point: the lens inside the ring spans `EyedropperSampler.span` page points.
        let k = (Self.diameter - 2 * Self.ringWidth) / CGFloat(EyedropperSampler.span)
        let offset = CGPoint(x: CGFloat(s.point.x - s.region.x) * k, y: CGFloat(s.point.y - s.region.y) * k)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = s.image
        imageLayer.frame = CGRect(x: bounds.midX - offset.x, y: bounds.midY - offset.y,
                                  width: CGFloat(s.region.width) * k, height: CGFloat(s.region.height) * k)
        ring.strokeColor = PresetColour.cgColor(RGBA(s.colour.r, s.colour.g, s.colour.b))
        CATransaction.commit()
        accessibilityValue = PresetColour.name(s.colour)
    }

    private func applyColours() {
        let t = traitCollection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lens.backgroundColor = NibUIColor.backgroundSecondary.resolvedColor(with: t).cgColor
        edge.strokeColor = NibUIColor.separator.resolvedColor(with: t).cgColor
        halo.strokeColor = NibUIColor.background.resolvedColor(with: t).cgColor
        reticle.strokeColor = NibUIColor.label.resolvedColor(with: t).cgColor
        if colour == nil { ring.strokeColor = NibUIColor.fill1.resolvedColor(with: t).cgColor }
        layer.nibElevation(.lifted, path: circle, dark: t.userInterfaceStyle == .dark)
        CATransaction.commit()
    }
}
