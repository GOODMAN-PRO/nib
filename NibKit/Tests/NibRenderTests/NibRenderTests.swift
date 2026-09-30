import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import NibRender

@MainActor
final class NibRenderTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibRenderFeature.id.isEmpty) }

    func testFeatureInstallsRendererCustomDrawerAndCommand() {
        let h = Harness(features: [NibRenderFeature.self])
        XCTAssertTrue(h.app.services.renderer is NibPageRenderer)
        XCTAssertEqual(h.app.content.drawers.get(ItemKind.custom.rawValue)?.owner, NibRenderFeature.id)
        XCTAssertEqual(h.app.commands.descriptor("render.page")?.owner, NibRenderFeature.id)
        XCTAssertEqual(h.app.commands.descriptor("render.page")?.effect, .read)
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [NibRenderFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Size and regions

    func testRenderOfFixturePageHasTheRequestedSize() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer)

        let page = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page1, scale: 1))
        XCTAssertEqual(page.image.width, 595)
        XCTAssertEqual(page.image.height, 842)
        XCTAssertEqual(page.region, Rect(x: 0, y: 0, width: 595.28, height: 841.89))

        let region = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page1,
                                                             region: Rect(x: 10, y: 20, width: 100, height: 50), scale: 2))
        XCTAssertEqual(region.image.width, 200)
        XCTAssertEqual(region.image.height, 100)
        XCTAssertEqual(region.scale, 2)

        // A tile-aligned request (the canvas case) is exactly one 512 px tile.
        let tile = TileGrid.rect(TileCoord(col: 0, row: 0), level: 1)
        let tiled = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page1, region: tile, scale: 2))
        XCTAssertEqual(tiled.image.width, 512)
        XCTAssertEqual(tiled.image.height, 512)
    }

    func testCustomItemDrawsItsDisplayList() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer)
        // Fixture custom item: a 100 × 50 black rect outline at (72, 700).
        let r = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page1,
                                                        region: Rect(x: 60, y: 690, width: 40, height: 40), scale: 4))
        let bmp = bitmap(r.image)
        XCTAssertLessThan(rgb(bmp, 48, 80).r, 90, "left edge of the custom item's rect")
        XCTAssertGreaterThan(rgb(bmp, 100, 80).r, 200, "inside the rect stays paper")
    }

    func testBoardDefaultRegionIsItsContentBounds() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer)
        let r = try await renderer.render(RenderRequest(doc: Fixtures.whiteboardID, page: Fixtures.boardID, scale: 1))
        // Ellipse frame (0, 0, 200, 120) with its outline pad (1.75) and the 24 pt board padding.
        XCTAssertEqual(r.region.x, -25.75, accuracy: 0.001)
        XCTAssertEqual(r.region.y, -25.75, accuracy: 0.001)
        XCTAssertEqual(r.region.width, 251.5, accuracy: 0.001)
        XCTAssertEqual(r.region.height, 171.5, accuracy: 0.001)
        XCTAssertEqual(r.image.width, 252)
    }

    // MARK: Ink compositing

    func testHighlighterOverTextMultiplies() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        h.app.content.drawers.register(ItemDrawerEntry(key: ItemKind.text.rawValue, owner: "test", drawer: SolidBoxDrawer()))
        let text = Item.makeText(TextBoxItem(frame: Frame(x: 20, y: 80, w: 200, h: 40), text: RichText(plain: "SUVAT")))
        let highlighter = Item.makeStroke(Stroke(style: .defaultHighlighter,
                                                 points: [StrokePoint(x: 0, y: 100), StrokePoint(x: 240, y: 100)]))
        let renderer = try XCTUnwrap(h.app.services.renderer)

        let (doc, page) = try makePage(h, items: [text, highlighter])
        let light = bitmap(try await renderer.render(RenderRequest(doc: doc, page: page, scale: 1)).image)
        XCTAssertLessThan(rgb(light, 120, 100).r, 60, "multiply keeps the text under the highlighter dark")
        let onPaper = rgb(light, 10, 100)
        XCTAssertGreaterThan(onPaper.r, 200)
        XCTAssertLessThan(onPaper.b, onPaper.r - 15, "paper under the highlighter turns yellow")

        // Dark paper (D-078): multiply would vanish, so the highlighter is drawn normally at 55 %.
        let (darkDoc, darkPage) = try makePage(h, items: [text, highlighter], background: .ofColor(.paperDark))
        let dark = bitmap(try await renderer.render(RenderRequest(doc: darkDoc, page: darkPage, scale: 1)).image)
        // Paper red is 0x24 (36); multiply could only keep it there or darken it.
        XCTAssertGreaterThan(rgb(dark, 10, 100).r, 50, "the highlighter shows on dark paper")
    }

    func testDashedStrokeIsVisibleWithGaps() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let style = InkStyle(tool: .pen, pen: .ball, color: RGBA(0, 0, 0), width: 4, pattern: .dashed)
        let dashed = Item.makeStroke(Stroke(style: style, points: [StrokePoint(x: 20, y: 50), StrokePoint(x: 220, y: 50)]))
        let (doc, page) = try makePage(h, items: [dashed])
        let renderer = try XCTUnwrap(h.app.services.renderer)
        let r = try await renderer.render(RenderRequest(doc: doc, page: page, region: Rect(x: 0, y: 0, width: 240, height: 100),
                                                        scale: 2))
        let bmp = bitmap(r.image)
        // Width 4 → 12 pt dashes and 8 pt gaps from x = 20: x = 26 is inside the first dash, x = 36 inside the gap.
        XCTAssertLessThan(rgb(bmp, 52, 100).r, 100, "dash drawn")
        XCTAssertGreaterThan(rgb(bmp, 72, 100).r, 200, "gap left open")
        XCTAssertLessThan(rgb(bmp, 92, 100).r, 100, "next dash drawn")
    }

    func testDottedStrokeDrawsDotsWithOpenGaps() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let style = InkStyle(tool: .pen, pen: .ball, color: RGBA(0, 0, 0), width: 6, pattern: .dotted)
        let dotted = Item.makeStroke(Stroke(style: style, points: [StrokePoint(x: 20, y: 50), StrokePoint(x: 220, y: 50)]))
        let (doc, page) = try makePage(h, items: [dotted])
        let renderer = try XCTUnwrap(h.app.services.renderer)
        let r = try await renderer.render(RenderRequest(doc: doc, page: page, region: Rect(x: 0, y: 0, width: 240, height: 100),
                                                        scale: 2))
        let bmp = bitmap(r.image)
        // Width 6 → round dots 6 pt wide every 15.01 pt from x = 20: dots centred at x ≈ 80.04 and 95.05.
        XCTAssertLessThan(rgb(bmp, 160, 100).r, 100, "dot drawn")
        XCTAssertGreaterThan(rgb(bmp, 175, 100).r, 200, "gap between dots left open")
        XCTAssertLessThan(rgb(bmp, 190, 100).r, 100, "next dot drawn")
    }

    func testSpotlightFadesInkWrittenAfterThePlayhead() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let style = InkStyle(tool: .pen, pen: .ball, color: RGBA(0, 0, 0), width: 6)
        let early = Item.makeStroke(Stroke(style: style, points: [StrokePoint(x: 20, y: 40), StrokePoint(x: 220, y: 40)], t0: 10))
        let late = Item.makeStroke(Stroke(style: style, points: [StrokePoint(x: 20, y: 120), StrokePoint(x: 220, y: 120)], t0: 30))
        let (doc, page) = try makePage(h, items: [early, late])
        let renderer = try XCTUnwrap(h.app.services.renderer)
        let bmp = bitmap(try await renderer.render(RenderRequest(doc: doc, page: page, scale: 1,
                                                                 replay: ReplayState(time: 20, mode: .spotlight))).image)
        XCTAssertLessThan(rgb(bmp, 120, 40).r, 80, "ink written before the playhead is drawn normally")
        let faded = rgb(bmp, 120, 120).r
        XCTAssertGreaterThan(faded, 150, "ink written after the playhead is drawn at about 25 %")
        XCTAssertLessThan(faded, 235, "faded ink is still visible")
    }

    func testBandsPutHighlightersBeneathInkAndApplyReplay() {
        let pts = (0..<10).map { StrokePoint(x: Float(10 + $0 * 5), y: 40, t: Float($0) * 0.02) }
        let pen = Item.makeStroke(Stroke(style: .defaultPen, points: pts, t0: 10))
        let highlighter = Item.makeStroke(Stroke(style: .defaultHighlighter, points: pts, t0: 20))
        let text = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 50, h: 20), text: RichText(plain: "a")))
        let pen2 = Item.makeStroke(Stroke(style: .defaultPen, points: pts, t0: 30))
        let items = [pen, highlighter, text, pen2]

        XCTAssertEqual(InkBands.make(items, replay: nil).map(\.kind), [.highlighter, .ink, .item, .ink])

        let spotlight = InkBands.make(items, replay: ReplayState(time: 15, mode: .spotlight))
        XCTAssertEqual(spotlight.map(\.faded), [true, false, false, true])

        let reveal = InkBands.make(items, replay: ReplayState(time: 20.05, mode: .reveal))
        XCTAssertEqual(reveal.map(\.kind), [.highlighter, .ink, .item])
        XCTAssertEqual(reveal[0].strokes[0].points.count, 3, "points written by t = 0.05 s")
        XCTAssertEqual(reveal[1].strokes[0].points.count, pts.count)

        XCTAssertEqual(InkBands.make(items, replay: ReplayState(time: 0, mode: .showAll)).count, 4)

        var dashedStyle = InkStyle.defaultPen
        dashedStyle.pattern = .dotted
        XCTAssertEqual(InkBands.kind(of: Item.makeStroke(Stroke(style: dashedStyle, points: pts))), .patternInk)
        XCTAssertEqual(InkBands.kind(of: Item.makeStroke(Stroke(style: .defaultTape, points: pts))), .item)
    }

    func testPDFBackgroundIsDrawnUpright() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer)
        let r = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.pdfPage, scale: 1))
        let bmp = bitmap(r.image)
        // The fixture PDF has one line of 18 pt text at (72, 72) from the top.
        XCTAssertGreaterThan(darkPixels(bmp, x: 70..<260, y: 66..<100), 0, "text near the top")
        XCTAssertEqual(darkPixels(bmp, x: 70..<260, y: 742..<776), 0, "nothing where a flipped page would put it")
    }

    // MARK: render.page

    func testRenderPageMarksEveryLiveFixtureItem() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let out = try await h.run("render.page", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "marks": true])
        let marks = try XCTUnwrap(out["marks"]?.objectValue)
        XCTAssertEqual(marks.count, 10)
        XCTAssertEqual(Set(marks.keys), Set((1...10).map { String($0) }))
        let ids: [ElementID] = [Fixtures.strokeID, Fixtures.shapeID, Fixtures.textID, Fixtures.stickyID, Fixtures.tapeID,
                                Fixtures.connectorID, Fixtures.commentID, Fixtures.mathID, Fixtures.imageID, Fixtures.customID]
        XCTAssertEqual(Set(marks.values.compactMap { $0.stringValue }),
                       Set(ids.map { NodeRef.item(Fixtures.docID, Fixtures.page1, $0).description }))
        let asset = try XCTUnwrap(out["asset"]?.stringValue)
        XCTAssertTrue(asset.hasPrefix("tmp:"))
        XCTAssertNotNil(h.assets.temporaryURL(AssetRef(String(asset.dropFirst(4)))))
        let unmarked = try await h.run("render.page", ["page": "page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertNil(unmarked["marks"])
    }

    func testRenderPageLongEdgeNeverExceeds1568() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        for scale in [8.0, 2.0] {
            let out = try await h.run("render.page", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "scale": .number(scale)])
            let image = try XCTUnwrap(png(h, out))
            XCTAssertLessThanOrEqual(max(image.width, image.height), 1568)
            XCTAssertGreaterThanOrEqual(max(image.width, image.height), 1567)
            XCTAssertEqual(try XCTUnwrap(out["pxPerPt"]?.doubleValue) * 841.89, 1568, accuracy: 1)
            let fullPage: JSONValue = [0, 0, 595.28, 841.89]
            XCTAssertEqual(out["region"], fullPage)
        }
        let region: JSONValue = [100, 100, 200, 100]
        let small = try await h.run("render.page", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "region": region, "scale": 3])
        let image = try XCTUnwrap(png(h, small))
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 300)
        XCTAssertEqual(small["pxPerPt"]?.doubleValue, 3)
    }

    func testRenderPageRejectsBadParams() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let notAPage: JSONValue = ["page": "doc:FIXTUREDOC01"]
        let emptyRegion: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "region": [0, 0, 0, 10]]
        let noSuchLayer: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "layers": [7]]
        for params in [notAPage, emptyRegion, noSuchLayer] {
            do {
                _ = try await h.run("render.page", params)
                XCTFail("expected invalid_params for \(params.jsonString())")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
            }
        }
    }

    // MARK: Tiles, invalidation, thumbnails

    func testTileGridBuckets() {
        XCTAssertEqual(TileGrid.level(for: 1), 0)
        XCTAssertEqual(TileGrid.level(for: 1.5), 1)
        XCTAssertEqual(TileGrid.level(for: 2), 1)
        XCTAssertEqual(TileGrid.level(for: 3), 2)
        XCTAssertEqual(TileGrid.level(for: 0.3), -1)
        XCTAssertEqual(TileGrid.side(level: 1), 256)
        XCTAssertEqual(TileGrid.tiles(covering: Rect(x: 0, y: 0, width: 300, height: 300), level: 1)?.count, 4)
        XCTAssertEqual(TileGrid.tiles(covering: Rect(x: -10, y: 0, width: 20, height: 256), level: 1),
                       [TileCoord(col: -1, row: 0), TileCoord(col: 0, row: 0)])
        XCTAssertNil(TileGrid.tiles(covering: Rect(x: 0, y: 0, width: 1e6, height: 1e6), level: 1))
    }

    func testCommitInvalidatesOnlyTheDirtyTiles() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer as? NibPageRenderer)
        let key = TileCache.pageKey(Fixtures.docID, Fixtures.page2)

        _ = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page2, scale: 1))
        XCTAssertEqual(renderer.tiles.count(page: key), 4, "an A4 page at 1 px/pt is 2 × 2 tiles of 512 pt")

        try await h.insert([shortStroke()], page: Fixtures.page2)
        XCTAssertEqual(renderer.tiles.count(page: key), 3, "only the top-left tile holds the new stroke")

        renderer.invalidate(doc: Fixtures.docID, page: Fixtures.page2, rect: nil)
        XCTAssertEqual(renderer.tiles.count(page: key), 0)

        _ = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page2, scale: 1))
        XCTAssertEqual(renderer.tiles.count(page: key), 4)
        h.app.content.drawers.register(ItemDrawerEntry(key: ItemKind.sticky.rawValue, owner: "test", drawer: SolidBoxDrawer()))
        XCTAssertEqual(renderer.tiles.count(page: key), 4, "page 2 holds no sticky note, so a sticky drawer leaves it")
        h.app.content.templates.register(paperTemplate("builtin.ruled", paper: .paperYellow))
        XCTAssertEqual(renderer.tiles.count(page: key), 0, "page 2's own template changed how it looks")

        _ = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page2, scale: 1))
        renderer.purgeCaches()
        XCTAssertEqual(renderer.tiles.count(page: key), 0)
    }

    func testPaintBoundsDecideCullingAndInvalidation() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        h.app.content.drawers.register(ItemDrawerEntry(key: "custom.test.far", owner: "test", drawer: FarDrawer()))
        let renderer = try XCTUnwrap(h.app.services.renderer as? NibPageRenderer)
        let far = Item.makeCustom(CustomItem(owner: "test", type: "far", frame: Frame(x: 20, y: 20, w: 40, h: 40)))
        let (doc, page) = try makePage(h, items: [far], size: PageSize(600, 200))

        // 600 pt at 2 px/pt is three 256 pt tiles; the paint bounds (20…260) reach into the second one.
        let key = TileCache.pageKey(doc, page)
        _ = try await renderer.render(RenderRequest(doc: doc, page: page, scale: 2))
        XCTAssertEqual(renderer.tiles.count(page: key), 3)
        var moved = try h.app.workspace.allItems(doc, page: page)[0]
        moved.custom?.frame.y = 22
        try await h.insert([moved], page: page, doc: doc)
        XCTAssertEqual(renderer.tiles.count(page: key), 1, "tiles under the old and new paint bounds are dropped")

        // The drawer paints at x 160…200, far outside the item's bounds (20…60) and their 12 pt margin but inside its
        // paint bounds; at 4 px/pt that region is the tile at x 128…256, which the item's bounds never reach.
        let r = try await renderer.render(RenderRequest(doc: doc, page: page, region: Rect(x: 140, y: 0, width: 100, height: 100),
                                                        scale: 4))
        XCTAssertLessThan(rgb(bitmap(r.image), 160, 170).r, 60, "an item is drawn wherever its paint bounds reach")
    }

    func testTileCacheRefusesTilesRenderedBeforeAnInvalidation() throws {
        let cache = TileCache(costLimit: 64 << 20)
        let image = try XCTUnwrap(PageCompositor.makeContext(width: 4, height: 4)?.makeImage())
        let rect = Rect(x: 0, y: 0, width: 512, height: 512)

        let stale = cache.generation("D/P")
        cache.invalidate(page: "D/P", rect: nil)
        XCTAssertFalse(cache.insert(image, key: "a", page: "D/P", rect: rect, generation: stale))
        XCTAssertEqual(cache.count(page: "D/P"), 0)
        XCTAssertTrue(cache.insert(image, key: "a", page: "D/P", rect: rect, generation: cache.generation("D/P")))
        XCTAssertEqual(cache.count(page: "D/P"), 1)

        let beforePurge = cache.generation("D/P")
        cache.removeAll()
        XCTAssertEqual(cache.count(page: "D/P"), 0)
        XCTAssertFalse(cache.insert(image, key: "b", page: "D/P", rect: rect, generation: beforePurge))
        XCTAssertEqual(cache.count(page: "D/P"), 0)

        let current = cache.generation("D/P")
        cache.invalidate(page: "D/Q", rect: nil)
        XCTAssertTrue(cache.insert(image, key: "c", page: "D/P", rect: rect, generation: current),
                      "another page's invalidation does not outdate this page")
    }

    func testCancelledRenderSkipsItsQueuedTiles() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer as? NibPageRenderer)
        let key = TileCache.pageKey(Fixtures.docID, Fixtures.page2)
        let gate = DispatchSemaphore(value: 0)
        for _ in 0..<NibPageRenderer.maxWorkers { renderer.queue.addOperation { gate.wait() } }
        defer { for _ in 0..<NibPageRenderer.maxWorkers { gate.signal() } }

        let task = Task { try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page2, scale: 1)) }
        for _ in 0..<200 where renderer.queue.operationCount <= NibPageRenderer.maxWorkers {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(renderer.queue.operationCount, NibPageRenderer.maxWorkers, "tiles wait behind busy workers")
        task.cancel()
        for _ in 0..<NibPageRenderer.maxWorkers { gate.signal() }
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertEqual(renderer.tiles.count(page: key), 0, "no queued tile was rendered after the cancel")
    }

    func testThumbnailIsCachedOnDiskByContent() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer as? NibPageRenderer)
        let ink = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 20, y: 20), StrokePoint(x: 200, y: 180)]))
        let (doc, page) = try makePage(h, items: [ink])
        let rendered = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 160)
        let first = try XCTUnwrap(rendered)
        XCTAssertEqual(first.width, 160)
        XCTAssertEqual(first.height, 133)
        let again = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 160)
        XCTAssertTrue(again === first, "served from memory")

        let file = try XCTUnwrap(thumbnailFile(renderer, doc, page, size: 160))
        XCTAssertTrue(file.path.contains("Nib/previews/\(doc.raw)/\(page.raw)/"))
        await diskSettled(renderer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: file.deletingLastPathComponent().appendingPathComponent(ThumbnailCache.looksFileName).path))

        renderer.purgeCaches()
        let reloaded = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 160)
        XCTAssertEqual(reloaded?.height, 133)
        XCTAssertNil(renderer.thumbnails.fileURL(ThumbnailCache.Key(doc: "../x", page: page, rev: .zero, size: 1)))

        // Fixture page 1 lacks its template and most item drawers in this harness: shown, but never persisted.
        let partialFile = try XCTUnwrap(thumbnailFile(renderer, Fixtures.docID, Fixtures.page1, size: 160))
        try? FileManager.default.removeItem(at: partialFile)
        let partial = await renderer.thumbnail(doc: Fixtures.docID, page: Fixtures.page1, maxPixelSize: 160)
        XCTAssertEqual(partial?.height, 160)
        await diskSettled(renderer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialFile.path))
    }

    func testThumbnailDiskHitDoesNotLoadThePageWhenPersistenceKnowsItsRevision() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer as? NibPageRenderer)
        let ink = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 20, y: 20), StrokePoint(x: 200, y: 180)]))
        let (doc, page) = try makePage(h, items: [ink])
        let firstThumb = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 100)
        let first = try XCTUnwrap(firstThumb)
        await diskSettled(renderer)

        let counting = CountingPersistence(base: h.persistence)
        h.app.workspace.close(doc)
        h.app.workspace.persistence = counting
        renderer.purgeCaches()
        let fromDiskThumb = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 100)
        let fromDisk = try XCTUnwrap(fromDiskThumb)
        XCTAssertEqual(counting.itemLoads, 0, "the content revision came from persistence")
        XCTAssertFalse(h.app.workspace.isPageCached(doc, page: page))
        XCTAssertEqual(bitmap(fromDisk).bytes, bitmap(first).bytes)

        // Without a revision from persistence the page is loaded to find it (and the disk file still serves).
        counting.knowsRevisions = false
        h.app.workspace.close(doc)
        renderer.purgeCaches()
        let loadedThumb = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 100)
        XCTAssertNotNil(loadedThumb)
        XCTAssertEqual(counting.itemLoads, 1)
    }

    func testThumbnailFollowsCommitsAndMergesOfOlderRevisions() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer as? NibPageRenderer)
        let (doc, page) = try makePage(h, items: [])
        let blankThumb = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 120)
        let blank = try XCTUnwrap(blankThumb)

        try await h.insert([shortStroke()], page: page, doc: doc)
        let editedThumb = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 120)
        let edited = try XCTUnwrap(editedThumb)
        XCTAssertNotEqual(bitmap(edited).bytes, bitmap(blank).bytes, "a commit re-renders the thumbnail")
        let editedFile = try XCTUnwrap(thumbnailFile(renderer, doc, page, size: 120))
        await diskSettled(renderer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: editedFile.path))
        let newest = try renderer.thumbnailProbe(doc: doc, page: page).rev

        // Ink another device wrote offline before the local edit: merged, yet the page's newest rev does not move.
        var remote = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 20, y: 150), StrokePoint(x: 220, y: 150)]))
        remote.rev = Rev(wallMs: 5, counter: 0, device: 8)
        let merged = h.app.bus.applyRemote(DocumentPatch(doc: doc, items: [page.raw: [remote]]), origin: "device-8")
        XCTAssertFalse(merged.isEmpty)
        XCTAssertEqual(try renderer.thumbnailProbe(doc: doc, page: page).rev, newest)
        await diskSettled(renderer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: editedFile.path), "the merge deleted the stale file")

        let syncedThumb = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 120)
        let synced = try XCTUnwrap(syncedThumb)
        XCTAssertNotEqual(bitmap(synced).bytes, bitmap(edited).bytes, "the merged ink shows, not the stale file")
        await diskSettled(renderer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: editedFile.path), "rewritten with the merged ink")
    }

    func testTemplateChangeDropsOnlyThePagesUsingItAndTheirFilesOnceStarted() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer as? NibPageRenderer)
        h.app.content.templates.register(paperTemplate("test.paper", paper: .white))
        let ink = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 20, y: 20), StrokePoint(x: 200, y: 180)]))
        let (doc, page) = try makePage(h, items: [ink], background: .ofTemplate("test.paper"))
        let (otherDoc, otherPage) = try makePage(h, items: [ink])
        let whiteThumb = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 120)
        XCTAssertGreaterThan(rgb(bitmap(try XCTUnwrap(whiteThumb)), 110, 10).b, 240)
        _ = await renderer.thumbnail(doc: otherDoc, page: otherPage, maxPixelSize: 120)
        await diskSettled(renderer)
        let file = try XCTUnwrap(thumbnailFile(renderer, doc, page, size: 120))
        let otherFile = try XCTUnwrap(thumbnailFile(renderer, otherDoc, otherPage, size: 120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(ThumbnailCache.readLooks(file.deletingLastPathComponent()), [PageLooks.template("test.paper")])
        let key = TileCache.pageKey(doc, page), otherKey = TileCache.pageKey(otherDoc, otherPage)
        XCTAssertGreaterThan(renderer.tiles.count(page: key), 0)
        XCTAssertGreaterThan(renderer.tiles.count(page: otherKey), 0)

        // Launch registration (before the app started) redraws the page but leaves the files alone.
        h.app.content.templates.register(paperTemplate("test.paper", paper: .paperYellow))
        XCTAssertEqual(renderer.tiles.count(page: key), 0)
        XCTAssertGreaterThan(renderer.tiles.count(page: otherKey), 0, "a page on colour paper does not use the template")
        await diskSettled(renderer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let yellow = try await renderer.render(RenderRequest(doc: doc, page: page, scale: 0.5))
        XCTAssertLessThan(rgb(bitmap(yellow.image), 110, 10).b, 240, "tiles re-rendered on the new paper")

        // Once started (a plugin or content pack), the files of the pages using a changed template go too.
        await h.app.start([NibRenderFeature.self])
        h.app.content.drawers.register(ItemDrawerEntry(key: "test.unused", owner: "test", drawer: SolidBoxDrawer()))
        await diskSettled(renderer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "an unrelated drawer changes nothing")
        h.app.content.templates.unregister(id: "test.paper")
        await diskSettled(renderer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFile.path))
        XCTAssertGreaterThan(renderer.tiles.count(page: otherKey), 0)
    }

    // MARK: Drawers and templates (contracts-v2)

    func testDrawersGetThePurposeAnnotationsAndPaper() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let recorder = RecordingDrawer()
        h.app.content.drawers.register(ItemDrawerEntry(key: "custom.test.rec", owner: "test", drawer: recorder))
        let renderer = try XCTUnwrap(h.app.services.renderer)
        let item = Item.makeCustom(CustomItem(owner: "test", type: "rec", frame: Frame(x: 20, y: 20, w: 40, h: 40)))
        let (doc, page) = try makePage(h, items: [item], background: .ofColor(.paperYellow))

        _ = try await renderer.render(RenderRequest(doc: doc, page: page, scale: 1, annotations: false))
        let screen = try XCTUnwrap(recorder.last, "annotations: false still draws the items")
        XCTAssertEqual(screen.purpose, .screen)
        XCTAssertFalse(screen.annotations)
        XCTAssertEqual(screen.paper, .paperYellow)

        try await h.run("render.page", ["page": .string(NodeRef.page(doc, page).description)])
        XCTAssertEqual(recorder.last?.purpose, .query)
        XCTAssertEqual(recorder.last?.annotations, true)

        _ = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 64)
        XCTAssertEqual(recorder.last?.purpose, .thumbnail)
    }

    func testBoardTemplatesRepeatAtTheirPeriodOrRenderTheirRegion() async throws {
        XCTAssertEqual(DisplayListRenderer.boardFrame(region: Rect(x: 260, y: -30, width: 80, height: 40),
                                                      period: PageSize(50, 50)).origin, Point(250, -50))
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer)

        // A render-only template that repeats every 50 pt: vertical lines at x = 50, 100, … of its frame.
        var lines = TemplateDefinition(id: "test.lines", title: "Lines", category: "Test", owner: "test") { _, size, _ in
            TemplateRender(paper: .white, display: DisplayList(ops: [
                DisplayOp(op: .vlines, rect: Rect(x: 0, y: 0, width: size.width, height: size.height), stroke: .black,
                          width: 2, spacing: 50)]))
        }
        lines.metricsProvider = { _, _ in TemplateMetrics(spacing: 50, repeatPeriod: PageSize(50, 50)) }
        h.app.content.templates.register(lines)
        let (board, boardPage) = try makePage(h, items: [], size: nil, background: .ofTemplate("test.lines"))
        // The tile at x 512…1024 lays the template out from x = 500 (a multiple of 50), so its lines fall at 550, 600 …
        // A 240 pt block would start at 480 and put them at 530, 580 …, off the board's 50 pt grid.
        let r = try await renderer.render(RenderRequest(doc: board, page: boardPage,
                                                        region: Rect(x: 520, y: 0, width: 80, height: 40), scale: 1))
        let bmp = bitmap(r.image)
        XCTAssertLessThan(rgb(bmp, 30, 20).r, 128, "the line at x = 550 lies on the grid anchored at the board origin")
        XCTAssertGreaterThan(rgb(bmp, 10, 20).r, 200, "no line at x = 530")
        XCTAssertGreaterThan(rgb(bmp, 60, 20).r, 200, "no line at x = 580")

        // A template with renderRegion gets each tile's own rect: world rects on boards, page rects on pages.
        let log = RegionLog()
        var regional = TemplateDefinition(id: "test.regional", title: "Regional", category: "Test", owner: "test") { _, _, _ in
            log.add(nil, PageSize(0, 0))
            return TemplateRender(paper: .white)
        }
        regional.renderRegion = { _, size, _, region in
            log.add(region, size)
            return TemplateRender(paper: .white)
        }
        h.app.content.templates.register(regional)
        let tile = TileGrid.rect(TileCoord(col: 1, row: -1), level: 0)
        let (regionBoard, regionBoardPage) = try makePage(h, items: [], size: nil, background: .ofTemplate("test.regional"))
        _ = try await renderer.render(RenderRequest(doc: regionBoard, page: regionBoardPage, region: tile, scale: 1))
        XCTAssertEqual(log.calls.map { $0.region }, [tile])
        XCTAssertEqual(log.calls.first?.size, PageSize(512, 512))

        log.reset()
        let (doc, page) = try makePage(h, items: [], background: .ofTemplate("test.regional"))
        let pageTile = TileGrid.rect(TileCoord(col: 0, row: 0), level: 1)
        _ = try await renderer.render(RenderRequest(doc: doc, page: page, region: pageTile, scale: 2))
        XCTAssertEqual(log.calls.map { $0.region }, [pageTile])
        XCTAssertEqual(log.calls.first?.size, PageSize(240, 200), "pages pass their own size")
    }

    func testRotatedBackgroundsFollowPageRecordBackgroundTransform() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        let renderer = try XCTUnwrap(h.app.services.renderer)

        // The fixture PDF (A4 portrait, text at (72, 72)) on a landscape page turned 90° clockwise: the text now runs
        // down the right-hand side near the top.
        let (pdfDoc, pdfPage) = try makePage(h, items: [], size: PageSize(841.89, 595.28),
                                             background: .ofPDF(Fixtures.pdfAsset, page: 0), rotation: 90)
        h.assets.install(Fixtures.pdfData(), as: Fixtures.pdfAsset, doc: pdfDoc)
        let pdf = bitmap(try await renderer.render(RenderRequest(doc: pdfDoc, page: pdfPage, scale: 1)).image)
        XCTAssertGreaterThan(darkPixels(pdf, x: 740..<780, y: 66..<220), 0, "text turned to the right edge")
        XCTAssertEqual(darkPixels(pdf, x: 66..<260, y: 66..<100), 0, "nothing where the unturned text was")

        // A 20 × 10 image, red left and blue right, turned 90° clockwise onto a 100 × 200 page: red on top.
        let png = try XCTUnwrap(twoColourPNG())
        let ref = AssetRef("two-colour.png")
        let (imageDoc, imagePage) = try makePage(h, items: [], size: PageSize(100, 200), background: .ofImage(ref),
                                                 rotation: 90)
        h.assets.install(png, as: ref, doc: imageDoc)
        let turned = bitmap(try await renderer.render(RenderRequest(doc: imageDoc, page: imagePage, scale: 1)).image)
        XCTAssertGreaterThan(rgb(turned, 50, 50).r, 200)
        XCTAssertLessThan(rgb(turned, 50, 50).b, 60)
        XCTAssertGreaterThan(rgb(turned, 50, 150).b, 200)
        XCTAssertLessThan(rgb(turned, 50, 150).r, 60)
    }

    // MARK: Performance

    func testTileWith150StrokesCompositesWithinBudget() throws {
        let h = Harness(features: [NibRenderFeature.self])
        let strokes: [Item] = (0..<150).map { i in
            let ox = Float(8 + (i % 10) * 24), oy = Float(8 + (i / 10) * 16)
            let pts = (0..<30).map { j -> StrokePoint in
                StrokePoint(x: ox + Float(j) * 0.6, y: oy + sin(Float(j) * 0.4) * 4, t: Float(j) * 0.008, force: 0.5,
                            width: 1.4, height: 1.4, opacity: 1)
            }
            return Item.makeStroke(Stroke(style: .defaultPen, points: pts, t0: 1_700_000_000 + Double(i)))
        }
        let (doc, page) = try makePage(h, items: strokes, size: PageSize(595.28, 841.89))
        let renderer = try XCTUnwrap(h.app.services.renderer as? NibPageRenderer)
        let tile = TileGrid.rect(TileCoord(col: 0, row: 0), level: 1)
        let job = try renderer.snapshot(RenderRequest(doc: doc, page: page, region: tile, scale: 2,
                                                      layers: Set(0..<NibLimits.layerCount)))
        XCTAssertEqual(job.visibleItems.count, 150)
        XCTAssertNotNil(PageCompositor.image(job, region: tile, scale: 2, width: 512, height: 512, marks: []))   // warm-up
        var best = Double.infinity
        for _ in 0..<3 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let image = PageCompositor.image(job, region: tile, scale: 2, width: 512, height: 512, marks: [])
            best = min(best, CFAbsoluteTimeGetCurrent() - t0)
            XCTAssertEqual(image?.width, 512)
        }
        XCTAssertLessThan(best, 0.008 * 4)
    }

    // MARK: Helpers

    /// A new one-page notebook holding `items` (z in array order), written straight to persistence so the page is not
    /// in memory until something reads it. Colour background by default (no template needed); `size` nil = a board.
    private func makePage(_ h: Harness, items: [Item], size: PageSize? = PageSize(240, 200),
                          background: Background = .ofColor(.white), rotation: Int = 0) throws -> (DocumentID, PageID) {
        let doc = NibID.make(), page = NibID.make()
        let content = DocumentContent(meta: DocumentMeta(id: doc, kind: size == nil ? .whiteboard : .notebook),
                                      pages: [PageRecord(id: page, order: "V", size: size, background: background,
                                                         rotation: rotation)])
        _ = try h.library.createDocument(content, title: "Render " + doc.raw, in: nil)
        let z = FractionalIndex.sequence(after: nil, count: items.count)
        var ordered: [Item] = []
        for (i, item) in items.enumerated() {
            var copy = item
            copy.z = z[i]
            ordered.append(copy)
        }
        h.persistence.pageItems[doc] = [page: ordered]
        return (doc, page)
    }

    /// Where the page's current thumbnail of `size` px lives on disk.
    private func thumbnailFile(_ renderer: NibPageRenderer, _ doc: DocumentID, _ page: PageID, size: Int) throws -> URL? {
        let probe = try renderer.thumbnailProbe(doc: doc, page: page)
        let key = ThumbnailCache.Key(doc: doc, page: page, rev: probe.rev, size: size)
        XCTAssertTrue(key.fileName.hasPrefix(probe.rev.description + "_"))
        return renderer.thumbnails.fileURL(key)
    }

    /// Waits for the thumbnail file writes and deletions queued so far (the renderer's disk queue is serial).
    private func diskSettled(_ renderer: NibPageRenderer) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            renderer.disk.addBarrierBlock { done.resume() }
        }
    }

    private func shortStroke() -> Item {
        Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 20, y: 15), StrokePoint(x: 40, y: 15)]))
    }

    private func paperTemplate(_ id: String, paper: RGBA) -> TemplateDefinition {
        TemplateDefinition(id: id, title: "Test Paper", category: "Test", owner: "test") { _, _, _ in TemplateRender(paper: paper) }
    }

    /// A 20 × 10 px PNG: red on the left half, blue on the right.
    private func twoColourPNG() -> Data? {
        guard let cg = PageCompositor.makeContext(width: 20, height: 10) else { return nil }
        cg.setFillColor(UIColor.red.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        cg.setFillColor(UIColor.blue.cgColor)
        cg.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        return cg.makeImage().flatMap { PNGCodec.encode($0) }
    }

    private func png(_ h: Harness, _ out: JSONValue) -> CGImage? {
        guard let asset = out["asset"]?.stringValue, let url = h.assets.temporaryURL(AssetRef(String(asset.dropFirst(4)))) else {
            return nil
        }
        return PNGCodec.decode(url: url)
    }

    private struct Bitmap {
        var width: Int
        var bytes: [UInt8]
    }

    /// RGBA8 pixels, row 0 at the top.
    private func bitmap(_ image: CGImage) -> Bitmap {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Bitmap(width: image.width, bytes: bytes)
    }

    private func rgb(_ bmp: Bitmap, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * bmp.width + x) * 4
        return (Int(bmp.bytes[i]), Int(bmp.bytes[i + 1]), Int(bmp.bytes[i + 2]))
    }

    private func darkPixels(_ bmp: Bitmap, x: Range<Int>, y: Range<Int>) -> Int {
        var n = 0
        for py in y {
            for px in x where rgb(bmp, px, py).r < 128 { n += 1 }
        }
        return n
    }
}

