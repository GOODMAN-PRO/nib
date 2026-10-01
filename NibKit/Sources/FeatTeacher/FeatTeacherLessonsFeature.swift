import Foundation
import SwiftUI
import NibContracts
import NibDesign

public enum FeatTeacherLessonsFeature: NibFeature {
    public static let id = "teacherlessons"
    static let panelID = "teacherlessons.panel"

    public static func register(_ app: NibApp) {
        app.commands.register(LessonCreate.self)
        app.commands.register(LessonSetState.self)
        app.commands.register(LessonImportRoster.self)
        app.services.set(LessonRuntime(), for: LessonRuntime.key)
        app.ui.panels.register(PanelDescriptor(
            id: panelID, title: String(localized: "Teacher Toolkit"), icon: NibSymbol.folder.name,
            placement: .sheet, order: 700, owner: id) { AnyView(LessonPanel(context: $0)) })
        for location in [MenuLocation.documentMore, .documentTitle, .libraryNew, .libraryItem] {
            app.ui.menus.register(MenuItemDescriptor(
                id: panelID + "." + location.rawValue, title: String(localized: "Open Teacher Toolkit"),
                icon: NibSymbol.folder.name, location: location, order: 710, owner: id,
                command: CommandIDs.panelOpen, params: { context in
                    var params: [String: JSONValue] = ["id": .string(panelID)]
                    if let doc = context.doc { params["doc"] = .string(NodeRef.document(doc).description) }
                    if let folder = context.folder { params["folder"] = .string(NodeRef.folder(folder).description) }
                    return .object(params)
                }))
        }
        for mode in ["prep", "present", "feedback"] {
            let title = mode == "prep" ? String(localized: "Use Prep Mode") : (mode == "present" ? String(localized: "Use Present Mode") : String(localized: "Write Feedback"))
            app.ui.menus.register(MenuItemDescriptor(
                id: "teacherlessons.mode." + mode, title: title, icon: NibSymbol.layers.name,
                location: .documentMore, order: 720, owner: id, command: CommandIDs.lessonSetState,
                params: { context in
                    guard let doc = context.doc else { return [:] }
                    return ["doc": .string(NodeRef.document(doc).description), "state": .string(mode)]
                }, isVisible: { context in
                    guard let doc = context.doc, context.session?.readOnly != true,
                          let meta = try? context.app.workspace.content(doc).meta else { return false }
                    return meta.kind == .notebook || meta.kind == .whiteboard
                }, submenu: String(localized: "Teaching Mode")))
        }
        app.ui.menus.register(MenuItemDescriptor(
            id: "teacherlessons.quickLesson", title: String(localized: "Start Quick Lesson"), icon: NibSymbol.share.name,
            location: .shareExport, order: 715, owner: id, command: CommandIDs.batch,
            params: { context in
                guard let doc = context.doc else { return [:] }
                return ["calls": [["command": .string(CommandIDs.collabHost), "params": ["doc": .string(NodeRef.document(doc).description)]],
                                  ["command": .string(CommandIDs.panelOpen), "params": ["id": "collab.share"]]]]
            },
            isVisible: { $0.doc.map { !LessonManager.isPrivate($0) } ?? false }))
        for location in [MenuLocation.documentMore, .documentTitle] {
            for (state, title) in [("submitted", String(localized: "Submit Assignment")),
                                   ("returned", String(localized: "Return Assignment")),
                                   ("resubmit", String(localized: "Request Resubmission"))] {
                app.ui.menus.register(MenuItemDescriptor(
                    id: "teacherlessons.assignment." + state + "." + location.rawValue, title: title,
                    icon: NibSymbol.documentWrite.name, location: location, order: 730, owner: id,
                    command: CommandIDs.lessonSetState,
                    params: { context in
                        guard let doc = context.doc else { return [:] }
                        return ["doc": .string(NodeRef.document(doc).description), "state": .string(state)]
                    }, isVisible: { context in
                        guard let doc = context.doc, !LessonManager.isPrivate(doc), context.session?.readOnly != true,
                              let meta = try? context.app.workspace.content(doc).meta,
                              let record = try? LessonManager.assignment(meta), let next = LessonState(rawValue: state) else { return false }
                        return record.state != next && record.state.accepts(next)
                    }))
            }
        }
        // Private presentation documents cannot be exported to the class or broadcast to a live session. The user
        // can return to Prep to share, and can still project the local presentation through present.start.
        app.bus.hooks.register(CommandHookDescriptor.guarding(
            id: "teacherlessons.privateSharing", owner: id,
            commands: [CommandIDs.collabHost, CommandIDs.exportRun, CommandIDs.exportPresent, CommandIDs.libraryDuplicate, CommandIDs.libraryMove]) { _, params, ctx in
                func containsPrivate(_ value: JSONValue) -> Bool {
                    if let text = value.stringValue {
                        let doc = NodeRef(text)?.documentID ?? NibID(text)
                        return LessonManager.isPrivate(doc)
                    }
                    if let values = value.arrayValue { return values.contains(where: containsPrivate) }
                    if let values = value.objectValue { return values.values.contains(where: containsPrivate) }
                    return false
                }
                let implicitPrivate = params["doc"] == nil && params["ref"] == nil && params["refs"] == nil && params["docs"] == nil
                    && ctx.activeSession?.document.map { LessonManager.isPrivate($0) } == true
                if containsPrivate(params) || implicitPrivate {
                    throw NibError(.permissionDenied, "Present notes stay on this device. Switch to Prep to share the lesson.", hint: "call lesson.setState {state: prep}")
                }
                return nil
            })
    }

