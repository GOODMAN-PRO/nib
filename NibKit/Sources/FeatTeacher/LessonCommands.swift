import Foundation
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

/// Runtime storage is installed on first use, after every feature has registered its persistence and assets.
@MainActor
final class LessonRuntime {
    static let key = "teacherlessons.runtime"
    let fallbackUndo = UndoManager()
    var busy = false
    private var undoSteps: [LessonCommandUndo] = []

    static func require(_ ctx: CommandContext) throws -> LessonRuntime {
        try ctx.services.require(ctx.services.get(key, as: LessonRuntime.self), "teacher lessons")
    }

    static func privateStore(_ ctx: CommandContext) throws -> PrivateLessonPersistence {
        if let store = ctx.workspace.persistence as? PrivateLessonPersistence { return store }
        let root: URL
        if let memory = ctx.workspace.persistence as? InMemoryPersistence {
            root = memory.root.appendingPathComponent("private-lessons", isDirectory: true)
        } else {
            root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
                .appendingPathComponent("Nib/PrivateLessons", isDirectory: true)
        }
        let store = PrivateLessonPersistence(base: ctx.workspace.persistence, root: root)
        let assets = try ctx.services.require(ctx.services.assets, "asset store")
        ctx.workspace.persistence = store
        ctx.services.assets = PrivateLessonAssets(base: assets, root: root)
        return store
    }

    func recordCopies(_ ids: [DocumentID], ctx: CommandContext) {
        guard ctx.principal.isUser, !ids.isEmpty, let app = ctx.app else { return }
        let refs = JSONValue.array(ids.map { .string(NodeRef.document($0).description) })
        record(command: CommandIDs.libraryTrash, redoCommand: CommandIDs.trashRecover,
               undo: ["refs": refs], redo: ["refs": refs], title: String(localized: "Create Lesson"), ctx: ctx, app: app)
    }

    private func record(command: String, redoCommand: String, undo: JSONValue, redo: JSONValue, title: String, ctx: CommandContext, app: NibApp) {
        let manager = ctx.navigator?.rootViewController?.undoManager ?? fallbackUndo
        let step = LessonCommandUndo(app: app, session: ctx.session, manager: manager, command: command, redoCommand: redoCommand,
                                     undo: undo, redo: redo, title: title)
        // UndoManager targets are not relied on for ownership; the feature keeps the steps for its lifetime.
        undoSteps.append(step)
        if undoSteps.count > 50 {
            let removed = undoSteps.removeFirst()
            manager.removeAllActions(withTarget: removed)
        }
        step.register(undo: true)
    }
}

@MainActor
final class LessonCommandUndo {
    weak var app: NibApp?
    weak var manager: UndoManager?
    weak var session: EditorSession?
    let command: String
    let redoCommand: String
    let undoParams: JSONValue
    let redoParams: JSONValue
    let title: String
    private var pending: [Bool] = []
    private var replaying = false
    init(app: NibApp, session: EditorSession?, manager: UndoManager, command: String, redoCommand: String, undo: JSONValue, redo: JSONValue, title: String) {
        self.app = app; self.session = session; self.manager = manager; self.command = command
        self.redoCommand = redoCommand
        self.undoParams = undo; self.redoParams = redo; self.title = title
    }
    func register(undo: Bool) {
        guard let manager else { return }
        // Retrying after an awaited failure is outside UndoManager's synchronous undo group.
        let needsGroup = manager.groupingLevel == 0 && !manager.isUndoing && !manager.isRedoing
        if needsGroup { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { step in
            step.register(undo: !undo)
            step.pending.append(undo)
            guard !step.replaying else { return }
            step.replaying = true
            Task { @MainActor in await step.replayPending() }
        }
        manager.setActionName(title)
        if needsGroup { manager.endUndoGrouping() }
    }

    private func replayPending() async {
        defer { replaying = false }
        guard let app else { pending.removeAll(); return }
        while !pending.isEmpty {
            let undo = pending.removeFirst()
            do {
                _ = try await app.bus.execute(undo ? command : redoCommand,
                                              undo ? undoParams : redoParams, session: session)
            } catch {
                // A failed replay offers retry, and queued inverses cannot act on unchanged state.
                pending.removeAll()
                manager?.removeAllActions(withTarget: self)
                register(undo: undo)
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": undo ? command : redoCommand, "error": NibError.wrap(error)])
                return
            }
        }
    }

}

struct LessonCreate: NibCommand {
    struct Params: Codable {
        var doc: String?
        var students: JSONValue?
        var folder: String?
        var ids: [String]?
    }
    struct Output: Codable { var refs: [String]; var source: String? }

