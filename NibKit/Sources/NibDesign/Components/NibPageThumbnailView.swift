import UIKit
import NibContracts

/// `NibPageThumbnail` for UIKit rows and cells (the outline and bookmark tables, page lists): the page render with
/// continuous radius 4 and the paper elevation, on a paper-coloured placeholder while it loads (never a shimmer).
/// `isCurrent` draws the 2 pt accent ring 3 pt outside (radius 7). No number: the row says which page it is, so the
/// view is not an accessibility element. 40 pt wide by default (`NibMetrics.rowThumbnailWidth`); its intrinsic
/// height follows `aspectRatio`.
public final class NibPageThumbnailView: UIView {
    public var image: UIImage? {
        didSet { imageView.image = image }
    }

    public var isCurrent = false {
        didSet { ring.isHidden = !isCurrent }
    }

    /// Width over height of the page as shown (A4 portrait by default).
    public var aspectRatio: CGFloat = 595.0 / 842.0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    public var width: CGFloat = NibMetrics.rowThumbnailWidth {
        didSet { invalidateIntrinsicContentSize() }
    }

    private let imageView = UIImageView()
    private let ring = CAShapeLayer()

    public init(width: CGFloat = NibMetrics.rowThumbnailWidth, aspectRatio: CGFloat = 595.0 / 842.0) {
        self.width = width
        self.aspectRatio = aspectRatio
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: width / max(aspectRatio, 0.01)))
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
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = NibRadius.thumbnail
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = NibPaper.white.uiColor
        addSubview(imageView)
        ring.fillColor = nil
        ring.lineWidth = NibStroke.ring
        ring.isHidden = true
        layer.addSublayer(ring)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: NibPageThumbnailView, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: width, height: width / max(aspectRatio, 0.01))
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let shape = UIBezierPath(roundedRect: bounds, cornerRadius: NibRadius.thumbnail).cgPath
        // The ring's centre line: 2 pt outside with radius 6, so the 2 pt stroke spans 1–3 pt outside (radius 7).
        let offset = NibStroke.ringOutset - NibStroke.ring / 2
        let ringPath = UIBezierPath(roundedRect: bounds.insetBy(dx: -offset, dy: -offset),
                                    cornerRadius: NibRadius.thumbnail + offset).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = bounds
        layer.nibElevation(.paper, path: shape, dark: traitCollection.userInterfaceStyle == .dark)
        ring.path = ringPath
        ring.strokeColor = NibUIColor.accent.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }
}
