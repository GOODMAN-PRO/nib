import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - History

/// A place a window was when it followed a link.
struct LinkStop: Equatable {
    var doc: DocumentID
    var page: PageID?

    var ref: String { page.map { NodeRef.page(doc, $0).description } ?? NodeRef.document(doc).description }
}

/// What following a link did ("url", "page", "audio" or "app" for other nib:// links) and where it went.
struct LinkFollowResult: Codable, Equatable {
    var kind: String
    var target: String
}

/// Follows links and keeps each window's return-to-page history. One per app, in `services` under `serviceKey`.
@MainActor
final class LinkNavigator {
    static let serviceKey = "links.navigator"
    /// Posted (object: the navigator, userInfo["session"]: session id) whenever a window's history changes.
    static let historyDidChange = Notification.Name("NibLinkHistoryDidChange")
    static let historyLimit = 50

    weak var app: NibApp?
    /// Opens web and other-app addresses outside Nib. Tests replace it; hostless tests never open anything.
    var openExternal: @MainActor (URL) -> Void
    private var stacks: [NibID: [LinkStop]] = [:]

    init(app: NibApp) {
        self.app = app
        openExternal = { [weak app] url in
            guard !NibApp.isHostlessTest else { return }
            if let scene = app?.ui.activeNavigator?.rootViewController?.view.window?.windowScene {
                scene.open(url, options: nil, completionHandler: nil)
            } else {
                UIApplication.shared.open(url)
            }
        }
    }

    static func require(_ services: NibServices) throws -> LinkNavigator {
        guard let navigator = services.get(serviceKey, as: LinkNavigator.self) else { throw NibError.unavailable("link navigation") }
        return navigator
    }

    func history(_ session: EditorSession) -> [LinkStop] { stacks[session.id] ?? [] }

    func currentStop(_ session: EditorSession?) -> LinkStop? {
        guard let session = session, let doc = session.document else { return nil }
        return LinkStop(doc: doc, page: session.page)
    }

    /// Where `link.back` would take the window (stops equal to where it already is are skipped).
    func pendingReturn(_ session: EditorSession) -> LinkStop? {
        let here = currentStop(session)
        return stacks[session.id]?.last { $0 != here }
    }

    // MARK: Following

    /// Follows `link`. Under `ctx.dryRun` (AI previews, plugin dry runs) the link is resolved and checked exactly
    /// the same way, but nothing moves, opens, plays or enters the history.
    func follow(_ link: TextLink, from: LinkStop?, ctx: CommandContext) async throws -> LinkFollowResult {
        let dryRun = ctx.dryRun
        if let raw = link.url {
            guard let url = URL(string: raw) else { throw NibError(.invalidParams, "'\(raw)' is not a URL", path: "$.url") }
            if url.scheme?.lowercased() == NibFormat.urlScheme {
                let internalLink = RichTextBridge.link(from: url)
                if internalLink.document != nil { return try await follow(internalLink, from: from, ctx: ctx) }
                if !dryRun { _ = try await ctx.execute(CommandIDs.appOpenURL, ["url": .string(raw)]) }
                return LinkFollowResult(kind: "app", target: raw)
            }
            try LinkPolicy.check(url, principal: ctx.principal, path: "$.url")
            if !dryRun { openExternal(url) }
            return LinkFollowResult(kind: "url", target: url.absoluteString)
        }
        guard let doc = link.document else { throw NibError(.invalidParams, "the link has no target", path: "$") }
        let content = try ctx.workspace.content(doc)
        if let clipID = link.audioClip {
            guard let clip = content.liveAudio.first(where: { $0.id == clipID }) else { throw NibError.notFound("audio clip \(clipID)") }
            let ref = NodeRef.audio(doc, clipID).description
            guard !dryRun else { return LinkFollowResult(kind: "audio", target: ref) }
            if let session = ctx.activeSession, session.document != doc {
                go(to: doc, page: clip.page, from: from, session: session, content: content)
            }
            var params: [String: JSONValue] = ["clip": .string(ref)]
            if let t = link.audioTime { params["t"] = .number(max(0, t)) }
            _ = try await ctx.execute("audio.play", .object(params))
            return LinkFollowResult(kind: "audio", target: ref)
        }
        guard let session = ctx.activeSession else { throw NibError.unavailable("an open window to show the page in") }
        var page: PageID?
        if let p = link.page {
            guard let record = content.page(p), !record.deleted else { throw NibError.notFound("page \(p)") }
            page = record.id
        }
        if !dryRun { go(to: doc, page: page, from: from, session: session, content: content) }
        return LinkFollowResult(kind: "page", target: page.map { NodeRef.page(doc, $0).description } ?? NodeRef.document(doc).description)
    }

