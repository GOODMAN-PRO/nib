import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

struct InsightPage: Codable, Identifiable {
    var id: String
    var title: String
    var number: Int
}

struct InsightQuestion: Codable, Identifiable {
    var id: String
    var title: String
    var page: String
}

struct InsightCopy: Codable, Identifiable {
    var id: String
    var student: String
    var state: String
}

struct InsightMissing: Codable, Identifiable {
    var id: String
    var reason: String
}

struct InsightEntry: Codable, Identifiable {
    var id: String
    var doc: String
    var page: String
    var zone: String?
    var student: String
    var region: NibContracts.Rect
    var text: String
    var hasInk: Bool
    var points: Double?
    var score: Double?
    var revision: Rev
    var asset: String?
}

struct InsightCollection: Codable {
    var source: String
    var folder: String? = nil
    var page: String?
    var zone: String?
    var pages: [InsightPage]
    var questions: [InsightQuestion]
    var copies: [InsightCopy]
    var entries: [InsightEntry]
    var model: InsightEntry?
    var clusters: [InsightCluster]
    var modelAnswer: String?
    var missing: [InsightMissing]
    var staleMembers: [String] = []

    var revisions: [String: Rev] {
        var result = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.revision) })
        if let model { result[model.id] = model.revision }
        return result
    }
}

@MainActor
enum SmartViews {
    static func invalid(_ message: String, path: String) -> NibError {
        NibError(.invalidParams, message, path: path, hint: "call lesson.collect with the source document, then choose a returned page or question ref")
    }

    static func modelAnswer(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 10_000 else { throw invalid("Use a model answer of at most 10,000 characters.", path: "$.modelAnswer") }
        return text.isEmpty ? nil : text
    }

