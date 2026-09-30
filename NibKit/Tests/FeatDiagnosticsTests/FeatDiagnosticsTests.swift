import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatDiagnostics

// MARK: - Fakes

/// Safe-mode storage that never touches the test process's real defaults.
final class InMemorySafeModeStore: SafeModeStore {
    var isActive: Bool
    var disabledFeatures: Set<String>

    init(isActive: Bool = false, disabled: Set<String> = []) {
        self.isActive = isActive
        self.disabledFeatures = disabled
    }
}

struct FakeLogSource: DiagnosticsLogSource {
    var entries: [DiagnosticsLogLine]

    func lines(detailed: Bool, limit: Int) throws -> [DiagnosticsLogLine] {
        Array(entries.filter { detailed || $0.level != "debug" }.suffix(limit))
    }
}

final class FakeSwitch: TemporaryDiagnosticSwitch {
    var isOn: Bool
    private(set) var turnedOff = 0

    init(_ isOn: Bool) { self.isOn = isOn }

    func turnOff() {
        isOn = false
        turnedOff += 1
    }
}

@MainActor
final class FakeSharing: DiagnosticsSharing {
    var anchor: UIView?
    private(set) var shared: [URL] = []

    func share(_ url: URL, navigator: SceneNavigator?) -> Bool {
        shared.append(url)
        return true
    }
}

/// A second running feature, so safe-mode switches have something that runs in this launch.
enum FakeLaserFeature: NibFeature {
    static let id = "laser"
    static func register(_ app: NibApp) {}
}

/// Reads zip archives (stored and deflated entries, ZIP64 records) and checks every entry's CRC and size.
struct ZipReader {
    struct Entry {
        var name: String
        var method: UInt16
        var crc: UInt32
        var size: UInt64
        var compressed: UInt64
        var offset: UInt64
    }

    let data: Data
    private(set) var entries: [Entry] = []
    private(set) var usedZip64 = false

    init(_ data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> UInt64 { UInt64(bytes[o]) | UInt64(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt64 { u16(o) | u16(o + 2) << 16 }
        func u64(_ o: Int) -> UInt64 { u32(o) | u32(o + 4) << 32 }
        guard bytes.count >= 22 else { throw CocoaError(.fileReadCorruptFile) }
        var end = bytes.count - 22
        while end >= 0 && u32(end) != 0x0605_4B50 { end -= 1 }
        guard end >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        var count = u16(end + 10)
        var directory = u32(end + 16)
        if end >= 20, u32(end - 20) == 0x0706_4B50 {
            let record = Int(u64(end - 20 + 8))
            guard u32(record) == 0x0606_4B50 else { throw CocoaError(.fileReadCorruptFile) }
            count = u64(record + 32)
            directory = u64(record + 48)
            usedZip64 = true
        }
        var p = Int(directory)
        for _ in 0..<count {
            guard u32(p) == 0x0201_4B50 else { throw CocoaError(.fileReadCorruptFile) }
            var compressed = u32(p + 20)
            var size = u32(p + 24)
            let nameLength = Int(u16(p + 28))
            let extraLength = Int(u16(p + 30))
            let commentLength = Int(u16(p + 32))
            var offset = u32(p + 42)
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = u16(e)
                let length = Int(u16(e + 2))
                if id == 1 {
                    var f = e + 4
                    if size == 0xFFFF_FFFF { size = u64(f); f += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = u64(f); f += 8 }
                    if offset == 0xFFFF_FFFF { offset = u64(f) }
                }
                e += 4 + length
            }
            entries.append(Entry(name: name, method: UInt16(u16(p + 10)), crc: UInt32(u32(p + 16)), size: size,
                                 compressed: compressed, offset: offset))
            p = extraEnd + commentLength
        }
    }

    func contents(_ entry: Entry) throws -> Data {
        let o = Int(entry.offset)
        let bytes = [UInt8](data[o..<(o + 30)])
        guard bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03, bytes[3] == 0x04 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        let extraLength = Int(bytes[28]) | Int(bytes[29]) << 8
        let start = o + 30 + nameLength + extraLength
        let raw = data.subdata(in: start..<(start + Int(entry.compressed)))
        let out = entry.method == 8 ? try (raw as NSData).decompressed(using: .zlib) as Data : raw
        guard CRC32.checksum(out) == entry.crc, UInt64(out.count) == entry.size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return out
    }

    /// Every file (not folder) entry as text, keyed by its path in the archive.
    func texts() throws -> [String: String] {
        var out: [String: String] = [:]
        for entry in entries where !entry.name.hasSuffix("/") {
            out[entry.name] = String(decoding: try contents(entry), as: UTF8.self)
        }
        return out
    }
}

// MARK: - Tests

@MainActor
final class FeatDiagnosticsTests: XCTestCase {
    /// Text that lives inside the fixture documents (NibTesting.Fixtures): none of it may reach a diagnostics zip.
    private let fixtureContent = ["Hello Nib", "Remember", "Check this", "Hello blocks", "Fixture section",
                                  "Fixture recording", "Welcome to the fixture lecture", "Velocity is displacement",
                                  "\\frac{a}{b}", "Fixture box", "Definition", "Fixture PDF text"]
    private let fixtureTitles = ["Fixture Notebook", "Fixture Text Document", "Fixture Study Set", "Fixture Whiteboard"]

