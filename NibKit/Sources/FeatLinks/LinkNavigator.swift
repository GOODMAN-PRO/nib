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

    func follow(_ link: TextLink, from: LinkStop?, ctx: CommandContext) async throws -> LinkFollowResult {
        if let raw = link.url {
            guard let url = URL(string: raw) else { throw NibError(.invalidParams, "'\(raw)' is not a URL", path: "$.url") }
            if url.scheme?.lowercased() == NibFormat.urlScheme {
                let internalLink = RichTextBridge.link(from: url)
                if internalLink.document != nil { return try await follow(internalLink, from: from, ctx: ctx) }
                _ = try await ctx.execute(CommandIDs.appOpenURL, ["url": .string(raw)])
                return LinkFollowResult(kind: "app", target: raw)
            }
            try LinkPolicy.check(url, principal: ctx.principal, path: "$.url")
            openExternal(url)
            return LinkFollowResult(kind: "url", target: url.absoluteString)
        }
        guard let doc = link.document else { throw NibError(.invalidParams, "the link has no target", path: "$") }
        let content = try ctx.workspace.content(doc)
        if let clipID = link.audioClip {
            guard let clip = content.liveAudio.first(where: { $0.id == clipID }) else { throw NibError.notFound("audio clip \(clipID)") }
            if let session = ctx.activeSession, session.document != doc {
                go(to: doc, page: clip.page, from: from, session: session, content: content)
            }
            let ref = NodeRef.audio(doc, clipID).description
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
        go(to: doc, page: page, from: from, session: session, content: content)
        return LinkFollowResult(kind: "page", target: page.map { NodeRef.page(doc, $0).description } ?? NodeRef.document(doc).description)
    }

    /// Shows `doc`/`page` in the session's window, remembering `from` when the jump goes somewhere else.
    func go(to doc: DocumentID, page: PageID?, from: LinkStop?, session: EditorSession, content: DocumentContent) {
        let landing = page ?? (session.document == doc ? session.page : content.livePages.first?.id)
        if let from = from, from != LinkStop(doc: doc, page: landing) { push(from, session) }
        show(doc: doc, page: page, fallback: landing, session: session)
    }

    /// Pops the history and shows the place it held. Stops whose document is gone are dropped.
    @discardableResult
    func back(session: EditorSession) -> LinkStop? {
        var stack = stacks[session.id] ?? []
        let here = currentStop(session)
        var result: LinkStop?
        while let stop = stack.popLast() {
            guard stop != here, let content = try? app?.workspace.content(stop.doc) else { continue }
            var page: PageID?
            if let p = stop.page, let record = content.page(p), !record.deleted { page = p }
            result = LinkStop(doc: stop.doc, page: page)
            show(doc: stop.doc, page: page, fallback: page ?? content.livePages.first?.id, session: session)
            break
        }
        stacks[session.id] = stack
        notify(session)
        return result
    }

    private func push(_ stop: LinkStop, _ session: EditorSession) {
        var stack = stacks[session.id] ?? []
        if stack.last != stop { stack.append(stop) }
        if stack.count > Self.historyLimit { stack.removeFirst(stack.count - Self.historyLimit) }
        stacks[session.id] = stack
        notify(session)
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

    /// Link regions of rich text laid out like a text box: inset by `style.padding`, wrapped to the box width.
    static func regions(text: RichText, style: TextBoxStyle, size: CGSize) -> [Region] {
        let attributed = RichTextBridge.attributed(text, base: style.defaults)
        guard attributed.length > 0 else { return [] }
        let ranges = linkRanges(attributed)
        guard !ranges.isEmpty else { return [] }
        let inset = CGFloat(style.padding)
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, size.width - 2 * inset), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var out: [Region] = []
        for (range, link) in ranges {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rects: [CGRect] = []
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                if rect.width > 0, rect.height > 0 { rects.append(rect.offsetBy(dx: inset, dy: inset)) }
            }
            if !rects.isEmpty { out.append(Region(link: link, rects: rects)) }
        }
        return out
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

    /// The link of a text item under a page point (rotation undone about the box's centre).
    static func link(at point: Point, in item: Item) -> TextLink? {
        guard item.kind == .text, let box = item.text else { return nil }
        let f = box.frame
        let local = Affine.rotation(-f.rotation, about: f.center).apply(point)
        let p = CGPoint(x: local.x - f.x, y: local.y - f.y)
        let reach = CGRect(x: 0, y: 0, width: f.w, height: f.h).insetBy(dx: -slop, dy: -slop)
        guard reach.contains(p) else { return nil }
        var best: (link: TextLink, distance: CGFloat)?
        for region in regions(text: box.text, style: box.style, size: CGSize(width: f.w, height: f.h)) {
            for rect in region.rects where rect.insetBy(dx: -slop, dy: -slop / 2).contains(p) {
                let d = distance(p, rect)
                if best == nil || d < best!.distance { best = (region.link, d) }
            }
        }
        return best?.link
    }

    /// The topmost visible text item's link under a page point.
    @MainActor
    static func link(at point: Point, doc: DocumentID, page: PageID, workspace: Workspace, hiddenLayers: Set<Int>) throws -> TextLink? {
        for item in try workspace.items(doc, page: page).reversed() where item.kind == .text && !hiddenLayers.contains(item.layer) {
            guard item.bounds.insetBy(-Double(slop)).contains(point) else { continue }
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
        // Link rects are in PDF page points; the page may have been sized differently from the PDF page.
        var sx = 1.0
        var sy = 1.0
        if let size = page.size, let pdfSize = pdf.pageSize(url, page: index), pdfSize.width > 0, pdfSize.height > 0 {
            sx = size.width / pdfSize.width
            sy = size.height / pdfSize.height
        }
        let hits = links.filter { l in
            Rect(x: l.rect.x * sx, y: l.rect.y * sy, width: l.rect.width * sx, height: l.rect.height * sy).insetBy(-2).contains(point)
        }
        guard let hit = hits.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) else { return nil }
        if let target = hit.pageIndex,
           let destination = content.livePages.first(where: { p in
               p.background.kind == .pdf && p.background.asset == asset && (p.background.pdfPage ?? 0) == target
           }) {
            return TextLink(document: doc, page: destination.id)
        }
        return hit.url.map { TextLink(url: $0) }
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

    func attach(to host: CanvasHost) {
        self.host = host
        model.action = { [weak self] in self?.returnToPage() }
        guard let view = hosting.view else { return }
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        host.canvasView.addSubview(view)
        observer = NotificationCenter.default.addObserver(forName: LinkNavigator.historyDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func detach(from host: CanvasHost) {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        hosting.view?.removeFromSuperview()
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) { refresh() }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard model.isVisible, let view = hosting.view else { return false }
        return view.frame.contains(viewPoint)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) { returnToPage() }

    private func refresh() {
        guard let host = host, let view = hosting.view else { return }
        let session = host.session
        guard let navigator = host.app.services.get(LinkNavigator.serviceKey, as: LinkNavigator.self),
              let stop = navigator.pendingReturn(session) else {
            model.isVisible = false
            view.isUserInteractionEnabled = false
            return
        }
        model.title = navigator.returnTitle(stop, session: session)
        model.isVisible = true
        view.isUserInteractionEnabled = true
        let canvas = host.canvasView
        let bounds = canvas.bounds
        let available = CGSize(width: max(0, bounds.width - 2 * NibMetrics.chromeInset), height: NibMetrics.hitTarget)
        let fit = hosting.sizeThatFits(in: available)
        let size = CGSize(width: min(fit.width, available.width), height: max(fit.height, NibMetrics.hitTarget))
        let top = bounds.minY + canvas.safeAreaInsets.top + NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.l
        view.frame = CGRect(x: bounds.midX - size.width / 2, y: top, width: size.width, height: size.height)
        canvas.bringSubviewToFront(view)
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
