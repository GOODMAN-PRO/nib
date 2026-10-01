import Foundation
import UIKit
import NibContracts
import NibDesign

/// Commands share one strict selection boundary. UI never reaches into the workspace.
struct MathSelection {
    var doc: DocumentID
    var page: PageID
    var refs: [String]
    var items: [Item]
    var bounds: Rect { NibFragment.union(items) }

    @MainActor
    static func load(_ refs: [String], _ ctx: CommandContext, strokesOnly: Bool) async throws -> MathSelection {
        guard !refs.isEmpty, refs.count <= 1_000 else {
            throw NibError(.invalidParams, "Select between 1 and 1000 handwriting items", path: "$.refs", hint: "select handwriting or pass item refs")
        }
        var doc: DocumentID?, page: PageID?, items: [Item] = [], seen = Set<ElementID>()
        for ref in refs {
            guard case let .item(d, p, id)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "Math needs item refs", path: "$.refs", hint: "call query.get for the page's items")
            }
            guard (doc == nil || doc == d), (page == nil || page == p), seen.insert(id).inserted else {
                throw NibError(.invalidParams, "Select distinct items on one page", path: "$.refs", hint: "select a single equation on one page")
            }
            if ctx.services.lock?.isLocked(d) == true { throw NibError(.locked, "Unlock the document before converting or copying maths") }
            let item = try ctx.workspace.item(d, page: p, id: id)
            if strokesOnly && (item.kind != .stroke || item.stroke == nil || item.stroke?.style.tool == .tape) {
                throw NibError(.invalidParams, "Math conversion accepts handwriting only", path: "$.refs", hint: "select pen or pencil strokes")
            }
            doc = d; page = p; items.append(item)
        }
        guard let doc, let page else { throw NibError(.invalidParams, "No handwriting was selected", path: "$.refs") }
        return MathSelection(doc: doc, page: page, refs: refs, items: items)
    }

    @MainActor
    func requireEditable(_ ctx: CommandContext) throws {
        guard !ctx.isReadOnly(doc) else { throw NibError(.permissionDenied, "This document is read-only") }
        guard !items.contains(where: \.locked) else { throw NibError(.permissionDenied, "Unlock the selected items before editing them") }
        guard Set(items.map(\.layer)).count == 1 else {
            throw NibError(.invalidParams, "Select handwriting on one layer", path: "$.refs", hint: "convert each layer separately")
        }
    }

    @MainActor
    func requireUnchanged(_ tx: DocTransaction) throws {
        for item in items {
            let current = try tx.item(doc, page: page, id: item.id)
            guard current == item else { throw NibError(.conflict, "The handwriting changed during recognition", hint: "recognise the selection again") }
        }
    }
}

struct MathRecognize: NibCommand {
    struct Params: Codable { var refs: [String] }
    static let descriptor = CommandDescriptor(id: CommandIDs.mathRecognize, title: String(localized: "Recognise Maths"),
        summary: "Recognise selected handwriting as editable LaTeX lines, using your vision provider or on-device recognition.",
        params: .obj(["refs": .arr(.ref)], required: ["refs"]),
        examples: [["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"]]], effect: .read, sensitive: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> MathRecognition {
        let selection = try await MathSelection.load(p.refs, ctx, strokesOnly: true)
        return try await MathRecognizer.recognize(selection, ctx)
    }
}

