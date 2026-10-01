import Foundation
import CryptoKit
import UIKit
import os
import NibContracts
import NibDesign

enum LessonState: String, Codable, CaseIterable {
    case published, submitted, returned, resubmit

    func accepts(_ next: LessonState) -> Bool {
        self == next || (self == .published && next == .submitted)
            || (self == .submitted && next == .returned)
            || (self == .returned && next == .resubmit)
            || (self == .resubmit && next == .submitted)
    }

    var title: String {
        switch self {
        case .published: return String(localized: "Published")
        case .submitted: return String(localized: "Submitted")
        case .returned: return String(localized: "Returned")
        case .resubmit: return String(localized: "Resubmit")
        }
    }
}

struct LessonReturn: Codable, Equatable {
    var asset: AssetRef
    var at: Double
    var attempt: Int
}

/// Persisted in DocumentMeta.ext, available to query.get and the insights half of FeatTeacher.
struct LessonAssignment: Codable, Equatable {
    var source: DocumentID
    var folder: FolderID?
    var student: LessonStudent?
    var state: LessonState
    var attempt: Int
    var returns: [LessonReturn]
}

struct LessonRoster: Codable, Equatable {
    var folder: FolderID
    var students: [LessonStudent]
}

struct LessonSnapshot: Codable, Equatable {
    var content: DocumentContent
    var items: [PageID: [Item]]
}

@MainActor
enum LessonManager {
    static let assignmentKey = "nib.lesson"
    static let rosterKey = "nib.roster"
    static let privateSourceKey = "nib.lesson.privateSource"
    static let returnReadOnlyKey = "nib.lesson.returnReadOnly"
    static let managedKey = "nib.lesson.managed"
    nonisolated static let privatePrefix = "PRESENT_"
    /// S-095: Prep prepares the source before publication; student copies are independent after publishing.
    static let prepLayer = 0
    static let presentLayer = NibLimits.layerCount - 1
    static let feedbackLayer = 1
    static let feedbackLayerKey = "nib.lesson.feedbackLayer"

    static func feedbackLayer(in snapshot: LessonSnapshot) -> Int? {
        guard snapshot.content.meta.kind == .notebook || snapshot.content.meta.kind == .whiteboard else { return nil }
        let occupied = Set(snapshot.items.values.joined().map(\.layer))
        return (1..<presentLayer).first { !occupied.contains($0) }
    }

    static func assignment(_ meta: DocumentMeta) throws -> LessonAssignment? {
        guard let value = meta.ext?[assignmentKey] else { return nil }
        do { return try value.decode(LessonAssignment.self) }
        catch { throw NibError(.unsupported, "This lesson was saved with an unreadable assignment record.", hint: "update Nib before changing its state") }
    }

    static func rosterID(_ folder: FolderID) -> DocumentID { NibID("ROSTER_" + digest(folder.raw)) }
    static func privateID(_ source: DocumentID, device: String) -> DocumentID { NibID(privatePrefix + digest(source.raw + ":" + device)) }
    nonisolated static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(20).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func isPrivate(_ doc: DocumentID) -> Bool { doc.raw.hasPrefix(privatePrefix) }

    static func document(_ string: String, path: String = "$.doc") throws -> DocumentID {
        let id: DocumentID
        if let ref = NodeRef(string) {
            guard case .document(let d) = ref else { throw invalid("Choose a document ref.", path: path) }
            id = d
        } else { id = NibID(string) }
        guard NibID.isValid(id.raw) else { throw invalid("The document id is invalid.", path: path) }
        return id
    }

    static func folder(_ string: String, library: LibraryService) throws -> FolderID {
        let id: FolderID
        if let ref = NodeRef(string) {
            guard case .folder(let f) = ref else { throw invalid("Choose a class folder.", path: "$.folder") }
            id = f
        } else { id = NibID(string) }
        guard NibID.isValid(id.raw), let node = library.node(id), node.kind == .folder, node.trashedAt == nil else {
            throw NibError(.notFound, "The class folder is unavailable.", path: "$.folder", hint: "choose an existing shared synced folder with library.list")
        }
        return id
    }

    static func writable(_ doc: DocumentID, _ ctx: CommandContext) throws {
        guard !ctx.isReadOnly(doc), !(ctx.activeSession?.document == doc && ctx.activeSession?.readOnly == true) else {
            throw NibError(.permissionDenied, "This document is read-only.", hint: "open an editable copy")
        }
        guard ctx.services.lock?.isLocked(doc) != true else {
            throw NibError(.locked, "Unlock the document before using it in a lesson.", hint: "unlock it in Nib")
        }
    }

