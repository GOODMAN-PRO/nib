import Foundation
import CryptoKit
import NibContracts

/// `AssetStore` over document packages: `assets/<sha256>.<ext>`, immutable and deduplicated by content, plus app-level
/// scratch assets in Caches/Nib/tmp that expire an hour after they were last stored. Thread-safe (drawers call it from
/// render threads): it touches only the captured `PackageLocator`, the read-only gate and the file system.
final class PackageAssetStore: AssetStore {
    static let temporaryLifetime: TimeInterval = 3600
    /// Expired scratch files are swept at most this often (on `putTemporary`).
    static let purgeInterval: TimeInterval = 600

    let temporaryDirectory: URL
    private let locator: PackageLocator
    private let gate: ReadOnlyGate
    private let lock = NSLock()
    private var lastPurge = Date.distantPast

    init(locator: PackageLocator, gate: ReadOnlyGate, temporaryDirectory: URL = PackageAssetStore.defaultTemporaryDirectory) {
        self.locator = locator
        self.gate = gate
        self.temporaryDirectory = temporaryDirectory
    }

    static var defaultTemporaryDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Nib/tmp", isDirectory: true)
    }

    // MARK: Document assets

    func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef {
        if gate.contains(doc) { throw ReadOnlyGate.refusal(doc) }
        guard let pkg = locator.url(doc) else { throw NibError.notFound("document \(doc.raw)") }
        let ref = try PackageAssetStore.ref(for: data, ext: ext)
        let url = pkg.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(ref.name)
        // Content-addressed: an existing file with this name already holds these bytes.
        if FileManager.default.fileExists(atPath: url.path) { return ref }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PackageFiles.coordinatedWrite(data, to: url)
        return ref
    }

    func url(_ ref: AssetRef, doc: DocumentID) -> URL? {
        guard let name = PackageAssetStore.fileName(ref), let pkg = locator.url(doc) else { return nil }
        let url = pkg.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func data(_ ref: AssetRef, doc: DocumentID) throws -> Data {
        guard let url = url(ref, doc: doc) else { throw NibError.notFound("asset \(ref.name) in document \(doc.raw)") }
        return try Data(contentsOf: url)
    }

    // MARK: Temporary assets

    func putTemporary(_ data: Data, ext: String) throws -> AssetRef {
        let ref = try PackageAssetStore.ref(for: data, ext: ext)
        purgeExpiredIfDue()
        let fm = FileManager.default
        let url = temporaryDirectory.appendingPathComponent(ref.name)
        if fm.fileExists(atPath: url.path) {
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) // restart its hour
        } else {
            try fm.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return ref
    }

    func temporaryURL(_ ref: AssetRef) -> URL? {
        guard let name = PackageAssetStore.fileName(ref) else { return nil }
        let url = temporaryDirectory.appendingPathComponent(name)
        guard let modified = PackageFiles.stamp(url).modified else { return nil }
        if Date().timeIntervalSince(modified) > PackageAssetStore.temporaryLifetime {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func purgeExpiredIfDue() {
        lock.lock()
        let due = Date().timeIntervalSince(lastPurge) > PackageAssetStore.purgeInterval
        if due { lastPurge = Date() }
        lock.unlock()
        guard due else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? [] {
            let url = temporaryDirectory.appendingPathComponent(name)
            if let modified = PackageFiles.stamp(url).modified,
               Date().timeIntervalSince(modified) > PackageAssetStore.temporaryLifetime {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: Names

    /// `<sha256 hex>.<ext>` with the extension lowercased; extensions are 1–16 ASCII letters or digits.
    static func ref(for data: Data, ext: String) throws -> AssetRef {
        var e = ext.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        guard (1...16).contains(e.count), e.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw NibError.invalid("asset extension '\(ext)' must be 1–16 letters or digits, e.g. png", path: "$.ext")
        }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AssetRef(hex + "." + e)
    }

    /// The file name a ref points at. Accepts "tmp:<name>" and "assets/<name>" spellings; anything that could leave
    /// the folder is refused.
    static func fileName(_ ref: AssetRef) -> String? {
        var name = ref.name
        for prefix in ["tmp:", "assets/"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return nil }
        return name
    }
}