/// Stand-in text drawer: a solid black box (the "text" a highlighter goes over).
private final class SolidBoxDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {
        guard let f = item.frame else { return }
        context.cg.setFillColor(UIColor.black.cgColor)
        context.cg.fill(f.rect.cg)
    }
}

/// Paints a black box 100 pt to the right of its item, and says so through `paintBounds`.
private final class FarDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {
        guard let f = item.frame else { return }
        context.cg.setFillColor(UIColor.black.cgColor)
        context.cg.fill(CGRect(x: f.x + f.w + 100, y: f.y, width: 40, height: f.h))
    }

    func paintBounds(_ item: Item) -> Rect? {
        item.frame.map { Rect(x: $0.x, y: $0.y, width: $0.w + 200, height: $0.h) }
    }
}

/// Records the context of every draw (render workers call it concurrently).
private final class RecordingDrawer: ItemDrawer {
    struct Seen {
        var purpose: DrawPurpose
        var annotations: Bool
        var paper: RGBA?
    }

    private let lock = NSLock()
    private var seen: [Seen] = []

    var last: Seen? {
        lock.lock()
        defer { lock.unlock() }
        return seen.last
    }

    func draw(_ item: Item, in context: DrawContext) {
        lock.lock()
        seen.append(Seen(purpose: context.purpose, annotations: context.annotations, paper: context.paper))
        lock.unlock()
    }
}

