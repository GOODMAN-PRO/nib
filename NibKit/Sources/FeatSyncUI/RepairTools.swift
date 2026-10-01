import Foundation
import NibContracts

/// The catalogue is derived data; a repair never deletes document packages or resets their revisions.
/// F002's refresh deliberately performs a full scan when this root's cache file is absent.
struct CatalogCacheRepair {
    static func cacheURL(root: URL, support: URL) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in root.standardizedFileURL.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return support.appendingPathComponent("Nib/library", isDirectory: true)
            .appendingPathComponent("catalog-" + String(format: "%016llx", hash) + ".json")
    }

    static func invalidate(root: URL, support: URL) throws {
        let url = cacheURL(root: root, support: support)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor
final class RepairState {
    static let key = "syncui.repairState"
    var running = false
}

struct LibraryRepair: NibCommand {
    struct Params: Codable { var rebuildIndex: Bool? }
    struct Failure: Codable, Equatable { var ref: String; var message: String }
    struct Output: Codable {
        var catalogRebuilt: Bool
        var merged: Int
        var skippedReadOnly: [String]
        var errors: [Failure]
        var indexRebuilt: Bool
        var dryRun: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "library.repair", title: String(localized: "Repair Library"),
        summary: "Rebuild the library catalogue, re-merge open packages and optionally rebuild search; originals and undo history are preserved. Returns per-document errors.",
        params: .obj(["rebuildIndex": .bool("also rebuild the search index (default false)")]),
        examples: [[:], ["rebuildIndex": true]], effect: .session, target: .library,
        extraScopes: [.libraryWrite], undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let library = ctx.services.library else { throw NibError.unavailable("the library") }
        guard ctx.bus.registry.entry(CommandIDs.syncNow) != nil else { throw NibError.unavailable("folder sync") }
        guard let state = ctx.services.get(RepairState.key, as: RepairState.self) else {
            throw NibError.unavailable("library repair")
        }
        guard !state.running else {
            throw NibError(.unavailable, String(localized: "A library repair is already running."),
                           hint: "wait for the current repair to finish")
        }
        // Check optional dependencies before touching derived data.
        if p.rebuildIndex == true, ctx.bus.registry.entry(CommandIDs.indexRebuild) == nil {
            throw NibError.unavailable("search index rebuilding")
        }
        var out = Output(catalogRebuilt: false, merged: 0, skippedReadOnly: [], errors: [],
                         indexRebuilt: false, dryRun: ctx.dryRun)
        guard !ctx.dryRun else { return out }
        let requestedRoot = library.rootURL
        state.running = true
        defer { state.running = false }
        ctx.events.emit(SyncStatusPayload(state: "checking", source: "syncui", reason: "repair",
                                         message: String(localized: "Rebuilding the library catalogue…")))
        do {
            // Complete pending saves before reading remote records. Do not close documents: their undo stacks stay.
            for doc in ctx.workspace.loadedDocuments where !ctx.isReadOnly(doc) {
                ctx.workspace.persistence.flush(doc)
            }
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw NibError.unavailable("the catalogue cache directory")
            }
            try CatalogCacheRepair.invalidate(root: library.rootURL, support: support)
            library.refresh()
            out.catalogRebuilt = true
            let root = library.rootURL
            let report = try await ctx.execute(CommandIDs.syncNow)
            guard root == library.rootURL else {
                throw NibError(.conflict, String(localized: "The library changed during repair. Repair the current library again."))
            }
            out.merged = report["merged"]?.intValue ?? 0
            out.skippedReadOnly = ctx.workspace.loadedDocuments.filter { ctx.isReadOnly($0) }
                .map { NodeRef.document($0).description }.sorted()
            out.errors = (report["errors"]?.arrayValue ?? []).map {
                Failure(ref: $0["doc"]?.stringValue ?? "library:",
                        message: $0["message"]?.stringValue ?? String(localized: "Sync could not finish. Try Sync Now again."))
            }
            if p.rebuildIndex == true {
                _ = try await ctx.execute(CommandIDs.indexRebuild)
                out.indexRebuilt = true
            }
            guard requestedRoot == library.rootURL else {
                throw NibError(.conflict, String(localized: "The library changed during repair. Repair the current library again."))
            }
            ctx.events.emit(SyncStatusPayload(state: out.errors.isEmpty ? "ok" : "warning", source: "syncui",
                                             reason: "repair", message: out.errors.isEmpty
                                                ? String(localized: "Library repair finished.")
                                                : String(localized: "Some documents still need attention.")))
            return out
        } catch {
            let failure = NibError.wrap(error)
            if requestedRoot == library.rootURL {
                ctx.events.emit(SyncStatusPayload(state: "error", source: "syncui", reason: "repair",
                                                 message: failure.message))
            }
            throw failure
        }
    }
}
