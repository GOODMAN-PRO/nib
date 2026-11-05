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

    func testDefaultDeadlineAndDelayedProviderCompletion() async throws {
        // Pin the permission budget without spending it in real time on every CI run.
        XCTAssertEqual(ShareHandoff.defaultProviderTimeoutNanoseconds, 60_000_000_000)
        let fixture = HandoffTestFixture()
        defer { fixture.restore() }
        let dir = try directory()
        let bytes = Data("shared after permission".utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: ShareHandoff.dataType, visibility: .all) { completion in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { completion(bytes, nil) }
            return nil
        }
        fixture.board.providers = [provider]
        let saved = try await importStep("handoff completes after a delayed paste permission response") {
            try await ShareHandoff.take(into: dir, timeoutNanoseconds: 1_000_000_000)
        }
        XCTAssertEqual(saved.count, 1)
        if let url = saved.first { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        XCTAssertFalse(ShareHandoff.isWaiting)
    }

    func testUnresponsiveDataOrNameProviderTimesOutWithoutConsumingAndCanRetry() async throws {
        for stalledType in [ShareHandoff.dataType, ShareHandoff.nameType] {
            let fixture = HandoffTestFixture()
            defer { fixture.restore() }
            let dir = try directory()
            let provider = NSItemProvider()
            let loading = Progress(totalUnitCount: 1)
            let late = HandoffTestBox<(Data?, Error?) -> Void>()
            for (type, data) in [ShareHandoff.dataType: Data("original".utf8),
                                 ShareHandoff.nameType: Data("shared.pdf".utf8)] {
                provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                    Task { @MainActor in
                        if type == stalledType { late.value = completion }
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
            XCTAssertTrue(ShareHandoff.isWaiting)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
            late.value?(Data("late".utf8), nil)
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
        let late = HandoffTestBox<(Data?, Error?) -> Void>()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: ShareHandoff.dataType, visibility: .all) { completion in
            Task { @MainActor in late.value = completion; started.fulfill() }
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
        late.value?(Data("late".utf8), nil)
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
        enum WriteFailure: Error, Equatable { case secondItem }
        let fixture = HandoffTestFixture()
        defer { fixture.restore() }
        let dir = try directory()
        let firstBytes = Data("first original".utf8)
        let secondBytes = Data("second original".utf8)
        fixture.board.items = [[ShareHandoff.nameType: "first.pdf", ShareHandoff.dataType: firstBytes],
                               [ShareHandoff.nameType: "second.pdf", ShareHandoff.dataType: secondBytes]]
        var writes = 0
        do {
            _ = try await importStep("partial handoff write rolls back") {
                try await ShareHandoff.take(into: dir) { data, url in
                    writes += 1
                    if writes == 2 {
                        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("first.pdf")), firstBytes)
                        throw WriteFailure.secondItem
                    }
                    try data.write(to: url, options: .atomic)
                }
            }
            XCTFail("The second write must fail")
        } catch {
            XCTAssertEqual(error as? WriteFailure, .secondItem)
        }
        XCTAssertEqual(writes, 2)
        XCTAssertTrue(ShareHandoff.isWaiting)
        XCTAssertEqual(fixture.board.items.count, 2)
        XCTAssertEqual(fixture.board.items.compactMap { $0[ShareHandoff.nameType] as? String }, ["first.pdf", "second.pdf"])
        XCTAssertEqual(fixture.board.items.compactMap { $0[ShareHandoff.dataType] as? Data }, [firstBytes, secondBytes])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        let saved = try await importStep("retry after write failure imports both originals") {
            try await ShareHandoff.take(into: dir)
        }
        XCTAssertEqual(saved.map { $0.lastPathComponent }, ["first.pdf", "second.pdf"])
        XCTAssertEqual(try saved.map { try Data(contentsOf: $0) }, [firstBytes, secondBytes])
        XCTAssertFalse(ShareHandoff.isWaiting)
        XCTAssertTrue(fixture.board.items.isEmpty)
    }
}
