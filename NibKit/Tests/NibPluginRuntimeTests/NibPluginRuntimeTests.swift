import XCTest
import NibContracts
import NibTesting
@testable import NibPluginRuntime

/// Feature registration and the runtime's pure parts: storage merge, timer clamping, the fetch allowlist, manifest
/// and entry validation.
@MainActor
final class NibPluginRuntimeTests: XCTestCase {
    func testFeatureRegistersTheRuntimeService() {
        let h = Harness(features: [NibPluginRuntimeFeature.self])
        XCTAssertEqual(NibPluginRuntimeFeature.id, "pluginruntime")
        XCTAssertNotNil(h.app.services.get(ServiceKeys.pluginRuntime, as: PluginRuntimeProviding.self))
        XCTAssertNotNil(h.app.services.get(ServiceKeys.pluginRuntime, as: PluginRuntime.self))
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [NibPluginRuntimeFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: nib.storage merge

    private func storageFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nib-plugin-storage-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("plugin-data/dev.test.plugin", isDirectory: true)
    }

    func testStorageMergesTwoDevicesPerKeyByRevision() throws {
        let folder = storageFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let a = PluginStorage(pluginID: "dev.test.plugin", folder: folder, deviceHex: "0000000a", clock: HLCClock(device: 10),
                              limitBytes: 1_000_000)
        let b = PluginStorage(pluginID: "dev.test.plugin", folder: folder, deviceHex: "0000000b", clock: HLCClock(device: 11),
                              limitBytes: 1_000_000)
        try a.set("shared", "from a")
        try a.set("onlyA", 1)
        try b.set("shared", "from b")          // b reads a's file first, so its revision is newer
        try b.set("onlyB", ["x": true])

        XCTAssertEqual(try a.get("shared"), "from b")
        XCTAssertEqual(try a.keys(), ["onlyA", "onlyB", "shared"])
        XCTAssertEqual(try b.get("onlyA"), 1)

        try a.remove("onlyB")                   // a tombstone beats b's older value
        XCTAssertNil(try b.get("onlyB"))
        XCTAssertEqual(try b.keys(), ["onlyA", "shared"])

        // Each device wrote only its own file.
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["storage.0000000a.json", "storage.0000000b.json"])
    }

    func testStorageMergesAndDeletesConflictCopies() throws {
        let folder = storageFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let a = PluginStorage(pluginID: "dev.test.plugin", folder: folder, deviceHex: "0000000a", clock: HLCClock(device: 10),
                              limitBytes: 1_000_000)
        try a.set("k", "old")
        let future = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000, counter: 0, device: 12)
        let body = PluginStorage.FileBody(plugin: "dev.test.plugin", entries: ["k": .init(rev: future, value: "newer")])
        let copy = folder.appendingPathComponent("storage.0000000a 2.json")
        try JSONEncoder().encode(body).write(to: copy)

