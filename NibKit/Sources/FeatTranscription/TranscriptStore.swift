import Foundation
import NibContracts
import os

/// Disk layout shared with NibIndex: one array per device, merged by stable line index.
actor TranscriptFiles {
    struct Write {
        let url: URL
        let before: Data?
        let after: Data
    }

    private var warnings: [URL: [String]] = [:]

    func warning(base: URL) -> NibError? {
        guard let names = warnings[base], !names.isEmpty else { return nil }
        return NibError(.conflict, "Skipped unreadable transcript files: \(names.joined(separator: ", "))", hint: "wait for these device files to finish syncing")
    }

    func read(base: URL, includingRetired: Bool = false, device: String? = nil) throws -> [TranscriptSegment] {
        let directory = base.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let stem = base.lastPathComponent
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { Self.matches($0.lastPathComponent, stem: stem) }.sorted { $0.path < $1.path }
        warnings[base] = []
        var arrays: [[TranscriptSegment]] = []
        for url in urls {
            do { arrays.append(try decode(url)) }
            catch {
                guard let device, url != base.appendingPathExtension(device).appendingPathExtension("json") else { throw error }
                warnings[base, default: []].append(url.lastPathComponent)
                Logger(subsystem: "app.nib", category: "transcription").error("Skipping unreadable transcript: \(url.lastPathComponent, privacy: .public)")
            }
        }
        let merged = Self.merge(arrays)
        return includingRetired ? merged : merged.filter { !Self.isRetired($0) }
    }

    static func matches(_ name: String, stem: String) -> Bool {
        if name == stem + ".json" { return true }
        guard name.hasPrefix(stem + "."), name.hasSuffix(".json") else { return false }
        let device = name.dropFirst(stem.count + 1).dropLast(5)
        return device.count == 8 && device.allSatisfy { "0123456789abcdef".contains($0) }
    }

    static func isRetired(_ line: TranscriptSegment) -> Bool { line.text.isEmpty && line.duration == 0 }

    static func merge(_ arrays: [[TranscriptSegment]]) -> [TranscriptSegment] {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var byIndex: [Int: TranscriptSegment] = [:]
        for lines in arrays {
            for line in lines {
                if let old = byIndex[line.index], (old.rev ?? .zero).effective(now: now) > (line.rev ?? .zero).effective(now: now) { continue }
                byIndex[line.index] = line
            }
        }
        return byIndex.values.sorted { $0.index < $1.index }
    }

    /// Patches only changed indices, never copies another device's lines into this device's file.
    func write(base: URL, device: String, lines: [TranscriptSegment]) throws -> Write {
        let url = base.appendingPathExtension(device).appendingPathExtension("json")
        let before = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let own = try before.map { try JSONDecoder().decode([TranscriptSegment].self, from: $0) } ?? []
        let all = Self.merge([own, lines])
        try Self.validate(all)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let after = try encoder.encode(all)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try after.write(to: url, options: .atomic)
        return Write(url: url, before: before, after: after)
    }

    /// Compare and write without an actor suspension between the two operations.
    func replace(base: URL, device: String, expected: [TranscriptSegment], lines: [TranscriptSegment]) throws -> Write {
        guard try read(base: base, includingRetired: true, device: device) == expected else {
            throw NibError(.conflict, "The transcript was edited while transcription was running",
                hint: "read transcript.get before replacing those edits")
        }
        return try write(base: base, device: device, lines: lines)
    }

    func rollback(_ write: Write) throws {
        // A subsequent successful edit owns the file now; do not undo it.
        guard try Data(contentsOf: write.url) == write.after else { return }
        if let before = write.before { try before.write(to: write.url, options: .atomic) }
        else { try FileManager.default.removeItem(at: write.url) }
    }

    private func decode(_ url: URL) throws -> [TranscriptSegment] {
        do {
            let lines = try JSONDecoder().decode([TranscriptSegment].self, from: Data(contentsOf: url))
            try Self.validate(lines)
            return lines
        } catch {
            throw NibError(.conflict, "The transcript file could not be read: \(url.lastPathComponent)",
                           hint: "restore the file from backup before editing the transcript")
        }
    }

    static func validate(_ lines: [TranscriptSegment]) throws {
        guard lines.allSatisfy({ $0.index >= 0 && $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration >= 0 }) else {
            throw NibError(.invalidParams, "Transcript timestamps and indices must be non-negative and finite",
                           path: "$.segments", hint: "call transcript.get to read valid lines")
        }
    }
}

