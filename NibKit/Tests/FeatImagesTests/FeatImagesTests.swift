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
        // Each step is one undo entry: undo restores the document as it was before the step, redo brings the step back
        // and the next step builds on it. ponytail: one step at a time, because the contract's revert skips an older
        // entry once a newer undo has re-stamped the same item's rev (reported as a contract gap).
        let steps: [(command: String, params: JSONValue)] = [
            ("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "asset": "fixture-image.png",
                              "frame": [100, 100, 200, 100], "id": "IMGTEST00001"]),
            ("image.crop", ["ref": .string(image2), "rect": [0.5, 0, 0.5, 1]]),
            ("image.flip", ["ref": .string(image2), "axis": "horizontal"])
        ]
        for step in steps {
            let before = try h.snapshot()
            let depth = h.undoDepth(Fixtures.docID)
            try await h.run(step.command, step.params)
            let after = try h.snapshot()
            XCTAssertNotEqual(after, before, step.command)
            XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1, "\(step.command) is one undo step")
            XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
            XCTAssertEqual(try h.snapshot(), before, "undo \(step.command)")
            XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
            XCTAssertEqual(try h.snapshot(), after, "redo \(step.command)")
        }

        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "IMGTEST00001")
        XCTAssertEqual(item.image?.crop, Rect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(item.image?.frame, Frame(x: 200, y: 100, w: 100, h: 100), "the kept half stays where it was")
        XCTAssertEqual(ImageFlip(item), ImageFlip(x: true, y: false))
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

    func testStillsNeverAnimate() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "asset": "fixture-image.png",
                                         "frame": [10, 10, 40, 40], "animated": true, "id": "IMGTEST00002"])
        let png = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "IMGTEST00002")
        XCTAssertEqual(png.image?.animated, false, "animated can only turn animation off")

        let gif = Self.gif(frames: 2)
        try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "base64": .string(gif.base64EncodedString()),
                                         "frame": [60, 10, 40, 40], "animated": false, "id": "IMGTEST00003"])
        let still = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "IMGTEST00003")
        XCTAssertEqual(still.image?.animated, false)

        let tiff = Self.multiPage(pages: 2, as: .tiff)
        let info = try XCTUnwrap(ImageDecoder.info(tiff))
        XCTAssertEqual(info.frameCount, 2)
        XCTAssertFalse(info.isAnimated, "the pages of a TIFF are not an animation")
        XCTAssertEqual(ImageDecoder.frames(tiff, maxPixelSize: 8, crop: nil).frames.count, 1)

        func kind(_ type: UTType, frames: Int) -> Bool {
            ImageDecoder.Info(pixelSize: CGSize(width: 8, height: 8), frameCount: frames, type: type.identifier).isAnimated
        }
        XCTAssertTrue(kind(.gif, frames: 2))
        XCTAssertTrue(kind(.png, frames: 2), "APNG")
        XCTAssertTrue(kind(.webP, frames: 2))
        XCTAssertFalse(kind(.gif, frames: 1))
        XCTAssertFalse(kind(.heic, frames: 3), "a HEIF burst is not an animation")
    }

    func testLockedImageIsRefusedBeforeASheetOrPickerOpens() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        let ref = "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01"
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)
        item.locked = true
        item.rev = h.app.workspace.clock.tick()
        h.app.bus.applyRemote(DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page1.raw: [item]]), origin: "test")
        XCTAssertTrue(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID).locked)

        let calls: [(command: String, params: JSONValue)] = [
            ("image.crop", ["ref": .string(ref)]),
            ("image.pick", ["source": "photos", "ref": .string(ref)])
        ]
        for call in calls {
            do {
                try await h.run(call.command, call.params)
                XCTFail("\(call.command) on a locked image must fail before anything is presented")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams, "\(call.command): refused up front, not after the sheet")
                XCTAssertTrue(e.message.contains("locked"), e.message)
            }
        }
        do {
            try await h.run("image.pick", ["source": "photos", "ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"])
            XCTFail("Replace Image on a text box is refused before the picker")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testRefusesImagesOverTwoHundredFiftySixMegapixels() {
        let huge = ImageDecoder.Info(pixelSize: CGSize(width: 20_000, height: 20_000), frameCount: 1, type: UTType.png.identifier)
        XCTAssertThrowsError(try ImageAssets.check(huge, path: "$.base64")) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
            XCTAssertEqual((error as? NibError)?.path, "$.base64")
        }
        let photo = ImageDecoder.Info(pixelSize: CGSize(width: 8000, height: 6000), frameCount: 1, type: UTType.jpeg.identifier)
        XCTAssertNoThrow(try ImageAssets.check(photo, path: "$.base64"))
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

    func testDrawerClipsToTheFreehandMask() throws {
        let assets = InMemoryAssetStore(root: FileManager.default.temporaryDirectory)
        assets.install(Self.halves(), as: AssetRef("halves.png"), doc: Fixtures.docID)
        var item = Item.makeImage(ImageItem(frame: Frame(x: 0, y: 0, w: 20, h: 10), asset: AssetRef("halves.png")))
        item.image?.mask = [Point(0.5, 0), Point(1, 1), Point(0, 1)]           // apex top centre, base along the bottom
        let px = Self.render(item, assets: assets)
        XCTAssertEqual(px(2, 1).a, 0, "outside the triangle stays transparent")
        XCTAssertEqual(px(18, 1).a, 0, "outside the triangle stays transparent")
        XCTAssertEqual(px(5, 8).a, 255)
        XCTAssertTrue(Self.isRed(px(5, 8)))
        XCTAssertTrue(Self.isBlue(px(15, 8)))
    }

    func testGIFFramesKeepTheirOwnDelaysAndCrop() throws {
        let animation = ImageDecoder.frames(Self.gif(frames: 2), maxPixelSize: 8, crop: Rect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(animation.frames.count, 2)
        XCTAssertEqual(animation.delays.count, 2)
        XCTAssertEqual(animation.delays.first ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(animation.duration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(animation.frames.first?.width, 4, "frames arrive cropped")
        XCTAssertEqual(animation.frames.first?.height, 8)

        // A tight budget keeps evenly spread frames, and the skipped ones keep their time.
        let many = Self.gif(frames: 40, width: 200, height: 100)
        let plan = ImageDecoder.animationPlan(pixelSize: CGSize(width: 200, height: 100), crop: Rect(x: 0, y: 0, width: 0.5, height: 1),
                                              frameCount: 40, maxPixelSize: 200, budget: 100_000)
        XCTAssertEqual(plan.indices, [0, 20])
        let tight = ImageDecoder.frames(many, maxPixelSize: 200, crop: Rect(x: 0, y: 0, width: 0.5, height: 1), budget: 100_000)
        XCTAssertEqual(tight.frames.count, 2)
        XCTAssertLessThanOrEqual(tight.byteCount, 100_000)
        XCTAssertEqual(tight.duration, 4, accuracy: 1e-6)
        XCTAssertEqual(tight.frames.first?.width, 100)
        XCTAssertEqual(tight.frames.first?.height, 100)
    }

    func testThreeHundredFrameGIFStaysWithinTheBudget() throws {
        // A 10 s screen recording: 300 frames at 1024 px. Undecoded in full it would be ~700 MB.
        let data = Self.gif(frames: 300, width: 1024, height: 576)
        XCTAssertEqual(ImageDecoder.info(data)?.frameCount, 300)
        let budget = ImageDecoder.animationBudget
        let plan = ImageDecoder.animationPlan(pixelSize: CGSize(width: 1024, height: 576), crop: ImageGeometry.unit,
                                              frameCount: 300, maxPixelSize: 1024, budget: budget)
        XCTAssertEqual(plan.maxPixelSize, ImageDecoder.minimumAnimationPixel, "shrinks to the floor before skipping frames")
        XCTAssertEqual(plan.indices.first, 0)
        XCTAssertEqual(plan.indices, plan.indices.sorted())

        let animation = ImageDecoder.frames(data, maxPixelSize: 1024, crop: nil, budget: budget)
        XCTAssertLessThanOrEqual(animation.byteCount, budget)
        XCTAssertGreaterThan(animation.frames.count, 150, "evenly sampled, not cut off at the end")
        XCTAssertLessThanOrEqual(animation.frames.count, 300)
        XCTAssertEqual(animation.frames.count, animation.delays.count)
        XCTAssertEqual(animation.duration, 30, accuracy: 1e-6, "the loop keeps its real length")
        for frame in animation.frames {
            XCTAssertLessThanOrEqual(max(frame.width, frame.height), 1024)
        }
    }

    func testPlaybackUsesEachFrameDelay() {
        let delays = [0.1, 0.2, 0.3]
        let a = AnimatedImageView.step(index: 0, elapsed: 0.05, delays: delays)
        XCTAssertEqual(a.index, 0)
        let b = AnimatedImageView.step(index: 0, elapsed: 0.25, delays: delays)
        XCTAssertEqual(b.index, 1)
        XCTAssertEqual(b.elapsed, 0.15, accuracy: 1e-9)
        let c = AnimatedImageView.step(index: 2, elapsed: 0.35, delays: delays)
        XCTAssertEqual(c.index, 0, "wraps around")
        XCTAssertEqual(c.elapsed, 0.05, accuracy: 1e-9)
        let stalled = AnimatedImageView.step(index: 2, elapsed: 6.05, delays: delays)
        XCTAssertEqual(stalled.index, 2, "a long stall skips whole loops")
        XCTAssertEqual(stalled.elapsed, 0.05, accuracy: 1e-9)
        XCTAssertEqual(AnimatedImageView.step(index: 0, elapsed: 5, delays: [0.1]).index, 0)
    }

    func testLiveViewsShareOneBudget() {
        let mb = 1024 * 1024
        XCTAssertEqual(AnimatedImageAttachment.budget(forViews: 1), 32 * mb)
        XCTAssertEqual(AnimatedImageAttachment.budget(forViews: 3), 32 * mb)
        XCTAssertEqual(AnimatedImageAttachment.budget(forViews: 4), 16 * mb)
        XCTAssertEqual(AnimatedImageAttachment.budget(forViews: 12), 8 * mb)
        let most = AnimatedImageAttachment.maxLiveViews
        XCTAssertLessThanOrEqual(AnimatedImageAttachment.budget(forViews: most) * most, AnimatedImageAttachment.totalBudget)
        XCTAssertEqual(AnimatedImageAttachment.budget(forViews: 500), AnimatedImageAttachment.minimumViewBudget)
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
        let view = try XCTUnwrap(host.liveViews["GIFTEST00001"] as? AnimatedImageView)
        for _ in 0..<250 where view.frameCount == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(view.frameCount, 2, "frames are decoded off the main thread and handed to the view")
        XCTAssertNotNil(view.imageView.image, "frame 0 shows at once")

        // Commits keep the page index current: a new GIF gets a view, and one that stops being animated loses it.
        try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "base64": .string(gif.base64EncodedString()),
                                         "frame": [200, 72, 80, 80], "id": "GIFTEST00002"])
        attachment.canvasDidChange(host)
        XCTAssertNotNil(host.liveViews["GIFTEST00002"])
        try await h.run("image.replace", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/GIFTEST00002", "asset": "fixture-image.png"])
        attachment.canvasDidChange(host)
        XCTAssertNil(host.liveViews["GIFTEST00002"])
        XCTAssertNotNil(host.liveViews["GIFTEST00001"])

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

    func testMirrorConvertsBetweenDisplayAndImageSpace() {
        let both = ImageFlip(x: true, y: true)
        let r = Rect(x: 0.25, y: 0.125, width: 0.5, height: 0.25)
        XCTAssertEqual(both.mirror(both.mirror(r)), r)
        XCTAssertEqual(both.mirror(Rect(x: 0, y: 0, width: 0.5, height: 1)), Rect(x: 0.5, y: 0, width: 0.5, height: 1))
        let pts = [Point(0.25, 0.75), Point(1, 0)]
        XCTAssertEqual(both.mirror(pts), [Point(0.75, 0.25), Point(0, 1)])
        XCTAssertEqual(both.mirror(both.mirror(pts)), pts)
        XCTAssertEqual(ImageFlip(x: true).mirror(pts), [Point(0.75, 0.75), Point(0, 0)])
        XCTAssertEqual(ImageFlip().mirror(r), r)
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

    /// A GIF alternating red and blue frames, 0.1 s each. Two bitmaps are shared by every frame, so 300 large frames
    /// cost two decoded images while encoding.
    static func gif(frames: Int, width: Int = 8, height: Int = 8) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil) else { return Data() }
        let colours = [UIColor.red, UIColor.blue].map { colour in
            bitmap(width: width, height: height) { cg in
                cg.setFillColor(colour.cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        for i in 0..<frames {
            CGImageDestinationAddImage(dest, colours[i % 2], props)
        }
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// A multi-page file (TIFF pages, not an animation) of 8 × 8 pages.
    static func multiPage(pages: Int, as type: UTType) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, pages, nil) else { return Data() }
        for _ in 0..<pages {
            CGImageDestinationAddImage(dest, bitmap(width: 8, height: 8) { cg in
                cg.setFillColor(UIColor.green.cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }, nil)
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

    /// Draws `item` with the drawer into a 20 × 10 y-down bitmap (like a tile at scale 1); returns an RGBA pixel reader.
    static func render(_ item: Item, assets: AssetStore) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cg = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.translateBy(x: 0, y: 10)
        cg.scaleBy(x: 1, y: -1)
        ImageDrawer().draw(item, in: DrawContext(cg: cg, scale: 1, doc: Fixtures.docID, page: Fixtures.page1, assets: assets))
        return { x, y in
            let bytes = cg.data!.assumingMemoryBound(to: UInt8.self)
            let i = y * 80 + x * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }

    static func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.b < 60 }
    static func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.b > 200 && p.r < 60 }
}