        XCTAssertEqual(try a.get("k"), "newer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the conflict copy is merged, then deleted")
        let own = try JSONDecoder().decode(PluginStorage.FileBody.self, from: Data(contentsOf: a.fileURL))
        XCTAssertEqual(own.entries["k"]?.value, "newer")
    }

    func testStorageDistrustsFarFutureRevisions() {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var base: [String: PluginStorage.Entry] = ["k": .init(rev: Rev(wallMs: now, counter: 0, device: 1), value: "good")]
        let broken = Rev(wallMs: now + 3 * 86_400_000, counter: 0, device: 2)   // a device whose clock is days ahead
        PluginStorage.merge(["k": .init(rev: broken, value: "bad")], into: &base, now: now)
        XCTAssertEqual(base["k"]?.value, "good")
    }

    func testStorageEnforcesItsLimit() throws {
        let folder = storageFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let s = PluginStorage(pluginID: "dev.test.plugin", folder: folder, deviceHex: "0000000a", clock: HLCClock(device: 10),
                              limitBytes: 100)
        try s.set("a", .string(String(repeating: "x", count: 60)))
        XCTAssertThrowsError(try s.set("b", .string(String(repeating: "y", count: 60)))) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
        }
        try s.set("a", "small")                  // replacing a value frees its bytes
        try s.set("b", .string(String(repeating: "y", count: 60)))
        XCTAssertEqual(try s.keys(), ["a", "b"])
        XCTAssertThrowsError(try s.set("", 1))
    }

    func testStorageFileNames() {
        XCTAssertTrue(PluginStorage.isStorageFile("storage.1a2b3c4d.json"))
        XCTAssertTrue(PluginStorage.isStorageFile("storage.1a2b3c4d (conflicted copy).json"))
        XCTAssertFalse(PluginStorage.isStorageFile("storage.json"))
        XCTAssertFalse(PluginStorage.isStorageFile("notes.1a2b3c4d.json"))
        XCTAssertTrue(PluginStorage.isConflictCopy("storage.1a2b3c4d 2.json"))
        XCTAssertFalse(PluginStorage.isConflictCopy("storage.1a2b3c4d.json"))
        let folder = PluginStorage.folder(metadata: URL(fileURLWithPath: "/lib/meta"), pluginID: "dev.x")
        XCTAssertEqual(folder.path, "/lib/meta/plugin-data/dev.x")
    }

    // MARK: Timers

    func testTimerDelaysAreClamped() {
        XCTAssertEqual(PluginTimers.delay(milliseconds: 250, repeats: false), 0.25, accuracy: 1e-9)
        XCTAssertEqual(PluginTimers.delay(milliseconds: -5, repeats: false), 0)
        XCTAssertEqual(PluginTimers.delay(milliseconds: .nan, repeats: false), 0)
        XCTAssertEqual(PluginTimers.delay(milliseconds: 0, repeats: true), PluginTimers.minimumInterval)
        XCTAssertEqual(PluginTimers.delay(milliseconds: 1e15, repeats: false), PluginTimers.maximumDelay)
    }

    func testTimersFireOnTheirQueueAndHonourTheCap() {
        let queue = DispatchQueue(label: "test.timers")
        let timers = PluginTimers(queue: queue, maxTimers: 2)
        let fired = expectation(description: "timer 1 fires")
        var ids: [Int] = []
        timers.fire = { id in
            dispatchPrecondition(condition: .onQueue(queue))
            ids.append(id)
            fired.fulfill()
        }
        XCTAssertTrue(timers.set(id: 1, milliseconds: 5, repeats: false))
        XCTAssertTrue(timers.set(id: 2, milliseconds: 60_000, repeats: false))
        XCTAssertFalse(timers.set(id: 3, milliseconds: 5, repeats: false), "at most maxTimers live timers")
        wait(for: [fired], timeout: 5)
        queue.sync {}
        XCTAssertEqual(ids, [1])
        XCTAssertEqual(timers.count, 1)
        timers.cancelAll()
        XCTAssertEqual(timers.count, 0)
        XCTAssertFalse(timers.set(id: 4, milliseconds: 5, repeats: false), "cancelled for good")
    }

    // MARK: Network allowlist

    func testFetchAllowsOnlyHttpsToListedHosts() throws {
        let hosts: Set<String> = ["api.example.com"]
        XCTAssertNoThrow(try PluginFetcher.check(URL(string: "https://api.example.com/v1")!, hosts: hosts))
        XCTAssertNoThrow(try PluginFetcher.check(URL(string: "https://API.Example.com/v1")!, hosts: hosts))
        for bad in ["http://api.example.com/v1", "https://evil.example.com/", "https://api.example.com.evil.net/", "file:///etc/hosts"] {
            XCTAssertThrowsError(try PluginFetcher.check(URL(string: bad)!, hosts: hosts), bad) { error in
                XCTAssertEqual((error as? NibError)?.code, .permissionDenied, bad)
            }
        }
    }

    func testFetchResultShape() throws {
        let url = URL(string: "https://api.example.com/")!
        let json = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let text = PluginFetcher.result(json, data: Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(text["status"], 201)
        XCTAssertEqual(text["text"], #"{"ok":true}"#)
        XCTAssertNil(text["base64"])
        XCTAssertEqual(text["headers"]?["content-type"], "application/json")
        let png = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        let binary = PluginFetcher.result(png, data: Fixtures.pngData)
        XCTAssertEqual(binary["base64"]?.stringValue, Fixtures.pngData.base64EncodedString())
        XCTAssertEqual(binary["text"], "")
    }

    // MARK: Manifest and entry

    func testManifestValidation() throws {
        XCTAssertNoThrow(try PluginRuntime.validate(PluginManifest.fixture(id: "dev.test.plugin")))
        var newer = try PluginManifest.fixture()
        newer.api = 2
        XCTAssertThrowsError(try PluginRuntime.validate(newer)) { XCTAssertEqual(($0 as? NibError)?.code, .unsupported) }
        for id in ["Dev.Test", "nodots", "dev..x", "dev.x/y"] {
            XCTAssertThrowsError(try PluginRuntime.validate(PluginManifest.fixture(id: id)), id)
        }
    }

    func testEntryMustStayInsideThePluginFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nib-entry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inside = try PluginRuntime.entryURL(PluginManifest.fixture(entry: "dist/main.js"), folder: folder)
        XCTAssertTrue(inside.path.hasSuffix("/dist/main.js"))
        for entry in ["../main.js", "/etc/main.js", "a/../../main.js", ""] {
            XCTAssertThrowsError(try PluginRuntime.entryURL(PluginManifest.fixture(entry: entry), folder: folder), entry)
        }
        let script = folder.appendingPathComponent("main.js")
        try Data("let a = 1;".utf8).write(to: script)
        XCTAssertEqual(try PluginRuntime.readEntry(script, maxBytes: 100), "let a = 1;")
        XCTAssertThrowsError(try PluginRuntime.readEntry(script, maxBytes: 3))
        XCTAssertThrowsError(try PluginRuntime.readEntry(folder.appendingPathComponent("missing.js"), maxBytes: 100)) {
            XCTAssertEqual(($0 as? NibError)?.code, .notFound)
        }
    }

    func testPreludeShipsInTheBundle() throws {
        let prelude = try PluginRuntime.preludeSource()
        XCTAssertTrue(prelude.contains("natives.__nib_call"))
    }

    func testPluginErrorsKeepTheirCode() {
        let (e, stack) = PluginInstance.error(fromJSON: #"{"code":"permission_denied","message":"no","hint":"grant it","stack":"at x"}"#)
        XCTAssertEqual(e.code, .permissionDenied)
        XCTAssertEqual(e.hint, "grant it")
        XCTAssertEqual(stack, "at x")
        XCTAssertEqual(PluginInstance.error(fromJSON: #"{"code":"bogus","message":"m"}"#).0.code, .internalError)
        XCTAssertEqual(PluginInstance.error(fromJSON: "not json").0.code, .internalError)
    }
}
