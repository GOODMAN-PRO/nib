import XCTest
import CryptoKit
import NibContracts
import NibTesting
@testable import FeatPluginInstall

// MARK: - Test kit (shared with FeatPluginInstallTests)

/// A tiny ZIP writer (stored entries, UNIX attributes) so tests can build exactly the archives they need, hostile ones
/// included: `../` paths, absolute paths, symbolic links.
enum TestZip {
    struct Entry {
        var path: String
        var data: Data
        /// st_mode: 0o100644 file, 0o120777 symbolic link, 0o040755 folder.
        var mode: UInt32 = 0o100644
        var declaredSize: UInt32? = nil
        var deflated = false

        static func file(_ path: String, _ text: String) -> Entry { Entry(path: path, data: Data(text.utf8)) }
        static func link(_ path: String, to target: String) -> Entry { Entry(path: path, data: Data(target.utf8), mode: 0o120777) }
        static func folder(_ path: String) -> Entry { Entry(path: path.hasSuffix("/") ? path : path + "/", data: Data(), mode: 0o040755) }
    }

    static func make(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let payload = entry.deflated ? deflateStoredBlocks(entry.data) : entry.data
            let method: UInt16 = entry.deflated ? 8 : 0
            let crc = crc32(entry.data)
            let offset = UInt32(out.count)
            out.append(le32(0x0403_4b50))
            out.append(le16(20)); out.append(le16(0x0800)); out.append(le16(method))
            out.append(le16(0)); out.append(le16(20_513))
            out.append(le32(crc)); out.append(le32(UInt32(payload.count))); out.append(le32(entry.declaredSize ?? UInt32(entry.data.count)))
            out.append(le16(UInt16(name.count))); out.append(le16(0))
            out.append(name)
            out.append(payload)

            central.append(le32(0x0201_4b50))
            central.append(le16(0x0314)); central.append(le16(20)); central.append(le16(0x0800)); central.append(le16(method))
            central.append(le16(0)); central.append(le16(20_513))
            central.append(le32(crc)); central.append(le32(UInt32(payload.count))); central.append(le32(entry.declaredSize ?? UInt32(entry.data.count)))
            central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0))
            central.append(le32(entry.mode << 16))
            central.append(le32(offset))
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x0605_4b50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(centralOffset))
        out.append(le16(0))
        return out
    }

    /// Raw DEFLATE with uncompressed blocks (RFC 1951), to exercise a false uncompressed size in the inflater.
    static func deflateStoredBlocks(_ data: Data) -> Data {
        var out = Data()
        var offset = 0
        repeat {
            let count = min(65_535, data.count - offset)
            out.append(offset + count == data.count ? 1 : 0)
            out.append(le16(UInt16(count)))
            out.append(le16(~UInt16(count)))
            out.append(data[offset..<(offset + count)])
            offset += count
        } while offset < data.count
        return out
    }

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

enum TestFiles {
    static func tempDir(_ label: String = "nib-install-tests") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(label + "-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ files: [(String, String)], into folder: URL) throws {
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    /// manifest.json text for a plugin.
    static func manifest(id: String = "dev.nib.cards", name: String = "Cards", version: String = "1.0.0",
                         permissions: [String] = ["document:read"], hosts: [String]? = nil,
                         commands: [String] = [], extra: [String: JSONValue] = [:]) -> String {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name), "version": .string(version), "api": 1,
                                      "entry": "main.js", "author": "Ada", "permissions": .array(permissions.map { .string($0) })]
        if let hosts = hosts { o["network"] = ["hosts": .array(hosts.map { .string($0) })] }
        if !commands.isEmpty {
            o["contributes"] = ["commands": .array(commands.map { c -> JSONValue in
                ["id": .string(id + "." + c), "title": .string(c.capitalized), "summary": .string("Does \(c)."), "examples": [[:]]]
            })]
        }
        for (k, v) in extra { o[k] = v }
        return JSONValue.object(o).jsonString(pretty: true)
    }

    static func decodeManifest(_ text: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(text.utf8))
    }
}

// MARK: - Pure installer logic

@MainActor
final class PluginInstallerTests: XCTestCase {
    private let files: [(String, String)] = [("manifest.json", TestFiles.manifest()),
                                             ("main.js", "nib.commands.register('dev.nib.cards.go', () => 1);"),
                                             ("panels/stats.html", "<p>stats</p>"),
                                             ("assets/é.txt", "accents in names")]