struct MathConvert: NibCommand {
    struct Params: Codable { var refs: [String]; var latex: [String]?; var id: String?; var revs: [Rev]? = nil }
    struct Output: Codable { var ref: String; var lines: [String] }
    static let descriptor = CommandDescriptor(id: CommandIDs.mathConvert, title: String(localized: "Convert to Maths"),
        summary: "Replace selected handwriting with a math object, retaining the original ink. latex is an array of LaTeX lines; id chooses its ID; optional revs guards against ink changed since recognition.",
        params: .obj(["refs": .arr(.ref), "latex": .arr(.str()), "id": .str(), "revs": .arr(.str("Recognised item revision, in the same order as refs"))], required: ["refs"]),
        examples: [["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"], "latex": ["x^{2}+1"], "id": "MATHCONVERT01"]], effect: .edit)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let selection = try await MathSelection.load(p.refs, ctx, strokesOnly: true)
        try selection.requireEditable(ctx)
        let id = p.id.map { NibID($0) } ?? NibID.make()
        guard NibID.isValid(id.raw) else { throw NibError(.invalidParams, "Invalid math object ID", path: "$.id", hint: "use 1 to 64 letters, digits, underscores or hyphens") }
        let lines: [String]
        if let explicit = p.latex { lines = explicit }
        else {
            // The nested sensitive read applies the gateway's provider disclosure to every principal.
            lines = try await ctx.execute(MathRecognize.self, MathRecognize.Params(refs: p.refs)).lines
        }
        let color = selection.items.first?.stroke?.style.color ?? RGBA(NibInk.carbon.uiColor)
        let natural = try await Task.detached(priority: .userInitiated) {
            try MathTypesetter.shared.image(lines: lines, color: color, scale: 1).size
        }.value
        let width = max(1, selection.bounds.width)
        let height = max(1, width * Double(natural.height / max(1, natural.width)))
        guard width.isFinite, height.isFinite else { throw NibError(.invalidParams, "The handwriting has invalid bounds", path: "$.refs") }
        let math = MathItem(frame: Frame(x: selection.bounds.x, y: selection.bounds.y, w: width, h: height),
                            latex: lines, color: color, sourceInk: selection.items.compactMap(\.stroke))
        if let revs = p.revs, revs.count != selection.items.count {
            throw NibError(.invalidParams, "Pass one recognised revision per ref", path: "$.revs")
        }
        try ctx.mutate { tx in
            if let revs = p.revs {
                for (index, item) in selection.items.enumerated() {
                    guard try tx.item(selection.doc, page: selection.page, id: item.id).rev == revs[index] else {
                        throw NibError(.conflict, "The handwriting changed since recognition", hint: "recognise the selection again")
                    }
                }
            }
            try selection.requireEditable(ctx)
            try selection.requireUnchanged(tx)
            guard !(try ctx.workspace.allItems(selection.doc, page: selection.page)).contains(where: { $0.id == id }) else {
                throw NibError(.conflict, "That math object ID already exists", path: "$.id", hint: "choose a new id")
            }
            let parent = selection.items[0].attachedTo
            let sharedParent = selection.items.allSatisfy { $0.attachedTo == parent } ? parent : nil
            let item = Item(id: id, kind: .math, z: selection.items.map(\.z).max() ?? "", layer: selection.items[0].layer,
                            attachedTo: sharedParent, math: math)
            // References to converted ink follow the new math object, preserving attachment invariants.
            let oldIDs = Set(selection.items.map(\.id))
            for var other in try tx.items(selection.doc, page: selection.page) where !oldIDs.contains(other.id) {
                var changed = false
                if let parent = other.attachedTo, oldIDs.contains(parent) { other.attachedTo = id; changed = true }
                if var connector = other.connector {
                    if let target = connector.from.item, oldIDs.contains(target) { connector.from.item = id; changed = true }
                    if let target = connector.to.item, oldIDs.contains(target) { connector.to.item = id; changed = true }
                    other.connector = connector
                }
                if changed { try tx.put(other, doc: selection.doc, page: selection.page) }
            }
            try tx.delete(items: selection.items.map(\.id), doc: selection.doc, page: selection.page)
            try tx.put(item, doc: selection.doc, page: selection.page)
        }
        if !ctx.dryRun, ctx.principal.isUser, let session = ctx.session,
           session.document == selection.doc, session.page == selection.page {
            session.selection = Selection(doc: selection.doc, page: selection.page, items: [id], bounds: math.frame.bounds)
        }
        return Output(ref: NodeRef.item(selection.doc, selection.page, id).description, lines: lines)
    }
}

