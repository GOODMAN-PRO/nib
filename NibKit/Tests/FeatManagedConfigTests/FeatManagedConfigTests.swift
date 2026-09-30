import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatManagedConfig

/// An MDM configuration held in memory.
final class FakeManagedSource: ManagedConfigSource {
    var configuration: [String: Any]?
    private(set) var reads = 0

    init(_ configuration: [String: Any]?) {
        self.configuration = configuration
    }

    func managedConfiguration() -> [String: Any]? {
        reads += 1
        return configuration
    }
}

@MainActor
final class FeatManagedConfigTests: XCTestCase {
    // The same configuration in the two forms MDM consoles produce.
    private let nested: [String: Any] = [
        "webdav": ["url": "https://dav.example.com/nib", "allowUntrusted": false, "port": 443] as [String: Any],
        "backup": ["reminder": ["enabled": true, "days": 7] as [String: Any]],
        "library": ["folders": ["Maths", "Physics"]],
        "organisation": "Example School"
    ]
    private let flat: [String: Any] = [
        "webdav.url": "https://dav.example.com/nib",
        "webdav.allowUntrusted": false,
        "webdav.port": 443,
        "backup.reminder.enabled": true,
        "backup.reminder.days": 7,
        "library.folders": ["Maths", "Physics"],
        "organisation": "Example School"
    ]
    private let expected: [String: JSONValue] = [
        "webdav.url": "https://dav.example.com/nib",
        "webdav.allowUntrusted": false,
        "webdav.port": 443,
        "backup.reminder.enabled": true,
        "backup.reminder.days": 7,
        "library.folders": ["Maths", "Physics"],
        "organisation": "Example School"
    ]

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func assertPermissionDenied(_ h: Harness, _ command: String, _ params: JSONValue, as principal: Principal,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await h.run(command, params, as: principal)
            XCTFail("\(command) \(params.jsonString()) should be refused", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied, e.message, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testFeatureID() {
        XCTAssertEqual(FeatManagedConfigFeature.id, "managed")
    }

    // MARK: Parsing

    func testParsesNestedForm() {
        let out = ManagedConfigParser.parse(nested)
        XCTAssertEqual(out.values, expected)
        XCTAssertEqual(out.skipped, [])
    }

    func testParsesFlatForm() {
        let out = ManagedConfigParser.parse(flat)
        XCTAssertEqual(out.values, expected)
        XCTAssertEqual(out.skipped, [])
        XCTAssertEqual(out, ManagedConfigParser.parse(nested))
    }

    func testMixedFormsMergeAndFlatSpellingWins() {
        let out = ManagedConfigParser.parse([
            "webdav": ["url": "https://nested.example.com", "user": "ann"],
            "webdav.url": "https://flat.example.com",
            // Same level twice: the first in key order ("x" before "x.y") wins.
            "x": ["y.z": 1],
            "x.y": ["z": 2]
        ])
        XCTAssertEqual(out.values, [
            "webdav.url": "https://flat.example.com",
            "webdav.user": "ann",
            "x.y.z": 1
        ])
        XCTAssertEqual(out.skipped, ["webdav.url", "x.y.z"])
    }

    func testConvertsPropertyListValuesAndNormalisesKeys() {
        let out = ManagedConfigParser.parse([
            "flag": NSNumber(value: true),
            "count": NSNumber(value: 1),
            "ratio": 0.5,
            "since": Date(timeIntervalSince1970: 1_700_000_000),
            "blob": Data([1, 2, 3]),
            "mixed": [1, "two", ["three": 3]] as [Any],
            " spaced . key ": "trimmed",
            "a..b": "collapsed",
            "": "no name",
            "...": "no name either",
            "nan": Double.nan,
            "link": URL(string: "https://example.com") as Any
        ])
        XCTAssertEqual(out.values, [
            "flag": true,
            "count": 1,
            "ratio": 0.5,
            "since": "2023-11-14T22:13:20Z",
            "blob": "AQID",
            "mixed": [1, "two", ["three": 3]],
            "spaced.key": "trimmed",
            "a.b": "collapsed"
        ])
        XCTAssertEqual(out.values["flag"]?.boolValue, true, "an NSNumber boolean stays a boolean")
        XCTAssertNil(out.values["count"]?.boolValue, "an NSNumber 1 stays a number")
        XCTAssertEqual(out.skipped, ["", "...", "link", "nan"])
    }

    func testDepthAndEntryLimits() {
        var deep: [String: Any] = ["l9": "deep"]
        for i in stride(from: 8, through: 0, by: -1) { deep = ["l\(i)": deep] }
        let out = ManagedConfigParser.parse(deep)
        XCTAssertEqual(out.values, ["l0.l1.l2.l3.l4.l5.l6.l7": ["l8": ["l9": "deep"]]])

        var many: [String: Any] = [:]
        for i in 0..<600 { many[String(format: "k%03d", i)] = i }
        let capped = ManagedConfigParser.parse(many)
        XCTAssertEqual(capped.values.count, ManagedConfigParser.maxEntries)
        XCTAssertEqual(capped.skipped.count, 600 - ManagedConfigParser.maxEntries)
        XCTAssertEqual(capped.values["k511"], 511)
        XCTAssertNil(capped.values["k512"])
    }

    // MARK: Reader

    func testMirrorsIntoReadOnlySettings() async throws {
        let h = Harness(fixtures: false)
        let reader = ManagedConfigReader(settings: h.app.settings, events: h.app.events, source: FakeManagedSource(nested))
        var events: [NibEvent] = []
        let sub = h.app.events.subscribe { e in
            if e.type == ManagedConfigReader.changedEvent { events.append(e) }
        }
        defer { sub.cancel() }

        let change = reader.refresh()
        XCTAssertEqual(Set(change.changed), Set(expected.keys.map { "managed." + $0 }))
        XCTAssertEqual(change.removed, [])
        XCTAssertEqual(reader.values, expected)

        // Read through the query API, typed and untyped.
        let url = try await h.run("settings.get", ["name": "managed.webdav.url"], as: .ai("test"))
        XCTAssertEqual(url["value"], "https://dav.example.com/nib")
        XCTAssertEqual(h.app.settings.get(SettingKey("managed.backup.reminder.days", default: 0)), 7)
        XCTAssertEqual(h.app.settings.get(SettingKey("managed.webdav.allowUntrusted", default: true)), false)
        XCTAssertEqual(h.app.settings.undeclaredNames, [])

        // Every key is listed and described as read-only.
        let list = try await h.run("settings.list", ["prefix": "managed."])
        let rows = list["settings"]?.arrayValue ?? []
        let names = Set(rows.compactMap { $0["name"]?.stringValue })
        XCTAssertTrue(names.isSuperset(of: expected.keys.map { "managed." + $0 }))
        XCTAssertEqual(rows.first { $0["name"] == "managed.webdav.url" }?["owner"], "managed")
        let described = try await h.run("settings.describe", ["name": "managed.webdav.port"])
        XCTAssertEqual(described["readOnly"], true)

        // Nobody can change them: not the user, not the AI.
        await assertPermissionDenied(h, "settings.set", ["name": "managed.webdav.url", "value": "https://evil.example.com"],
                                     as: .user)
        await assertPermissionDenied(h, "settings.set", ["name": "managed.webdav.allowUntrusted", "value": true],
                                     as: .ai("test"))
        XCTAssertEqual(h.app.settings.json("managed.webdav.url"), "https://dav.example.com/nib")

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.payload?["changed"]?.arrayValue?.count, expected.count)
    }

    func testRefreshIsIdempotentAndRemovesDroppedKeys() async throws {
        let h = Harness(fixtures: false)
        let source = FakeManagedSource(nested)
        let reader = ManagedConfigReader(settings: h.app.settings, events: h.app.events, source: source)
        var eventCount = 0
        let sub = h.app.events.subscribe { e in
            if e.type == ManagedConfigReader.changedEvent { eventCount += 1 }
        }
        defer { sub.cancel() }
        reader.refresh()
        XCTAssertEqual(eventCount, 1)

        XCTAssertTrue(reader.refresh().isEmpty, "an unchanged dictionary writes nothing")
        XCTAssertTrue(reader.refresh(force: true).isEmpty, "re-applying the same values writes nothing")
        XCTAssertEqual(eventCount, 1)

        source.configuration = ["webdav": ["url": "https://dav2.example.com"]]
        let change = reader.refresh()
        XCTAssertEqual(change.changed, ["managed.webdav.url"])
        XCTAssertEqual(Set(change.removed), Set(expected.keys.filter { $0 != "webdav.url" }.map { "managed." + $0 }))
        XCTAssertEqual(h.app.settings.json("managed.webdav.url"), "https://dav2.example.com")
        XCTAssertNil(h.app.settings.json("managed.webdav.port"))
        let port = try await h.run("settings.get", ["name": "managed.webdav.port"])
        XCTAssertNil(port["value"])
        let described = try await h.run("settings.describe", ["name": "managed.webdav.port"])
        XCTAssertEqual(described["readOnly"], true)
        XCTAssertEqual(eventCount, 2)

        // Un-enrolled: the managed dictionary disappears and so do the settings.
        source.configuration = nil
        XCTAssertEqual(reader.refresh().removed, ["managed.webdav.url"])
        XCTAssertEqual(h.app.settings.names(prefix: "managed."), [])
        XCTAssertEqual(reader.values, [:])
    }

    func testClearsValuesLeftByAnEarlierEnrolment() {
        let h = Harness(fixtures: false)
        h.app.settings.setJSON("managed.old.server", "https://gone.example.com")
        let reader = ManagedConfigReader(settings: h.app.settings, events: h.app.events, source: FakeManagedSource(nil))
        XCTAssertEqual(reader.refresh(), ManagedConfigChange(changed: [], removed: ["managed.old.server"]))
        XCTAssertNil(h.app.settings.json("managed.old.server"))
    }

    func testRefreshesOnUserDefaultsChanges() async {
        let suiteName = "nib.tests.managed." + UUID().uuidString
        guard let suite = UserDefaults(suiteName: suiteName) else { return XCTFail("no scratch defaults suite") }
        defer { suite.removePersistentDomain(forName: suiteName) }
        let h = Harness(fixtures: false)
        let reader = ManagedConfigReader(settings: h.app.settings, events: h.app.events,
                                         source: UserDefaultsManagedConfigSource(defaults: suite))
        reader.refresh()
        XCTAssertEqual(reader.values, [:])
        reader.startObserving()
        defer { reader.stopObserving() }

        suite.set(flat, forKey: UserDefaultsManagedConfigSource.key)
        await waitUntil { h.app.settings.json("managed.webdav.url") == "https://dav.example.com/nib" }
        XCTAssertEqual(reader.values, expected)
        XCTAssertEqual(h.app.settings.json("managed.library.folders"), ["Maths", "Physics"])

        suite.set(["webdav": ["url": "https://dav2.example.com"]], forKey: UserDefaultsManagedConfigSource.key)
        await waitUntil { h.app.settings.json("managed.organisation") == nil }
        XCTAssertEqual(h.app.settings.json("managed.webdav.url"), "https://dav2.example.com")
        XCTAssertEqual(reader.values, ["webdav.url": "https://dav2.example.com"])

        reader.stopObserving()
        XCTAssertFalse(reader.isObserving)
        try? await Task.sleep(nanoseconds: 50_000_000)
        suite.set(["organisation": "Later"], forKey: UserDefaultsManagedConfigSource.key)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(h.app.settings.json("managed.organisation"), "no refresh after stopObserving")
    }

    func testRefreshesWhenReturningToForeground() async {
        let h = Harness(fixtures: false)
        let center = NotificationCenter()
        let source = FakeManagedSource(nil)
        let reader = ManagedConfigReader(settings: h.app.settings, events: h.app.events, source: source)
        reader.refresh()
        reader.startObserving(center: center)
        defer { reader.stopObserving() }

        source.configuration = ["backup.reminder.days": 14]
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await waitUntil { h.app.settings.json("managed.backup.reminder.days") == 14 }
        XCTAssertEqual(h.app.settings.json("managed.backup.reminder.days"), 14)
    }

    func testBurstOfNotificationsRefreshesOnce() async {
        let h = Harness(fixtures: false)
        let center = NotificationCenter()
        let source = FakeManagedSource(["organisation": "Example School"])
        let reader = ManagedConfigReader(settings: h.app.settings, events: h.app.events, source: source)
        reader.refresh()
        reader.startObserving(center: center)
        defer { reader.stopObserving() }
        let before = source.reads

        for _ in 0..<5 { center.post(name: UserDefaults.didChangeNotification, object: nil) }
        await waitUntil { source.reads > before }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(source.reads, before + 1)

        // Queued refreshes are dropped once observing stops.
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        reader.stopObserving()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(source.reads, before + 1)
    }

    // MARK: Feature

    func testRegisterInstallsReaderAndStartObserves() async {
        let bare = Harness(features: [], fixtures: false)
        let h = Harness(features: [FeatManagedConfigFeature.self], fixtures: false)
        XCTAssertEqual(h.app.commands.all().count, bare.app.commands.all().count, "F097 owns no commands")
        guard let reader = h.app.services.get(ManagedConfigReader.serviceKey, as: ManagedConfigReader.self) else {
            return XCTFail("reader not installed")
        }
        XCTAssertTrue(reader.source is UserDefaultsManagedConfigSource)
        XCTAssertFalse(reader.isObserving)
        await FeatManagedConfigFeature.start(h.app)
        XCTAssertTrue(reader.isObserving)
        reader.stopObserving()
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatManagedConfigFeature.self])
        XCTAssertEqual(problems, [])
    }
}
