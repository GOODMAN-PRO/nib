import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatClipboard

/// Pure fragment logic: the JSON format, id / reference / asset remapping, placement and external content.
@MainActor
final class FragmentTests: XCTestCase {
    private func fixtureItems() -> [Item] { Fixtures.sampleContent().1[Fixtures.page1] ?? [] }

    private func fixture(_ id: ElementID) -> Item {
        guard let item = fixtureItems().first(where: { $0.id == id }) else {
            XCTFail("missing fixture item \(id)")
            return Item(kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 1, h: 1)))
        }
        return item
    }

    private func normalized(_ item: Item) -> Item {
        var n = item
        n.rev = .zero
        n.createdBy = nil
        n.deleted = false
        return n
    }

    // MARK: Format

    func testJSONRoundTripPreservesGeometryStylesAndAssets() throws {
        let items = fixtureItems()
        let fragment = Fragment.make(items: items) { $0 == Fixtures.pngAsset ? Fixtures.pngData : nil }
        XCTAssertEqual(fragment.assets, [Fixtures.pngAsset.name: Fixtures.pngData])

        let data = try XCTUnwrap(fragment.encoded())
        let json = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(json["format"], "nib-fragment/1")
        XCTAssertEqual(json["assets"]?[Fixtures.pngAsset.name], JSONValue.string(Fixtures.pngData.base64EncodedString()))
        XCTAssertEqual(json["items"]?.arrayValue?.count, items.count)

        let back = try Fragment.decode(data)
        XCTAssertEqual(back.assets, fragment.assets)
        XCTAssertEqual(back.items.count, items.count)
        for (a, b) in zip(items, back.items) {
            XCTAssertEqual(a.id, b.id)
            XCTAssertEqual(a.kind, b.kind)
            XCTAssertEqual(a.bounds.x, b.bounds.x, accuracy: 0.01)
            XCTAssertEqual(a.bounds.y, b.bounds.y, accuracy: 0.01)
            XCTAssertEqual(a.bounds.width, b.bounds.width, accuracy: 0.01)
            XCTAssertEqual(a.bounds.height, b.bounds.height, accuracy: 0.01)
            if a.kind == .stroke {
                // Points travel as rounded numbers in JSON; style and shape must survive.
                XCTAssertEqual(a.stroke?.style, b.stroke?.style)
                XCTAssertEqual(a.stroke?.points.map { $0.location }, b.stroke?.points.map { $0.location })
            } else {
                XCTAssertEqual(normalized(a), b)
            }
        }
        XCTAssertEqual(back.bounds, fragment.bounds)
    }

    func testDecodingIsLenientAndRefusesOtherVersions() throws {
        let minimal = #"{"items":[{"kind":"text","text":{"frame":{"x":10,"y":20,"w":30,"h":40}}}]}"#
        let fragment = try Fragment.decode(Data(minimal.utf8))
        XCTAssertEqual(fragment.items.first?.kind, .text)
        XCTAssertEqual(fragment.bounds, Rect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertTrue(fragment.assets.isEmpty)

        XCTAssertThrowsError(try Fragment.decode(Data(#"{"format":"nib-fragment/2","items":[]}"#.utf8))) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
        }
        XCTAssertThrowsError(try Fragment.decode(Data(#"{"items":[],"assets":{"a.png":"abc"}}"#.utf8)))
    }

    // MARK: Landing on a page

    func testInstantiateRemintsIDsReassignsZAndRemapsReferences() {
        var inner = Item.makeText(TextBoxItem(frame: Frame(x: 110, y: 210, w: 80, h: 30), text: RichText(plain: "Inside")))
        inner.id = "INNERTEXT001"
        inner.attachedTo = Fixtures.shapeID
        inner.z = "l"                                   // between the shape ("k") and the sticky ("w")
        let source = [fixture(Fixtures.shapeID), fixture(Fixtures.stickyID), fixture(Fixtures.connectorID), inner]
        let fragment = Fragment.make(items: source) { _ in nil }

        let out = fragment.instantiated(translate: Point(10, 20), ids: ["NEWSHAPE0001"], zAfter: "z", layer: 2)

        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0].id, "NEWSHAPE0001")
        XCTAssertEqual(Set(out.map { $0.id }).count, 4)
        XCTAssertTrue(Set(out.map { $0.id }).isDisjoint(with: source.map { $0.id }))

        let connector = out[2].connector
        XCTAssertEqual(connector?.from.item, out[0].id)
        XCTAssertEqual(connector?.to.item, out[1].id)
        XCTAssertEqual(connector?.from.side, 1)
        XCTAssertEqual(connector?.from.point, Point(270, 265))
        XCTAssertEqual(out[3].attachedTo, out[0].id)

        XCTAssertEqual(out[0].shape?.frame.x ?? 0, 110, accuracy: 1e-9)
        XCTAssertEqual(out[0].shape?.frame.y ?? 0, 220, accuracy: 1e-9)
        XCTAssertEqual(out[0].shape?.style, source[0].shape?.style)

        // New z keys sit above zAfter and keep the source's stacking order: shape < inner text < sticky < connector.
        XCTAssertTrue(out.allSatisfy { $0.z > "z" })
        XCTAssertLessThan(out[0].z, out[3].z)
        XCTAssertLessThan(out[3].z, out[1].z)
        XCTAssertLessThan(out[1].z, out[2].z)
        XCTAssertTrue(out.allSatisfy { $0.layer == 2 && $0.rev == .zero && $0.createdBy == nil && !$0.deleted })
    }

    func testReferencesOutsideTheFragmentAreLetGo() {
        var pinned = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 10, h: 10), text: RichText(plain: "x")))
        pinned.attachedTo = "SOMEWHEREELS"
        let out = Fragment(items: [fixture(Fixtures.connectorID), pinned]).instantiated(translate: .zero, zAfter: nil, layer: nil)
        let connector = out[0].connector
        XCTAssertNil(connector?.from.item)
        XCTAssertNil(connector?.from.side)
        XCTAssertEqual(connector?.from.point, Point(260, 245))
        XCTAssertNil(connector?.to.item)
        XCTAssertNil(out[1].attachedTo)
    }

    /// Untrusted fragments may attach in a loop: the item that closes it lets go, the rest stay attached.
    func testAttachmentLoopsAreBroken() {
        func box(_ id: ElementID, attachedTo parent: ElementID) -> Item {
            var n = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 10, h: 10), text: RichText(plain: "x")))
            n.id = id
            n.attachedTo = parent
            return n
        }
        let fragment = Fragment(items: [box("SELFLOOP0001", attachedTo: "SELFLOOP0001"),
                                        box("PAIRLOOPA001", attachedTo: "PAIRLOOPB001"),
                                        box("PAIRLOOPB001", attachedTo: "PAIRLOOPA001")])
        let out = fragment.instantiated(translate: .zero, zAfter: nil, layer: nil)
        XCTAssertNil(out[0].attachedTo)
        XCTAssertNil(out[1].attachedTo)
        XCTAssertEqual(out[2].attachedTo, out[1].id)
    }

    func testExpandCarriesAttachedContentButNotComments() {
        var inner = Item.makeText(TextBoxItem(frame: Frame(x: 110, y: 210, w: 80, h: 30), text: RichText(plain: "Inside")))
        inner.id = "INNERTEXT001"
        inner.attachedTo = Fixtures.shapeID
        var nested = Item.makeSticky(StickyItem(frame: Frame(x: 120, y: 220, w: 20, h: 20)))
        nested.id = "NESTEDSTICK1"
        nested.attachedTo = inner.id
        var pin = Item.makeComment(CommentItem(anchor: Point(150, 240), messages: []))
        pin.attachedTo = Fixtures.shapeID
        let page = fixtureItems() + [inner, nested, pin]

        let chosen = Fragment.expand([Fixtures.shapeID, Fixtures.shapeID], in: page)
        XCTAssertEqual(chosen.map { $0.id }, [Fixtures.shapeID, inner.id, nested.id])
    }

    func testAssetsAreCollectedAndRemapped() {
        var tape = fixture(Fixtures.tapeID)
        tape.stroke?.style.tapePattern = AssetRef("tile.png")
        let glyph = TextRun("x", TextAttributes(attachment: AssetRef("glyph.png")))
        let text = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 20, h: 20),
                                             text: RichText(paragraphs: [Paragraph(runs: [glyph])])))
        let bytes: [String: Data] = [Fixtures.pngAsset.name: Data([1]), "tile.png": Data([2]), "glyph.png": Data([3])]
        let fragment = Fragment.make(items: [fixture(Fixtures.imageID), tape, text]) { bytes[$0.name] }
        XCTAssertEqual(fragment.assets, bytes)

        let map = [Fixtures.pngAsset.name: AssetRef("a.png"), "tile.png": AssetRef("b.png"), "glyph.png": AssetRef("c.png")]
        let out = fragment.instantiated(translate: .zero, zAfter: nil, layer: nil, assets: map)
        XCTAssertEqual(out[0].image?.asset, AssetRef("a.png"))
        XCTAssertEqual(out[1].stroke?.style.tapePattern, AssetRef("b.png"))
        XCTAssertEqual(out[2].text?.text.paragraphs.first?.runs.first?.attrs.attachment, AssetRef("c.png"))
    }

    // MARK: Placement

    func testPlacementCentresClampsAndCascades() {
        let b = Rect(x: 100, y: 100, width: 50, height: 40)
        XCTAssertEqual(Placement.delta(bounds: b, at: Point(300, 300), cascade: .zero, visible: nil, page: nil), Point(175, 180))

        let clamped = Placement.delta(bounds: b, at: Point(590, 5), cascade: .zero, visible: nil, page: .a4)
        XCTAssertEqual(clamped.x + b.maxX, PageSize.a4.width, accuracy: 1e-9)
        XCTAssertEqual(clamped.y + b.minY, 0, accuracy: 1e-9)

        let visible = Rect(x: 0, y: 500, width: 400, height: 300)
        XCTAssertEqual(Placement.delta(bounds: b, at: nil, cascade: .zero, visible: visible, page: nil), Point(75, 530))
        XCTAssertEqual(Placement.delta(bounds: b, at: nil, cascade: Point(20, 20), visible: nil, page: nil), Point(20, 20))

        let shape = fixture(Fixtures.shapeID)
        let copy = shape.transformed(by: .translation(20, 20))
        XCTAssertEqual(Placement.cascadeSteps(probe: shape, existing: [], step: Placement.step, from: 0), 0)
        XCTAssertEqual(Placement.cascadeSteps(probe: shape, existing: [shape], step: Placement.step, from: 0), 1)
        XCTAssertEqual(Placement.cascadeSteps(probe: shape, existing: [shape, copy], step: Placement.step, from: 0), 2)
        XCTAssertEqual(Placement.cascadeSteps(probe: shape, existing: [shape, copy], step: Placement.step, from: 1), 2)
    }

    func testCombineLaysFragmentsOutInARowWithoutIDClashes() throws {
        let one = Fragment(items: [fixture(Fixtures.shapeID)])
        let combined = try XCTUnwrap(Fragment.combine([one, Fragment(items: []), one], gap: 16))
        XCTAssertEqual(combined.items.count, 2)
        XCTAssertNotEqual(combined.items[0].id, combined.items[1].id)
        let first = combined.items[0].bounds
        let second = combined.items[1].bounds
        XCTAssertEqual(first.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(first.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(second.minX, first.maxX + 16, accuracy: 1e-6)
        XCTAssertEqual(second.minY, 0, accuracy: 1e-6)
        XCTAssertLessThan(combined.items[0].z, combined.items[1].z)
        XCTAssertNil(Fragment.combine([]))
    }

    // MARK: External content and text

    func testExternalImagesAndTextBecomeItems() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).pngData { ctx in
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let images = ContentFragments.images([(data: png, ext: "png"), (data: Data([0, 1, 2]), ext: "png")],
                                             maxSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(images.items.count, 1, "undecodable data is skipped")
        let frame = try XCTUnwrap(images.items.first?.image?.frame)
        XCTAssertEqual(frame.w, 400, accuracy: 1e-6)
        XCTAssertEqual(frame.h, 200, accuracy: 1e-6)
        let asset = try XCTUnwrap(images.items.first?.image?.asset)
        XCTAssertEqual(images.assets[asset.name], png)
        XCTAssertEqual(asset.ext, "png")

        let text = ContentFragments.text(RichText(plain: "Hello\nWorld"), style: TextBoxStyle(), width: 300)
        let box = try XCTUnwrap(text.items.first?.text)
        XCTAssertEqual(box.text.plainText, "Hello\nWorld")
        XCTAssertGreaterThan(box.frame.h, 20)
        XCTAssertLessThanOrEqual(box.frame.w, 300)
        XCTAssertFalse(box.style.fullPage)
    }

    func testClipboardTextReadsTopToBottom() {
        let blocks: [(bbox: Rect, text: String)] = [(bbox: Rect(x: 50, y: 50, width: 10, height: 10), text: "third"),
                                                   (bbox: Rect(x: 0, y: 10, width: 10, height: 10), text: "first"),
                                                   (bbox: Rect(x: 0, y: 50, width: 10, height: 10), text: "second")]
        XCTAssertEqual(ClipboardText.join(blocks), "first\nsecond\nthird")
        XCTAssertEqual(ClipboardText.typed(fixture(Fixtures.stickyID)), "Remember")
        XCTAssertNil(ClipboardText.typed(fixture(Fixtures.strokeID)))
        XCTAssertTrue(ClipboardText.isHandwriting(fixture(Fixtures.strokeID)))
        XCTAssertFalse(ClipboardText.isHandwriting(fixture(Fixtures.tapeID)))
    }

    func testRecognisedHandwritingJoinsTypedText() async {
        let stroke = fixture(Fixtures.strokeID)
        let sticky = fixture(Fixtures.stickyID)
        var asked: [String] = []
        let text = await ClipboardText.text(for: [sticky, stroke], doc: Fixtures.docID, page: Fixtures.page1) { refs in
            asked = refs
            return ["text": "hello", "lines": [["text": "hello", "bbox": [72, 118, 80, 10]]]]
        }
        XCTAssertEqual(asked, ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"])
        XCTAssertEqual(text, "hello\nRemember")
    }
}
