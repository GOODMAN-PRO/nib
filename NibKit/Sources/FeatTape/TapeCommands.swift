import Foundation
import os
import NibContracts

// The tape commands (ARCHITECTURE §6.5 `tape.*`) and `TapeStore`, which owns the library side of tape: custom
// pattern images and the per-device pattern history in `.nib-library/tape/`.

extension Notification.Name {
    /// Posted by `TapeStore` when custom patterns or the pattern history changed.
    static let tapeStoreDidChange = Notification.Name("NibTapeStoreDidChange")
}

/// What the next strip is drawn with: the selected tape preset slot plus the tape settings.
struct TapeCurrent {
    var color: RGBA
    var width: Double
    /// The selected slot's pattern (a `TapePatternRef`); nil = plain colour.
    var patternRef: AssetRef?
    var followsDirection: Bool
    var straight: Bool

    var pattern: String? { patternRef.map { TapePatternRef.id(from: $0) } }
}

// MARK: - Store

/// Custom patterns (`<library>/.nib-library/tape/<id>.png`, one `TapePatternDescriptor` each) and the pattern
/// history (`history.<dev>.json`, merged). One per app, shared through `NibServices` under `serviceKey`.
@MainActor
final class TapeStore {
    static let serviceKey = "tape.store"
    private static let cacheLimit = 128

    private weak var app: NibApp?
    private let log = Logger(subsystem: "app.nib", category: "tape")
    private(set) var customIDs: [String] = []
    private(set) var history: [TapeHistoryEntry] = []
    private var loaded = false
    private var loadedFolder: URL?
    private var reloadQueued = false
    private var tiles: [String: Data] = [:]
    private var documentAssets: [String: AssetRef] = [:]
    /// Keeps the `library.changed` subscription alive (set in `start`).
    var librarySubscription: EventSubscription?

    init(app: NibApp) { self.app = app }

    static func of(_ services: NibServices) throws -> TapeStore {
        guard let store = services.get(serviceKey, as: TapeStore.self) else { throw NibError.unavailable("the tape store") }
        return store
    }

    /// The library's tape folder; nil while no library is configured.
    var folder: URL? { app?.services.library?.metadataURL.appendingPathComponent("tape", isDirectory: true) }

    /// This device's file suffix: the HLC device id, which is `DeviceIdentity.hex` in the app.
    var device: String { String(format: "%08x", app?.clock.device ?? DeviceIdentity.current) }

    // MARK: Loading

    /// Loads on first use and whenever the library folder changed.
    func ensureLoaded() {
        if !loaded || loadedFolder != folder { reload() }
    }

    /// Coalesces bursts of `library.changed` into one reload.
    func scheduleReload() {
        guard !reloadQueued else { return }
        reloadQueued = true
        Task { @MainActor [weak self] in
            self?.reloadQueued = false
            self?.reload()
        }
    }

    /// Rescans custom patterns (registering and unregistering their descriptors) and re-merges the history files.
    /// ponytail: synchronous reads of a handful of small files on main; move to a queue if libraries grow huge folders.
    func reload() {
        loaded = true
        let folder = self.folder
        loadedFolder = folder
        let ids = folder.map { TapeStore.customPatternIDs(in: $0) } ?? []
        if ids != customIDs, let app {
            for gone in customIDs where !ids.contains(gone) { app.content.tapePatterns.unregister(id: gone) }
            if let folder {
                for (i, id) in ids.enumerated() { app.content.tapePatterns.register(customDescriptor(id, order: 1000 + i, folder: folder)) }
            }
        }
        customIDs = ids
        history = folder.map { TapeHistory.load(folder: $0) } ?? []
        tiles.removeAll()
        NotificationCenter.default.post(name: .tapeStoreDidChange, object: self)
    }

