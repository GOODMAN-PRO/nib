import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatLinks

/// Pure link logic: TextKit hit-testing on known layouts, range editing on rich text, URL detection.
@MainActor
final class LinkHitTests: XCTestCase {
    private let site = TextLink(url: "https://nib.example/docs")

    private func linked(_ plain: String, _ range: NSRange, _ link: TextLink) -> RichText {
        LinkText.setLink(link, in: RichText(plain: plain), range: range)
    }

    private func box(_ text: RichText, _ frame: Frame) -> Item {
        Item(kind: .text, text: TextBoxItem(frame: frame, text: text, style: TextBoxStyle(padding: 4)))
    }

    /// Text layouts as the text features publish them; only text boxes have one without help.
    private let content = ContentRegistries()

    private func firstRect(_ item: Item, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(LinkHitTester.regions(of: item, content: content).first?.rects.first, file: file, line: line)
    }

    // MARK: Hit testing

    func testLinkRectSitsAfterTheUnlinkedWordsOnAKnownLayout() throws {
        let text = linked("Visit Nib now", NSRange(location: 6, length: 3), site)
        let item = box(text, Frame(x: 0, y: 0, w: 300, h: 60))
        // The container comes from the contracts (text boxes: the frame inset by the style's padding).
        XCTAssertEqual(content.textLayout(for: item)?.container, Frame(x: 4, y: 4, w: 292, h: 52))
        let regions = LinkHitTester.regions(of: item, content: content)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.link, site)
        let rect = try XCTUnwrap(regions.first?.rects.first)
        let font = RichTextBridge.font(TextAttributes())
        let lead = ("Visit " as NSString).size(withAttributes: [.font: font]).width
        let word = ("Nib" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(rect.minX, 4 + lead, accuracy: 1)
        XCTAssertEqual(rect.width, word, accuracy: 1.5)
        XCTAssertEqual(rect.minY, 4, accuracy: 1)
        XCTAssertGreaterThan(rect.height, 15)
    }

    func testHitFollowsTheLinkAndMissesEverythingElse() throws {
        let item = box(linked("Visit Nib now", NSRange(location: 6, length: 3), site), Frame(x: 100, y: 200, w: 300, h: 60))
        let rect = try firstRect(item)
        let centre = Point(Double(rect.midX), Double(rect.midY))
        XCTAssertEqual(LinkHitTester.link(at: centre, in: item, content: content), site)
        // A fingertip just past the last glyph still counts.
        XCTAssertEqual(LinkHitTester.link(at: Point(Double(rect.maxX) + 4, centre.y), in: item, content: content), site)
        // "Visit", the empty area below the line, and outside the box.
        XCTAssertNil(LinkHitTester.link(at: Point(100 + 4 + 2, centre.y), in: item, content: content))
        XCTAssertNil(LinkHitTester.link(at: Point(centre.x, 200 + 50), in: item, content: content))
        XCTAssertNil(LinkHitTester.link(at: Point(20, 20), in: item, content: content))
    }