@MainActor
final class TranscriptStore {
    static let serviceKey = "transcription.store"
    static let changed = "transcript.changed"
    let files = TranscriptFiles()
    let device: String
    init(device: String) { self.device = device }

    struct Clip {
        let doc: DocumentID
        let record: AudioClip
        let base: URL
        let audio: URL
    }

    static func of(_ services: NibServices) throws -> TranscriptStore {
        guard let store = services.get(serviceKey, as: TranscriptStore.self) else {
            throw NibError.unavailable("transcription storage")
        }
        return store
    }

    func clip(_ ref: String, workspace: Workspace) throws -> Clip {
        guard case let .audio(doc, id)? = NodeRef(ref), NibID.isValid(doc.raw), NibID.isValid(id.raw) else {
            throw NibError(.invalidParams, "Use an audio clip ref such as audio:D/A", path: "$.clip",
                           hint: "call audio.list for clip refs")
        }
        guard let record = try workspace.content(doc).liveAudio.first(where: { $0.id == id }) else {
            throw NibError.notFound("audio clip \(ref)")
        }
        let path = record.transcriptFile ?? "audio/\(id.raw).transcript"
        try Self.validatePath(path)
        try Self.validatePath(record.file)
        let base = try workspace.persistence.fileURL(doc, relativePath: path)
        let audio = try workspace.persistence.fileURL(doc, relativePath: record.file)
        return Clip(doc: doc, record: record, base: base, audio: audio)
    }

    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains(".."), !path.contains(":") else {
            throw NibError(.invariantViolation, "The recording contains an invalid package path")
        }
    }

    func read(_ clip: Clip) async throws -> [TranscriptSegment] { try await files.read(base: clip.base, device: device) }

    func persist(_ lines: [TranscriptSegment], clip: Clip, ctx: CommandContext, expected: [TranscriptSegment]? = nil) async throws {
        try Self.canWrite(clip.doc, ctx: ctx)
        guard !ctx.dryRun else { return }
        let write: TranscriptFiles.Write
        do {
            if let expected { write = try await files.replace(base: clip.base, device: device, expected: expected, lines: lines) }
            else { write = try await files.write(base: clip.base, device: device, lines: lines) }
        }
        catch { throw NibError.wrap(error) }
        do {
            try Self.canWrite(clip.doc, ctx: ctx)
            guard var current = try ctx.workspace.content(clip.doc).liveAudio.first(where: { $0.id == clip.record.id }) else {
                throw NibError.notFound("audio clip")
            }
            if current.transcriptFile == nil {
                current.transcriptFile = "audio/\(clip.record.id.raw).transcript"
                try ctx.mutate(undoable: false) { tx in _ = try tx.put(current, doc: clip.doc) }
            }
        } catch {
            try await files.rollback(write)
            throw error
        }
        ctx.events.emit(Self.changed, principal: ctx.principal, doc: clip.doc,
                        payload: ["clip": .string(NodeRef.audio(clip.doc, clip.record.id).description)])
    }

    static func canWrite(_ doc: DocumentID, ctx: CommandContext) throws {
        guard !ctx.readOnly else { throw NibError(.permissionDenied, "This command runs read-only") }
        guard !ctx.isReadOnly(doc) else { throw NibError(.permissionDenied, "This document is read-only") }
        if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "Unlock the document before transcribing") }
    }
}

/// Ink timestamps are absolute, transcript timestamps are relative to the clip.
enum TranscriptPageLink {
    static func mostEditedPage(clip: AudioClip, segment: TranscriptSegment,
                               pages: [(PageID, [Item])]) -> PageID? {
        let lower = clip.start + segment.start
        let upper = lower + segment.duration
        var winner: PageID?
        var count = 0
        for (page, items) in pages {
            let written = items.filter { item in
                guard !item.deleted, let stroke = item.stroke, stroke.style.tool != .tape else { return false }
                return stroke.t0 >= lower && stroke.t0 < upper
            }.count
            if written > count { count = written; winner = page }
        }
        return winner ?? clip.page
    }

    static func activeIndex(_ lines: [TranscriptSegment], at time: Double) -> Int? {
        lines.last { $0.start <= time && time < $0.start + $0.duration }?.index
    }
}