    /// Custom pattern ids (file stems that are valid ids), oldest first.
    nonisolated static func customPatternIDs(in folder: URL) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        let found = urls.compactMap { url -> (id: String, date: Date)? in
            let id = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension.lowercased() == "png", NibID.isValid(id) else { return nil }
            let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return (id, date)
        }
        return found.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.map { $0.id }
    }

    /// Built off the main actor's isolation: render threads and the presets bar may call `load`.
    nonisolated private func customDescriptor(_ id: String, order: Int, folder: URL) -> TapePatternDescriptor {
        let url = folder.appendingPathComponent(id + ".png")
        return TapePatternDescriptor(id: id, title: String(localized: "Custom pattern"), order: order,
                                     owner: TapeCommands.owner) { try Data(contentsOf: url) }
    }

    // MARK: Patterns

    func source(of id: String) -> String {
        if TapePattern(id: id) != nil { return "builtin" }
        return customIDs.contains(id) ? "custom" : "pack"
    }

    /// Every pattern for pickers: built-ins, then content packs, then your own images.
    func descriptors() -> [TapePatternDescriptor] {
        ensureLoaded()
        func rank(_ id: String) -> Int {
            switch source(of: id) {
            case "builtin": return 0
            case "pack": return 1
            default: return 2
            }
        }
        let all = app?.content.tapePatterns.all ?? []
        return all.enumerated()
            .sorted { (rank($0.element.id), $0.offset) < (rank($1.element.id), $1.offset) }
            .map { $0.element }
    }

    /// PNG tile of a pattern in `color`: built-ins are recoloured, custom and content-pack tiles are used as they are.
    func tile(pattern id: String, color: RGBA) -> Data? {
        let key = id + "|" + color.hex
        if let data = tiles[key] { return data }
        let data: Data?
        if let builtin = TapePattern(id: id) {
            data = TapeTile.png(builtin, color: color)
        } else {
            ensureLoaded()
            data = try? app?.content.tapePatterns.get(id)?.load()
        }
        if let data {
            if tiles.count >= TapeStore.cacheLimit { tiles.removeAll() }
            tiles[key] = data
        }
        return data
    }

    /// The asset a strip in `doc` points at for the swatch pattern `ref`: the tile copied into the document
    /// (content-addressed, so every strip with the same look shares one file). nil = plain colour.
    func documentAsset(for ref: AssetRef, color: RGBA, doc: DocumentID) -> AssetRef? {
        guard let assets = app?.services.assets else { return nil }
        let key = doc.raw + "|" + ref.name + "|" + color.hex
        if let known = documentAssets[key] { return known }
        var result: AssetRef?
        if let data = tile(pattern: TapePatternRef.id(from: ref), color: color) {
            result = try? assets.put(data, ext: "png", doc: doc)
        } else if (try? assets.data(ref, doc: doc)) != nil {
            result = ref            // the swatch already points at an asset of this document (plugin or AI)
        }
        if let result {
            if documentAssets.count >= TapeStore.cacheLimit { documentAssets.removeAll() }
            documentAssets[key] = result
        }
        return result
    }

    func current() -> TapeCurrent {
        guard let app else {
            return TapeCurrent(color: TapeTile.defaultColor, width: InkStyle.defaultTape.width, patternRef: nil,
                               followsDirection: false, straight: false)
        }
        let presets = app.settings.get(NibSettings.presets("tape"))
        return TapeCurrent(color: presets.color, width: max(1, presets.width), patternRef: presets.tapePattern,
                           followsDirection: app.settings.get(TapeSettings.followsDirection),
                           straight: app.settings.get(TapeSettings.straight))
    }

    /// Stores an image as a custom pattern tile and registers it. Returns the pattern id.
    func importPattern(data: Data, id requested: String?) throws -> String {
        guard let folder else { throw NibError.unavailable("the library folder") }
        ensureLoaded()
        if let requested, !NibID.isValid(requested) {
            throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id")
        }
        let id = requested ?? NibID.make().raw
        guard !customIDs.contains(id), app?.content.tapePatterns.get(id) == nil else {
            throw NibError(.conflict, "a tape pattern with id '\(id)' already exists", path: "$.id",
                           hint: "omit id, or call tape.patterns to see the ids in use")
        }
        guard let tile = TapeTile.customTile(from: data) else {
            throw NibError(.invalidParams, "the file is not an image Nib can read", hint: "use a PNG, JPEG, HEIC or GIF")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try tile.write(to: folder.appendingPathComponent(id + ".png"), options: .atomic)
        customIDs.append(id)
        app?.content.tapePatterns.register(customDescriptor(id, order: 1000 + customIDs.count, folder: folder))
        NotificationCenter.default.post(name: .tapeStoreDidChange, object: self)
        return id
    }

    func deletePattern(_ id: String) throws {
        ensureLoaded()
        if TapePattern(id: id) != nil {
            throw NibError.invalid("built-in tape patterns cannot be deleted", path: "$.id")
        }
        guard let folder, customIDs.contains(id) else {
            if app?.content.tapePatterns.get(id) != nil {
                throw NibError(.invalidParams, "'\(id)' comes from a content pack", path: "$.id",
                               hint: "remove the content pack's plugin to remove its patterns")
            }
            throw NibError(.notFound, "tape pattern '\(id)' not found", hint: "call tape.patterns for the custom pattern ids")
        }
        let file = folder.appendingPathComponent(id + ".png")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        customIDs.removeAll { $0 == id }
        app?.content.tapePatterns.unregister(id: id)
        tiles = tiles.filter { !$0.key.hasPrefix(id + "|") }
        if let clock = app?.clock, history.contains(where: { $0.pattern == id && !$0.deleted }) {
            history = try TapeHistory.save(TapeHistory.cleared(history, pattern: id, clock: clock), folder: folder,
                                           device: device, now: Date().timeIntervalSince1970)
        }
        NotificationCenter.default.post(name: .tapeStoreDidChange, object: self)
    }

    // MARK: History

    /// Called by the tape tool after a strip is committed. Writes only when the most recent entry changes.
    func recordUse(pattern: String?, color: RGBA) {
        guard let folder, let clock = app?.clock else { return }
        ensureLoaded()
        guard TapeHistory.live(history).first?.id != TapeHistory.key(pattern: pattern, color: color) else { return }
        let now = Date().timeIntervalSince1970
        do {
            history = try TapeHistory.save(TapeHistory.recording(history, pattern: pattern, color: color, at: now, clock: clock),
                                           folder: folder, device: device, now: now)
            NotificationCenter.default.post(name: .tapeStoreDidChange, object: self)
        } catch {
            log.error("tape history not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tombstones every recent entry on every device. Returns how many were cleared.
    func clearHistory() throws -> Int {
        guard let folder, let clock = app?.clock else { throw NibError.unavailable("the library folder") }
        ensureLoaded()
        let count = TapeHistory.live(history).count
        guard count > 0 else { return 0 }
        history = try TapeHistory.save(TapeHistory.cleared(history, clock: clock), folder: folder, device: device,
                                       now: Date().timeIntervalSince1970)
        NotificationCenter.default.post(name: .tapeStoreDidChange, object: self)
        return count
    }
}

// MARK: - Commands

enum TapeCommands {
    /// The feature id, readable from any isolation (drawers and pattern loaders are built off the main actor).
    static let owner = "tape"

    @MainActor
    static func register(_ app: NibApp) {
        app.commands.register(TapeTapAt.self)
        app.commands.register(TapeSetRevealed.self)
        app.commands.register(TapeRemoveAll.self)
        app.commands.register(TapeImportPattern.self)
        app.commands.register(TapePatternsList.self)
        app.commands.register(TapeDeletePattern.self)
        app.commands.register(TapeClearHistory.self)
    }

    static let fixturePage = "page:FIXTUREDOC01/FIXTUREPG001"

    /// A live page from a "page:D/P" ref.
    @MainActor
    static func page(_ ref: String, _ ctx: CommandContext, path: String) throws -> (doc: DocumentID, page: PageID) {
        guard case let .page(doc, page)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: path,
                           hint: "call query.context for the current page")
        }
        guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
            throw NibError.notFound("page \(page) in document \(doc)")
        }
        return (doc, page)
    }

    @MainActor
    static func tapes(_ doc: DocumentID, _ page: PageID, _ ctx: CommandContext) throws -> [Item] {
        try ctx.workspace.items(doc, page: page).filter(TapeGeometry.isTape)
    }
}

