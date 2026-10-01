import Foundation
import NibContracts

/// Shape-recognition settings (P-040, T-014). Synced: they are preferences that follow the library. Draw and Hold is
/// `NibSettings.drawAndHold` ("shapes.drawAndHold"): the contracts declare it, since the pen, pencil and highlighter
/// read it too; this feature owns the behaviour and declares only the two Draw Shape settings below.
enum ShapeSettings {
    static let snapToOtherShapes = SettingKey("shapes.snapToOtherShapes", default: true, synced: true)
    static let requireHoldToSnap = SettingKey("shapes.requireHoldToSnap", default: false, synced: true)

    static func declare(in settings: SettingsStore, owner: String) {
        settings.declare(snapToOtherShapes, summary: "Snap to Other Shapes: join line ends that land within 12 pt of another shape.",
                         owner: owner, schema: .bool())
        settings.declare(requireHoldToSnap, summary: "Require Hold to Snap: Draw Shape converts only strokes held at the end, not on lift.",
                         owner: owner, schema: .bool())
    }
}

/// `shape.recognize {points, neighbors?}` (read): the recogniser behind Draw and Hold, AutoShape and the AI.
/// Returns `{shape: ShapeItem?, confidence?, mergeWith?: [ref]}` (ARCHITECTURE §6.5): `shape` is the whole ShapeItem
/// (control points, frame, style) or null when the stroke is not a shape. With neighbours and Snap to Other Shapes on,
/// line ends join or snap to them, and `mergeWith` lists the neighbours joined in, which the caller deletes in the
/// same undo group as its `shape.create`.
struct ShapeRecognizeCommand: NibCommand {
    struct Params: Codable {
        var points: [Point]
        /// A page ref (every shape on it), or an array of item refs and/or ShapeItem objects carrying an `id`.
        var neighbors: JSONValue?
    }

    struct Output: Codable, Equatable {
        /// The clean shape, or nil (encoded as `null`) when nothing matched.
        var shape: ShapeItem?
        /// 0…1, how comfortably the stroke passed its shape's error threshold. Present with a shape.
        var confidence: Double?
        /// Neighbours joined into this shape (refs, or the ids given with inline shapes); delete them when you create
        /// it. Present with a shape (empty when nothing was joined).
        var mergeWith: [String]?

        static var noShape: Output { Output(shape: nil, confidence: nil, mergeWith: nil) }

        enum CodingKeys: String, CodingKey { case shape, confidence, mergeWith }

        init(shape: ShapeItem?, confidence: Double?, mergeWith: [String]?) {
            self.shape = shape
            self.confidence = confidence
            self.mergeWith = mergeWith
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shape = try c.decodeIfPresent(ShapeItem.self, forKey: .shape)
            confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
            mergeWith = try c.decodeIfPresent([String].self, forKey: .mergeWith)
        }

        /// `shape` is always written, as `null` when nothing matched, so callers can tell "no shape" from a malformed
        /// answer.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(shape, forKey: .shape)
            try c.encodeIfPresent(confidence, forKey: .confidence)
            try c.encodeIfPresent(mergeWith, forKey: .mergeWith)
        }
    }

    static let maxPoints = 50_000

    static let descriptor = CommandDescriptor(
        id: "shape.recognize", title: String(localized: "Recognise Shape"),
        summary: "Recognise a rough stroke (page points) as a line, arrow, arc, curve, polyline, ellipse, rectangle, triangle or polygon: {shape: ShapeItem or null, confidence, mergeWith}.",
        params: .obj([
            "points": .arr(.point, "the stroke as [[x, y], …] in page points, at least 2"),
            "neighbors": .anything("shapes to snap to: a page ref (its shapes on visible layers; when a window shows the document only unlocked shapes on its active layer are merged, as when drawing), or an array of item refs / ShapeItem objects with an id")
        ], required: ["points"]),
        examples: [
            try! JSONValue.parse(#"{"points": [[100, 100], [260, 102], [259, 190], [101, 188], [100, 101]]}"#),
            try! JSONValue.parse(#"{"points": [[104, 203], [180, 320]], "neighbors": "page:FIXTUREDOC01/FIXTUREPG001"}"#)
        ],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard p.points.count >= 2 else {
            throw NibError(.invalidParams, "a stroke needs at least 2 points", path: "$.points",
                           hint: "pass points as [[x, y], …] in page points")
        }
        guard p.points.count <= maxPoints else {
            throw NibError.invalid("at most \(maxPoints) points", path: "$.points")
        }
        let targets = try neighbours(p.neighbors, ctx)
        guard let found = ShapeRecognizer.recognize(p.points) else { return .noShape }
        var result = SnapResult(shape: found.shape, mergeWith: [])
        if !targets.isEmpty, ctx.services.settings.get(ShapeSettings.snapToOtherShapes) {
            result = ShapeSnapper.snap(found.shape, to: targets)
        }
        return Output(shape: result.shape, confidence: (found.confidence * 100).rounded() / 100,
                      mergeWith: result.mergeWith)
    }

    /// Resolves `neighbors`: a page ref gives the page's shapes the Draw Shape tool would see (none on hidden layers;
    /// only the active layer's merge, when a window shows the document); item refs give those shapes; inline ShapeItem
    /// objects are used as they are (their `id` or `ref` is what `mergeWith` reports). Locked items never merge.
    static func neighbours(_ value: JSONValue?, _ ctx: CommandContext) throws -> [SnapNeighbor] {
        guard let value = value, value != .null else { return [] }
        let entries = value.arrayValue ?? [value]
        var out: [SnapNeighbor] = []
        for (i, entry) in entries.enumerated() {
            let path = value.arrayValue == nil ? "$.neighbors" : "$.neighbors[\(i)]"
            if let string = entry.stringValue {
                switch NodeRef(string) {
                case let .page(doc, page)?:
                    let session = ctx.activeSession.flatMap { $0.document == doc ? $0 : nil }
                    let hidden = session?.hiddenLayers ?? []
                    for item in try ctx.workspace.items(doc, page: page) {
                        guard let shape = item.shape, !hidden.contains(item.layer) else { continue }
                        let mergeable = !item.locked && item.layer == (session?.activeLayer ?? item.layer)
                        out.append(SnapNeighbor(ref: NodeRef.item(doc, page, item.id).description, shape: shape,
                                                mergeable: mergeable))
                    }
                case let .item(doc, page, id)?:
                    let item = try ctx.workspace.item(doc, page: page, id: id)
                    guard let shape = item.shape else {
                        throw NibError.invalid("\(string) is not a shape", path: path)
                    }
                    out.append(SnapNeighbor(ref: string, shape: shape, mergeable: !item.locked))
                default:
                    throw NibError(.invalidParams, "expected a page or item ref", path: path,
                                   hint: "use page:D/P for every shape on a page, or item:D/P/I")
                }
            } else if entry.objectValue != nil {
                let shape: ShapeItem
                do {
                    shape = try entry.decode(ShapeItem.self)
                } catch {
                    throw NibError(.invalidParams, "not a ShapeItem", path: path,
                                   hint: "give at least {\"shape\": \"line\", \"points\": [[x, y], [x, y]], \"id\": \"…\"}")
                }
                let ref = entry["ref"]?.stringValue ?? entry["id"]?.stringValue ?? String(i)
                out.append(SnapNeighbor(ref: ref, shape: shape))
            } else {
                throw NibError.invalid("expected a ref string or a ShapeItem object", path: path)
            }
        }
        return out
    }
}
