import Foundation
import NibContracts

// MARK: - Style presets (T-098)

/// Full-page text style presets. Stored per paragraph in `Paragraph.style`; the family is always the box default
/// (Helvetica), so a preset only sets size and weight.
enum PageTextStyle: String, CaseIterable {
    case title, heading, body, caption

    var size: Double {
        switch self {
        case .title: return 30
        case .heading: return 22
        case .body: return 17
        case .caption: return 13
        }
    }

    var isBold: Bool { self == .title || self == .heading }

    /// What the preset writes onto every run of its paragraphs (bold is cleared for body and caption).
    var attributes: TextAttributes { TextAttributes(size: size, bold: isBold ? true : nil) }

    /// The preset of a paragraph; untagged paragraphs are body text.
    static func of(_ p: Paragraph) -> PageTextStyle { p.style.flatMap { PageTextStyle(rawValue: $0) } ?? .body }

    /// The style of the paragraph Return starts: headings are followed by body text.
    var next: PageTextStyle { isBold ? .body : self }
}

// MARK: - Page text model (pure)

struct PageMargins: Equatable {
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double
}

enum PageTextModel {
    static let fontFamily = "Helvetica"
    static let maxIndent = 6
    /// Gap between a template's margin line and the text.
    static let marginGap: Double = 8

    /// The box style of every full-page text box: no chrome, fixed size, Helvetica body text.
    static func boxStyle() -> TextBoxStyle {
        TextBoxStyle(padding: 0, autoGrow: false, fullPage: true,
                     defaults: TextAttributes(font: fontFamily, size: PageTextStyle.body.size))
    }

    static func isFullPageBox(_ item: Item) -> Bool {
        !item.deleted && item.kind == .text && item.text?.style.fullPage == true
    }

    /// Page-sized minus the template margins; nil for infinite whiteboard boards.
    /// ponytail: margins are page-proportional plus the template's `margin` param (templates publish no text area,
    /// see contract gaps); rotated pages use the unrotated page frame, like every other item.
    static func frame(for page: PageRecord) -> Frame? {
        guard let size = page.size else { return nil }
        let m = margins(page.background, size: size)
        return Frame(x: m.left, y: m.top, w: max(size.width - m.left - m.right, 1), h: max(size.height - m.top - m.bottom, 1))
    }

    static func margins(_ background: Background, size: PageSize) -> PageMargins {
        let side = min(max(size.width * 0.085, 24), 72)
        let top = min(max(size.height * 0.085, 36), 96)
        var m = PageMargins(top: top, left: side, bottom: side, right: side)
        guard let margin = background.template?.params["margin"] else { return m }
        if let points = margin.doubleValue, points > 1, points < size.width / 2 {
            m.left = max(side, points + marginGap)                                   // margin line position in points
        } else if margin.boolValue == true {
            m.left = max(side, 70.87 * size.width / PageSize.a4.width + marginGap)  // the 25 mm rule (DESIGN §3.6)
        }
        return m
    }

    /// Text of several full-page boxes on one page (two devices started typing offline), in z order.
    static func merged(_ boxes: [Item]) -> RichText {
        let texts = boxes.compactMap { $0.text?.text }.filter { !$0.isEmpty }
        guard var out = texts.first else { return boxes.first?.text?.text ?? .empty }
        for t in texts.dropFirst() { out.paragraphs += t.paragraphs }
        return out
    }

    // Paragraph operations; `paragraphs` is clamped to the text.

    static func applying(_ style: PageTextStyle, to paragraphs: Range<Int>, in text: RichText) -> RichText {
        edit(paragraphs, in: text) { p in
            p.style = style.rawValue
            for i in p.runs.indices {
                p.runs[i].attrs.size = style.size
                p.runs[i].attrs.bold = style.isBold ? true : nil
            }
        }
    }

    /// Sets the list kind. With `toggles`, a kind every paragraph already has is removed instead (the bar button and
    /// the shortcuts); the list menu picks a kind outright.
    static func settingList(_ kind: ListKind, paragraphs: Range<Int>, in text: RichText, toggles: Bool = true) -> RichText {
        let range = paragraphs.clamped(to: 0..<text.paragraphs.count)
        let all = toggles && !range.isEmpty && range.allSatisfy { text.paragraphs[$0].list == kind }
        let target: ListKind = all ? .plain : kind
        return edit(range, in: text) { p in
            p.list = target
            if target != .todo { p.checked = false }
        }
    }

    static func indenting(by delta: Int, paragraphs: Range<Int>, in text: RichText) -> RichText {
        edit(paragraphs, in: text) { p in p.indent = min(max(p.indent + delta, 0), maxIndent) }
    }

    static func togglingChecked(_ paragraph: Int, in text: RichText) -> RichText {
        edit(paragraph..<(paragraph + 1), in: text) { p in
            if p.list == .todo { p.checked.toggle() }
        }
    }

