import XCTest
import UIKit
import UniformTypeIdentifiers
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
