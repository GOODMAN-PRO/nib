import UIKit

/// A selection or frame handle for UIKit canvas overlays (DESIGN.md §14.3, §10.15): a rigid 12 pt bead centred in a
/// 44 pt hit area. Precision affordances never stretch, wobble, poke or refract, so a handle is drawn with the water
/// tokens rather than being a droplet: `clear` (corners, the rotation bead) is the Clear body over paper with its rim,
/// the 0.8 pt water line and the resting elevation; `tinted` (edge handles) is accent with the Tinted rim. Under
/// Reduce Transparency the Clear body is `chromeOpaque`. Colours follow the appearance and Increase Contrast.
/// The view is not an accessibility element: the selection it belongs to carries the actions.
public final class NibHandleView: UIView {
    public enum Style: Sendable {
        case clear, tinted
    }

    public var style: Style {
        didSet { updateColours() }
    }

    private let body = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let rimMask = CAShapeLayer()
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
        rim.fillRule = .evenOdd
        rim.mask = rimMask
        outline.fillColor = nil
        outline.lineWidth = NibStroke.outline
        for sublayer in [body, rim, outline] { layer.addSublayer(sublayer) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
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
        rim.path = NibWaterPaths.rim(UIBezierPath(ovalIn: bead))
        rimMask.path = path
        outline.path = UIBezierPath(ovalIn: bead.insetBy(dx: NibStroke.outline / 2, dy: NibStroke.outline / 2)).cgPath
        body.nibElevation(.rest, path: path, dark: traitCollection.userInterfaceStyle == .dark)
        CATransaction.commit()
    }

    @objc private func transparencyChanged() {
        updateColours()
    }

    private func updateColours() {
        let traits = traitCollection
        let opaque = UIAccessibility.isReduceTransparencyEnabled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .clear:
            body.fillColor = (opaque ? NibUIColor.chromeOpaque : NibUIColor.clearBodyOnPaper).resolvedColor(with: traits).cgColor
            rim.fillColor = NibUIColor.waterRim.resolvedColor(with: traits).cgColor
        case .tinted:
            body.fillColor = NibUIColor.accent.resolvedColor(with: traits).cgColor
            rim.fillColor = NibUIColor.tintRim.resolvedColor(with: traits).cgColor
        }
        outline.strokeColor = NibUIColor.waterLine.resolvedColor(with: traits).cgColor
        CATransaction.commit()
        setNeedsLayout()
    }
}

/// The Zoom Window's target box for UIKit canvas overlays (DESIGN.md §14.3): the `frame` droplet's look, rim and
/// water line only, no body, radius 18, so the page stays readable through it. It draws; the attachment moves it and
/// takes its touches. Inside the droplet container the same box is `.droplet(id, style: .frame)`, which also
/// stretches while dragged (present it through `NibFloatingHost`).
public final class NibFrameView: UIView {
    private let rim = CAShapeLayer()
    private let rimMask = CAShapeLayer()
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
        rim.fillRule = .evenOdd
        rim.mask = rimMask
        outline.fillColor = nil
        outline.lineWidth = NibStroke.outline
        layer.addSublayer(rim)
        layer.addSublayer(outline)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: NibFrameView, _: UITraitCollection) in
            view.updateColours()
        }
        updateColours()
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let shape = UIBezierPath(roundedRect: bounds, cornerRadius: NibRadius.zoomFrame)
        let inset = NibStroke.outline / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.path = NibWaterPaths.rim(shape)
        rimMask.path = shape.cgPath
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                    cornerRadius: max(0, NibRadius.zoomFrame - inset)).cgPath
        CATransaction.commit()
    }

    private func updateColours() {
        let traits = traitCollection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.fillColor = NibUIColor.waterRim.resolvedColor(with: traits).cgColor
        outline.strokeColor = NibUIColor.waterLine.resolvedColor(with: traits).cgColor
        CATransaction.commit()
    }
}

/// The water rim as a path (DESIGN.md §10.9): the shape minus itself offset by (1.1, 1.5) pt, which leaves a crescent
/// on the top-left facing the light. Fill it even-odd and mask it with the shape.
enum NibWaterPaths {
    static let rimOffset = CGSize(width: 1.1, height: 1.5)

    static func rim(_ shape: UIBezierPath) -> CGPath {
        let path = CGMutablePath()
        path.addPath(shape.cgPath)
        path.addPath(shape.cgPath, transform: CGAffineTransform(translationX: rimOffset.width, y: rimOffset.height))
        return path
    }
}
