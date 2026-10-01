import UIKit
import NibContracts

/// The seven note colours (DESIGN.md §14.3). Like ink they are page content: never themed, the same in light and
/// dark mode, and stored on the item as RGBA.
enum StickyColour: String, CaseIterable {
    case lemon, apricot, blush, lilac, sky, mint, stone

    var rgba: RGBA {
        switch self {
        case .lemon: return RGBA(0xFF, 0xE8, 0x7C)          // StickyItem's own default
        case .apricot: return RGBA(0xFF, 0xCB, 0x8E)
        case .blush: return RGBA(0xFF, 0xB8, 0xCC)
        case .lilac: return RGBA(0xDB, 0xC8, 0xFF)
        case .sky: return RGBA(0xAE, 0xDA, 0xFF)
        case .mint: return RGBA(0xB8, 0xEC, 0xC9)
        case .stone: return RGBA(0xE6, 0xE3, 0xDC)
        }
    }

    var name: String {
        switch self {
        case .lemon: return String(localized: "Lemon")
        case .apricot: return String(localized: "Apricot")
        case .blush: return String(localized: "Blush")
        case .lilac: return String(localized: "Lilac")
        case .sky: return String(localized: "Sky")
        case .mint: return String(localized: "Mint")
        case .stone: return String(localized: "Stone")
        }
    }

    /// The preset with the same hue (alpha ignored), if any.
    static func preset(_ c: RGBA) -> StickyColour? {
        allCases.first { $0.rgba.r == c.r && $0.rgba.g == c.g && $0.rgba.b == c.b }
    }
}

/// Sticky-note geometry in page points, shared by the drawer, the editing overlay and hit testing.
enum StickyGeometry {
    /// A new note is a square of this side.
    static let noteSide = 160.0
    static let padding = 12.0
    /// Side of the collapsed note icon, drawn at the frame's top-left. The frame keeps the expanded size, so expanding
    /// (or an export that prints collapsed notes expanded, on a copy) only flips `collapsed`.
    static let iconSide = 28.0
    /// Height of the author / resolved line at the bottom of a note.
    static let footerHeight = 11.0
    static let authorSize = 9.0
    /// Default character attributes of note text (runs that leave fields nil inherit these).
    static let textBase = TextAttributes(size: 15)

    /// The folded corner's leg: 14 % of the short side, 8…22 pt.
    static func fold(width: Double, height: Double) -> Double {
        min(max(min(width, height) * 0.14, 8), 22)
    }

    /// Side of the icon a collapsed note is drawn as.
    static func iconSide(_ f: Frame) -> Double { max(0, min(iconSide, f.w, f.h)) }

    static func hasFooter(_ s: StickyItem) -> Bool { s.resolved || !(s.author ?? "").isEmpty }

    /// Where the text lays out, in the note's own unrotated space (origin at the frame's top-left).
    static func textRect(_ s: StickyItem) -> Rect {
        let f = s.frame
        let bottom = hasFooter(s) ? padding + footerHeight + 4 : max(padding, fold(width: f.w, height: f.h))
        return Rect(x: padding, y: padding, width: max(0, f.w - 2 * padding), height: max(0, f.h - padding - bottom))
    }

    /// A rect of the note's own unrotated space (origin at the frame's top-left) as a page frame, turned with the note
    /// about the note's centre (the inverse of `local(_:in:)`).
    static func pageFrame(_ r: Rect, in f: Frame) -> Frame {
        let c = f.center
        let dx = r.midX - f.w / 2, dy = r.midY - f.h / 2
        let cs = cos(f.rotation), sn = sin(f.rotation)
        let cx = c.x + dx * cs - dy * sn, cy = c.y + dx * sn + dy * cs
        return Frame(x: cx - r.width / 2, y: cy - r.height / 2, w: r.width, h: r.height, rotation: f.rotation)
    }

    /// The icon a collapsed note is drawn as, at the frame's top-left, in page space.
    static func iconFrame(_ s: StickyItem) -> Frame {
        let side = iconSide(s.frame)
        return pageFrame(Rect(x: 0, y: 0, width: side, height: side), in: s.frame)
    }

    /// Where the note's text lays out on the page (`content.textLayouts`); nil while collapsed, when no text shows.
    static func textLayout(_ s: StickyItem) -> TextLayoutInfo? {
        guard !s.collapsed else { return nil }
        return TextLayoutInfo(container: pageFrame(textRect(s), in: s.frame), base: textBase)
    }

    /// A note whose top-left corner is `at`, kept on the page when the page is big enough (boards are infinite).
    static func frame(topLeft at: Point, pageSize: PageSize?) -> Frame {
        var x = at.x, y = at.y
        if let s = pageSize {
            if s.width >= noteSide { x = min(max(x, 0), s.width - noteSide) }
            if s.height >= noteSide { y = min(max(y, 0), s.height - noteSide) }
        }
        return Frame(x: x, y: y, w: noteSide, h: noteSide)
    }

