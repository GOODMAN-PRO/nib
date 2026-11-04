import XCTest
@testable import NibContracts

@MainActor
final class BridgeTokenStorageTests: XCTestCase {
    func testFixtureTokenPersistsRotatesAndNeverTouchesKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BridgeTokenStorage(fixtureRoot: root, keychainRead: {
            XCTFail("Fixture must not read production credentials"); return nil
        }, keychainWrite: { _ in
            XCTFail("Fixture must not write production credentials"); return false
        })
        XCTAssertNil(store.read())
        XCTAssertTrue(store.write("first"))
        XCTAssertEqual(store.read(), "first")
        let reopened = BridgeTokenStorage(fixtureRoot: root)
        XCTAssertEqual(reopened.read(), "first")
        XCTAssertTrue(reopened.write("rotated"))
        XCTAssertEqual(store.read(), "rotated")
        XCTAssertFalse(store.write(""))
        XCTAssertEqual(store.read(), "rotated")
    }

    func testProductionStorageFailureDoesNotFallBack() {
        var attempts = 0
        let store = BridgeTokenStorage(fixtureRoot: nil, keychainRead: { nil }, keychainWrite: { _ in
            attempts += 1; return false
        })
        XCTAssertFalse(store.write("secret"))
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(store.read())
    }
}