struct MathSetLatex: NibCommand {
    struct Params: Codable { var ref: String; var lines: [String] }
    static let descriptor = CommandDescriptor(id: CommandIDs.mathSetLatex, title: String(localized: "Edit LaTeX"),
        summary: "Replace a math object's LaTeX lines while preserving its colour, position, width, rotation and original handwriting, and fitting its height to the formula.",
        params: .obj(["ref": .ref, "lines": .arr(.str())], required: ["ref", "lines"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREMTH01", "lines": ["\\frac{a}{b}", "x^{2}"]]], effect: .edit)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let selection = try await MathSelection.load([p.ref], ctx, strokesOnly: false)
        try selection.requireEditable(ctx)
        var item = selection.items[0]
        guard var math = item.math else { throw NibError(.invalidParams, "Select a math object", path: "$.ref", hint: "call query.get to inspect the item kind") }
        let color = math.color
        let natural = try await Task.detached(priority: .userInitiated) {
            try MathTypesetter.shared.image(lines: p.lines, color: color, scale: 1).size
        }.value
        math.frame.h = math.frame.w * natural.height / natural.width
        math.latex = p.lines; item.math = math
        try ctx.mutate { tx in
            try selection.requireEditable(ctx)
            try selection.requireUnchanged(tx)
            try tx.put(item, doc: selection.doc, page: selection.page)
        }
        return NoResult()
    }
}

struct MathCopy: NibCommand {
    struct Params: Codable { var ref: String; var `as`: String }
    struct Output: Codable {
        var format: String
        var latex: String?
        var lines: [String]?
        var asset: String?
        var fragment: NibFragment?
    }
    static let descriptor = CommandDescriptor(id: CommandIDs.mathCopy, title: String(localized: "Copy Maths"),
        summary: "Return a math object as LaTeX, a temporary PNG asset, or its original nib-fragment/1 handwriting.",
        params: .obj(["ref": .ref, "as": .str(choices: ["latex", "image", "handwriting"])], required: ["ref", "as"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREMTH01", "as": "latex"]], effect: .read)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let selection = try await MathSelection.load([p.ref], ctx, strokesOnly: false)
        guard let math = selection.items[0].math else { throw NibError(.invalidParams, "Select a math object", path: "$.ref", hint: "call query.get for math items") }
        switch p.as {
        case "latex": return Output(format: "latex", latex: math.latex.joined(separator: "\n"), lines: math.latex)
        case "image":
            guard let assets = ctx.services.assets else { throw NibError.unavailable("The asset store is not installed") }
            let data = try await Task.detached(priority: .userInitiated) {
                let natural = try MathTypesetter.shared.image(lines: math.latex, color: math.color, scale: 1)
                let density = 2 * min(math.frame.w / max(1, natural.size.width), math.frame.h / max(1, natural.size.height))
                let image = try MathTypesetter.shared.image(lines: math.latex, color: math.color, scale: density)
                guard let data = image.pngData() else { throw NibError(.internalError, "The formula could not be encoded") }
                return data
            }.value
            let asset = try assets.putTemporary(data, ext: "png")
            return Output(format: "image", asset: "tmp:" + asset.name)
        case "handwriting":
            guard let strokes = math.sourceInk, !strokes.isEmpty else {
                throw NibError.unavailable(String(localized: "This math object has no original handwriting"))
            }
            let items = strokes.map { Item(kind: .stroke, layer: selection.items[0].layer, stroke: $0) }
            let fragment = NibFragment.make(items: items) { ref in try? ctx.services.assets?.data(ref, doc: selection.doc) }
            return Output(format: "handwriting", fragment: fragment)
        default: throw NibError(.invalidParams, "Choose latex, image or handwriting", path: "$.as", hint: "call commands.describe for math.copy")
        }
    }
}