    // Acceptance: hash stable across file order.
    func testHashIsStableAcrossFileOrderDatesAndPackaging() throws {
        let a = TestFiles.tempDir()
        let b = TestFiles.tempDir()
        try TestFiles.write(files, into: a)
        try TestFiles.write(files.reversed(), into: b)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: b.appendingPathComponent("main.js").path)
        let hashA = try PluginPackageHash.compute(a)
        XCTAssertEqual(hashA, try PluginPackageHash.compute(b), "write order and dates never change the hash")

        // The same files through a zip (in either entry order), inline files and a folder copy hash the same.
        let zipForward = TestFiles.tempDir().appendingPathComponent("p.nibplugin")
        let zipBackward = TestFiles.tempDir().appendingPathComponent("p.nibplugin")
        try TestZip.make(files.map { TestZip.Entry.file($0.0, $0.1) }).write(to: zipForward)
        try TestZip.make(files.reversed().map { TestZip.Entry.file($0.0, $0.1) }).write(to: zipBackward)
        for zip in [zipForward, zipBackward] {
            let out = TestFiles.tempDir()
            try PackageStager.unzip(zip, into: out)
            XCTAssertEqual(try PluginPackageHash.compute(out), hashA)
        }
        let inline = TestFiles.tempDir()
        try PackageStager.writeInline(Dictionary(uniqueKeysWithValues: files.map { ($0.0, JSONValue.string($0.1)) }), into: inline)
        XCTAssertEqual(try PluginPackageHash.compute(inline), hashA)
        let copied = TestFiles.tempDir()
        try PackageStager.copyFolder(a, into: copied)
        XCTAssertEqual(try PluginPackageHash.compute(copied), hashA)

