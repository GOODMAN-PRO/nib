import Foundation
import NibContracts

struct LessonCollect: NibCommand {
    struct Params: Codable {
        var doc: String
        var zone: String?
        var page: String?
        var folder: String?
        var renders: Bool?
    }
    static let descriptor = CommandDescriptor(
        id: "lesson.collect", title: String(localized: "Collect Student Answers"),
        summary: "Collect student copies by page or answer zone; renders defaults to true and uses render.page. Includes the source model answer, saved clusters and missing copies.",
        params: .obj(["doc": .ref, "zone": .ref, "page": .ref, "folder": .ref, "renders": .bool("false collects metadata without rendering")], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01", "renders": false]], effect: .read,
        extraScopes: [.libraryRead])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> InsightCollection {
        var collection = try SmartViews.collect(doc: p.doc, zone: p.zone, page: p.page, folder: p.folder, ctx: ctx)
        if p.renders != false {
            for index in collection.entries.indices {
                try Task.checkCancellation()
                collection.entries[index].asset = try await SmartViews.render(collection.entries[index], ctx: ctx)
            }
            if let model = collection.model {
                collection.model?.asset = try await SmartViews.render(model, ctx: ctx)
            }
        }
        if ctx.principal.isUser, !ctx.dryRun, let session = ctx.activeSession, let runtime = ctx.services.get(InsightRuntime.key, as: InsightRuntime.self) {
            runtime.update(collection, session: session)
            ctx.ui?.setNeedsChromeUpdate(session)
        }
        return collection
    }
}

struct LessonCluster: NibCommand {
    struct Params: Codable { var zone: String; var mode: InsightClusterMode; var modelAnswer: String?; var folder: String? }
    struct Output: Codable {
        var zone: String
        var clusters: [InsightCluster]
        var modelAnswer: String?
        var revisions: [String: Rev]
        var folder: String?
    }
    static let descriptor = CommandDescriptor(
        id: "lesson.cluster", title: String(localized: "Suggest Answer Clusters"),
        summary: "Suggest answer clusters using your AI, by similarity or modelAnswer (optional modelAnswer text, otherwise the source zone). Read only; review then save with lesson.setClusters.",
        params: .obj(["zone": .ref, "folder": .ref, "mode": .str(choices: InsightClusterMode.allCases.map(\.rawValue)),
                      "modelAnswer": .str("teacher model answer; at most 10,000 characters")], required: ["zone", "mode"]),
        examples: [["zone": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECUS01", "mode": "similarity"]],
        effect: .read, extraScopes: [.libraryRead, .ai, .network], sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let explicitAnswer = try SmartViews.modelAnswer(p.modelAnswer)
        guard let ref = NodeRef(p.zone), case .item(let doc, _, _) = ref else {
            throw SmartViews.invalid("Choose an answer zone.", path: "$.zone")
        }
        let ai = try ctx.services.require(ctx.services.ai, "AI provider")
        guard ai.isConfigured else { throw NibError(.unavailable, "Connect your model in Settings before suggesting clusters.") }
        var collection = try SmartViews.collect(doc: doc.raw, zone: p.zone, page: nil, folder: p.folder, ctx: ctx)
        let answer = try SmartViews.modelAnswer(explicitAnswer ?? collection.modelAnswer)
        guard !collection.entries.isEmpty else { throw NibError(.notFound, "This question has no student copies. Publish a lesson first.") }
        guard collection.missing.isEmpty else { throw NibError(.conflict, "Some student answers are unavailable. Resolve the missing copies before suggesting clusters.") }
        if p.mode == .modelAnswer, answer == nil, collection.model?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           collection.model?.hasInk != true {
            throw SmartViews.invalid("Enter a model answer or write it in the source question before comparing answers.", path: "$.modelAnswer")
        }
        let sourceText = collection.model?.text.nilIfEmpty
        let needsImages = collection.entries.contains(where: \.hasInk) || (p.mode == .modelAnswer && answer == nil && sourceText == nil)
        if needsImages && !ai.supportsVision {
            throw NibError(.unsupported, "This question needs a model that can read images. Connect a vision model or use manual clusters.")
        }
        if needsImages {
            let count = collection.entries.count + (p.mode == .modelAnswer && answer == nil && sourceText == nil ? 1 : 0)
            guard count <= 100 else { throw NibError(.unsupported, "This question exceeds the 100-image limit. Use manual clusters for this class.") }
            for index in collection.entries.indices {
                collection.entries[index].asset = try await SmartViews.render(collection.entries[index], ctx: ctx)
            }
            if p.mode == .modelAnswer && answer == nil && sourceText == nil, let model = collection.model {
                collection.model?.asset = try await SmartViews.render(model, ctx: ctx)
            }
        }
        let modelText = answer ?? (p.mode == .modelAnswer ? sourceText : nil)
        if p.mode == .modelAnswer, modelText == nil, collection.model?.asset == nil {
            throw NibError(.invalidParams, "Enter a model answer before comparing this question.", path: "$.modelAnswer", hint: "pass modelAnswer text or write an answer in the source zone")
        }
        var images = collection.entries.compactMap(\.asset).map(SmartViews.assetRef)
        if p.mode == .modelAnswer && modelText == nil, let asset = collection.model?.asset { images.append(SmartViews.assetRef(asset)) }
        let prompt = try ClusterEngine.prompt(entries: collection.entries, mode: p.mode, modelAnswer: modelText)
        let request = AIRequest(system: "You help a teacher review answers. Return JSON only. Clustering is advisory and must never change a document.",
                                messages: [AIMessage(role: "user", text: prompt, images: images.isEmpty ? nil : images)],
                                tools: [], mode: .ask, scope: AIScope(kind: .page, doc: NodeRef(collection.source)?.documentID,
                                                                    page: ref.pageID, refs: [collection.zone ?? p.zone]),
                                principal: ctx.principal, group: ctx.group, maxSteps: 1, jsonOutput: true)
        let response = try await ai.complete(request)
        try Task.checkCancellation()
        let clusters = try ClusterEngine.parse(response.text, entries: collection.entries, mode: p.mode)
        let current = try SmartViews.collect(doc: collection.source, zone: collection.zone, page: nil, folder: collection.folder, ctx: ctx)
        guard current.revisions == collection.revisions else { throw NibError(.conflict, "Student answers changed while the model was working. Collect them again.") }
        return Output(zone: collection.zone ?? p.zone, clusters: clusters, modelAnswer: answer, revisions: collection.revisions, folder: collection.folder)
    }
}

struct LessonSetClusters: NibCommand {
    struct Params: Codable {
        var zone: String
        var clusters: [InsightCluster]
        var modelAnswer: String?
        var folder: String?
        var revisions: [String: Rev]?
        /// Applies explicit teacher scores only. AI suggestions never call this command themselves.
        var applyScores: Bool?
    }
    struct Output: Codable { var zone: String; var clusters: [InsightCluster]; var scored: [String] }
    static let descriptor = CommandDescriptor(
        id: "lesson.setClusters", title: String(localized: "Save Answer Clusters"),
        summary: "Save manual or reviewed clusters for a question. applyScores applies explicit cluster scores through answerZone.score in one linked undo step; revisions prevents stale grading.",
        params: .obj(["zone": .ref, "folder": .ref, "clusters": .arr(.obj([
            "id": .str(), "label": .str(), "members": .arr(.ref), "score": .num(min: 0, max: AnswerZone.maxPoints)
        ], required: ["id", "label", "members"])), "modelAnswer": .str(), "revisions": .anything("answer ref to revision map from lesson.cluster"),
                      "applyScores": .bool()], required: ["zone", "clusters"]),
        examples: [["zone": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECUS01", "clusters": []]],
        effect: .edit, extraScopes: [.libraryRead])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let collection = try SmartViews.collect(doc: NodeRef.documentID(from: p.zone).raw, zone: p.zone, page: nil, folder: p.folder, ctx: ctx)
        let answer = try SmartViews.modelAnswer(p.modelAnswer ?? collection.modelAnswer)
        try ClusterEngine.validate(p.clusters, entries: collection.entries)
        if let revisions = p.revisions, revisions != collection.revisions {
            throw NibError(.conflict, "Student answers changed after this preview. Collect them again before saving or scoring.")
        }
        guard let model = collection.model, case .item(let doc, _, _)? = NodeRef(model.id) else {
            throw NibError(.notFound, "The source question is unavailable.")
        }
        try LessonManager.writable(doc, ctx)
        var calls: [(String, Double)] = []
        if p.applyScores == true {
            for cluster in p.clusters {
                guard let score = cluster.score else { continue }
                for member in cluster.members {
                    guard let d = NodeRef(member)?.documentID else { throw ClusterEngine.invalid("Invalid answer ref.") }
                    try LessonManager.writable(d, ctx)
                    calls.append((member, score))
                }
            }
            // Complete permission preflight before any cluster or score is written.
            for (ref, score) in calls {
                try await ctx.bus.gateway.authorize(AnswerZoneScore.descriptor, params: ["ref": .string(ref), "score": .number(score)],
                                                     principal: ctx.principal, group: ctx.group, inheritedPolicy: ctx.inheritedPolicy)
            }
            let current = try SmartViews.collect(doc: collection.source, zone: collection.zone, page: nil, folder: collection.folder, ctx: ctx)
            guard current.revisions == collection.revisions else { throw NibError(.conflict, "Answers changed during grading approval. Collect them again.") }
        }
        if !ctx.dryRun { ctx.linkUndoAcrossDocuments() }
        var written: [DocumentID] = []
        do {
            for (ref, score) in calls {
                let target = NodeRef.documentID(from: ref)
                // Include the attempted document: a post-command hook may fail after its commit.
                if !written.contains(target) { written.append(target) }
                _ = try await ctx.execute(CommandIDs.answerZoneScore, ["ref": .string(ref), "score": .number(score)])
            }
            if !written.contains(doc) { written.append(doc) }
            try ctx.mutate { tx in
                var meta = try ctx.workspace.content(doc).meta
                var teacher = meta.ext?[LessonManager.rosterKey]?.objectValue ?? [:]
                var records = teacher[ClusterEngine.recordKey]?.objectValue ?? [:]
                var scopes = records[model.id]?.objectValue ?? [:]
                scopes[collection.folder ?? "*"] = try JSONValue.from(InsightClusterRecord(clusters: p.clusters, modelAnswer: answer))
                records[model.id] = .object(scopes)
                // Migrate earlier records into the stripped metadata namespace before future publication.
                for record in try ctx.workspace.content(doc).livePages {
                    for var item in try ctx.workspace.items(doc, page: record.id) {
                        guard var custom = item.custom, var data = custom.data.objectValue,
                              let legacy = data.removeValue(forKey: ClusterEngine.recordKey) else { continue }
                        let key = NodeRef.item(doc, record.id, item.id).description
                        var legacyScopes = records[key]?.objectValue ?? [:]
                        if legacyScopes["*"] == nil { legacyScopes["*"] = legacy }
                        records[key] = .object(legacyScopes)
                        custom.data = .object(data); item.custom = custom
                        try tx.put(item, doc: doc, page: record.id)
                    }
                }
                teacher[ClusterEngine.recordKey] = .object(records)
                meta.ext = meta.ext ?? [:]
                // lesson.create removes the entire teacher-only roster namespace before publishing.
                meta.ext?[LessonManager.rosterKey] = .object(teacher)
                try tx.putMeta(meta)
            }
        } catch {
            if !ctx.dryRun {
                for target in written.reversed() { _ = ctx.bus.revert(group: ctx.group, doc: target, principal: ctx.principal) }
            }
            throw error
        }
        return Output(zone: model.id, clusters: p.clusters, scored: calls.map { $0.0 })
    }
}

private extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