    func testAnAutoGrowingBoxIsHitBelowAStaleFrameHeight() throws {
        // Three lines in a frame one line tall: F026 paints an auto-growing box as tall as its text needs.
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("One")]), Paragraph(runs: [TextRun("Two")]),
                                         Paragraph(runs: [TextRun("Three "), TextRun("link", TextAttributes(link: site))])])
        let frame = Frame(x: 100, y: 200, w: 300, h: 20)
        let grows = box(text, frame)
        let laid = LinkHitTester.layout(text: text, base: TextBoxStyle(padding: 4).defaults, width: 292)
        XCTAssertGreaterThan(laid.textHeight, 3 * 15)
        let rect = try firstRect(grows)
        XCTAssertGreaterThan(Double(rect.minY), frame.y + frame.h + Double(LinkHitTester.slop))
        let point = Point(Double(rect.midX), Double(rect.midY))
        XCTAssertTrue(LinkHitTester.mayHit(point, grows, content: content))
        XCTAssertEqual(LinkHitTester.link(at: point, in: grows, content: content), site)

        // A fixed-height box clips its text at the frame, so the hidden link is not there to tap.
        let fixed = Item(kind: .text, text: TextBoxItem(frame: frame, text: text, style: TextBoxStyle(padding: 4, autoGrow: false)))
        XCTAssertFalse(LinkHitTester.mayHit(point, fixed, content: content))
        XCTAssertNil(LinkHitTester.link(at: point, in: fixed, content: content))
    }

    func testStickyNotesAreHitOnceTheirFeaturePublishesALayout() throws {
        let text = linked("Visit Nib now", NSRange(location: 0, length: 13), site)
        let sticky = Item(kind: .sticky, sticky: StickyItem(frame: Frame(x: 0, y: 0, w: 200, h: 200), text: text))
        XCTAssertFalse(LinkHitTester.mayHit(Point(20, 20), sticky, content: content))
        XCTAssertNil(LinkHitTester.link(at: Point(20, 20), in: sticky, content: content))

        content.textLayouts.register(TextLayoutDescriptor(key: ItemKind.sticky.rawValue, owner: "tests") { item in
            item.sticky.map { f in TextLayoutInfo(container: Frame(x: f.frame.x + 12, y: f.frame.y + 12, w: f.frame.w - 24, h: f.frame.h - 24)) }
        })
        let rect = try firstRect(sticky)
        XCTAssertEqual(rect.minX, 12, accuracy: 0.5)
        XCTAssertEqual(rect.minY, 12, accuracy: 0.5)
        let point = Point(Double(rect.midX), Double(rect.midY))
        XCTAssertTrue(LinkHitTester.mayHit(point, sticky, content: content))
        XCTAssertEqual(LinkHitTester.link(at: point, in: sticky, content: content), site)
    }

    func testShapeLabelsAreHitWhereTheirCentredTextSits() throws {
        content.textLayouts.register(TextLayoutDescriptor(key: ItemKind.shape.rawValue, owner: "tests") { item in
            item.shape.map { s in TextLayoutInfo(container: s.frame, base: TextAttributes(size: 24), centredVertically: true) }
        })
        let label = linked("Go", NSRange(location: 0, length: 2), site)
        let shape = Item(kind: .shape, shape: ShapeItem(shape: .ellipse, frame: Frame(x: 50, y: 50, w: 200, h: 120), text: label))
        let rect = try firstRect(shape)
        // Centred top to bottom in the container, at the base size the shape feature asks for.
        XCTAssertEqual(Double(rect.midY), 110, accuracy: 2)
        XCTAssertGreaterThan(rect.height, 24)
        XCTAssertEqual(LinkHitTester.link(at: Point(Double(rect.midX), Double(rect.midY)), in: shape, content: content), site)
        XCTAssertNil(LinkHitTester.link(at: Point(Double(rect.midX), 60), in: shape, content: content))
    }

    func testRotatedBoxIsHitInItsOwnFrame() throws {
        let item = box(linked("Visit Nib now", NSRange(location: 6, length: 3), site),
                       Frame(x: 100, y: 100, w: 300, h: 60, rotation: .pi / 2))
        let f = try XCTUnwrap(item.text?.frame)
        let rect = try firstRect(item)
        let unrotated = Point(Double(rect.midX), Double(rect.midY))
        let onPage = Affine.rotation(f.rotation, about: f.center).apply(unrotated)
        XCTAssertEqual(LinkHitTester.link(at: onPage, in: item, content: content), site)
        XCTAssertNil(LinkHitTester.link(at: unrotated, in: item, content: content))
    }

    func testAWrappedLinkHasOneRectPerLine() {
        let url = "https://example.com/a/rather/long/path/that/wraps/over/lines"
        let text = linked(url, NSRange(location: 0, length: (url as NSString).length), TextLink(url: url))
        let regions = LinkHitTester.regions(of: box(text, Frame(x: 0, y: 0, w: 120, h: 200)), content: content)
        XCTAssertEqual(regions.count, 1)
        XCTAssertGreaterThanOrEqual(regions.first?.rects.count ?? 0, 2)
    }

    func testListMarkersAreNotPartOfALink() {
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("Alpha", TextAttributes(link: site))], list: .bullet)])
        let ranges = LinkHitTester.linkRanges(RichTextBridge.attributed(text))
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.0, NSRange(location: 2, length: 5))
    }

    // MARK: Rich text ranges

    func testSetLinkSplitsRunsAndKeepsOtherStyling() {
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("Hello ", TextAttributes(bold: true)), TextRun("Nib world")])])
        let out = LinkText.setLink(site, in: text, range: NSRange(location: 4, length: 5))
        XCTAssertEqual(out.plainText, text.plainText)
        let runs = out.paragraphs[0].runs
        XCTAssertEqual(runs.map { $0.text }, ["Hell", "o ", "Nib", " world"])
        XCTAssertNil(runs[0].attrs.link)
        XCTAssertEqual(runs[1].attrs.bold, true)
        XCTAssertEqual(runs[1].attrs.link, site)
        XCTAssertEqual(runs[2].attrs, TextAttributes(link: site))
        XCTAssertNil(runs[3].attrs.link)
        XCTAssertEqual(LinkText.links(in: out).map { $0.range }, [NSRange(location: 4, length: 5)])
    }

    func testLinkingAndUnlinkingKeepTheWritersOwnUnderlineAndColour() {
        let red = RGBA(0xD0, 0x30, 0x30)
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("Styled", TextAttributes(color: red, underline: true)),
                                                          TextRun(" plain")])])
        let linked = LinkText.setLink(site, in: text, range: NSRange(location: 0, length: 12))
        XCTAssertEqual(linked.paragraphs[0].runs.map { $0.attrs },
                       [TextAttributes(color: red, underline: true, link: site), TextAttributes(link: site)])
        let unlinked = LinkText.removeLinks(in: linked, range: NSRange(location: 0, length: 12))
        XCTAssertEqual(unlinked.removed, 1)
        XCTAssertEqual(unlinked.text, text)
    }

    func testRemovingLinksAcrossParagraphsRestoresTheText() {
        let text = RichText(plain: "Hello Nib\nSecond line")
        let linked = LinkText.setLink(site, in: text, range: NSRange(location: 6, length: 9))
        XCTAssertEqual(LinkText.links(in: linked).map { $0.range },
                       [NSRange(location: 6, length: 3), NSRange(location: 10, length: 5)])
        let result = LinkText.removeLinks(in: linked, range: NSRange(location: 0, length: LinkText.length(linked)))
        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(LinkText.removeLinks(in: text, range: NSRange(location: 0, length: 5)).removed, 0)
    }

    func testRangesAreValidatedAndSnappedToWholeCharacters() throws {
        let text = RichText(plain: "Cafe\u{301} menu")
        XCTAssertEqual(try LinkText.range([3, 1], in: text, allowEmpty: false), NSRange(location: 3, length: 2))
        XCTAssertThrowsError(try LinkText.range([8, 9], in: text, allowEmpty: false))
        XCTAssertThrowsError(try LinkText.range([0, 0], in: text, allowEmpty: false))
        XCTAssertThrowsError(try LinkText.range([2], in: text, allowEmpty: true))
        XCTAssertEqual(try LinkText.range([4, 0], in: text, allowEmpty: true), NSRange(location: 4, length: 0))
        XCTAssertEqual(try LinkText.range([10, 0], in: text, allowEmpty: true), NSRange(location: 10, length: 0))
    }

    func testHugeRangesAreRefusedWithoutOverflowing() {
        // Agents and plugins pass any Int the schema's `min: 0` allows; start + length must never be computed.
        let text = RichText(plain: "Hello Nib")
        XCTAssertThrowsError(try LinkText.range([Int.max / 2 + 1, Int.max / 2 + 1], in: text, allowEmpty: false))
        XCTAssertThrowsError(try LinkText.range([Int.max, Int.max], in: text, allowEmpty: false))
        XCTAssertThrowsError(try LinkText.range([1, Int.max], in: text, allowEmpty: false))
        XCTAssertThrowsError(try LinkText.range([Int.max, 0], in: text, allowEmpty: true))
        XCTAssertThrowsError(try LinkText.range([Int.min, 1], in: text, allowEmpty: false))
        XCTAssertEqual(try LinkText.range([6, 3], in: text, allowEmpty: false), NSRange(location: 6, length: 3))
    }

    func testCaretFindsTheLinkAroundIt() {
        let text = linked("Visit Nib now", NSRange(location: 6, length: 3), site)
        XCTAssertEqual(LinkText.link(at: 7, in: text)?.range, NSRange(location: 6, length: 3))
        XCTAssertEqual(LinkText.link(at: 9, in: text)?.range, NSRange(location: 6, length: 3))
        XCTAssertNil(LinkText.link(at: 2, in: text))
    }

    // MARK: Detection and addresses

    func testAutodetectLinksWebAddressesOnce() {
        let text = RichText(plain: "Read https://example.com/docs and www.apple.com today")
        let first = LinkText.autodetect(text)
        XCTAssertEqual(first.urls.count, 2)
        XCTAssertEqual(first.urls.first, "https://example.com/docs")
        XCTAssertEqual(LinkText.links(in: first.text).first?.range, NSRange(location: 5, length: 24))
        XCTAssertEqual(first.text.plainText, text.plainText)
        XCTAssertEqual(LinkText.autodetect(first.text).urls, [])
    }

    func testAutodetectLinksOnlyWebAndMailAddresses() {
        let text = RichText(plain: "Vault obsidian://open?vault=notes and the site https://example.com/x today")
        let result = LinkText.autodetect(text)
        XCTAssertEqual(result.urls, ["https://example.com/x"])
        XCTAssertEqual(LinkText.links(in: result.text).map { $0.link }, [TextLink(url: "https://example.com/x")])
    }

    // MARK: PDF placement

    func testPDFLinksAreAspectFittedAndCentredOnTheNibPage() {
        // A4 on US Letter: scaled by Letter's height, centred left to right (contracts-v2 `backgroundTransform`).
        let letter = PageRecord(size: .letter, background: .ofPDF(AssetRef("a4.pdf"), page: 0)).backgroundTransform(sourceSize: .a4)
        let k = min(612 / 595.28, 792 / 841.89)
        let dx = (612 - 595.28 * k) / 2
        let r = LinkHitTester.onPage(Rect(x: 100, y: 200, width: 50, height: 10), letter)
        XCTAssertEqual(r.x, dx + 100 * k, accuracy: 1e-9)
        XCTAssertEqual(r.y, 200 * k, accuracy: 1e-9)
        XCTAssertEqual(r.width / r.height, 5, accuracy: 1e-9)
        // Same size: identity. Degenerate sizes never divide by zero.
        let same = PageRecord(size: .a4).backgroundTransform(sourceSize: .a4)
        XCTAssertEqual(LinkHitTester.onPage(Rect(x: 1, y: 2, width: 3, height: 4), same), Rect(x: 1, y: 2, width: 3, height: 4))
        let degenerate = PageRecord(size: .a4).backgroundTransform(sourceSize: PageSize(0, 0))
        XCTAssertEqual(LinkHitTester.onPage(Rect(x: 1, y: 2, width: 3, height: 4), degenerate), Rect(x: 1, y: 2, width: 3, height: 4))
    }

    func testPDFLinksTurnWithThePage() {
        // Half a turn on the same size: a rect at the top-left lands at the bottom-right.
        let turned = PageRecord(size: .a4, rotation: 180).backgroundTransform(sourceSize: .a4)
        let r = LinkHitTester.onPage(Rect(x: 10, y: 20, width: 30, height: 40), turned)
        XCTAssertEqual(r.x, PageSize.a4.width - 40, accuracy: 1e-9)
        XCTAssertEqual(r.y, PageSize.a4.height - 60, accuracy: 1e-9)
        XCTAssertEqual(r.width, 30, accuracy: 1e-9)
        XCTAssertEqual(r.height, 40, accuracy: 1e-9)
    }

    func testTypedAddressesAreNormalised() {
        XCTAssertEqual(LinkTarget.normalizedURL("example.com/notes")?.absoluteString, "https://example.com/notes")
        XCTAssertEqual(LinkTarget.normalizedURL(" https://nib.example ")?.absoluteString, "https://nib.example")
        XCTAssertEqual(LinkTarget.normalizedURL("mailto:me@example.com")?.scheme, "mailto")
        XCTAssertNil(LinkTarget.normalizedURL("not a link"))
        XCTAssertNil(LinkTarget.normalizedURL("https://"))
        XCTAssertNil(LinkTarget.normalizedURL("plainword"))
    }

    func testFlatTargetsRoundTripStoredLinks() {
        let page = TextLink(document: Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(LinkTarget(page), LinkTarget(page: "page:FIXTUREDOC01/FIXTUREPG002"))
        let audio = TextLink(document: Fixtures.docID, audioClip: Fixtures.audioID, audioTime: 12)
        XCTAssertEqual(LinkTarget(audio), LinkTarget(clip: "audio:FIXTUREDOC01/FIXTUREAUD01", t: 12))
        XCTAssertEqual(LinkTarget(TextLink(document: Fixtures.docID)), LinkTarget(doc: "doc:FIXTUREDOC01"))
        XCTAssertTrue(LinkTarget().isEmpty)
    }
}