    static func collect(doc raw: String, zone zoneRef: String?, page pageRef: String?, folder folderRef: String? = nil, ctx: CommandContext) throws -> InsightCollection {
        let requested = try LessonManager.document(raw)
        try unlocked(requested, ctx)
        let requestedMeta = try ctx.workspace.content(requested).meta
        let assignment = try LessonManager.assignment(requestedMeta)
        let source = assignment?.source ?? requestedMeta.ext?[LessonManager.privateSourceKey]?.stringValue.map { NibID($0) } ?? requested
        try unlocked(source, ctx)
        let library = try ctx.services.require(ctx.services.library, "library")
        let folder = try folderRef.map { try LessonManager.folder($0, library: library) } ?? assignment?.folder
        let snapshot = try ctx.services.get(InsightRuntime.key, as: InsightRuntime.self)?.snapshot(source, workspace: ctx.workspace)
            ?? LessonManager.capture(source, workspace: ctx.workspace)
        guard snapshot.content.meta.kind == .notebook || snapshot.content.meta.kind == .whiteboard else {
            throw NibError(.unsupported, "Smart Views require a notebook or whiteboard lesson.")
        }
        let livePages = snapshot.content.livePages
        let pages = livePages.enumerated().map { index, page in
            InsightPage(id: NodeRef.page(source, page.id).description, title: page.title ?? String(localized: "Page \(index + 1)"), number: index + 1)
        }
        var questions: [InsightQuestion] = []
        for page in livePages {
            let zones = (snapshot.items[page.id] ?? []).filter { !$0.deleted && AnswerZone.decode($0) != nil }
                .sorted { $0.bounds.minY == $1.bounds.minY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.minY < $1.bounds.minY }
            for (index, item) in zones.enumerated() {
                questions.append(InsightQuestion(id: NodeRef.item(source, page.id, item.id).description,
                                                 title: AnswerZone.decode(item)?.label ?? String(localized: "Question \(index + 1)"),
                                                 page: NodeRef.page(source, page.id).description))
            }
        }
        var selectedPage = livePages.first?.id
        var zoneID: ElementID?
        if let zoneRef {
            guard case .item(let d, let p, let i)? = NodeRef(zoneRef), d == requested || d == source,
                  NibID.isValid(i.raw), livePages.contains(where: { $0.id == p }) else {
                throw invalid("The question must belong to this lesson.", path: "$.zone")
            }
            selectedPage = p; zoneID = i
            guard let item = snapshot.items[p]?.first(where: { $0.id == i && !$0.deleted }), AnswerZone.decode(item) != nil else {
                throw NibError(.unsupported, "The selected item is not an answer zone.", path: "$.zone", hint: "choose a question returned by lesson.collect")
            }
        } else if let pageRef {
            guard case .page(let d, let p)? = NodeRef(pageRef), d == source || d == requested,
                  livePages.contains(where: { $0.id == p }) else { throw invalid("The page must belong to this lesson.", path: "$.page") }
            selectedPage = p
        }
        var copies: [InsightCopy] = [], entries: [InsightEntry] = [], missing: [InsightMissing] = []
        for node in library.allNodes().filter({ $0.kind == .document && $0.trashedAt == nil && $0.id != source && !LessonManager.isPrivate($0.id) }).sorted(by: { $0.id < $1.id }) {
            // Heads are small. Inspect only assignment metadata, then load the selected page of matching copies.
            guard let meta = try? ctx.workspace.peekContent(node.id).meta, meta.ext?[LessonManager.assignmentKey] != nil else { continue }
            let record: LessonAssignment
            do {
                guard let decoded = try LessonManager.assignment(meta) else { continue }
                record = decoded
            } catch {
                missing.append(InsightMissing(id: NodeRef.document(node.id).description, reason: NibError.wrap(error).message))
                continue
            }
            guard record.source == source, let student = record.student else { continue }
            if let folder, record.folder != folder { continue }
            guard copies.count < RosterImport.maxStudents else { throw NibError(.unsupported, "Collect at most 1,000 student copies at a time.") }
            let copy = InsightCopy(id: NodeRef.document(node.id).description, student: student.name, state: record.state.rawValue)
            copies.append(copy)
            do {
                try unlocked(node.id, ctx)
                guard let selectedPage else { throw NibError(.notFound, "The source lesson has no pages.") }
                entries.append(try entry(doc: node.id, page: selectedPage, zone: zoneID, student: student.name, ctx: ctx))
            } catch {
                missing.append(InsightMissing(id: copy.id, reason: NibError.wrap(error).message))
            }
        }
        copies.sort { ($0.student.localizedStandardCompare($1.student) == .orderedAscending) || ($0.student == $1.student && $0.id < $1.id) }
        let rank = Dictionary(uniqueKeysWithValues: copies.enumerated().map { ($0.element.id, $0.offset) })
        entries.sort { (rank[$0.doc] ?? 0) < (rank[$1.doc] ?? 0) }
        var model: InsightEntry?
        var record: InsightClusterRecord?
        if let selectedPage {
            model = try entry(doc: source, page: selectedPage, zone: zoneID, student: String(localized: "Model answer"), ctx: ctx)
            if let zoneID {
                let scopes = snapshot.content.meta.ext?[LessonManager.rosterKey]?[ClusterEngine.recordKey]?[NodeRef.item(source, selectedPage, zoneID).description]
                let value = scopes?[folder.map { NodeRef.folder($0).description } ?? "*"] ?? scopes?["*"]
                    ?? snapshot.items[selectedPage]?.first(where: { $0.id == zoneID })?.custom?.data[ClusterEngine.recordKey]
                if let value {
                    do { record = try value.decode(InsightClusterRecord.self) }
                    catch { throw NibError(.unsupported, "This question's saved clusters are unreadable. Update Nib before changing them.") }
                }
            }
        }
        let available = Set(entries.map(\.id))
        let stale = Array(Set((record?.clusters ?? []).flatMap(\.members)).subtracting(available)).sorted()
        let pruned = (record?.clusters ?? []).map { cluster in
            var cluster = cluster
            cluster.members.removeAll { !available.contains($0) }
            return cluster
        }
        return InsightCollection(source: NodeRef.document(source).description, folder: folder.map { NodeRef.folder($0).description },
                                 page: selectedPage.map { NodeRef.page(source, $0).description }, zone: model?.zone,
                                 pages: pages, questions: questions, copies: copies, entries: entries, model: model,
                                 clusters: pruned, modelAnswer: record?.modelAnswer, missing: missing, staleMembers: stale)
    }

    static func unlocked(_ doc: DocumentID, _ ctx: CommandContext) throws {
        guard ctx.services.lock?.isLocked(doc) != true else { throw NibError(.locked, "Unlock the lesson copy before collecting its answers.") }
    }

