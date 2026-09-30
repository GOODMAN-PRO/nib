import Foundation

/// contracts-v2: the clipboard, drag-and-drop, element and board-template format "nib-fragment/1" (UTI
/// `app.nib.fragment`): `{"format": "nib-fragment/1", "items": [Item], "assets": {name: base64}, "bounds": [x, y, w, h]}`.
/// Items keep their source ids, z keys and page geometry; `instantiated` re-mints ids, re-assigns z and remaps
/// `attachedTo`, connector anchors and asset names when the fragment lands on a page. Shared by clipboard (F014),
/// elements (F035), board templates (F044), content packs and plugins, so nobody keeps a byte-compatible copy.
public struct NibFragment: Equatable {
    public static let format = "nib-fragment/1"
    public static let typeIdentifier = "app.nib.fragment"

    public var items: [Item]
    /// Asset bytes keyed by the asset name the items reference.
    public var assets: [String: Data]
    public var bounds: Rect

    public init(items: [Item], assets: [String: Data] = [:], bounds: Rect? = nil) {
        self.items = items
        self.assets = assets
        self.bounds = bounds ?? NibFragment.union(items)
    }

    // MARK: Building

    /// A fragment of `items` (provenance and revisions stripped) carrying the bytes of every asset they reference.
    public static func make(items: [Item], assetData: (AssetRef) -> Data?) -> NibFragment {
        var assets: [String: Data] = [:]
        var clean: [Item] = []
        clean.reserveCapacity(items.count)
        for item in items {
            var n = item
            n.rev = .zero
            n.createdBy = nil
            n.deleted = false
            for ref in NibFragment.assetRefs(n) where assets[ref.name] == nil {
                if let data = assetData(ref) { assets[ref.name] = data }
            }
            clean.append(n)
        }
        return NibFragment(items: clean, assets: assets)
    }

    /// The live items `ids` (in that order), then every item attached to them, so a container carries its contents.
    /// Comments pinned to an item stay behind: they discuss the object, they are not part of it.
    public static func expand(_ ids: [ElementID], in pageItems: [Item]) -> [Item] {
        let live = pageItems.filter { !$0.deleted }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen = Set<ElementID>()
        var out: [Item] = []
        for id in ids {
            if let item = byID[id], chosen.insert(id).inserted { out.append(item) }
        }
        var grew = !out.isEmpty
        while grew {
            grew = false
            for item in live where item.kind != .comment && !chosen.contains(item.id) {
                if let parent = item.attachedTo, chosen.contains(parent) {
                    chosen.insert(item.id)
                    out.append(item)
                    grew = true
                }
            }
        }
        return out
    }

    // MARK: Landing on a page

    /// The items ready to write: new ids (`ids` in creation order, the rest minted), z keys above `zAfter` in the
    /// fragment's own z order, geometry moved by `translate`, references remapped (`attachedTo` and connector anchors
    /// that point outside the fragment are dropped, keeping the connector end where it is), asset names mapped
    /// through `assetMap`, and `layer` applied when given. Attachment loops from untrusted JSON are broken.
    public func instantiated(translate d: Point, ids: [NibID] = [], zAfter: String?, layer: Int?,
                             assets assetMap: [String: AssetRef] = [:]) -> [Item] {
        var newIDs: [ElementID] = []
        var map: [ElementID: ElementID] = [:]
        for (i, item) in items.enumerated() {
            let fresh = i < ids.count ? ids[i] : NibID.make()
            newIDs.append(fresh)
            if map[item.id] == nil { map[item.id] = fresh }
        }
        let order = items.indices.sorted { a, b in
            (items[a].z, items[a].id.raw, a) < (items[b].z, items[b].id.raw, b)
        }
        let keys = FractionalIndex.sequence(after: zAfter, count: items.count)
        var z = [String](repeating: "", count: items.count)
        for (k, i) in order.enumerated() { z[i] = keys[k] }
        let move = Affine.translation(d.x, d.y)

        var out: [Item] = []
        out.reserveCapacity(items.count)
        for i in items.indices {
            let source = items[i]
            var n = d == .zero ? source : source.transformed(by: move)
            n.id = newIDs[i]
            n.rev = .zero
            n.deleted = false
            n.createdBy = nil
            n.z = z[i]
            n.attachedTo = source.attachedTo.flatMap { map[$0] }
            if var c = n.connector {
                c.from = NibFragment.remap(c.from, map)
                c.to = NibFragment.remap(c.to, map)
                n.connector = c
            }
            if var s = n.stroke {
                InkModel.prepare(&s)                  // synthetic (AI / plugin) ink gets nib sizes; captured ink is untouched
                n.stroke = s
            }
            if !assetMap.isEmpty { NibFragment.mapAssets(&n) { assetMap[$0.name] ?? $0 } }
            n.layer = min(max(layer ?? n.layer, 0), NibLimits.layerCount - 1)
            out.append(n)
        }
        var parent: [ElementID: ElementID] = [:]
        for n in out { if let p = n.attachedTo { parent[n.id] = p } }
        for i in out.indices {
            var seen = Set<ElementID>()
            var next = out[i].attachedTo
            while let p = next, seen.insert(p).inserted {
                if p == out[i].id {
                    out[i].attachedTo = nil
                    parent[out[i].id] = nil
                    break
                }
                next = parent[p]
            }
        }
        return out
    }

