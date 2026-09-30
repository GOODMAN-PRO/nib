import UIKit
import NibContracts
import NibDesign

/// The "comment" item drawer: the pin on the page, in tiles, thumbnails and `render.page`. An open thread is a 22 pt
/// accent disc with its message count (DESIGN.md §14.3); a resolved one is a paper disc with an accent ring and a
/// check (never colour alone), drawn only while Show Resolved Comments is on for this device. Exports and renders
/// without annotations leave pins out (contracts-v2 `DrawContext.purpose` / `annotations`): NibExport writes comments
/// as PDF text annotations instead. Thread-safe and pure: everything main-actor is resolved once at registration.
final class CommentPinDrawer: ItemDrawer {
    private let settings: SettingsStore
    private let accent: CGColor
    private let accentOnDarkPaper: CGColor
    private let paper: CGColor
    private let digits: UIColor
    private let font: UIFont
    private let smallFont: UIFont

    @MainActor
    init(settings: SettingsStore) {
        self.settings = settings
        accent = NibUIColor.accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
        accentOnDarkPaper = NibUIColor.accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor
        paper = NibUIColor.onAccent.cgColor
        digits = NibUIColor.onAccent
        // The page never follows Dynamic Type: the badge number role (SF Rounded bold) at a fixed page size.
        font = NibUIFont.badgeNumber.withSize(12)
        smallFont = NibUIFont.badgeNumber.withSize(9)
    }

    /// Pins are an on-screen annotation: never flattened into an export, and left out when a render asks for no
    /// annotations.
    static func drawsPins(_ context: DrawContext) -> Bool { context.annotations && context.purpose != .export }

    func draw(_ item: Item, in context: DrawContext) {
        guard Self.drawsPins(context), let comment = item.comment,
              CommentRules.isVisible(comment, showResolved: settings.get(CommentSettings.showResolved)) else { return }
        let d = CGFloat(CommentRules.pinDiameter)
        let disc = CGRect(x: CGFloat(comment.anchor.x) - d / 2, y: CGFloat(comment.anchor.y) - d / 2, width: d, height: d)
        let tint = context.darkPaper ? accentOnDarkPaper : accent
        let cg = context.cg
        cg.saveGState()
        defer { cg.restoreGState() }
        if comment.resolved {
            cg.setFillColor(paper)
            cg.fillEllipse(in: disc)
            cg.setStrokeColor(tint)
            cg.setLineWidth(NibStroke.emphasis)
            cg.strokeEllipse(in: disc.insetBy(dx: NibStroke.emphasis / 2, dy: NibStroke.emphasis / 2))
            let check = CGMutablePath()
            check.move(to: CGPoint(x: disc.minX + d * 0.29, y: disc.minY + d * 0.52))
            check.addLine(to: CGPoint(x: disc.minX + d * 0.44, y: disc.minY + d * 0.67))
            check.addLine(to: CGPoint(x: disc.minX + d * 0.72, y: disc.minY + d * 0.36))
            cg.setLineWidth(NibStroke.ring)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(check)
            cg.strokePath()
            return
        }
        cg.setFillColor(tint)
        cg.fillEllipse(in: disc)
        let count = comment.messages.count
        let label = count > 99 ? "99+" : String(count)
        let text = NSAttributedString(string: label, attributes: [.font: count > 99 ? smallFont : font,
                                                                 .foregroundColor: digits])
        let size = text.size()
        UIGraphicsPushContext(cg)
        text.draw(at: CGPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2))
        UIGraphicsPopContext()
    }
}