    static let descriptor = CommandDescriptor(
        id: "lesson.create", title: String(localized: "Create Lesson"),
        summary: "Publish one independent copy per student in a shared class folder; students accepts roster objects or names; doc=sample creates a sample; ids fixes copy ids.",
        params: .obj(["doc": .str("source doc ref, or sample for the built-in lesson"),
                      "students": .arr(.anything("name string or {id,name,email?}; omit to use the imported roster")),
                      "folder": .ref, "ids": .arr(.str("caller-chosen document ids, one per copy")) ], required: ["doc", "folder"]),
        examples: [["doc": "doc:FIXTUREDOC01", "students": ["Sam"], "folder": "folder:FIXTUREFLD01"],
                   ["doc": "sample", "students": [], "folder": "folder:FIXTUREFLD01", "ids": ["SAMPLELESSON01"]]],
        effect: .library, target: .library, extraScopes: [.documentRead])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "library")
        let runtime = try LessonRuntime.require(ctx)
        guard !runtime.busy else { throw NibError(.conflict, "Another lesson operation is still saving.", hint: "try again when it finishes") }
        runtime.busy = true
        defer { runtime.busy = false }
        guard let folderString = p.folder, let sourceString = p.doc else {
            throw LessonManager.invalid("Choose a source document and a class folder.", path: "$.doc")
        }
        let folder = try LessonManager.folder(folderString, library: library)
        let isSample = sourceString == "sample"
        let source: DocumentID
        var snapshot: LessonSnapshot
        if isSample {
            source = NibID.make()
            snapshot = try LessonManager.sample(id: source)
        } else {
            source = try LessonManager.document(sourceString)
            guard !LessonManager.isPrivate(source) else {
                throw NibError(.permissionDenied, "Present notes are private. Create the lesson from its Prep document.")
            }
            try LessonManager.writable(source, ctx)
            snapshot = try LessonManager.capture(source, workspace: ctx.workspace)
        }
        let students = try studentList(p.students, folder: folder, ctx: ctx)
        guard isSample || !students.isEmpty else { throw LessonManager.invalid("Import a roster or choose at least one student.", path: "$.students") }
        let count = max(students.count, 1)
        guard p.ids == nil || p.ids?.count == count else { throw LessonManager.invalid("Supply one document id per copy.", path: "$.ids") }
        let ids = p.ids?.map { NibID($0) } ?? (0..<count).map { _ in NibID.make() }
        guard Set(ids).count == ids.count, ids.allSatisfy({ NibID.isValid($0.raw) && !LessonManager.isPrivate($0) && library.node($0) == nil }) else {
            throw LessonManager.invalid("Copy ids must be valid, unique and unused.", path: "$.ids")
        }
        let title = isSample ? String(localized: "Sample Lesson") : (library.node(source)?.title ?? String(localized: "Lesson"))
        snapshot.content.meta.sourceBookmark = nil
        snapshot.content.meta.locked = false
        snapshot.content.meta.favorite = false
        snapshot.content.meta.ext?[LessonManager.assignmentKey] = nil
        snapshot.content.meta.ext?[LessonManager.rosterKey] = nil
        // Dry runs are a true preview: no package creation, file copy, state or undo changes.
        if ctx.dryRun { return Output(refs: ids.map { NodeRef.document($0).description }, source: isSample ? nil : NodeRef.document(source).description) }
        let inputs = try copyInputs(snapshot, source: isSample ? nil : source, ctx: ctx)
        let journal = try pendingURL(ctx)
        try JSONEncoder().encode(ids).write(to: journal, options: .atomic)
        var created: [DocumentID] = []
        do {
            var copies: [(DocumentID, LessonSnapshot)] = []
            for (index, id) in ids.enumerated() {
                let student = students.indices.contains(index) ? students[index] : nil
                var copy = snapshot
                copy.content.meta.id = id
                copy.content.meta.rev = .zero
                copy.content.meta.createdAt = Date().timeIntervalSince1970
                copy.content.meta.ext = copy.content.meta.ext ?? [:]
                copy.content.meta.ext?[LessonManager.managedKey] = true
                if let student {
                    copy.content.meta.ext?[LessonManager.assignmentKey] = try JSONValue.from(
                        LessonAssignment(source: source, folder: folder, student: student, state: .published, attempt: 1, returns: []))
                }
                if let layer = LessonManager.feedbackLayer(in: snapshot) {
                    copy.content.meta.ext?[LessonManager.feedbackLayerKey] = .number(Double(layer))
                    if copy.content.meta.layers[layer].name == "Layer \(layer + 1)" {
                        copy.content.meta.layers[layer].name = String(localized: "Feedback")
                    }
                }
                let blank = DocumentContent(meta: DocumentMeta(id: id, kind: copy.content.meta.kind))
                let actual = try library.createDocument(blank, title: student.map { title + " · " + $0.name } ?? title, in: folder)
                created.append(actual)
                guard actual == id else { throw NibError(.unsupported, "The library did not honour the supplied document id.") }
                copies.append((id, copy))
            }
            let mapped = try await transfer(snapshot, to: ids, inputs: inputs, ctx: ctx)
            for index in copies.indices {
                let meta = copies[index].1.content.meta
                copies[index].1 = mapped
                copies[index].1.content.meta = meta
            }
            try ctx.mutate(undoable: false) { tx in
                for (id, copy) in copies {
                    try tx.putMeta(copy.content.meta)
                    try tx.put(copy.content.pages, doc: id)
                    try tx.put(copy.content.outline, doc: id)
                    try tx.put(copy.content.blocks, doc: id)
                    try tx.put(copy.content.cards, doc: id)
                    try tx.put(copy.content.audio, doc: id)
                    for (page, items) in copy.items { try tx.put(items, doc: id, page: page) }
                }
            }
            for id in created { ctx.workspace.persistence.flush(id) }
            try FileManager.default.removeItem(at: journal)
            runtime.recordCopies(created, ctx: ctx)
            ctx.events.emit(NibEventType.libraryChanged)
            return Output(refs: created.map { NodeRef.document($0).description }, source: isSample ? nil : NodeRef.document(source).description)
        } catch {
            for id in created { ctx.workspace.close(id); try? library.deletePermanently(id) }
            if created.allSatisfy({ library.node($0) == nil }) { try? FileManager.default.removeItem(at: journal) }
            throw NibError.wrap(error)
        }
    }

    static func studentList(_ value: JSONValue?, folder: FolderID, ctx: CommandContext) throws -> [LessonStudent] {
        guard let value, value != .null else {
            let id = LessonManager.rosterID(folder)
            guard let node = ctx.services.library?.node(id), node.trashedAt == nil,
                  let json = try ctx.workspace.content(id).meta.ext?[LessonManager.rosterKey] else { return [] }
            return try json.decode(LessonRoster.self).students.map { LessonStudent(id: $0.id, name: $0.name, email: nil) }
        }
        guard let values = value.arrayValue, values.count <= RosterImport.maxStudents else {
            throw LessonManager.invalid("Choose at most 1,000 students.", path: "$.students")
        }
        var out: [LessonStudent] = [], ids = Set<String>()
        for (index, value) in values.enumerated() {
            let name = (value.stringValue ?? value["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let email = value["email"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let id = value["id"]?.stringValue ?? RosterImport.stableID(email?.isEmpty == false ? email! : name)
            guard !name.isEmpty, name.count <= 200, NibID.isValid(id), ids.insert(id).inserted else {
                throw LessonManager.invalid("Each student needs a name and a distinct valid id.", path: "$.students[\(index)]")
            }
            out.append(LessonStudent(id: id, name: name, email: email))
        }
        return out
    }

    /// Written before package creation. A process termination cannot bypass next-launch rollback.
    static func pendingURL(_ ctx: CommandContext) throws -> URL {
        let library = try ctx.services.require(ctx.services.library, "library")
        let directory = library.metadataURL.appendingPathComponent("teacherlessons-pending", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(ctx.workspace.clock.deviceHex + ".json")
    }

    struct CopyInputs { var refs: Set<AssetRef>; var source: DocumentID?; var files: [String: URL] }
    static func copyInputs(_ snapshot: LessonSnapshot, source: DocumentID?, ctx: CommandContext) throws -> CopyInputs {
        let refs = LessonManager.assets(in: try JSONValue.from(snapshot))
        var files: [String: URL] = [:]
        if let source {
            for clip in snapshot.content.liveAudio {
                files[clip.file] = try ctx.workspace.persistence.fileURL(source, relativePath: clip.file)
                if let transcript = clip.transcriptFile {
                    let base = try ctx.workspace.persistence.fileURL(source, relativePath: transcript)
                    if FileManager.default.fileExists(atPath: base.path) { files[transcript] = base }
                    for file in try FileManager.default.contentsOfDirectory(at: base.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                    where file.lastPathComponent.hasPrefix(base.lastPathComponent + ".") && file.pathExtension == "json" {
                        let relative = (transcript as NSString).deletingLastPathComponent
                        files[relative.isEmpty ? file.lastPathComponent : relative + "/" + file.lastPathComponent] = file
                    }
                }
            }
        }
        return CopyInputs(refs: refs, source: source, files: files)
    }

    /// One asset is loaded at a time and released after every destination receives it. Names are mapped once.
    static func transfer(_ snapshot: LessonSnapshot, to docs: [DocumentID], inputs: CopyInputs, ctx: CommandContext) async throws -> LessonSnapshot {
        let assets = try ctx.services.require(ctx.services.assets, "asset store")
        var paths: [DocumentID: [String: URL]] = [:]
        for doc in docs {
            for path in inputs.files.keys { paths[doc, default: [:]][path] = try ctx.workspace.persistence.fileURL(doc, relativePath: path) }
        }
        return try await Task.detached {
            var map: [String: AssetRef] = [:]
            for ref in inputs.refs {
                guard let source = inputs.source else { throw NibError.unavailable("lesson assets") }
                try autoreleasepool {
                    let bytes = try assets.data(ref, doc: source)
                    let ext = (ref.name as NSString).pathExtension
                    for doc in docs {
                        let copied = try assets.put(bytes, ext: ext.isEmpty ? "bin" : ext, doc: doc)
                        if let previous = map[ref.name], previous != copied { throw NibError(.unsupported, "Asset names must be content-addressed.") }
                        map[ref.name] = copied
                    }
                }
            }
            for doc in docs {
                for (path, source) in inputs.files {
                    guard let destination = paths[doc]?[path], source != destination else { continue }
                    // Replace atomically, leaving the previous Present recording intact on copy failure.
                    let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try FileManager.default.copyItem(at: source, to: temporary)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                    } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                }
            }
            guard map.contains(where: { $0.key != $0.value.name }) else { return snapshot }
            return try LessonManager.remappedAssets(JSONValue.from(snapshot), map).decode(LessonSnapshot.self)
        }.value
    }

}

struct LessonSetState: NibCommand {
    struct Params: Codable { var doc: String?; var state: String }
    struct Output: Codable { var ref: String; var state: String; var snapshot: AssetRef? }
    static let descriptor = CommandDescriptor(
        id: "lesson.setState", title: String(localized: "Change Assignment State"),
        summary: "Change assignment state; return saves an immutable version, openReturn views it read-only. Prep, private Present and Feedback select notebook teaching modes.",
        params: .obj(["doc": .ref, "state": .str(choices: ["published", "submitted", "returned", "resubmit", "prep", "present", "feedback", "openReturn"])], required: ["doc", "state"]),
        examples: [["doc": "doc:FIXTUREDOC01", "state": "published"]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let runtime = try LessonRuntime.require(ctx)
        guard !runtime.busy else { throw NibError(.conflict, "Another lesson operation is still saving.", hint: "try again when it finishes") }
        runtime.busy = true
        defer { runtime.busy = false }
        var doc = try ctx.documentOrSession(p.doc)
        if let raw = try ctx.workspace.content(doc).meta.ext?[LessonManager.privateSourceKey]?.stringValue {
            let source = try LessonManager.document(raw)
            if p.state != "present" { doc = source }
        }
        if p.state == "openReturn" { return try await openReturn(doc: doc, ctx: ctx) }
        try LessonManager.writable(doc, ctx)
        if ["prep", "present", "feedback"].contains(p.state) { return try await mode(p.state, doc: doc, ctx: ctx) }
        guard !LessonManager.isPrivate(doc), let state = LessonState(rawValue: p.state) else {
            throw LessonManager.invalid("Choose a valid assignment state.", path: "$.state")
        }
        var meta = try ctx.workspace.content(doc).meta
        guard meta.ext?[LessonManager.rosterKey] == nil else { throw NibError.invalid("The class roster is not an assignment.", path: "$.doc") }
        let existing = try LessonManager.assignment(meta)
        if let existing, !existing.state.accepts(state) {
            throw NibError(.conflict, "This assignment cannot move from \(existing.state.rawValue) to \(state.rawValue).", path: "$.state",
                           hint: "use published → submitted → returned → resubmit → submitted")
        }
        guard existing != nil || state == .published else {
            throw NibError(.conflict, "Publish the assignment before changing its state.", path: "$.state", hint: "call lesson.setState with state published")
        }
        if existing?.state == state { return Output(ref: NodeRef.document(doc).description, state: state.rawValue, snapshot: nil) }
        var record = existing ?? LessonAssignment(source: doc, folder: ctx.services.library?.node(doc)?.parent,
                                                  student: nil, state: .published, attempt: 1, returns: [])
        var snapshotRef: AssetRef?
        if state == .returned {
            var snapshot = try LessonManager.capture(doc, workspace: ctx.workspace)
            let assets = try ctx.services.require(ctx.services.assets, "asset store")
            if !ctx.dryRun {
                let inputs = try LessonCreate.copyInputs(snapshot, source: doc, ctx: ctx)
                let prefix = "returns/" + UUID().uuidString + "/"
                var destinations: [String: URL] = [:]
                for path in inputs.files.keys { destinations[path] = try ctx.workspace.persistence.fileURL(doc, relativePath: prefix + path) }
                try await Task.detached {
                    for (path, source) in inputs.files {
                        if let destination = destinations[path] { try FileManager.default.copyItem(at: source, to: destination) }
                    }
                }.value
                for index in snapshot.content.audio.indices {
                    snapshot.content.audio[index].file = prefix + snapshot.content.audio[index].file
                    if let transcript = snapshot.content.audio[index].transcriptFile { snapshot.content.audio[index].transcriptFile = prefix + transcript }
                }
            }
            let captured = snapshot
            let bytes = try await Task.detached { try JSONEncoder().encode(captured) }.value
            if !ctx.dryRun {
                let destination = doc
                let ref = try await Task.detached { try assets.put(bytes, ext: "json", doc: destination) }.value
                record.returns.append(LessonReturn(asset: ref, at: Date().timeIntervalSince1970, attempt: record.attempt))
                snapshotRef = ref
            }
        }
        if state == .resubmit { record.attempt += 1 }
        record.state = state
        meta = try ctx.workspace.content(doc).meta
        guard try LessonManager.assignment(meta) == existing else {
            throw NibError(.conflict, "The assignment changed while its snapshot was saving. Try again.")
        }
        try LessonManager.writable(doc, ctx)
        meta.ext = meta.ext ?? [:]
        meta.ext?[LessonManager.assignmentKey] = try JSONValue.from(record)
        try ctx.mutate { tx in try tx.putMeta(meta) }
        return Output(ref: NodeRef.document(doc).description, state: state.rawValue, snapshot: snapshotRef)
    }

    private static func openReturn(doc: DocumentID, ctx: CommandContext) async throws -> Output {
        guard ctx.services.lock?.isLocked(doc) != true else { throw NibError(.locked, "Unlock the assignment before opening its returned version.") }
        guard let record = try LessonManager.assignment(ctx.workspace.content(doc).meta), let saved = record.returns.last else {
            throw NibError(.notFound, "This assignment has no returned version.")
        }
        let target = NibID(LessonManager.privatePrefix + "RETURN_" + LessonManager.digest(doc.raw + saved.asset.name))
        if !ctx.dryRun {
            let assets = try ctx.services.require(ctx.services.assets, "asset store")
            var snapshot = try await Task.detached { try JSONDecoder().decode(LessonSnapshot.self, from: assets.data(saved.asset, doc: doc)) }.value
            let store = try LessonRuntime.privateStore(ctx)
            let inputs = try LessonCreate.copyInputs(snapshot, source: doc, ctx: ctx)
            snapshot = try await LessonCreate.transfer(snapshot, to: [target], inputs: inputs, ctx: ctx)
            snapshot.content.meta.id = target
            snapshot.content.meta.sourceBookmark = nil
            snapshot.content.meta.ext = snapshot.content.meta.ext ?? [:]
            snapshot.content.meta.ext?[LessonManager.returnReadOnlyKey] = true
            ctx.workspace.close(target)
            try store.seed(snapshot)
            ctx.services.packages.set(store.package(target), for: target)
            if ctx.navigator != nil { _ = try await ctx.execute(CommandIDs.docOpen, ["doc": .string(NodeRef.document(target).description)]) }
            ctx.activeSession?.document = target
            ctx.activeSession?.page = snapshot.content.livePages.first?.id
            ctx.activeSession?.readOnly = true
        }
        return Output(ref: NodeRef.document(target).description, state: "openReturn", snapshot: saved.asset)
    }

    private static func mode(_ mode: String, doc: DocumentID, ctx: CommandContext) async throws -> Output {
        let meta = try ctx.workspace.content(doc).meta
        guard meta.kind == .notebook || meta.kind == .whiteboard else {
            throw NibError(.unsupported, "Teaching modes require a notebook or whiteboard.")
        }
        if mode == "present", let app = ctx.app {
            let menu = MenuContext(app: app, session: ctx.activeSession, doc: doc)
            if app.ui.menus.all.contains(where: { $0.command == CommandIDs.collabFollowMe && $0.isChecked?(menu) == true }) {
                throw NibError(.conflict, "Stop Follow Me before entering private Present mode.", hint: "call collab.followMe {on: false}")
            }
        }
        let feedback = meta.ext?[LessonManager.feedbackLayerKey]?.intValue
        if mode == "feedback", feedback == nil {
            throw NibError(.unsupported, "This copy has no empty feedback layer. Publish a notebook with an unused layer.")
        }
        let target: DocumentID
        if mode == "present", !LessonManager.isPrivate(doc) {
            target = LessonManager.privateID(doc, device: ctx.workspace.clock.deviceHex)
            guard ctx.services.library?.node(target) == nil else { throw NibError(.conflict, "The private presentation id is already in use.") }
            if ctx.dryRun { return Output(ref: NodeRef.document(target).description, state: mode, snapshot: nil) }
            let store = try LessonRuntime.privateStore(ctx)
            let old: LessonSnapshot?
            if (try? store.loadHead(target)) != nil {
                old = try LessonManager.capture(target, workspace: ctx.workspace)
            } else { old = nil }
            var value = try LessonManager.capture(doc, workspace: ctx.workspace)
            guard !value.items.values.joined().contains(where: { $0.layer == LessonManager.presentLayer }) else {
                throw NibError(.unsupported, "The source uses the private Present layer. Move its contents to another layer first.")
            }
            value.content.meta.id = target
            value.content.meta.locked = false
            value.content.meta.sourceBookmark = nil
            value.content.meta.ext = value.content.meta.ext ?? [:]
            value.content.meta.ext?[LessonManager.privateSourceKey] = .string(doc.raw)
            value.content.meta.layers[LessonManager.presentLayer].name = String(localized: "Present, private")
            let inputs = try LessonCreate.copyInputs(value, source: doc, ctx: ctx)
            try FileManager.default.createDirectory(at: store.package(target), withIntermediateDirectories: true)
            value = try await LessonCreate.transfer(value, to: [target], inputs: inputs, ctx: ctx)
            if let old {
                let sourceItems = Set(value.items.values.joined().map(\.id))
                let sourcePages = Set(value.content.livePages.map(\.id))
                for page in old.content.pages {
                    if !sourcePages.contains(page.id) {
                        value.content.pages.removeAll { $0.id == page.id }
                        value.content.pages.append(page)
                    }
                    value.items[page.id, default: []] += (old.items[page.id] ?? []).filter { !sourceItems.contains($0.id) }
                }
                // Legacy private copies could contain blocks/cards; never drop their independent records.
                let blocks = Set(value.content.blocks.map(\.id)), cards = Set(value.content.cards.map(\.id))
                value.content.blocks += old.content.blocks.filter { !blocks.contains($0.id) }
                value.content.cards += old.content.cards.filter { !cards.contains($0.id) }
                let audio = Set(value.content.audio.map(\.id)), outline = Set(value.content.outline.map(\.id))
                value.content.audio += old.content.audio.filter { !audio.contains($0.id) }
                value.content.outline += old.content.outline.filter { !outline.contains($0.id) }
            }
            ctx.workspace.close(target)
            try store.seed(value)
            ctx.services.packages.set(store.package(target), for: target)
        } else { target = doc }
        if !ctx.dryRun {
            // Every navigation action is itself a registered command; test/headless contexts can change mode without a navigator.
            if ctx.navigator != nil { _ = try await ctx.execute(CommandIDs.docOpen, ["doc": .string(NodeRef.document(target).description)]) }
            if let session = ctx.activeSession {
                session.document = target
                session.page = try ctx.workspace.content(target).livePages.first?.id
                session.activeLayer = mode == "present" ? LessonManager.presentLayer : (mode == "feedback" ? feedback! : LessonManager.prepLayer)
                // Retain the teacher's layer visibility choices.
            }
        }
        return Output(ref: NodeRef.document(target).description, state: mode, snapshot: nil)
    }
}

struct LessonImportRoster: NibCommand {
    struct Params: Codable { var csv: String?; var url: String?; var folder: String; var recordUndo: Bool? }
    struct Output: Codable { var ref: String; var students: [LessonStudent] }
    static let descriptor = CommandDescriptor(
        id: "lesson.importRoster", title: String(localized: "Import Roster"),
        summary: "Import or replace a class roster from CSV text or a file URL; columns name or first_name,last_name, with optional id,email; the roster is a synced document in the class folder.",
        params: .obj(["csv": .str("CSV text, mutually exclusive with url"), "url": .str("tmp:, file: or https: CSV URL"), "folder": .ref,
                      "recordUndo": .bool("default true; false for UndoManager replay")], required: ["folder"]),
        examples: [["csv": "id,name,email\nsam,Sam,sam@example.org", "folder": "folder:FIXTUREFLD01"]],
        effect: .library, target: .library, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard p.csv == nil || p.url == nil else { throw LessonManager.invalid("Pass CSV text or a URL, choosing one.", path: "$.csv") }
        let library = try ctx.services.require(ctx.services.library, "library")
        let runtime = try LessonRuntime.require(ctx)
        guard !runtime.busy else { throw NibError(.conflict, "Another lesson operation is still saving.", hint: "try again when it finishes") }
        runtime.busy = true
        defer { runtime.busy = false }
        let folder = try LessonManager.folder(p.folder, library: library)
        let text: String
        if let csv = p.csv { text = csv }
        else {
            let url: URL
            if let input = p.url { url = try await ctx.inputFile(input) }
            else {
                guard ctx.principal.isUser, !ctx.dryRun, !NibApp.isHostlessTest,
                      let navigator = ctx.navigator, navigator.rootViewController != nil else {
                    throw NibError(.unavailable, "Choose a CSV file in Nib, or pass CSV text or a URL.", path: "$.csv", hint: "pass csv or url to lesson.importRoster")
                }
                let picker = LessonRosterPicker()
                url = try await picker.choose(navigator: navigator)
            }
            text = try await Task.detached {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: RosterImport.maxBytes + 1) ?? Data()
                return try RosterImport.text(bytes)
            }.value
        }
        let students = try await Task.detached { try RosterImport.parse(text).map { LessonStudent(id: $0.id, name: $0.name, email: nil) } }.value
        let doc = LessonManager.rosterID(folder)
        let created = library.node(doc) == nil
        if !created {
            try LessonManager.writable(doc, ctx)
            let existing = try ctx.workspace.content(doc).meta.ext?[LessonManager.rosterKey]?.decode(LessonRoster.self)
            guard existing?.folder == folder, library.node(doc)?.trashedAt == nil else {
                throw NibError(.conflict, "The roster id is already used or the roster is in Trash.", hint: "restore the roster before importing it again")
            }
        }
        if ctx.dryRun { return Output(ref: NodeRef.document(doc).description, students: students) }
        if created {
            var meta = DocumentMeta(id: doc, kind: .notebook, language: "en-GB")
            meta.ext = [LessonManager.managedKey: true]
            _ = try library.createDocument(DocumentContent(meta: meta, pages: [PageRecord(order: "V", title: String(localized: "Class Roster"))]),
                                           title: String(localized: "Class Roster"), in: folder)
        }
        do {
            try LessonManager.writable(doc, ctx)
            var meta = try ctx.workspace.content(doc).meta
            meta.ext = meta.ext ?? [:]
            meta.ext?[LessonManager.rosterKey] = try JSONValue.from(LessonRoster(folder: folder, students: students))
            try ctx.mutate(undoable: !created && p.recordUndo != false) { tx in try tx.putMeta(meta) }
            ctx.workspace.persistence.flush(doc)
            if p.recordUndo != false {
                if created { runtime.recordCopies([doc], ctx: ctx) }

            }
            ctx.events.emit(NibEventType.libraryChanged)
        } catch {
            if created { ctx.workspace.close(doc); try? library.deletePermanently(doc) }
            throw NibError.wrap(error)
        }
        return Output(ref: NodeRef.document(doc).description, students: students)
    }
}

/// Retained across the continuation; cancellation resumes with a normal command error, never a hanging task.
@MainActor
private final class LessonRosterPicker: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    func choose(navigator: SceneNavigator) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.commaSeparatedText, .plainText], asCopy: false)
            picker.allowsMultipleSelection = false
            picker.delegate = self
            navigator.presentModal(picker)
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { cancel(); return }
        continuation?.resume(returning: url)
        continuation = nil
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancel() }
    private func cancel() {
        continuation?.resume(throwing: NibError(.userDenied, "Roster import cancelled."))
        continuation = nil
    }
}
