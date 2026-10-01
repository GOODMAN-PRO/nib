import Foundation
import UIKit
import PDFKit
import CryptoKit
import os
import NibContracts

struct CustomTemplate: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var kind: String
    var file: String
    var size: PageSize
    var rev: Rev
    var deleted = false
}

struct TemplateGroup: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var rev: Rev
    var deleted = false
    var templates: [CustomTemplate] = []
    var liveTemplates: [CustomTemplate] { templates.filter { !$0.deleted }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
}

/// A device writes only its own group file. Blobs are immutable, content addressed and retained with tombstones
/// so a slow device can still merge a deletion, and an already applied document never depends on this library.
actor CustomTemplateStore {
    private static let logger = Logger(subsystem: "app.nib", category: "templateui")
    nonisolated let root: URL
    let clock: HLCClock
    init(root: URL, clock: HLCClock) { self.root = root; self.clock = clock }

    nonisolated static func validID(_ id: String, field: String = "id") throws -> String {
        guard NibID.isValid(id) else { throw NibError.invalid("Use 1–64 letters, digits, underscores or hyphens.", path: "$." + field) }
        return id
    }

    nonisolated static func title(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw NibError.invalid("Enter a title of 1–200 characters.", path: "$.title") }
        return value
    }

    func groups(includeDeleted: Bool = false) throws -> [TemplateGroup] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var merged: [TemplateGroup] = []
        let directories: [URL]
        do { directories = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) }
        catch {
            Self.logger.warning("Cannot scan template library: \(error.localizedDescription, privacy: .public)")
            return []
        }
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  NibID.isValid(directory.lastPathComponent) else { continue }
            var winner: TemplateGroup?
            var deleted = false
            var templates: [String: CustomTemplate] = [:]
            let files: [URL]
            do { files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch {
                Self.logger.warning("Cannot scan template group: \(directory.path, privacy: .public)")
                continue
            }
            for file in files.sorted(by: { $0.path < $1.path })
                where file.lastPathComponent.hasPrefix("group.") && file.pathExtension == "json" {
                do {
                    // Decode entries separately so one future-version entry does not hide its valid siblings.
                    let data = try Data(contentsOf: file)
                    var object = try JSONDecoder().decode(JSONValue.self, from: data)
                    let entries = object["templates"]?.arrayValue ?? []
                    guard case var .object(fields) = object else { throw NibError.invalid("Invalid group record") }
                    fields["templates"] = []
                    object = .object(fields)
                    let group = try object.decode(TemplateGroup.self)
                    guard group.id == directory.lastPathComponent else { throw NibError.invalid("Mismatched group ID") }
                    clock.observe(group.rev)
                    deleted = deleted || group.deleted
                    if winner == nil || winner!.rev.effective() < group.rev.effective() { winner = group }
                    for value in entries {
                        guard let entry = try? value.decode(CustomTemplate.self), NibID.isValid(entry.id),
                              Self.isBlobName(entry.file), entry.kind == "paper" || entry.kind == "cover",
                              entry.size.width.isFinite, entry.size.height.isFinite, entry.size.width > 0, entry.size.height > 0 else {
                            Self.logger.warning("Skipping invalid template entry in \(file.path, privacy: .public)")
                            continue
                        }
                        clock.observe(entry.rev)
                        if templates[entry.id] == nil || templates[entry.id]!.rev.effective() < entry.rev.effective() { templates[entry.id] = entry }
                    }
                } catch {
                    Self.logger.warning("Skipping invalid template group file \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if var group = winner {
                group.deleted = deleted
                group.templates = templates.values.sorted { $0.id < $1.id }.map { entry in
                    var entry = entry
                    if deleted { entry.deleted = true }
                    return entry
                }
                if includeDeleted || !group.deleted { merged.append(group) }
            }
        }
        return merged.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func isBlobName(_ name: String) -> Bool {
        let components = name.split(separator: ".")
        return components.count == 2 && components[0].count == 64 && components[0].allSatisfy { $0.isHexDigit }
            && ["pdf", "png"].contains(String(components[1]))
    }

    func group(_ id: String, includeDeleted: Bool = false) throws -> TemplateGroup {
        _ = try Self.validID(id, field: "group")
        guard let g = try groups(includeDeleted: includeDeleted).first(where: { $0.id == id }) else { throw NibError.notFound("Template group \(id)") }
        return g
    }

    func write(_ group: TemplateGroup) throws {
        let directory = root.appendingPathComponent(try Self.validID(group.id), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw NibError(.permissionDenied, "Template group folders must stay inside the library.")
        }
        let data = try JSONEncoder().encode(group)
        try data.write(to: directory.appendingPathComponent("group.\(clock.deviceHex).json"), options: .atomic)
    }

    @discardableResult
    func create(title: String, id: String?) throws -> TemplateGroup {
        let id = try Self.validID(id ?? NibID.make().raw)
        guard try !groups(includeDeleted: true).contains(where: { $0.id == id }) else { throw NibError.invalid("That group ID is already in use.", path: "$.id") }
        let group = TemplateGroup(id: id, title: try Self.title(title), rev: clock.tick())
        try write(group)
        return group
    }

    func rename(_ id: String, title: String) throws -> TemplateGroup {
        var group = try group(id)
        group.title = try Self.title(title); group.rev = clock.tick()
        try write(group)
        return group
    }

    func deleteGroup(_ id: String) throws {
        var group = try group(id)
        group.deleted = true; group.rev = clock.tick()
        for index in group.templates.indices { group.templates[index].deleted = true; group.templates[index].rev = clock.tick() }
        try write(group)
    }

    func locate(_ id: String) throws -> (TemplateGroup, CustomTemplate) {
        _ = try Self.validID(id)
        for group in try groups() {
            if let entry = group.liveTemplates.first(where: { $0.id == id }) { return (group, entry) }
        }
        throw NibError.notFound("Custom template \(id)")
    }

    func delete(_ id: String) throws {
        var (group, entry) = try locate(id)
        entry.deleted = true; entry.rev = clock.tick()
        group.templates.removeAll { $0.id == id }; group.templates.append(entry)
        try write(group)
    }

    // Actor isolation serialises each import, including preparation and persistence, away from MainActor.
    // There is no suspension between reading the merged snapshot and writing our device record.
    func importFile(_ url: URL, group requested: String?, kind: String, id: String?, title: String? = nil) throws -> CustomTemplate {
        guard kind == "paper" || kind == "cover" else { throw NibError.invalid("Choose paper or cover.", path: "$.kind") }
        let id = try Self.validID(id ?? NibID.make().raw)
        let snapshot = try groups(includeDeleted: true)
        guard !snapshot.contains(where: { $0.templates.contains { $0.id == id } }) else {
            throw NibError.invalid("That template ID is already in use.", path: "$.id")
        }
        let title = try Self.title(title ?? url.deletingPathExtension().lastPathComponent)
        var group: TemplateGroup
        if let requested {
            _ = try Self.validID(requested, field: "group")
            guard let existing = snapshot.first(where: { $0.id == requested && !$0.deleted }) else { throw NibError.notFound("Template group \(requested)") }
            group = existing
        } else if let custom = snapshot.first(where: { $0.id == "custom" && !$0.deleted }) { group = custom }
        else if let fallback = snapshot.first(where: { !$0.deleted && $0.title == String(localized: "Custom") }) { group = fallback }
        else {
            let defaultID = snapshot.contains { $0.id == "custom" } ? NibID.make().raw : "custom"
            group = TemplateGroup(id: defaultID, title: String(localized: "Custom"), rev: clock.tick())
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let prepared = try Self.prepare(url)
        let hash = SHA256.hash(data: prepared.data).map { String(format: "%02x", $0) }.joined()
        let name = hash + "." + prepared.ext
        let directory = root.appendingPathComponent(group.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw NibError(.permissionDenied, "Template group folders must stay inside the library.")
        }
        try prepared.data.write(to: directory.appendingPathComponent(name), options: .atomic)
        let entry = CustomTemplate(id: id, title: title, kind: kind, file: name, size: prepared.size, rev: clock.tick())
        group.templates.append(entry)
        try write(group)
        return entry
    }

    nonisolated private static func prepare(_ url: URL) throws -> (data: Data, ext: String, size: PageSize) {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= NibLimits.maxDownloadBytes else { throw NibError.invalid("Template files must be between 1 byte and 200 MB.", path: "$.url") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let pdf = PDFDocument(data: data) {
            guard !pdf.isLocked else { throw NibError(.locked, "Unlock the PDF before importing it.") }
            guard let first = pdf.page(at: 0) else { throw NibError.invalid("The PDF has no pages.", path: "$.url") }
            let bounds = first.bounds(for: .cropBox)
            let odd = (first.rotation / 90) % 2 != 0
            let size = PageSize(Double(odd ? bounds.height : bounds.width), Double(odd ? bounds.width : bounds.height))
            guard size.width > 0, size.height > 0 else { throw NibError.invalid("The first PDF page has no size.") }
            let one = PDFDocument(); one.insert(first, at: 0)
            guard let flattened = one.dataRepresentation() else { throw NibError(.invalidParams, "Cannot read the first PDF page.") }
            return (flattened, "pdf", size)
        }
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0,
              image.size.width * image.size.height <= 100_000_000 else { throw NibError.invalid("Import a PDF or a supported image of at most 100 megapixels.", path: "$.url") }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let normalised = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let png = normalised.pngData() else { throw NibError(.invalidParams, "Cannot decode the template image.") }
        return (png, "png", PageSize(Double(image.size.width), Double(image.size.height)))
    }

    nonisolated func url(group: TemplateGroup, template: CustomTemplate) -> URL {
        root.appendingPathComponent(group.id, isDirectory: true).appendingPathComponent(template.file)
    }

    func background(_ id: String, doc: DocumentID?, assets: AssetStore) async throws -> Background {
        let (group, entry) = try locate(id)
        return try await background(group: group, entry: entry, doc: doc, assets: assets)
    }

    func background(group: TemplateGroup, entry: CustomTemplate, doc: DocumentID?, assets: AssetStore) async throws -> Background {
        let url = url(group: group, template: entry)
        return try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let ext = (entry.file as NSString).pathExtension
            let asset = try doc.map { try assets.put(data, ext: ext, doc: $0) } ?? assets.putTemporary(data, ext: ext)
            let ref = doc == nil ? AssetRef("tmp:" + asset.name) : asset
            return ext == "pdf" ? .ofPDF(ref, page: 0) : .ofImage(ref)
        }.value
    }
}
