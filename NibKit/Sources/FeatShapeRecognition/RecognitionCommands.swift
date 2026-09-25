import Foundation
import NibContracts

/// Shape-recognition settings (P-040, T-014). Synced: they are preferences that follow the library. The pen and
/// pencil (F007) read `shapes.drawAndHold` for their own Draw and Hold.
enum ShapeSettings {
    static let drawAndHold = SettingKey("shapes.drawAndHold", default: true, synced: true)
    static let snapToOtherShapes = SettingKey("shapes.snapToOtherShapes", default: true, synced: true)
    static let requireHoldToSnap = SettingKey("shapes.requireHoldToSnap", default: false, synced: true)

    static func declare(in settings: SettingsStore, owner: String) {
        settings.declare(drawAndHold, summary: "Draw and Hold: pause at the end of a stroke to snap it to a shape (pen, pencil, Draw Shape).",
                         owner: owner, schema: .bool())
        settings.declare(snapToOtherShapes, summary: "Snap to Other Shapes: join line ends that land within 12 pt of another shape.",
                         owner: owner, schema: .bool())
        settings.declare(requireHoldToSnap, summary: "Require Hold to Snap: Draw Shape converts only strokes held at the end, not on lift.",
                         owner: owner, schema: .bool())
    }
}

/// `shape.recognize {points, neighbors?}` (read): the recogniser behind Draw and Hold, AutoShape and the AI.
/// Returns the ShapeItem fields (so the value decodes as a `ShapeItem`) plus `confidence` and `mergeWith`, or null
/// when the stroke is not a shape. With neighbours and Snap to Other Shapes on, line ends join or snap to them.
struct ShapeRecognizeCommand: NibCommand {
    typealias Output = Recognized?

    struct Params: Codable {
        var points: [Point]
        /// A page ref (every shape on it), or an array of item refs and/or ShapeItem objects carrying an `id`.
        var neighbors: JSONValue?
    }

    struct Recognized: Codable, Equatable {
        var shape: ShapeKind
        var frame: Frame
        var points: [Point]
        var style: ShapeItemStyle
        /// 0…1, how comfortably the stroke passed its shape's error threshold.
        var confidence: Double
        /// Neighbours joined into this shape (refs, or the ids given with inline shapes); delete them when you create it.
        var mergeWith: [String]
    }

    static let maxPoints = 50_000

    static let descriptor = CommandDescriptor(
        id: "shape.recognize", title: String(localized: "Recognise Shape"),
        summary: "Recognise a rough stroke (page points) as a line, arrow, arc, curve, polyline, ellipse, rectangle, triangle or polygon: ShapeItem JSON + mergeWith, or null.",
        params: .obj([
            "points": .arr(.point, "the stroke as [[x, y], …] in page points, at least 2"),
            "neighbors": .anything("shapes to snap to: a page ref (all its shapes), or an array of item refs / ShapeItem objects with an id")
        ], required: ["points"]),
        examples: [
            try! JSONValue.parse(#"{"points": [[100, 100], [260, 102], [259, 190], [101, 188], [100, 101]]}"#),
            try! JSONValue.parse(#"{"points": [[104, 203], [180, 320]], "neighbors": "page:FIXTUREDOC01/FIXTUREPG001"}"#)
        ],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Recognized? {
        guard p.points.count >= 2 else {
            throw NibError(.invalidParams, "a stroke needs at least 2 points", path: "$.points",
                           hint: "pass points as [[x, y], …] in page points")
        }
        guard p.points.count <= maxPoints else {
            throw NibError.invalid("at most \(maxPoints) points", path: "$.points")
        }
        let targets = try neighbours(p.neighbors, ctx)
        guard let found = ShapeRecognizer.recognize(p.points) else { return nil }
        var result = SnapResult(shape: found.shape, mergeWith: [])
        if !targets.isEmpty, ctx.services.settings.get(ShapeSettings.snapToOtherShapes) {
            result = ShapeSnapper.snap(found.shape, to: targets)
        }
        let s = result.shape
        return Recognized(shape: s.shape, frame: s.frame, points: s.points, style: s.style,
                          confidence: (found.confidence * 100).rounded() / 100, mergeWith: result.mergeWith)
    }

    /// Resolves `neighbors`: a page ref gives every shape on the page; item refs give those shapes; inline ShapeItem
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
                    for item in try ctx.workspace.items(doc, page: page) {
                        guard let shape = item.shape else { continue }
                        out.append(SnapNeighbor(ref: NodeRef.item(doc, page, item.id).description, shape: shape,
                                                mergeable: !item.locked))
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
