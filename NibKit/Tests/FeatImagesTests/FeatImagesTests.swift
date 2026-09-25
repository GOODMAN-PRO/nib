import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import NibContracts
import NibTesting
@testable import FeatImages

@MainActor
final class FeatImagesTests: XCTestCase {
    private let image2 = "item:FIXTUREDOC01/FIXTUREPG002/IMGTEST00001"

    // MARK: Commands

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatImagesFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersExactlyItsCommandsAndTool() {
        let h = Harness(features: [FeatImagesFeature.self])
        let mine = h.app.commands.all().filter { $0.owner == FeatImagesFeature.id }.map { $0.id }
        XCTAssertEqual(Set(mine), ["image.insert", "image.crop", "image.flip", "image.replace", "image.saveToPhotos", "image.pick"])
        XCTAssertNotNil(h.app.ui.canvasTools.get("image"))
        XCTAssertEqual(h.app.ui.toolbar.get("images.tool")?.shortcut, KeyShortcut("i"))
        XCTAssertNotNil(h.app.content.drawers.get("image"))
        let tool = ImageTool()
        XCTAssertFalse(tool.isSticky)
        if case .taps = tool.inputMode {} else { XCTFail("the image tool takes taps") }
    }

    func testInsertCropFlipUndoRoundTrip() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        let before = try h.snapshot()
        let r = try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "asset": "fixture-image.png",
                                                 "frame": [100, 100, 200, 100], "id": "IMGTEST00001"])
        XCTAssertEqual(r["ref"]?.stringValue, image2)

        try await h.run("image.crop", ["ref": .string(image2), "rect": [0.5, 0, 0.5, 1]])
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "IMGTEST00001")
        XCTAssertEqual(item.image?.crop, Rect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(item.image?.frame, Frame(x: 200, y: 100, w: 100, h: 100), "the kept half stays where it was")

        try await h.run("image.flip", ["ref": .string(image2), "axis": "horizontal"])
        item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "IMGTEST00001")
        XCTAssertEqual(ImageFlip(item), ImageFlip(x: true, y: false))

        XCTAssertEqual(h.undoDepth(Fixtures.docID), 3)
        while h.undoDepth(Fixtures.docID) > 0 { h.app.bus.undo(Fixtures.docID) }
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testURLParamsResolveThroughInputFile() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        let tmp = try h.assets.putTemporary(Fixtures.pngData, ext: "png")
        let r = try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "url": .string("tmp:" + tmp.name)],
                                as: .ai("chat1"))
        guard case let .item(doc, page, id)? = NodeRef(r["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        let item = try h.app.workspace.item(doc, page: page, id: id)
        XCTAssertEqual(item.createdBy, "ai:chat1")
        XCTAssertEqual(try h.assets.data(XCTUnwrap(item.image?.asset), doc: doc), Fixtures.pngData)
        XCTAssertEqual(item.image?.frame.w, 32, "a 1 px image is shown at the 32 pt minimum")

        do {
            try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "url": "file:///etc/hosts"],
                            as: .ai("chat1"))
            XCTFail("file:// outside tmp must be refused for the AI")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
    }

    func testCropValidationAndFreehandMask() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        let ref = "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01"
        try await h.run("image.crop", ["ref": .string(ref), "mask": [[0.2, 0.2], [0.6, 0.2], [0.4, 0.8]]])
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)
        let crop = try XCTUnwrap(item.image?.crop)
        XCTAssertEqual(crop.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(crop.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 0.6, accuracy: 1e-9)
        XCTAssertEqual(item.image?.mask?.count, 3)
        XCTAssertEqual(item.image?.frame.w ?? 0, 64 * 0.4, accuracy: 1e-9)

        for bad: JSONValue in [["ref": .string(ref), "mask": [[0, 0], [1, 1]]],
                               ["ref": .string(ref), "rect": [0.2, 0.2, 0.5, 0.5], "mask": [[0, 0], [1, 0], [1, 1]]],
                               ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "rect": [0, 0, 0.5, 0.5]]] {
            do {
                try await h.run("image.crop", bad)
                XCTFail("\(bad.jsonString()) must fail")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
            }
        }
        do {
            try await h.run("image.crop", ["ref": .string(ref)], as: .ai("chat1"))
            XCTFail("only the user gets the crop sheet")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testReplaceKeepsFrameAndFillsWithoutStretching() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        h.assets.install(Self.halves(), as: AssetRef("halves.png"), doc: Fixtures.docID)
        try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "asset": "fixture-image.png",
                                         "frame": [50, 60, 100, 100], "id": "IMGTEST00001"])
        try await h.run("image.flip", ["ref": .string(image2), "axis": "vertical"])
        try await h.run("image.replace", ["ref": .string(image2), "asset": "halves.png"])
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "IMGTEST00001")
        XCTAssertEqual(item.image?.asset, AssetRef("halves.png"))
        XCTAssertEqual(item.image?.frame, Frame(x: 50, y: 60, w: 100, h: 100))
        XCTAssertEqual(item.image?.crop, Rect(x: 0.25, y: 0, width: 0.5, height: 1), "a 2:1 picture fills a square box")
        XCTAssertTrue(ImageFlip(item).isIdentity)
    }

    func testSaveToPhotosIsSensitive() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        let d = try XCTUnwrap(h.app.commands.descriptor("image.saveToPhotos"))
        XCTAssertEqual(d.effect, .read)
        XCTAssertTrue(d.sensitive)
        XCTAssertTrue(d.userPresence)
        do {
            try await h.run("image.saveToPhotos", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01"], as: .ai("chat1"))
            XCTFail("hostless tests have no Photos library")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        XCTAssertEqual(h.confirmer.requests.count, 1, "sensitive commands are always confirmed for the AI")
    }

    // MARK: Decoding and drawing

    func testDownsamplesTwelveMegapixelsToTheTileSize() throws {
        let data = Self.encode(Self.bitmap(width: 4000, height: 3000) { cg in
            cg.setFillColor(UIColor.systemTeal.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }, as: .jpeg)
        let info = try XCTUnwrap(ImageDecoder.info(data))
        XCTAssertEqual(info.pixelSize, CGSize(width: 4000, height: 3000))
        let tile = 512
        let image = try XCTUnwrap(ImageDecoder.downsample(data, maxPixelSize: tile))
        XCTAssertLessThanOrEqual(max(image.width, image.height), tile)
        XCTAssertEqual(image.width, tile)
        XCTAssertGreaterThan(image.width, image.height)
    }

    func testDrawerAppliesCropAndFlip() throws {
        let assets = InMemoryAssetStore(root: FileManager.default.temporaryDirectory)
        assets.install(Self.halves(), as: AssetRef("halves.png"), doc: Fixtures.docID)
        var item = Item.makeImage(ImageItem(frame: Frame(x: 0, y: 0, w: 20, h: 10), asset: AssetRef("halves.png")))

        var px = Self.render(item, assets: assets)
        XCTAssertTrue(Self.isRed(px(3, 5)))
        XCTAssertTrue(Self.isBlue(px(17, 5)))

        ImageFlip(x: true).write(to: &item)
        px = Self.render(item, assets: assets)
        XCTAssertTrue(Self.isBlue(px(3, 5)))
        XCTAssertTrue(Self.isRed(px(17, 5)))

        ImageFlip().write(to: &item)
        XCTAssertNil(item.ext)
        item.image?.crop = Rect(x: 0.5, y: 0, width: 0.5, height: 1)
        px = Self.render(item, assets: assets)
        XCTAssertTrue(Self.isBlue(px(3, 5)))
        XCTAssertTrue(Self.isBlue(px(17, 5)))
    }

    func testAnimatedGIFGetsALiveViewWhileVisible() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        let gif = Self.gif(frames: 2)
        XCTAssertEqual(ImageDecoder.info(gif)?.frameCount, 2)
        try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "base64": .string(gif.base64EncodedString()),
                                         "frame": [72, 72, 80, 80], "id": "GIFTEST00001"])
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "GIFTEST00001")
        XCTAssertEqual(item.image?.animated, true)
        XCTAssertEqual(item.image?.asset.ext, "gif", "GIF bytes are stored unchanged")

        let host = FakeCanvasHost(h)
        let attachment = AnimatedImageAttachment()
        attachment.attach(to: host)
        XCTAssertNotNil(host.liveViews["GIFTEST00001"])
        XCTAssertNil(host.liveViews[Fixtures.imageID], "still images are tiles only")

        host.zoomScale = 1
        host.pages = [Fixtures.page2]                      // page 1 scrolled out of the canvas
        attachment.canvasDidChange(host)
        XCTAssertNil(host.liveViews["GIFTEST00001"])

        host.pages = [Fixtures.page1, Fixtures.page2]
        attachment.canvasDidChange(host)
        XCTAssertNotNil(host.liveViews["GIFTEST00001"])
        attachment.detach(from: host)
        XCTAssertNil(host.liveViews["GIFTEST00001"])
    }

    // MARK: Geometry

    func testRecropKeepsTheImageInPlaceWhenRotatedOrFlipped() {
        let f = Frame(x: 0, y: 0, w: 200, h: 100)
        let flipped = ImageGeometry.recrop(f, from: ImageGeometry.unit, to: Rect(x: 0, y: 0, width: 0.5, height: 1),
                                           flip: ImageFlip(x: true))
        XCTAssertEqual(flipped, Frame(x: 100, y: 0, w: 100, h: 100), "a mirrored image shows its left half on the right")

        let turned = ImageGeometry.recrop(Frame(x: 0, y: 0, w: 200, h: 100, rotation: .pi / 2), from: ImageGeometry.unit,
                                          to: Rect(x: 0.5, y: 0, width: 0.5, height: 1), flip: ImageFlip())
        XCTAssertEqual(turned.center.x, 100, accuracy: 1e-9)
        XCTAssertEqual(turned.center.y, 100, accuracy: 1e-9)
        XCTAssertEqual(turned.w, 100, accuracy: 1e-9)

        let back = ImageGeometry.recrop(Frame(x: 200, y: 100, w: 100, h: 100), from: Rect(x: 0.5, y: 0, width: 0.5, height: 1),
                                        to: ImageGeometry.unit, flip: ImageFlip())
        XCTAssertEqual(back, Frame(x: 100, y: 100, w: 200, h: 100), "removing the crop grows the frame back")
    }

    func testCropHandlesStayInsideTheImage() {
        let r = CropEditing.drag(ImageGeometry.unit, handle: .topLeft, dx: 0.25, dy: 0.5)
        XCTAssertEqual(r, Rect(x: 0.25, y: 0.5, width: 0.75, height: 0.5))
        let tooFar = CropEditing.drag(ImageGeometry.unit, handle: .right, dx: -2, dy: 0)
        XCTAssertEqual(tooFar.width, CropEditing.minimumSize, accuracy: 1e-12)
        let moved = CropEditing.drag(Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), handle: nil, dx: 1, dy: -1)
        XCTAssertEqual(moved, Rect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(CropEditing.aspect(1, imageAspect: 2), Rect(x: 0.25, y: 0, width: 0.5, height: 1))
        let grown = CropEditing.scaled(Rect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), by: 1.5)
        XCTAssertLessThanOrEqual(grown.maxX, 1)
        XCTAssertEqual(grown.width, 0.75, accuracy: 1e-12)
    }

    func testPlacementFitsHalfThePage() {
        let photo = ImagePlacement.size(pixels: CGSize(width: 4000, height: 3000), page: .a4)
        XCTAssertEqual(photo.w, PageSize.a4.width / 2, accuracy: 1e-9)
        XCTAssertEqual(photo.h, PageSize.a4.width / 2 * 0.75, accuracy: 1e-9)
        let dot = ImagePlacement.size(pixels: CGSize(width: 1, height: 1), page: .a4)
        XCTAssertEqual(dot.w, 32)
        let edge = ImagePlacement.frame(size: (100, 100), centre: Point(0, 0), page: .a4)
        XCTAssertEqual(edge, Frame(x: 0, y: 0, w: 100, h: 100), "kept on the page")
    }

    // MARK: Fixtures

    /// 20 × 10 PNG: left half red, right half blue.
    static func halves() -> Data {
        encode(bitmap(width: 20, height: 10) { cg in
            cg.setFillColor(UIColor.red.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            cg.setFillColor(UIColor.blue.cgColor)
            cg.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        }, as: .png)
    }

    static func gif(frames: Int) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil) else { return Data() }
        for i in 0..<frames {
            let frame = bitmap(width: 8, height: 8) { cg in
                cg.setFillColor((i % 2 == 0 ? UIColor.red : UIColor.blue).cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            CGImageDestinationAddImage(dest, frame, props)
        }
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(cg)
        return cg.makeImage()!
    }

    static func encode(_ image: CGImage, as type: UTType) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Draws `item` with the drawer into a 20 × 10 y-down bitmap (like a tile at scale 1); returns a pixel reader.
    static func render(_ item: Item, assets: AssetStore) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let cg = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.translateBy(x: 0, y: 10)
        cg.scaleBy(x: 1, y: -1)
        ImageDrawer().draw(item, in: DrawContext(cg: cg, scale: 1, doc: Fixtures.docID, page: Fixtures.page1, assets: assets))
        return { x, y in
            let bytes = cg.data!.assumingMemoryBound(to: UInt8.self)
            let i = y * 80 + x * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2])
        }
    }

    static func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool { p.r > 200 && p.b < 60 }
    static func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool { p.b > 200 && p.r < 60 }
}