    public static func start(_ app: NibApp) async {
        // A durable creation journal repairs transfers interrupted by process termination.
        if let library = app.services.library {
            let journal = library.metadataURL.appendingPathComponent("teacherlessons-pending")
                .appendingPathComponent(app.workspace.clock.deviceHex + ".json")
            if let bytes = try? Data(contentsOf: journal), let ids = try? JSONDecoder().decode([DocumentID].self, from: bytes) {
                for doc in ids where library.node(doc) != nil {
                    app.workspace.close(doc)
                    try? library.deletePermanently(doc)
                }
                if ids.allSatisfy({ library.node($0) == nil }) { try? FileManager.default.removeItem(at: journal) }
            }
        }
        // Install before restored private tabs load. Public document calls are forwarded unchanged.
        guard !(app.workspace.persistence is PrivateLessonPersistence), let assets = app.services.assets else { return }
        let root: URL
        if let memory = app.workspace.persistence as? InMemoryPersistence { root = memory.root.appendingPathComponent("private-lessons") }
        else {
            guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: true) else { return }
            root = support.appendingPathComponent("Nib/PrivateLessons", isDirectory: true)
        }
        let store = PrivateLessonPersistence(base: app.workspace.persistence, root: root)
        app.workspace.persistence = store
        app.services.assets = PrivateLessonAssets(base: assets, root: root)
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let doc = NibID(url.lastPathComponent)
            if LessonManager.isPrivate(doc) { app.services.packages.set(url, for: doc) }
        }
    }
}

private struct LessonPanelEntry: Identifiable {
    var id: String
    var title: String
    var state: LessonState?
    var student: String?
    var returns: Int
    var unreadable = false
}