    // MARK: Helpers

    private func makeHarness(features: [NibFeature.Type] = [FeatDiagnosticsFeature.self],
                             safeMode: InMemorySafeModeStore = InMemorySafeModeStore()) -> (Harness, DiagnosticsRuntime) {
        let h = Harness(features: features)
        let runtime = DiagnosticsRuntime.resolve(h.app.services)
        runtime.safeMode = safeMode
        runtime.launchedInSafeMode = safeMode.isActive
        runtime.disabledAtLaunch = safeMode.disabledFeatures
        runtime.logSource = FakeLogSource(entries: [])
        runtime.sharing = FakeSharing()
        runtime.diagnosticSwitch = FakeSwitch(false)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nib-diagnostics-tests-" + UUID().uuidString,
                                                                                  isDirectory: true)
        runtime.exportDirectory = base.appendingPathComponent("export", isDirectory: true)
        runtime.documentsDirectory = base.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtime.documentsDirectory, withIntermediateDirectories: true)
        return (h, runtime)
    }

    private func line(_ message: String, level: String = "info") -> DiagnosticsLogLine {
        DiagnosticsLogLine(date: Date(), level: level, subsystem: "app.nib", category: "tests", message: message)
    }

    private func export(_ h: Harness, _ params: JSONValue = [:]) async throws -> (DiagnosticsExportCommand.Output, [String: String]) {
        let output = try await h.run("diagnostics.export", params).decode(DiagnosticsExportCommand.Output.self)
        let ref = try XCTUnwrap(output.file)
        XCTAssertTrue(ref.hasPrefix("tmp:"))
        let url = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(ref.dropFirst(4)))))
        return (output, try ZipReader(try Data(contentsOf: url)).texts())
    }

    private func file(_ name: String, in files: [String: String]) -> String? {
        files.first { $0.key.hasSuffix("/" + name) }?.value
    }

    private func assertNibError(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                                _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nib-zip-tests-" + UUID().uuidString,
                                                                                isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Registration and conformance

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatDiagnosticsFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersItsCommandsAndTheTroubleshootingPage() {
        let (h, _) = makeHarness()
        let export = h.app.commands.descriptor("diagnostics.export")
        XCTAssertEqual(export?.effect, .read)
        XCTAssertEqual(export?.userPresence, true)
        XCTAssertEqual(export?.owner, FeatDiagnosticsFeature.id)
        let toggle = h.app.commands.descriptor("diagnostics.setFeatureEnabled")
        XCTAssertEqual(toggle?.effect, .session)
        XCTAssertEqual(toggle?.owner, FeatDiagnosticsFeature.id)
        let page = h.app.ui.settingsPages.all.first { $0.id == DiagnosticsIDs.settingsPage }
        XCTAssertEqual(page?.section, .advanced)
        XCTAssertEqual(page?.owner, FeatDiagnosticsFeature.id)
        XCTAssertFalse(page?.keywords.isEmpty ?? true)
    }

    // MARK: diagnostics.export (P-092)

    func testExportZipHoldsNoDocumentContentOrTitles() async throws {
        let (h, runtime) = makeHarness()
        h.app.settings.set(NibSettings.authorName, "Ada Lovelace")
        runtime.logSource = FakeLogSource(entries: [
            line("Opened Fixture Notebook from Fixtures/Fixture Notebook.nibnote"),
            line("Low-level detail", level: "debug"),
        ])
        let (output, files) = try await export(h)
        XCTAssertFalse(output.includesTitles)
        XCTAssertTrue(output.shared)
        XCTAssertEqual((runtime.sharing as? FakeSharing)?.shared.count, 1)
        XCTAssertEqual(output.logLines, 1)
        for name in ["README.txt", "summary.txt", "device.json", "features.json", "plugins.json", "library.json",
                     "settings.json", "logs.txt"] {
            XCTAssertNotNil(file(name, in: files), name)
        }
        let everything = files.values.joined(separator: "\n")
        for text in fixtureContent + fixtureTitles + ["Ada Lovelace"] {
            XCTAssertFalse(everything.contains(text), "the zip contains \(text)")
        }
        let logs = try XCTUnwrap(file("logs.txt", in: files))
        XCTAssertTrue(logs.contains("Opened " + DiagnosticsRedactor.placeholder))
        XCTAssertFalse(logs.contains("Low-level detail"))

        let library = try JSONValue.parse(try XCTUnwrap(file("library.json", in: files)))
        XCTAssertEqual(library["documents"]?["notebook"]?.intValue, 1)
        XCTAssertEqual(library["documents"]?["textDocument"]?.intValue, 1)
        XCTAssertEqual(library["documents"]?["studySet"]?.intValue, 1)
        XCTAssertEqual(library["documents"]?["whiteboard"]?.intValue, 1)
        XCTAssertEqual(library["folders"]?.intValue, 1)
        XCTAssertNil(library["documentList"])
        XCTAssertEqual(output.reportURL?.hasPrefix(IssueReport.repository + "/issues/new?"), true)
        XCTAssertEqual(output.mailURL?.hasPrefix("mailto:?subject="), true)
    }

    func testExportWithTitlesListsTheLibraryAndKeepsTitlesInTheLog() async throws {
        let (h, runtime) = makeHarness()
        runtime.logSource = FakeLogSource(entries: [line("Opened Fixture Notebook")])
        let (output, files) = try await export(h, ["includeTitles": true])
        XCTAssertTrue(output.includesTitles)
        let library = try XCTUnwrap(file("library.json", in: files))
        for title in fixtureTitles { XCTAssertTrue(library.contains(title), title) }
        XCTAssertTrue(try XCTUnwrap(file("logs.txt", in: files)).contains("Opened Fixture Notebook"))
        let everything = files.values.joined(separator: "\n")
        for text in fixtureContent { XCTAssertFalse(everything.contains(text), "the zip contains \(text)") }
    }

    func testExportKeepsSwitchValuesButNeverFreeTextOrSecuritySettings() async throws {
        let (h, _) = makeHarness()
        h.app.settings.set(NibSettings.openAsTabs, false)
        h.app.settings.set(NibSettings.aiConfirmationPolicy, .always)
        h.app.settings.set(NibSettings.authorName, "Ada Lovelace")
        let (_, files) = try await export(h)
        let settings = try JSONValue.parse(try XCTUnwrap(file("settings.json", in: files)))
        let rows = Dictionary(uniqueKeysWithValues: (settings.arrayValue ?? []).compactMap { row in
            row["name"]?.stringValue.map { ($0, row) }
        })
        XCTAssertEqual(rows["editing.openAsTabs"]?["value"], .bool(false))
        XCTAssertEqual(rows["editing.openAsTabs"]?["customised"], .bool(true))
        XCTAssertEqual(rows["appearance.liquid"]?["value"], .string("full"))
        XCTAssertNil(rows["profile.authorName"]?["value"])
        XCTAssertEqual(rows["profile.authorName"]?["customised"], .bool(true))
        XCTAssertNil(rows["security.ai.confirmationPolicy"]?["value"])
        XCTAssertNil(rows["templates.defaultPaper"]?["value"])
        XCTAssertNotNil(rows["writing.dictionary."]?["entries"])
    }

    func testDebugMessagesJoinTheLogOnlyWithTheExperiment() async throws {
        let (h, runtime) = makeHarness()
        runtime.logSource = FakeLogSource(entries: [line("Visible"), line("Debug only", level: "debug")])
        var (_, files) = try await export(h)
        XCTAssertFalse(try XCTUnwrap(file("logs.txt", in: files)).contains("Debug only"))
        try await h.run(CommandIDs.settingsSet, ["name": .string(NibSettings.experimental.name),
                                                 "value": [ExperimentalFlags.detailedLogs: true]])
        (_, files) = try await export(h)
        XCTAssertTrue(try XCTUnwrap(file("logs.txt", in: files)).contains("Debug only"))
    }

    func testExportListsPluginsFromPluginList() async throws {
        let (h, runtime) = makeHarness(safeMode: InMemorySafeModeStore(isActive: true))
        h.app.commands.register(CommandDescriptor(id: "plugin.list", title: "Plugins", summary: "Fake plugin list.",
                                                  examples: [[:]], effect: .read, target: .app,
                                                  owner: "pluginhost")) { _, _ in
            let list: JSONValue = ["plugins": [["id": "dev.nib.cards", "name": "Cards", "version": "1.2.0",
                                                "enabled": true, "needsReview": false, "permissions": ["document:read"],
                                                "sha256": "abc"]]]
            return list
        }
        XCTAssertTrue(runtime.launchedInSafeMode)
        let (_, files) = try await export(h)
        let plugins = try JSONValue.parse(try XCTUnwrap(file("plugins.json", in: files)))
        XCTAssertEqual(plugins["available"], .bool(true))
        XCTAssertEqual(plugins["runningInThisLaunch"], .bool(false))
        XCTAssertEqual(plugins["plugins"]?[0]?["name"], .string("Cards"))
        let summary = try XCTUnwrap(file("summary.txt", in: files))
        XCTAssertTrue(summary.contains("Safe mode: on for this launch"))
        XCTAssertTrue(summary.contains("Plugins: 1 installed, 1 on, none running in safe mode"))
    }

    // MARK: diagnostics.setFeatureEnabled (N-026)

    func testFeatureSwitchesWriteSafeModeChoicesForTheNextLaunch() async throws {
        let store = InMemorySafeModeStore(disabled: ["pen"])
        let (h, _) = makeHarness(features: [FeatDiagnosticsFeature.self, FakeLaserFeature.self], safeMode: store)
        typealias Output = DiagnosticsSetFeatureEnabledCommand.Output

        var out = try await h.run("diagnostics.setFeatureEnabled", ["id": "laser", "enabled": false]).decode(Output.self)
        XCTAssertEqual(store.disabledFeatures, ["pen", "laser"])
        XCTAssertEqual(out.running, true)
        XCTAssertTrue(out.pendingRelaunch)
        XCTAssertEqual(out.disabled, ["laser", "pen"])

        out = try await h.run("diagnostics.setFeatureEnabled", ["id": "laser", "enabled": true]).decode(Output.self)
        XCTAssertFalse(out.pendingRelaunch)
        // Off in this launch, on at the next.
        out = try await h.run("diagnostics.setFeatureEnabled", ["id": "pen", "enabled": true]).decode(Output.self)
        XCTAssertEqual(out.running, false)
        XCTAssertTrue(out.pendingRelaunch)
        XCTAssertEqual(store.disabledFeatures, [])

        // Split features move together.
        out = try await h.run("diagnostics.setFeatureEnabled", ["id": "canvas", "enabled": false]).decode(Output.self)
        XCTAssertEqual(store.disabledFeatures, ["canvas", "canvasinput"])
        XCTAssertEqual(out.alsoChanged, ["canvasinput"])
        out = try await h.run("diagnostics.setFeatureEnabled", ["id": "canvasinput", "enabled": true]).decode(Output.self)
        XCTAssertEqual(store.disabledFeatures, [])
        XCTAssertEqual(out.alsoChanged, ["canvas"])

        // The assistant can do it too (a session command, not security).
        _ = try await h.run("diagnostics.setFeatureEnabled", ["id": "laser", "enabled": false], as: .ai("chat"))
        XCTAssertEqual(store.disabledFeatures, ["laser"])

        await assertNibError(.invalidParams) {
            _ = try await h.run("diagnostics.setFeatureEnabled", ["id": "diagnostics", "enabled": false])
        }
        await assertNibError(.invalidParams) {
            _ = try await h.run("diagnostics.setFeatureEnabled", ["id": "library", "enabled": false])
        }
        await assertNibError(.notFound) {
            _ = try await h.run("diagnostics.setFeatureEnabled", ["id": "nope", "enabled": false])
        }
        await assertNibError(.invalidParams) {
            _ = try await h.run("diagnostics.setFeatureEnabled", ["id": "laser"], as: .ai("chat"))
        }
    }

    func testPluginSwitchesGoThroughPluginEnable() async throws {
        let store = InMemorySafeModeStore()
        let (h, _) = makeHarness(safeMode: store)
        await assertNibError(.unavailable) {
            _ = try await h.run("diagnostics.setFeatureEnabled", ["id": "plugin:dev.nib.cards", "enabled": false])
        }
        var calls: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(
            id: "plugin.enable", title: "Enable Plugin", summary: "Fake plugin switch.",
            params: .obj(["id": .str(), "enabled": .bool()], required: ["id", "enabled"]),
            examples: [["id": "dev.nib.cards", "enabled": true]], effect: .session, target: .app,
            extraScopes: [.pluginsManage], owner: "pluginhost")) { json, _ in
            calls.append(json)
            return ["id": json["id"] ?? .null]
        }
        let out = try await h.run("diagnostics.setFeatureEnabled", ["id": "plugin:dev.nib.cards", "enabled": false])
            .decode(DiagnosticsSetFeatureEnabledCommand.Output.self)
        XCTAssertEqual(calls, [["id": "dev.nib.cards", "enabled": false]])
        XCTAssertFalse(out.pendingRelaunch)
        XCTAssertNil(out.running)
        XCTAssertEqual(store.disabledFeatures, [])
        await assertNibError(.invalidParams) {
            _ = try await h.run("diagnostics.setFeatureEnabled", ["id": "plugin:", "enabled": false])
        }
    }

    func testFeatureRulesAndCatalogue() throws {
        let ids = FeatureCatalog.all.map { $0.id }
        XCTAssertEqual(ids.count, 108)
        XCTAssertEqual(Set(ids).count, ids.count)
        for info in FeatureCatalog.all {
            if let parent = info.parent { XCTAssertTrue(FeatureCatalog.ids.contains(parent), info.id) }
            XCTAssertFalse(info.title.isEmpty)
        }
        XCTAssertTrue(FeatureCatalog.required.isSubset(of: FeatureCatalog.ids))
        XCTAssertEqual(Set(FeatureCatalog.children(of: "teacher")), ["teacherlessons", "teacherinsights"])
        let change = try FeatureToggleRules.apply(id: "mathassist", enabled: false, disabled: ["mathgraph"],
                                                  known: FeatureCatalog.ids)
        XCTAssertEqual(change.disabled, ["mathassist", "mathassistoverlay", "mathgraph"])
        XCTAssertEqual(change.alsoChanged, ["mathassistoverlay"])
        XCTAssertEqual(FeatureCatalog.title("somethingnew"), "somethingnew")
    }

    // MARK: Troubleshooting page model

    func testTroubleshootingModelListsAndSwitchesFeaturesPluginsAndExperiments() async throws {
        let store = InMemorySafeModeStore(isActive: true, disabled: ["pen"])
        let (h, runtime) = makeHarness(features: [FeatDiagnosticsFeature.self, FakeLaserFeature.self], safeMode: store)
        var enabled = ["dev.nib.cards": true]
        h.app.commands.register(CommandDescriptor(id: "plugin.list", title: "Plugins", summary: "Fake plugin list.",
                                                  examples: [[:]], effect: .read, target: .app,
                                                  owner: "pluginhost")) { _, _ in
            let list: JSONValue = [["id": "dev.nib.cards", "name": "Cards", "version": "1.2.0",
                                    "state": .string(enabled["dev.nib.cards"] == true ? "enabled" : "disabled")]]
            return list
        }
        h.app.commands.register(CommandDescriptor(
            id: "plugin.enable", title: "Enable Plugin", summary: "Fake plugin switch.",
            params: .obj(["id": .str(), "enabled": .bool()], required: ["id", "enabled"]),
            examples: [["id": "dev.nib.cards", "enabled": true]], effect: .session, target: .app,
            extraScopes: [.pluginsManage], owner: "pluginhost")) { json, _ in
            if let id = json["id"]?.stringValue { enabled[id] = json["enabled"]?.boolValue ?? true }
            return .null
        }
        let model = TroubleshootingModel(app: h.app, runtime: runtime)
        await model.refresh()
        XCTAssertTrue(model.launchedInSafeMode)
        XCTAssertEqual(Set(model.features.map { $0.id }), ["diagnostics", "laser", "pen"])
        XCTAssertEqual(model.features.first { $0.id == "diagnostics" }?.isRequired, true)
        XCTAssertEqual(model.shownFeatures.map { $0.id }, ["pen"])
        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertTrue(model.pluginsAvailable)
        XCTAssertEqual(model.plugins.map { $0.id }, ["dev.nib.cards"])
        XCTAssertEqual(model.plugins.first?.enabled, true)
        XCTAssertEqual(model.experiments.map { $0.id }, [ExperimentalFlags.detailedLogs])
        XCTAssertNotNil(model.reportURL)
        XCTAssertNotNil(model.mailURL)

        await model.setFeature("laser", enabled: false)
        XCTAssertNil(model.problem)
        XCTAssertEqual(store.disabledFeatures, ["pen", "laser"])
        XCTAssertTrue(model.hasPendingChanges)
        XCTAssertEqual(Set(model.shownFeatures.map { $0.id }), ["laser", "pen"])

        await model.setFeature("diagnostics", enabled: false)
        XCTAssertNotNil(model.problem)
        XCTAssertFalse(store.disabledFeatures.contains("diagnostics"))

        await model.setPlugin("dev.nib.cards", enabled: false)
        XCTAssertNil(model.problem)
        XCTAssertEqual(enabled["dev.nib.cards"], false)
        XCTAssertEqual(model.plugins.first?.enabled, false)

        let flag = try XCTUnwrap(model.experiments.first)
        await model.setExperiment(flag.id, on: true)
        XCTAssertEqual(h.app.settings.get(NibSettings.experimental)[flag.id], true)
        XCTAssertTrue(model.isOn(flag))

        // A switch tap shows its new state at once; the command settles it.
        model.requestExperiment(flag.id, on: false)
        XCTAssertFalse(model.isOn(flag))
        model.requestFeature("laser", enabled: true)
        XCTAssertEqual(model.features.first { $0.id == "laser" }?.isOn, true)
        let settled = await eventually {
            h.app.settings.get(NibSettings.experimental)[flag.id] == false && !store.disabledFeatures.contains("laser")
        }
        XCTAssertTrue(settled)

        model.showsAllFeatures = true
        model.filter = "las"
        XCTAssertEqual(model.shownFeatures.map { $0.id }, ["laser"])

        await model.export()
        guard case .done(let bytes, let shared) = model.exportPhase else {
            return XCTFail("export ended in \(model.exportPhase)")
        }
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertTrue(shared)
    }

    func testExperimentListShowsOnlyFlagsSomethingReads() {
        let running: Set<String> = [FeatDiagnosticsFeature.id]
        XCTAssertEqual(ExperimentalFlags.visible(values: [:], running: running).map { $0.id }, [ExperimentalFlags.detailedLogs])
        XCTAssertEqual(ExperimentalFlags.visible(values: [:], running: []).map { $0.id }, [])
        let withUnknown = ExperimentalFlags.visible(values: ["plugin.fancy": true], running: running)
        XCTAssertEqual(withUnknown.map { $0.id }, [ExperimentalFlags.detailedLogs, "plugin.fancy"])
        XCTAssertNil(withUnknown.last?.owner)
    }

    func testTroubleshootingPageRendersInEveryVariant() {
        let (h, runtime) = makeHarness(safeMode: InMemorySafeModeStore(isActive: true, disabled: ["laser"]))
        let images = NibSnapshot.images(NavigationStack { TroubleshootingPage(app: h.app, runtime: runtime) },
                                        size: CGSize(width: 390, height: 844))
        XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases))
        let wide = NibSnapshot.image(TroubleshootingPage(app: h.app, runtime: runtime), size: CGSize(width: 760, height: 706))
        XCTAssertNotNil(wide)
    }

    // MARK: Temporary Diagnostic Mode (P-093)

    func testTemporaryDiagnosticModeCopiesTheLibraryOnceAndTurnsItselfOff() async throws {
        let (_, runtime) = makeHarness()
        let root = runtime.documentsDirectory
        let fm = FileManager.default
        let package = root.appendingPathComponent("Physics/Waves.nibnote", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{\"pages\":[]}".utf8).write(to: package.appendingPathComponent("doc.0000abcd.json"))
        let meta = root.appendingPathComponent(".nib-library", isDirectory: true)
        try fm.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: meta.appendingPathComponent("prefs.0000abcd.json"))
        try fm.createDirectory(at: root.appendingPathComponent("Empty Folder", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: runtime.libraryCopyFolder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: runtime.libraryCopyFolder.appendingPathComponent("earlier.zip"))

        runtime.diagnosticSwitch = FakeSwitch(false)
        XCTAssertNil(runtime.startTemporaryDiagnosticModeIfRequested(libraryRoot: root))

        let toggle = FakeSwitch(true)
        runtime.diagnosticSwitch = toggle
        let task = try XCTUnwrap(runtime.startTemporaryDiagnosticModeIfRequested(libraryRoot: root))
        XCTAssertFalse(toggle.isOn)
        XCTAssertEqual(toggle.turnedOff, 1)
        let state = await task.value
        guard case .done(let name, let bytes) = state else { return XCTFail("library copy ended in \(state)") }
        XCTAssertEqual(runtime.libraryCopy, state)
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertEqual(LibraryArchiver.latestCopy(in: runtime.libraryCopyFolder)?.name, name)

        let zip = try ZipReader(try Data(contentsOf: runtime.libraryCopyFolder.appendingPathComponent(name)))
        let names = Set(zip.entries.map { $0.name })
        XCTAssertTrue(names.contains("Nib Library/Physics/Waves.nibnote/doc.0000abcd.json"))
        XCTAssertTrue(names.contains("Nib Library/.nib-library/prefs.0000abcd.json"))
        XCTAssertTrue(names.contains("Nib Library/Empty Folder/"))
        XCTAssertFalse(names.contains { $0.contains("diagnostics") }, "the copy must not contain itself")
        let texts = try zip.texts()
        XCTAssertEqual(texts["Nib Library/Physics/Waves.nibnote/doc.0000abcd.json"], "{\"pages\":[]}")
        XCTAssertFalse(fm.fileExists(atPath: runtime.libraryCopyFolder.appendingPathComponent("." + name + ".partial").path))
    }

    func testLibraryCopyRefusesWhenTheDiskIsFull() throws {
        let root = tempFolder()
        try Data(count: 4096).write(to: root.appendingPathComponent("big.bin"))
        let folder = root.appendingPathComponent("diagnostics", isDirectory: true)
        XCTAssertThrowsError(try LibraryArchiver.archive(root: root, into: folder, stamp: Date(),
                                                         availableCapacity: { _ in 1024 })) { error in
            guard case LibraryArchiver.Failure.notEnoughSpace(let needed, let available)? = error as? LibraryArchiver.Failure else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertGreaterThanOrEqual(needed, 4096)
            XCTAssertEqual(available, 1024)
        }
        XCTAssertFalse(DiagnosticsRuntime.message(for: LibraryArchiver.Failure.notEnoughSpace(needed: 4096, available: 1)).isEmpty)
        XCTAssertThrowsError(try LibraryArchiver.archive(root: root.appendingPathComponent("missing"), into: folder,
                                                         stamp: Date()))
    }

    // MARK: Zip, redaction, report links

    func testZipWriterRoundTripsStoredDeflatedAndZip64Entries() throws {
        let folder = tempFolder()
        let source = folder.appendingPathComponent("source.bin")
        var big = Data()
        for i in 0..<300_000 { big.append(UInt8(truncatingIfNeeded: i &* 31)) }
        try big.write(to: source)
        let text = Data(String(repeating: "diagnostics ", count: 400).utf8)
        for forced in [false, true] {
            let url = folder.appendingPathComponent(forced ? "zip64.zip" : "plain.zip")
            let writer = try ZipArchiveWriter(url: url)
            writer.forcesZip64 = forced
            try writer.addDirectory("Top")
            try writer.addData(text, path: "Top/logs.txt")
            try writer.addData(Data("tiny".utf8), path: "Top/tiny.txt")
            try writer.addData(Data("Gr\u{00F6}\u{00DF}e".utf8), path: "Top/Gr\u{00F6}\u{00DF}e.txt")
            try writer.addFile(at: source, path: "Top/data/source.bin")
            try writer.finish()
            XCTAssertThrowsError(try writer.finish())

            let reader = try ZipReader(try Data(contentsOf: url))
            XCTAssertEqual(reader.usedZip64, forced)
            XCTAssertEqual(reader.entries.map { $0.name },
                           ["Top/", "Top/logs.txt", "Top/tiny.txt", "Top/Gr\u{00F6}\u{00DF}e.txt", "Top/data/source.bin"])
            XCTAssertEqual(reader.entries[1].method, 8, "text is deflated")
            XCTAssertEqual(reader.entries[2].method, 0, "tiny files are stored")
            let texts = try reader.texts()
            XCTAssertEqual(texts["Top/logs.txt"], String(decoding: text, as: UTF8.self))
            XCTAssertEqual(texts["Top/Gr\u{00F6}\u{00DF}e.txt"], "Gr\u{00F6}\u{00DF}e")
            XCTAssertEqual(try reader.contents(reader.entries[4]), big)
        }
        XCTAssertThrowsError(try ZipArchiveWriter(url: folder.appendingPathComponent("x.zip"))
            .addFile(at: folder.appendingPathComponent("missing.bin"), path: "missing.bin")) { error in
            XCTAssertEqual(error as? ZipArchiveError, .unreadable("missing.bin"))
        }
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testRedactorMasksLongestTitlesFirstAndLeavesShortOnes() {
        let redactor = DiagnosticsRedactor(titles: ["Physics", "Physics 9702", "ab", " Physics "])
        XCTAssertEqual(redactor.titles, ["Physics 9702", "Physics"])
        let p = DiagnosticsRedactor.placeholder
        XCTAssertEqual(redactor.redact("Opened Physics 9702 then Physics; ab stays"), "Opened \(p) then \(p); ab stays")
        XCTAssertEqual(DiagnosticsRedactor(titles: []).redact("Physics"), "Physics")
    }

    func testReportLinksCarryTheSummaryIntact() throws {
        let summary = "Nib 1.0 (7)\nFeatures turned off: laser & pen + more #1 = yes"
        let github = try XCTUnwrap(IssueReport.githubURL(summary: summary))
        let items = try XCTUnwrap(URLComponents(url: github, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(github.host, "github.com")
        XCTAssertEqual(github.path, "/GOODMAN-PRO/nib/issues/new")
        XCTAssertEqual(items.first { $0.name == "title" }?.value, IssueReport.title)
        XCTAssertTrue(items.first { $0.name == "body" }?.value?.contains(summary) ?? false)

        let mail = try XCTUnwrap(IssueReport.mailURL(summary: summary))
        XCTAssertEqual(mail.scheme, "mailto")
        let mailItems = try XCTUnwrap(URLComponents(url: mail, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(mailItems.first { $0.name == "subject" }?.value, "Nib: " + IssueReport.title)
        let body = try XCTUnwrap(mailItems.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("laser & pen + more #1 = yes"))
        XCTAssertTrue(body.contains("\r\n"))

        let long = String(repeating: "x", count: 20_000)
        XCTAssertLessThanOrEqual(IssueReport.body(summary: long).count, IssueReport.maxBodyLength)
    }

    func testPluginListIsReadLeniently() {
        let bare: JSONValue = [["id": "b.plugin", "name": "Beta", "state": "needsReview"], ["id": "a.plugin"]]
        let plugins = DiagnosticsPlugin.list(from: bare)
        XCTAssertEqual(plugins.map { $0.id }, ["a.plugin", "b.plugin"])
        XCTAssertEqual(plugins.last?.needsReview, true)
        XCTAssertEqual(plugins.last?.enabled, false)
        XCTAssertEqual(plugins.first?.name, "a.plugin")
        let wrapped: JSONValue = ["installed": [["id": "c", "enabled": false]]]
        XCTAssertEqual(DiagnosticsPlugin.list(from: wrapped).first?.enabled, false)
        XCTAssertEqual(DiagnosticsPlugin.list(from: nil), [])
    }

    func testProcessLogSourceKeepsNibMessagesAndErrorsWithinItsLimit() {
        let lines = (try? ProcessLogSource().lines(detailed: false, limit: 25)) ?? []
        XCTAssertLessThanOrEqual(lines.count, 25)
        for line in lines {
            XCTAssertTrue(line.subsystem.hasPrefix(ProcessLogSource.subsystem) || line.level == "error" || line.level == "fault",
                          "\(line.subsystem) \(line.level)")
        }
    }
}