        // Content changes do change it.
        try Data("changed".utf8).write(to: b.appendingPathComponent("main.js"))
        XCTAssertNotEqual(try PluginPackageHash.compute(b), hashA)
    }

    /// The installer's hash must equal the plugin host's (F078) and the gallery index's (F082): sorted UTF-8 paths,
    /// each as path 0x00 byte-count 0x00 contents; hidden files ignored.
    /// (ASCII names: the file system reports names in its own Unicode normalisation, which both sides read the same way.)
    func testHashMatchesThePluginHostAlgorithm() throws {
        let folder = TestFiles.tempDir()
        let ascii = files.filter { $0.0.allSatisfy { $0.isASCII } } + [("Z.txt", "capitals sort before lower case")]
        try TestFiles.write(ascii + [(".DS_Store", "finder"), (".git/config", "hidden")], into: folder)
        var hasher = SHA256()
        for (path, text) in ascii.sorted(by: { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }) {
            let data = Data(text.utf8)
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(data.count).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
        }
        let expected = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try PluginPackageHash.compute(folder), expected)
    }

    // Acceptance: zip-slip rejected.
    func testZipSlipPathsAreRejected() throws {
        for hostile in ["../evil.js", "a/../../evil.js", "/etc/evil.js", "C:/evil.js", "a\\..\\evil.js", "~/evil.js"] {
            let zip = TestFiles.tempDir().appendingPathComponent("bad.nibplugin")
            try TestZip.make([.file("manifest.json", TestFiles.manifest()), .file("main.js", "1"), .file(hostile, "x")]).write(to: zip)
            let out = TestFiles.tempDir()
            XCTAssertThrowsError(try PackageStager.unzip(zip, into: out), hostile) { error in
                XCTAssertEqual((error as? NibError)?.code, .invalidParams, hostile)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.deletingLastPathComponent().appendingPathComponent("evil.js").path))
        }
        XCTAssertThrowsError(try PackageStager.writeInline(["../main.js": "x"], into: TestFiles.tempDir()))
    }

    func testSanitizeKeepsPlainPathsAndSkipsHiddenOnes() throws {
        XCTAssertEqual(try StagingPath.sanitize("panels/stats.html"), "panels/stats.html")
        XCTAssertEqual(try StagingPath.sanitize("./a//b.js"), "a/b.js")
        XCTAssertEqual(try StagingPath.sanitize("a..b/c.js"), "a..b/c.js")
        XCTAssertNil(try StagingPath.sanitize(".DS_Store"))
        XCTAssertNil(try StagingPath.sanitize("__MACOSX/._main.js"))
        XCTAssertNil(try StagingPath.sanitize("assets/.hidden/x.png"))
        XCTAssertNil(try StagingPath.sanitize(""))
        XCTAssertThrowsError(try StagingPath.sanitize(".."))
        XCTAssertThrowsError(try StagingPath.sanitize("a/\0b"))
    }

    func testSymbolicLinksAreRejected() throws {
        let zip = TestFiles.tempDir().appendingPathComponent("link.nibplugin")
        try TestZip.make([.file("manifest.json", TestFiles.manifest()), .link("main.js", to: "/etc/passwd")]).write(to: zip)
        XCTAssertThrowsError(try PackageStager.unzip(zip, into: TestFiles.tempDir())) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
            XCTAssertTrue((error as? NibError)?.message.contains("symbolic link") == true)
        }
        let folder = TestFiles.tempDir()
        try TestFiles.write(files, into: folder)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.js"),
                                                   withDestinationURL: folder.appendingPathComponent("main.js"))
        XCTAssertThrowsError(try PackageStager.copyFolder(folder, into: TestFiles.tempDir()))
        XCTAssertThrowsError(try PluginPackageHash.compute(folder), "a folder with a link has no hash")
    }

    func testBundlesOver20MBAreRejected() throws {
        let folder = TestFiles.tempDir()
        try TestFiles.write(files, into: folder)
        let big = folder.appendingPathComponent("assets/video.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(PluginRules.maxBundleBytes) + 1)   // sparse: nothing is written
        try handle.close()
        XCTAssertThrowsError(try PackageStager.copyFolder(folder, into: TestFiles.tempDir())) { error in
            XCTAssertTrue((error as? NibError)?.message.contains("20 MB") == true)
        }
        XCTAssertThrowsError(try PluginPackage.inspect(folder, unwrap: false))
        let budget = PackageStager.Budget()
        XCTAssertNoThrow(try budget.check(pending: PluginRules.maxBundleBytes))
        budget.commit(PluginRules.maxBundleBytes)
        XCTAssertThrowsError(try budget.check(pending: 1))
    }

    func testDirectoryOnlyArchivesAndFoldersHaveAnEntryLimit() throws {
        let source = TestFiles.tempDir()
        defer { try? FileManager.default.removeItem(at: source) }
        let entries = (0...PluginRules.maxEntries).map { TestZip.Entry.folder("folder-\($0)") }
        let zip = source.appendingPathComponent("directories.nibplugin")
        try TestZip.make(entries).write(to: zip)
        let dest = TestFiles.tempDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertThrowsError(try PackageStager.unzip(zip, into: dest)) { error in
            XCTAssertTrue((error as? NibError)?.message.contains("entries") == true)
        }
        let folders = source.appendingPathComponent("folders")
        for entry in entries {
            try FileManager.default.createDirectory(at: folders.appendingPathComponent(entry.path), withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try PackageStager.copyFolder(folders, into: dest)) { error in
            XCTAssertTrue((error as? NibError)?.message.contains("entries") == true)
        }
        XCTAssertThrowsError(try StagingPath.sanitize(String(repeating: "a", count: PluginRules.maxPathBytes + 1)))
        XCTAssertThrowsError(try StagingPath.sanitize(Array(repeating: "a", count: PluginRules.maxPathDepth + 1).joined(separator: "/")))
    }

    func testZipBudgetUsesActualChunksWhenDeclaredSizeLies() throws {
        let root = TestFiles.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("lying.nibplugin")
        for deflated in [false, true] {
            let entry = TestZip.Entry(path: "big.bin", data: Data(repeating: 0x61, count: Int(PluginRules.maxBundleBytes) + 1),
                                      declaredSize: 1, deflated: deflated)
            try TestZip.make([entry]).write(to: zip)
            XCTAssertThrowsError(try PackageStager.unzip(zip, into: root.appendingPathComponent("out"))) { error in
                XCTAssertTrue((error as? NibError)?.message.contains("20 MB") == true, "\(error)")
            }
        }
    }

    func testHashSnapshotRetainsTheExactManifestAndCodeBytesItHashed() throws {
        let root = TestFiles.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = TestFiles.manifest(permissions: ["network"], hosts: ["approved.example.com"])
        try TestFiles.write([("manifest.json", manifest), ("main.js", "approved();"), ("panel.html", "<p>approved</p>")], into: root)
        let snapshot = try PluginPackageHash.snapshot(files: PluginPackageHash.files(root))
        let hash = try PluginPackageHash.compute(root)
        try TestFiles.write([("manifest.json", TestFiles.manifest(permissions: ["network"], hosts: ["unshown.example.com"])),
                             ("panel.html", "<script>changed()</script>")], into: root)
        XCTAssertEqual(snapshot.sha256, hash)
        XCTAssertNotEqual(snapshot.sha256, try PluginPackageHash.compute(root))
        XCTAssertEqual(ManifestCheck.hosts(try ManifestCheck.decode(XCTUnwrap(snapshot.manifest))), ["approved.example.com"])
        XCTAssertEqual(snapshot.previews.first { $0.path == "panel.html" }?.text, "<p>approved</p>")
    }

    func testPackageReplacementRetainsItsBackupUntilCommittedAndCanRollBack() throws {
        let root = TestFiles.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appendingPathComponent("plugins")
        let old = plugins.appendingPathComponent("dev.nib.cards")
        let new = root.appendingPathComponent("new")
        try TestFiles.write([("main.js", "old")], into: old)
        try TestFiles.write([("main.js", "new")], into: new)
        let backup = try XCTUnwrap(PackagePlacer.place(new, at: old, in: plugins))
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("main.js")), "old")
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("main.js")), "new")
        try PackagePlacer.restore(backup, at: old)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("main.js")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testZipOfThePluginFolderIsUnwrappedAndValidated() throws {
        let zip = TestFiles.tempDir().appendingPathComponent("cards.zip")
        try TestZip.make([.folder("dev.nib.cards"), .file("__MACOSX/dev.nib.cards/._main.js", "fork")]
                         + files.map { TestZip.Entry.file("dev.nib.cards/" + $0.0, $0.1) }).write(to: zip)
        let out = TestFiles.tempDir()
        try PackageStager.unzip(zip, into: out)
        let package = try PluginPackage.inspect(out, unwrap: true)
        XCTAssertEqual(package.root.lastPathComponent, "dev.nib.cards")
        XCTAssertEqual(package.manifest.id, "dev.nib.cards")
        XCTAssertEqual(package.files.map { $0.path }.sorted(), files.map { $0.0 }.sorted())
        XCTAssertEqual(package.code?.path, "main.js")
        XCTAssertEqual(package.code?.isTruncated, false)
        let direct = TestFiles.tempDir()
        try TestFiles.write(files, into: direct)
        XCTAssertEqual(package.sha256, try PluginPackageHash.compute(direct), "the wrapping folder is not part of the package")
    }

    func testManifestValidation() throws {
        let root = TestFiles.tempDir()
        try TestFiles.write([("main.js", "1")], into: root)
        func problems(_ text: String) throws -> [NibError] {
            ManifestCheck.problems(try TestFiles.decodeManifest(text), root: root)
        }
        XCTAssertEqual(try problems(TestFiles.manifest()), [])
        XCTAssertFalse(try problems(TestFiles.manifest(id: "Cards_Plugin")).isEmpty)
        XCTAssertFalse(try problems(TestFiles.manifest(version: "1.0")).isEmpty)
        XCTAssertEqual(try problems(TestFiles.manifest(extra: ["api": 2])).first?.code, .unsupported)
        XCTAssertEqual(try problems(TestFiles.manifest(permissions: ["plugins:manage"])).first?.code, .permissionDenied)
        XCTAssertFalse(try problems(TestFiles.manifest(permissions: ["everything"])).isEmpty)
        XCTAssertFalse(try problems(TestFiles.manifest(hosts: ["https://api.example.com"])).isEmpty)
        XCTAssertFalse(try problems(TestFiles.manifest(extra: ["entry": "missing.js"])).isEmpty)
        XCTAssertFalse(try problems(TestFiles.manifest(extra: ["entry": "../main.js"])).isEmpty)
        let foreignCommand: JSONValue = ["commands": [["id": "other.plugin.go", "title": "Go", "summary": "Go."]]]
        XCTAssertFalse(try problems(TestFiles.manifest(extra: ["contributes": foreignCommand])).isEmpty)
        XCTAssertThrowsError(try ManifestCheck.decode(Data(#"{"id": "dev.nib.cards"}"#.utf8))) { error in
            XCTAssertTrue((error as? NibError)?.message.contains("missing") == true)
        }
    }

    // Acceptance: permission-diff logic.
    func testPermissionDiff() throws {
        let next = try TestFiles.decodeManifest(TestFiles.manifest(permissions: ["network", "document:read", "ai"],
                                                                   hosts: ["API.example.com", "cdn.example.com"],
                                                                   commands: ["go", "stop"]))
        let d = PermissionDiff.between(oldPermissions: ["document:read", "document:write"], oldHosts: ["api.example.com"],
                                       oldCommands: ["dev.nib.cards.go"], new: next)
        XCTAssertEqual(d.unchanged, ["document:read"])
        XCTAssertEqual(d.added, ["ai", "network"], "consent order, not manifest order")
        XCTAssertEqual(d.removed, ["document:write"])
        XCTAssertEqual(d.hosts, ["api.example.com", "cdn.example.com"])
        XCTAssertEqual(d.addedHosts, ["cdn.example.com"])
        XCTAssertEqual(d.addedCommands, ["dev.nib.cards.stop"])
        XCTAssertTrue(d.isExpansion)

        // Fewer permissions (and fewer hosts) are no expansion.
        let smaller = try TestFiles.decodeManifest(TestFiles.manifest(permissions: ["document:read", "network"], hosts: ["api.example.com"]))
        let shrink = PermissionDiff.between(oldPermissions: ["document:read", "document:write", "network"],
                                            oldHosts: ["api.example.com", "cdn.example.com"], oldCommands: nil, new: smaller)
        XCTAssertEqual(shrink.removed, ["document:write"])
        XCTAssertEqual(shrink.removedHosts, ["cdn.example.com"])
        XCTAssertFalse(shrink.isExpansion)

        // A new host is an expansion only while the plugin holds "network".
        let hostsOnly = try TestFiles.decodeManifest(TestFiles.manifest(permissions: ["document:read"], hosts: ["new.example.com"]))
        XCTAssertFalse(PermissionDiff.between(oldPermissions: ["document:read"], oldHosts: [], oldCommands: nil, new: hostsOnly).isExpansion)
        let withNetwork = try TestFiles.decodeManifest(TestFiles.manifest(permissions: ["network"], hosts: ["new.example.com"]))
        XCTAssertTrue(PermissionDiff.between(oldPermissions: ["network"], oldHosts: [], oldCommands: nil, new: withNetwork).isExpansion)

        // A first install has nothing to compare with.
        let first = PermissionDiff.between(oldPermissions: nil, oldHosts: nil, oldCommands: nil, new: next)
        XCTAssertEqual(first.unchanged, ["document:read", "ai", "network"])
        XCTAssertEqual(first.added, [])
        XCTAssertFalse(first.isExpansion)

        // Consent carries over: what the person switched off stays off, what is new starts on (to be checked).
        XCTAssertEqual(first.initialConsent(previous: nil), ["document:read", "ai", "network"])
        let update = PermissionDiff.between(oldPermissions: ["document:read", "ai"], oldHosts: nil, oldCommands: nil, new: next)
        XCTAssertEqual(update.initialConsent(previous: ["document:read"]), ["document:read", "network"])
    }

    func testSemanticVersionsOrder() {
        func v(_ s: String) -> SemVer? { SemVer(s) }
        XCTAssertLessThan(v("1.2.3")!, v("1.10.0")!)
        XCTAssertLessThan(v("1.0.0-beta.2")!, v("1.0.0-beta.11")!)
        XCTAssertLessThan(v("1.0.0-alpha")!, v("1.0.0")!)
        XCTAssertLessThan(v("1.0.0-1")!, v("1.0.0-alpha")!)
        XCTAssertEqual(v("2.0.0+build.7"), v("2.0.0"))
        XCTAssertNil(v("1.0"))
        XCTAssertNil(v("one.two.three"))
    }

    func testGrantFileKeepsOtherEntriesInTheHostsFormat() throws {
        let url = TestFiles.tempDir().appendingPathComponent("PluginGrants.json")
        try Data(#"{"dev.other.tool": {"sha256": "abc", "scopes": ["app"], "future": 1}}"#.utf8).write(to: url)
        let file = PluginGrantFile(url: url)
        try file.set(StoredGrant(sha256: "f00d", scopes: ["document:read"], source: "url:https://example.com/p.nibplugin",
                                 version: "1.0.0", permissions: ["document:read", "ai"], hosts: []), for: "dev.nib.cards")
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        XCTAssertEqual(raw["dev.other.tool"]?["future"], 1, "entries of other writers are kept as they are")
        // What the plugin host decodes: {sha256, scopes, source}.
        XCTAssertEqual(raw["dev.nib.cards"]?["sha256"], "f00d")
        XCTAssertEqual(raw["dev.nib.cards"]?["scopes"], ["document:read"])
        XCTAssertEqual(file.grant("dev.nib.cards")?.permissions, ["document:read", "ai"])
        XCTAssertEqual(file.grant("dev.other.tool")?.scopes, ["app"])
        try file.set(nil, for: "dev.nib.cards")
        XCTAssertNil(file.grant("dev.nib.cards"))
        XCTAssertNotNil(file.grant("dev.other.tool"))
    }

    func testCorruptGrantsArePreservedAndIOErrorsCannotOverwriteTheFile() throws {
        let root = TestFiles.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("PluginGrants.json")
        let damaged = Data("not JSON".utf8)
        try damaged.write(to: url)
        let file = PluginGrantFile(url: url)
        try file.set(StoredGrant(sha256: "abc", scopes: ["app"]), for: "dev.nib.cards")
        let aside = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("PluginGrants.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: aside), damaged)
        XCTAssertEqual(file.grant("dev.nib.cards")?.sha256, "abc")

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try TestFiles.write([("untouched", "keep")], into: url)
        XCTAssertThrowsError(try file.set(StoredGrant(sha256: "new", scopes: []), for: "dev.nib.cards"))
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("untouched")), "keep")
    }

    func testSourcesNeedExactlyOneKindAndGalleryPathsStayUnderBase() throws {
        XCTAssertThrowsError(try PluginSource.from(url: nil, path: nil, files: nil, base: nil, index: nil))
        XCTAssertThrowsError(try PluginSource.from(url: "https://a.example/p.nibplugin", path: "/tmp/p", files: nil, base: nil, index: nil))
        XCTAssertThrowsError(try PluginSource.from(url: nil, path: nil, files: ["main.js"], base: nil, index: nil))
        XCTAssertThrowsError(try PluginSource.from(url: nil, path: nil, files: ["main.js": "1"], base: "https://a.example/", index: nil))
        XCTAssertEqual(try PluginSource.from(url: nil, path: nil, files: ["main.js": "1"], base: nil, index: nil), .inline(["main.js": "1"]))
        XCTAssertThrowsError(try PluginSource.fileReference("plugins/dev.nib.cards"))
        XCTAssertEqual(try PluginSource.fileReference("/tmp/cards.nibplugin"), "file:///tmp/cards.nibplugin")

        let source = try PluginSource.from(url: nil, path: nil, files: ["manifest.json", "main.js"], base: "examples/hello-world",
                                           index: "https://raw.example.com/nib/plugins/index.json")
        guard case let .gallery(base, list) = source else { return XCTFail("expected a gallery source") }
        XCTAssertEqual(base.absoluteString, "https://raw.example.com/nib/plugins/examples/hello-world/")
        XCTAssertEqual(list, ["manifest.json", "main.js"])
        XCTAssertEqual(try GallerySource.fileURL("panels/word count.html", base: base, path: "$").url.absoluteString,
                       "https://raw.example.com/nib/plugins/examples/hello-world/panels/word%20count.html")
        XCTAssertThrowsError(try GallerySource.fileURL("../../secret.js", base: base, path: "$"))
        XCTAssertThrowsError(try GallerySource.resolveBase("ftp://example.com/p/", index: nil))
        XCTAssertThrowsError(try GallerySource.resolveBase("http://example.com/p/", index: nil))
        XCTAssertEqual(try GallerySource.resolveBase("http://example.com/p/", index: nil, allowHTTP: true).scheme, "http")
        XCTAssertThrowsError(try GallerySource.resolveBase("examples/", index: nil), "a relative base needs the index")
    }

    func testConsentSheetModelNeedsAReviewOnlyWhenAnUpdateAsksForMore() throws {
        let next = try TestFiles.decodeManifest(TestFiles.manifest(version: "1.1.0", permissions: ["document:read", "ai"],
                                                                   commands: ["go"]))
        let package = PluginPackage(root: TestFiles.tempDir(), manifest: next, sha256: String(repeating: "ab", count: 32),
                                    files: [PackageFileInfo(path: "main.js", bytes: 12)], totalBytes: 12,
                                    code: CodePreview(path: "main.js", text: "1", totalBytes: 1, isTruncated: false))
        let diff = PermissionDiff.between(oldPermissions: ["document:read", "document:write"], oldHosts: [], oldCommands: [],
                                          new: next)
        let update = PluginConsentRequest(kind: .update(from: "1.0.0"), package: package,
                                          source: SourceInfo(kind: .url, detail: "https://example.com/cards.nibplugin"),
                                          requestedBy: .user, diff: diff, previousConsent: ["document:read"], galleryVerified: false)
        XCTAssertTrue(update.requiresReview)
        XCTAssertEqual(update.commands, [PluginConsentRequest.Command(id: "dev.nib.cards.go", title: "Go", isNew: true)])
        let model = ConsentSheetModel(request: update)
        XCTAssertEqual(model.switches.map { $0.id }, ["document:read", "ai"])
        XCTAssertEqual(model.switches.map { $0.isAdded }, [false, true])
        XCTAssertFalse(model.canApprove, "Update stays disabled until the person checked what changed")
        var decisions: [PluginConsentDecision] = []
        model.onFinish = { decisions.append($0) }
        model.approve()
        XCTAssertTrue(decisions.isEmpty)
        model.reviewed = true
        model.switches[1].isOn = false
        model.approve()
        model.cancel()
        XCTAssertEqual(decisions, [.approve(["document:read"])], "one decision, with what was left on")
        XCTAssertEqual(model.versionLine, "Version 1.0.0 → 1.1.0 · by Ada")

        let install = PluginConsentRequest(kind: .install, package: package,
                                           source: SourceInfo(kind: .inline, detail: "ai:chat1"), requestedBy: .ai("chat1"),
                                           diff: PermissionDiff.between(oldPermissions: nil, oldHosts: nil, oldCommands: nil, new: next),
                                           previousConsent: nil, galleryVerified: false)
        XCTAssertFalse(install.requiresReview)
        let fresh = ConsentSheetModel(request: install)
        XCTAssertTrue(fresh.canApprove)
        XCTAssertTrue(fresh.showsCode, "the code viewer opens for plugins the assistant wrote")
        XCTAssertEqual(fresh.notices.map { $0.id }, ["inline"])
        XCTAssertEqual(ConsentWords.permission("library:write", hosts: []), "Organise your library")
        XCTAssertEqual(ConsentWords.permission("network", hosts: ["api.example.com"]), "Connect to: api.example.com")
        XCTAssertEqual(ConsentWords.sourceDetail(SourceInfo(kind: .inline, detail: "ai:chat1")), "Written by the assistant")
    }

    /// DESIGN.md §15.7: the new screen renders in Light, Dark and AX3, at iPhone and iPad sheet sizes.
    func testConsentSheetRendersInEveryVariant() throws {
        let next = try TestFiles.decodeManifest(TestFiles.manifest(version: "1.1.0", permissions: ["document:read", "ai", "network"],
                                                                   hosts: ["api.example.com"], commands: ["go"],
                                                                   extra: ["description": "Turns term and definition lines into a study set."]))
        let package = PluginPackage(root: TestFiles.tempDir(), manifest: next, sha256: String(repeating: "c0", count: 32),
                                    files: [PackageFileInfo(path: "main.js", bytes: 2_048), PackageFileInfo(path: "manifest.json", bytes: 512)],
                                    totalBytes: 2_560,
                                    code: CodePreview(path: "main.js", text: "nib.commands.register('dev.nib.cards.go', () => 1);",
                                                      totalBytes: 2_048, isTruncated: false))
        let diff = PermissionDiff.between(oldPermissions: ["document:read"], oldHosts: [], oldCommands: [], new: next)
        let request = PluginConsentRequest(kind: .update(from: "1.0.0"), package: package,
                                           source: SourceInfo(kind: .gallery, detail: "https://raw.example.com/nib/plugins/cards/"),
                                           requestedBy: .ai("chat1"), diff: diff, previousConsent: ["document:read"],
                                           galleryVerified: true)
        let sheet = ConsentSheet(model: ConsentSheetModel(request: request))
        for size in [CGSize(width: 390, height: 844), CGSize(width: 540, height: 620)] {
            let images = NibSnapshot.images(sheet, size: size)
            XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases), "\(size)")
        }
    }
}