/// Opaque sheet content: the host owns the floating droplet container. Lists and fields never draw glass over ink.
@MainActor
private struct LessonPanel: View {
    let context: PanelContext
    @State private var folder = ""
    @State private var doc = ""
    @State private var csv = ""
    @State private var className = ""
    @State private var archiveFolder = ""
    @State private var roster: [LessonStudent] = []
    @State private var entries: [LessonPanelEntry] = []
    @State private var folders: [LessonPanelEntry] = []
    @State private var documents: [LessonPanelEntry] = []
    @State private var filter = "all"
    @State private var sort = "name"
    @State private var error: String?
    @State private var receipt: String?
    @State private var loading = false
    @State private var liveHosted = false
    @State private var liveCode: String?
    @State private var liveURL: String?
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var liveSubscription: EventSubscription?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.xxl) {
                section(String(localized: "Class folder")) {
                    Text(String(localized: "Choose any shared synced folder. Co-teachers use the same folder and student copies."))
                        .font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                    Picker(String(localized: "Choose class folder"), selection: $folder) {
                        Text(String(localized: "Choose a folder")).tag("")
                        ForEach(folders) { Text($0.title).tag($0.id) }
                    }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                    if folders.isEmpty {
                        NibField(text: $className, prompt: String(localized: "Class folder name"))
                            .accessibilityLabel(String(localized: "New class folder name"))
                        NibButton(String(localized: "Create Class Folder"), symbol: .folder) {
                            run(CommandIDs.folderCreate, ["title": .string(className)]) { _ in
                                Task { await loadFolders() }
                            }
                        }.disabled(className.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                    }
                    NibButton(String(localized: "Load Class"), symbol: .folder) { performLoad() }
                        .disabled(folder.isEmpty || loading)
                    NibButton(String(localized: "Open Class Folder"), kind: .plain) {
                        run(CommandIDs.librarySetView, ["folder": .string(folder)])
                    }.disabled(folder.isEmpty || loading)
                }
                if let error { NibBanner(error, style: .warning) }
                if let receipt { NibBanner(receipt, style: .info) }
                if loading { ProgressView().accessibilityLabel(String(localized: "Saving lesson changes")) }
                section(String(localized: "Roster")) {
                    Text(String(localized: "CSV headings: id,name,email. Use different ids for students with the same name. Only ids and names are saved. The roster is visible to everyone with folder access. Import again to replace it."))
                        .font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                    NibField(text: $csv, prompt: String(localized: "Paste roster CSV"), lines: 3...8)
                        .accessibilityLabel(String(localized: "Roster CSV"))
                    NibButton(String(localized: "Import Pasted Roster"), symbol: .importFile) {
                        run(CommandIDs.lessonImportRoster, ["csv": .string(csv), "folder": .string(folder)], completion: importedRoster)
                    }.disabled(folder.isEmpty || loading || csv.isEmpty)
                    NibButton(String(localized: "Choose Roster File"), symbol: .importFile, kind: .plain) {
                        run(CommandIDs.lessonImportRoster, ["folder": .string(folder)], completion: importedRoster)
                    }.disabled(folder.isEmpty || loading)
                    if !roster.isEmpty {
                        DisclosureGroup(String(localized: "\(roster.count) students")) {
                            LazyVStack(alignment: .leading, spacing: NibSpacing.s) {
                                ForEach(roster) { student in NibRow(student.name) { EmptyView() } }
                            }
                        }.font(NibFont.body)
                    }
                }
                section(String(localized: "Lesson")) {
                    Picker(String(localized: "Source lesson"), selection: $doc) {
                        Text(String(localized: "Choose a document")).tag("")
                        ForEach(documents) { Text($0.title).tag($0.id) }
                    }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                    Text(String(localized: "Prep prepares the source before publishing. Published student copies are independent. Present keeps teaching notes on this device. Feedback writes on the selected student copy."))
                        .font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                    if widthClass == .compact || typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: NibSpacing.s) { modeButtons }
                    } else { HStack(spacing: NibSpacing.s) { modeButtons } }
                    NibButton(String(localized: "Create Lesson"), symbol: .duplicate, kind: .primary) {
                        run(CommandIDs.lessonCreate, ["doc": .string(doc), "folder": .string(folder)]) { value in
                            let count = value["refs"]?.arrayValue?.count ?? 0
                            receipt = String(localized: "Published \(count) student copies.")
                            performLoad()
                        }
                    }.disabled(folder.isEmpty || doc.isEmpty || roster.isEmpty || loading)
                    NibButton(String(localized: "Create Sample Lesson"), symbol: .documentWrite, kind: .plain) {
                        run(CommandIDs.lessonCreate, ["doc": "sample", "folder": .string(folder), "students": []]) { value in
                            if let ref = value["refs"]?[0]?.stringValue { doc = ref }
                            receipt = String(localized: "Sample lesson created. Open it to try answer zones and hints.")
                            Task { await loadFolders(); await loadClass() }
                        }
                    }.disabled(folder.isEmpty || loading)
                    if widthClass == .compact || typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: NibSpacing.s) { liveButtons }
                    } else { HStack(spacing: NibSpacing.s) { liveButtons } }
                    if let liveCode {
                        Text(String(localized: "Join code: \(liveCode)")).font(NibFont.title2).textSelection(.enabled)
                        if let liveURL { NibQRCode(liveURL, label: String(localized: "Join this Quick Lesson")) }
                        NibButton(String(localized: "Manage Participants"), kind: .plain) {
                            run(CommandIDs.panelOpen, ["id": "collab.share"])
                        }
                    }
                }
                section(String(localized: "Assignments")) {
                    Picker(String(localized: "Filter assignments"), selection: $filter) {
                        Text(String(localized: "All assignments")).tag("all")
                        ForEach(LessonState.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                    NibSegmentedControl(selection: $sort, options: ["name", "state"]) {
                        $0 == "name" ? String(localized: "Student name") : String(localized: "Assignment state")
                    }.accessibilityLabel(String(localized: "Sort assignments"))
                    if visibleEntries.isEmpty {
                        NibEmptyState(symbol: .documentWrite, title: String(localized: "No assignments here"),
                                      message: String(localized: "Import a roster and publish a lesson to create student copies."))
                    } else {
                        LazyVStack(alignment: .leading, spacing: NibSpacing.m) {
                            ForEach(visibleEntries) { entry in assignmentRow(entry) }
                        }
                    }
                }
                section(String(localized: "Archive class")) {
                    Text(String(localized: "Move the entire class folder into an Archive folder. The library keeps its usual filters and sorting."))
                        .font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                    Picker(String(localized: "Archive destination"), selection: $archiveFolder) {
                        Text(String(localized: "Choose an Archive folder")).tag("")
                        ForEach(folders.filter { $0.id != folder }) { Text($0.title).tag($0.id) }
                    }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                    NibButton(String(localized: "Archive Class"), symbol: .folder) {
                        run(CommandIDs.libraryMove, ["refs": [.string(folder)], "folder": .string(archiveFolder)]) { _ in
                            receipt = String(localized: "Class folder moved to Archive.")
                        }
                    }.disabled(folder.isEmpty || archiveFolder.isEmpty || folder == archiveFolder || loading)
                }
            }
            .padding(widthClass == .compact ? NibSpacing.m : NibSpacing.xl)
            .frame(maxWidth: NibMetrics.textColumnWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(NibColor.backgroundSecondary)
        .onChange(of: error) { _, value in
            if let value { AccessibilityNotification.Announcement(value).post() }
        }
        .onChange(of: receipt) { _, value in
            if let value { AccessibilityNotification.Announcement(value).post() }
        }
        .onDisappear { liveSubscription?.cancel(); liveSubscription = nil }
        .task {
            liveSubscription?.cancel()
            liveSubscription = context.app.events.subscribe { event in
                if event.type == "collab.session" { Task { @MainActor in await loadLiveSession() } }
            }
            folder = context.params["folder"]?.stringValue ?? ""
            doc = context.params["doc"]?.stringValue ?? context.session?.document.map { NodeRef.document($0).description } ?? ""
            await loadFolders()
            await loadLiveSession()
            if let selected = try? LessonManager.document(doc), LessonManager.isPrivate(selected) {
                if let detail = try? await context.app.bus.execute(CommandIDs.queryGet, ["ref": .string(doc), "fields": ["meta", "ext"]], session: context.session),
                   let source = (detail["meta"]?["ext"] ?? detail["ext"])?[LessonManager.privateSourceKey]?.stringValue {
                    doc = NodeRef.document(NibID(source)).description
                }
            }
            if !folder.isEmpty { await loadClass() }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NibInspectorSection(title) { content() }
    }
    private var modeButtons: some View {
        Group {
            NibButton(String(localized: "Use Prep"), symbol: .layers) { state("prep", ref: doc) }
            NibButton(String(localized: "Use Present"), symbol: .layers) { state("present", ref: doc) }
            NibButton(String(localized: "Write Feedback"), symbol: .documentWrite) { state("feedback", ref: doc) }
        }.disabled(doc.isEmpty || loading || !supportsModes)
    }
    private var supportsModes: Bool {
        guard let id = try? LessonManager.document(doc), let kind = try? context.app.workspace.content(id).meta.kind else { return false }
        return kind == .notebook || kind == .whiteboard
    }
    private var liveButtons: some View {
        Group {
            NibButton(String(localized: "Start Quick Lesson"), symbol: .share) {
                run(CommandIDs.collabHost, ["doc": .string(doc)]) { value in
                    Task { await loadLiveSession() }
                    liveCode = value["code"]?.stringValue
                    liveURL = value["url"]?.stringValue
                    receipt = String(localized: "Quick Lesson started. Approve students in Manage Participants.")
                }
            }
                .disabled(doc.isEmpty || loading)
            NibButton(String(localized: "Start Follow Me"), symbol: .present) { run(CommandIDs.collabFollowMe, ["on": true]) }
                .disabled(loading || !liveHosted)
            NibButton(String(localized: "Stop Follow Me"), symbol: .present, kind: .plain) { run(CommandIDs.collabFollowMe, ["on": false]) }
                .disabled(loading || !liveHosted)
        }
    }
    private func loadLiveSession() async {
        let value = try? await context.app.bus.execute(CommandIDs.collabParticipants, [:], session: context.session)
        liveHosted = value?["active"]?.boolValue == true && value?["side"]?.stringValue == "host"
    }
    private var visibleEntries: [LessonPanelEntry] {
        entries.filter { ($0.state != nil || $0.unreadable) && (filter == "all" || $0.state?.rawValue == filter) }.sorted {
            if sort == "state", $0.state != $1.state { return ($0.state?.rawValue ?? "") < ($1.state?.rawValue ?? "") }
            return ($0.student ?? $0.title).localizedStandardCompare($1.student ?? $1.title) == .orderedAscending
        }
    }
    private func assignmentRow(_ entry: LessonPanelEntry) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            NibRow(entry.student ?? entry.title, subtitle: entry.unreadable ? String(localized: "Unreadable assignment") : entry.state?.title) {
                NibButton(String(localized: "Open Copy"), kind: .plain) { run(CommandIDs.docOpen, ["doc": .string(entry.id)]) }
            }
            if entry.returns > 0 {
                NibButton(String(localized: "Open Returned Version"), symbol: .history, kind: .plain) { state("openReturn", ref: entry.id) }
            }
            if widthClass == .compact || typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NibSpacing.s) { assignmentActions(entry) }
            } else { HStack(spacing: NibSpacing.s) { assignmentActions(entry) } }
            Divider()
        }
    }
    private func assignmentActions(_ entry: LessonPanelEntry) -> some View {
        Group {
            if !entry.unreadable { NibButton(String(localized: "Write Feedback"), kind: .plain) { state("feedback", ref: entry.id) } }
            if entry.state == .published || entry.state == .resubmit {
                NibButton(String(localized: "Submit Copy")) { state("submitted", ref: entry.id) }
            }
            if entry.state == .submitted {
                NibButton(String(localized: "Return Copy")) { state("returned", ref: entry.id) }
            }
            if entry.state == .returned {
                NibButton(String(localized: "Request Resubmission")) { state("resubmit", ref: entry.id) }
            }
        }.disabled(loading)
    }
    private func state(_ state: String, ref: String) {
        run(CommandIDs.lessonSetState, ["doc": .string(ref), "state": .string(state)]) { value in
            if ["prep", "present", "feedback"].contains(state) {
                receipt = state == "present" ? String(localized: "Present mode keeps your notes on this device.") : String(localized: "Teaching mode selected. Close the toolkit to write on the page.")
            } else { performLoad() }
        }
    }
    private func importedRoster(_ value: JSONValue) {
        roster = (try? value["students"]?.decode([LessonStudent].self)) ?? []
        receipt = String(localized: "Imported \(roster.count) students.")
    }
    private func run(_ command: String, _ params: JSONValue, completion: @escaping (JSONValue) -> Void = { _ in }) {
        guard !loading else { return }
        loading = true; error = nil; receipt = nil
        Task {
            do {
                let value = try await context.app.bus.execute(command, params, session: context.session)
                loading = false
                completion(value)
            } catch { loading = false; self.error = NibError.wrap(error).message }
        }
    }
    private func performLoad() {
        Task { await loadClass() }
    }
    private func loadFolders() async {
        do {
            let nodes = try await pagedNodes(CommandIDs.queryTree, ["root": "lib", "depth": 8])
            documents = nodes.filter { $0["kind"]?.stringValue == "document" || $0["ref"]?.stringValue?.hasPrefix("doc:") == true }.compactMap { node in
                guard let ref = node["ref"]?.stringValue ?? node["id"]?.stringValue.map({ "doc:" + $0 }) else { return nil }
                return LessonPanelEntry(id: ref, title: node["title"]?.stringValue ?? ref, returns: 0)
            }
            folders = nodes.filter { $0["kind"]?.stringValue == "folder" }.compactMap { node in
                guard let ref = node["ref"]?.stringValue ?? node["id"]?.stringValue.map({ "folder:" + $0 }) else { return nil }
                return LessonPanelEntry(id: ref, title: node["title"]?.stringValue ?? ref, returns: 0)
            }
        } catch { self.error = NibError.wrap(error).message }
    }
    private func loadClass() async {
        guard !folder.isEmpty, !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            var results: [LessonPanelEntry] = []
            let nodes = try await pagedNodes(CommandIDs.libraryList, ["folder": .string(folder), "sort": "title"]).filter { $0["kind"]?.stringValue == "document" || $0["ref"]?.stringValue?.hasPrefix("doc:") == true }
            roster = []
            // Bound concurrent reads so large classes do not create a task per document at once.
            for start in stride(from: 0, to: nodes.count, by: 8) {
                let batch = Array(nodes[start..<min(start + 8, nodes.count)])
                let details = await withTaskGroup(of: (JSONValue, JSONValue?).self) { group in
                    for node in batch {
                        group.addTask { @MainActor in
                            guard let ref = node["ref"]?.stringValue ?? node["id"]?.stringValue.map({ "doc:" + $0 }) else { return (node, nil) }
                            let detail = try? await context.app.bus.execute(CommandIDs.queryGet, ["ref": .string(ref), "fields": ["meta", "ext"]], session: context.session)
                            return (node, detail)
                        }
                    }
                    var values: [(JSONValue, JSONValue?)] = []
                    for await value in group { values.append(value) }
                    return values
                }
                for (node, detail) in details {
                    guard let ref = node["ref"]?.stringValue ?? node["id"]?.stringValue.map({ "doc:" + $0 }) else { continue }
                    let ext = detail?["meta"]?["ext"] ?? detail?["ext"] ?? detail?["document"]?["meta"]?["ext"]
                    if let json = ext?[LessonManager.rosterKey], let record = try? json.decode(LessonRoster.self) { roster = record.students }
                    let assignment = try? ext?[LessonManager.assignmentKey]?.decode(LessonAssignment.self)
                    results.append(LessonPanelEntry(id: ref, title: node["title"]?.stringValue ?? ref,
                                                   state: assignment?.state, student: assignment?.student?.name, returns: assignment?.returns.count ?? 0,
                                                   unreadable: detail == nil || (ext?[LessonManager.assignmentKey] != nil && assignment == nil)))
                }
            }
            entries = results
        } catch { self.error = NibError.wrap(error).message }
    }
    private func pagedNodes(_ command: String, _ params: JSONValue) async throws -> [JSONValue] {
        var params = params.objectValue ?? [:], nodes: [JSONValue] = [], cursors = Set<String>()
        repeat {
            let value = try await context.app.bus.execute(command, .object(params), session: context.session)
            nodes += flattened(value)
            guard let cursor = value["cursor"]?.stringValue, !cursor.isEmpty else { break }
            guard cursors.insert(cursor).inserted else { throw NibError(.conflict, "The library pagination cursor repeated.") }
            params["cursor"] = .string(cursor)
        } while true
        return nodes
    }
    private func flattened(_ value: JSONValue) -> [JSONValue] {
        if let values = value.arrayValue { return values.flatMap(flattened) }
        guard let object = value.objectValue else { return [] }
        var values: [JSONValue] = object["ref"] != nil || object["id"] != nil ? [value] : []
        for key in ["nodes", "items", "children", "tree", "root"] { if let child = object[key] { values += flattened(child) } }
        return values
    }
}
