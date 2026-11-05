import XCTest
import UIKit
import UniformTypeIdentifiers
import VisionKit
import NibContracts
import NibTesting
@testable import FeatImages

final class ImageAssetSpy: AssetStore {
    let base: AssetStore
    let onRead: () throws -> Void
    let onPut: () throws -> Void
    let onTemporary: () throws -> Void
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }

    init(_ base: AssetStore, onRead: @escaping () throws -> Void = {},
         onPut: @escaping () throws -> Void = {}, onTemporary: @escaping () throws -> Void = {}) {
        self.base = base
        self.onRead = onRead
        self.onPut = onPut
        self.onTemporary = onTemporary
    }
    func data(_ ref: AssetRef, doc: DocumentID) throws -> Data {
        lock.lock(); reads += 1; lock.unlock()
        try onRead()
        return try base.data(ref, doc: doc)
    }
    func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef {
        try onPut()
        return try base.put(data, ext: ext, doc: doc)
    }
    func url(_ ref: AssetRef, doc: DocumentID) -> URL? { base.url(ref, doc: doc) }
    func putTemporary(_ data: Data, ext: String) throws -> AssetRef {
        try onTemporary()
        return try base.putTemporary(data, ext: ext)
    }
    func temporaryURL(_ ref: AssetRef) -> URL? { base.temporaryURL(ref) }
}

@MainActor
final class ImageImportRegressionTests: XCTestCase {
    func testAccessibleActionsCanKeepAnOffCentreSubjectAndAdjustEveryEdge() {
        var rect = CropEditing.scaled(ImageGeometry.unit, by: 0.5)
        for _ in 0..<5 {
            rect = CropAdjustment.moveLeft.apply(to: rect)
            rect = CropAdjustment.moveUp.apply(to: rect)
        }
        XCTAssertEqual(rect.x, 0, accuracy: 1e-12)
        XCTAssertEqual(rect.y, 0, accuracy: 1e-12)
        XCTAssertEqual(rect.width, 0.5, accuracy: 1e-12)
        XCTAssertEqual(rect.height, 0.5, accuracy: 1e-12)
        for action in CropAdjustment.allCases {
            let centred = Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            XCTAssertNotEqual(action.apply(to: centred), centred)
            XCTAssertFalse(action.title.isEmpty)
        }
    }

    func testCancelledRectanglePreviewCannotBecomeTheNextDragOrigin() {
        let committed = Rect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        var draft = CropGestureDraft()
        draft.move(from: committed, handle: nil, dx: 0.2, dy: 0.1)
        XCTAssertNotEqual(draft.rectangle, committed)
        draft = CropGestureDraft() // The GestureState lifetime reset discards the preview on cancellation.
        XCTAssertEqual(draft.rectangle ?? committed, committed)
        draft.move(from: committed, handle: .topLeft, dx: 0.1, dy: 0.1)
        XCTAssertEqual(draft.rectangle, CropEditing.drag(committed, handle: .topLeft, dx: 0.1, dy: 0.1))
    }

    func testCancelledFreehandPreviewCannotJoinTheNextOutline() {
        let committed = [Point(0, 0), Point(1, 0), Point(1, 1)]
        var draft = CropGestureDraft()
        draft.append(Point(0.9, 0.9))
        draft.append(Point(0.8, 0.9))
        draft = CropGestureDraft()
        XCTAssertEqual(draft.outline(or: committed), committed)
        let fresh = [Point(0.1, 0.1), Point(0.3, 0.1), Point(0.2, 0.3)]
        fresh.forEach { draft.append($0) }
        XCTAssertEqual(draft.outline(or: committed), fresh)
        XCTAssertEqual(draft.points.count, 3)
    }

