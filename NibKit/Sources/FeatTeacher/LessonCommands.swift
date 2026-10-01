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

    /// UndoManager registers its inverse synchronously. The actual disk changes still run through lesson.create,
    /// retaining schema validation, permission checks and normal command error presentation.
    func recordCopies(_ ids: [DocumentID], ctx: CommandContext) {
        guard !ids.isEmpty, let app = ctx.app else { return }
        let refs = JSONValue.array(ids.map { .string($0.raw) })
        record(command: CommandIDs.lessonCreate, undo: ["action": "trash", "ids": refs],
               redo: ["action": "restore", "ids": refs], title: String(localized: "Create Lesson"), ctx: ctx, app: app)
    }

    func recordRoster(previous: [LessonStudent], next: [LessonStudent], folder: FolderID, ctx: CommandContext) {
        guard let app = ctx.app else { return }
        let undo: JSONValue = ["csv": .string(RosterImport.csv(previous)), "folder": .string(NodeRef.folder(folder).description), "recordUndo": false]
        let redo: JSONValue = ["csv": .string(RosterImport.csv(next)), "folder": .string(NodeRef.folder(folder).description), "recordUndo": false]
        record(command: CommandIDs.lessonImportRoster, undo: undo, redo: redo,
               title: String(localized: "Import Roster"), ctx: ctx, app: app)
    }

    private func record(command: String, undo: JSONValue, redo: JSONValue, title: String, ctx: CommandContext, app: NibApp) {
        let manager = ctx.navigator?.rootViewController?.undoManager ?? fallbackUndo
        let step = LessonCommandUndo(app: app, session: ctx.session, manager: manager, command: command,
                                     undo: undo, redo: redo, title: title)
        // UndoManager targets are not relied on for ownership; the feature keeps the steps for its lifetime.
        undoSteps.append(step)
        step.register(undo: true)
    }
}

@MainActor
final class LessonCommandUndo {
    weak var app: NibApp?
    weak var manager: UndoManager?
    weak var session: EditorSession?
    let command: String
    let undoParams: JSONValue
    let redoParams: JSONValue
    let title: String
    init(app: NibApp, session: EditorSession?, manager: UndoManager, command: String, undo: JSONValue, redo: JSONValue, title: String) {
        self.app = app; self.session = session; self.manager = manager; self.command = command
        self.undoParams = undo; self.redoParams = redo; self.title = title
    }
    func register(undo: Bool) {
        manager?.registerUndo(withTarget: self) { step in
            step.register(undo: !undo)
            step.app?.perform(step.command, undo ? step.undoParams : step.redoParams, session: step.session)
        }
        manager?.setActionName(title)
    }
}

struct LessonCreate: NibCommand {
    struct Params: Codable {
        var doc: String?
        var students: JSONValue?
        var folder: String?
        var ids: [String]?
        /// Additive library undo operation; only documents tagged as created by this feature can be acted on.
        var action: String?
    }
    struct Output: Codable { var refs: [String]; var source: String? }