    private static func entry(doc: DocumentID, page: PageID, zone: ElementID?, student: String, ctx: CommandContext) throws -> InsightEntry {
        let cached = ctx.workspace.cachedPages(doc)
        defer { ctx.workspace.evictPages(doc, keeping: cached) }
        let content = try ctx.workspace.content(doc)
        guard let record = content.livePages.first(where: { $0.id == page }) else { throw NibError(.notFound, "This student copy is missing the selected page.") }
        let items = try ctx.workspace.items(doc, page: page)
        let item = zone.flatMap { id in items.first { $0.id == id && !$0.deleted } }
        if zone != nil && item.flatMap(AnswerZone.decode) == nil { throw NibError(.notFound, "This student copy is missing the selected answer zone.") }
        let pageBounds: NibContracts.Rect
        if let size = record.size {
            pageBounds = NibContracts.Rect(x: 0, y: 0, width: size.width, height: size.height)
        } else {
            let liveBounds = items.filter { !$0.deleted }.map(\.bounds).filter { !$0.isEmpty }
            pageBounds = liveBounds.dropFirst().reduce(liveBounds.first ?? NibContracts.Rect(x: 0, y: 0, width: PageSize.a4.width, height: PageSize.a4.height)) { $0.union($1) }
        }
        let bounds: NibContracts.Rect = item?.bounds ?? pageBounds
        guard !bounds.isEmpty, [bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy(\.isFinite) else {
            throw NibError(.unsupported, "This question has an invalid frame.")
        }
        let answerItems = items.filter { !$0.deleted && $0.id != item?.id && bounds.intersects($0.bounds) }
            .sorted { $0.z < $1.z }
        let text = answerItems.compactMap { item -> String? in
            if let text = item.text { return text.text.plainText }
            if let sticky = item.sticky { return sticky.text.plainText }
            if let text = item.shape?.text { return text.plainText }
            if let math = item.math { return math.latex.joined(separator: "\n") }
            return nil
        }.joined(separator: "\n")
        let zoneRecord = item.flatMap(AnswerZone.decode)
        let ref = zone.map { NodeRef.item(doc, page, $0).description }
        let pageRevision = try ctx.workspace.contentRevision(doc, page: page) ?? ctx.workspace.allItems(doc, page: page).map(\.rev).max() ?? .zero
        let revision = max(content.meta.rev, record.rev, pageRevision)
        let hasInk = answerItems.contains { $0.kind == .stroke || $0.kind == .image || $0.kind == .custom }
        return InsightEntry(id: ref ?? NodeRef.page(doc, page).description, doc: NodeRef.document(doc).description,
                            page: NodeRef.page(doc, page).description, zone: ref, student: student, region: bounds,
                            text: text, hasInk: hasInk,
                            points: zoneRecord?.points, score: zoneRecord?.score, revision: revision)
    }

    static func render(_ entry: InsightEntry, ctx: CommandContext) async throws -> String {
        let value = try await ctx.execute(CommandIDs.renderPage, ["page": .string(entry.page), "region": try JSONValue.from(entry.region), "scale": 1])
        guard let asset = value["asset"]?.stringValue, asset.hasPrefix("tmp:"), asset.count > 4 else {
            throw NibError(.unsupported, "The renderer did not return a temporary page image.")
        }
        return asset
    }

    static func assetRef(_ string: String) -> AssetRef {
        AssetRef(string.hasPrefix("tmp:") ? String(string.dropFirst(4)) : string)
    }
}

/// Opaque review sheet: the canvas stays outside it and thumbnails never acquire liquid effects.
@MainActor
struct SmartViewsPanel: View {
    let context: PanelContext
    @State private var collection: InsightCollection?
    @State private var view = "page"
    @State private var selectedPage = ""
    @State private var selectedZone = ""
    @State private var currentCopy: String?
    @State private var modelAnswer = ""
    @State private var newGroup = ""
    @State private var clusters: [InsightCluster] = []
    @State private var scoreText: [String: String] = [:]
    @State private var savedClusters: [InsightCluster] = []
    @State private var proposed = false
    @State private var revisions: [String: Rev]?
    @State private var busy = false
    @State private var error: String?
    @State private var receipt: String?
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize

    init(context: PanelContext, initialCollection: InsightCollection? = nil, initialView: String = "page") {
        self.context = context
        _collection = State(initialValue: initialCollection)
        _view = State(initialValue: initialView)
        _selectedPage = State(initialValue: initialCollection?.page ?? "")
        _selectedZone = State(initialValue: initialCollection?.zone ?? "")
        _modelAnswer = State(initialValue: initialCollection?.modelAnswer ?? "")
        _clusters = State(initialValue: initialCollection?.clusters ?? [])
        _savedClusters = State(initialValue: initialCollection?.clusters ?? [])
        _revisions = State(initialValue: initialCollection?.revisions)
    }

