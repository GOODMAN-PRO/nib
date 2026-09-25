import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatTape

@MainActor
final class FeatTapeTests: XCTestCase {
    private let page = "page:FIXTUREDOC01/FIXTUREPG001"
    private let tapeRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETAP01"

    private func harness() -> Harness { Harness(features: [FeatTapeFeature.self]) }

    private func fixtureTape(_ h: Harness) throws -> Item {
        try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.tapeID)
    }

    private func store(_ h: Harness) throws -> TapeStore {
        try XCTUnwrap(h.app.services.get(TapeStore.serviceKey, as: TapeStore.self))
    }

    // MARK: Registration and conformance

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatTapeFeature.self], owners: [FeatTapeFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersToolDrawerTapHandlerAndPatterns() {
        let h = harness()
        XCTAssertEqual(FeatTapeFeature.id, "tape")
        XCTAssertNotNil(h.app.content.drawers.get("stroke.tape"))
        let handler = h.app.content.tapHandlers.get("tape.tapAt")
        XCTAssertEqual(handler?.order, 100)
        XCTAssertEqual(handler?.worksInReadOnly, true)
        XCTAssertEqual(handler?.command, "tape.tapAt")
        XCTAssertEqual(h.app.ui.canvasTools.get("tape")?.make().inputMode, .samples)
        XCTAssertEqual(h.app.ui.toolbar.get("tape")?.shortcut, KeyShortcut("a"))
        XCTAssertEqual(h.app.ui.toolbar.get("tape")?.toolID, "tape")
        XCTAssertEqual(h.app.content.tapePatterns.all.filter { TapePattern(id: $0.id) != nil }.count, 12)
        let ids = Set(h.app.commands.all().filter { $0.owner == FeatTapeFeature.id }.map { $0.id })
        XCTAssertEqual(ids, ["tape.tapAt", "tape.setRevealed", "tape.removeAll", "tape.importPattern", "tape.patterns",
                             "tape.deletePattern", "tape.clearHistory"])
        XCTAssertEqual(h.app.commands.descriptor("tape.tapAt")?.undoable, false)
        XCTAssertEqual(h.app.commands.descriptor("tape.setRevealed")?.undoable, false)
    }

    // MARK: Hide and reveal

    func testTapTogglesTapeWithoutAddingAnUndoEntry() async throws {
        let h = harness()
        let depth = h.undoDepth(Fixtures.docID)

        let first = try await h.run("tape.tapAt", ["page": .string(page), "point": [170, 603]])
        XCTAssertEqual(first["handled"]?.boolValue, true)
        XCTAssertEqual(first["ref"]?.stringValue, tapeRef)
        XCTAssertEqual(first["revealed"]?.boolValue, true)
        XCTAssertEqual(try fixtureTape(h).stroke?.tapeRevealed, true)

        let second = try await h.run("tape.tapAt", ["page": .string(page), "point": [100, 596]])
        XCTAssertEqual(second["revealed"]?.boolValue, false)
        XCTAssertEqual(try fixtureTape(h).stroke?.tapeRevealed, false)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)

        let miss = try await h.run("tape.tapAt", ["page": .string(page), "point": [300, 300]])
        XCTAssertEqual(miss["handled"]?.boolValue, false)

        h.session.hiddenLayers = [0]
        let hidden = try await h.run("tape.tapAt", ["page": .string(page), "point": [170, 600]])
        XCTAssertEqual(hidden["handled"]?.boolValue, false, "tape on a hidden layer cannot be tapped")
    }

    func testSetRevealedAndRemoveAll() async throws {
        let h = harness()
        let depth = h.undoDepth(Fixtures.docID)

        let revealed = try await h.run("tape.setRevealed", ["refs": [.string(page)], "revealed": true], as: .ai("chat"))
        XCTAssertEqual(revealed["changed"]?.intValue, 1)
        XCTAssertEqual(try fixtureTape(h).stroke?.tapeRevealed, true)
        let again = try await h.run("tape.setRevealed", ["refs": [.string(tapeRef)], "revealed": true])
        XCTAssertEqual(again["changed"]?.intValue, 0)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)

        do {
            try await h.run("tape.setRevealed", ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"], "revealed": true])
            XCTFail("pen ink is not tape")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.refs[0]")
        }

        let removed = try await h.run("tape.removeAll", ["page": .string(page)])
        XCTAssertEqual(removed["removed"]?.intValue, 1)
        XCTAssertThrowsError(try fixtureTape(h))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try fixtureTape(h).stroke?.tapeRevealed, true)
    }

    func testHitTestFindsTheTopmostVisibleTape() {
        let strip = [StrokePoint(x: 0, y: 50, width: 18, height: 18), StrokePoint(x: 100, y: 50, width: 18, height: 18)]
        let low = Item(id: "LOWTAPE", kind: .stroke, z: "a", layer: 0, stroke: Stroke(style: .defaultTape, points: strip))
        let high = Item(id: "HIGHTAPE", kind: .stroke, z: "b", layer: 1, stroke: Stroke(style: .defaultTape, points: strip))
        let ink = Item(id: "INK", kind: .stroke, z: "c", stroke: Stroke(style: .defaultPen, points: strip))
        XCTAssertEqual(TapeGeometry.topmostTape(in: [low, high, ink], at: Point(50, 55))?.id, "HIGHTAPE")
        XCTAssertEqual(TapeGeometry.topmostTape(in: [low, high, ink], at: Point(50, 55), hiddenLayers: [1])?.id, "LOWTAPE")
        XCTAssertNil(TapeGeometry.topmostTape(in: [low, high], at: Point(50, 80)))

        XCTAssertEqual(TapeGeometry.straightened(Point(0, 0), Point(100, 5)), [Point(0, 0), Point(100, 0)])
        XCTAssertEqual(TapeGeometry.straightened(Point(0, 0), Point(3, 100)), [Point(0, 0), Point(0, 100)])
        XCTAssertEqual(TapeGeometry.straightened(Point(0, 0), Point(50, 50)), [Point(0, 0), Point(50, 50)])
        let trimmed = TapeGeometry.trimmed([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)], by: 1)
        XCTAssertEqual(trimmed.count, 2)
        XCTAssertEqual(trimmed.first?.x ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(trimmed.last?.x ?? 0, 9, accuracy: 1e-9)
        XCTAssertEqual(TapeGeometry.trimmed([CGPoint(x: 0, y: 0), CGPoint(x: 1.5, y: 0)], by: 1), [])
    }

    // MARK: Tool

    private func sample(_ x: Double, _ y: Double, _ t: Double, predicted: Bool = false) -> CanvasSample {
        CanvasSample(page: Fixtures.page2, location: Point(x, y), timestamp: t, isPredicted: predicted)
    }

    func testToolCommitsATapeStrokeWithPresetWidthPatternAndHistory() throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        var presets = ToolPresets.defaults(for: "tape")
        presets.swatches[0].pattern = TapePatternRef.asset(for: TapePattern.dots.id)
        h.app.settings.set(NibSettings.presets("tape"), presets)

        let tool = TapeTool()
        tool.touchesBegan(sample(100, 300, 0), host: host)
        tool.touchesMoved([sample(150, 302, 0.02), sample(200, 305, 0.04), sample(260, 330, 0.05, predicted: true)], host: host)
        tool.touchesEnded(sample(250, 300, 0.06), host: host)

        XCTAssertEqual(host.committed.count, 1)
        XCTAssertEqual(host.committed.first?.page, Fixtures.page2)
        let stroke = try XCTUnwrap(host.committed.first?.stroke)
        XCTAssertEqual(stroke.style.tool, .tape)
        XCTAssertEqual(stroke.style.width, 18)
        XCTAssertEqual(stroke.style.color, presets.swatches[0].color)
        XCTAssertEqual(stroke.points.count, 4, "predicted samples only feed the preview")
        XCTAssertTrue(stroke.points.allSatisfy { $0.width == 18 && $0.height == 18 })
        let asset = try XCTUnwrap(stroke.style.tapePattern, "the pattern tile is copied into the document")
        XCTAssertNotNil(try? h.assets.data(asset, doc: Fixtures.docID))
        XCTAssertEqual(TapeHistory.live(try store(h).history).first?.pattern, TapePattern.dots.id)
    }

    func testStraightTapeAndShortTouches() throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        h.app.settings.set(TapeSettings.straight, true)
        h.app.settings.set(TapeSettings.followsDirection, true)
        let tool = TapeTool()

        tool.touchesBegan(sample(100, 300, 0), host: host)
        tool.touchesMoved([sample(170, 310, 0.02), sample(210, 296, 0.04)], host: host)
        tool.touchesEnded(sample(250, 304, 0.06), host: host)
        let stroke = try XCTUnwrap(host.committed.first?.stroke)
        XCTAssertEqual(stroke.polyline, [Point(100, 300), Point(250, 300)], "straight tape is snapped level")
        XCTAssertTrue(stroke.style.tapeFollowsDirection)
        XCTAssertNil(stroke.style.tapePattern)

        tool.touchesBegan(sample(40, 40, 1), host: host)
        tool.touchesEnded(sample(41, 40.5, 1.05), host: host)
        XCTAssertEqual(host.committed.count, 1, "a touch shorter than 3 pt toggles tape instead of drawing")
    }

    // MARK: Drawer

    private func render(_ stroke: Stroke, assets: AssetStore? = nil) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGContext(data: nil, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.translateBy(x: 0, y: 60)
        cg.scaleBy(x: 1, y: -1)
        TapeDrawer().draw(Item(kind: .stroke, stroke: stroke),
                          in: DrawContext(cg: cg, scale: 1, doc: Fixtures.docID, page: Fixtures.page1, assets: assets))
        return try XCTUnwrap(cg.makeImage())
    }

    /// Premultiplied RGBA of the pixel at page point (x, y).
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let i = y * image.bytesPerRow + x * 4
        return (0..<4).map { Int(data[i + $0]) }
    }

    func testDrawerRendersPlainPatternAndRevealedTape() throws {
        let red = RGBA(255, 0, 0)
        var style = InkStyle(tool: .tape, pen: nil, color: red, width: 20)
        let strip = [StrokePoint(x: 5, y: 30, width: 20, height: 20), StrokePoint(x: 55, y: 30, width: 20, height: 20)]

        let hidden = try render(Stroke(style: style, points: strip))
        XCTAssertEqual(try pixel(hidden, 30, 30), [255, 0, 0, 255], "hidden tape is opaque")
        XCTAssertEqual(try pixel(hidden, 30, 5)[3], 0)

        let revealed = try render(Stroke(style: style, points: strip, tapeRevealed: true))
        let centre = try pixel(revealed, 30, 30)
        let edge = try pixel(revealed, 30, 20)
        XCTAssertEqual(Double(centre[3]), 0.15 * 255, accuracy: 4, "revealed tape keeps 15 % of its fill")
        XCTAssertGreaterThan(edge[3], centre[3] + 60, "revealed tape keeps an outline")

        let assets = InMemoryAssetStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("tape-assets-" + UUID().uuidString, isDirectory: true))
        let tile = try XCTUnwrap(TapeTile.png(.stripes, color: RGBA(33, 86, 217)))
        style.tapePattern = try assets.put(tile, ext: "png", doc: Fixtures.docID)
        let patterned = try render(Stroke(style: style, points: strip), assets: assets)
        let row = try (6...54).map { try pixel(patterned, $0, 30) }
        XCTAssertTrue(row.allSatisfy { $0[3] == 255 }, "patterned tape still hides what is under it")
        XCTAssertGreaterThan(Set(row.map { $0[0] << 16 | $0[1] << 8 | $0[2] }).count, 1, "the pattern is drawn")
        XCTAssertFalse(row.contains([255, 0, 0, 255]), "the tiles cover the base colour")

        style.tapeFollowsDirection = true
        let diagonal = [StrokePoint(x: 5, y: 5, width: 20, height: 20), StrokePoint(x: 55, y: 55, width: 20, height: 20)]
        let following = try render(Stroke(style: style, points: diagonal), assets: assets)
        XCTAssertEqual(try pixel(following, 30, 30)[3], 255)
    }

    // MARK: Patterns

    func testBuiltInPatternsAreDistinctRecolourableTiles() throws {
        var seen = Set<Data>()
        for pattern in TapePattern.allCases {
            let data = try XCTUnwrap(TapeTile.png(pattern, color: RGBA(33, 86, 217)))
            XCTAssertEqual(try XCTUnwrap(TapeTile.decode(data)).width, TapeTile.pixels)
            XCTAssertTrue(seen.insert(data).inserted, "\(pattern) duplicates another pattern")
            XCTAssertNotEqual(data, TapeTile.png(pattern, color: .black), "\(pattern) ignores the tape colour")
            XCTAssertEqual(TapePattern(id: pattern.id), pattern)
        }
        XCTAssertEqual(TapePatternRef.id(from: TapePatternRef.asset(for: "tape.hearts")), "tape.hearts")
    }

    func testImportListAndDeleteCustomPattern() async throws {
        let h = harness()
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGContext(data: nil, width: 300, height: 150, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.setFillColor(RGBA(11, 135, 147).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
        let png = try XCTUnwrap(TapeTile.png(try XCTUnwrap(cg.makeImage())))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tape-import-\(UUID().uuidString).png")
        try png.write(to: file)

        let imported = try await h.run("tape.importPattern", ["url": .string(file.absoluteString), "id": "MYWASHI01"])
        XCTAssertEqual(imported["id"]?.stringValue, "MYWASHI01")
        let stored = h.library.metadataURL.appendingPathComponent("tape/MYWASHI01.png")
        let tile = try XCTUnwrap(TapeTile.decode(try Data(contentsOf: stored)))
        XCTAssertLessThanOrEqual(abs(tile.height - 100), 1, "custom images become ~100 px tiles")
        XCTAssertLessThanOrEqual(abs(tile.width - 200), 1)

        let list = try await h.run("tape.patterns")
        let patterns = list["patterns"]?.arrayValue ?? []
        XCTAssertEqual(patterns.count, 13)
        XCTAssertEqual(patterns.first?["source"]?.stringValue, "builtin")
        XCTAssertEqual(patterns.last?["id"]?.stringValue, "MYWASHI01")
        XCTAssertEqual(patterns.last?["source"]?.stringValue, "custom")
        XCTAssertTrue(patterns.allSatisfy { $0["asset"]?.stringValue?.hasPrefix("tmp:") == true })
        XCTAssertEqual(list["current"]?["width"]?.doubleValue, 18)

        do {
            try await h.run("tape.deletePattern", ["id": "tape.stars"])
            XCTFail("built-in patterns cannot be deleted")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        try await h.run("tape.deletePattern", ["id": "MYWASHI01"])
        XCTAssertNil(h.app.content.tapePatterns.get("MYWASHI01"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    }

    // MARK: History

    func testHistoryFilesFromTwoDevicesMerge() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tape-history-" + UUID().uuidString,
                                                                                   isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ipad = HLCClock(device: 7)
        let phone = HLCClock(device: 8)
        let red = RGBA(217, 67, 43)
        let now = Date().timeIntervalSince1970

        // Each device writes only its own file; the phone has not seen the iPad's yet.
        try TapeHistory.save(TapeHistory.recording([], pattern: "tape.dots", color: red, at: 100, clock: ipad),
                             folder: folder, device: "00000007", now: now)
        let phoneOnly = TapeHistory.recording([], pattern: "tape.stars", color: .black, at: 200, clock: phone)
        try JSONEncoder().encode(phoneOnly).write(to: folder.appendingPathComponent(TapeHistory.fileName(device: "00000008")))
        // A cloud provider's conflict copy of the iPad's file.
        let copy = TapeHistory.recording([], pattern: nil, color: red, at: 150, clock: ipad)
        try JSONEncoder().encode(copy).write(to: folder.appendingPathComponent("history.00000007 2.json"))

        let merged = TapeHistory.live(TapeHistory.load(folder: folder))
        XCTAssertEqual(merged.map { $0.pattern }, ["tape.stars", nil, "tape.dots"])

        let saved = try TapeHistory.save(TapeHistory.load(folder: folder), folder: folder, device: "00000007", now: now)
        XCTAssertEqual(TapeHistory.live(saved).count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("history.00000007 2.json").path),
                       "merged conflict copies are removed")

        // Clearing on the iPad is a set of tombstones that beats the phone's older, still-live file.
        try TapeHistory.save(TapeHistory.cleared(TapeHistory.load(folder: folder), clock: ipad), folder: folder,
                             device: "00000007", now: now)
        XCTAssertTrue(TapeHistory.live(TapeHistory.load(folder: folder)).isEmpty)
        let phoneFile = try JSONDecoder().decode([TapeHistoryEntry].self,
                                                 from: Data(contentsOf: folder.appendingPathComponent("history.00000008.json")))
        XCTAssertTrue(phoneFile.contains { !$0.deleted })
    }

    func testHistoryKeepsTheMostRecentEntries() {
        let clock = HLCClock(device: 7)
        var entries: [TapeHistoryEntry] = []
        for i in 0..<(TapeHistory.maxLive + 5) {
            entries = TapeHistory.recording(entries, pattern: "tape.grid", color: RGBA(UInt8(i), 0, 0), at: Double(i), clock: clock)
        }
        let live = TapeHistory.live(entries)
        XCTAssertEqual(live.count, TapeHistory.maxLive)
        XCTAssertEqual(live.first?.usedAt, Double(TapeHistory.maxLive + 4))
        entries = TapeHistory.recording(entries, pattern: "tape.grid", color: RGBA(10, 0, 0), at: 1_000, clock: clock)
        XCTAssertEqual(TapeHistory.live(entries).first?.color, RGBA(10, 0, 0), "using a tape again moves it to the front")
    }
}