    /// A note centred on `p` (the tool: the note lands under the finger), kept on the page.
    static func frame(centredOn p: Point, pageSize: PageSize?) -> Frame {
        frame(topLeft: Point(p.x - noteSide / 2, p.y - noteSide / 2), pageSize: pageSize)
    }

    /// `p` in the note's own unrotated space (origin at the frame's top-left).
    static func local(_ p: Point, in f: Frame) -> Point {
        let c = f.center
        let dx = p.x - c.x, dy = p.y - c.y
        let cs = cos(-f.rotation), sn = sin(-f.rotation)
        return Point(dx * cs - dy * sn + f.w / 2, dx * sn + dy * cs + f.h / 2)
    }

    /// True when a tap at `p` lands on the note as drawn: the whole note, or only its icon when collapsed (the area
    /// `StickyDrawer.hitBounds` gives the canvas). The icon's target grows to `minimumSide` (44 view points at the
    /// current zoom) around it.
    static func hits(_ s: StickyItem, _ p: Point, minimumSide: Double = 0) -> Bool {
        let q = local(p, in: s.frame)
        guard s.collapsed else { return q.x >= 0 && q.y >= 0 && q.x <= s.frame.w && q.y <= s.frame.h }
        let side = iconSide(s.frame)
        let grow = max(0, (minimumSide - side) / 2)
        return q.x >= -grow && q.y >= -grow && q.x <= side + grow && q.y <= side + grow
    }
}

/// Paints a sticky note into any y-down CGContext whose unit is one page point: dry tiles, thumbnails, exports
/// (through `StickyDrawer`) and the editing overlay. Pure and thread-safe. A collapsed note paints only its icon.
enum StickyPainter {
    /// `pixelsPerPoint` sizes the shadow (CoreGraphics shadows are in device pixels). `drawsText: false` leaves the
    /// text out (the editing overlay puts a live text view there).
    static func paint(_ s: StickyItem, in cg: CGContext, pixelsPerPoint: Double, drawsText: Bool = true) {
        let f = s.frame
        guard f.w > 0, f.h > 0, f.w.isFinite, f.h.isFinite else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: CGFloat(f.center.x), y: CGFloat(f.center.y))
        cg.rotate(by: CGFloat(f.rotation))
        cg.translateBy(x: CGFloat(-f.w / 2), y: CGFloat(-f.h / 2))
        if s.resolved {
            cg.setAlpha(0.6)                                   // a resolved note steps back
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if s.collapsed {
            icon(s, side: StickyGeometry.iconSide(f), cg: cg, ppp: pixelsPerPoint)
        } else {
            note(s, cg: cg, ppp: pixelsPerPoint, drawsText: drawsText)
        }
        if s.resolved { cg.endTransparencyLayer() }
    }

    // MARK: Expanded

    private static func note(_ s: StickyItem, cg: CGContext, ppp: Double, drawsText: Bool) {
        let w = s.frame.w, h = s.frame.h
        let k = StickyGeometry.fold(width: w, height: h)
        body(width: w, height: h, fold: k, colour: s.color, cg: cg, ppp: ppp)
        if drawsText && !s.text.isEmpty {
            let r = StickyGeometry.textRect(s).cg
            if r.width > 2 && r.height > 2 {
                let text = RichTextBridge.attributed(s.text, base: StickyGeometry.textBase)
                cg.saveGState()
                cg.clip(to: r)
                UIGraphicsPushContext(cg)
                text.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                UIGraphicsPopContext()
                cg.restoreGState()
            }
        }
        footer(s, width: w, height: h, fold: k, cg: cg)
    }

