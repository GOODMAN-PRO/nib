import UIKit

/// A selection or frame handle for UIKit canvas overlays (DESIGN.md §14.3, §10.15): a rigid 12 pt bead centred in a
/// 44 pt hit area. Precision affordances never stretch, wobble, poke or refract, so a handle is drawn with the water
/// tokens rather than being a droplet: `clear` is the Clear body over paper with its rim,
/// the stronger 0.8 pt `waterLineBud` outline so it reads on light paper, and the resting elevation;
/// `tinted` is accent with the Tinted rim. Liquid Off and Reduce Transparency remove rim and shadow;
/// Clear becomes `chromeOpaque`, Tinted stays accent. Colours follow appearance and Increase Contrast.
/// The view is not an accessibility element: the selection it belongs to carries the actions.
public final class NibHandleView: UIView {
    public enum Style: Sendable {
        case clear, tinted
    }

    public var style: Style {
        didSet { updateColours() }
    }

    private let body = CAShapeLayer()
    private let rim = NibDirectionalRimLayer()
    private let outline = CAShapeLayer()

    public init(style: Style = .clear) {
        self.style = style
        super.init(frame: CGRect(x: 0, y: 0, width: NibMetrics.hitTarget, height: NibMetrics.hitTarget))
        setUp()
    }

    public required init?(coder: NSCoder) {
        self.style = .clear
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        outline.fillColor = nil
        outline.lineWidth = NibStroke.outline
        for sublayer in [body, rim, outline] { layer.addSublayer(sublayer) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, NibLiquidModeTrait.self]) {
            (view: NibHandleView, _: UITraitCollection) in
            view.updateColours()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(transparencyChanged),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                                               object: nil)
        updateColours()
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let d = NibMetrics.handleBead
        let bead = CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let path = UIBezierPath(ovalIn: bead).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.path = path
        rim.frame = bead
        rim.cornerRadius = d / 2
        rim.contentsScale = traitCollection.displayScale
        rim.setNeedsDisplay()
        outline.path = UIBezierPath(ovalIn: bead.insetBy(dx: NibStroke.outline / 2, dy: NibStroke.outline / 2)).cgPath
        body.nibElevation(.rest, path: path, dark: traitCollection.userInterfaceStyle == .dark)
        if usesOpaqueChrome { body.shadowOpacity = 0; body.shadowPath = nil }
        CATransaction.commit()
    }

    private var usesOpaqueChrome: Bool {
        traitCollection[NibLiquidModeTrait.self] == .off || UIAccessibility.isReduceTransparencyEnabled
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateColours()
    }

    @objc private func transparencyChanged() {
        updateColours()
    }

    private func updateColours() {
        let traits = traitCollection
        let opaque = usesOpaqueChrome
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.isHidden = opaque
        switch style {
        case .clear:
            body.fillColor = (opaque ? NibUIColor.chromeOpaque : NibUIColor.clearBodyOnPaper).resolvedColor(with: traits).cgColor
            rim.rimColor = NibUIColor.waterRim.resolvedColor(with: traits).cgColor
            outline.strokeColor = NibUIColor.waterLineBud.resolvedColor(with: traits).cgColor
        case .tinted:
            body.fillColor = NibUIColor.accent.resolvedColor(with: traits).cgColor
            rim.rimColor = NibUIColor.tintRim.resolvedColor(with: traits).cgColor
            outline.strokeColor = NibUIColor.waterLine.resolvedColor(with: traits).cgColor
        }
        CATransaction.commit()
        setNeedsLayout()
    }
}

/// The Zoom Window's target box for UIKit canvas overlays (DESIGN.md §14.3): the `frame` droplet's look, rim and
/// water line only, no body, radius 18, so the page stays readable through it. It draws; the attachment moves it and
/// takes its touches. Inside the droplet container the same box is `.droplet(id, style: .frame)`, which also
/// stretches while dragged (present it through `NibFloatingHost`).
public final class NibFrameView: UIView {
    private let rim = NibDirectionalRimLayer()
    private let outline = CAShapeLayer()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        outline.fillColor = nil
        outline.lineWidth = NibStroke.outline
        layer.addSublayer(rim)
        layer.addSublayer(outline)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, NibLiquidModeTrait.self]) {
            (view: NibFrameView, _: UITraitCollection) in
            view.updateColours()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateColours),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        updateColours()
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let inset = NibStroke.outline / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = bounds
        rim.cornerRadius = NibRadius.zoomFrame
        rim.contentsScale = traitCollection.displayScale
        rim.setNeedsDisplay()
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                    cornerRadius: max(0, NibRadius.zoomFrame - inset)).cgPath
        CATransaction.commit()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateColours()
    }

    @objc private func updateColours() {
        let traits = traitCollection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.isHidden = traitCollection[NibLiquidModeTrait.self] == .off || UIAccessibility.isReduceTransparencyEnabled
        rim.rimColor = NibUIColor.waterRim.resolvedColor(with: traits).cgColor
        outline.strokeColor = NibUIColor.waterLine.resolvedColor(with: traits).cgColor
        CATransaction.commit()
    }
}

/// Static UIKit optics use the same normal/light lobes as the water shader. Draw a 0.8 pt inner
/// stroke, with a top-left key and half-strength counter-rim; never the retired offset crescent.
final class NibDirectionalRimLayer: CALayer {
    var rimColor: CGColor = UIColor.white.cgColor { didSet { setNeedsDisplay() } }

    override func draw(in context: CGContext) {
        let inset = NibStroke.outline / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = max(0, min(cornerRadius - inset, min(rect.width, rect.height) / 2))
        context.setLineWidth(NibStroke.outline)
        func stroke(_ path: CGPath, normal: CGVector) {
            context.setStrokeColor(rimColor.copy(alpha: rimColor.alpha * NibOptics.rimLight(normal))!)
            context.addPath(path)
            context.strokePath()
        }
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: rect.maxX - radius, y: rect.minY + radius), -.pi / 2),
            (CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), 0),
            (CGPoint(x: rect.minX + radius, y: rect.maxY - radius), .pi / 2),
            (CGPoint(x: rect.minX + radius, y: rect.minY + radius), .pi)
        ]
        for (index, corner) in corners.enumerated() {
            let (center, start) = corner
            for step in 0..<30 {
                let a = start + CGFloat(step) * .pi / 60
                let b = a + .pi / 60
                let path = CGMutablePath()
                path.addArc(center: center, radius: radius, startAngle: a, endAngle: b, clockwise: false)
                stroke(path, normal: CGVector(dx: cos((a + b) / 2), dy: sin((a + b) / 2)))
            }
            let end = start + .pi / 2
            let next = corners[(index + 1) % corners.count].0
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end)))
            path.addLine(to: CGPoint(x: next.x + radius * cos(end), y: next.y + radius * sin(end)))
            stroke(path, normal: CGVector(dx: cos(end), dy: sin(end)))
        }
    }
}
