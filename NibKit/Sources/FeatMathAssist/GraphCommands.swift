import Foundation
import NibContracts
import NibDesign

@MainActor
enum GraphCommands {
    static let panelID = "mathgraph.editor"

    static func ensureWritable(_ doc: DocumentID, _ ctx: CommandContext) throws {
        guard !ctx.isReadOnly(doc), ctx.activeSession?.document != doc || ctx.activeSession?.readOnly != true else {
            throw NibError(.permissionDenied, "This document is read-only.")
        }
    }

    static func item(_ ref: String, _ ctx: CommandContext) throws -> (DocumentID, PageID, Item, CustomItem) {
        guard case let .item(doc, page, id)? = NodeRef(ref) else {
            throw GraphBuilder.invalid("Use an item ref for a graph.", path: "$.ref")
        }
        let item = try ctx.workspace.item(doc, page: page, id: id)
        guard item.kind == .custom, let custom = item.custom,
              custom.owner == GraphBuilder.owner, custom.type == GraphBuilder.type else {
            throw NibError(.unsupported, "This item is not a Nib maths graph.", path: "$.ref",
                           hint: "Call math.graph.create to insert a graph, then use its returned ref.")
        }
        return (doc, page, item, custom)
    }

    static func open(_ params: JSONValue, _ ctx: CommandContext) async throws -> JSONValue {
        guard !ctx.dryRun else { return ["handled": true] }
        guard ctx.ui != nil else { throw NibError.unavailable("the graph editor") }
        _ = try await ctx.execute(CommandIDs.panelOpen, params.merging(["id": .string(panelID)]))
        return ["handled": true]
    }
}

struct GraphCreate: NibCommand {
    struct Params: Codable {
        var page: String?
        var expressions: [String]?
        var rect: [Double]?
        var id: String?
    }
    typealias Output = JSONValue

    static let descriptor = CommandDescriptor(
        id: CommandIDs.mathGraphCreate, title: String(localized: "Insert Graph"),
        summary: "Insert a 2D graph from expressions (x^2, y=sin(x), f(x)=x^3); honours id. Omit expressions to open the graph editor.",
        params: .obj(["page": .ref, "expressions": .arr(.str(), "1–8 explicit functions of x"),
                      "rect": .rect, "id": .str("Caller-chosen item id")]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "expressions": ["y=x^2", "sin(x)"]]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let (doc, page) = try ctx.pageOrSession(p.page)
        try GraphCommands.ensureWritable(doc, ctx)
        guard let record = try ctx.workspace.content(doc).page(page) else { throw NibError.notFound("page \(page)") }
        guard let expressions = p.expressions else {
            var params: JSONValue = ["page": .string(NodeRef.page(doc, page).description)]
            if let r = p.rect { params = params.merging(["rect": try JSONValue.from(r)]) }
            if let id = p.id { params = params.merging(["itemID": .string(id)]) }
            return try await GraphCommands.open(params, ctx)
        }
        let defaultWidth = min(400, record.size?.width ?? 400)
        let defaultHeight = min(280, record.size?.height ?? 280)
        let frame: Frame
        if let rect = p.rect {
            guard rect.count == 4, let parsed = Frame(array: rect) else {
                throw GraphBuilder.invalid("Rect must contain [x, y, width, height].", path: "$.rect")
            }
            frame = parsed
        } else {
            let visible = ctx.activeSession?.document == doc && ctx.activeSession?.page == page
                ? ctx.activeSession?.visibleRect : nil
            frame = Frame(x: visible?.midX ?? ((record.size?.width ?? defaultWidth) / 2),
                          y: visible?.midY ?? ((record.size?.height ?? defaultHeight) / 2),
                          w: defaultWidth, h: defaultHeight)
            // Frame coordinates refer to its top-left, not its centre.
        }
        var placed = frame
        if p.rect == nil { placed.x -= placed.w / 2; placed.y -= placed.h / 2 }
        let id = p.id.map { NibID($0) } ?? NibID.make()
        guard !id.raw.isEmpty, !id.raw.contains("/"), !id.raw.contains(":") else {
            throw GraphBuilder.invalid("Use a non-empty item id without / or :.", path: "$.id")
        }
        func checkID() throws {
            for existingPage in try ctx.workspace.content(doc).pages {
                if try ctx.workspace.allItems(doc, page: existingPage.id).contains(where: { $0.id == id }) {
                    throw NibError(.conflict, "The item id is already in use.", path: "$.id", hint: "Choose a new id or edit the existing graph with math.graph.setViewport.")
                }
            }
        }
        try checkID()
        let viewport = GraphViewport()
        let snapshotFrame = placed
        let display = try await MathStack.perform {
            try GraphBuilder.build(expressions: expressions, frame: snapshotFrame, viewport: viewport)
        }
        try Task.checkCancellation()
        try GraphCommands.ensureWritable(doc, ctx)
        try checkID() // Another command may have claimed the id while sampling.
        let custom = CustomItem(owner: GraphBuilder.owner, type: GraphBuilder.type, frame: placed,
                                data: try JSONValue.from(GraphData(expressions: expressions, viewport: viewport)), display: display)
        let layer = ctx.activeSession?.document == doc ? (ctx.activeSession?.activeLayer ?? 0) : 0
        try ctx.mutate { tx in
            _ = try tx.put(Item(id: id, kind: .custom, layer: layer, custom: custom), doc: doc, page: page)
        }
        return ["ref": .string(NodeRef.item(doc, page, id).description)]
    }
}