    /// A connector end anchored inside the fragment follows the copy; one anchored outside becomes a free end.
    static func remap(_ end: ConnectorEnd, _ map: [ElementID: ElementID]) -> ConnectorEnd {
        guard let target = end.item else { return end }
        guard let mapped = map[target] else { return ConnectorEnd(point: end.point) }
        var e = end
        e.item = mapped
        return e
    }

    // MARK: Assets

    /// Rewrites every asset reference an item holds: image, tape pattern, custom display ops and inline text glyphs.
    public static func mapAssets(_ item: inout Item, _ f: (AssetRef) -> AssetRef) {
        if var image = item.image {
            image.asset = f(image.asset)
            item.image = image
        }
        if var stroke = item.stroke, let pattern = stroke.style.tapePattern {
            stroke.style.tapePattern = f(pattern)
            item.stroke = stroke
        }
        if var custom = item.custom {
            for i in custom.display.ops.indices {
                if let a = custom.display.ops[i].asset { custom.display.ops[i].asset = f(a) }
            }
            item.custom = custom
        }
        if var text = item.text {
            mapRich(&text.text, f)
            item.text = text
        }
        if var sticky = item.sticky {
            mapRich(&sticky.text, f)
            item.sticky = sticky
        }
        if var shape = item.shape, var label = shape.text {
            mapRich(&label, f)
            shape.text = label
            item.shape = shape
        }
        if var connector = item.connector, var label = connector.label {
            mapRich(&label, f)
            connector.label = label
            item.connector = connector
        }
    }

    private static func mapRich(_ t: inout RichText, _ f: (AssetRef) -> AssetRef) {
        for p in t.paragraphs.indices {
            for r in t.paragraphs[p].runs.indices {
                if let a = t.paragraphs[p].runs[r].attrs.attachment { t.paragraphs[p].runs[r].attrs.attachment = f(a) }
            }
        }
    }

    /// Every asset an item references (image, tape pattern, display-op images, inline glyphs), without duplicates.
    public static func assetRefs(_ item: Item) -> [AssetRef] {
        var out: [AssetRef] = []
        var probe = item
        mapAssets(&probe) { ref in
            if !out.contains(ref) { out.append(ref) }
            return ref
        }
        return out
    }

    // MARK: Helpers

    /// Union of the items' bounds (`.zero` when empty).
    public static func union(_ items: [Item]) -> Rect {
        guard let first = items.first else { return .zero }
        return items.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    /// Decodes fragment JSON, turning errors into `invalid_params`.
    public static func decode(_ data: Data) throws -> NibFragment {
        do {
            return try JSONDecoder().decode(NibFragment.self, from: data)
        } catch {
            throw NibError(.invalidParams, "the Nib fragment could not be read (\(error.localizedDescription))",
                           hint: "copy the items again, or pass nib-fragment/1 JSON")
        }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

extension NibFragment: Codable {
    enum CodingKeys: String, CodingKey { case format, items, assets, bounds }

    /// Lenient: `format` may be left out (elements, board templates, AI JSON); `assets` defaults to none and
    /// `bounds` to the union of the items. A different format version is refused.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let f = try c.decodeIfPresent(String.self, forKey: .format), f != NibFragment.format {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c,
                                                   debugDescription: "unsupported fragment format '\(f)'; expected \(NibFragment.format)")
        }
        let items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        var assets: [String: Data] = [:]
        for (name, b64) in try c.decodeIfPresent([String: String].self, forKey: .assets) ?? [:] {
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw DecodingError.dataCorruptedError(forKey: .assets, in: c, debugDescription: "asset '\(name)' is not base64")
            }
            assets[name] = data
        }
        self.items = items
        self.assets = assets
        self.bounds = try c.decodeIfPresent(Rect.self, forKey: .bounds) ?? NibFragment.union(items)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(NibFragment.format, forKey: .format)
        try c.encode(items, forKey: .items)
        try c.encode(assets.mapValues { $0.base64EncodedString() }, forKey: .assets)
        try c.encode(bounds, forKey: .bounds)
    }
}