    /// Captures a consistent value snapshot before asynchronous asset work. Page and item ids stay stable between
    /// student copies, so answer zones match by id in By Page / By Question views. A doc ref still disambiguates them.
    static func capture(_ doc: DocumentID, workspace: Workspace) throws -> LessonSnapshot {
        let cached = workspace.cachedPages(doc)
        defer { workspace.evictPages(doc, keeping: cached) }
        let content = try workspace.content(doc)
        var items: [PageID: [Item]] = [:]
        for page in content.livePages { items[page.id] = try workspace.items(doc, page: page.id) }
        return LessonSnapshot(content: content, items: items)
    }

    /// Asset references in heads include cards, inline text, block display lists and page backgrounds. Audio and
    /// transcripts use package-relative files instead and are copied separately. Unknown extension fields survive.
    nonisolated static func assets(in value: JSONValue) -> Set<AssetRef> {
        var refs = Set<AssetRef>()
        func walk(_ value: JSONValue) {
            if case .object(let object) = value {
                for (key, child) in object {
                    if ["asset", "attachment", "tapePattern"].contains(key), let name = child.stringValue { refs.insert(AssetRef(name)) }
                    else { walk(child) }
                }
            } else if case .array(let array) = value { array.forEach(walk) }
        }
        walk(value)
        return refs
    }

    nonisolated static func remappedAssets(_ value: JSONValue, _ map: [String: AssetRef]) -> JSONValue {
        switch value {
        case .object(let object):
            var out = object
            for (key, child) in object {
                if ["asset", "attachment", "tapePattern"].contains(key), let name = child.stringValue, let ref = map[name] {
                    out[key] = .string(ref.name)
                } else { out[key] = remappedAssets(child, map) }
            }
            return .object(out)
        case .array(let array): return .array(array.map { remappedAssets($0, map) })
        default: return value
        }
    }

    static func invalid(_ message: String, path: String) -> NibError {
        NibError(.invalidParams, message, path: path, hint: "call commands.describe for lesson.create, lesson.setState or lesson.importRoster")
    }

    static func sample(id: DocumentID) throws -> LessonSnapshot {
        var meta = DocumentMeta(id: id, kind: .notebook, language: "en-GB")
        meta.layers[prepLayer].name = String(localized: "Prep")
        meta.layers[feedbackLayer].name = String(localized: "Feedback")
        meta.ext = [managedKey: true]
        let page = PageRecord(order: "V", size: .a4, title: String(localized: "Sample Lesson"))
        let heading = Item(kind: .text, z: "V", text: TextBoxItem(
            frame: Frame(x: 48, y: 48, w: 499, h: 160),
            text: RichText(plain: String(localized: "Sample Lesson: motion\nA cyclist travels 120 metres in 20 seconds. What is their average speed?\nShow your working in the answer zone below."))))
        var zone = try AnswerZone(label: String(localized: "Average speed"), points: 3,
                                  hints: [String(localized: "Average speed is distance divided by time."),
                                          String(localized: "Divide 120 metres by 20 seconds. Include the units.")])
            .makeItem(frame: Frame(x: 48, y: 240, w: 499, h: 240), layer: prepLayer)
        zone.z = "k"
        let instructions = Item(kind: .text, z: "t", text: TextBoxItem(
            frame: Frame(x: 48, y: 540, w: 499, h: 180),
            text: RichText(plain: String(localized: "Teacher guide\nImport a CSV roster, then create a lesson to publish one copy per student. Use Present for private teaching notes. Students submit their copies; write feedback, then return the work. Returning saves a snapshot before a student resubmits."))))
        return LessonSnapshot(content: DocumentContent(meta: meta, pages: [page]), items: [page.id: [heading, zone, instructions]])
    }
}

/// The private Present workspace lives in Application Support, outside every class/library sync folder. It uses
/// ordinary document transactions and undo. No layer is merely hidden and then accidentally shared on disk.
@MainActor
final class PrivateLessonPersistence: DocumentPersistence {
    let base: DocumentPersistence
    let root: URL
    private var cache: [DocumentID: LessonSnapshot] = [:]
    private let writer = DispatchQueue(label: "app.nib.teacherlessons.private")
    private let log = Logger(subsystem: "app.nib", category: "teacherlessons")