/// Tap handler (order 100, also in read-only mode): hide or reveal the tape under a finger tap.
struct TapeTapAt: NibCommand {
    struct Params: Codable {
        var page: String
        var point: [Double]
        /// Topmost item under the point (from the gesture router); the command hit-tests tape itself.
        var ref: String?
        var gesture: String?
    }

    struct Output: Codable {
        var handled: Bool
        var ref: String? = nil
        var revealed: Bool? = nil
    }

    static let example: JSONValue = ["page": .string(TapeCommands.fixturePage), "point": [170, 600]]
    static let descriptor = CommandDescriptor(
        id: "tape.tapAt", title: String(localized: "Hide or Reveal Tape"),
        summary: "Tap handler: toggle (hide/reveal) the topmost tape strip under a point on a page; returns {handled, ref, revealed}. Not undoable.",
        params: .obj(["page": .ref, "point": .point, "ref": .ref,
                      "gesture": .str("tap gesture", choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["page", "point"]),
        examples: [example], effect: .edit, undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try TapeCommands.page(p.page, ctx, path: "$.page")
        guard p.point.count == 2 else { throw NibError.invalid("point must be [x, y]", path: "$.point") }
        // Layers hidden in the tapping window stay out of reach.
        var hidden: Set<Int> = []
        if let session = ctx.activeSession, session.document == doc { hidden = session.hiddenLayers }
        let items = try ctx.workspace.items(doc, page: page)
        guard var tape = TapeGeometry.topmostTape(in: items, at: Point(p.point[0], p.point[1]), hiddenLayers: hidden) else {
            return Output(handled: false)
        }
        tape.stroke?.tapeRevealed.toggle()
        let revealed = tape.stroke?.tapeRevealed ?? false
        let item = tape
        try ctx.mutate(undoable: false) { tx in try tx.put(item, doc: doc, page: page) }
        return Output(handled: true, ref: NodeRef.item(doc, page, item.id).description, revealed: revealed)
    }
}

struct TapeSetRevealed: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var revealed: Bool
    }

