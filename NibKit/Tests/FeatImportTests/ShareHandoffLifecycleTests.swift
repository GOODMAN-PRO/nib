import XCTest
import UIKit
import NibContracts
@testable import FeatImport

@MainActor
final class ShareHandoffLifecycleTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testUnresponsiveDataOrNameProviderTimesOutWithoutConsumingAndCanRetry() async throws {
        for stalledType in [ShareHandoff.dataType, ShareHandoff.nameType] {
            let fixture = HandoffTestFixture()
            defer { fixture.restore() }
            let dir = try directory()
            let provider = NSItemProvider()
            let loading = Progress(totalUnitCount: 1)
            var late: ((Data?, Error?) -> Void)?
            for (type, data) in [ShareHandoff.dataType: Data("original".utf8),
                                 ShareHandoff.nameType: Data("shared.pdf".utf8)] {
                provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                    Task { @MainActor in
                        if type == stalledType { late = completion }
                        else { completion(data, nil) }
                    }
                    return type == stalledType ? loading : nil
                }
            }
            fixture.board.providers = [provider]
            do {
                _ = try await importStep("unresponsive \(stalledType) provider reports its deadline") {
                    try await ShareHandoff.take(into: dir, timeoutNanoseconds: 20_000_000)
                }
                XCTFail("Missing provider callback must fail")
            } catch { XCTAssertEqual(NibError.wrap(error).code, .unavailable) }
            XCTAssertTrue(loading.isCancelled)
            XCTAssertTrue(ShareHandoff.isWaiting)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
            late?(Data("late".utf8), nil)
            fixture.board.items = [[ShareHandoff.nameType: "shared.pdf", ShareHandoff.dataType: Data("original".utf8)]]
            let saved = try await importStep("retry after provider timeout releases handoff ownership") {
                try await ShareHandoff.take(into: dir)
            }
            XCTAssertEqual(saved.map { $0.lastPathComponent }, ["shared.pdf"])
            XCTAssertEqual(try Data(contentsOf: saved[0]), Data("original".utf8))
            XCTAssertFalse(ShareHandoff.isWaiting)
        }
    }

    func testCancellationReleasesPendingProviderAndConcurrentScanDoesNotDuplicate() async throws {
        let fixture = HandoffTestFixture()
        defer { fixture.restore() }
        let dir = try directory()
        let started = expectation(description: "provider requested")
        let finished = expectation(description: "cancelled handoff returned")
        var late: ((Data?, Error?) -> Void)?
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: ShareHandoff.dataType, visibility: .all) { completion in
            Task { @MainActor in late = completion; started.fulfill() }
            return Progress(totalUnitCount: 1)
        }
        fixture.board.providers = [provider]
        let task = Task { @MainActor in
            do {
                _ = try await ShareHandoff.take(into: dir)
                XCTFail("Cancelled handoff must fail")
            } catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 2)
        let concurrent = try await importStep("activation scan leaves the pending deep link alone") {
            try await ShareHandoff.take(into: dir)
        }
        XCTAssertTrue(concurrent.isEmpty)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(ShareHandoff.isWaiting)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        late?(Data("late".utf8), nil)
        fixture.board.items = [[ShareHandoff.nameType: "retry.pdf", ShareHandoff.dataType: Data("original".utf8)]]
        let saved = try await importStep("retry after cancellation completes") { try await ShareHandoff.take(into: dir) }
        XCTAssertEqual(saved.count, 1)
    }

    func testProviderFailureRetainsTheWholePayloadWithoutWritingPartialCopies() async throws {
        let fixture = HandoffTestFixture()
        defer { fixture.restore() }
        let dir = try directory()
        fixture.board.items = [[ShareHandoff.nameType: "first.pdf", ShareHandoff.dataType: Data("first".utf8)]]
        let broken = NSItemProvider()
        broken.registerDataRepresentation(forTypeIdentifier: ShareHandoff.dataType, visibility: .all) { completion in
            DispatchQueue.main.async { completion(nil, NibError(.userDenied, "Paste denied")) }
            return nil
        }
        fixture.board.providers.append(broken)
        do {
            _ = try await importStep("provider error reports failure without consuming any items") {
                try await ShareHandoff.take(into: dir)
            }
            XCTFail("Unreadable handoff must fail")
        } catch { XCTAssertEqual(NibError.wrap(error).code, .userDenied) }
        XCTAssertTrue(ShareHandoff.isWaiting)
        XCTAssertFalse(ShareHandoff.shouldOffer(isWaiting: true, changeCount: fixture.board.changeCount))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testClipboardReplacementDuringLoadingIsNeverClearedOrImported() async throws {
        let fixture = HandoffTestFixture()
        defer { fixture.restore() }
        let dir = try directory()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: ShareHandoff.dataType, visibility: .all) { completion in
            Task { @MainActor in
                fixture.board.items = [[ShareHandoff.dataType: Data("new clipboard".utf8)]]
                completion(Data("old clipboard".utf8), nil)
            }
            return nil
        }
        fixture.board.providers = [provider]
        do {
            _ = try await importStep("clipboard replacement rejects stale handoff") { try await ShareHandoff.take(into: dir) }
            XCTFail("A stale snapshot must not clear newer clipboard contents")
        } catch { XCTAssertEqual(NibError.wrap(error).code, .unavailable) }
        XCTAssertTrue(ShareHandoff.isWaiting)
        XCTAssertEqual(fixture.board.items.first?[ShareHandoff.dataType] as? Data, Data("new clipboard".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testWriteFailureRollsBackPartialFilesAndPreservesUpstreamPayload() async throws {
        let fixture = HandoffTestFixture()
        defer { fixture.restore() }
        let dir = try directory()
        let bytes = Data("original".utf8)
        // Under the character limit but over the filesystem's 255-byte component limit after UTF-8 encoding.
        let invalidName = String(repeating: "界", count: 100) + ".pdf"
        fixture.board.items = [[ShareHandoff.nameType: "first.pdf", ShareHandoff.dataType: bytes],
                               [ShareHandoff.nameType: invalidName, ShareHandoff.dataType: bytes]]
        do {
            _ = try await importStep("partial handoff write rolls back") { try await ShareHandoff.take(into: dir) }
            XCTFail("Overlong filename must fail")
        } catch { XCTAssertTrue(error is CocoaError) }
        XCTAssertTrue(ShareHandoff.isWaiting)
        XCTAssertEqual(fixture.board.items.count, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