    private var source: String? {
        collection?.source ?? context.params["doc"]?.stringValue ?? context.session?.document.map { NodeRef.document($0).description }
    }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: NibMetrics.thumbnailWidth), spacing: NibSpacing.l, alignment: .top)]
    }

    var body: some View {
        ScrollView { reviewContent }
            .background(NibColor.background)
            .task { collect() }
    }

    /// The exact sheet contents, also rendered without the platform scroll host for hostless snapshots.
    var reviewContent: some View {
            VStack(alignment: .leading, spacing: NibSpacing.xl) {
                if let error { NibBanner(error, style: .warning) }
                if let receipt {
                    NibBanner(receipt, style: .info)
                    NibButton(String(localized: "Undo Saved Clusters"), symbol: .undo, kind: .plain) {
                        guard let source else { return }
                        run(CommandIDs.undo, ["doc": .string(source)]) { _ in self.receipt = nil; collect() }
                    }.disabled(busy)
                }
                if busy { NibTraceRow(String(localized: "Collecting class answers"), phase: .running) }
                if let collection {
                    ClassNavigatorView(navigator: ClassNavigator(copies: collection.copies, current: currentCopy), busy: busy,
                                       open: openCopy, mode: teachingMode)
                    Divider()
                    viewControls(collection)
                    if !collection.missing.isEmpty || !collection.staleMembers.isEmpty {
                        VStack(alignment: .leading, spacing: NibSpacing.s) {
                            Text(String(localized: "Unavailable copies")).font(NibFont.headline)
                            ForEach(collection.missing) { copy in
                                Text(copy.reason).font(NibFont.callout).foregroundStyle(NibColor.warning)
                            }
                            ForEach(collection.staleMembers, id: \.self) { ref in
                                Text(String(localized: "Unavailable answer: \(ref)")).font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                            }
                        }
                    }
                    if collection.entries.isEmpty {
                        NibEmptyState(symbol: .pages, title: String(localized: "No student answers yet"),
                                      message: String(localized: "Publish this lesson to a class roster, then collect the student copies."))
                    } else {
                        if view == "question", !selectedZone.isEmpty { questionControls(collection) }
                        if view == "question", !clusters.isEmpty {
                            clusterSections(collection)
                            let assigned = Set(clusters.flatMap(\.members))
                            let unassigned = collection.entries.filter { !assigned.contains($0.id) }
                            if !unassigned.isEmpty {
                                Text(String(localized: "Unassigned answers")).font(NibFont.headline)
                                answerGrid(unassigned, collection: collection)
                            }
                        } else { answerGrid(collection.entries, collection: collection) }
                    }
                } else if !busy {
                    NibEmptyState(symbol: .pages, title: String(localized: "Choose a lesson"),
                                  message: String(localized: "Open a lesson or student copy, then choose Review Class Answers."))
                }
                NibButton(String(localized: "Collect Current Answers"), symbol: .retry, kind: .plain) { collect() }
                    .disabled(busy || source == nil).nibShortcut(KeyboardShortcut("r", modifiers: .command))
            }.padding(NibSpacing.l)
        .background(NibColor.background)
    }

    @ViewBuilder
    private func viewControls(_ collection: InsightCollection) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                NibButton(String(localized: "Show By Page"), kind: view == "page" ? .secondary : .plain, expands: true) {
                    selectView("page", collection: collection)
                }.accessibilityAddTraits(view == "page" ? .isSelected : [])
                NibButton(String(localized: "Show By Question"), kind: view == "question" ? .secondary : .plain, expands: true) {
                    selectView("question", collection: collection)
                }.accessibilityAddTraits(view == "question" ? .isSelected : [])
            }.disabled(busy)
        } else {
            NibSegmentedControl(selection: Binding(get: { view }, set: { selectView($0, collection: collection) }), options: ["page", "question"]) {
                $0 == "page" ? String(localized: "By Page") : String(localized: "By Question")
            }.accessibilityLabel(String(localized: "Smart View")).disabled(busy)
        }
        if view == "page" {
            Picker(String(localized: "Lesson page"), selection: Binding(get: { selectedPage }, set: { selectedPage = $0; collect() })) {
                ForEach(collection.pages) { Text($0.title).tag($0.id) }
            }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget).disabled(busy)
                .labelsHidden().accessibilityLabel(String(localized: "Lesson page"))
        } else {
            Picker(String(localized: "Lesson question"), selection: Binding(get: { selectedZone }, set: { selectedZone = $0; collect() })) {
                Text(String(localized: "Choose a question")).tag("")
                ForEach(collection.questions) { Text($0.title).tag($0.id) }
            }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget).disabled(busy)
                .labelsHidden().accessibilityLabel(String(localized: "Lesson question"))
            if collection.questions.isEmpty {
                Text(String(localized: "Add answer zones to the source lesson to review by question."))
                    .font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
            }
        }
    }

    @ViewBuilder
    private func questionControls(_ collection: InsightCollection) -> some View {
        Text(String(localized: "Compare to Model Answer")).font(NibFont.headline)
        NibField(text: $modelAnswer, prompt: String(localized: "Enter a model answer, or use the source question below"), lines: 2...5)
            .accessibilityLabel(String(localized: "Model answer"))
        if let model = collection.model {
            InsightThumbnail(entry: model, app: context.app, session: context.session, isModel: true)
        }
        Text(String(localized: "Your connected model suggests groups. Review every answer before saving or applying scores."))
            .font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
        if widthClass == .compact || typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NibSpacing.s) { clusterActions }
        } else { HStack(spacing: NibSpacing.s) { clusterActions } }
        if widthClass == .compact || typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NibSpacing.s) { addCluster }
        } else { HStack(spacing: NibSpacing.s) { addCluster } }
        if proposed {
            NibBanner(String(localized: "These are suggestions. No scores have changed."), style: .info)
            NibButton(String(localized: "Save Reviewed Clusters"), symbol: .checkmark) { save(clusters) }.disabled(busy)
            NibButton(String(localized: "Discard Suggestions"), kind: .plain) {
                clusters = savedClusters; proposed = false; scoreText = [:]
            }.disabled(busy)
        }
    }

    private var addCluster: some View {
        Group {
            NibField(text: $newGroup, prompt: String(localized: "Name a manual cluster"))
                .accessibilityLabel(String(localized: "New cluster name"))
            NibButton(String(localized: "Add Cluster"), symbol: .plus, kind: .plain) {
                var next = clusters
                next.append(InsightCluster(id: NibID.make().raw, label: newGroup, members: []))
                save(next); newGroup = ""
            }.disabled(newGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || proposed)
        }
    }

    private var clusterActions: some View {
        Group {
            NibButton(String(localized: "Compare Answers"), symbol: .assistant, kind: .plain) { suggest(.modelAnswer) }
            NibButton(String(localized: "Group Similar Answers"), symbol: .assistant, kind: .plain) { suggest(.similarity) }
            NibButton(String(localized: "Save Model Answer"), kind: .plain) { save(savedClusters) }.disabled(proposed)
        }.disabled(busy)
    }

    private func clusterSections(_ collection: InsightCollection) -> some View {
        ForEach(clusters) { cluster in
            VStack(alignment: .leading, spacing: NibSpacing.m) {
                Text(cluster.label).font(NibFont.headline)
                Text(String(localized: "\(cluster.members.count) answers")).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                NibField(text: Binding(get: { cluster.label }, set: { label in
                    if let index = clusters.firstIndex(where: { $0.id == cluster.id }) { clusters[index].label = label }
                }), prompt: String(localized: "Cluster name"))
                .accessibilityLabel(String(localized: "Rename \(cluster.label)"))
                .disabled(proposed)
                NibButton(String(localized: "Save Cluster Name"), kind: .plain) { save(clusters) }.disabled(busy || proposed)
                    .accessibilityLabel(String(localized: "Save name for \(cluster.label)"))
                let members = Set(cluster.members)
                let entries = collection.entries.filter { members.contains($0.id) }
                answerGrid(entries, collection: collection)
                VStack(alignment: .leading, spacing: NibSpacing.s) {
                    NibField(text: Binding(get: { scoreText[cluster.id] ?? cluster.score.map(AnswerZoneFormat.number) ?? "" },
                                          set: { scoreText[cluster.id] = $0 }), prompt: String(localized: "Points for this cluster"))
                        .keyboardType(.decimalPad).accessibilityLabel(String(localized: "Score for \(cluster.label)"))
                    NibButton(String(localized: "Score All Answers in Cluster"), symbol: .checkmark, kind: .plain) {
                        let raw = scoreText[cluster.id] ?? cluster.score.map(AnswerZoneFormat.number) ?? ""
                        guard let value = Double(raw.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
                            error = String(localized: "Enter a number of points before scoring this cluster."); return
                        }
                        var next = clusters
                        // Only the chosen group is graded, even if other groups have saved score proposals.
                        for index in next.indices { next[index].score = next[index].id == cluster.id ? value : nil }
                        save(next, scores: true)
                    }.disabled(busy || proposed || entries.isEmpty)
                    .accessibilityLabel(String(localized: "Score all answers in \(cluster.label)"))
                    NibButton(String(localized: "Remove Cluster"), kind: .destructivePlain) {
                        save(clusters.filter { $0.id != cluster.id })
                    }.disabled(busy || proposed)
                    .accessibilityLabel(String(localized: "Remove \(cluster.label)"))
                }
                Divider()
            }
        }
    }

    private func answerGrid(_ entries: [InsightEntry], collection: InsightCollection) -> some View {
        let membership = Dictionary(clusters.flatMap { cluster in cluster.members.map { ($0, cluster.id) } }, uniquingKeysWith: { first, _ in first })
        return LazyVGrid(columns: columns, alignment: .leading, spacing: NibSpacing.xl) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: NibSpacing.s) {
                    InsightThumbnail(entry: entry, app: context.app, session: context.session)
                    Text(entry.student).font(NibFont.headline)
                    if let points = entry.points {
                        Text(String(localized: "Score: \(entry.score.map(AnswerZoneFormat.number) ?? String(localized: "Unscored")) of \(AnswerZoneFormat.number(points))"))
                            .font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                    }
                    NibButton(String(localized: "Open Copy"), kind: .plain) {
                        if let copy = collection.copies.first(where: { $0.id == entry.doc }) { openCopy(copy) }
                    }.disabled(busy)
                    .accessibilityLabel(String(localized: "Open \(entry.student)'s copy"))
                    if view == "question" {
                        Picker(String(localized: "Move answer to cluster"), selection: Binding(get: {
                            membership[entry.id] ?? ""
                        }, set: { group in
                            var next = clusters
                            for index in next.indices {
                                next[index].members.removeAll { $0 == entry.id }
                                if next[index].id == group { next[index].members.append(entry.id) }
                            }
                            save(next)
                        })) {
                            Text(String(localized: "Unassigned")).tag("")
                            ForEach(clusters) { Text($0.label).tag($0.id) }
                        }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget).disabled(busy || proposed)
                        .accessibilityLabel(String(localized: "Cluster for \(entry.student)"))
                    }
                }.accessibilityElement(children: .contain)
            }
        }
    }

    private func selectView(_ value: String, collection: InsightCollection) {
        view = value
        if value == "question", selectedZone.isEmpty { selectedZone = collection.questions.first?.id ?? "" }
        collect()
    }

    private func collect() {
        guard let source, !busy else { return }
        var params: [String: JSONValue] = ["doc": .string(source), "renders": false]
        if let folder = collection?.folder { params["folder"] = .string(folder) }
        if view == "question", !selectedZone.isEmpty { params["zone"] = .string(selectedZone) }
        else if !selectedPage.isEmpty { params["page"] = .string(selectedPage) }
        run(CommandIDs.lessonCollect, .object(params)) { value in
            do {
                let loaded = try value.decode(InsightCollection.self)
                collection = loaded
                selectedPage = loaded.page ?? ""
                if view == "question" { selectedZone = loaded.zone ?? "" }
                clusters = loaded.clusters; savedClusters = loaded.clusters
                modelAnswer = loaded.modelAnswer ?? ""
                proposed = false; revisions = loaded.revisions; scoreText = [:]
                if currentCopy == nil {
                    let active = context.session?.document.map { NodeRef.document($0).description }
                    currentCopy = loaded.copies.first { $0.id == active }?.id
                }
            } catch { self.error = NibError.wrap(error).message }
        }
    }

    private func suggest(_ mode: InsightClusterMode) {
        guard !selectedZone.isEmpty else { return }
        var params: [String: JSONValue] = ["zone": .string(selectedZone), "mode": .string(mode.rawValue)]
        if let folder = collection?.folder { params["folder"] = .string(folder) }
        if !modelAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { params["modelAnswer"] = .string(modelAnswer) }
        run(CommandIDs.lessonCluster, .object(params)) { value in
            do {
                let output = try value.decode(LessonCluster.Output.self)
                clusters = output.clusters; revisions = output.revisions; scoreText = [:]; proposed = true
            } catch { self.error = NibError.wrap(error).message }
        }
    }

    private func save(_ next: [InsightCluster], scores: Bool = false) {
        guard !selectedZone.isEmpty else { return }
        do {
            var params: [String: JSONValue] = ["zone": .string(selectedZone), "clusters": try JSONValue.from(next),
                                               "modelAnswer": .string(modelAnswer), "applyScores": .bool(scores)]
            if let folder = collection?.folder { params["folder"] = .string(folder) }
            if let revisions { params["revisions"] = try JSONValue.from(revisions) }
            run(CommandIDs.lessonSetClusters, .object(params)) { _ in
                receipt = scores ? String(localized: "Cluster scores saved. Undo restores every student copy together.") : String(localized: "Clusters saved.")
                collect()
            }
        } catch { self.error = NibError.wrap(error).message }
    }

    private func openCopy(_ copy: InsightCopy) {
        var params: [String: JSONValue] = ["doc": .string(copy.id)]
        if let page = collection?.page.flatMap({ NodeRef($0)?.pageID }) {
            params["page"] = .string(NodeRef.page(NodeRef.documentID(from: copy.id), page).description)
        }
        run(CommandIDs.docOpen, .object(params)) { _ in currentCopy = copy.id }
    }

    private func teachingMode(_ mode: String) {
        guard let currentCopy else { return }
        run(CommandIDs.lessonSetState, ["doc": .string(currentCopy), "state": .string(mode)]) { value in
            if mode == "present", let session = context.session, let ref = value["ref"]?.stringValue {
                context.app.services.get(InsightRuntime.key, as: InsightRuntime.self)?.rememberPrivate(ref, copy: currentCopy, session: session)
                context.app.ui.setNeedsChromeUpdate(session)
            }
            receipt = mode == "present" ? String(localized: "Present notes stay on this device. Close Class Insights to teach.") : String(localized: "Feedback mode selected. Close Class Insights to write feedback.")
        }
    }

    private func run(_ command: String, _ params: JSONValue, completion: @escaping (JSONValue) -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            do {
                let value = try await context.app.bus.execute(command, params, session: context.session)
                busy = false
                completion(value)
            } catch { busy = false; self.error = NibError.wrap(error).message }
        }
    }
}