    init(base: DocumentPersistence, root: URL) { self.base = base; self.root = root }
    func package(_ doc: DocumentID) -> URL { root.appendingPathComponent(doc.raw, isDirectory: true) }
    func seed(_ snapshot: LessonSnapshot) throws {
        let doc = snapshot.content.meta.id
        try FileManager.default.createDirectory(at: package(doc), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: package(doc).appendingPathComponent("presentation.json"), options: .atomic)
        cache[doc] = snapshot
    }
    private func snapshot(_ doc: DocumentID) throws -> LessonSnapshot {
        if let value = cache[doc] { return value }
        writer.sync {}
        let url = package(doc).appendingPathComponent("presentation.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw NibError.notFound("private presentation \(doc.raw)") }
        let value = try JSONDecoder().decode(LessonSnapshot.self, from: Data(contentsOf: url))
        cache[doc] = value
        return value
    }
    func loadHead(_ doc: DocumentID) throws -> DocumentContent {
        if LessonManager.isPrivate(doc) { return try snapshot(doc).content }
        return try base.loadHead(doc)
    }
    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        if LessonManager.isPrivate(doc) { return try snapshot(doc).items[page] ?? [] }
        return try base.loadItems(doc, page: page)
    }
    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        guard LessonManager.isPrivate(doc) else { base.didChange(doc, head: head, pages: pages); return }
        do {
            var value = try snapshot(doc)
            if let head { value.content = head }
            for (page, items) in pages { value.items[page] = items }
            cache[doc] = value
            let url = package(doc).appendingPathComponent("presentation.json"), log = self.log
            writer.async {
                do { try JSONEncoder().encode(value).write(to: url, options: .atomic) }
                catch { log.error("Could not save private presentation: \(error.localizedDescription, privacy: .public)") }
            }
        } catch { log.error("Could not load private presentation: \(error.localizedDescription, privacy: .public)") }
    }
    func flush(_ doc: DocumentID) { if LessonManager.isPrivate(doc) { writer.sync {} } else { base.flush(doc) } }
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL {
        guard LessonManager.isPrivate(doc) else { return try base.fileURL(doc, relativePath: relativePath) }
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else { throw NibError.invalid("invalid private file path") }
        let url = package(doc).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { LessonManager.isPrivate(doc) ? nil : try base.remoteChanges(doc) }
    func isReadOnly(_ doc: DocumentID) -> Bool {
        if LessonManager.isPrivate(doc) { return (try? snapshot(doc).content.meta.ext?[LessonManager.returnReadOnlyKey]?.boolValue) == true }
        return base.isReadOnly(doc)
    }
    func contentRevision(_ doc: DocumentID, page: PageID) -> Rev? {
        if LessonManager.isPrivate(doc) { return (try? snapshot(doc).items[page]?.map(\.rev).max()) ?? nil }
        return base.contentRevision(doc, page: page)
    }
}

/// Private presentation assets follow the private document; all public documents use the installed AssetStore.
final class PrivateLessonAssets: AssetStore {
    let base: AssetStore
    let root: URL
    init(base: AssetStore, root: URL) { self.base = base; self.root = root }
    func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef {
        guard LessonManager.isPrivate(doc) else { return try base.put(data, ext: ext, doc: doc) }
        guard ext.range(of: "^[A-Za-z0-9]{1,16}$", options: .regularExpression) != nil else { throw NibError.invalid("invalid asset extension") }
        let ref = AssetRef(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "." + ext.lowercased())
        guard let url = url(ref, doc: doc) else { throw NibError.invalid("invalid private asset name") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return ref
    }
    func url(_ ref: AssetRef, doc: DocumentID) -> URL? {
        guard LessonManager.isPrivate(doc) else { return base.url(ref, doc: doc) }
        guard !ref.name.contains("/"), !ref.name.contains("\\"), !ref.name.hasPrefix(".") else { return nil }
        return root.appendingPathComponent(doc.raw).appendingPathComponent("assets").appendingPathComponent(ref.name)
    }
    func data(_ ref: AssetRef, doc: DocumentID) throws -> Data {
        guard LessonManager.isPrivate(doc) else { return try base.data(ref, doc: doc) }
        guard let url = url(ref, doc: doc) else { throw NibError.invalid("invalid private asset name") }
        return try Data(contentsOf: url)
    }
    func putTemporary(_ data: Data, ext: String) throws -> AssetRef { try base.putTemporary(data, ext: ext) }
    func temporaryURL(_ ref: AssetRef) -> URL? { base.temporaryURL(ref) }
}