    static let descriptor = CommandDescriptor(
        id: "lesson.create", title: String(localized: "Create Lesson"),
        summary: "Publish one independent copy per student in a shared class folder; students accepts roster objects or names; doc=sample creates a sample; ids fixes copy ids; action trash/restore supports undo.",
        params: .obj(["doc": .str("source doc ref, or sample for the built-in lesson"),
                      "students": .arr(.anything("name string or {id,name,email?}; omit to use the imported roster")),
                      "folder": .ref, "ids": .arr(.str("caller-chosen document ids, one per copy")),
                      "action": .str("default create; undo operations only affect lesson-managed documents", choices: ["create", "trash", "restore"]) ]),
        examples: [["doc": "doc:FIXTUREDOC01", "students": ["Sam"], "folder": "folder:FIXTUREFLD01"],
                   ["doc": "sample", "students": [], "folder": "folder:FIXTUREFLD01", "ids": ["SAMPLELESSON01"]]],
        effect: .library, target: .library, extraScopes: [.documentRead])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "library")
        let runtime = try LessonRuntime.require(ctx)
        guard !runtime.busy else { throw NibError(.conflict, "Another lesson operation is still saving.", hint: "try again when it finishes") }
        runtime.busy = true
        defer { runtime.busy = false }
        let action = p.action ?? "create"
        if action != "create" {
            guard ["trash", "restore"].contains(action), let ids = p.ids, !ids.isEmpty else {
                throw LessonManager.invalid("Choose lesson document ids and a valid action.", path: "$.action")
            }
            let docs = try ids.map { try LessonManager.document($0, path: "$.ids") }
            for doc in docs {
                try LessonManager.writable(doc, ctx)
                guard library.node(doc) != nil, try ctx.workspace.content(doc).meta.ext?[LessonManager.managedKey]?.boolValue == true else {
                    throw NibError(.permissionDenied, "Library undo can only change documents created by the lesson toolkit.")
                }
            }
            if !ctx.dryRun {
                var changed: [DocumentID] = []
                do {
                    for doc in docs {
                        if action == "trash" { try library.trash(doc) }
                        else { try library.restore(doc, to: nil) }
                        changed.append(doc)
                    }
                } catch {
                    for doc in changed.reversed() {
                        if action == "trash" { try? library.restore(doc, to: nil) }
                        else { try? library.trash(doc) }
                    }
                    throw NibError.wrap(error)
                }
                ctx.events.emit(NibEventType.libraryChanged)
            }
            return Output(refs: docs.map { NodeRef.document($0).description }, source: nil)
        }
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
        let blobs = try await copyInputs(snapshot, source: isSample ? nil : source, ctx: ctx)
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
                copy.content.meta.layers[LessonManager.feedbackLayer].name = String(localized: "Feedback")
                let blank = DocumentContent(meta: DocumentMeta(id: id, kind: copy.content.meta.kind))
                let actual = try library.createDocument(blank, title: student.map { title + " · " + $0.name } ?? title, in: folder)
                created.append(actual)
                guard actual == id else { throw NibError(.unsupported, "The library did not honour the supplied document id.") }
                copy = try await transfer(copy, to: id, blobs: blobs, ctx: ctx)
                copies.append((id, copy))
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
            runtime.recordCopies(created, ctx: ctx)
            ctx.events.emit(NibEventType.libraryChanged)
            return Output(refs: created.map { NodeRef.document($0).description }, source: isSample ? nil : NodeRef.document(source).description)
        } catch {
            for id in created { ctx.workspace.close(id); try? library.deletePermanently(id) }
            throw NibError.wrap(error)
        }
    }

    static func studentList(_ value: JSONValue?, folder: FolderID, ctx: CommandContext) throws -> [LessonStudent] {
        guard let value, value != .null else {
            let id = LessonManager.rosterID(folder)
            guard ctx.services.library?.node(id) != nil,
                  let json = try ctx.workspace.content(id).meta.ext?[LessonManager.rosterKey] else { return [] }
            return try json.decode(LessonRoster.self).students
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

    struct CopyInputs { var assets: [String: Data]; var files: [String: Data] }
    static func copyInputs(_ snapshot: LessonSnapshot, source: DocumentID?, ctx: CommandContext) async throws -> CopyInputs {
        let refs = LessonManager.assets(in: try JSONValue.from(snapshot))
        let assets = ctx.services.assets
        var files: [String: URL] = [:]
        if let source {
            for clip in snapshot.content.liveAudio {
                files[clip.file] = try ctx.workspace.persistence.fileURL(source, relativePath: clip.file)
                if let transcript = clip.transcriptFile {
                    // Persisted transcripts have per-device suffixes; preserve every file belonging to this base.
                    let base = try ctx.workspace.persistence.fileURL(source, relativePath: transcript)
                    for file in try FileManager.default.contentsOfDirectory(at: base.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                    where file.lastPathComponent.hasPrefix(base.lastPathComponent + ".") && file.pathExtension == "json" {
                        let relative = (transcript as NSString).deletingLastPathComponent
                        files[relative + "/" + file.lastPathComponent] = file
                    }
                }
            }
        }
        return try await Task.detached {
            var bytes: [String: Data] = [:], fileBytes: [String: Data] = [:]
            for ref in refs {
                guard let source, let assets else { throw NibError.unavailable("lesson assets") }
                bytes[ref.name] = try assets.data(ref, doc: source)
            }
            for (path, url) in files { fileBytes[path] = try Data(contentsOf: url) }
            return CopyInputs(assets: bytes, files: fileBytes)
        }.value
    }

    static func transfer(_ snapshot: LessonSnapshot, to doc: DocumentID, blobs: CopyInputs, ctx: CommandContext) async throws -> LessonSnapshot {
        let assets = try ctx.services.require(ctx.services.assets, "asset store")
        var paths: [String: URL] = [:]
        for path in blobs.files.keys { paths[path] = try ctx.workspace.persistence.fileURL(doc, relativePath: path) }
        return try await Task.detached {
            var map: [String: AssetRef] = [:]
            for (name, bytes) in blobs.assets {
                let ext = (name as NSString).pathExtension
                map[name] = try assets.put(bytes, ext: ext.isEmpty ? "bin" : ext, doc: doc)
            }
            for (path, bytes) in blobs.files {
                guard let url = paths[path] else { continue }
                try bytes.write(to: url, options: .atomic)
            }
            let json = try JSONValue.from(snapshot)
            return try LessonManager.remappedAssets(json, map).decode(LessonSnapshot.self)
        }.value
    }
}

struct LessonSetState: NibCommand {
    struct Params: Codable { var doc: String?; var state: String }
    struct Output: Codable { var ref: String; var state: String; var snapshot: AssetRef? }
    static let descriptor = CommandDescriptor(
        id: "lesson.setState", title: String(localized: "Change Assignment State"),
        summary: "Set published, submitted, returned or resubmit on a student copy; return saves an immutable snapshot. Prep, present and feedback select teaching modes; present uses a device-private workspace.",
        params: .obj(["doc": .ref, "state": .str(choices: ["published", "submitted", "returned", "resubmit", "prep", "present", "feedback"])], required: ["doc", "state"]),
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
            let snapshot = try LessonManager.capture(doc, workspace: ctx.workspace)
            let assets = try ctx.services.require(ctx.services.assets, "asset store")
            let bytes = try await Task.detached { try JSONEncoder().encode(snapshot) }.value
            if !ctx.dryRun {
                let destination = doc
                let ref = try await Task.detached { try assets.put(bytes, ext: "json", doc: destination) }.value
                record.returns.append(LessonReturn(asset: ref, at: Date().timeIntervalSince1970, attempt: record.attempt))
                snapshotRef = ref
            }
        }
        if state == .resubmit { record.attempt += 1 }
        record.state = state
        meta.ext = meta.ext ?? [:]
        meta.ext?[LessonManager.assignmentKey] = try JSONValue.from(record)
        try ctx.mutate { tx in try tx.putMeta(meta) }
        return Output(ref: NodeRef.document(doc).description, state: state.rawValue, snapshot: snapshotRef)
    }

    private static func mode(_ mode: String, doc: DocumentID, ctx: CommandContext) async throws -> Output {
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
            value.content.meta.id = target
            value.content.meta.locked = false
            value.content.meta.sourceBookmark = nil
            value.content.meta.ext = value.content.meta.ext ?? [:]
            value.content.meta.ext?[LessonManager.privateSourceKey] = .string(doc.raw)
            value.content.meta.layers[LessonManager.presentLayer].name = String(localized: "Present, private")
            for page in Array(value.items.keys) {
                value.items[page] = value.items[page]?.map { item in var item = item; item.layer = LessonManager.prepLayer; return item }
            }
            let blobs = try await LessonCreate.copyInputs(value, source: doc, ctx: ctx)
            // Asset writes need only the directory, so no previous private note is overwritten if a copy fails.
            try FileManager.default.createDirectory(at: store.package(target), withIntermediateDirectories: true)
            value = try await LessonCreate.transfer(value, to: target, blobs: blobs, ctx: ctx)
            if let old {
                for page in old.content.livePages {
                    let notes = old.items[page.id]?.filter { $0.layer == LessonManager.presentLayer } ?? []
                    if !notes.isEmpty {
                        if value.content.page(page.id) == nil { value.content.pages.append(page) }
                        value.items[page.id, default: []] += notes
                    }
                }
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
                session.activeLayer = mode == "present" ? LessonManager.presentLayer : (mode == "feedback" ? LessonManager.feedbackLayer : LessonManager.prepLayer)
                session.hiddenLayers = []
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
                guard bytes.count <= RosterImport.maxBytes, let text = String(data: bytes, encoding: .utf8) else {
                    throw RosterImport.invalid("Choose a UTF-8 CSV file no larger than 2 MB.")
                }
                return text
            }.value
        }
        let students = try await Task.detached { try RosterImport.parse(text) }.value
        let doc = LessonManager.rosterID(folder)
        let created = library.node(doc) == nil
        var previous: [LessonStudent]?
        if !created {
            try LessonManager.writable(doc, ctx)
            let existing = try ctx.workspace.content(doc).meta.ext?[LessonManager.rosterKey]?.decode(LessonRoster.self)
            previous = existing?.students
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
                else if let previous { runtime.recordRoster(previous: previous, next: students, folder: folder, ctx: ctx) }
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