/// Calls of a template's `render` (region nil) and `renderRegion`, from render workers.
private final class RegionLog: @unchecked Sendable {
    struct Call {
        var region: Rect?
        var size: PageSize
    }

    private let lock = NSLock()
    private var list: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    func add(_ region: Rect?, _ size: PageSize) {
        lock.lock()
        list.append(Call(region: region, size: size))
        lock.unlock()
    }

    func reset() {
        lock.lock()
        list.removeAll()
        lock.unlock()
    }
}

/// `InMemoryPersistence` that can report page content revisions without loading items, and counts item loads.
@MainActor
private final class CountingPersistence: DocumentPersistence {
    let base: InMemoryPersistence
    var knowsRevisions = true
    private(set) var itemLoads = 0

    init(base: InMemoryPersistence) {
        self.base = base
    }

    func loadHead(_ doc: DocumentID) throws -> DocumentContent { try base.loadHead(doc) }

    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        itemLoads += 1
        return try base.loadItems(doc, page: page)
    }

    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        base.didChange(doc, head: head, pages: pages)
    }

    func flush(_ doc: DocumentID) { base.flush(doc) }
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL { try base.fileURL(doc, relativePath: relativePath) }
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { try base.remoteChanges(doc) }

    func contentRevision(_ doc: DocumentID, page: PageID) -> Rev? {
        guard knowsRevisions, let items = base.pageItems[doc]?[page] else { return nil }
        return items.map { $0.rev }.max() ?? .zero
    }
}