struct GraphSetViewport: NibCommand {
    struct Params: Codable {
        var ref: String
        var x: Double?
        var y: Double?
        var scale: Double?
        // The catalogue has no graph-expression edit id. Keep the edit API on this existing owned command.
        var expressions: [String]?
        var gesture: String?
        var revision: String?
    }
    typealias Output = JSONValue

    static let descriptor = CommandDescriptor(
        id: CommandIDs.mathGraphSetViewport, title: String(localized: "Edit Graph"),
        summary: "Pan/zoom a graph: ref, centre x/y, scale in points per unit. Optional expressions replace its curves. Ref alone opens its editor.",
        params: .obj(["ref": .ref, "x": .num("Centre x", min: -1e12, max: 1e12),
                      "y": .num("Centre y", min: -1e12, max: 1e12),
                      "scale": .num("Points per unit", min: GraphViewport.scaleRange.lowerBound, max: GraphViewport.scaleRange.upperBound),
                      "expressions": .arr(.str(), "Replace the explicit functions of x"),
                      "gesture": .str(choices: ["tap", "doubleTap", "longPress"]),
                      "revision": .str("Optional query.get revision; rejects a stale editor save")], required: ["ref"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECUS01", "x": 0, "y": 0, "scale": 32]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let (doc, page, original, custom) = try GraphCommands.item(p.ref, ctx)
        try GraphCommands.ensureWritable(doc, ctx)
        let supplied = [p.x, p.y, p.scale].compactMap { $0 }.count
        guard supplied == 0 || supplied == 3 else {
            throw GraphBuilder.invalid("Supply x, y and scale together.", path: "$.scale")
        }
        if supplied == 0, p.expressions == nil {
            return try await GraphCommands.open(["ref": .string(p.ref)], ctx)
        }
        if let revision = p.revision, revision != original.rev.description {
            throw NibError(.conflict, "The graph changed while its editor was open.", hint: "Close and reopen the graph editor before saving.")
        }
        var data: GraphData
        do { data = try custom.data.decode(GraphData.self) }
        catch { throw GraphBuilder.invalid("The graph's stored data is invalid.", path: "$.ref") }
        if let x = p.x, let y = p.y, let scale = p.scale { data.viewport = GraphViewport(x: x, y: y, scale: scale) }
        if let expressions = p.expressions { data.expressions = expressions }
        let snapshot = data
        let display = try await MathStack.perform {
            try GraphBuilder.build(expressions: snapshot.expressions, frame: custom.frame, viewport: snapshot.viewport)
        }
        try Task.checkCancellation()
        try GraphCommands.ensureWritable(doc, ctx)
        try ctx.mutate { tx in
            var item = try tx.item(doc, page: page, id: original.id)
            guard item.rev == original.rev else {
                throw NibError(.conflict, "The graph changed during rendering.", hint: "Read the graph with query.get, then retry math.graph.setViewport.")
            }
            var updated = custom
            updated.data = try JSONValue.from(data)
            updated.display = display
            item.custom = updated
            _ = try tx.put(item, doc: doc, page: page)
        }
        return ["ref": .string(p.ref), "handled": true, "viewport": try JSONValue.from(data.viewport)]
    }
}