    /// Shows `doc`/`page` in the session's window, remembering `from` when the jump goes somewhere else.
    func go(to doc: DocumentID, page: PageID?, from: LinkStop?, session: EditorSession, content: DocumentContent) {
        let landing = page ?? (session.document == doc ? session.page : content.livePages.first?.id)
        if let from = from, from != LinkStop(doc: doc, page: landing) { push(from, session) }
        show(doc: doc, page: page, fallback: landing, session: session)
    }

    /// Pops the history and shows the place it held. Stops whose document is gone are dropped. With `dryRun` it only
    /// reports where it would go: the history and the window stay as they are.
    @discardableResult
    func back(session: EditorSession, dryRun: Bool = false) -> LinkStop? {
        var stack = stacks[session.id] ?? []
        let here = currentStop(session)
        var result: LinkStop?
        var landing: PageID?
        while let stop = stack.popLast() {
            guard stop != here, let content = try? app?.workspace.content(stop.doc) else { continue }
            var page: PageID?
            if let p = stop.page, let record = content.page(p), !record.deleted { page = p }
            result = LinkStop(doc: stop.doc, page: page)
            landing = page ?? content.livePages.first?.id
            break
        }
        guard !dryRun else { return result }
        stacks[session.id] = stack
        pruneClosedSessions(keeping: session)
        if let stop = result { show(doc: stop.doc, page: stop.page, fallback: landing, session: session) }
        notify(session)
        return result
    }

    private func push(_ stop: LinkStop, _ session: EditorSession) {
        var stack = stacks[session.id] ?? []
        if stack.last != stop { stack.append(stop) }
        if stack.count > Self.historyLimit { stack.removeFirst(stack.count - Self.historyLimit) }
        stacks[session.id] = stack
        pruneClosedSessions(keeping: session)
        notify(session)
    }

    /// Drops the history of windows that have closed, so it never outgrows the open windows.
    private func pruneClosedSessions(keeping session: EditorSession) {
        guard let sessions = app?.services.sessions.sessions else { return }
        var open = Set(sessions.map { $0.id })
        open.insert(session.id)
        stacks = stacks.filter { open.contains($0.key) }
    }

    private func notify(_ session: EditorSession) {
        NotificationCenter.default.post(name: Self.historyDidChange, object: self, userInfo: ["session": session.id.raw])
    }

    /// The window's own navigator opens other documents and reveals pages; without a window (headless callers,
    /// tests) the session is moved directly.
    private func show(doc: DocumentID, page: PageID?, fallback: PageID?, session: EditorSession) {
        if let navigator = app?.ui.activeNavigator, navigator.session === session {
            if navigator.activeDocument == doc {
                guard let target = page ?? fallback else { return }
                if let editor = session.editor, editor.documentID == doc {
                    editor.reveal(page: target, rect: nil, animated: false)
                }
                session.page = target
            } else {
                navigator.openDocument(doc, page: page, mode: .replace)
            }
        } else {
            session.document = doc
            session.page = page ?? fallback
        }
    }

    /// "Return to page 3", or "Return to Kinematics, page 3" for another document.
    func returnTitle(_ stop: LinkStop, session: EditorSession) -> String {
        var number: Int?
        if let p = stop.page, let content = try? app?.workspace.content(stop.doc), let index = content.pageIndex(p) {
            number = index + 1
        }
        if stop.doc == session.document {
            if let n = number { return String(localized: "Return to page \(n)") }
            return String(localized: "Return to page")
        }
        let title = app?.services.library?.node(stop.doc)?.title ?? String(localized: "the previous document")
        if let n = number { return String(localized: "Return to \(title), page \(n)") }
        return String(localized: "Return to \(title)")
    }
}

// MARK: - Hit testing

/// Finds the link under a point: typed links in text boxes (laid out with TextKit exactly as `RichTextBridge`
/// renders them) and PDF links on PDF-backed pages (`services.pdf.links`).
@MainActor
enum LinkHitTester {
    /// Extra reach around a link's glyphs, in page points, so a fingertip slightly off the text still follows it.
    static let slop: CGFloat = 6