    static func rgba(_ ink: NibInk) -> RGBA {
        RGBA(UInt8((ink.hex >> 16) & 0xFF), UInt8((ink.hex >> 8) & 0xFF), UInt8(ink.hex & 0xFF))
    }

    private static func edit(_ paragraphs: Range<Int>, in text: RichText, _ change: (inout Paragraph) -> Void) -> RichText {
        var out = text
        for i in paragraphs.clamped(to: 0..<out.paragraphs.count) { change(&out.paragraphs[i]) }
        return out
    }
}

// MARK: - text.startPageText

/// Creates or opens the page's single full-page text box and hands it to the editor of the invoking window.
struct StartPageText: NibCommand {
    struct Params: Codable {
        var page: String?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
        var created: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "text.startPageText", title: "Start Typing",
        summary: "Create or open the page's one full-page text box (page minus margins, bottom of the z-order) and start typing in it; returns its ref.",
        params: .obj(["page": .str("page ref page:D/P; defaults to the current page of the active window"),
                      "id": .str("your own id for a newly created box, [A-Za-z0-9_-]{1,64}")]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG002"],
                   ["page": "page:FIXTUREDOC01/FIXTUREPG001", "id": "PAGETEXT0001"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try target(p.page, ctx)
        var chosen: ElementID?
        if let id = p.id {
            guard NibID.isValid(id) else { throw NibError.invalid("id must be 1-64 of [A-Za-z0-9_-]", path: "$.id") }
            chosen = NibID(id)
        }
        let layer = ctx.activeSession?.activeLayer ?? 0
        let (box, created) = try ctx.mutate { tx in
            try ensureBox(tx, doc: doc, page: page, id: chosen, layer: layer)
        }
        if ctx.principal.isUser, !ctx.dryRun, let session = ctx.activeSession, session.document == doc {
            PageTextEditor.begin(box, doc: doc, page: page, session: session)
        }
        return Output(ref: NodeRef.item(doc, page, box.id).description, created: created)
    }

    static func target(_ ref: String?, _ ctx: CommandContext) throws -> (DocumentID, PageID) {
        if let ref = ref {
            guard case let .page(doc, page)? = NodeRef(ref) else {
                throw NibError.invalid("expected a page ref like page:D/P", path: "$.page")
            }
            return (doc, page)
        }
        guard let session = ctx.activeSession, let doc = session.document, let page = session.page else {
            throw NibError(.invalidParams, "no page given and no page is open", path: "$.page",
                           hint: "pass page: \"page:D/P\" (query.context returns the current page)")
        }
        return (doc, page)
    }

    /// The one-box-per-page rule: reuse the existing box (merging duplicates that sync brought in, re-fitting it to
    /// the page and keeping it at the bottom of the z-order), or create it.
    static func ensureBox(_ tx: DocTransaction, doc: DocumentID, page: PageID, id: ElementID?,
                          layer: Int) throws -> (Item, Bool) {
        guard let record = try tx.content(doc).page(page), !record.deleted else {
            throw NibError.notFound("page \(page.raw) in document \(doc.raw)")
        }
        guard let frame = PageTextModel.frame(for: record) else {
            throw NibError(.unsupported, "full-page typing needs a fixed-size page; whiteboard boards are infinite",
                           hint: "use text.createBox on a board")
        }
        let items = try tx.items(doc, page: page)
        let boxes = items.filter(PageTextModel.isFullPageBox)
        if var keep = boxes.first {
            var changed = false
            if boxes.count > 1 {
                keep.text?.text = PageTextModel.merged(boxes)
                for extra in boxes.dropFirst() { try tx.delete(item: extra.id, doc: doc, page: page) }
                changed = true
            }
            if keep.text?.frame != frame {
                keep.text?.frame = frame
                changed = true
            }
            if items.first?.id != keep.id {
                keep.z = try tx.bottomZ(doc, page: page)
                changed = true
            }
            if changed { keep = try tx.put(keep, doc: doc, page: page) }
            return (keep, false)
        }
        if let id = id, items.contains(where: { $0.id == id }) {
            throw NibError(.conflict, "an item with id \(id.raw) already exists on this page", path: "$.id",
                           hint: "choose another id or leave it out")
        }
        let text = RichText(paragraphs: [Paragraph(style: PageTextStyle.body.rawValue)])
        var item = Item.makeText(TextBoxItem(frame: frame, text: text, style: PageTextModel.boxStyle()), layer: layer)
        if let id = id { item.id = id }
        item.locked = true                                   // part of the page: never moved or resized by accident
        item.z = try tx.bottomZ(doc, page: page)
        return (try tx.put(item, doc: doc, page: page), true)
    }
}