    func testCropRejectsImageReplacedOrFlippedWhileSheetOpen() async throws {
        for command in ["image.replace", "image.flip"] {
            let h = Harness(features: [FeatImagesFeature.self])
            let ref = "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01"
            var intervening: Item?
            h.app.commands.register(CommandDescriptor(id: "test.crop", title: "Crop", summary: "Interactive crop regression.",
                                                      effect: .edit)) { _, ctx in
                _ = try await ImageCrop.run(ImageCrop.Params(ref: ref), ctx, ask: { doc, page, id, context in
                    let previewed = try context.workspace.item(doc, page: page, id: id)
                    let params: JSONValue = command == "image.replace"
                        ? ["ref": .string(ref), "asset": "fixture-image.png"]
                        : ["ref": .string(ref), "axis": "horizontal"]
                    _ = try await context.execute(command, params)
                    intervening = try context.workspace.item(doc, page: page, id: id)
                    return ImageCrop.Preview(request: .rect(Rect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)),
                                             revision: previewed.rev)
                })
                return .null
            }
            do {
                try await h.run("test.crop")
                XCTFail("A stale crop must not change the edited image")
            } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
            let actual = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)
            XCTAssertEqual(actual, try XCTUnwrap(intervening))
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "only the intervening edit is undoable")
        }
    }

    func testLateImportPreservesSelectionAndToolAfterNavigation() async throws {
        for returnToOrigin in [false, true] {
            let h = Harness(features: [FeatImagesFeature.self])
            h.session.page = Fixtures.page2
            h.session.tool = "image"
            var selections = 0
            h.app.commands.register(CommandDescriptor(id: CommandIDs.selectionSet, title: "Select", summary: "Test selection.",
                                                      effect: .session)) { _, _ in
                selections += 1
                return .null
            }
            h.app.commands.register(CommandDescriptor(id: "test.lateImage", title: "Import", summary: "Delayed image import.",
                                                      effect: .edit)) { _, ctx in
                await Task.yield()
                h.session.document = "FIXTUREDOC04"
                h.session.page = "FIXTUREBRD01"
                if returnToOrigin {
                    h.session.document = Fixtures.docID
                    h.session.page = Fixtures.page2
                }
                return try await ctx.execute("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002",
                    "asset": "fixture-image.png", "id": "LATEIMAGE"])
            }
            let selection = h.session.selection
            let refs = await ImageUI.perform(h.app, [("test.lateImage", [:])], session: h.session,
                target: ImageMenuTarget(doc: Fixtures.docID, page: Fixtures.page2, point: nil))
            XCTAssertEqual(refs, ["item:FIXTUREDOC01/FIXTUREPG002/LATEIMAGE"])
            XCTAssertNotNil(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "LATEIMAGE").image)
            XCTAssertEqual(selections, 0)
            XCTAssertEqual(h.session.selection, selection)
            XCTAssertEqual(h.session.tool, "image")
        }
    }

    func testProviderFailureRejectsTheWholeSelection() async {
        let good = NSItemProvider()
        good.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(Fixtures.pngData, nil)
            return nil
        }
        let bad = NSItemProvider()
        bad.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, URLError(.cannotDecodeContentData))
            return nil
        }
        for providers in [[bad], [good, bad], [NSItemProvider()]] {
            let finished = expectation(description: "Provider failure delivered")
            var failed = false
            Task { @MainActor in
                defer { finished.fulfill() }
                do { _ = try await ImageProviders.load(providers) }
                catch { failed = true }
            }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertTrue(failed, "failed and partial selections must not appear cancelled or successful")
        }
        do {
            let cancelled = try await ImageProviders.load([])
            XCTAssertTrue(cancelled.isEmpty)
        } catch { XCTFail("Cancellation must succeed: \(error)") }
    }

    func testFilesReadOffMainAndRejectUnreadableSelections() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Fixtures.pngData.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let images = try await ImageFiles.load([file], reader: { url in
            XCTAssertFalse(Thread.isMainThread)
            return try Data(contentsOf: url)
        })
        XCTAssertEqual(images, [Fixtures.pngData])
        do {
            _ = try await ImageFiles.load([file, file.appendingPathExtension("missing")])
            XCTFail("One unreadable file must reject the selection before insertion")
        } catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
    }

    func testScannerFailureIsNotCancellationAndCompletesOnlyOnce() throws {
        let session = ScanSession()
        var results: [Result<[Data], Error>] = []
        session.receive = { results.append($0) }
        let scanner = VNDocumentCameraViewController()
        session.documentCameraViewController(scanner, didFailWithError: URLError(.unknown))
        session.documentCameraViewControllerDidCancel(scanner)
        XCTAssertEqual(results.count, 1)
        XCTAssertThrowsError(try XCTUnwrap(results.first).get()) { error in
            XCTAssertEqual((error as? NibError)?.code, .unavailable)
        }
    }

    func testTemporaryStorageFailureRejectsBatchAndReportsError() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        var writes = 0
        h.app.services.assets = ImageAssetSpy(h.assets, onTemporary: {
            writes += 1
            if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let reported = expectation(description: "Staging error reported")
        let observer = NotificationCenter.default.addObserver(forName: .nibCommandFailed, object: h.app, queue: nil) { note in
            XCTAssertEqual((note.userInfo?["error"] as? NibError)?.code, .unavailable)
            reported.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let before = try h.snapshot()
        do {
            _ = try await ImageUI.insertCalls([Fixtures.pngData, Fixtures.pngData],
                target: ImageMenuTarget(doc: Fixtures.docID, page: Fixtures.page2, point: nil), app: h.app, session: h.session)
            XCTFail("Staging must not return a shortened command list")
        } catch { ImageLoading.report(error, app: h.app) }
        await fulfillment(of: [reported], timeout: 2)
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testInsertRejectsIDClaimedDuringAssetRead() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        let reading = expectation(description: "Asset read suspended")
        let finished = expectation(description: "Insert completed")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        h.app.services.assets = ImageAssetSpy(h.assets, onRead: {
            XCTAssertFalse(Thread.isMainThread)
            reading.fulfill()
            guard gate.wait(timeout: .now() + 5) == .success else { throw NibError.unavailable("test gate") }
        })
        var failure: NibError?
        Task { @MainActor in
            defer { finished.fulfill() }
            do {
                try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002",
                    "asset": "fixture-image.png", "id": "CLAIMED"])
            } catch { failure = NibError.wrap(error) }
        }
        await fulfillment(of: [reading], timeout: 2)
        var claimed = Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: 1, y: 2, w: 30, h: 40)))
        claimed.id = "CLAIMED"
        claimed.rev = h.app.clock.tick()
        h.app.bus.applyRemote(DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page2.raw: [claimed]]), origin: "test")
        let before = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: claimed.id)
        gate.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(failure?.code, .conflict)
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: claimed.id), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testPickerDeliveryStoresOffMainAndDoesNotRereadPreparedAssets() async throws {
        let h = Harness(features: [FeatImagesFeature.self])
        let spy = ImageAssetSpy(h.assets, onRead: { XCTAssertFalse(Thread.isMainThread) },
                                onPut: { XCTAssertFalse(Thread.isMainThread) })
        h.app.services.assets = spy
        h.app.commands.register(CommandDescriptor(id: "test.deliver", title: "Deliver", summary: "Test picker delivery.",
                                                  effect: .edit)) { _, ctx in
            let refs = try await ImagePick.deliver([Fixtures.pngData, Fixtures.pngData],
                to: .insert(Fixtures.docID, Fixtures.page2, nil), ids: ["PHOTO1", "PHOTO2"], ctx: ctx)
            return .array(refs.map { .string($0) })
        }
        let result = try await h.run("test.deliver")
        XCTAssertEqual(result.arrayValue?.count, 2)
        XCTAssertEqual(spy.readCount, 0, "nested commands reuse only trusted prepared metadata")
        for id: NibID in ["PHOTO1", "PHOTO2"] {
            let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: id)
            XCTAssertEqual(try h.assets.data(XCTUnwrap(item.image?.asset), doc: Fixtures.docID), Fixtures.pngData)
        }
        // The task-local optimisation expires with delivery; ordinary commands still validate stored bytes.
        try await h.run("image.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "asset": "fixture-image.png"])
        XCTAssertEqual(spy.readCount, 1)
    }
}