    struct Output: Codable {
        var changed: Int
    }

    static let example: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETAP01"], "revealed": true]
    static let descriptor = CommandDescriptor(
        id: "tape.setRevealed", title: String(localized: "Hide or Reveal Tape"),
        summary: "Reveal (true) or hide (false) tape strips; refs are tape item refs, or page refs for every tape on that page. Returns {changed}. Not undoable.",
        params: .obj(["refs": .arr(.ref), "revealed": .bool()], required: ["refs", "revealed"]),
        examples: [example], effect: .edit, undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        var targets: [(doc: DocumentID, page: PageID, item: Item)] = []
        var seen = Set<String>()
        func add(_ doc: DocumentID, _ page: PageID, _ item: Item) {
            if seen.insert(NodeRef.item(doc, page, item.id).description).inserted { targets.append((doc, page, item)) }
        }
        for (i, ref) in p.refs.enumerated() {
            let path = "$.refs[\(i)]"
            switch NodeRef(ref) {
            case let .item(doc, page, id)?:
                let item = try ctx.workspace.item(doc, page: page, id: id)
                guard TapeGeometry.isTape(item) else {
                    throw NibError(.invalidParams, "\(ref) is not tape", path: path,
                                   hint: "pass tape stroke refs, or a page ref for every tape on that page")
                }
                add(doc, page, item)
            case .page(_, _)?:
                let (doc, page) = try TapeCommands.page(ref, ctx, path: path)
                for item in try TapeCommands.tapes(doc, page, ctx) { add(doc, page, item) }
            default:
                throw NibError.invalid("expected an item or page ref", path: path)
            }
        }
        let changes = targets.filter { $0.item.stroke?.tapeRevealed != p.revealed }
        guard !changes.isEmpty else { return Output(changed: 0) }
        try ctx.mutate(undoable: false) { tx in
            for change in changes {
                var item = change.item
                item.stroke?.tapeRevealed = p.revealed
                try tx.put(item, doc: change.doc, page: change.page)
            }
        }
        return Output(changed: changes.count)
    }
}

struct TapeRemoveAll: NibCommand {
    struct Params: Codable {
        var page: String
    }

    struct Output: Codable {
        var removed: Int
    }

    static let example: JSONValue = ["page": .string(TapeCommands.fixturePage)]
    static let descriptor = CommandDescriptor(
        id: "tape.removeAll", title: String(localized: "Remove All Tape"),
        summary: "Remove every tape strip on a page (undoable). Returns {removed}.",
        params: .obj(["page": .ref], required: ["page"]),
        examples: [example], effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try TapeCommands.page(p.page, ctx, path: "$.page")
        let tapes = try TapeCommands.tapes(doc, page, ctx)
        guard !tapes.isEmpty else { return Output(removed: 0) }
        try ctx.mutate { tx in
            for tape in tapes { try tx.delete(item: tape.id, doc: doc, page: page) }
        }
        return Output(removed: tapes.count)
    }
}

struct TapeImportPattern: NibCommand {
    struct Params: Codable {
        var asset: String?
        var url: String?
        var doc: String?
        var id: String?
    }

    struct Output: Codable {
        var id: String
        var title: String
    }

