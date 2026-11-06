import XCTest
import NibContracts
import NibTesting
@testable import FeatCollab

struct CollabTestTimeout: Error {
    let step: String
}

@MainActor
private final class CollabTestCompletion<Value> {
    var continuation: CheckedContinuation<Value, Error>?

    func finish(_ result: Result<Value, Error>) {
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
    }
}

private final class CollabDeadlineOwner {}

/// A wall-clock test deadline, independent of production silence/progress timers. Unstructured
/// tasks are intentional: a task group would wait forever for a child that ignores cancellation.
@MainActor
func withCollabDeadline<Value>(_ step: String, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line,
                              report: ((String) -> Void)? = nil,
                              cleanup: @escaping @MainActor () -> Void = {},
                              operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
    let completion = CollabTestCompletion<Value>()
    let work = Task { @MainActor in
        do { completion.finish(.success(try await operation())) }
        catch { completion.finish(.failure(error)) }
    }
    let watchdog = Task { @MainActor in
        do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
        catch { return }
        guard completion.continuation != nil else { return }
        let message = "Timed out during \(step) after \(timeout) seconds"
        if let report { report(message) } else { XCTFail(message, file: file, line: line) }
        work.cancel()
        cleanup()
        completion.finish(.failure(CollabTestTimeout(step: step)))
    }
    defer { work.cancel(); watchdog.cancel() }
    let value: Value = try await withCheckedThrowingContinuation { completion.continuation = $0 }
    // Release the operation's captures before returning to owner-deallocation assertions.
    await work.value
    watchdog.cancel()
    await watchdog.value
    return value
}

@MainActor
extension Harness {
    @discardableResult
    func runBounded(_ command: String, _ params: JSONValue = [:], as principal: Principal = .user,
                    timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        try await withCollabDeadline(command, timeout: timeout, file: file, line: line,
            cleanup: { [weak service = CollabService.of(app)] in service?.leave() }) {
            try await self.run(command, params, as: principal)
        }
    }

    @discardableResult
    func insertBounded(_ items: [Item], page: PageID = Fixtures.page1, doc: DocumentID = Fixtures.docID,
                       file: StaticString = #filePath, line: UInt = #line) async throws -> [Item] {
        try await withCollabDeadline("insert items on \(page.raw)", file: file, line: line) {
            try await self.insert(items, page: page, doc: doc)
        }
    }
}

@MainActor
extension CollabPair {
    func bounded<Value>(_ step: String, timeout: TimeInterval? = nil,
                        file: StaticString = #filePath, line: UInt = #line,
                        guest: CollabService? = nil, report: ((String) -> Void)? = nil,
                        operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try await withCollabDeadline(step, timeout: timeout ?? stepTimeout, file: file, line: line,
            report: report, cleanup: { [weak host = hostService, weak guest = guest ?? guestService] in
                guest?.leave(); host?.leave()
            }, operation: operation)
    }
}

@MainActor
final class CollabTestDeadlineTests: XCTestCase {
    func testPairDeadlineLeavesBothSessionsEvenWhenWorkIgnoresCancellation() async throws {
        let pair = CollabPair()
        defer { pair.guestService.leave(); pair.hostService.leave() }
        let code = try await pair.share()
        try await pair.join(code)
        var pending: CheckedContinuation<Void, Never>?
        var failures: [String] = []
        let timedOut = expectation(description: "test deadline releases stalled admission")
        let finished = expectation(description: "cancelled work eventually releases its continuation")
        // Deliberately ignore cancellation, like a stuck admission continuation. The watchdog
        // must return without awaiting this work; release it explicitly after checking the error.
        defer { pending?.resume(); pending = nil }
        let attempt = Task { @MainActor in
            do {
                try await pair.bounded("stalled initial admission", timeout: 0.02,
                    report: { failures.append($0) }) {
                    await withCheckedContinuation { pending = $0 }
                    finished.fulfill()
                }
                XCTFail("stalled admission completed without a deadline error")
            } catch let error as CollabTestTimeout {
                XCTAssertEqual(error.step, "stalled initial admission")
            } catch {
                XCTFail("unexpected admission error: \(error)")
            }
            timedOut.fulfill()
        }
        defer { attempt.cancel() }
        // The watchdog's own regression test also has an independent XCTest deadline.
        await fulfillment(of: [timedOut], timeout: 1)
        XCTAssertNil(pair.hostService.session)
        XCTAssertNil(pair.guestService.session)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("stalled initial admission") == true)
        pending?.resume()
        pending = nil
        await fulfillment(of: [finished], timeout: 1)
    }

    func testSuccessfulDeadlineReleasesOwnersAndCancelsLateCleanup() async throws {
        var owner: CollabDeadlineOwner? = CollabDeadlineOwner()
        weak var released = owner
        var cleanups = 0
        let value = try await withCollabDeadline("completed setup", timeout: 0.02,
            cleanup: { [weak owner] in cleanups += 1; _ = owner }) { [owner = owner!] in
            XCTAssertTrue(owner === released)
            return 7
        }
        XCTAssertEqual(value, 7)
        owner = nil
        XCTAssertNil(released)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(cleanups, 0, "successful setup must disarm its watchdog before teardown")
    }
}
