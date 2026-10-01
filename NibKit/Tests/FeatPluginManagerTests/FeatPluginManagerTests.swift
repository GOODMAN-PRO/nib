import XCTest
import Foundation
import SwiftUI
import UIKit
import NibDesign
import NibContracts
import NibTesting
@testable import FeatPluginManager

@MainActor
final class FeatPluginManagerTests: XCTestCase {
    func testRegistrationAndConformance() async {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        XCTAssertEqual(h.app.ui.panels.get(PanelIDs.gallery)?.placement, .libraryTab)
        XCTAssertNotNil(h.app.ui.settingsPages.get("pluginmanager.plugins"))
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.galleryList)?.effect, .read)
        let problems = await CommandConformance.check(features: [FeatPluginManagerFeature.self])
        XCTAssertEqual(problems, [])
    }
    func gallery(_ id: String, author: String, category: String) -> JSONValue {
        ["id": .string(id), "name": .string(id), "version": "1.0.0", "author": .string(author), "category": .string(category),
         "description": "Templates for weekly planning", "url": "pack.nibplugin", "kind": "content"]
    }
    func testGalleryIndexesPartialFailureFilteringPaginationAndSavedItems() async throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        let custom = "https://example.com/index.json"
        let missing = "https://missing.example/index.json"
        let payload: JSONValue = ["version": 1, "name": "Community", "plugins": .array([
            gallery("dev.test.one", author: "Ada", category: "Planners"), gallery("dev.test.two", author: "Ada", category: "Study")])]
        let data = try JSONEncoder().encode(payload)
        h.app.services.set(GalleryClient(fetcher: GalleryFixtureFetcher(documents: [GalleryClient.defaultIndex: data, custom: data])), for: GalleryClient.serviceKey)
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": .string(NibSettings.pluginGalleries.name), "value": .array([.string(custom), .string(missing)])])
        let result = try await h.app.bus.execute(CommandIDs.galleryList, ["limit": 1])
        XCTAssertEqual(result["total"]?.intValue, 4)
        XCTAssertEqual(result["cursor"]?.intValue, 1)
        let indexes = try XCTUnwrap(result["indexes"]).decode([GalleryIndex].self)
        XCTAssertEqual(indexes.count, 3)
        XCTAssertNotNil(indexes[2].error)
        let entry = try XCTUnwrap(indexes[0].plugins.first)
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": .string(ManagerSettings.savedKey(entry)), "value": true])
        let saved = try await h.app.bus.execute(CommandIDs.galleryList, ["saved": true])
        XCTAssertEqual(saved["total"]?.intValue, 1)
        let filtered = try await h.app.bus.execute(CommandIDs.galleryList, ["index": .string(custom), "author": "Ada", "category": "Planners", "query": "weekly"])
        XCTAssertEqual(filtered["total"]?.intValue, 1)
        XCTAssertTrue(h.app.settings.undeclaredNames.isEmpty)
    }
    func testNewPluginForwardsEscapedSkeletonThroughInstaller() async throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        let host = ManagerHostFake(manifest: try PluginManifest.fixture())
        h.app.services.set(host, for: ServiceKeys.pluginHost)
        var captured: JSONValue = [:]
        h.app.commands.register(CommandDescriptor(id: CommandIDs.pluginInstall, title: "Install", summary: "Test installation.",
            effect: .library, target: .library)) { p, _ in captured = p; return ["installed": true] }
        let name = "Hello \"World\"\nWelcome"
        _ = try await h.app.bus.execute(ManagerCommands.create, ["id": "dev.test.hello", "name": .string(name)])
        let manifest = try JSONValue.parse(try XCTUnwrap(captured["files"]?["manifest.json"]?.stringValue))
        XCTAssertEqual(manifest["name"]?.stringValue, name)
        XCTAssertEqual(manifest["id"]?.stringValue, "dev.test.hello")
        XCTAssertTrue(try XCTUnwrap(captured["files"]?["main.js"]?.stringValue).contains("dev.test.hello.hello"))
        XCTAssertThrowsError(try PluginSkeleton.files(id: "../escape", name: "Bad"))
    }
    func testConsoleUsesRuntimeHandleAndRejectsNonUserAndDryRun() async throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        let host = ManagerHostFake(manifest: try PluginManifest.fixture())
        h.app.services.set(host, for: ServiceKeys.pluginHost)
        let p: JSONValue = ["id": .string(host.runtime.manifest.id), "javascript": "1 + 1"]
        let result = try await h.app.bus.execute(ManagerCommands.evaluate, p)
        XCTAssertEqual(result["text"]?.stringValue, "2")
        XCTAssertEqual(host.runtime.evaluations, ["1 + 1"])
        do { _ = try await h.app.bus.execute(ManagerCommands.evaluate, p, principal: .ai("test")); XCTFail("AI must not evaluate without an inherited context") }
        catch { XCTAssertEqual((error as? NibError)?.code, .permissionDenied) }
        do { _ = try await h.app.bus.execute(Invocation(command: ManagerCommands.evaluate, params: p, dryRun: true)); XCTFail("dry run must have no evaluation") }
        catch { XCTAssertEqual((error as? NibError)?.code, .unsupported) }
        XCTAssertEqual(host.runtime.evaluations.count, 1)
    }
    func testPermissionRevocationPreservesOtherGrantsAndHashBinding() async throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        let host = ManagerHostFake(manifest: try PluginManifest.fixture(permissions: ["app", "network"]))
        h.app.services.set(host, for: ServiceKeys.pluginHost)
        let url = h.library.metadataURL.appendingPathComponent("test-grants.json")
        let store = ManagerGrants(url: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let grants: JSONValue = [.init(host.runtime.manifest.id): ["sha256": "hash", "scopes": ["app", "network"], "source": "fixture"]]
        try JSONEncoder().encode(grants).write(to: url)
        h.app.services.set(store, for: ManagerGrants.serviceKey)
        let p: JSONValue = ["id": .string(host.runtime.manifest.id), "scope": "network", "enabled": false]
        _ = try await h.app.bus.execute(ManagerCommands.permission, p)
        XCTAssertEqual(try store.read()[host.runtime.manifest.id]?["scopes"], ["app"])
        XCTAssertEqual(try store.read()[host.runtime.manifest.id]?["source"], "fixture")
        XCTAssertEqual(host.loads, [host.runtime.manifest.id])
        XCTAssertThrowsError(try store.set(host.runtime.manifest.id, hash: "changed", scopes: ["app", "network"]))
        do { _ = try await h.app.bus.execute(ManagerCommands.permission, p.merging(["scope": "security"])); XCTFail("cannot grant security") }
        catch { XCTAssertEqual((error as? NibError)?.code, .invalidParams) }
    }
    func testSDKExportCollectsAllPagesWithoutTruncating() async throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.pluginSdkTypes, title: "SDK", summary: "Test SDK pages.", effect: .read, target: .app)) { p, _ in
            p["cursor"] == nil ? ["text": "first\n", "truncated": true, "cursor": "second"] : ["text": "last\n", "truncated": false]
        }
        let output = try await h.app.bus.execute(ManagerCommands.sdkExport)
        let ref = AssetRef(String(try XCTUnwrap(output["asset"]?.stringValue).dropFirst(4)))
        let url = try XCTUnwrap(h.assets.temporaryURL(ref))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first\nlast\n")
    }
    func testManifestPagingPreservesUTF8AndRejectsMidCharacterCursor() throws {
        let text = String(repeating: "日🖊e\u{301}", count: 1_000)
        let data = Data(text.utf8)
        var cursor = 0
        var reconstructed = ""
        repeat {
            let page = try ManagerTextPage.page(data, offset: cursor)
            reconstructed += try XCTUnwrap(page["text"]?.stringValue)
            XCTAssertLessThan(try JSONEncoder().encode(page).count, 20_000)
            guard let next = page["cursor"]?.intValue else { break }
            XCTAssertGreaterThan(next, cursor)
            cursor = next
        } while true
        XCTAssertEqual(reconstructed, text)
        XCTAssertThrowsError(try ManagerTextPage.page(data, offset: 1))
    }
    func testPermissionEnablingRequiresConsentAndDoesNotRestoreOtherRevokedScopes() async throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        let host = ManagerHostFake(manifest: try PluginManifest.fixture(permissions: ["app", "network", "ai"]))
        h.app.services.set(host, for: ServiceKeys.pluginHost)
        let url = h.library.metadataURL.appendingPathComponent("test-grants.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let grants: JSONValue = [.init(host.runtime.manifest.id): ["sha256": "hash", "scopes": ["app"]]]
        try JSONEncoder().encode(grants).write(to: url)
        let store = ManagerGrants(url: url)
        h.app.services.set(store, for: ManagerGrants.serviceKey)
        let params: JSONValue = ["id": .string(host.runtime.manifest.id), "scope": "network", "enabled": true]
        h.confirmer.decision = .deny
        do { _ = try await h.app.bus.execute(ManagerCommands.permission, params); XCTFail("deny must leave the grant unchanged") }
        catch { XCTAssertEqual((error as? NibError)?.code, .userDenied) }
        XCTAssertEqual(try store.read()[host.runtime.manifest.id]?["scopes"], ["app"])
        XCTAssertTrue(host.loads.isEmpty)
        h.confirmer.decision = .allow
        _ = try await h.app.bus.execute(ManagerCommands.permission, params)
        XCTAssertEqual(try store.read()[host.runtime.manifest.id]?["scopes"], ["app", "network"])
        XCTAssertEqual(h.confirmer.requests.count, 2)
    }
    func testGalleryPageBudgetDoesNotSkipLargeRows() async throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        let entries = (0..<5).map { index -> JSONValue in
            gallery("dev.test.pack" + String(index), author: "Ada", category: "Planners")
                .merging(["description": .string(String(repeating: "x", count: [1, 3].contains(index) ? 9_000 : 1_000))])
        }
        let payload: JSONValue = ["version": 1, "name": "Packs", "plugins": .array(entries)]
        let index = "https://example.com/index.json"
        h.app.services.set(GalleryClient(fetcher: GalleryFixtureFetcher(documents: [index: try JSONEncoder().encode(payload)])), for: GalleryClient.serviceKey)
        var params: JSONValue = ["index": .string(index)]
        var ids: [String] = []
        repeat {
            let result = try await h.app.bus.execute(CommandIDs.galleryList, params)
            XCTAssertLessThan(try JSONEncoder().encode(result).count, 20_000)
            let sections = try XCTUnwrap(result["indexes"]).decode([GalleryIndex].self)
            ids += sections.flatMap(\.plugins).map(\.id)
            guard let cursor = result["cursor"] else { XCTFail("missing cursor"); break }
            if cursor == .null { break }
            params = params.merging(["cursor": cursor])
        } while true
        XCTAssertEqual(ids, entries.compactMap { $0["id"]?.stringValue })
    }
    func testNativeGalleryRowSnapshotsAndDynamicTypeLayout() throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        let model = PluginManagerModel(app: h.app)
        let payload: JSONValue = ["version": 1, "name": "Packs", "plugins": .array([gallery("dev.test.planner", author: "Ada", category: "Planners")])]
        let index = try GalleryClient.parse(JSONEncoder().encode(payload), index: URL(string: "https://example.com/index.json")!)
        let entry = try XCTUnwrap(index.plugins.first)
        let row = GalleryEntryRow(entry: entry, model: model, showAuthor: {})
            .padding(NibSpacing.l).background(NibColor.backgroundSecondary)
        for variant in NibSnapshot.Variant.allCases {
            let size = NibSnapshot.fittingSize(row, width: NibMetrics.sidebarWidth, variant: variant)
            XCTAssertTrue(size.height.isFinite)
            XCTAssertGreaterThan(size.height, NibMetrics.hitTarget)
            XCTAssertLessThanOrEqual(size.width, NibMetrics.sidebarWidth + 1)
            let image = try XCTUnwrap(NibSnapshot.image(row, size: CGSize(width: NibMetrics.sidebarWidth, height: size.height), variant: variant))
            let attachment = XCTAttachment(image: image)
            attachment.name = "Gallery row " + variant.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let normal = NibSnapshot.fittingSize(row, width: NibMetrics.sidebarWidth, variant: .light)
        let large = NibSnapshot.fittingSize(row, width: NibMetrics.sidebarWidth, variant: .largeText)
        XCTAssertGreaterThan(large.height, normal.height)
        let fallback = try XCTUnwrap(NibSnapshot.image(row.nibLiquidMode(.off), size: CGSize(width: NibMetrics.sidebarWidth, height: normal.height)))
        var contrastImage: UIImage?
        UITraitCollection(accessibilityContrast: .high).performAsCurrent {
            contrastImage = NibSnapshot.image(row, size: CGSize(width: NibMetrics.sidebarWidth, height: normal.height))
        }
        let contrast = try XCTUnwrap(contrastImage)
        for (name, image) in [("Gallery row opaque fallback", fallback), ("Gallery row increased contrast", contrast)] {
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func testPluginExportAndManifestQueryUseRealPackageFiles() async throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        let manifest = try PluginManifest.fixture()
        let host = ManagerHostFake(manifest: manifest)
        let folder = h.library.metadataURL.appendingPathComponent("plugins/" + manifest.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host.folderURL = folder
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: folder.appendingPathComponent("manifest.json"))
        try Data("console.log('hello');".utf8).write(to: folder.appendingPathComponent("main.js"))
        h.app.services.set(host, for: ServiceKeys.pluginHost)
        let params: JSONValue = ["id": .string(manifest.id)]
        let page = try await h.app.bus.execute(ManagerCommands.inspect, params)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(try XCTUnwrap(page["text"]?.stringValue).utf8))
        XCTAssertEqual(decoded, manifest)
        let exported = try await h.app.bus.execute(ManagerCommands.export, params)
        let ref = try XCTUnwrap(exported["asset"]?.stringValue)
        XCTAssertTrue(ref.hasPrefix("tmp:"))
        let asset = AssetRef(String(ref.dropFirst(4)))
        let archiveURL = try XCTUnwrap(h.assets.temporaryURL(asset))
        let data = try Data(contentsOf: archiveURL)
        XCTAssertEqual(data, try PluginArchive.make(folder: folder))
        XCTAssertEqual(exported["filename"]?.stringValue, manifest.id + ".nibplugin")
    }
    func testScreenShellSnapshots() throws {
        let h = Harness(features: [FeatPluginManagerFeature.self])
        let screens: [(String, AnyView, CGSize)] = [
            ("Plugins", AnyView(PluginListView(app: h.app)), NibMetrics.pluginManagerSheetSize),
            ("Gallery", AnyView(GalleryView(app: h.app)), NibMetrics.pluginManagerSheetSize),
            ("Console", AnyView(DevConsoleView(app: h.app, close: {})), NibMetrics.developerConsoleSize)
        ]
        // ImageRenderer captures native SwiftUI chrome; UIKit lists/editors are placeholders in hostless snapshots.
        for (name, screen, size) in screens {
            for variant in NibSnapshot.Variant.allCases {
                let image = try XCTUnwrap(NibSnapshot.image(screen, size: size, variant: variant, scale: 1))
                XCTAssertEqual(image.size.width, size.width)
                XCTAssertEqual(image.size.height, size.height)
                let attachment = XCTAttachment(image: image)
                attachment.name = name + " " + variant.rawValue
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
    func testZIPRecordsUseCRCAndCentralDirectoryAndRejectSymlinks() throws {
        let data = Data("123456789".utf8)
        XCTAssertEqual(PluginArchive.crc32(data), 0xcbf43926)
        let archive = try PluginArchive.zip(files: [("manifest.json", data)])
        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(Array(archive.suffix(22).prefix(4)), [0x50, 0x4b, 0x05, 0x06])
        XCTAssertEqual(archive[14..<18], Data([0x26, 0x39, 0xf4, 0xcb]))
        XCTAssertEqual(archive[30..<43], Data("manifest.json".utf8))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("secret"), withDestinationURL: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try PluginArchive.make(folder: root))
    }
}

@MainActor
final class ManagerRuntimeFake: PluginRuntimeHandle {
    let manifest: PluginManifest
    var logs: [String] = []
    var evaluations: [String] = []
    init(manifest: PluginManifest) { self.manifest = manifest }
    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue { [:] }
    func deliver(_ event: NibEvent) {}
    func postMessage(from panel: String, message: JSONValue) {}
    func evaluate(_ javascript: String) async -> String { evaluations.append(javascript); return "2" }
    func stop() {}
}
@MainActor
final class ManagerHostFake: PluginHosting {
    let runtime: ManagerRuntimeFake
    var loads: [String] = []
    var folderURL: URL?
    init(manifest: PluginManifest) { runtime = ManagerRuntimeFake(manifest: manifest) }
    var installed: [PluginInfo] { [PluginInfo(id: runtime.manifest.id, name: "Fixture", version: "1.0.0", enabled: true,
        needsReview: false, permissions: runtime.manifest.permissions, sha256: "hash")] }
    func handle(_ id: String) -> PluginRuntimeHandle? { id == runtime.manifest.id ? runtime : nil }
    func folder(_ id: String) -> URL? { id == runtime.manifest.id ? folderURL : nil }
    func load(_ id: String) async throws { loads.append(id) }
    func unload(_ id: String) {}
    func setEnabled(_ id: String, _ enabled: Bool) async throws {}
    var aiInstructions: [String] { [] }
}