    static let example: JSONValue = ["url": "tmp:washi-pattern.png"]
    static let descriptor = CommandDescriptor(
        id: "tape.importPattern", title: String(localized: "Add Tape Pattern"),
        summary: "Add a custom tape pattern image (url: https or tmp: ref from asset.upload; or asset: an asset name in doc), scaled to a ~100 px tile. Returns {id}.",
        params: .obj(["asset": .str("tmp:<name> from asset.upload, or the name of an asset in doc"),
                      "url": .str("https URL or tmp:<name> ref of a PNG, JPEG, HEIC or GIF"),
                      "doc": .ref,
                      "id": .str("your own pattern id, [A-Za-z0-9_-]{1,64}")]),
        examples: [example], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let store = try TapeStore.of(ctx.services)
        let data: Data
        if let url = p.url ?? p.asset.flatMap({ $0.hasPrefix("tmp:") ? $0 : nil }) {
            let file = try await ctx.inputFile(url)
            data = try Data(contentsOf: file)
        } else if let asset = p.asset {
            guard let doc = p.doc.map({ NodeRef.documentID(from: $0) }) ?? ctx.activeSession?.document else {
                throw NibError.invalid("name the document that holds the asset", path: "$.doc")
            }
            let assets = try ctx.services.require(ctx.services.assets, "the asset store")
            data = try assets.data(AssetRef(asset), doc: doc)
        } else {
            throw NibError(.invalidParams, "pass url or asset", path: "$.url",
                           hint: "upload the image with asset.upload and pass the returned tmp: ref as url")
        }
        let id = try store.importPattern(data: data, id: p.id)
        return Output(id: id, title: String(localized: "Custom pattern"))
    }
}

struct TapePatternsList: NibCommand {
    struct Pattern: Codable {
        var id: String
        /// "builtin" | "custom" | "pack".
        var source: String
        var title: String
        /// Built-ins are drawn in the tape colour; custom and pack tiles are used as they are.
        var recolorable: Bool
        /// Temporary PNG of the tile (in the current tape colour for built-ins), for asset.put.
        var asset: String?
    }

    struct Recent: Codable {
        var pattern: String?
        var color: String
        var usedAt: Double
    }

    struct Current: Codable {
        var pattern: String?
        var color: String
        var width: Double
        var followsDirection: Bool
        var straight: Bool
    }

    struct Output: Codable {
        var patterns: [Pattern]
        var history: [Recent]
        var current: Current
    }

    static let example: JSONValue = [:]
    static let descriptor = CommandDescriptor(
        id: "tape.patterns", title: String(localized: "Tape Patterns"),
        summary: "List tape patterns (built-in, custom, content packs) with tmp: PNG tiles for asset.put, recently used tape and the current tape style.",
        examples: [example], effect: .read, target: .app)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> Output {
        let store = try TapeStore.of(ctx.services)
        let current = store.current()
        let temporary = ctx.services.assets
        let patterns = store.descriptors().map { d -> Pattern in
            let source = store.source(of: d.id)
            let data = source == "builtin" ? store.tile(pattern: d.id, color: current.color) : (try? d.load())
            let asset = data.flatMap { try? temporary?.putTemporary($0, ext: "png") }.map { "tmp:" + $0.name }
            return Pattern(id: d.id, source: source, title: d.title, recolorable: source == "builtin", asset: asset)
        }
        let recent = TapeHistory.live(store.history).map { Recent(pattern: $0.pattern, color: $0.color.hex, usedAt: $0.usedAt) }
        return Output(patterns: patterns, history: recent,
                      current: Current(pattern: current.pattern, color: current.color.hex, width: current.width,
                                       followsDirection: current.followsDirection, straight: current.straight))
    }
}

struct TapeDeletePattern: NibCommand {
    struct Params: Codable {
        var id: String
    }

    static let example: JSONValue = ["id": "CUSTOMTAPE01"]
    static let descriptor = CommandDescriptor(
        id: "tape.deletePattern", title: String(localized: "Delete Tape Pattern"),
        summary: "Delete a custom tape pattern by id (built-in and content-pack patterns cannot be deleted).",
        params: .obj(["id": .str("custom pattern id from tape.patterns")], required: ["id"]),
        examples: [example], effect: .session, target: .app, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try TapeStore.of(ctx.services).deletePattern(p.id)
        return NoResult()
    }
}

struct TapeClearHistory: NibCommand {
    struct Output: Codable {
        var cleared: Int
    }

    static let example: JSONValue = [:]
    static let descriptor = CommandDescriptor(
        id: "tape.clearHistory", title: String(localized: "Clear Tape History"),
        summary: "Clear the recently used tape patterns on every device (synced tombstones). Returns {cleared}.",
        examples: [example], effect: .session, target: .app, destructive: true)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> Output {
        Output(cleared: try TapeStore.of(ctx.services).clearHistory())
    }
}