    struct Region {
        var link: TextLink
        /// Line rects in the box's own (unrotated) coordinates, origin at its top-left.
        var rects: [CGRect]
    }

    /// Link regions of rich text laid out like a text box, plus the height the box needs for all of its text.
    struct Layout {
        var regions: [Region]
        /// Text height plus top and bottom padding: how tall F026's drawer paints an auto-growing box
        /// (`max(frame.h, needed)`), so links below a stale frame height stay reachable.
        var needed: CGFloat
    }

    /// Link regions of rich text laid out like a text box: inset by `style.padding`, wrapped to the box width.
    static func regions(text: RichText, style: TextBoxStyle, size: CGSize) -> [Region] {
        layout(text: text, style: style, width: size.width).regions
    }

    /// TextKit 1 layout at the box width minus its padding, no line-fragment padding (as F026 draws text boxes).
    static func layout(text: RichText, style: TextBoxStyle, width: CGFloat) -> Layout {
        let attributed = RichTextBridge.attributed(text, base: style.defaults)
        guard attributed.length > 0 else { return Layout(regions: [], needed: 0) }
        let ranges = linkRanges(attributed)
        guard !ranges.isEmpty else { return Layout(regions: [], needed: 0) }
        let inset = CGFloat(max(0, style.padding))
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width - 2 * inset), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var out: [Region] = []
        for (range, link) in ranges {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rects: [CGRect] = []
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in
                if rect.width > 0, rect.height > 0 { rects.append(rect.offsetBy(dx: inset, dy: inset)) }
            }
            if !rects.isEmpty { out.append(Region(link: link, rects: rects)) }
        }
        var height = manager.usedRect(for: container).maxY
        let extra = manager.extraLineFragmentRect
        if extra.height > 0 { height = max(height, extra.maxY) }
        height = ceil(max(height, RichTextBridge.font(TextAttributes(), base: style.defaults).lineHeight))
        return Layout(regions: out, needed: height + 2 * inset)
    }

    /// Linked character ranges of an attributed string, skipping generated list markers.
    static func linkRanges(_ s: NSAttributedString) -> [(NSRange, TextLink)] {
        var out: [(NSRange, TextLink)] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length), options: []) { attrs, range, _ in
            guard attrs[.nibListMarker] == nil, let link = linkValue(attrs[.link]) else { return }
            if let last = out.last, last.1 == link, NSMaxRange(last.0) == range.location {
                out[out.count - 1].0.length += range.length
            } else {
                out.append((range, link))
            }
        }
        return out
    }

    static func linkValue(_ value: Any?) -> TextLink? {
        if let url = value as? URL { return RichTextBridge.link(from: url) }
        if let s = value as? String, let url = URL(string: s) { return RichTextBridge.link(from: url) }
        return nil
    }

    /// The link of a text box under a page point. The box is taken as drawn: an auto-growing box is as tall as its
    /// text needs even when its frame is stale, and rotation is undone about the centre of that drawn rect.
    static func link(at point: Point, in item: Item) -> TextLink? {
        guard item.kind == .text, let box = item.text, !LinkText.links(in: box.text).isEmpty else { return nil }
        let f = box.frame
        guard f.w > 0, f.h >= 0 else { return nil }
        let laid = layout(text: box.text, style: box.style, width: CGFloat(f.w))
        guard !laid.regions.isEmpty else { return nil }
        let height = box.style.autoGrow ? max(CGFloat(f.h), laid.needed) : CGFloat(f.h)
        let centre = Point(f.x + f.w / 2, f.y + Double(height) / 2)
        let local = Affine.rotation(-f.rotation, about: centre).apply(point)
        let p = CGPoint(x: local.x - f.x, y: local.y - f.y)
        let reach = CGRect(x: 0, y: 0, width: CGFloat(f.w), height: height).insetBy(dx: -slop, dy: -slop)
        guard reach.contains(p) else { return nil }
        var best: (link: TextLink, distance: CGFloat)?
        for region in laid.regions {
            for rect in region.rects where rect.insetBy(dx: -slop, dy: -slop / 2).contains(p) {
                let d = distance(p, rect)
                if best == nil || d < best!.distance { best = (region.link, d) }
            }
        }
        return best?.link
    }

    /// A cheap test that skips laying out boxes the point cannot be in. An auto-growing box may be drawn taller than
    /// its frame, so only its sides and top bound it (a rotated one is always laid out).
    static func mayHit(_ point: Point, _ item: Item) -> Bool {
        guard item.kind == .text, let box = item.text else { return false }
        let s = Double(slop)
        guard box.style.autoGrow else { return item.bounds.insetBy(-s).contains(point) }
        let f = box.frame
        guard f.rotation == 0 else { return true }
        return point.x >= f.x - s && point.x <= f.x + f.w + s && point.y >= f.y - s
    }

    /// The topmost visible text box's link under a page point.
    @MainActor
    static func link(at point: Point, doc: DocumentID, page: PageID, workspace: Workspace, hiddenLayers: Set<Int>) throws -> TextLink? {
        for item in try workspace.items(doc, page: page).reversed() where item.kind == .text && !hiddenLayers.contains(item.layer) {
            guard mayHit(point, item) else { continue }
            if let link = link(at: point, in: item) { return link }
        }
        return nil
    }

    /// The PDF link under a page point on a PDF-backed page. An internal link becomes a link to the page of this
    /// document that shows the destination PDF page; a web link keeps its URL.
    @MainActor
    static func pdfLink(at point: Point, doc: DocumentID, page pageID: PageID, workspace: Workspace,
                        pdf: PDFService?, assets: AssetStore?) throws -> TextLink? {
        let content = try workspace.content(doc)
        guard let page = content.page(pageID), page.background.kind == .pdf, let asset = page.background.asset,
              let pdf = pdf, let url = assets?.url(asset, doc: doc) else { return nil }
        let index = page.background.pdfPage ?? 0
        let links = pdf.links(url, page: index)
        guard !links.isEmpty else { return nil }
        // Link rects are in PDF page points. The renderer and F024's placement aspect-fit the PDF page and centre it
        // on the Nib page, so a page sized differently from the PDF page maps links the same way.
        var placement = PDFPlacement.identity
        if let size = page.size, let pdfSize = pdf.pageSize(url, page: index) {
            placement = PDFPlacement(pdfSize: pdfSize, pageSize: size)
        }
        let hits = links.filter { placement.rect($0.rect).insetBy(-2).contains(point) }
        guard let hit = hits.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) else { return nil }
        if let target = hit.pageIndex,
           let destination = content.livePages.first(where: { p in
               p.background.kind == .pdf && p.background.asset == asset && (p.background.pdfPage ?? 0) == target
           }) {
            return TextLink(document: doc, page: destination.id)
        }
        return hit.url.map { TextLink(url: $0) }
    }

    /// Where a PDF page sits on its Nib page: aspect-fitted and centred (the maths of F024's `PDFPagePlacement`).
    struct PDFPlacement: Equatable {
        var scale: Double
        var dx: Double
        var dy: Double

        static let identity = PDFPlacement(scale: 1, dx: 0, dy: 0)

        init(scale: Double, dx: Double, dy: Double) {
            self.scale = scale
            self.dx = dx
            self.dy = dy
        }

        init(pdfSize: PageSize, pageSize: PageSize) {
            let w = pdfSize.width
            let h = pdfSize.height
            if w > 0, h > 0, pageSize.width > 0, pageSize.height > 0 {
                let k = min(pageSize.width / w, pageSize.height / h)
                scale = k
                dx = (pageSize.width - w * k) / 2
                dy = (pageSize.height - h * k) / 2
            } else {
                scale = 1
                dx = 0
                dy = 0
            }
        }

        func rect(_ r: Rect) -> Rect {
            Rect(x: dx + r.x * scale, y: dy + r.y * scale, width: r.width * scale, height: r.height * scale)
        }
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Return to page pill

@MainActor
final class ReturnToPageModel: ObservableObject {
    @Published var title = ""
    @Published var isVisible = false
    var action: @MainActor () -> Void = {}
}

/// The Clear "Return to page N" pill after an internal link jump (DESIGN.md HUD: 40 pt, 44 pt hit), top centre
/// below the bars, in every mode. It lives on the canvas as an attachment and claims its own touches, so a tap on it
/// never inks or reaches the page.
@MainActor
final class ReturnToPageAttachment: CanvasAttachment {
    private let model = ReturnToPageModel()
    private lazy var hosting: UIHostingController<ReturnToPagePill> = UIHostingController(rootView: ReturnToPagePill(model: model))
    private weak var host: CanvasHost?
    private var observer: NSObjectProtocol?
    private var lastTrigger = Date.distantPast
    /// What the title was made for; it is rebuilt only when the history, the stop or the window's document changes.
    private var titledStop: LinkStop?
    private var titledDocument: DocumentID?
    /// The measured pill size and what it was measured for (title, width available, text size).
    private var measured: CGSize = .zero
    private var measuredFor: (title: String, width: CGFloat, category: UIContentSizeCategory)?

    func attach(to host: CanvasHost) {
        self.host = host
        model.action = { [weak self] in self?.returnToPage() }
        guard let view = hosting.view else { return }
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        host.canvasView.addSubview(view)
        observer = NotificationCenter.default.addObserver(forName: LinkNavigator.historyDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(historyChanged: true) }
        }
        refresh(historyChanged: true)
    }

    func detach(from host: CanvasHost) {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        hosting.view?.removeFromSuperview()
        self.host = nil
        titledStop = nil
        titledDocument = nil
        measuredFor = nil
    }

    /// Runs on every scroll and zoom frame: it only repositions the pill unless something it shows has changed.
    func canvasDidChange(_ host: CanvasHost) { refresh(historyChanged: false) }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard model.isVisible, let view = hosting.view else { return false }
        return view.frame.contains(viewPoint)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) { returnToPage() }

    private func refresh(historyChanged: Bool) {
        guard let host = host, let view = hosting.view else { return }
        let session = host.session
        guard let navigator = host.app.services.get(LinkNavigator.serviceKey, as: LinkNavigator.self),
              let stop = navigator.pendingReturn(session) else {
            if model.isVisible { model.isVisible = false }
            if view.isUserInteractionEnabled { view.isUserInteractionEnabled = false }
            titledStop = nil
            return
        }
        if historyChanged || stop != titledStop || session.document != titledDocument {
            titledStop = stop
            titledDocument = session.document
            let title = navigator.returnTitle(stop, session: session)
            if title != model.title { model.title = title }
        }
        if !model.isVisible { model.isVisible = true }
        if !view.isUserInteractionEnabled { view.isUserInteractionEnabled = true }
        position(view, in: host.canvasView)
    }

    private func position(_ view: UIView, in canvas: UIView) {
        let bounds = canvas.bounds
        let available = CGSize(width: max(0, bounds.width - 2 * NibMetrics.chromeInset), height: NibMetrics.hitTarget)
        let category = canvas.traitCollection.preferredContentSizeCategory
        let stale = measuredFor.map { $0.title != model.title || $0.width != available.width || $0.category != category } ?? true
        if stale {
            let fit = hosting.sizeThatFits(in: available)
            measured = CGSize(width: min(fit.width, available.width), height: max(fit.height, NibMetrics.hitTarget))
            measuredFor = (title: model.title, width: available.width, category: category)
        }
        let top = bounds.minY + canvas.safeAreaInsets.top + NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.l
        let frame = CGRect(x: bounds.midX - measured.width / 2, y: top, width: measured.width, height: measured.height)
        if view.frame != frame { view.frame = frame }
        if canvas.subviews.last !== view { canvas.bringSubviewToFront(view) }
    }

    /// The button and the claimed touch can both report the same tap; one return per tap.
    private func returnToPage() {
        let now = Date()
        guard now.timeIntervalSince(lastTrigger) > 0.4, let host = host else { return }
        lastTrigger = now
        host.app.perform(LinkBack.descriptor.id, [:], session: host.session)
    }
}

struct ReturnToPagePill: View {
    @ObservedObject var model: ReturnToPageModel

    var body: some View {
        Button {
            model.action()
        } label: {
            HStack(spacing: NibSpacing.xs) {
                Image(nib: .back)
                    .font(NibFont.glyph(.bar))
                    .accessibilityHidden(true)
                Text(model.title)
                    .font(NibFont.button)
                    .lineLimit(1)
            }
            .foregroundStyle(NibColor.label)
            .padding(.leading, NibSpacing.s)
            .padding(.trailing, NibSpacing.l)
            .frame(height: NibMetrics.hudHeight)
            .droplet("links.returnToPage", style: .hud)
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Capsule())
        }
        .buttonStyle(NibPressStyle(shape: Capsule()))
        .nibChromeTypeCap()
        .opacity(model.isVisible ? 1 : 0)
        .animation(model.isVisible ? NibMotion.enter : NibMotion.exit, value: model.isVisible)
        .accessibilityLabel(model.title)
        .accessibilityHint(String(localized: "Goes back to where you were before you followed the link."))
        .accessibilityHidden(!model.isVisible)
    }
}
