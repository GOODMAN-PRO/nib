import XCTest
import UIKit
import NibContracts
@testable import FeatImport

/// The production provider loader still runs; only the simulator's permission service is replaced.
@MainActor
final class HandoffTestBoard: ShareHandoffBoard {
    private(set) var changeCount = 0
    var providers: [NSItemProvider] = [] { didSet { changeCount += 1 } }
    var items: [[String: Any]] = [] {
        didSet {
            providers = items.map { item in
                let provider = NSItemProvider()
                for (type, value) in item {
                    if let data = (value as? Data) ?? (value as? String).map({ Data($0.utf8) }) {
                        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                            // The main actor must be free to service this callback.
                            DispatchQueue.main.async { completion(data, nil) }
                            return nil
                        }
                    }
                }
                return provider
            }
        }
    }
    func contains(_ type: String) -> Bool { providers.contains { $0.hasItemConformingToTypeIdentifier(type) } }
    func readProviders() -> [NSItemProvider] { providers }
    func clear() { items = [] }
}

@MainActor
final class HandoffTestFixture {
    let board = HandoffTestBoard()
    private let previous = ShareHandoff.board
    private let lastTaken = ShareHandoff.lastTaken
    private let deniedChangeCount = ShareHandoff.deniedChangeCount

    init() {
        ShareHandoff.board = board
        ShareHandoff.lastTaken = nil
        ShareHandoff.deniedChangeCount = nil
    }

    func restore() {
        ShareHandoff.board = previous
        ShareHandoff.lastTaken = lastTaken
        ShareHandoff.deniedChangeCount = deniedChangeCount
    }
}

private struct ImportStepTimeout: Error {}

extension XCTestCase {
    /// Unstructured task deliberately: a task group would wait forever for an unresumed continuation on exit.
    @MainActor
    func importStep<T>(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                       operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let completed = expectation(description: description)
        var result: Result<T, Error>?
        let task = Task { @MainActor in
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            completed.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [completed], timeout: 2)
        guard let result else {
            XCTFail("Import step did not complete within 2 seconds: \(description)", file: file, line: line)
            throw ImportStepTimeout()
        }
        return try result.get()
    }
}