@MainActor
private struct InsightThumbnail: View {
    let entry: InsightEntry
    let app: NibApp
    let session: EditorSession?
    var isModel = false
    @State private var image: UIImage?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            NibPageThumbnail(number: 1, isCurrent: false, aspectRatio: CGFloat(entry.region.width / entry.region.height), showsNumber: false) {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if error != nil { Image(nib: .warningTriangle).foregroundStyle(NibColor.warning) }
                else { ProgressView().accessibilityLabel(String(localized: "Rendering answer")) }
            }.accessibilityLabel(isModel ? String(localized: "Model answer") : String(localized: "Answer by \(entry.student)"))
            if let error {
                Text(error).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                NibButton(String(localized: "Render Again"), kind: .plain) { retry += 1 }
                    .accessibilityLabel(isModel ? String(localized: "Render model answer again") : String(localized: "Render \(entry.student)'s answer again"))
            }
        }.task(id: entry.id + entry.revision.description + String(retry)) { await load() }
    }

    private func load() async {
        do {
            let rendered = try await app.bus.execute(CommandIDs.renderPage, ["page": .string(entry.page),
                                                                            "region": try JSONValue.from(entry.region), "scale": 1], session: session)
            guard let raw = rendered["asset"]?.stringValue, raw.hasPrefix("tmp:"), let assets = app.services.assets,
                  let url = assets.temporaryURL(SmartViews.assetRef(raw)) else { throw NibError(.unavailable, "The page image is unavailable. Try rendering it again.") }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            try Task.checkCancellation()
            guard let decoded = UIImage(data: data) else { throw NibError(.unsupported, "The renderer returned an unreadable image.") }
            image = decoded; error = nil
        } catch is CancellationError { }
        catch { self.error = NibError.wrap(error).message }
    }
}