    /// The square with its bottom-right corner folded over, lifted off the page by a soft shadow.
    private static func body(width w: Double, height h: Double, fold k: Double, colour: RGBA, cg: CGContext, ppp: Double) {
        let outline = CGMutablePath()
        outline.move(to: .zero)
        outline.addLine(to: CGPoint(x: w, y: 0))
        outline.addLine(to: CGPoint(x: w, y: h - k))
        outline.addLine(to: CGPoint(x: w - k, y: h))
        outline.addLine(to: CGPoint(x: 0, y: h))
        outline.closeSubpath()
        cg.saveGState()
        // ponytail: a centred blur reads the same whatever base-space flip the tile or export context has; an offset
        // shadow would need to know it.
        cg.setShadow(offset: .zero, blur: CGFloat(4 * max(ppp, 1)), color: RGBA(0, 0, 0, 64).cgColor)
        cg.setFillColor(colour.cgColor)
        cg.addPath(outline)
        cg.fillPath()
        cg.restoreGState()

        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: w - k, y: h - k))
        flap.addLine(to: CGPoint(x: w, y: h - k))
        flap.addLine(to: CGPoint(x: w - k, y: h))
        flap.closeSubpath()
        cg.setFillColor(shade(colour, 0.84).cgColor)
        cg.addPath(flap)
        cg.fillPath()
        cg.setStrokeColor(RGBA(0, 0, 0, 36).cgColor)
        cg.setLineWidth(0.5)
        cg.move(to: CGPoint(x: w, y: h - k))
        cg.addLine(to: CGPoint(x: w - k, y: h))
        cg.strokePath()
    }

    /// Resolved check and author signature along the bottom edge, clear of the fold.
    private static func footer(_ s: StickyItem, width w: Double, height h: Double, fold k: Double, cg: CGContext) {
        guard StickyGeometry.hasFooter(s) else { return }
        let p = StickyGeometry.padding
        let lineH = StickyGeometry.footerHeight
        let y = h - p - lineH
        var x = p
        if s.resolved {
            check(in: CGRect(x: x, y: y, width: lineH, height: lineH), cg: cg, width: 1.1)
            x += lineH + 4
        }
        if let author = s.author, !author.isEmpty {
            let r = CGRect(x: x, y: y - 1, width: max(0, w - k - x - 2), height: lineH + 2)
            guard r.width > 4 else { return }
            let font = RichTextBridge.font(TextAttributes(size: StickyGeometry.authorSize, italic: true))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: RGBA(0, 0, 0, 150).uiColor]
            UIGraphicsPushContext(cg)
            (author as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: attrs, context: nil)
            UIGraphicsPopContext()
        }
    }

    // MARK: Collapsed

    /// A small note: the same folded square with three text lines, or a check when resolved.
    private static func icon(_ s: StickyItem, side: Double, cg: CGContext, ppp: Double) {
        guard side > 2 else { return }
        body(width: side, height: side, fold: side * 0.3, colour: s.color, cg: cg, ppp: ppp)
        if s.resolved {
            check(in: CGRect(x: side * 0.2, y: side * 0.2, width: side * 0.5, height: side * 0.5), cg: cg,
                  width: side * 0.07)
            return
        }
        cg.saveGState()
        cg.setStrokeColor(RGBA(0, 0, 0, 115).cgColor)
        cg.setLineWidth(CGFloat(side * 0.06))
        cg.setLineCap(.round)
        for (i, end) in [0.72, 0.72, 0.5].enumerated() {
            let y = side * (0.28 + 0.16 * Double(i))
            cg.move(to: CGPoint(x: side * 0.22, y: y))
            cg.addLine(to: CGPoint(x: side * end, y: y))
        }
        cg.strokePath()
        cg.restoreGState()
    }

    private static func check(in r: CGRect, cg: CGContext, width: Double) {
        cg.saveGState()
        cg.setStrokeColor(RGBA(0, 0, 0, 150).cgColor)
        cg.setLineWidth(CGFloat(width))
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokeEllipse(in: r)
        cg.move(to: CGPoint(x: r.minX + r.width * 0.28, y: r.minY + r.height * 0.52))
        cg.addLine(to: CGPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.68))
        cg.addLine(to: CGPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.34))
        cg.strokePath()
        cg.restoreGState()
    }

    /// The colour darkened by `f` (the fold's underside), alpha kept.
    static func shade(_ c: RGBA, _ f: Double) -> RGBA {
        func d(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(v) * f).rounded()))) }
        return RGBA(d(c.r), d(c.g), d(c.b), c.a)
    }
}

/// `ItemDrawer` for `Item.drawKey` "sticky": shadowed square, folded corner, text, author and resolved mark. A
/// collapsed note draws as its icon for every `DrawContext.purpose`, exports included (the spec's "collapsed notes
/// export as icons"); its frame keeps the expanded size, so it takes taps and lasso hits, and dirties tiles, only
/// where the icon is (`hitBounds`, `paintBounds`).
final class StickyDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {
        guard let s = item.sticky else { return }
        StickyPainter.paint(s, in: context.cg, pixelsPerPoint: context.scale)
    }

    /// A collapsed note is hit only on its visible icon; an expanded one on its whole frame (`Item.bounds`).
    func hitBounds(_ item: Item) -> Rect? {
        guard let s = item.sticky, s.collapsed else { return nil }
        return StickyGeometry.iconFrame(s).bounds
    }

    /// A collapsed note paints only its icon and the icon's shadow (within `NibLimits.drawerMargin`); an expanded one
    /// stays within its frame and shadow (the default).
    func paintBounds(_ item: Item) -> Rect? {
        guard let s = item.sticky, s.collapsed else { return nil }
        return StickyGeometry.iconFrame(s).bounds.insetBy(-NibLimits.drawerMargin)
    }
}
