import NibContracts
import NibDesign
import QuartzCore
import UIKit

/// What the hover preview draws under a hovering Apple Pencil.
enum HoverPreviewKind: Equatable {
    case none
    /// The ink the pen, pencil or shape tool will lay down (an ellipse turned by the barrel for a rolling nib).
    case dot
    /// A chisel tip: highlighter and tape.
    case chisel
    /// An outline of what the eraser will take.
    case ring
}

struct HoverPreviewShape: Equatable {
    var kind: HoverPreviewKind
    /// View points.
    var size: CGSize
    /// Radians, about the centre.
    var angle: Double
    /// Fill for dots and chisels; rings use the chrome's label colour.
    var color: RGBA?

    static let none = HoverPreviewShape(kind: .none, size: .zero, angle: 0, color: nil)
}

/// Pure geometry of the hover preview (T-075 / P-044): what the current tool will put down, at the canvas zoom.
enum HoverPreviewGeometry {
    /// Anything thinner vanishes under the tip; the preview is a hint, not the stroke.
    static let minimumDot = 3.0
    static let defaultEraserRadius = 6.0
    static let inkOpacity = 0.9
    static let highlightOpacity = 0.5

    /// - Parameters:
    ///   - presets: the tool's colour and thickness presets (nil for tools without them).
    ///   - eraserRadius: page points (the eraser's current size), nil for the default.
    ///   - zoom: view points per page point.
    ///   - azimuth: the Pencil's azimuth in radians (turns chisel tips).
    ///   - roll: Apple Pencil Pro barrel roll in radians, only when the pen reacts to rotation (Dynamic Ink).
    static func shape(tool: String, presets: ToolPresets?, eraserRadius: Double?, zoom: Double, azimuth: Double,
                      roll: Double?) -> HoverPreviewShape {
        let z = max(zoom, 0.01)
        switch tool {
        case "pen", "pencil", "shape", "drawShape":
            guard let p = presets else { return .none }
            let d = max(minimumDot, p.width * z)
            let color = p.color.withAlpha(min(p.color.alpha, inkOpacity))
            if tool == "pen", let roll {
                // A flat nib seen from above: its long side turns with the barrel.
                return HoverPreviewShape(kind: .dot, size: CGSize(width: d, height: max(minimumDot / 2, d * 0.35)),
                                         angle: roll, color: color)
            }
            return HoverPreviewShape(kind: .dot, size: CGSize(width: d, height: d), angle: 0, color: color)
        case "highlighter", "tape":
            guard let p = presets else { return .none }
            let h = max(minimumDot + 1, p.width * z)
            return HoverPreviewShape(kind: .chisel, size: CGSize(width: max(2, h * 0.35), height: h),
                                     angle: azimuth + (roll ?? 0),
                                     color: p.color.withAlpha(min(p.color.alpha, highlightOpacity)))
        case "eraser":
            let d = max(minimumDot * 2, 2 * (eraserRadius ?? defaultEraserRadius) * z)
            return HoverPreviewShape(kind: .ring, size: CGSize(width: d, height: d), angle: 0, color: nil)
        default:
            return .none                                    // lasso, text, plugin tools: nothing to preview
        }
    }

    /// The outline centred on the origin (the layer is positioned at the Pencil and turned by `angle`).
    static func path(for shape: HoverPreviewShape) -> CGPath {
        let rect = CGRect(x: -shape.size.width / 2, y: -shape.size.height / 2,
                          width: shape.size.width, height: shape.size.height)
        if shape.kind == .chisel {
            let corner = min(shape.size.width, shape.size.height) / 4
            return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        }
        return CGPath(ellipseIn: rect, transform: nil)
    }
}

/// The hover preview on one canvas: a shape layer in the active tool's overlay, moved without animation (Pencil
/// feedback never animates) and never drawn while the Pencil is down (the canvas stops sending hover then).
@MainActor
final class HoverPreview {
    private(set) weak var host: CanvasHost?
    private let layer = CAShapeLayer()

    init(host: CanvasHost) {
        self.host = host
        layer.zPosition = 1_000
        layer.isHidden = true
    }

    func show(_ shape: HoverPreviewShape, at point: CGPoint) {
        guard let host, shape.kind != .none else {
            hide()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Tools clear their overlay; put the preview back when that happened.
        if layer.superlayer !== host.overlayLayer { host.overlayLayer.addSublayer(layer) }
        let traits = host.canvasView.traitCollection
        layer.contentsScale = max(traits.displayScale, 1)
        layer.path = HoverPreviewGeometry.path(for: shape)
        layer.position = point
        layer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(shape.angle)))
        if shape.kind == .ring {
            layer.fillColor = nil
            layer.strokeColor = NibUIColor.labelSecondary.resolvedColor(with: traits).cgColor
            layer.lineWidth = 1
        } else {
            layer.fillColor = shape.color?.cgColor
            // A hairline keeps the dot visible over ink of the same colour.
            layer.strokeColor = NibUIColor.swatchHairline.resolvedColor(with: traits).cgColor
            layer.lineWidth = 0.5
        }
        layer.isHidden = false
        CATransaction.commit()
    }

    func hide() {
        guard !layer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
    }

    func remove() {
        layer.removeFromSuperlayer()
    }
}
