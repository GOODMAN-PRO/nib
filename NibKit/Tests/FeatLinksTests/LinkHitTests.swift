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

    // MARK: Hit testing

    func testLinkRectSitsAfterTheUnlinkedWordsOnAKnownLayout() throws {
        let text = linked("Visit Nib now", NSRange(location: 6, length: 3), site)
        let regions = LinkHitTester.regions(text: text, style: TextBoxStyle(padding: 4), size: CGSize(width: 300, height: 60))
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
        let rect = try XCTUnwrap(LinkHitTester.regions(text: item.text!.text, style: item.text!.style,
                                                       size: CGSize(width: 300, height: 60)).first?.rects.first)
        let centre = Point(100 + Double(rect.midX), 200 + Double(rect.midY))
        XCTAssertEqual(LinkHitTester.link(at: centre, in: item), site)
        // A fingertip just past the last glyph still counts.
        XCTAssertEqual(LinkHitTester.link(at: Point(100 + Double(rect.maxX) + 4, centre.y), in: item), site)
        // "Visit", the empty area below the line, and outside the box.
        XCTAssertNil(LinkHitTester.link(at: Point(100 + 4 + 2, centre.y), in: item))
        XCTAssertNil(LinkHitTester.link(at: Point(centre.x, 200 + 50), in: item))
        XCTAssertNil(LinkHitTester.link(at: Point(20, 20), in: item))
    }

    func testAnAutoGrowingBoxIsHitBelowAStaleFrameHeight() throws {
        // Three lines in a frame one line tall: F026 paints an auto-growing box as tall as its text needs.
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("One")]), Paragraph(runs: [TextRun("Two")]),
                                         Paragraph(runs: [TextRun("Three "), TextRun("link", TextAttributes(link: site))])])
        let frame = Frame(x: 100, y: 200, w: 300, h: 20)
        let grows = box(text, frame)
        let laid = LinkHitTester.layout(text: text, style: TextBoxStyle(padding: 4), width: 300)
        XCTAssertGreaterThan(laid.needed, 3 * 15)
        let rect = try XCTUnwrap(laid.regions.first?.rects.first)
        XCTAssertGreaterThan(Double(rect.minY), frame.h + Double(LinkHitTester.slop))
        let point = Point(frame.x + Double(rect.midX), frame.y + Double(rect.midY))
        XCTAssertTrue(LinkHitTester.mayHit(point, grows))
        XCTAssertEqual(LinkHitTester.link(at: point, in: grows), site)

        // A fixed-height box clips its text at the frame, so the hidden link is not there to tap.
        let fixed = Item(kind: .text, text: TextBoxItem(frame: frame, text: text, style: TextBoxStyle(padding: 4, autoGrow: false)))
        XCTAssertFalse(LinkHitTester.mayHit(point, fixed))
        XCTAssertNil(LinkHitTester.link(at: point, in: fixed))
    }

    func testOnlyTextBoxesAreHitTested() {
        let text = linked("Visit Nib now", NSRange(location: 0, length: 13), site)
        let sticky = Item(kind: .sticky, sticky: StickyItem(frame: Frame(x: 0, y: 0, w: 200, h: 200), text: text))
        XCTAssertFalse(LinkHitTester.mayHit(Point(20, 20), sticky))
        XCTAssertNil(LinkHitTester.link(at: Point(20, 20), in: sticky))
    }

    func testRotatedBoxIsHitInItsOwnFrame() throws {
        let item = box(linked("Visit Nib now", NSRange(location: 6, length: 3), site),
                       Frame(x: 100, y: 100, w: 300, h: 60, rotation: .pi / 2))
        let f = try XCTUnwrap(item.text?.frame)
        let rect = try XCTUnwrap(LinkHitTester.regions(text: item.text!.text, style: item.text!.style,
                                                       size: CGSize(width: f.w, height: f.h)).first?.rects.first)
        let unrotated = Point(f.x + Double(rect.midX), f.y + Double(rect.midY))
        let onPage = Affine.rotation(f.rotation, about: f.center).apply(unrotated)
        XCTAssertEqual(LinkHitTester.link(at: onPage, in: item), site)
        XCTAssertNil(LinkHitTester.link(at: unrotated, in: item))
    }

    func testAWrappedLinkHasOneRectPerLine() {
        let url = "https://example.com/a/rather/long/path/that/wraps/over/lines"
        let text = linked(url, NSRange(location: 0, length: (url as NSString).length), TextLink(url: url))
        let regions = LinkHitTester.regions(text: text, style: TextBoxStyle(padding: 4), size: CGSize(width: 120, height: 200))
        XCTAssertEqual(regions.count, 1)
        XCTAssertGreaterThanOrEqual(regions.first?.rects.count ?? 0, 2)
    }

    func testListMarkersAreNotPartOfALink() {
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("Alpha", TextAttributes(link: site))], list: .bullet)])
        let ranges = LinkHitTester.linkRanges(RichTextBridge.attributed(text))
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.0, NSRange(location: 2, length: 5))
    }

    func testTextViewSelectionMapsBackToModelText() {
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("Alpha")], list: .bullet),
                                         Paragraph(runs: [TextRun("Beta")], list: .bullet)])
        let attributed = RichTextBridge.attributed(text)
        XCTAssertEqual(attributed.string, "• Alpha\n• Beta")
        let range = LinkSelection.plainRange(NSRange(location: 10, length: 4), in: attributed)
        XCTAssertEqual(range, NSRange(location: 6, length: 4))
        XCTAssertEqual((text.plainText as NSString).substring(with: range), "Beta")
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
        // A4 on US Letter: scaled by Letter's height, centred left to right (F024's PDFPagePlacement).
        let letter = LinkHitTester.PDFPlacement(pdfSize: .a4, pageSize: .letter)
        let k = min(612 / 595.28, 792 / 841.89)
        XCTAssertEqual(letter.scale, k, accuracy: 1e-9)
        XCTAssertEqual(letter.dx, (612 - 595.28 * k) / 2, accuracy: 1e-9)
        XCTAssertEqual(letter.dy, 0, accuracy: 1e-9)
        let r = letter.rect(Rect(x: 100, y: 200, width: 50, height: 10))
        XCTAssertEqual(r.x, letter.dx + 100 * k, accuracy: 1e-9)
        XCTAssertEqual(r.y, 200 * k, accuracy: 1e-9)
        XCTAssertEqual(r.width / r.height, 5, accuracy: 1e-9)
        // Same size: identity. Degenerate sizes never divide by zero.
        XCTAssertEqual(LinkHitTester.PDFPlacement(pdfSize: .a4, pageSize: .a4).rect(Rect(x: 1, y: 2, width: 3, height: 4)),
                       Rect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(LinkHitTester.PDFPlacement(pdfSize: PageSize(0, 0), pageSize: .a4), .identity)
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
