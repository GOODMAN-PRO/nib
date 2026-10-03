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
/// It publishes every history change (the Return-to-page pill observes it) and asks the chrome to re-evaluate the
/// pill's visibility in that window (`UIRegistries.setNeedsChromeUpdate`).
@MainActor
final class LinkNavigator: ObservableObject {
    static let serviceKey = "links.navigator"
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

    static func of(_ app: NibApp) -> LinkNavigator? { app.services.get(serviceKey, as: LinkNavigator.self) }

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
                go(to: doc, page: clip.page, from: from, session: session, content: content, navigator: ctx.navigator)
            }
            // §6.1: media time is seconds, the clip an audio ref.
            var params: [String: JSONValue] = ["clip": .string(ref)]
            if let t = link.audioTime { params["t"] = .number(max(0, t)) }
            _ = try await ctx.execute(CommandIDs.audioPlay, .object(params))
            return LinkFollowResult(kind: "audio", target: ref)
        }
        guard let session = ctx.activeSession else { throw NibError.unavailable("an open window to show the page in") }
        var page: PageID?
        if let p = link.page {
            guard let record = content.page(p), !record.deleted else { throw NibError.notFound("page \(p)") }
            page = record.id
        }
        if !dryRun { go(to: doc, page: page, from: from, session: session, content: content, navigator: ctx.navigator) }
        return LinkFollowResult(kind: "page", target: page.map { NodeRef.page(doc, $0).description } ?? NodeRef.document(doc).description)
    }

    /// Shows `doc`/`page` in the session's window, remembering `from` when the jump goes somewhere else.
    func go(to doc: DocumentID, page: PageID?, from: LinkStop?, session: EditorSession, content: DocumentContent,
            navigator: SceneNavigator?) {
        let landing = page ?? (session.document == doc ? session.page : content.livePages.first?.id)
        if let from = from, from != LinkStop(doc: doc, page: landing) { push(from, session) }
        show(doc: doc, page: page, fallback: landing, session: session, navigator: navigator)
    }

    /// Pops the history and shows the place it held. Stops whose document is gone are dropped. With `dryRun` it only
    /// reports where it would go: the history and the window stay as they are.
    @discardableResult
    func back(session: EditorSession, navigator: SceneNavigator?, workspace: Workspace, dryRun: Bool = false) -> LinkStop? {
        var stack = stacks[session.id] ?? []
        let here = currentStop(session)
        var result: LinkStop?
        var landing: PageID?
        while let stop = stack.popLast() {
            guard stop != here, let content = try? workspace.content(stop.doc) else { continue }
            var page: PageID?
            if let p = stop.page, let record = content.page(p), !record.deleted { page = p }
            result = LinkStop(doc: stop.doc, page: page)
            landing = page ?? content.livePages.first?.id
            break
        }
        guard !dryRun else { return result }
        stacks[session.id] = stack
        pruneClosedSessions(keeping: session)
        if let stop = result { show(doc: stop.doc, page: stop.page, fallback: landing, session: session, navigator: navigator) }
        changed(session)
        return result
    }

    private func push(_ stop: LinkStop, _ session: EditorSession) {
        var stack = stacks[session.id] ?? []
        if stack.last != stop { stack.append(stop) }
        if stack.count > Self.historyLimit { stack.removeFirst(stack.count - Self.historyLimit) }
        stacks[session.id] = stack
        pruneClosedSessions(keeping: session)
        changed(session)
    }

    /// Drops the history of windows that have closed, so it never outgrows the open windows.
    private func pruneClosedSessions(keeping session: EditorSession) {
        guard let sessions = app?.services.sessions.sessions else { return }
        var open = Set(sessions.map { $0.id })
        open.insert(session.id)
        stacks = stacks.filter { open.contains($0.key) }
    }

    private func changed(_ session: EditorSession) {
        objectWillChange.send()
        app?.ui.setNeedsChromeUpdate(session)
    }

    /// The window's own navigator opens other documents and reveals pages; without one (headless callers, tests, a
    /// command run for another window) the session is moved directly.
    private func show(doc: DocumentID, page: PageID?, fallback: PageID?, session: EditorSession, navigator: SceneNavigator?) {
        if let navigator = navigator, navigator.session === session {
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

/// Finds the link under a point: typed links in any item whose feature publishes where its text lays out
/// (`ContentRegistries.textLayout(for:)`, laid out with TextKit exactly as `RichTextBridge` renders it), and PDF links
/// on PDF-backed pages (`services.pdf.links`, placed with `PageRecord.backgroundTransform`).
@MainActor
enum LinkHitTester {
    /// Fingertip reach around a link's target, in view points: a finger slightly off the text still follows it.
    static let slop: CGFloat = 6

    /// Small glyphs still need a finger-sized target (DESIGN §5). Convert view points to page points so
    /// zooming out does not shrink the control. Keep the existing fingertip tolerance around that target.
    static func hitRect(_ rect: CGRect, zoom: Double = 1) -> CGRect {
        let scale = CGFloat(zoom.isFinite && zoom > 0 ? zoom : 1)
        let minimum = NibMetrics.hitTarget / scale
        return rect.insetBy(dx: -max(0, (minimum - rect.width) / 2),
                            dy: -max(0, (minimum - rect.height) / 2))
            .insetBy(dx: -slop / scale, dy: -slop / scale)
    }

    struct Region {
        var link: TextLink
        /// Line rects in the text container's own (unrotated) coordinates, origin at its top-left.
        var rects: [CGRect]
    }

    /// Link regions of rich text laid out in a container, plus the height of all of the text.
    struct Layout {
        var regions: [Region]
        var textHeight: CGFloat
    }

    /// Where an item's text sits on its page: the container its feature publishes (grown to the text for an
    /// auto-growing text box, whose drawer paints it as tall as the text needs), and the laid-out links.
    struct Placed {
        /// Unrotated container in page points; `rotation` turns it about its centre.
        var box: CGRect
        var rotation: Double
        /// Link rects in `box`'s coordinates (vertical centring applied).
        var regions: [Region]
    }

    /// TextKit 1 layout at the container width, `TextLayoutInfo.lineFragmentPadding` and no container inset (the
    /// contracts-v2 rule every text drawer follows).
    static func layout(text: RichText, base: TextAttributes, width: CGFloat) -> Layout {
        let attributed = RichTextBridge.attributed(text, base: base)
        guard attributed.length > 0 else { return Layout(regions: [], textHeight: 0) }
        let ranges = linkRanges(attributed)
        guard !ranges.isEmpty else { return Layout(regions: [], textHeight: 0) }
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = CGFloat(TextLayoutInfo.lineFragmentPadding)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var out: [Region] = []
        for (range, link) in ranges {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rects: [CGRect] = []
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in
                if rect.width > 0, rect.height > 0 { rects.append(rect) }
            }
            if !rects.isEmpty { out.append(Region(link: link, rects: rects)) }
        }
        var height = manager.usedRect(for: container).maxY
        let extra = manager.extraLineFragmentRect
        if extra.height > 0 { height = max(height, extra.maxY) }
        height = ceil(max(height, RichTextBridge.font(TextAttributes(), base: base).lineHeight))
        return Layout(regions: out, textHeight: height)
    }

    /// The item's text laid out where its feature draws it; nil for items without links or without a published layout.
    static func placed(_ item: Item, content: ContentRegistries) -> Placed? {
        guard let text = ItemText.text(of: item), !LinkText.links(in: text).isEmpty,
              let info = content.textLayout(for: item) else { return nil }
        let c = info.container
        guard c.w > 0, c.h >= 0 else { return nil }
        let laid = layout(text: text, base: info.base, width: CGFloat(c.w))
        guard !laid.regions.isEmpty else { return nil }
        let height = grows(item) ? max(CGFloat(c.h), laid.textHeight) : CGFloat(c.h)
        let top = info.centredVertically ? (height - laid.textHeight) / 2 : 0
        let regions = laid.regions.map { Region(link: $0.link, rects: $0.rects.map { $0.offsetBy(dx: 0, dy: top) }) }
        return Placed(box: CGRect(x: c.x, y: c.y, width: c.w, height: Double(height)), rotation: c.rotation, regions: regions)
    }

    /// Link regions of an item with their rects in page points (before the container's rotation).
    static func regions(of item: Item, content: ContentRegistries) -> [Region] {
        guard let placed = placed(item, content: content) else { return [] }
        return placed.regions.map { region in
            Region(link: region.link, rects: region.rects.map { $0.offsetBy(dx: placed.box.minX, dy: placed.box.minY) })
        }
    }

    /// An auto-growing text box is painted as tall as its text needs, even while its frame height is stale.
    static func grows(_ item: Item) -> Bool { item.kind == .text && (item.text?.style.autoGrow ?? false) }

    /// The link of an item under a page point. Rotation is undone about the centre of the text container as drawn.
    static func link(at point: Point, in item: Item, content: ContentRegistries, zoom: Double = 1) -> TextLink? {
        guard let placed = placed(item, content: content) else { return nil }
        let box = placed.box
        let centre = Point(Double(box.midX), Double(box.midY))
        let local = Affine.rotation(-placed.rotation, about: centre).apply(point)
        let p = CGPoint(x: local.x - Double(box.minX), y: local.y - Double(box.minY))
        let visible = CGRect(origin: .zero, size: box.size)
        var best: (link: TextLink, distance: CGFloat)?
        for region in placed.regions {
            for glyphRect in region.rects {
                // Enlarge only visible text; a fixed-height container must not expose clipped links.
                let rect = glyphRect.intersection(visible)
                guard !rect.isNull, !rect.isEmpty, hitRect(rect, zoom: zoom).contains(p) else { continue }
                let d = distance(p, rect)
                if best == nil || d < best!.distance { best = (region.link, d) }
            }
        }
        return best?.link
    }

    /// A cheap test that skips laying out items the point cannot be in. An auto-growing box may be drawn taller than
    /// its container, so only its sides and top bound it (a rotated container is always laid out).
    static func mayHit(_ point: Point, _ item: Item, content: ContentRegistries, zoom: Double = 1) -> Bool {
        guard ItemText.text(of: item) != nil, let info = content.textLayout(for: item) else { return false }
        let c = info.container
        let scale = zoom.isFinite && zoom > 0 ? zoom : 1
        let s = Double(NibMetrics.hitTarget / 2 + slop) / scale
        guard c.rotation == 0 else { return true }
        guard point.x >= c.x - s, point.x <= c.x + c.w + s, point.y >= c.y - s else { return false }
        return grows(item) || point.y <= c.y + c.h + s
    }

    /// The topmost visible item's link under a page point.
    static func link(at point: Point, doc: DocumentID, page: PageID, workspace: Workspace, content: ContentRegistries,
                     hiddenLayers: Set<Int>, zoom: Double = 1) throws -> TextLink? {
        for item in try workspace.items(doc, page: page).reversed() where !hiddenLayers.contains(item.layer) {
            guard mayHit(point, item, content: content, zoom: zoom) else { continue }
            if let link = link(at: point, in: item, content: content, zoom: zoom) { return link }
        }
        return nil
    }

    /// The PDF link under a page point on a PDF-backed page. An internal link becomes a link to the page of this
    /// document that shows the destination PDF page; a web link keeps its URL.
    static func pdfLink(at point: Point, doc: DocumentID, page pageID: PageID, workspace: Workspace,
                        pdf: PDFService?, assets: AssetStore?) throws -> TextLink? {
        let content = try workspace.content(doc)
        guard let page = content.page(pageID), page.background.kind == .pdf, let asset = page.background.asset,
              let pdf = pdf, let url = assets?.url(asset, doc: doc) else { return nil }
        let index = page.background.pdfPage ?? 0
        let links = pdf.links(url, page: index)
        guard !links.isEmpty else { return nil }
        // Link rects are in PDF page points (top-left origin). The page shows the PDF page turned by its rotation,
        // aspect-fitted and centred (contracts-v2 `PageRecord.backgroundTransform`, as the renderer draws it).
        let transform = pdf.pageSize(url, page: index).map { page.backgroundTransform(sourceSize: $0) } ?? .identity
        let hits = links.filter { onPage($0.rect, transform).insetBy(-2).contains(point) }
        guard let hit = hits.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) else { return nil }
        if let target = hit.pageIndex,
           let destination = content.livePages.first(where: { p in
               p.background.kind == .pdf && p.background.asset == asset && (p.background.pdfPage ?? 0) == target
           }) {
            return TextLink(document: doc, page: destination.id)
        }
        return hit.url.map { TextLink(url: $0) }
    }

    /// A PDF rect in page points: the bounds of its corners through the page's background transform (exact for the
    /// quarter turns `PageRecord.rotation` allows).
    static func onPage(_ r: Rect, _ transform: Affine) -> Rect {
        let corners = [Point(r.x, r.y), Point(r.x + r.width, r.y), Point(r.x, r.y + r.height),
                       Point(r.x + r.width, r.y + r.height)].map { transform.apply($0) }
        let xs = corners.map { $0.x }
        let ys = corners.map { $0.y }
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return Rect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
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

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Return to page pill

/// The "Return to page N" pill after an internal link jump: a contracts-v2 chrome overlay (`.bottom`, `.pill`), so the
/// document chrome places it in the window's droplet container, on the Clear pill surface, and fades it while the
/// Pencil is down. Shown in every document window whose history has somewhere to return to.
enum ReturnToPageOverlay {
    static let id = "link.returnToPage"

    static func descriptor(owner: String) -> ChromeOverlayDescriptor {
        ChromeOverlayDescriptor(
            id: id, owner: owner, placement: .bottom, surface: .pill, order: 400, recedesWhileWriting: true,
            isVisible: { ctx in LinkNavigator.of(ctx.app)?.pendingReturn(ctx.session) != nil },
            makeView: { ctx in
                guard let navigator = LinkNavigator.of(ctx.app) else { return AnyView(EmptyView()) }
                return AnyView(ReturnToPagePill(navigator: navigator, session: ctx.session, app: ctx.app))
            })
    }
}

/// The pill's content; the chrome gives it its surface, type cap and entrance. It follows the window's history and
/// document itself, so its title stays current while the chrome keeps the same overlay on screen.
struct ReturnToPagePill: View {
    @ObservedObject var navigator: LinkNavigator
    @ObservedObject var session: EditorSession
    let app: NibApp

    var title: String {
        navigator.pendingReturn(session).map { navigator.returnTitle($0, session: session) } ?? ""
    }

    var body: some View {
        let title = self.title
        Button {
            app.perform(CommandIDs.linkBack, [:], session: session)
        } label: {
            HStack(spacing: NibSpacing.xs) {
                Image(nib: .back)
                    .font(NibFont.glyph(.bar))
                    .accessibilityHidden(true)
                Text(title)
                    .font(NibFont.button)
                    .lineLimit(1)
            }
            .foregroundStyle(NibColor.label)
            .padding(.leading, NibSpacing.s)
            .padding(.trailing, NibSpacing.l)
            .frame(minHeight: NibMetrics.hudHeight)
            .contentShape(Capsule())
        }
        .accessibilityIdentifier("cmd." + CommandIDs.linkBack)
        .buttonStyle(NibPressStyle(shape: Capsule()))
        .accessibilityLabel(title)
        .accessibilityHint(String(localized: "Goes back to where you were before you followed the link."))
    }
}
