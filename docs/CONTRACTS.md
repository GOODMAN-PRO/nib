# Nib — Contracts (shared source of truth)

This file holds the **exact** source that the scaffold agent creates **verbatim, byte for byte**, before any feature work starts. Every parallel feature agent compiles against it. It targets Swift 5 language mode, iOS 17.0 (deployment target), Xcode 26.6 and the iOS 26 SDK; every API newer than iOS 17.0 sits behind `#available`.

| Part | Contents | Owner after scaffold |
|---|---|---|
| **A** | `NibContracts` module (Model, Core, UI), `NibTesting` module, contract tests | Architect only (ARCHITECTURE.md §16) |
| **B** | `Package.swift`, generated feature lists, conformance tests | Regenerated from `forge-spec.json` |
| **C** | App shell (`AppDelegate.swift`, `ShellViewController.swift`) | Architect only |
| **D** | `project.yml`, CI workflow, `pick_sim.py`, `lint.py` | Architect only |

11,601 lines across 49 files. Every file starts with its repository path as a heading.

## How to use this file

- **Scaffold agent.** Create every file below at the given path, exactly as written. Then create the module stubs listed in `forge-spec.json` → `scaffold[2]` (one per feature entry type, including the second entry types of split features). Push, and do not start features until CI is green — including `NameLookupCanaryTests`, which proves no contract name clashes with an SDK type.
- **Feature agents.** Import `NibContracts` (and `NibTesting` in tests: Harness, Fixtures, fakes) and use only the API below. If something is missing, file `docs/contract-requests/<Fxxx>-<slug>.md`; do not edit these files.
- **Concurrency.** Everything marked `@MainActor` must be used from the main actor. Test classes that use `Harness` or `NibApp` are `@MainActor`.

## Quick reference: a complete feature module (example, do not create)

```swift
// NibKit/Sources/FeatExample/FeatExampleFeature.swift
import SwiftUI
import NibContracts

public enum FeatExampleFeature: NibFeature {
    public static let id = "example"

    public static func register(_ app: NibApp) {
        app.commands.register(ExampleStamp.self)                                    // a command (owner stamped = "example")
        app.settings.declare(ExampleSettings.loud, summary: "Stamp in bold red.", owner: id, schema: .bool())
        app.ui.toolbar.register(ToolbarItemDescriptor(                              // a toolbar button → command
            id: "example.stamp", title: "Stamp", icon: "seal", group: .accessories, order: 500, owner: id,
            command: "example.stamp"))
        app.ui.menus.register(MenuItemDescriptor(                                   // an object-menu entry → command
            id: "example.stamp.menu", title: "Stamp here", icon: "seal", location: .pageLongPress, order: 900,
            owner: id, command: "example.stamp",
            params: { ctx in ["page": .string(NodeRef.page(ctx.doc!, ctx.page!).description),
                              "at": .array([.number(ctx.point?.x ?? 72), .number(ctx.point?.y ?? 72)])] },
            isVisible: { ctx in ctx.doc != nil && ctx.page != nil }))
        app.ui.settingsPages.register(SettingsPageDescriptor(                       // a settings page
            id: "example.settings", title: "Example", icon: "seal", section: .advanced, order: 900, owner: id,
            makeView: { app in AnyView(Toggle("Loud stamps", isOn: .constant(app.settings.get(ExampleSettings.loud)))) }))
    }
}

enum ExampleSettings {
    static let loud = SettingKey("example.loud", default: false, synced: true)
}

struct ExampleStamp: NibCommand {
    struct Params: Codable { var page: String; var at: [Double]?; var id: String? }
    struct Output: Codable { var ref: String }
    static let descriptor = CommandDescriptor(
        id: "example.stamp", title: "Stamp",
        summary: "Put a 'Checked' text box on a page at a point (optional caller-chosen id).",
        params: .obj(["page": .ref, "at": .point, "id": .str("your own id, [A-Za-z0-9_-]{1,64}")], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "at": [100, 100]]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, page)? = NodeRef(p.page) else { throw NibError.invalid("expected a page ref", path: "$.page") }
        if let id = p.id, !NibID.isValid(id) { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
        let at = p.at ?? [72, 72]
        let layer = ctx.activeSession?.activeLayer ?? 0
        let item = try ctx.mutate { tx in
            var it = Item.makeText(TextBoxItem(frame: Frame(x: at[0], y: at[1], w: 120, h: 32),
                                               text: RichText(plain: "Checked ✓")), layer: layer)
            if let id = p.id { it.id = NibID(id) }
            return try tx.put(it, doc: doc, page: page)
        }
        return Output(ref: NodeRef.item(doc, page, item.id).description)
    }
}
```

## Part A — `NibContracts`, `NibTesting` and contract tests

The frozen, shared layer. Model = value types and the JSON wire format (lenient decoding everywhere). Core = commands, bus, transactions, undo, events, permissions, settings, services, registries and the AI tool catalogue. UI = PencilKit and TextKit bridges, shared drawing (DisplayList, InkOutline), UI registries, canvas protocols (tools, attachments) and the `NibApp` composition root.

### `NibKit/Sources/NibContracts/Model/JSONValue.swift`

```swift
import Foundation

/// Dynamically typed JSON. Used on every untyped boundary: plugins, AI tools, the MCP bridge, settings, `ext` data.
public enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var intValue: Int? {
        if case .number(let n) = self, n == n.rounded(), abs(n) < 9.0e15 { return Int(n) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isNull: Bool { self == .null }

    /// Encodes any `Encodable` into a `JSONValue`.
    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value into `T`.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func jsonString(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        guard let d = try? e.encode(self) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Deep-merges `other` over this value. Objects merge key by key; anything else is replaced.
    func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let over) = other else { return other }
        for (k, v) in over { base[k] = (base[k] ?? .null).merging(v) }
        return .object(base)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}
```

### `NibKit/Sources/NibContracts/Model/Primitives.swift`

```swift
import Foundation

// MARK: - Format constants

public enum NibFormat {
    /// Major on-disk format version. Readers refuse to write packages with a newer major version.
    public static let version = 1
    /// Document package extension. The ONLY place it is spelled (plus project.yml). "nibnote", not "nib":
    /// `.nib` is the system-declared Interface Builder type. Folders named `*.nib` that contain `doc.*.json`
    /// are still accepted as a legacy import (F002, F064).
    public static let packageExtension = "nibnote"
    public static let legacyPackageExtension = "nib"
    public static let packageUTType = "app.nib.document"
    public static let pluginExtension = "nibplugin"
    public static let pluginUTType = "app.nib.plugin"
    /// Hidden folder at the library root holding trash, plugins, elements, templates, prefs, AI chats.
    public static let libraryDirectory = ".nib-library"
    public static let urlScheme = "nib"
}

public enum NibLimits {
    public static let layerCount = 5
    public static let maxNesting = 16
    public static let boardItemLimit = 100_000
    public static let aiToolResultBytes = 20_000
    public static let undoDepth = 200
}

// MARK: - Identifiers

/// Identifier for every persisted record (documents, folders, pages, items, blocks, cards, clips).
/// Generated IDs are 12 Crockford-base32 characters. AI agents and plugins may supply their own
/// IDs (see `isValid`) so they can link records created in one batch.
public struct NibID: Hashable, Comparable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.raw = value }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    public var description: String { raw }
    public static func < (a: NibID, b: NibID) -> Bool { a.raw < b.raw }

    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    public static func make() -> NibID {
        var rng = SystemRandomNumberGenerator()
        var chars: [Character] = []
        chars.reserveCapacity(12)
        for _ in 0..<12 {
            let v: UInt64 = rng.next()
            chars.append(NibID.alphabet[Int(v % 32)])
        }
        return NibID(String(chars))
    }

    /// 1–64 characters of [A-Za-z0-9_-].
    public static func isValid(_ s: String) -> Bool {
        guard (1...64).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { NibID.allowed.contains($0) }
    }
}

public typealias DocumentID = NibID
public typealias PageID = NibID
public typealias ElementID = NibID
public typealias FolderID = NibID

// MARK: - Revisions (hybrid logical clock)

/// Last-writer-wins revision. Ordered by (wall ms, counter, device); encoded as a sortable hex string.
public struct Rev: Hashable, Comparable, Codable, CustomStringConvertible {
    public var wallMs: UInt64
    public var counter: UInt32
    public var device: UInt32

    public init(wallMs: UInt64, counter: UInt32, device: UInt32) {
        self.wallMs = wallMs
        self.counter = counter
        self.device = device
    }

    public static let zero = Rev(wallMs: 0, counter: 0, device: 0)

    public static func < (a: Rev, b: Rev) -> Bool {
        if a.wallMs != b.wallMs { return a.wallMs < b.wallMs }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.device < b.device
    }

    public var description: String { String(format: "%012llx.%08x.%08x", wallMs, counter, device) }

    /// Revisions stamped more than 24 h in the future come from a device whose clock is wrong: they compare as if
    /// written at time 0, so every correctly-clocked edit beats them (they still merge when nothing else exists)
    /// until real time catches up. Used by `LWW.merge` and `Workspace.merge`; F025 reports such files in sync.status.
    public func effective(now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> Rev {
        wallMs > now + 86_400_000 ? Rev(wallMs: 0, counter: counter, device: device) : self
    }

    public init?(string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 3,
              let w = UInt64(parts[0], radix: 16),
              let c = UInt32(parts[1], radix: 16),
              let d = UInt32(parts[2], radix: 16) else { return nil }
        self.init(wallMs: w, counter: c, device: d)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let r = Rev(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid rev '\(s)'")
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Hybrid logical clock. One per app process (`NibApp.clock`). Thread-safe.
public final class HLCClock {
    public let device: UInt32
    private var last = Rev.zero
    private let lock = NSLock()

    public init(device: UInt32) { self.device = device }

    public func tick() -> Rev {
        lock.lock()
        defer { lock.unlock() }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if now > last.wallMs {
            last = Rev(wallMs: now, counter: 0, device: device)
        } else {
            last = Rev(wallMs: last.wallMs, counter: last.counter &+ 1, device: device)
        }
        return last
    }

    /// Advances the clock past a remote revision (remote wall time is capped at now + 24 h).
    public func observe(_ remote: Rev) {
        lock.lock()
        defer { lock.unlock() }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let wall = min(remote.wallMs, now + 86_400_000)
        if wall > last.wallMs || (wall == last.wallMs && remote.counter > last.counter) {
            last = Rev(wallMs: wall, counter: remote.counter, device: device)
        }
    }
}

// MARK: - Fractional ordering keys

/// Base-62 fractional index used for z-order, page order, block/card/outline order.
/// Keys never end in "0", so a key can always be generated between any two keys.
public enum FractionalIndex {
    private static let digits: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static func value(_ c: Character) -> Int { digits.firstIndex(of: c) ?? 0 }

    /// A key strictly between `a` and `b` (nil = unbounded). Precondition: a < b when both are given.
    public static func between(_ a: String?, _ b: String?) -> String {
        String(mid(Array(a ?? ""), b.map { Array($0) }))
    }

    /// `count` increasing keys after `a`.
    public static func sequence(after a: String?, count: Int) -> [String] {
        var out: [String] = []
        var last = a
        for _ in 0..<max(0, count) {
            let k = between(last, nil)
            out.append(k)
            last = k
        }
        return out
    }

    private static func mid(_ a: [Character], _ b: [Character]?) -> [Character] {
        if let b = b {
            var n = 0
            while n < b.count && (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 {
                return Array(b[0..<n]) + mid(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let da = a.isEmpty ? 0 : value(a[0])
        let db = b.map { $0.isEmpty ? 62 : value($0[0]) } ?? 62
        if db - da > 1 { return [digits[(da + db) / 2]] }
        if let b = b, b.count > 1 { return [b[0]] }
        return [digits[da]] + mid(Array(a.dropFirst()), nil)
    }
}

// MARK: - Colors and assets

/// sRGB color with alpha. Encoded as "#RRGGBBAA".
public struct RGBA: Hashable, Codable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Accepts "#RRGGBB" or "#RRGGBBAA" (the "#" is optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF), 255)
        } else {
            self.init(UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }
    }

    public var hex: String { String(format: "#%02X%02X%02X%02X", r, g, b, a) }
    public var description: String { hex }
    public var alpha: Double { Double(a) / 255 }

    public func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(r, g, b, UInt8(max(0, min(255, (alpha * 255).rounded()))))
    }

    public static let black = RGBA(0x1A, 0x1A, 0x1A)
    public static let white = RGBA(0xFF, 0xFF, 0xFF)
    public static let clear = RGBA(0, 0, 0, 0)
    public static let highlighterYellow = RGBA(0xFF, 0xE0, 0x3D, 0x80)
    public static let paperYellow = RGBA(0xFD, 0xF6, 0xDC)
    public static let paperDark = RGBA(0x24, 0x24, 0x26)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = RGBA(hex: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid color '\(s)', expected #RRGGBB or #RRGGBBAA")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// Content-addressed file inside a document package: "assets/<sha256 hex>.<ext>". Immutable.
public struct AssetRef: Hashable, Codable, CustomStringConvertible {
    public var name: String

    public init(_ name: String) { self.name = name }

    public var ext: String { (name as NSString).pathExtension.lowercased() }
    public var description: String { name }

    public init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}
```

### `NibKit/Sources/NibContracts/Model/Geometry.swift`

```swift
import Foundation

/// A point in page coordinates: PDF points (1/72 in), origin at the page's top-left, y grows downward.
/// Encoded as `[x, y]`.
public struct Point: Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(0, 0)

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }

    public func distance(to p: Point) -> Double { hypot(p.x - x, p.y - y) }

    public static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
    public static func * (a: Point, s: Double) -> Point { Point(a.x * s, a.y * s) }
}

/// Axis-aligned rectangle in page coordinates. Encoded as `[x, y, width, height]`.
public struct Rect: Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        width = try c.decode(Double.self)
        height = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
        try c.encode(width)
        try c.encode(height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: Point { Point(midX, midY) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func union(_ r: Rect) -> Rect {
        let nx = min(x, r.x), ny = min(y, r.y)
        return Rect(x: nx, y: ny, width: max(maxX, r.maxX) - nx, height: max(maxY, r.maxY) - ny)
    }

    public func intersects(_ r: Rect) -> Bool {
        x <= r.maxX && r.x <= maxX && y <= r.maxY && r.y <= maxY
    }

    public func contains(_ p: Point) -> Bool {
        p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY
    }

    public func contains(_ r: Rect) -> Bool {
        r.x >= x && r.maxX <= maxX && r.y >= y && r.maxY <= maxY
    }

    /// Positive `d` shrinks, negative grows.
    public func insetBy(_ d: Double) -> Rect {
        Rect(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d))
    }

    public static func bounding(_ points: [Point]) -> Rect? {
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A possibly rotated box: position/size of the unrotated box plus rotation (radians, clockwise on screen)
/// about its center. Used by shapes, text boxes, images, sticky notes, math and custom items.
public struct Frame: Hashable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var rotation: Double

    public init(x: Double, y: Double, w: Double, h: Double, rotation: Double = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rotation = rotation
    }

    public init(_ r: Rect, rotation: Double = 0) {
        self.init(x: r.x, y: r.y, w: r.width, h: r.height, rotation: rotation)
    }

    enum CodingKeys: String, CodingKey { case x, y, w, h, rotation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        w = try c.decode(Double.self, forKey: .w)
        h = try c.decode(Double.self, forKey: .h)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }

    public var rect: Rect { Rect(x: x, y: y, width: w, height: h) }
    public var center: Point { Point(x + w / 2, y + h / 2) }

    /// Corners (top-left, top-right, bottom-right, bottom-left) after rotation.
    public var corners: [Point] {
        let c = center
        let hw = w / 2, hh = h / 2
        let cs = cos(rotation), sn = sin(rotation)
        let offsets: [(Double, Double)] = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
        return offsets.map { d in Point(c.x + d.0 * cs - d.1 * sn, c.y + d.0 * sn + d.1 * cs) }
    }

    /// Axis-aligned bounds of the rotated box.
    public var bounds: Rect {
        if rotation == 0 { return rect }
        return Rect.bounding(corners) ?? rect
    }

    /// Applies an affine transform (translation, uniform/non-uniform scale, rotation; shear is ignored).
    public func applying(_ t: Affine) -> Frame {
        let c = t.apply(center)
        let sx = hypot(t.a, t.b), sy = hypot(t.c, t.d)
        let nw = w * sx, nh = h * sy
        return Frame(x: c.x - nw / 2, y: c.y - nh / 2, w: nw, h: nh, rotation: rotation + atan2(t.b, t.a))
    }
}

/// 2-D affine transform in CoreGraphics convention: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
/// Encoded as `[a, b, c, d, tx, ty]`.
public struct Affine: Hashable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ dx: Double, _ dy: Double) -> Affine {
        Affine(a: 1, b: 0, c: 0, d: 1, tx: dx, ty: dy)
    }

    public static func scale(_ sx: Double, _ sy: Double, about p: Point = .zero) -> Affine {
        translation(-p.x, -p.y)
            .concatenating(Affine(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0))
            .concatenating(translation(p.x, p.y))
    }

    public static func rotation(_ radians: Double, about p: Point = .zero) -> Affine {
        let cs = cos(radians), sn = sin(radians)
        return translation(-p.x, -p.y)
            .concatenating(Affine(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0))
            .concatenating(translation(p.x, p.y))
    }

    /// `self` first, then `t`.
    public func concatenating(_ t: Affine) -> Affine {
        Affine(a: a * t.a + b * t.c,
               b: a * t.b + b * t.d,
               c: c * t.a + d * t.c,
               d: c * t.b + d * t.d,
               tx: tx * t.a + ty * t.c + t.tx,
               ty: tx * t.b + ty * t.d + t.ty)
    }

    public func apply(_ p: Point) -> Point {
        Point(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }

    public var determinant: Double { a * d - b * c }

    public init(from decoder: Decoder) throws {
        var u = try decoder.unkeyedContainer()
        a = try u.decode(Double.self)
        b = try u.decode(Double.self)
        c = try u.decode(Double.self)
        d = try u.decode(Double.self)
        tx = try u.decode(Double.self)
        ty = try u.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var u = encoder.unkeyedContainer()
        try u.encode(a)
        try u.encode(b)
        try u.encode(c)
        try u.encode(d)
        try u.encode(tx)
        try u.encode(ty)
    }
}

/// Shared geometry helpers (hit testing, lasso, eraser, recognition).
public enum Geo {
    public static func distance(_ p: Point, toSegment a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: Point(a.x + t * dx, a.y + t * dy))
    }

    /// Even-odd point-in-polygon test.
    public static func polygonContains(_ polygon: [Point], _ p: Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i], pj = polygon[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let xCross = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    public static func segmentsIntersect(_ p1: Point, _ p2: Point, _ q1: Point, _ q2: Point) -> Bool {
        func orient(_ a: Point, _ b: Point, _ c: Point) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2)
        let d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    /// True when any vertex of `line` is inside `polygon` or any segment crosses its boundary.
    public static func polylineTouchesPolygon(_ line: [Point], _ polygon: [Point]) -> Bool {
        if line.contains(where: { polygonContains(polygon, $0) }) { return true }
        guard polygon.count >= 2, line.count >= 2 else { return false }
        for i in 0..<(line.count - 1) {
            for j in 0..<polygon.count {
                let k = (j + 1) % polygon.count
                if segmentsIntersect(line[i], line[i + 1], polygon[j], polygon[k]) { return true }
            }
        }
        return false
    }

    public static func pathLength(_ pts: [Point]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += pts[i - 1].distance(to: pts[i]) }
        return total
    }

    /// Resamples a polyline to `count` evenly spaced points.
    public static func resample(_ pts: [Point], count: Int) -> [Point] {
        guard pts.count > 1, count > 1 else { return pts }
        let total = pathLength(pts)
        if total == 0 { return Array(repeating: pts[0], count: count) }
        let step = total / Double(count - 1)
        var out = [pts[0]]
        var acc = 0.0
        var prev = pts[0]
        var i = 1
        while i < pts.count && out.count < count {
            let cur = pts[i]
            let d = prev.distance(to: cur)
            if d > 0 && acc + d >= step {
                let t = (step - acc) / d
                let q = Point(prev.x + t * (cur.x - prev.x), prev.y + t * (cur.y - prev.y))
                out.append(q)
                prev = q
                acc = 0
            } else {
                acc += d
                prev = cur
                i += 1
            }
        }
        while out.count < count { out.append(pts[pts.count - 1]) }
        return out
    }

    /// Douglas–Peucker simplification.
    public static func simplify(_ pts: [Point], tolerance: Double) -> [Point] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let pair = stack.popLast() {
            let s = pair.0, e = pair.1
            guard e > s + 1 else { continue }
            var maxD = 0.0
            var idx = -1
            for i in (s + 1)..<e {
                let d = distance(pts[i], toSegment: pts[s], pts[e])
                if d > maxD {
                    maxD = d
                    idx = i
                }
            }
            if idx >= 0 && maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }
}
```

### `NibKit/Sources/NibContracts/Model/Ink.swift`

```swift
import Foundation

public enum InkTool: String, Codable, CaseIterable { case pen, pencil, highlighter, tape }
public enum PenStyle: String, Codable, CaseIterable { case fountain, ball, brush }
public enum StrokePattern: String, Codable, CaseIterable { case solid, dashed, dotted }

/// How a stroke looks. Every field is optional in JSON (missing fields take the defaults below).
public struct InkStyle: Codable, Hashable {
    public var tool: InkTool
    /// Pen tool only.
    public var pen: PenStyle?
    public var color: RGBA
    /// Nominal preset width in points.
    public var width: Double
    public var pattern: StrokePattern
    /// 0 = round … 1 = sharp (fountain pen).
    public var tipSharpness: Double
    /// 0 … 1 (fountain, brush).
    public var pressureSensitivity: Double
    /// 0 … 1 (fountain).
    public var tipFlatness: Double
    /// Apple Pencil Pro barrel roll shapes the nib (fountain).
    public var reactsToRoll: Bool
    /// Tape only: tiled pattern image; nil = solid color.
    public var tapePattern: AssetRef?
    /// Tape only: pattern follows stroke direction instead of staying horizontal.
    public var tapeFollowsDirection: Bool

    public init(tool: InkTool = .pen, pen: PenStyle? = .fountain, color: RGBA = .black, width: Double = 1.2,
                pattern: StrokePattern = .solid, tipSharpness: Double = 0.5, pressureSensitivity: Double = 0.5,
                tipFlatness: Double = 0, reactsToRoll: Bool = false, tapePattern: AssetRef? = nil,
                tapeFollowsDirection: Bool = false) {
        self.tool = tool
        self.pen = pen
        self.color = color
        self.width = width
        self.pattern = pattern
        self.tipSharpness = tipSharpness
        self.pressureSensitivity = pressureSensitivity
        self.tipFlatness = tipFlatness
        self.reactsToRoll = reactsToRoll
        self.tapePattern = tapePattern
        self.tapeFollowsDirection = tapeFollowsDirection
    }

    enum CodingKeys: String, CodingKey {
        case tool, pen, color, width, pattern, tipSharpness, pressureSensitivity, tipFlatness, reactsToRoll,
             tapePattern, tapeFollowsDirection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InkStyle()
        tool = try c.decodeIfPresent(InkTool.self, forKey: .tool) ?? d.tool
        pen = try c.decodeIfPresent(PenStyle.self, forKey: .pen) ?? (tool == .pen ? .fountain : nil)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        pattern = try c.decodeIfPresent(StrokePattern.self, forKey: .pattern) ?? d.pattern
        tipSharpness = try c.decodeIfPresent(Double.self, forKey: .tipSharpness) ?? d.tipSharpness
        pressureSensitivity = try c.decodeIfPresent(Double.self, forKey: .pressureSensitivity) ?? d.pressureSensitivity
        tipFlatness = try c.decodeIfPresent(Double.self, forKey: .tipFlatness) ?? d.tipFlatness
        reactsToRoll = try c.decodeIfPresent(Bool.self, forKey: .reactsToRoll) ?? d.reactsToRoll
        tapePattern = try c.decodeIfPresent(AssetRef.self, forKey: .tapePattern)
        tapeFollowsDirection = try c.decodeIfPresent(Bool.self, forKey: .tapeFollowsDirection) ?? d.tapeFollowsDirection
    }

    public static let defaultPen = InkStyle()
    public static let defaultPencil = InkStyle(tool: .pencil, pen: nil, color: RGBA(0x3A, 0x3A, 0x3C), width: 1.6)
    public static let defaultHighlighter = InkStyle(tool: .highlighter, pen: nil, color: .highlighterYellow, width: 12)
    public static let defaultTape = InkStyle(tool: .tape, pen: nil, color: RGBA(0xF4, 0xC4, 0x30), width: 18)
}

/// One captured sample. Page coordinates; `t` seconds since the stroke's `t0`; angles in radians.
/// `width`/`height`/`opacity` are what PencilKit rendered (0 = derive from style with `InkModel.fillSizes`).
public struct StrokePoint: Hashable {
    public var x: Float
    public var y: Float
    public var t: Float
    public var force: Float
    public var azimuth: Float
    public var altitude: Float
    public var roll: Float
    public var width: Float
    public var height: Float
    public var opacity: Float

    public init(x: Float, y: Float, t: Float = 0, force: Float = 0.5, azimuth: Float = 0,
                altitude: Float = 1.5707964, roll: Float = 0, width: Float = 0, height: Float = 0, opacity: Float = 1) {
        self.x = x
        self.y = y
        self.t = t
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.roll = roll
        self.width = width
        self.height = height
        self.opacity = opacity
    }

    public var location: Point { Point(Double(x), Double(y)) }

    /// Field order of the canonical "full" format.
    public static let fullFormat = ["x", "y", "t", "force", "azimuth", "altitude", "roll", "width", "height", "opacity"]
    public static let fullStride = 10

    /// Accepted `fmt` values for the flat `pts` array (plugins/AI usually send "xy").
    public static let formats: [String: [String]] = [
        "xy": ["x", "y"],
        "xyt": ["x", "y", "t"],
        "xytf": ["x", "y", "t", "force"],
        "xytfaa": ["x", "y", "t", "force", "azimuth", "altitude"],
        "xytfaar": ["x", "y", "t", "force", "azimuth", "altitude", "roll"],
        "full": StrokePoint.fullFormat
    ]

    var packed: [Float] { [x, y, t, force, azimuth, altitude, roll, width, height, opacity] }

    /// Linear interpolation of every field (used by `InkModel.densify`).
    public static func lerp(_ a: StrokePoint, _ b: StrokePoint, _ t: Float) -> StrokePoint {
        func m(_ u: Float, _ v: Float) -> Float { u + (v - u) * t }
        return StrokePoint(x: m(a.x, b.x), y: m(a.y, b.y), t: m(a.t, b.t), force: m(a.force, b.force),
                           azimuth: m(a.azimuth, b.azimuth), altitude: m(a.altitude, b.altitude), roll: m(a.roll, b.roll),
                           width: m(a.width, b.width), height: m(a.height, b.height), opacity: m(a.opacity, b.opacity))
    }

    mutating func set(_ field: String, _ v: Float) {
        switch field {
        case "x": x = v
        case "y": y = v
        case "t": t = v
        case "force": force = v
        case "azimuth": azimuth = v
        case "altitude": altitude = v
        case "roll": roll = v
        case "width": width = v
        case "height": height = v
        case "opacity": opacity = v
        default: break
        }
    }
}

/// A freehand stroke (pen, pencil, highlighter or tape) with the transform baked into its points.
public struct Stroke: Equatable {
    public var style: InkStyle
    public var points: [StrokePoint]
    /// Unix seconds of the first sample (links ink to audio for Note Replay).
    public var t0: Double
    /// Tape only: false = opaque (content hidden), true = revealed.
    public var tapeRevealed: Bool

    public init(style: InkStyle, points: [StrokePoint], t0: Double = Date().timeIntervalSince1970, tapeRevealed: Bool = false) {
        self.style = style
        self.points = points
        self.t0 = t0
        self.tapeRevealed = tapeRevealed
    }

    public var polyline: [Point] { points.map { $0.location } }

    /// Bounds including half the nib width.
    public var bounds: Rect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        var maxW: Float = 0
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
            maxW = max(maxW, max(p.width, p.height))
        }
        let pad = Double(max(maxW, Float(style.width))) / 2 + 1
        return Rect(x: Double(minX) - pad, y: Double(minY) - pad,
                    width: Double(maxX - minX) + 2 * pad, height: Double(maxY - minY) + 2 * pad)
    }

    public func transformed(by t: Affine) -> Stroke {
        var s = self
        let k = Float(sqrt(abs(t.determinant)))
        for i in s.points.indices {
            let p = t.apply(s.points[i].location)
            s.points[i].x = Float(p.x)
            s.points[i].y = Float(p.y)
            s.points[i].width *= k
            s.points[i].height *= k
        }
        s.style.width *= Double(k)
        return s
    }
}

public extension CodingUserInfoKey {
    /// Set to `true` in an encoder's `userInfo` to write stroke points as base64 little-endian Float32
    /// (`ptsB64`, used inside document packages). Otherwise points are written as a flat number array (`pts`).
    static let nibCompactPoints = CodingUserInfoKey(rawValue: "nib.compactPoints")!
}

extension Stroke: Codable {
    enum CodingKeys: String, CodingKey { case style, pts, ptsB64, fmt, t0, tapeRevealed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(InkStyle.self, forKey: .style) ?? InkStyle()
        t0 = try c.decodeIfPresent(Double.self, forKey: .t0) ?? Date().timeIntervalSince1970
        tapeRevealed = try c.decodeIfPresent(Bool.self, forKey: .tapeRevealed) ?? false
        if let b64 = try c.decodeIfPresent(String.self, forKey: .ptsB64) {
            guard let data = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(forKey: .ptsB64, in: c, debugDescription: "invalid base64 points")
            }
            var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
            _ = floats.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
            points = Stroke.unpack(floats, fields: StrokePoint.fullFormat)
        } else {
            let fmt = try c.decodeIfPresent(String.self, forKey: .fmt) ?? "xy"
            guard let fields = StrokePoint.formats[fmt] else {
                throw DecodingError.dataCorruptedError(forKey: .fmt, in: c,
                    debugDescription: "unknown point format '\(fmt)'; use one of \(StrokePoint.formats.keys.sorted())")
            }
            let raw = try c.decodeIfPresent([Double].self, forKey: .pts) ?? []
            points = Stroke.unpack(raw.map { Float($0) }, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(t0, forKey: .t0)
        if tapeRevealed { try c.encode(true, forKey: .tapeRevealed) }
        var flat: [Float] = []
        flat.reserveCapacity(points.count * StrokePoint.fullStride)
        for p in points { flat.append(contentsOf: p.packed) }
        if encoder.userInfo[.nibCompactPoints] as? Bool == true {
            let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
            try c.encode(data.base64EncodedString(), forKey: .ptsB64)
        } else {
            try c.encode("full", forKey: .fmt)
            try c.encode(flat.map { (Double($0) * 1000).rounded() / 1000 }, forKey: .pts)
        }
    }

    static func unpack(_ v: [Float], fields: [String]) -> [StrokePoint] {
        let stride = fields.count
        guard stride > 0 else { return [] }
        var out: [StrokePoint] = []
        out.reserveCapacity(v.count / stride)
        var i = 0
        var n = 0
        while i + stride <= v.count {
            var p = StrokePoint(x: 0, y: 0, t: Float(n) * 0.008)
            for (k, f) in fields.enumerated() { p.set(f, v[i + k]) }
            out.append(p)
            i += stride
            n += 1
        }
        return out
    }
}

public enum InkModel {
    /// Fills zero `width`/`height` (and zero opacity) from the style — for points created by AI, plugins,
    /// ink synthesis or SVG import that carry no rendered nib size.
    public static func fillSizes(_ points: inout [StrokePoint], style: InkStyle) {
        let w = Float(style.width)
        for i in points.indices where points[i].width <= 0 || points[i].height <= 0 {
            var f: Float = 1
            switch style.tool {
            case .pen:
                if style.pen != .ball {
                    f = 1 + (points[i].force - 0.5) * Float(style.pressureSensitivity) * 1.2
                }
            case .pencil:
                f = 0.8 + points[i].force * 0.4
            case .highlighter, .tape:
                f = 1
            }
            let size = max(0.1, w * f)
            points[i].width = size
            points[i].height = size
            if points[i].opacity <= 0 { points[i].opacity = 1 }
        }
    }

    /// Resamples so consecutive points are at most `maxSpacing` points apart (every field interpolated) and
    /// repeats each end point so it appears 3 times. PencilKit treats stroke points as control points of a
    /// uniform cubic B-spline; sparse AI/plugin polylines would otherwise render with rounded, pulled-in corners
    /// that no longer match the polyline used by the eraser, lasso, hit testing and recognition.
    public static func densify(_ points: [StrokePoint], maxSpacing: Float = 1.5) -> [StrokePoint] {
        guard points.count >= 2, let first = points.first, let last = points.last else { return points }
        let spacing = max(maxSpacing, 0.1)
        var out: [StrokePoint] = [first, first]
        out.reserveCapacity(points.count * 4)
        for i in points.indices {
            let p = points[i]
            if i > 0 {
                let a = points[i - 1]
                let d = ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot()
                let n = max(1, Int((d / spacing).rounded(.up)))
                for k in 1..<n { out.append(StrokePoint.lerp(a, p, Float(k) / Float(n))) }
            }
            out.append(p)
        }
        out.append(last)
        out.append(last)
        return out
    }

    /// Normalises a stroke that did not come from PencilKit (AI, plugins, ink synthesis, SVG import, patched
    /// points): when EVERY point has zero width it is densified and its nib sizes are derived from the style.
    /// Captured PencilKit strokes (non-zero widths) are untouched. `ink.addStrokes`, `ink.setPoints`,
    /// `item.update`/`node.set` of stroke points and `PKBridge.pkStroke` all call this before storing/drawing.
    public static func prepare(_ stroke: inout Stroke) {
        guard !stroke.points.isEmpty, stroke.points.allSatisfy({ $0.width <= 0 }) else { return }
        stroke.points = densify(stroke.points)
        fillSizes(&stroke.points, style: stroke.style)
    }
}
```

### `NibKit/Sources/NibContracts/Model/RichText.swift`

```swift
import Foundation

/// A link target on typed text: a web URL, a page of any document, or an audio timestamp.
public struct TextLink: Codable, Hashable {
    public var url: String?
    public var document: DocumentID?
    public var page: PageID?
    public var audioClip: NibID?
    public var audioTime: Double?

    public init(url: String? = nil, document: DocumentID? = nil, page: PageID? = nil,
                audioClip: NibID? = nil, audioTime: Double? = nil) {
        self.url = url
        self.document = document
        self.page = page
        self.audioClip = audioClip
        self.audioTime = audioTime
    }
}

/// Character attributes. nil = inherit (text box default style, then app default).
public struct TextAttributes: Codable, Hashable {
    public var font: String?
    public var size: Double?
    public var color: RGBA?
    public var highlight: RGBA?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var code: Bool?
    /// -1 = subscript, 1 = superscript.
    public var baseline: Int?
    public var link: TextLink?
    /// Inline image glyph (system stickers / adaptive image glyphs).
    public var attachment: AssetRef?

    public init(font: String? = nil, size: Double? = nil, color: RGBA? = nil, highlight: RGBA? = nil,
                bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strikethrough: Bool? = nil,
                code: Bool? = nil, baseline: Int? = nil, link: TextLink? = nil, attachment: AssetRef? = nil) {
        self.font = font
        self.size = size
        self.color = color
        self.highlight = highlight
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.code = code
        self.baseline = baseline
        self.link = link
        self.attachment = attachment
    }
}

public struct TextRun: Codable, Hashable {
    public var text: String
    public var attrs: TextAttributes

    public init(_ text: String, _ attrs: TextAttributes = TextAttributes()) {
        self.text = text
        self.attrs = attrs
    }

    enum CodingKeys: String, CodingKey { case text, attrs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        attrs = try c.decodeIfPresent(TextAttributes.self, forKey: .attrs) ?? TextAttributes()
    }
}

public enum ParagraphAlignment: String, Codable, CaseIterable { case natural, left, center, right, justified }
public enum ListKind: String, Codable, CaseIterable { case plain, bullet, number, numberParen, todo }

public struct Paragraph: Codable, Hashable {
    public var runs: [TextRun]
    public var align: ParagraphAlignment
    public var list: ListKind
    /// Nesting level for lists / indentation (0 = none).
    public var indent: Int
    /// Todo lists only.
    public var checked: Bool
    /// nil = automatic line spacing.
    public var lineSpacing: Double?
    /// Style preset name for full-page text ("title", "heading", "body", "caption").
    public var style: String?

    public init(runs: [TextRun] = [], align: ParagraphAlignment = .natural, list: ListKind = .plain, indent: Int = 0,
                checked: Bool = false, lineSpacing: Double? = nil, style: String? = nil) {
        self.runs = runs
        self.align = align
        self.list = list
        self.indent = indent
        self.checked = checked
        self.lineSpacing = lineSpacing
        self.style = style
    }

    enum CodingKeys: String, CodingKey { case runs, align, list, indent, checked, lineSpacing, style }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent([TextRun].self, forKey: .runs) ?? []
        align = try c.decodeIfPresent(ParagraphAlignment.self, forKey: .align) ?? .natural
        list = try c.decodeIfPresent(ListKind.self, forKey: .list) ?? .plain
        indent = try c.decodeIfPresent(Int.self, forKey: .indent) ?? 0
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing)
        style = try c.decodeIfPresent(String.self, forKey: .style)
    }

    public var plainText: String { runs.map { $0.text }.joined() }
}

/// Rich text used by text boxes, shapes, sticky notes, connectors labels, text-document blocks and cards.
/// In JSON it may also be given as a plain string (one paragraph per line).
public struct RichText: Codable, Hashable {
    public var paragraphs: [Paragraph]

    public init(paragraphs: [Paragraph]) { self.paragraphs = paragraphs }

    public init(plain: String, attrs: TextAttributes = TextAttributes()) {
        paragraphs = plain.components(separatedBy: "\n").map { line in
            Paragraph(runs: line.isEmpty ? [] : [TextRun(line, attrs)])
        }
    }

    public static let empty = RichText(paragraphs: [Paragraph()])

    public var plainText: String { paragraphs.map { $0.plainText }.joined(separator: "\n") }
    public var isEmpty: Bool { plainText.isEmpty }

    enum CodingKeys: String, CodingKey { case paragraphs }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = RichText(plain: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paragraphs = try c.decode([Paragraph].self, forKey: .paragraphs)
    }
}
```

### `NibKit/Sources/NibContracts/Model/Items.swift`

```swift
import Foundation

public enum ItemKind: String, Codable, CaseIterable {
    case stroke, shape, connector, text, image, sticky, math, comment, custom
}

// MARK: - Shapes and connectors

public enum ShapeKind: String, Codable, CaseIterable {
    case line, polyline, polygon, rectangle, roundedRectangle, ellipse, triangle, diamond, arc, curve, arrow
}

public struct ShapeItemStyle: Codable, Hashable {
    /// nil = no outline (fill-only shape).
    public var strokeColor: RGBA?
    public var strokeWidth: Double
    /// nil = no fill.
    public var fillColor: RGBA?
    public var cornerRadius: Double
    public var pattern: StrokePattern
    /// Shapes snapped from Draw-and-Hold keep the look of the tool that drew them.
    public var drawnWith: InkTool?
    public var arrowStart: Bool
    public var arrowEnd: Bool

    public init(strokeColor: RGBA? = .black, strokeWidth: Double = 1.5, fillColor: RGBA? = nil, cornerRadius: Double = 6,
                pattern: StrokePattern = .solid, drawnWith: InkTool? = nil, arrowStart: Bool = false, arrowEnd: Bool = false) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
        self.pattern = pattern
        self.drawnWith = drawnWith
        self.arrowStart = arrowStart
        self.arrowEnd = arrowEnd
    }

    enum CodingKeys: String, CodingKey {
        case strokeColor, strokeWidth, fillColor, cornerRadius, pattern, drawnWith, arrowStart, arrowEnd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokeColor = try c.decodeIfPresent(RGBA.self, forKey: .strokeColor)
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 1.5
        fillColor = try c.decodeIfPresent(RGBA.self, forKey: .fillColor)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 6
        pattern = try c.decodeIfPresent(StrokePattern.self, forKey: .pattern) ?? .solid
        drawnWith = try c.decodeIfPresent(InkTool.self, forKey: .drawnWith)
        arrowStart = try c.decodeIfPresent(Bool.self, forKey: .arrowStart) ?? false
        arrowEnd = try c.decodeIfPresent(Bool.self, forKey: .arrowEnd) ?? false
    }
}

public struct ShapeItem: Codable, Equatable {
    public var shape: ShapeKind
    public var frame: Frame
    /// Vertices / control points in page coordinates (line, polyline, polygon, arc, curve, arrow).
    /// Empty for box shapes, which are defined by `frame` alone.
    public var points: [Point]
    public var style: ShapeItemStyle
    public var text: RichText?

    public init(shape: ShapeKind, frame: Frame, points: [Point] = [], style: ShapeItemStyle = ShapeItemStyle(), text: RichText? = nil) {
        self.shape = shape
        self.frame = frame
        self.points = points
        self.style = style
        self.text = text
    }

    enum CodingKeys: String, CodingKey { case shape, frame, points, style, text }

    /// Lenient (AI / plugin JSON): only `shape` is required; `frame` defaults to the bounds of `points`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decode(ShapeKind.self, forKey: .shape)
        points = try c.decodeIfPresent([Point].self, forKey: .points) ?? []
        frame = try c.decodeIfPresent(Frame.self, forKey: .frame)
            ?? Rect.bounding(points).map { Frame($0) } ?? Frame(x: 0, y: 0, w: 0, h: 0)
        style = try c.decodeIfPresent(ShapeItemStyle.self, forKey: .style) ?? ShapeItemStyle()
        text = try c.decodeIfPresent(RichText.self, forKey: .text)
    }
}

public struct ConnectorEnd: Codable, Hashable {
    /// Current end point in page coordinates (kept in sync with the anchored item).
    public var point: Point
    /// Anchored shape/item, if any.
    public var item: ElementID?
    /// 0 top, 1 right, 2 bottom, 3 left.
    public var side: Int?
    /// 0…1 along the side.
    public var t: Double?

    public init(point: Point, item: ElementID? = nil, side: Int? = nil, t: Double? = nil) {
        self.point = point
        self.item = item
        self.side = side
        self.t = t
    }

    enum CodingKeys: String, CodingKey { case point, item, side, t }

    /// Lenient: `point` defaults to (0, 0) (anchored ends are recomputed from `item`/`side`/`t` by the commands).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = try c.decodeIfPresent(Point.self, forKey: .point) ?? .zero
        item = try c.decodeIfPresent(ElementID.self, forKey: .item)
        side = try c.decodeIfPresent(Int.self, forKey: .side)
        t = try c.decodeIfPresent(Double.self, forKey: .t)
    }
}

public enum ConnectorRoute: String, Codable, CaseIterable { case straight, elbow, curved }

public struct ConnectorItem: Codable, Equatable {
    public var from: ConnectorEnd
    public var to: ConnectorEnd
    public var route: ConnectorRoute
    /// User-added bend / control points.
    public var bends: [Point]
    public var style: ShapeItemStyle
    public var label: RichText?

    public init(from: ConnectorEnd, to: ConnectorEnd, route: ConnectorRoute = .straight, bends: [Point] = [],
                style: ShapeItemStyle = ShapeItemStyle(arrowEnd: true), label: RichText? = nil) {
        self.from = from
        self.to = to
        self.route = route
        self.bends = bends
        self.style = style
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case from, to, route, bends, style, label }

    /// Lenient: only `from` and `to` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(ConnectorEnd.self, forKey: .from)
        to = try c.decode(ConnectorEnd.self, forKey: .to)
        route = try c.decodeIfPresent(ConnectorRoute.self, forKey: .route) ?? .straight
        bends = try c.decodeIfPresent([Point].self, forKey: .bends) ?? []
        style = try c.decodeIfPresent(ShapeItemStyle.self, forKey: .style) ?? ShapeItemStyle(arrowEnd: true)
        label = try c.decodeIfPresent(RichText.self, forKey: .label)
    }
}

// MARK: - Boxes

public struct TextBoxStyle: Codable, Hashable {
    public var background: RGBA?
    public var borderColor: RGBA?
    public var borderWidth: Double
    public var cornerRadius: Double
    public var padding: Double
    public var shadow: Bool
    /// Grow height to fit content.
    public var autoGrow: Bool
    /// Full-page ("body") text: page-sized box at the bottom of the z-order.
    public var fullPage: Bool
    /// Default character attributes for runs that leave fields nil.
    public var defaults: TextAttributes

    public init(background: RGBA? = nil, borderColor: RGBA? = nil, borderWidth: Double = 0, cornerRadius: Double = 0,
                padding: Double = 4, shadow: Bool = false, autoGrow: Bool = true, fullPage: Bool = false,
                defaults: TextAttributes = TextAttributes()) {
        self.background = background
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.shadow = shadow
        self.autoGrow = autoGrow
        self.fullPage = fullPage
        self.defaults = defaults
    }

    enum CodingKeys: String, CodingKey {
        case background, borderColor, borderWidth, cornerRadius, padding, shadow, autoGrow, fullPage, defaults
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decodeIfPresent(RGBA.self, forKey: .background)
        borderColor = try c.decodeIfPresent(RGBA.self, forKey: .borderColor)
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 4
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        autoGrow = try c.decodeIfPresent(Bool.self, forKey: .autoGrow) ?? true
        fullPage = try c.decodeIfPresent(Bool.self, forKey: .fullPage) ?? false
        defaults = try c.decodeIfPresent(TextAttributes.self, forKey: .defaults) ?? TextAttributes()
    }
}

public struct TextBoxItem: Codable, Equatable {
    public var frame: Frame
    public var text: RichText
    public var style: TextBoxStyle

    public init(frame: Frame, text: RichText, style: TextBoxStyle = TextBoxStyle()) {
        self.frame = frame
        self.text = text
        self.style = style
    }

    enum CodingKeys: String, CodingKey { case frame, text, style }

    /// Lenient: only `frame` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        style = try c.decodeIfPresent(TextBoxStyle.self, forKey: .style) ?? TextBoxStyle()
    }
}

public struct ImageItem: Codable, Equatable {
    public var frame: Frame
    public var asset: AssetRef
    /// Rectangular crop, normalized 0…1 in image space.
    public var crop: Rect?
    /// Freehand crop outline, normalized 0…1 in image space.
    public var mask: [Point]?
    /// Animated GIF: tiles show the first frame, a live view animates it while visible.
    public var animated: Bool
    public var altText: String?

    public init(frame: Frame, asset: AssetRef, crop: Rect? = nil, mask: [Point]? = nil, animated: Bool = false, altText: String? = nil) {
        self.frame = frame
        self.asset = asset
        self.crop = crop
        self.mask = mask
        self.animated = animated
        self.altText = altText
    }

    enum CodingKeys: String, CodingKey { case frame, asset, crop, mask, animated, altText }

    /// Lenient: `frame` and `asset` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        asset = try c.decode(AssetRef.self, forKey: .asset)
        crop = try c.decodeIfPresent(Rect.self, forKey: .crop)
        mask = try c.decodeIfPresent([Point].self, forKey: .mask)
        animated = try c.decodeIfPresent(Bool.self, forKey: .animated) ?? false
        altText = try c.decodeIfPresent(String.self, forKey: .altText)
    }
}

public struct StickyItem: Codable, Equatable {
    public var frame: Frame
    public var color: RGBA
    public var text: RichText
    public var collapsed: Bool
    public var author: String?
    public var resolved: Bool

    public init(frame: Frame, color: RGBA = RGBA(0xFF, 0xE8, 0x7C), text: RichText = .empty, collapsed: Bool = false,
                author: String? = nil, resolved: Bool = false) {
        self.frame = frame
        self.color = color
        self.text = text
        self.collapsed = collapsed
        self.author = author
        self.resolved = resolved
    }

    enum CodingKeys: String, CodingKey { case frame, color, text, collapsed, author, resolved }

    /// Lenient: only `frame` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? RGBA(0xFF, 0xE8, 0x7C)
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        author = try c.decodeIfPresent(String.self, forKey: .author)
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }
}

public struct MathItem: Codable, Equatable {
    public var frame: Frame
    /// One LaTeX string per line.
    public var latex: [String]
    public var color: RGBA
    /// The handwriting it was converted from ("Copy Handwriting").
    public var sourceInk: [Stroke]?

    public init(frame: Frame, latex: [String], color: RGBA = .black, sourceInk: [Stroke]? = nil) {
        self.frame = frame
        self.latex = latex
        self.color = color
        self.sourceInk = sourceInk
    }

    enum CodingKeys: String, CodingKey { case frame, latex, color, sourceInk }

    /// Lenient: only `frame` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        latex = try c.decodeIfPresent([String].self, forKey: .latex) ?? []
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? .black
        sourceInk = try c.decodeIfPresent([Stroke].self, forKey: .sourceInk)
    }
}

public struct CommentMessage: Codable, Equatable {
    public var id: NibID
    public var author: String
    public var text: String
    /// Unix seconds.
    public var at: Double
    public var edited: Bool

    public init(id: NibID = NibID.make(), author: String, text: String, at: Double = Date().timeIntervalSince1970, edited: Bool = false) {
        self.id = id
        self.author = author
        self.text = text
        self.at = at
        self.edited = edited
    }

    enum CodingKeys: String, CodingKey { case id, author, text, at, edited }

    /// Lenient: only `text` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        text = try c.decode(String.self, forKey: .text)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? Date().timeIntervalSince1970
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
    }
}

public struct CommentItem: Codable, Equatable {
    /// Pin location. When `Item.attachedTo` is set the pin follows that item.
    public var anchor: Point
    public var messages: [CommentMessage]
    public var resolved: Bool

    public init(anchor: Point, messages: [CommentMessage], resolved: Bool = false) {
        self.anchor = anchor
        self.messages = messages
        self.resolved = resolved
    }

    enum CodingKeys: String, CodingKey { case anchor, messages, resolved }

    /// Lenient: only `anchor` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchor = try c.decode(Point.self, forKey: .anchor)
        messages = try c.decodeIfPresent([CommentMessage].self, forKey: .messages) ?? []
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }
}

// MARK: - Plugin / custom items

public enum DisplayOpKind: String, Codable, CaseIterable {
    case rect, ellipse, line, polyline, polygon, text, image, hlines, vlines, dots
}

/// One drawing instruction. Coordinates are relative to the owning frame's top-left (custom items)
/// or to the page (templates). Unused fields stay nil.
public struct DisplayOp: Codable, Equatable {
    public var op: DisplayOpKind
    public var rect: Rect?
    public var points: [Point]?
    public var stroke: RGBA?
    public var fill: RGBA?
    public var width: Double?
    public var dash: [Double]?
    public var text: String?
    public var fontSize: Double?
    public var fontName: String?
    public var asset: AssetRef?
    /// Line / dot spacing for hlines, vlines, dots.
    public var spacing: Double?
    /// Corner radius (rect) or dot radius (dots).
    public var radius: Double?

    public init(op: DisplayOpKind, rect: Rect? = nil, points: [Point]? = nil, stroke: RGBA? = nil, fill: RGBA? = nil,
                width: Double? = nil, dash: [Double]? = nil, text: String? = nil, fontSize: Double? = nil,
                fontName: String? = nil, asset: AssetRef? = nil, spacing: Double? = nil, radius: Double? = nil) {
        self.op = op
        self.rect = rect
        self.points = points
        self.stroke = stroke
        self.fill = fill
        self.width = width
        self.dash = dash
        self.text = text
        self.fontSize = fontSize
        self.fontName = fontName
        self.asset = asset
        self.spacing = spacing
        self.radius = radius
    }
}

/// A tiny vector format drawn by the host renderer (templates, plugin items, math graphs, AI diagrams).
public struct DisplayList: Codable, Equatable {
    public var ops: [DisplayOp]
    public init(ops: [DisplayOp] = []) { self.ops = ops }

    enum CodingKeys: String, CodingKey { case ops }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ops = try c.decodeIfPresent([DisplayOp].self, forKey: .ops) ?? []
    }
}

/// An item whose meaning is owned by a feature or plugin. It always renders from `display`,
/// so it survives the owner being disabled or uninstalled.
public struct CustomItem: Codable, Equatable {
    /// Feature or plugin id, e.g. "nib.mathgraph" or "dev.example.chart".
    public var owner: String
    public var type: String
    public var frame: Frame
    public var data: JSONValue
    public var display: DisplayList

    public init(owner: String, type: String, frame: Frame, data: JSONValue = [:], display: DisplayList = DisplayList()) {
        self.owner = owner
        self.type = type
        self.frame = frame
        self.data = data
        self.display = display
    }

    enum CodingKeys: String, CodingKey { case owner, type, frame, data, display }

    /// Lenient: `owner`, `type` and `frame` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        type = try c.decode(String.self, forKey: .type)
        frame = try c.decode(Frame.self, forKey: .frame)
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data) ?? [:]
        display = try c.decodeIfPresent(DisplayList.self, forKey: .display) ?? DisplayList()
    }
}

// MARK: - Item

/// Every object on a page. Exactly one payload matching `kind` is non-nil.
/// JSON: {"id":"…","kind":"stroke","layer":0,"z":"V","stroke":{…}}.
public struct Item: Codable, Equatable, Identifiable, LWWRecord {
    public var id: ElementID
    public var rev: Rev
    /// Tombstone (kept for sync / undo).
    public var deleted: Bool
    public var kind: ItemKind
    /// Fractional z-order key; empty = assign on first write (top of the page).
    public var z: String
    /// 0…4.
    public var layer: Int
    public var locked: Bool
    /// Container shape / sticky note / anchored comment target.
    public var attachedTo: ElementID?
    /// Provenance: "user", "ai:<chat>", "plugin:<id>", "bridge:<client>".
    public var createdBy: String?
    /// Plugin-owned data keyed by plugin id.
    public var ext: [String: JSONValue]?

    public var stroke: Stroke?
    public var shape: ShapeItem?
    public var connector: ConnectorItem?
    public var text: TextBoxItem?
    public var image: ImageItem?
    public var sticky: StickyItem?
    public var math: MathItem?
    public var comment: CommentItem?
    public var custom: CustomItem?

    public init(id: ElementID = NibID.make(), kind: ItemKind, z: String = "", layer: Int = 0, locked: Bool = false,
                attachedTo: ElementID? = nil, createdBy: String? = nil, ext: [String: JSONValue]? = nil,
                stroke: Stroke? = nil, shape: ShapeItem? = nil, connector: ConnectorItem? = nil, text: TextBoxItem? = nil,
                image: ImageItem? = nil, sticky: StickyItem? = nil, math: MathItem? = nil, comment: CommentItem? = nil,
                custom: CustomItem? = nil) {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.kind = kind
        self.z = z
        self.layer = layer
        self.locked = locked
        self.attachedTo = attachedTo
        self.createdBy = createdBy
        self.ext = ext
        self.stroke = stroke
        self.shape = shape
        self.connector = connector
        self.text = text
        self.image = image
        self.sticky = sticky
        self.math = math
        self.comment = comment
        self.custom = custom
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, kind, z, layer, locked, attachedTo, createdBy, ext
        case stroke, shape, connector, text, image, sticky, math, comment, custom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(ElementID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        kind = try c.decode(ItemKind.self, forKey: .kind)
        z = try c.decodeIfPresent(String.self, forKey: .z) ?? ""
        layer = try c.decodeIfPresent(Int.self, forKey: .layer) ?? 0
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        attachedTo = try c.decodeIfPresent(ElementID.self, forKey: .attachedTo)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        ext = try c.decodeIfPresent([String: JSONValue].self, forKey: .ext)
        stroke = try c.decodeIfPresent(Stroke.self, forKey: .stroke)
        shape = try c.decodeIfPresent(ShapeItem.self, forKey: .shape)
        connector = try c.decodeIfPresent(ConnectorItem.self, forKey: .connector)
        text = try c.decodeIfPresent(TextBoxItem.self, forKey: .text)
        image = try c.decodeIfPresent(ImageItem.self, forKey: .image)
        sticky = try c.decodeIfPresent(StickyItem.self, forKey: .sticky)
        math = try c.decodeIfPresent(MathItem.self, forKey: .math)
        comment = try c.decodeIfPresent(CommentItem.self, forKey: .comment)
        custom = try c.decodeIfPresent(CustomItem.self, forKey: .custom)
    }

    // MARK: Factories

    public static func makeStroke(_ s: Stroke, layer: Int = 0) -> Item { Item(kind: .stroke, layer: layer, stroke: s) }
    public static func makeShape(_ s: ShapeItem, layer: Int = 0) -> Item { Item(kind: .shape, layer: layer, shape: s) }
    public static func makeConnector(_ c: ConnectorItem, layer: Int = 0) -> Item { Item(kind: .connector, layer: layer, connector: c) }
    public static func makeText(_ t: TextBoxItem, layer: Int = 0) -> Item { Item(kind: .text, layer: layer, text: t) }
    public static func makeImage(_ i: ImageItem, layer: Int = 0) -> Item { Item(kind: .image, layer: layer, image: i) }
    public static func makeSticky(_ s: StickyItem, layer: Int = 0) -> Item { Item(kind: .sticky, layer: layer, sticky: s) }
    public static func makeMath(_ m: MathItem, layer: Int = 0) -> Item { Item(kind: .math, layer: layer, math: m) }
    public static func makeComment(_ c: CommentItem, layer: Int = 0) -> Item { Item(kind: .comment, layer: layer, comment: c) }
    public static func makeCustom(_ c: CustomItem, layer: Int = 0) -> Item { Item(kind: .custom, layer: layer, custom: c) }

    // MARK: Derived

    /// True when exactly the payload matching `kind` is present.
    public var isValid: Bool {
        var kinds: [ItemKind] = []
        if stroke != nil { kinds.append(.stroke) }
        if shape != nil { kinds.append(.shape) }
        if connector != nil { kinds.append(.connector) }
        if text != nil { kinds.append(.text) }
        if image != nil { kinds.append(.image) }
        if sticky != nil { kinds.append(.sticky) }
        if math != nil { kinds.append(.math) }
        if comment != nil { kinds.append(.comment) }
        if custom != nil { kinds.append(.custom) }
        return kinds == [kind]
    }

    /// Key used to look up an `ItemDrawer`: "stroke.<tool>", "custom.<owner>.<type>", or the kind name.
    public var drawKey: String {
        switch kind {
        case .stroke: return "stroke." + (stroke?.style.tool.rawValue ?? InkTool.pen.rawValue)
        case .custom: return "custom." + (custom?.owner ?? "") + "." + (custom?.type ?? "")
        default: return kind.rawValue
        }
    }

    /// Frame of frame-based kinds (shape, text, image, sticky, math, custom); nil otherwise.
    public var frame: Frame? {
        get {
            switch kind {
            case .shape: return shape?.frame
            case .text: return text?.frame
            case .image: return image?.frame
            case .sticky: return sticky?.frame
            case .math: return math?.frame
            case .custom: return custom?.frame
            default: return nil
            }
        }
        set {
            guard let f = newValue else { return }
            switch kind {
            case .shape: shape?.frame = f
            case .text: text?.frame = f
            case .image: image?.frame = f
            case .sticky: sticky?.frame = f
            case .math: math?.frame = f
            case .custom: custom?.frame = f
            default: break
            }
        }
    }

    /// Axis-aligned bounds in page coordinates.
    public var bounds: Rect {
        switch kind {
        case .stroke:
            return stroke?.bounds ?? .zero
        case .shape:
            guard let s = shape else { return .zero }
            let pad = s.style.strokeWidth / 2 + 1
            if let r = Rect.bounding(s.points), !s.points.isEmpty { return r.insetBy(-pad) }
            return s.frame.bounds.insetBy(-pad)
        case .connector:
            guard let c = connector else { return .zero }
            let r = Rect.bounding([c.from.point, c.to.point] + c.bends) ?? .zero
            return r.insetBy(-(c.style.strokeWidth / 2 + 6))
        case .comment:
            guard let c = comment else { return .zero }
            return Rect(x: c.anchor.x - 12, y: c.anchor.y - 12, width: 24, height: 24)
        default:
            return frame?.bounds ?? .zero
        }
    }

    /// Point on a side of a frame-based item (0 top, 1 right, 2 bottom, 3 left; t 0…1), used by connectors.
    public func anchorPoint(side: Int, t: Double) -> Point? {
        guard let f = frame else { return nil }
        let c = f.corners
        var a = c[0]
        var b = c[1]
        switch side {
        case 1:
            a = c[1]
            b = c[2]
        case 2:
            a = c[3]
            b = c[2]
        case 3:
            a = c[0]
            b = c[3]
        default:
            break
        }
        let k = max(0, min(1, t))
        return Point(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k)
    }

    /// Applies a transform to the geometry (points are baked; frames move/scale/rotate; stroke widths scale).
    public func transformed(by t: Affine) -> Item {
        var it = self
        switch kind {
        case .stroke:
            it.stroke = stroke?.transformed(by: t)
        case .shape:
            if var s = shape {
                s.frame = s.frame.applying(t)
                s.points = s.points.map { t.apply($0) }
                it.shape = s
            }
        case .connector:
            if var c = connector {
                c.from.point = t.apply(c.from.point)
                c.to.point = t.apply(c.to.point)
                c.bends = c.bends.map { t.apply($0) }
                it.connector = c
            }
        case .comment:
            if var c = comment {
                c.anchor = t.apply(c.anchor)
                it.comment = c
            }
        case .math:
            if var m = math {
                m.frame = m.frame.applying(t)
                m.sourceInk = m.sourceInk?.map { $0.transformed(by: t) }
                it.math = m
            }
        case .text, .image, .sticky, .custom:
            if let f = frame { it.frame = f.applying(t) }
        }
        return it
    }
}
```

### `NibKit/Sources/NibContracts/Model/Document.swift`

```swift
import Foundation

// MARK: - Last-writer-wins records

/// A synced record: merged by `id`, the higher `rev` wins; deletion is a tombstone.
public protocol LWWRecord: Codable, Equatable {
    var id: NibID { get }
    var rev: Rev { get set }
    var deleted: Bool { get set }
}

public enum LWW {
    /// Merges `incoming` into `base` by id keeping the higher rev (far-future revs are distrusted, see `Rev.effective`).
    /// Order: base order, new records appended.
    public static func merge<T: LWWRecord>(_ base: [T], _ incoming: [T]) -> [T] {
        var index: [NibID: Int] = [:]
        var out = base
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for (i, r) in out.enumerated() { index[r.id] = i }
        for r in incoming {
            if let i = index[r.id] {
                if r.rev.effective(now: now) > out[i].rev.effective(now: now) { out[i] = r }
            } else {
                index[r.id] = out.count
                out.append(r)
            }
        }
        return out
    }
}

// MARK: - Documents

public enum DocumentKind: String, Codable, CaseIterable { case notebook, whiteboard, textDocument, studySet }
public enum ScrollDirection: String, Codable, CaseIterable { case vertical, horizontal }

public struct LayerInfo: Codable, Hashable {
    public var index: Int
    public var name: String
    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case index, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer \(index + 1)"
    }
}

public struct PageSize: Codable, Hashable {
    public var width: Double
    public var height: Double

    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }

    public var isLandscape: Bool { width > height }
    public var rotated: PageSize { PageSize(height, width) }

    public static let standard = PageSize(455.04, 588.45)
    public static let standardLandscape = PageSize(650.88, 406.8)
    public static let a3 = PageSize(841.89, 1190.55)
    public static let a4 = PageSize(595.28, 841.89)
    public static let a5 = PageSize(419.53, 595.28)
    public static let a6 = PageSize(297.64, 419.53)
    public static let a7 = PageSize(209.76, 297.64)
    public static let b5 = PageSize(498.9, 708.66)
    public static let letter = PageSize(612, 792)
    public static let legal = PageSize(612, 1008)
    public static let tabloid = PageSize(792, 1224)
    public static let square = PageSize(595.28, 595.28)

    public static let presets: [(name: String, size: PageSize)] = [
        ("Standard", PageSize.standard), ("A3", PageSize.a3), ("A4", PageSize.a4), ("A5", PageSize.a5),
        ("A6", PageSize.a6), ("A7", PageSize.a7), ("B5", PageSize.b5), ("Letter", PageSize.letter),
        ("Legal", PageSize.legal), ("Tabloid", PageSize.tabloid), ("Square", PageSize.square)
    ]
}

/// Reference to a registered (parametric) template: `{"id": "builtin.ruled", "params": {"spacing": 24}}`.
public struct TemplateRef: Codable, Hashable {
    public var id: String
    public var params: [String: JSONValue]

    public init(_ id: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case id, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }
}

public enum BackgroundKind: String, Codable, CaseIterable { case template, pdf, image, color }

/// Page background. PDFs and images are referenced assets; templates are parametric.
public struct Background: Codable, Hashable {
    public var kind: BackgroundKind
    public var template: TemplateRef?
    public var asset: AssetRef?
    /// 0-based page index inside the PDF asset.
    public var pdfPage: Int?
    public var color: RGBA?

    public init(kind: BackgroundKind, template: TemplateRef? = nil, asset: AssetRef? = nil, pdfPage: Int? = nil, color: RGBA? = nil) {
        self.kind = kind
        self.template = template
        self.asset = asset
        self.pdfPage = pdfPage
        self.color = color
    }

    public static func ofTemplate(_ id: String, params: [String: JSONValue] = [:]) -> Background {
        Background(kind: .template, template: TemplateRef(id, params: params))
    }
    public static func ofPDF(_ asset: AssetRef, page: Int) -> Background { Background(kind: .pdf, asset: asset, pdfPage: page) }
    public static func ofImage(_ asset: AssetRef) -> Background { Background(kind: .image, asset: asset) }
    public static func ofColor(_ color: RGBA) -> Background { Background(kind: .color, color: color) }
}

public struct DocumentMeta: Codable, Equatable {
    public var id: DocumentID
    public var rev: Rev
    /// `NibFormat.version` that last wrote this document.
    public var format: Int
    public var kind: DocumentKind
    /// Unix seconds.
    public var createdAt: Double
    /// BCP-47 handwriting-recognition / search language.
    public var language: String
    public var scrollDirection: ScrollDirection
    public var favorite: Bool
    /// Password-locked (access gate, not encryption).
    public var locked: Bool
    public var coverEnabled: Bool
    public var layers: [LayerInfo]
    public var spellcheck: Bool
    public var mathAssist: Bool
    /// Template for "Add Page › Current template" and QuickNote pages.
    public var defaultTemplate: TemplateRef?
    /// Library-relative folder path the document was trashed from (nil when not trashed).
    public var trashedFrom: String?
    /// Security-scoped bookmark of an external source file (import-in-place, "save changes back").
    public var sourceBookmark: Data?
    public var ext: [String: JSONValue]?

    public init(id: DocumentID = NibID.make(), kind: DocumentKind, createdAt: Double = Date().timeIntervalSince1970,
                language: String = "en-US", scrollDirection: ScrollDirection = .vertical) {
        self.id = id
        self.rev = .zero
        self.format = NibFormat.version
        self.kind = kind
        self.createdAt = createdAt
        self.language = language
        self.scrollDirection = scrollDirection
        self.favorite = false
        self.locked = false
        self.coverEnabled = kind == .notebook
        self.layers = (0..<NibLimits.layerCount).map { LayerInfo(index: $0, name: "Layer \($0 + 1)") }
        self.spellcheck = false
        self.mathAssist = false
        self.defaultTemplate = nil
        self.trashedFrom = nil
        self.sourceBookmark = nil
        self.ext = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, format, kind, createdAt, language, scrollDirection, favorite, locked, coverEnabled, layers,
             spellcheck, mathAssist, defaultTemplate, trashedFrom, sourceBookmark, ext
    }

    /// Lenient: every field has a decode default (`kind` defaults to notebook, `format` to 1), so heads written by
    /// older builds and hand-written JSON decode, and new fields can be added with defaults (ARCHITECTURE §16).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .notebook
        self.init(id: try c.decodeIfPresent(DocumentID.self, forKey: .id) ?? NibID.make(), kind: kind,
                  createdAt: try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? Date().timeIntervalSince1970,
                  language: try c.decodeIfPresent(String.self, forKey: .language) ?? "en-US",
                  scrollDirection: try c.decodeIfPresent(ScrollDirection.self, forKey: .scrollDirection) ?? .vertical)
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        coverEnabled = try c.decodeIfPresent(Bool.self, forKey: .coverEnabled) ?? (kind == .notebook)
        layers = try c.decodeIfPresent([LayerInfo].self, forKey: .layers) ?? layers
        spellcheck = try c.decodeIfPresent(Bool.self, forKey: .spellcheck) ?? false
        mathAssist = try c.decodeIfPresent(Bool.self, forKey: .mathAssist) ?? false
        defaultTemplate = try c.decodeIfPresent(TemplateRef.self, forKey: .defaultTemplate)
        trashedFrom = try c.decodeIfPresent(String.self, forKey: .trashedFrom)
        sourceBookmark = try c.decodeIfPresent(Data.self, forKey: .sourceBookmark)
        ext = try c.decodeIfPresent([String: JSONValue].self, forKey: .ext)
    }
}

/// A notebook page or whiteboard board. `deleted` + `trashedAt` = in the page Trash (recoverable);
/// `deleted` without `trashedAt` = purged tombstone.
public struct PageRecord: LWWRecord {
    public let id: PageID
    public var rev: Rev
    public var deleted: Bool
    public var trashedAt: Double?
    /// Fractional order key (see `DocumentContent.orderKey`).
    public var order: String
    /// nil = infinite whiteboard board.
    public var size: PageSize?
    /// 0, 90, 180 or 270.
    public var rotation: Int
    public var background: Background
    public var bookmarked: Bool
    /// Board name or page label.
    public var title: String?
    /// Zoom Window return height override (points).
    public var zoomReturnHeight: Double?
    public var ext: [String: JSONValue]?

    public init(id: PageID = NibID.make(), order: String = "", size: PageSize? = .a4,
                background: Background = .ofTemplate("builtin.blank"), rotation: Int = 0, title: String? = nil) {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.trashedAt = nil
        self.order = order
        self.size = size
        self.rotation = rotation
        self.background = background
        self.bookmarked = false
        self.title = title
        self.zoomReturnHeight = nil
        self.ext = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, trashedAt, order, size, rotation, background, bookmarked, title, zoomReturnHeight, ext
    }

    /// Lenient: every field has a default. An absent `size` means an infinite whiteboard board (nil is never
    /// encoded), so raw inserts of notebook pages must pass `size`; `page.add` fills it for you.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(PageID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        trashedAt = try c.decodeIfPresent(Double.self, forKey: .trashedAt)
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        size = try c.decodeIfPresent(PageSize.self, forKey: .size)
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? .ofTemplate("builtin.blank")
        bookmarked = try c.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title)
        zoomReturnHeight = try c.decodeIfPresent(Double.self, forKey: .zoomReturnHeight)
        ext = try c.decodeIfPresent([String: JSONValue].self, forKey: .ext)
    }
}

/// A custom outline (table of contents) entry. PDF outlines are read from the PDF, not stored.
public struct OutlineEntry: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var title: String
    public var page: PageID?
    /// Parent entry (max depth 3).
    public var parent: NibID?
    public var order: String

    public init(id: NibID = NibID.make(), title: String, page: PageID?, parent: NibID? = nil, order: String = "") {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.title = title
        self.page = page
        self.parent = parent
        self.order = order
    }

    enum CodingKeys: String, CodingKey { case id, rev, deleted, title, page, parent, order }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        page = try c.decodeIfPresent(PageID.self, forKey: .page)
        parent = try c.decodeIfPresent(NibID.self, forKey: .parent)
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
    }
}

/// One transcript line. Transcripts are NOT document records: each device writes its own
/// `<AudioClip.transcriptFile base>.<dev>.json` (`[TranscriptSegment]`); readers merge every such file (plus a
/// legacy `<base>.json`) per `index`, the highest `rev` winning, exactly like package files (ARCHITECTURE §4.3).
public struct TranscriptSegment: Codable, Equatable {
    /// Stable position of the line in the clip's transcript.
    public var index: Int
    /// Seconds from the clip start.
    public var start: Double
    public var duration: Double
    public var text: String
    public var speaker: String?
    /// Last edit (nil = as recognised). The merge keeps the highest rev per index.
    public var rev: Rev?

    public init(index: Int = 0, start: Double, duration: Double, text: String, speaker: String? = nil, rev: Rev? = nil) {
        self.index = index
        self.start = start
        self.duration = duration
        self.text = text
        self.speaker = speaker
        self.rev = rev
    }

    enum CodingKeys: String, CodingKey { case index, start, duration, text, speaker, rev }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        text = try c.decode(String.self, forKey: .text)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev)
    }
}

/// An audio recording. Audio bytes live at `file` inside the package; transcripts in per-device files derived from
/// `transcriptFile` (see `TranscriptSegment`).
public struct AudioClip: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var name: String
    /// Package-relative path, e.g. "audio/<id>.m4a".
    public var file: String
    /// Unix seconds when recording started (ink with `t0` inside [start, start+duration] is linked).
    public var start: Double
    public var duration: Double
    /// Page where recording started.
    public var page: PageID?
    public var language: String?
    /// Package-relative base path of the transcript, e.g. "audio/<id>.transcript" (device files add ".<dev>.json").
    public var transcriptFile: String?
    public var summary: String?

    public init(id: NibID = NibID.make(), name: String, file: String, start: Double, duration: Double = 0, page: PageID? = nil) {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.name = name
        self.file = file
        self.start = start
        self.duration = duration
        self.page = page
        self.language = nil
        self.transcriptFile = nil
        self.summary = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, name, file, start, duration, page, language, transcriptFile, summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Recording"
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? "audio/\(id.raw).caf"
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        page = try c.decodeIfPresent(PageID.self, forKey: .page)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        transcriptFile = try c.decodeIfPresent(String.self, forKey: .transcriptFile)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}

// MARK: - Text documents

public enum BlockKind: String, Codable, CaseIterable {
    case paragraph, heading1, heading2, heading3, bullet, numbered, todo, quote, code, divider, table, image, video
    /// Owned by a feature or plugin (`TextBlock.custom`); always renders from its DisplayList.
    case custom
}

public struct TableCell: Codable, Equatable {
    public var text: RichText
    public var background: RGBA?
    public init(text: RichText = .empty, background: RGBA? = nil) {
        self.text = text
        self.background = background
    }

    enum CodingKeys: String, CodingKey { case text, background }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        background = try c.decodeIfPresent(RGBA.self, forKey: .background)
    }
}

public struct TableMerge: Codable, Hashable {
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var columnSpan: Int
    public init(row: Int, column: Int, rowSpan: Int, columnSpan: Int) {
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
    }

    enum CodingKeys: String, CodingKey { case row, column, rowSpan, columnSpan }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        row = try c.decode(Int.self, forKey: .row)
        column = try c.decode(Int.self, forKey: .column)
        rowSpan = try c.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1
        columnSpan = try c.decodeIfPresent(Int.self, forKey: .columnSpan) ?? 1
    }
}

public struct TableData: Codable, Equatable {
    public var rows: [[TableCell]]
    public var columnWidths: [Double]
    public var merges: [TableMerge]
    public var borders: Bool
    public init(rows: [[TableCell]], columnWidths: [Double] = [], merges: [TableMerge] = [], borders: Bool = true) {
        self.rows = rows
        self.columnWidths = columnWidths
        self.merges = merges
        self.borders = borders
    }

    enum CodingKeys: String, CodingKey { case rows, columnWidths, merges, borders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decodeIfPresent([[TableCell]].self, forKey: .rows) ?? []
        columnWidths = try c.decodeIfPresent([Double].self, forKey: .columnWidths) ?? []
        merges = try c.decodeIfPresent([TableMerge].self, forKey: .merges) ?? []
        borders = try c.decodeIfPresent(Bool.self, forKey: .borders) ?? true
    }
}

/// Payload of a `BlockKind.custom` block (plugins' `contributes.blocks`, feature-owned block kinds). The editor
/// draws `display` in a full-width box `height` points tall, so the block survives its owner being removed.
public struct CustomBlock: Codable, Equatable {
    public var owner: String
    public var type: String
    public var height: Double
    public var data: JSONValue
    public var display: DisplayList

    public init(owner: String, type: String, height: Double = 120, data: JSONValue = [:], display: DisplayList = DisplayList()) {
        self.owner = owner
        self.type = type
        self.height = height
        self.data = data
        self.display = display
    }

    enum CodingKeys: String, CodingKey { case owner, type, height, data, display }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        type = try c.decode(String.self, forKey: .type)
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 120
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data) ?? [:]
        display = try c.decodeIfPresent(DisplayList.self, forKey: .display) ?? DisplayList()
    }
}

public struct BlockComment: Codable, Equatable {
    public var id: NibID
    public var author: String
    public var text: String
    public var at: Double
    public var resolved: Bool
    /// UTF-16 range inside the block's plain text.
    public var rangeStart: Int
    public var rangeLength: Int
    public init(id: NibID = NibID.make(), author: String, text: String, at: Double = Date().timeIntervalSince1970,
                resolved: Bool = false, rangeStart: Int = 0, rangeLength: Int = 0) {
        self.id = id
        self.author = author
        self.text = text
        self.at = at
        self.resolved = resolved
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
    }

    enum CodingKeys: String, CodingKey { case id, author, text, at, resolved, rangeStart, rangeLength }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        text = try c.decode(String.self, forKey: .text)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? Date().timeIntervalSince1970
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        rangeStart = try c.decodeIfPresent(Int.self, forKey: .rangeStart) ?? 0
        rangeLength = try c.decodeIfPresent(Int.self, forKey: .rangeLength) ?? 0
    }
}

public struct TextBlock: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var order: String
    public var kind: BlockKind
    public var text: RichText
    public var checked: Bool?
    public var indent: Int?
    public var codeLanguage: String?
    public var table: TableData?
    public var asset: AssetRef?
    /// Video URL for `.video` blocks.
    public var url: String?
    public var caption: RichText?
    public var comments: [BlockComment]?
    /// `.custom` blocks only.
    public var custom: CustomBlock?

    public init(id: NibID = NibID.make(), kind: BlockKind, text: RichText = .empty, order: String = "") {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.order = order
        self.kind = kind
        self.text = text
        self.checked = nil
        self.indent = nil
        self.codeLanguage = nil
        self.table = nil
        self.asset = nil
        self.url = nil
        self.caption = nil
        self.comments = nil
        self.custom = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, order, kind, text, checked, indent, codeLanguage, table, asset, url, caption, comments, custom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        kind = try c.decodeIfPresent(BlockKind.self, forKey: .kind) ?? .paragraph
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked)
        indent = try c.decodeIfPresent(Int.self, forKey: .indent)
        codeLanguage = try c.decodeIfPresent(String.self, forKey: .codeLanguage)
        table = try c.decodeIfPresent(TableData.self, forKey: .table)
        asset = try c.decodeIfPresent(AssetRef.self, forKey: .asset)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        caption = try c.decodeIfPresent(RichText.self, forKey: .caption)
        comments = try c.decodeIfPresent([BlockComment].self, forKey: .comments)
        custom = try c.decodeIfPresent(CustomBlock.self, forKey: .custom)
    }
}

// MARK: - Study sets

public enum CardFaceKind: String, Codable, CaseIterable { case text, image, ink }

public struct CardFace: Codable, Equatable {
    public var kind: CardFaceKind
    public var text: RichText?
    public var asset: AssetRef?
    public var ink: [Stroke]?
    /// Canvas size for ink faces.
    public var size: PageSize?
    public init(kind: CardFaceKind = .text, text: RichText? = nil, asset: AssetRef? = nil, ink: [Stroke]? = nil, size: PageSize? = nil) {
        self.kind = kind
        self.text = text
        self.asset = asset
        self.ink = ink
        self.size = size
    }

    enum CodingKeys: String, CodingKey { case kind, text, asset, ink, size }

    /// Lenient: a plain string is a text face; `kind` is inferred (ink > image > text) when absent.
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = CardFace(kind: .text, text: RichText(plain: s))
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(RichText.self, forKey: .text)
        asset = try c.decodeIfPresent(AssetRef.self, forKey: .asset)
        ink = try c.decodeIfPresent([Stroke].self, forKey: .ink)
        size = try c.decodeIfPresent(PageSize.self, forKey: .size)
        kind = try c.decodeIfPresent(CardFaceKind.self, forKey: .kind) ?? (ink != nil ? .ink : asset != nil ? .image : .text)
    }
}

/// Spaced-repetition state (Smart Learn).
public struct SRSState: Codable, Equatable {
    /// Unix seconds when the card is next due.
    public var due: Double
    /// Days.
    public var interval: Double
    public var ease: Double
    public var reps: Int
    public var lapses: Int
    public var lastReviewed: Double?
    public init(due: Double = 0, interval: Double = 0, ease: Double = 2.5, reps: Int = 0, lapses: Int = 0, lastReviewed: Double? = nil) {
        self.due = due
        self.interval = interval
        self.ease = ease
        self.reps = reps
        self.lapses = lapses
        self.lastReviewed = lastReviewed
    }

    enum CodingKeys: String, CodingKey { case due, interval, ease, reps, lapses, lastReviewed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        due = try c.decodeIfPresent(Double.self, forKey: .due) ?? 0
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 0
        ease = try c.decodeIfPresent(Double.self, forKey: .ease) ?? 2.5
        reps = try c.decodeIfPresent(Int.self, forKey: .reps) ?? 0
        lapses = try c.decodeIfPresent(Int.self, forKey: .lapses) ?? 0
        lastReviewed = try c.decodeIfPresent(Double.self, forKey: .lastReviewed)
    }
}

public struct StudyCard: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var order: String
    public var front: CardFace
    public var back: CardFace
    public var srs: SRSState?
    public init(id: NibID = NibID.make(), front: CardFace, back: CardFace, order: String = "") {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.order = order
        self.front = front
        self.back = back
        self.srs = nil
    }

    enum CodingKeys: String, CodingKey { case id, rev, deleted, order, front, back, srs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        front = try c.decodeIfPresent(CardFace.self, forKey: .front) ?? CardFace()
        back = try c.decodeIfPresent(CardFace.self, forKey: .back) ?? CardFace()
        srs = try c.decodeIfPresent(SRSState.self, forKey: .srs)
    }
}

// MARK: - Document content (the persisted document head)

public enum PagePosition: String, Codable, CaseIterable { case before, after, start, end }

/// Everything in a document except page items. Page items are loaded per page by `Workspace`.
public struct DocumentContent: Codable, Equatable {
    public var meta: DocumentMeta
    /// All pages including trashed and purged tombstones. Use `livePages` for display order.
    public var pages: [PageRecord]
    public var outline: [OutlineEntry]
    public var blocks: [TextBlock]
    public var cards: [StudyCard]
    public var audio: [AudioClip]

    public init(meta: DocumentMeta, pages: [PageRecord] = [], outline: [OutlineEntry] = [], blocks: [TextBlock] = [],
                cards: [StudyCard] = [], audio: [AudioClip] = []) {
        self.meta = meta
        self.pages = pages
        self.outline = outline
        self.blocks = blocks
        self.cards = cards
        self.audio = audio
    }

    enum CodingKeys: String, CodingKey { case meta, pages, outline, blocks, cards, audio }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(DocumentMeta.self, forKey: .meta)
        pages = try c.decodeIfPresent([PageRecord].self, forKey: .pages) ?? []
        outline = try c.decodeIfPresent([OutlineEntry].self, forKey: .outline) ?? []
        blocks = try c.decodeIfPresent([TextBlock].self, forKey: .blocks) ?? []
        cards = try c.decodeIfPresent([StudyCard].self, forKey: .cards) ?? []
        audio = try c.decodeIfPresent([AudioClip].self, forKey: .audio) ?? []
    }

    public var livePages: [PageRecord] { pages.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var trashedPages: [PageRecord] { pages.filter { $0.deleted && $0.trashedAt != nil } }
    public var liveOutline: [OutlineEntry] { outline.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var liveBlocks: [TextBlock] { blocks.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var liveCards: [StudyCard] { cards.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var liveAudio: [AudioClip] { audio.filter { !$0.deleted }.sorted { $0.start < $1.start } }

    /// Any page record (including trashed) with this id.
    public func page(_ id: PageID) -> PageRecord? { pages.first { $0.id == id } }

    /// 0-based index among live pages.
    public func pageIndex(_ id: PageID) -> Int? { livePages.firstIndex { $0.id == id } }

    /// Order key for inserting a page at `position` relative to `anchor` (a live page).
    public func orderKey(_ position: PagePosition, relativeTo anchor: PageID?) -> String {
        let pages = livePages
        switch position {
        case .start:
            return FractionalIndex.between(nil, pages.first?.order)
        case .end:
            return FractionalIndex.between(pages.last?.order, nil)
        case .before, .after:
            guard let anchor = anchor, let i = pages.firstIndex(where: { $0.id == anchor }) else {
                return FractionalIndex.between(pages.last?.order, nil)
            }
            if position == .before {
                return FractionalIndex.between(i > 0 ? pages[i - 1].order : nil, pages[i].order)
            }
            return FractionalIndex.between(pages[i].order, i + 1 < pages.count ? pages[i + 1].order : nil)
        }
    }
}
```

### `NibKit/Sources/NibContracts/Model/Presets.swift`

```swift
import Foundation

/// One color (or tape pattern) slot of a writing tool.
public struct PresetSwatch: Codable, Hashable {
    public var color: RGBA
    /// Tape only: tiled pattern stored in `.nib-library/tape/`; copied into a document's assets on use.
    public var pattern: AssetRef?

    public init(color: RGBA, pattern: AssetRef? = nil) {
        self.color = color
        self.pattern = pattern
    }
}

/// Per-tool presets: up to 12 color slots and exactly 3 thickness slots (each with its own line pattern).
/// Stored as the synced setting `NibSettings.presets(<toolId>)`; edited by the Tool Presets feature,
/// read by pen, pencil, highlighter, tape and shape tools.
public struct ToolPresets: Codable, Equatable {
    public static let maxSwatches = 12

    public var swatches: [PresetSwatch]
    public var widths: [Double]
    public var patterns: [StrokePattern]
    public var selectedSwatch: Int
    public var selectedWidth: Int

    public init(swatches: [PresetSwatch], widths: [Double], patterns: [StrokePattern]? = nil,
                selectedSwatch: Int = 0, selectedWidth: Int = 1) {
        self.swatches = swatches
        self.widths = widths
        self.patterns = patterns ?? widths.map { _ in StrokePattern.solid }
        self.selectedSwatch = selectedSwatch
        self.selectedWidth = selectedWidth
    }

    public var color: RGBA { swatches.indices.contains(selectedSwatch) ? swatches[selectedSwatch].color : .black }
    public var width: Double { widths.indices.contains(selectedWidth) ? widths[selectedWidth] : 1.2 }
    public var pattern: StrokePattern { patterns.indices.contains(selectedWidth) ? patterns[selectedWidth] : .solid }
    public var tapePattern: AssetRef? { swatches.indices.contains(selectedSwatch) ? swatches[selectedSwatch].pattern : nil }

    public static func defaults(for tool: String) -> ToolPresets {
        switch tool {
        case "highlighter":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0xFF, 0xE0, 0x3D, 0x80)), PresetSwatch(color: RGBA(0x7C, 0xE3, 0x8B, 0x80)),
                                          PresetSwatch(color: RGBA(0xFF, 0x8F, 0xB1, 0x80))], widths: [8, 12, 18])
        case "tape":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0xF4, 0xC4, 0x30)), PresetSwatch(color: RGBA(0x8E, 0xC5, 0xFF)),
                                          PresetSwatch(color: RGBA(0xFF, 0xA8, 0xA8))], widths: [12, 18, 26])
        case "pencil":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0x3A, 0x3A, 0x3C)), PresetSwatch(color: RGBA(0x5B, 0x6B, 0x7F)),
                                          PresetSwatch(color: RGBA(0x8A, 0x5A, 0x3C))], widths: [1.0, 1.6, 2.4])
        case "shape":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0x1A, 0x1A, 0x1A)), PresetSwatch(color: RGBA(0x1F, 0x5F, 0xD1)),
                                          PresetSwatch(color: RGBA(0xD1, 0x3B, 0x2F))], widths: [1.0, 1.5, 3.0])
        default:
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0x1A, 0x1A, 0x1A)), PresetSwatch(color: RGBA(0x1F, 0x5F, 0xD1)),
                                          PresetSwatch(color: RGBA(0xD1, 0x3B, 0x2F))], widths: [0.6, 1.2, 2.0])
        }
    }
}
```

### `NibKit/Sources/NibContracts/Model/Library.swift`

```swift
import Foundation

public struct FolderStyle: Codable, Hashable {
    public var color: RGBA?
    /// SF Symbol name or a single emoji.
    public var icon: String?
    public var favorite: Bool

    public init(color: RGBA? = nil, icon: String? = nil, favorite: Bool = false) {
        self.color = color
        self.icon = icon
        self.favorite = favorite
    }
}

public enum LibraryNodeKind: String, Codable, CaseIterable { case folder, document }

/// Sync state shown on library thumbnails.
public enum SyncBadge: String, Codable, CaseIterable { case synced, syncing, downloading, error, localOnly }

/// A folder or document as listed by the library catalog (derived, rebuilt from disk).
public struct LibraryNode: Codable, Hashable, Identifiable {
    /// Document id, or the folder id stored in the folder's `.nibfolder.<dev>.json` files.
    public var id: NibID
    public var kind: LibraryNodeKind
    /// Package / folder name without extension.
    public var title: String
    /// Library-relative path, "/"-separated.
    public var path: String
    /// Parent folder; nil = library root.
    public var parent: FolderID?
    public var documentKind: DocumentKind?
    /// Unix seconds.
    public var modified: Double
    public var created: Double
    public var favorite: Bool
    public var locked: Bool
    public var pageCount: Int?
    public var style: FolderStyle?
    public var sync: SyncBadge
    public var trashedAt: Double?

    public init(id: NibID, kind: LibraryNodeKind, title: String, path: String, parent: FolderID? = nil,
                documentKind: DocumentKind? = nil, modified: Double = 0, created: Double = 0, favorite: Bool = false,
                locked: Bool = false, pageCount: Int? = nil, style: FolderStyle? = nil, sync: SyncBadge = .localOnly,
                trashedAt: Double? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.parent = parent
        self.documentKind = documentKind
        self.modified = modified
        self.created = created
        self.favorite = favorite
        self.locked = locked
        self.pageCount = pageCount
        self.style = style
        self.sync = sync
        self.trashedAt = trashedAt
    }
}
```

### `NibKit/Sources/NibContracts/Model/NodeRef.swift`

```swift
import Foundation

/// String address of any node, used by commands, queries, AI tools, plugins and the bridge:
/// `lib`, `folder:F`, `doc:D`, `page:D/P`, `item:D/P/I`, `block:D/B`, `card:D/C`, `audio:D/A`, `outline:D/O`.
public enum NodeRef: Hashable, Codable, CustomStringConvertible {
    case library
    case folder(FolderID)
    case document(DocumentID)
    case page(DocumentID, PageID)
    case item(DocumentID, PageID, ElementID)
    case block(DocumentID, NibID)
    case card(DocumentID, NibID)
    case audio(DocumentID, NibID)
    case outline(DocumentID, NibID)

    public init?(_ string: String) {
        if string == "lib" || string == "library" {
            self = .library
            return
        }
        guard let colon = string.firstIndex(of: ":") else { return nil }
        let kind = String(string[..<colon])
        let parts = string[string.index(after: colon)...].split(separator: "/").map { NibID(String($0)) }
        switch (kind, parts.count) {
        case ("folder", 1): self = .folder(parts[0])
        case ("doc", 1): self = .document(parts[0])
        case ("page", 2): self = .page(parts[0], parts[1])
        case ("item", 3): self = .item(parts[0], parts[1], parts[2])
        case ("block", 2): self = .block(parts[0], parts[1])
        case ("card", 2): self = .card(parts[0], parts[1])
        case ("audio", 2): self = .audio(parts[0], parts[1])
        case ("outline", 2): self = .outline(parts[0], parts[1])
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .library: return "lib"
        case .folder(let f): return "folder:\(f.raw)"
        case .document(let d): return "doc:\(d.raw)"
        case .page(let d, let p): return "page:\(d.raw)/\(p.raw)"
        case .item(let d, let p, let i): return "item:\(d.raw)/\(p.raw)/\(i.raw)"
        case .block(let d, let b): return "block:\(d.raw)/\(b.raw)"
        case .card(let d, let c): return "card:\(d.raw)/\(c.raw)"
        case .audio(let d, let a): return "audio:\(d.raw)/\(a.raw)"
        case .outline(let d, let o): return "outline:\(d.raw)/\(o.raw)"
        }
    }

    public var documentID: DocumentID? {
        switch self {
        case .library, .folder: return nil
        case .document(let d), .page(let d, _), .item(let d, _, _), .block(let d, _), .card(let d, _),
             .audio(let d, _), .outline(let d, _):
            return d
        }
    }

    public var pageID: PageID? {
        switch self {
        case .page(_, let p), .item(_, let p, _): return p
        default: return nil
        }
    }

    /// Accepts "doc:D", any ref inside a document, or a bare id.
    public static func documentID(from string: String) -> DocumentID {
        NodeRef(string)?.documentID ?? NibID(string)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let r = NodeRef(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid node ref '\(s)'")
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
```

### `NibKit/Sources/NibContracts/Core/Errors.swift`

```swift
import Foundation

/// The one error type that crosses every boundary (UI, plugins, AI tools, MCP). Stable `code`s let models self-correct.
/// Wire form: {"error": {"code": "...", "message": "...", "path": "...", "hint": "..."}}.
public struct NibError: Error, Codable, Equatable, CustomStringConvertible, LocalizedError {
    public enum Code: String, Codable, CaseIterable {
        case invalidParams = "invalid_params"
        case notFound = "not_found"
        case permissionDenied = "permission_denied"
        case userDenied = "user_denied"
        case locked
        case conflict
        case invariantViolation = "invariant_violation"
        case timeout
        case unavailable
        case unsupported
        case internalError = "internal"
    }

    public var code: Code
    public var message: String
    /// JSON path of the offending parameter, e.g. "$.points[3]".
    public var path: String?
    /// What to try next, e.g. "call commands.describe {id: 'ink.addStrokes'}".
    public var hint: String?

    public init(_ code: Code, _ message: String, path: String? = nil, hint: String? = nil) {
        self.code = code
        self.message = message
        self.path = path
        self.hint = hint
    }

    public static func notFound(_ what: String) -> NibError { NibError(.notFound, "\(what) not found") }
    public static func invalid(_ message: String, path: String? = nil) -> NibError { NibError(.invalidParams, message, path: path) }
    public static func unavailable(_ what: String) -> NibError {
        NibError(.unavailable, "\(what) is not available", hint: "the feature that provides it is disabled or not configured")
    }
    public static func unsupported(_ what: String) -> NibError { NibError(.unsupported, "\(what) is not supported") }

    /// Converts any error into a NibError (non-Nib errors become `internal`).
    public static func wrap(_ error: Error) -> NibError {
        if let e = error as? NibError { return e }
        return NibError(.internalError, error.localizedDescription)
    }

    public var description: String {
        var s = "[\(code.rawValue)] \(message)"
        if let p = path { s += " at \(p)" }
        if let h = hint { s += " (hint: \(h))" }
        return s
    }

    public var errorDescription: String? { message }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message)]
        if let p = path { o["path"] = .string(p) }
        if let h = hint { o["hint"] = .string(h) }
        return ["error": .object(o)]
    }
}
```

### `NibKit/Sources/NibContracts/Core/Permissions.swift`

```swift
import Foundation

/// Who is calling a command. String form: "user", "plugin:<id>", "ai:<chat>", "bridge:<client>", "sync:<device>".
public enum Principal: Hashable, Codable, CustomStringConvertible {
    case user
    case plugin(String)
    case ai(String)
    case bridge(String)
    case sync(String)

    public init(string: String) {
        let parts = string.split(separator: ":", maxSplits: 1).map { String($0) }
        let rest = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "plugin": self = .plugin(rest)
        case "ai": self = .ai(rest)
        case "bridge": self = .bridge(rest)
        case "sync": self = .sync(rest)
        default: self = .user
        }
    }

    public var description: String {
        switch self {
        case .user: return "user"
        case .plugin(let id): return "plugin:\(id)"
        case .ai(let id): return "ai:\(id)"
        case .bridge(let id): return "bridge:\(id)"
        case .sync(let id): return "sync:\(id)"
        }
    }

    public var isUser: Bool { self == .user }

    /// The exposure bit a command needs for this principal to see it.
    public var exposure: Exposure {
        switch self {
        case .user: return .ui
        case .plugin: return .plugin
        case .ai: return .ai
        case .bridge: return .bridge
        case .sync: return []
        }
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self.init(string: s)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// What a command does. Drives undo, confirmation and default scopes.
public enum Effect: String, Codable, CaseIterable {
    /// No mutation.
    case read
    /// Editor/window state only (tool, selection, zoom, navigation, panels). Not undoable, not persisted in documents.
    case session
    /// Undoable document mutation through `CommandContext.mutate`.
    case edit
    /// Library/file-system change (create, move, rename, trash). Recoverable through Trash, not on the undo stack.
    case library
    /// Cannot be undone (empty trash, delete permanently, overwrite a source file). Always confirmed for non-users.
    case irreversible
}

public enum CommandTarget: String, Codable, CaseIterable { case document, library, app }

public enum Scope: String, Codable, CaseIterable, Hashable {
    case documentRead = "document:read"
    case documentWrite = "document:write"
    case libraryRead = "library:read"
    case libraryWrite = "library:write"
    case destructive
    case app
    case ai
    case network
    /// Install/enable/remove plugins. Grantable to AI and bridge (always confirmed), never to plugins.
    case pluginsManage = "plugins:manage"
    /// Security settings, secrets, grants, passwords. Never granted to any non-user principal.
    case security
}

/// Which callers may see/run a command.
public struct Exposure: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let ui = Exposure(rawValue: 1)
    public static let plugin = Exposure(rawValue: 2)
    public static let ai = Exposure(rawValue: 4)
    public static let bridge = Exposure(rawValue: 8)
    public static let all: Exposure = [.ui, .plugin, .ai, .bridge]
}
```

### `NibKit/Sources/NibContracts/Core/JSONSchema.swift`

```swift
import Foundation

/// A deliberately flat JSON Schema subset (no $ref / oneOf) that small local models can follow.
/// Unknown object keys are allowed; `null` values are treated as absent.
public indirect enum JSONSchema {
    case object([String: JSONSchema], required: [String], description: String?)
    case array(JSONSchema, description: String?)
    case string(description: String?, choices: [String]?)
    case number(description: String?, minimum: Double?, maximum: Double?)
    case integer(description: String?, minimum: Int?, maximum: Int?)
    case boolean(description: String?)
    case anyValue(description: String?)
    /// A schema supplied verbatim (plugin manifests). Only its presence is checked.
    case raw(JSONValue)

    // MARK: Builders

    public static func obj(_ properties: [String: JSONSchema], required: [String] = [], _ description: String? = nil) -> JSONSchema {
        .object(properties, required: required, description: description)
    }
    public static func str(_ description: String? = nil, choices: [String]? = nil) -> JSONSchema {
        .string(description: description, choices: choices)
    }
    public static func num(_ description: String? = nil, min: Double? = nil, max: Double? = nil) -> JSONSchema {
        .number(description: description, minimum: min, maximum: max)
    }
    public static func int(_ description: String? = nil, min: Int? = nil, max: Int? = nil) -> JSONSchema {
        .integer(description: description, minimum: min, maximum: max)
    }
    public static func bool(_ description: String? = nil) -> JSONSchema { .boolean(description: description) }
    public static func arr(_ items: JSONSchema, _ description: String? = nil) -> JSONSchema { .array(items, description: description) }
    public static func anything(_ description: String? = nil) -> JSONSchema { .anyValue(description: description) }

    public static let empty: JSONSchema = .object([:], required: [], description: nil)
    public static let ref: JSONSchema = .string(description: "node ref: doc:D, page:D/P, item:D/P/I, block:D/B, card:D/C, audio:D/A, folder:F", choices: nil)
    public static let color: JSONSchema = .string(description: "#RRGGBB or #RRGGBBAA", choices: nil)
    public static let point: JSONSchema = .array(.number(description: nil, minimum: nil, maximum: nil), description: "[x, y] in page points, origin top-left")
    public static let rect: JSONSchema = .array(.number(description: nil, minimum: nil, maximum: nil), description: "[x, y, width, height] in page points")

    /// Wraps a plugin-supplied JSON Schema.
    public static func fromJSON(_ value: JSONValue) -> JSONSchema { .raw(value) }

    // MARK: Validation

    public func validate(_ value: JSONValue, path: String = "$") -> [NibError] {
        switch self {
        case .anyValue, .raw:
            return []
        case let .object(properties, required, _):
            guard case .object(let o) = value else { return [NibError.invalid("expected an object", path: path)] }
            var errors: [NibError] = []
            for key in required where o[key] == nil || o[key] == .null {
                errors.append(NibError.invalid("missing required field '\(key)'", path: path + "." + key))
            }
            for key in o.keys.sorted() {
                guard let schema = properties[key], let v = o[key], v != .null else { continue }
                errors += schema.validate(v, path: path + "." + key)
            }
            return errors
        case let .array(items, _):
            guard case .array(let a) = value else { return [NibError.invalid("expected an array", path: path)] }
            var errors: [NibError] = []
            for (i, v) in a.enumerated() {
                errors += items.validate(v, path: "\(path)[\(i)]")
                if errors.count > 20 { break }
            }
            return errors
        case let .string(_, choices):
            guard case .string(let s) = value else { return [NibError.invalid("expected a string", path: path)] }
            if let choices = choices, !choices.contains(s) {
                return [NibError.invalid("expected one of: \(choices.joined(separator: ", "))", path: path)]
            }
            return []
        case let .number(_, lo, hi):
            guard case .number(let n) = value else { return [NibError.invalid("expected a number", path: path)] }
            if let lo = lo, n < lo { return [NibError.invalid("must be >= \(lo)", path: path)] }
            if let hi = hi, n > hi { return [NibError.invalid("must be <= \(hi)", path: path)] }
            return []
        case let .integer(_, lo, hi):
            guard case .number(let n) = value, n == n.rounded() else { return [NibError.invalid("expected an integer", path: path)] }
            if let lo = lo, n < Double(lo) { return [NibError.invalid("must be >= \(lo)", path: path)] }
            if let hi = hi, n > Double(hi) { return [NibError.invalid("must be <= \(hi)", path: path)] }
            return []
        case .boolean:
            guard case .bool = value else { return [NibError.invalid("expected true or false", path: path)] }
            return []
        }
    }

    // MARK: Export (tool definitions, MCP, commands.describe)

    public func toJSON() -> JSONValue {
        switch self {
        case .raw(let v):
            return v
        case let .object(properties, required, d):
            var o: [String: JSONValue] = ["type": "object", "properties": .object(properties.mapValues { $0.toJSON() })]
            if !required.isEmpty { o["required"] = .array(required.map { JSONValue.string($0) }) }
            return JSONSchema.described(o, d)
        case let .array(items, d):
            return JSONSchema.described(["type": "array", "items": items.toJSON()], d)
        case let .string(d, choices):
            var o: [String: JSONValue] = ["type": "string"]
            if let c = choices { o["enum"] = .array(c.map { JSONValue.string($0) }) }
            return JSONSchema.described(o, d)
        case let .number(d, lo, hi):
            var o: [String: JSONValue] = ["type": "number"]
            if let lo = lo { o["minimum"] = .number(lo) }
            if let hi = hi { o["maximum"] = .number(hi) }
            return JSONSchema.described(o, d)
        case let .integer(d, lo, hi):
            var o: [String: JSONValue] = ["type": "integer"]
            if let lo = lo { o["minimum"] = .number(Double(lo)) }
            if let hi = hi { o["maximum"] = .number(Double(hi)) }
            return JSONSchema.described(o, d)
        case let .boolean(d):
            return JSONSchema.described(["type": "boolean"], d)
        case let .anyValue(d):
            return JSONSchema.described([:], d)
        }
    }

    private static func described(_ o: [String: JSONValue], _ description: String?) -> JSONValue {
        var o = o
        if let d = description { o["description"] = .string(d) }
        return .object(o)
    }
}
```

### `NibKit/Sources/NibContracts/Core/Command.swift`

```swift
import Foundation

/// Describes a command for the UI, plugins, the AI tool catalogue and MCP.
public struct CommandDescriptor {
    /// "namespace.verb" (built-in) or "<pluginId>.<name>" (plugins). Lower camel case segments.
    public var id: String
    /// UI label, e.g. "Add Page".
    public var title: String
    /// ONE line (≤ 200 chars) written for an LLM: what it does and the key params.
    public var summary: String
    public var params: JSONSchema
    /// Example params. Required for every command exposed to AI; they must validate and should use
    /// `Fixtures` ids (FIXTUREDOC01, FIXTUREPG001, …) so the conformance test can run them.
    public var examples: [JSONValue]
    public var effect: Effect
    public var target: CommandTarget
    public var destructive: Bool
    /// Derived from effect/target/destructive plus `extraScopes`.
    public var scopes: Set<Scope>
    public var exposure: Exposure
    /// "builtin" (contracts), the feature id (stamped by `NibApp.register`) or the plugin id.
    public var owner: String
    /// Shows system UI that needs a human (camera, microphone, file picker, Face ID, print).
    public var userPresence: Bool
    /// `.edit` commands that persist through `ctx.mutate(undoable: false)` (tape reveal, study grading, view flags)
    /// set this to false: conformance then asserts the undo stack is unchanged instead of an undo round trip.
    public var undoable: Bool
    /// Sends data off the device or captures it (WebDAV/backup destinations, collaboration, microphone, calendar,
    /// Photos, AI provider endpoints). Non-user principals are ALWAYS confirmed, whatever their policy.
    public var sensitive: Bool
    /// Runs caller-supplied nested calls that are authorized one by one (`commands.batch`, `ai.ask`). Every other
    /// `read` command runs read-only: its nested calls must be `read` and `ctx.mutate` throws.
    public var forwardsCalls: Bool

    public init(id: String, title: String, summary: String, params: JSONSchema = .empty, examples: [JSONValue] = [],
                effect: Effect, target: CommandTarget = .document, destructive: Bool = false,
                extraScopes: Set<Scope> = [], exposure: Exposure = .all, owner: String = "builtin",
                userPresence: Bool = false, undoable: Bool = true, sensitive: Bool = false, forwardsCalls: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.params = params
        self.examples = examples
        self.effect = effect
        self.target = target
        self.destructive = destructive || effect == .irreversible
        self.exposure = exposure
        self.owner = owner
        self.userPresence = userPresence
        self.undoable = undoable
        self.sensitive = sensitive
        self.forwardsCalls = forwardsCalls
        var s = extraScopes
        switch (effect, target) {
        case (.read, .document): s.insert(.documentRead)
        case (.read, .library): s.insert(.libraryRead)
        case (.read, .app), (.session, _): s.insert(.app)
        case (.edit, .document), (.irreversible, .document): s.insert(.documentWrite)
        case (.edit, .library), (.library, _), (.irreversible, .library): s.insert(.libraryWrite)
        case (.edit, .app), (.irreversible, .app): s.insert(.app)
        }
        if self.destructive { s.insert(.destructive) }
        self.scopes = s
    }

    /// Tool name for LLM APIs ([a-zA-Z0-9_-]{1,64}): dots become double underscores.
    public var toolName: String { id.replacingOccurrences(of: ".", with: "__") }

    public var isMutating: Bool { effect == .edit || effect == .library || effect == .irreversible }
}

/// A native command. Conforming types are main-actor isolated. Return `NoResult()` when there is nothing to return.
/// The result associated type is `Output` (not `Result`) so `Swift.Result` stays usable inside conformers; name
/// your nested result type `Output` too. Keep `examples` literals small: annotate nested literals
/// (`let ex: JSONValue = […]`) or use `try! JSONValue.parse(#"…"#)` for anything longer than one line.
///
///     struct PageRotate: NibCommand {
///         struct Params: Codable { var page: String; var degrees: Int? }
///         static let descriptor = CommandDescriptor(id: "page.rotate", title: "Rotate Page", summary: "…",
///             params: .obj(["page": .ref, "degrees": .int(min: 90, max: 270)], required: ["page"]),
///             examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]], effect: .edit)
///         static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult { … ctx.mutate { tx in … } … }
///     }
@MainActor
public protocol NibCommand {
    associatedtype Params: Codable
    associatedtype Output: Codable
    static var descriptor: CommandDescriptor { get }
    static func run(_ params: Params, _ ctx: CommandContext) async throws -> Output
}

/// Empty params/result. Named `NoResult` (not `Empty`) so it never clashes with `Combine.Empty`.
public struct NoResult: Codable, Equatable {
    public init() {}
}

public typealias CommandHandler = @MainActor (JSONValue, CommandContext) async throws -> JSONValue

/// All commands: built-in, feature and plugin. The command registry IS the app's API.
@MainActor
public final class CommandRegistry {
    public struct Entry {
        public let descriptor: CommandDescriptor
        public let handler: CommandHandler
    }

    private var entries: [String: Entry] = [:]
    /// Set by `NibApp.register` around each feature's `register`: descriptors that still say "builtin" are
    /// stamped with this owner, so `unregister(owner:)`, conformance filtering and provenance work per feature.
    public var defaultOwner: String?
    /// Ids registered twice while features registered (the later one replaced the earlier). Conformance fails on any.
    public private(set) var duplicateIDs: [String] = []

    public init() {}

    public func register<C: NibCommand>(_ type: C.Type) {
        register(C.descriptor) { json, ctx in
            let params = try CommandRegistry.decode(C.Params.self, from: json)
            let result = try await C.run(params, ctx)
            return try JSONValue.from(result)
        }
    }

    /// Registers a JSON-level command (plugins, generated commands).
    public func register(_ descriptor: CommandDescriptor, handler: @escaping CommandHandler) {
        var d = descriptor
        if d.owner == "builtin", let owner = defaultOwner { d.owner = owner }
        if defaultOwner != nil, entries[d.id] != nil { duplicateIDs.append(d.id) }
        entries[d.id] = Entry(descriptor: d, handler: handler)
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(id: String) {
        entries[id] = nil
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(owner: String) {
        entries = entries.filter { $0.value.descriptor.owner != owner }
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func entry(_ id: String) -> Entry? { entries[id] }
    public func descriptor(_ id: String) -> CommandDescriptor? { entries[id]?.descriptor }

    /// Sorted by id; filtered to commands exposed to `exposure` when given.
    public func all(exposedTo exposure: Exposure? = nil) -> [CommandDescriptor] {
        entries.values.map { $0.descriptor }
            .filter { d in exposure.map { d.exposure.contains($0) } ?? true }
            .sorted { $0.id < $1.id }
    }

    /// Decodes params, turning DecodingError into a readable `invalid_params` NibError with a JSON path.
    public nonisolated static func decode<T: Decodable>(_ type: T.Type, from json: JSONValue) throws -> T {
        let value: JSONValue = json == .null ? [:] : json
        do {
            return try value.decode(T.self)
        } catch let e as DecodingError {
            throw NibError.invalid(describe(e))
        }
    }

    nonisolated static func describe(_ e: DecodingError) -> String {
        func path(_ p: [CodingKey]) -> String {
            "$" + p.map { k in k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }.joined()
        }
        switch e {
        case .keyNotFound(let k, let c): return "missing '\(k.stringValue)' at \(path(c.codingPath))"
        case .typeMismatch(let t, let c): return "wrong type at \(path(c.codingPath)) (expected \(t))"
        case .valueNotFound(let t, let c): return "missing value at \(path(c.codingPath)) (expected \(t))"
        case .dataCorrupted(let c): return "invalid value at \(path(c.codingPath)): \(c.debugDescription)"
        @unknown default: return "invalid parameters"
        }
    }
}

public extension Notification.Name {
    /// Posted when any command or UI/content registry changes (UI refreshes toolbars/menus).
    static let nibRegistryDidChange = Notification.Name("NibRegistryDidChange")
}
```

### `NibKit/Sources/NibContracts/Core/CommandIDs.swift`

```swift
import Foundation

/// Well-known command ids that features call across module boundaries (owners: ARCHITECTURE.md §6).
/// Calling a command by id is the ONLY way one feature uses another feature's behaviour.
public enum CommandIDs {
    // Contracts (always present)
    public static let undo = "edit.undo"
    public static let redo = "edit.redo"
    public static let historyList = "history.list"
    public static let revertGroup = "history.revertGroup"
    public static let commandsList = "commands.list"
    public static let commandsDescribe = "commands.describe"
    public static let batch = "commands.batch"
    public static let toolSelect = "tool.select"
    public static let settingsGet = "settings.get"
    public static let settingsSet = "settings.set"
    public static let settingsList = "settings.list"
    public static let settingsDescribe = "settings.describe"

    // Query / render / recognition
    public static let queryContext = "query.context"
    public static let queryGet = "query.get"
    public static let queryFind = "query.find"
    public static let queryTree = "query.tree"
    /// Owner: F004 (NibRender). {page, scale?, region?, marks?, layers?, background?} →
    /// {asset: "tmp:<name>", pxPerPt, region, marks?}; long edge capped at 1568 px.
    public static let renderPage = "render.page"
    public static let recognizePageText = "recognize.pageText"
    public static let recognizeItems = "recognize.items"
    public static let searchText = "search.text"

    // Ink, items, selection
    public static let inkAddStrokes = "ink.addStrokes"
    public static let inkErase = "ink.erase"
    public static let inkScribbleErase = "ink.scribbleErase"
    public static let inkWriteText = "ink.writeText"
    public static let inkSetPoints = "ink.setPoints"
    public static let itemCreate = "item.create"
    public static let itemUpdate = "item.update"
    public static let itemDelete = "item.delete"
    public static let itemTransform = "item.transform"
    public static let itemMoveToPage = "item.moveToPage"
    public static let selectionSet = "selection.set"
    public static let selectionFromPolygon = "selection.fromPolygon"
    public static let clipboardCopy = "clipboard.copy"
    public static let clipboardPaste = "clipboard.paste"
    public static let shapeRecognize = "shape.recognize"
    public static let shapeCreate = "shape.create"
    public static let diagramCreate = "diagram.create"
    public static let textCreateBox = "text.createBox"
    public static let assetPut = "asset.put"
    /// Stores bytes as a temporary asset ("tmp:<name>", 1 h) that url-taking commands accept.
    public static let assetUpload = "asset.upload"
    /// Owner: F006. Transient DisplayList overlays per page ({page, id, display, ttl?}); plugins: nib.canvas.decorate.
    public static let canvasDecorate = "canvas.decorate"

    // Pages, documents, library, view
    public static let pageAdd = "page.add"
    public static let pageSetTemplate = "page.setTemplate"
    public static let docCreate = "doc.create"
    /// Owner: F018. {doc, page?, mode?: replace|newTab|newWindow} — opens in the active window unless told otherwise.
    public static let docOpen = "doc.open"
    public static let viewGoToPage = "view.goToPage"
    public static let panelOpen = "panel.open"
    public static let importFiles = "import.files"
    public static let exportRun = "export.run"
    public static let appOpenURL = "app.openURL"
    public static let appQuickAction = "app.quickAction"

    // Finger taps, double-taps and long-presses are routed through `app.content.tapHandlers`
    // (TapHandlerDescriptor, lowest order first; built-ins: tape.tapAt 100, comment.tapAt 200, link.tapAt 300,
    // selection.tapAt 400), then to the active tool. There is no fixed tap-chain constant.

    // Extensibility
    public static let pluginInstall = "plugin.install"
    public static let aiAsk = "ai.ask"
}
```

### `NibKit/Sources/NibContracts/Core/Mutation.swift`

```swift
import Foundation

/// Node refs touched by a change (what events carry; subscribers query for details).
public struct ChangeSummary: Codable, Equatable {
    public var created: [String]
    public var updated: [String]
    public var removed: [String]

    public init(created: [String] = [], updated: [String] = [], removed: [String] = []) {
        self.created = created
        self.updated = updated
        self.removed = removed
    }

    public var isEmpty: Bool { created.isEmpty && updated.isEmpty && removed.isEmpty }
    public var count: Int { created.count + updated.count + removed.count }
    public var all: [String] { created + updated + removed }

    public mutating func merge(_ other: ChangeSummary) {
        var seen = Set(all)
        for r in other.created where seen.insert(r).inserted { created.append(r) }
        for r in other.updated where seen.insert(r).inserted { updated.append(r) }
        for r in other.removed where seen.insert(r).inserted { removed.append(r) }
    }
}

/// One record write with its previous value (nil = inserted). The only mutation primitive.
public enum Mutation {
    case item(DocumentID, PageID, before: Item?, after: Item)
    case page(DocumentID, before: PageRecord?, after: PageRecord)
    case meta(DocumentID, before: DocumentMeta, after: DocumentMeta)
    case block(DocumentID, before: TextBlock?, after: TextBlock)
    case card(DocumentID, before: StudyCard?, after: StudyCard)
    case audio(DocumentID, before: AudioClip?, after: AudioClip)
    case outline(DocumentID, before: OutlineEntry?, after: OutlineEntry)

    public var document: DocumentID {
        switch self {
        case .item(let d, _, _, _), .page(let d, _, _), .meta(let d, _, _), .block(let d, _, _),
             .card(let d, _, _), .audio(let d, _, _), .outline(let d, _, _):
            return d
        }
    }

    /// Ref of the written record and whether the write created or removed it (tombstone transitions).
    public var change: (ref: String, created: Bool, removed: Bool) {
        func classify(_ beforeDeleted: Bool?, _ afterDeleted: Bool) -> (Bool, Bool) {
            let wasLive = beforeDeleted.map { !$0 } ?? false
            return (!wasLive && !afterDeleted, wasLive && afterDeleted)
        }
        switch self {
        case let .item(d, p, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.item(d, p, a.id).description, c.0, c.1)
        case let .page(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.page(d, a.id).description, c.0, c.1)
        case let .meta(d, _, _):
            return (NodeRef.document(d).description, false, false)
        case let .block(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.block(d, a.id).description, c.0, c.1)
        case let .card(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.card(d, a.id).description, c.0, c.1)
        case let .audio(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.audio(d, a.id).description, c.0, c.1)
        case let .outline(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.outline(d, a.id).description, c.0, c.1)
        }
    }
}

/// A committed transaction (or a merged remote patch). Observers use it to invalidate tiles, indexes, etc.
public struct Changeset {
    public let id: UUID
    /// Monotonic per app run.
    public let seq: UInt64
    public let principal: Principal
    /// Undo group: all changes of one command, one plugin call or one AI turn share a group.
    public let group: String
    public let label: String
    public let command: String
    public let mutations: [Mutation]

    public init(id: UUID = UUID(), seq: UInt64, principal: Principal, group: String, label: String, command: String, mutations: [Mutation]) {
        self.id = id
        self.seq = seq
        self.principal = principal
        self.group = group
        self.label = label
        self.command = command
        self.mutations = mutations
    }

    public static func summarize(_ mutations: [Mutation]) -> ChangeSummary {
        var s = ChangeSummary()
        var seen = Set<String>()
        for m in mutations {
            let c = m.change
            guard seen.insert(c.ref).inserted else { continue }
            if c.created {
                s.created.append(c.ref)
            } else if c.removed {
                s.removed.append(c.ref)
            } else {
                s.updated.append(c.ref)
            }
        }
        return s
    }

    public var summary: ChangeSummary { Changeset.summarize(mutations) }
    public func summary(for doc: DocumentID) -> ChangeSummary { Changeset.summarize(mutations.filter { $0.document == doc }) }
    public var documents: Set<DocumentID> { Set(mutations.map { $0.document }) }

    /// True when the document head (meta, page table, outline, blocks, cards, audio) changed.
    public func headChanged(_ doc: DocumentID) -> Bool {
        mutations.contains { m in
            if case .item = m { return false }
            return m.document == doc
        }
    }

    /// Pages whose items changed, per document.
    public var itemPages: [DocumentID: Set<PageID>] {
        var out: [DocumentID: Set<PageID>] = [:]
        for m in mutations {
            if case let .item(d, p, _, _) = m { out[d, default: []].insert(p) }
        }
        return out
    }

    /// Union of before/after bounds of items changed on a page (for tile invalidation); nil if none.
    public func dirtyRect(doc: DocumentID, page: PageID) -> Rect? {
        var r: Rect?
        for m in mutations {
            guard case let .item(d, p, b, a) = m, d == doc, p == page else { continue }
            var u = a.bounds
            if let b = b { u = u.union(b.bounds) }
            r = r.map { $0.union(u) } ?? u
        }
        return r
    }

    /// The after-values for one document, as sent to collaborators.
    public func patch(for doc: DocumentID) -> DocumentPatch {
        var p = DocumentPatch(doc: doc)
        for m in mutations where m.document == doc {
            switch m {
            case let .item(_, page, _, a): p.items[page.raw, default: []].append(a)
            case let .page(_, _, a): p.pages.append(a)
            case let .meta(_, _, a): p.meta = a
            case let .block(_, _, a): p.blocks.append(a)
            case let .card(_, _, a): p.cards.append(a)
            case let .audio(_, _, a): p.audio.append(a)
            case let .outline(_, _, a): p.outline.append(a)
            }
        }
        return p
    }
}

/// Records to merge last-writer-wins (sync, collaboration, per-device package files).
public struct DocumentPatch: Codable {
    public var doc: DocumentID
    public var meta: DocumentMeta?
    public var pages: [PageRecord]
    /// PageID raw value → items.
    public var items: [String: [Item]]
    public var outline: [OutlineEntry]
    public var blocks: [TextBlock]
    public var cards: [StudyCard]
    public var audio: [AudioClip]

    public init(doc: DocumentID, meta: DocumentMeta? = nil, pages: [PageRecord] = [], items: [String: [Item]] = [:],
                outline: [OutlineEntry] = [], blocks: [TextBlock] = [], cards: [StudyCard] = [], audio: [AudioClip] = []) {
        self.doc = doc
        self.meta = meta
        self.pages = pages
        self.items = items
        self.outline = outline
        self.blocks = blocks
        self.cards = cards
        self.audio = audio
    }

    public var isEmpty: Bool {
        meta == nil && pages.isEmpty && items.isEmpty && outline.isEmpty && blocks.isEmpty && cards.isEmpty && audio.isEmpty
    }
}
```

### `NibKit/Sources/NibContracts/Core/Workspace.swift`

```swift
import Foundation

/// Storage behind the workspace. Implemented by the NibStore feature (package files in the library folder);
/// `InMemoryPersistence` is the default and the test double. Main-actor isolated (the workspace calls it on main);
/// implementations snapshot on main and do file I/O on their own queue. Package URLs off-main come from
/// `NibServices.packages` (a thread-safe `PackageLocator`), never from `LibraryService`.
@MainActor
public protocol DocumentPersistence: AnyObject {
    /// Loads and merges the document head from every device file. Throws `not_found`.
    func loadHead(_ doc: DocumentID) throws -> DocumentContent
    /// Loads and merges all items of a page, tombstones included.
    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item]
    /// Called on the main actor after every commit/merge. `head` is nil when unchanged; `pages` holds the
    /// full item arrays (tombstones included) of changed pages. Implementations debounce and write off-main.
    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]])
    /// Writes pending changes now (page leave, background, close).
    func flush(_ doc: DocumentID)
    /// Absolute URL of a file inside the document package (audio, transcripts); creates parent folders.
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL
    /// Records written by OTHER devices since this device last read them (folder sync). nil = nothing new.
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch?
}

@MainActor
public final class InMemoryPersistence: DocumentPersistence {
    public var heads: [DocumentID: DocumentContent] = [:]
    public var pageItems: [DocumentID: [PageID: [Item]]] = [:]
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-memory-" + UUID().uuidString, isDirectory: true)
    }

    public func loadHead(_ doc: DocumentID) throws -> DocumentContent {
        guard let h = heads[doc] else { throw NibError.notFound("document \(doc)") }
        return h
    }

    public func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        pageItems[doc]?[page] ?? []
    }

    public func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        if let h = head { heads[doc] = h }
        for (p, items) in pages { pageItems[doc, default: [:]][p] = items }
    }

    public func flush(_ doc: DocumentID) {}

    public func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(doc.raw, isDirectory: true).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    public func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { nil }
}

/// In-memory state of open documents. Reads are public; writes happen only inside `DocTransaction`
/// (via `CommandContext.mutate`), undo/redo, and `CommandBus.applyRemote`.
@MainActor
public final class Workspace {
    public let clock: HLCClock
    /// Replace before any document is opened (the NibStore feature does this in `register`).
    public var persistence: DocumentPersistence
    public let events: EventBus
    private var heads: [DocumentID: DocumentContent] = [:]
    private var pageItems: [DocumentID: [PageID: [Item]]] = [:]

    public init(clock: HLCClock, persistence: DocumentPersistence, events: EventBus) {
        self.clock = clock
        self.persistence = persistence
        self.events = events
    }

    // MARK: Reads

    public func content(_ doc: DocumentID) throws -> DocumentContent {
        if let h = heads[doc] { return h }
        let h = try persistence.loadHead(doc)
        clock.observe(h.meta.rev)
        heads[doc] = h
        events.emit(NibEventType.docOpened, doc: doc)
        return h
    }

    /// All items of a page including tombstones, sorted by (z, id).
    public func allItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        if let items = pageItems[doc]?[page] { return items }
        _ = try content(doc)
        let items = Workspace.sortedByZ(try persistence.loadItems(doc, page: page))
        pageItems[doc, default: [:]][page] = items
        return items
    }

    /// Live items of a page in z-order (bottom first).
    public func items(_ doc: DocumentID, page: PageID) throws -> [Item] {
        try allItems(doc, page: page).filter { !$0.deleted }
    }

    /// Live items whose bounds intersect `rect`.
    public func items(_ doc: DocumentID, page: PageID, in rect: Rect) throws -> [Item] {
        try items(doc, page: page).filter { $0.bounds.intersects(rect) }
    }

    public func item(_ doc: DocumentID, page: PageID, id: ElementID) throws -> Item {
        guard let it = try allItems(doc, page: page).first(where: { $0.id == id && !$0.deleted }) else {
            throw NibError.notFound("item \(id) on page \(page)")
        }
        return it
    }

    /// Finds the page holding a live item (loads pages as needed).
    public func page(ofItem id: ElementID, in doc: DocumentID) throws -> PageID? {
        for p in try content(doc).pages {
            if try allItems(doc, page: p.id).contains(where: { $0.id == id && !$0.deleted }) { return p.id }
        }
        return nil
    }

    public var loadedDocuments: [DocumentID] { Array(heads.keys) }
    public func isLoaded(_ doc: DocumentID) -> Bool { heads[doc] != nil }

    /// Flushes and drops a document from memory.
    public func close(_ doc: DocumentID) {
        guard heads[doc] != nil else { return }
        persistence.flush(doc)
        heads[doc] = nil
        pageItems[doc] = nil
        events.emit(NibEventType.docClosed, doc: doc)
    }

    /// Memory pressure: drop cached pages except `keeping`.
    public func evictPages(_ doc: DocumentID, keeping: Set<PageID>) {
        persistence.flush(doc)
        guard var cache = pageItems[doc] else { return }
        for key in Array(cache.keys) where !keeping.contains(key) { cache[key] = nil }
        pageItems[doc] = cache
    }

    static func sortedByZ(_ items: [Item]) -> [Item] {
        items.sorted { ($0.z, $0.id.raw) < ($1.z, $1.id.raw) }
    }

    // MARK: Internal writes (DocTransaction, undo, merge)

    func currentItem(_ id: ElementID, doc: DocumentID, page: PageID) -> Item? {
        (try? allItems(doc, page: page))?.first { $0.id == id }
    }

    @discardableResult
    func writeItem(_ item: Item, doc: DocumentID, page: PageID) throws -> Item? {
        var list = try allItems(doc, page: page)
        var old: Item?
        if let i = list.firstIndex(where: { $0.id == item.id }) {
            old = list[i]
            list[i] = item
        } else {
            list.append(item)
        }
        if old?.z != item.z { list = Workspace.sortedByZ(list) }
        pageItems[doc, default: [:]][page] = list
        return old
    }

    func removeItem(_ id: ElementID, doc: DocumentID, page: PageID) {
        pageItems[doc]?[page]?.removeAll { $0.id == id }
    }

    @discardableResult
    func writeRecord<T: LWWRecord>(_ record: T, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) throws -> T? {
        var h = try content(doc)
        var list = h[keyPath: path]
        var old: T?
        if let i = list.firstIndex(where: { $0.id == record.id }) {
            old = list[i]
            list[i] = record
        } else {
            list.append(record)
        }
        h[keyPath: path] = list
        heads[doc] = h
        return old
    }

    func removeRecord<T: LWWRecord>(_ id: NibID, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) {
        guard var h = heads[doc] else { return }
        h[keyPath: path].removeAll { $0.id == id }
        heads[doc] = h
    }

    func currentRecord<T: LWWRecord>(_ id: NibID, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) -> T? {
        (try? content(doc))?[keyPath: path].first { $0.id == id }
    }

    @discardableResult
    func writeMeta(_ meta: DocumentMeta) throws -> DocumentMeta {
        var h = try content(meta.id)
        let old = h.meta
        h.meta = meta
        heads[meta.id] = h
        return old
    }

    /// Hands changed state to persistence.
    func persist(_ cs: Changeset) {
        let itemPages = cs.itemPages
        for doc in cs.documents {
            guard let h = heads[doc] else { continue }
            var pages: [PageID: [Item]] = [:]
            for p in itemPages[doc] ?? [] {
                if let items = pageItems[doc]?[p] { pages[p] = items }
            }
            persistence.didChange(doc, head: cs.headChanged(doc) ? h : nil, pages: pages)
        }
    }

    /// Last-writer-wins merge of a remote patch. Returns the mutations that actually changed state.
    /// Remote revs more than 24 h ahead are distrusted (`Rev.effective`).
    func merge(_ patch: DocumentPatch) throws -> [Mutation] {
        let doc = patch.doc
        var out: [Mutation] = []
        if let m = patch.meta {
            clock.observe(m.rev)
            let current = try content(doc).meta
            if m.rev.effective() > current.rev.effective() {
                let before = try writeMeta(m)
                out.append(.meta(doc, before: before, after: m))
            }
        }
        for r in patch.pages { try mergeRecord(r, doc: doc, at: \.pages, into: &out) { .page(doc, before: $0, after: $1) } }
        for r in patch.outline { try mergeRecord(r, doc: doc, at: \.outline, into: &out) { .outline(doc, before: $0, after: $1) } }
        for r in patch.blocks { try mergeRecord(r, doc: doc, at: \.blocks, into: &out) { .block(doc, before: $0, after: $1) } }
        for r in patch.cards { try mergeRecord(r, doc: doc, at: \.cards, into: &out) { .card(doc, before: $0, after: $1) } }
        for r in patch.audio { try mergeRecord(r, doc: doc, at: \.audio, into: &out) { .audio(doc, before: $0, after: $1) } }
        for (pageRaw, items) in patch.items {
            let page = PageID(pageRaw)
            guard try content(doc).page(page) != nil else { continue }
            for it in items {
                clock.observe(it.rev)
                let current = currentItem(it.id, doc: doc, page: page)
                if let current = current, current.rev.effective() >= it.rev.effective() { continue }
                let before = try writeItem(it, doc: doc, page: page)
                out.append(.item(doc, page, before: before, after: it))
            }
        }
        return out
    }

    private func mergeRecord<T: LWWRecord>(_ record: T, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>,
                                           into out: inout [Mutation], wrap: (T?, T) -> Mutation) throws {
        clock.observe(record.rev)
        if let current = currentRecord(record.id, doc: doc, at: path), current.rev.effective() >= record.rev.effective() { return }
        let before = try writeRecord(record, doc: doc, at: path)
        out.append(wrap(before, record))
    }
}
```

### `NibKit/Sources/NibContracts/Core/DocTransaction.swift`

```swift
import Foundation

/// The ONLY way to change documents. Obtained exclusively inside `CommandContext.mutate { tx in … }`,
/// which runs synchronously on the main actor, so a transaction is atomic. Every write gets a fresh
/// revision and is recorded with its previous value (undo, sync, collaboration, events).
/// If the body throws, or an invariant fails, everything written is rolled back.
@MainActor
public final class DocTransaction {
    public let principal: Principal
    public let group: String
    let workspace: Workspace
    private(set) var mutations: [Mutation] = []

    init(workspace: Workspace, principal: Principal, group: String) {
        self.workspace = workspace
        self.principal = principal
        self.group = group
    }

    // MARK: Reads (see this transaction's own writes)

    public func content(_ doc: DocumentID) throws -> DocumentContent { try workspace.content(doc) }
    public func items(_ doc: DocumentID, page: PageID) throws -> [Item] { try workspace.items(doc, page: page) }
    public func item(_ doc: DocumentID, page: PageID, id: ElementID) throws -> Item { try workspace.item(doc, page: page, id: id) }

    /// A z key above every item on the page.
    public func topZ(_ doc: DocumentID, page: PageID) throws -> String {
        let last = try workspace.allItems(doc, page: page).last?.z
        return FractionalIndex.between(last, nil)
    }

    /// A z key below every item on the page.
    public func bottomZ(_ doc: DocumentID, page: PageID) throws -> String {
        let first = try workspace.allItems(doc, page: page).first?.z
        return FractionalIndex.between(nil, (first?.isEmpty ?? true) ? nil : first)
    }

    // MARK: Writes

    /// Inserts or replaces an item. Empty `z` = keep the existing z, or top of page for new items.
    @discardableResult
    public func put(_ item: Item, doc: DocumentID, page: PageID) throws -> Item {
        var it = item
        guard it.isValid else {
            throw NibError(.invariantViolation, "item \(it.id) must carry exactly the '\(it.kind.rawValue)' payload")
        }
        guard (0..<NibLimits.layerCount).contains(it.layer) else {
            throw NibError.invalid("layer must be 0...\(NibLimits.layerCount - 1)")
        }
        guard try content(doc).page(page) != nil else { throw NibError.notFound("page \(page) in document \(doc)") }
        let existing = workspace.currentItem(it.id, doc: doc, page: page)
        if it.z.isEmpty {
            if let z = existing?.z, !z.isEmpty { it.z = z } else { it.z = try topZ(doc, page: page) }
        }
        // Provenance cannot be forged: non-user principals always stamp themselves on create and never change it.
        if let existing = existing {
            if !principal.isUser { it.createdBy = existing.createdBy }
        } else if !principal.isUser || it.createdBy == nil {
            it.createdBy = principal.description
        }
        it.rev = workspace.clock.tick()
        let before = try workspace.writeItem(it, doc: doc, page: page)
        mutations.append(.item(doc, page, before: before, after: it))
        return it
    }

    /// Tombstones an item.
    public func delete(item id: ElementID, doc: DocumentID, page: PageID) throws {
        var it = try workspace.item(doc, page: page, id: id)
        it.deleted = true
        try put(it, doc: doc, page: page)
    }

    /// Inserts or replaces a page record. Empty `order` = append at the end.
    @discardableResult
    public func put(_ page: PageRecord, doc: DocumentID) throws -> PageRecord {
        var p = page
        if let s = p.size, !(1.0...100_000.0).contains(s.width) || !(1.0...100_000.0).contains(s.height) {
            throw NibError.invalid("page size out of range")
        }
        guard [0, 90, 180, 270].contains(p.rotation) else { throw NibError.invalid("rotation must be 0, 90, 180 or 270") }
        if p.order.isEmpty {
            let last = try content(doc).livePages.last?.order
            p.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(p, doc: doc, at: \.pages) { .page(doc, before: $0, after: $1) }
    }

    public func putMeta(_ meta: DocumentMeta) throws {
        var m = meta
        m.rev = workspace.clock.tick()
        let before = try workspace.writeMeta(m)
        mutations.append(.meta(m.id, before: before, after: m))
    }

    @discardableResult
    public func put(_ block: TextBlock, doc: DocumentID) throws -> TextBlock {
        var b = block
        if b.order.isEmpty {
            let last = try content(doc).liveBlocks.last?.order
            b.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(b, doc: doc, at: \.blocks) { .block(doc, before: $0, after: $1) }
    }

    @discardableResult
    public func put(_ card: StudyCard, doc: DocumentID) throws -> StudyCard {
        var c = card
        if c.order.isEmpty {
            let last = try content(doc).liveCards.last?.order
            c.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(c, doc: doc, at: \.cards) { .card(doc, before: $0, after: $1) }
    }

    @discardableResult
    public func put(_ clip: AudioClip, doc: DocumentID) throws -> AudioClip {
        try putRecord(clip, doc: doc, at: \.audio) { .audio(doc, before: $0, after: $1) }
    }

    @discardableResult
    public func put(_ entry: OutlineEntry, doc: DocumentID) throws -> OutlineEntry {
        var e = entry
        if e.order.isEmpty {
            let last = try content(doc).liveOutline.last?.order
            e.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(e, doc: doc, at: \.outline) { .outline(doc, before: $0, after: $1) }
    }

    private func putRecord<T: LWWRecord>(_ record: T, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>,
                                         wrap: (T?, T) -> Mutation) throws -> T {
        var r = record
        r.rev = workspace.clock.tick()
        let before = try workspace.writeRecord(r, doc: doc, at: path)
        mutations.append(wrap(before, r))
        return r
    }

    // MARK: Commit support (bus only)

    /// Referential invariants checked before commit.
    func validate() throws {
        for m in mutations {
            guard case let .item(doc, page, _, after) = m, !after.deleted else { continue }
            if let parent = after.attachedTo, workspace.currentItem(parent, doc: doc, page: page)?.deleted != false {
                throw NibError(.invariantViolation, "item \(after.id) is attached to missing item \(parent)")
            }
            if let c = after.connector {
                for end in [c.from, c.to] {
                    if let target = end.item, workspace.currentItem(target, doc: doc, page: page)?.deleted != false {
                        throw NibError(.invariantViolation, "connector \(after.id) points at missing item \(target)")
                    }
                }
            }
        }
    }

    /// Restores every record to its exact previous value (revisions included).
    func rollback() {
        for m in mutations.reversed() {
            switch m {
            case let .item(d, p, b, a):
                if let b = b { _ = try? workspace.writeItem(b, doc: d, page: p) } else { workspace.removeItem(a.id, doc: d, page: p) }
            case let .page(d, b, a): restore(b, a.id, d, \.pages)
            case let .meta(_, b, _): _ = try? workspace.writeMeta(b)
            case let .block(d, b, a): restore(b, a.id, d, \.blocks)
            case let .card(d, b, a): restore(b, a.id, d, \.cards)
            case let .audio(d, b, a): restore(b, a.id, d, \.audio)
            case let .outline(d, b, a): restore(b, a.id, d, \.outline)
            }
        }
        mutations.removeAll()
    }

    private func restore<T: LWWRecord>(_ before: T?, _ id: NibID, _ doc: DocumentID, _ path: WritableKeyPath<DocumentContent, [T]>) {
        if let b = before {
            _ = try? workspace.writeRecord(b, doc: doc, at: path)
        } else {
            workspace.removeRecord(id, doc: doc, at: path)
        }
    }

    /// Undo/redo/revert: writes each mutation's `before` (or a tombstone when it was an insert) with a fresh
    /// revision — but only where the record still carries the reverted revision, so later edits by other
    /// devices or collaborators are never overwritten. Returns the number of skipped records.
    func revert(_ muts: [Mutation]) -> Int {
        var skipped = 0
        for m in muts.reversed() {
            switch m {
            case let .item(d, p, b, a):
                guard let cur = workspace.currentItem(a.id, doc: d, page: p), cur.rev == a.rev else {
                    skipped += 1
                    continue
                }
                var target = b ?? a
                if b == nil { target.deleted = true }
                target.rev = workspace.clock.tick()
                _ = try? workspace.writeItem(target, doc: d, page: p)
                mutations.append(.item(d, p, before: cur, after: target))
            case let .page(d, b, a):
                if !revertRecord(b, a, d, \.pages, { .page(d, before: $0, after: $1) }) { skipped += 1 }
            case let .meta(d, b, a):
                guard let cur = try? workspace.content(d).meta, cur.rev == a.rev else {
                    skipped += 1
                    continue
                }
                var target = b
                target.rev = workspace.clock.tick()
                _ = try? workspace.writeMeta(target)
                mutations.append(.meta(d, before: cur, after: target))
            case let .block(d, b, a):
                if !revertRecord(b, a, d, \.blocks, { .block(d, before: $0, after: $1) }) { skipped += 1 }
            case let .card(d, b, a):
                if !revertRecord(b, a, d, \.cards, { .card(d, before: $0, after: $1) }) { skipped += 1 }
            case let .audio(d, b, a):
                if !revertRecord(b, a, d, \.audio, { .audio(d, before: $0, after: $1) }) { skipped += 1 }
            case let .outline(d, b, a):
                if !revertRecord(b, a, d, \.outline, { .outline(d, before: $0, after: $1) }) { skipped += 1 }
            }
        }
        return skipped
    }

    private func revertRecord<T: LWWRecord>(_ before: T?, _ after: T, _ doc: DocumentID,
                                            _ path: WritableKeyPath<DocumentContent, [T]>,
                                            _ wrap: (T?, T) -> Mutation) -> Bool {
        guard let cur = workspace.currentRecord(after.id, doc: doc, at: path), cur.rev == after.rev else { return false }
        var target = before ?? after
        if before == nil { target.deleted = true }
        target.rev = workspace.clock.tick()
        _ = try? workspace.writeRecord(target, doc: doc, at: path)
        mutations.append(wrap(cur, target))
        return true
    }
}
```

### `NibKit/Sources/NibContracts/Core/Undo.swift`

```swift
import Foundation

public struct UndoEntry {
    public let group: String
    public var label: String
    public let principal: Principal
    public var mutations: [Mutation]
    public let at: Date

    public init(group: String, label: String, principal: Principal, mutations: [Mutation], at: Date = Date()) {
        self.group = group
        self.label = label
        self.principal = principal
        self.mutations = mutations
        self.at = at
    }
}

/// Per-document undo/redo stacks. Consecutive commits with the same group merge into one entry
/// (one pen stroke, one eraser gesture, one plugin call, one AI turn). Lives from open to app quit.
@MainActor
public final class UndoHistory {
    public var limit = NibLimits.undoDepth
    private var undoStacks: [DocumentID: [UndoEntry]] = [:]
    private var redoStacks: [DocumentID: [UndoEntry]] = [:]

    public init() {}

    public func canUndo(_ doc: DocumentID) -> Bool { !(undoStacks[doc] ?? []).isEmpty }
    public func canRedo(_ doc: DocumentID) -> Bool { !(redoStacks[doc] ?? []).isEmpty }
    public func undoLabel(_ doc: DocumentID) -> String? { undoStacks[doc]?.last?.label }
    public func redoLabel(_ doc: DocumentID) -> String? { redoStacks[doc]?.last?.label }
    /// Oldest first.
    public func entries(_ doc: DocumentID) -> [UndoEntry] { undoStacks[doc] ?? [] }

    public func clear(_ doc: DocumentID) {
        undoStacks[doc] = nil
        redoStacks[doc] = nil
    }

    func record(_ cs: Changeset) {
        for doc in cs.documents {
            let muts = cs.mutations.filter { $0.document == doc }
            var stack = undoStacks[doc] ?? []
            if var top = stack.last, top.group == cs.group {
                top.mutations.append(contentsOf: muts)
                stack[stack.count - 1] = top
            } else {
                stack.append(UndoEntry(group: cs.group, label: cs.label, principal: cs.principal, mutations: muts))
                if stack.count > limit { stack.removeFirst(stack.count - limit) }
            }
            undoStacks[doc] = stack
            redoStacks[doc] = []
        }
    }

    func popUndo(_ doc: DocumentID) -> UndoEntry? { undoStacks[doc]?.popLast() }
    func popRedo(_ doc: DocumentID) -> UndoEntry? { redoStacks[doc]?.popLast() }
    func pushUndo(_ e: UndoEntry, doc: DocumentID) { undoStacks[doc, default: []].append(e) }
    func pushRedo(_ e: UndoEntry, doc: DocumentID) { redoStacks[doc, default: []].append(e) }

    func removeEntry(group: String, doc: DocumentID) -> UndoEntry? {
        guard let i = undoStacks[doc]?.lastIndex(where: { $0.group == group }) else { return nil }
        return undoStacks[doc]?.remove(at: i)
    }
}
```

### `NibKit/Sources/NibContracts/Core/Events.swift`

```swift
import Foundation

public enum NibEventType {
    public static let committed = "tx.committed"
    public static let docOpened = "doc.opened"
    public static let docClosed = "doc.closed"
    public static let sessionDocument = "session.document"
    public static let pageChanged = "page.changed"
    public static let toolChanged = "tool.changed"
    public static let selectionChanged = "selection.changed"
    public static let libraryChanged = "library.changed"
    public static let aiTurnFinished = "ai.turn.finished"
    public static let pluginMessage = "plugin.message"
    public static let syncStatus = "sync.status"
    /// Laser pointer moved (F040 → presentation F063, collaboration F108). Payload {page, point: [x, y], mode:
    /// "dot" | "trail"}; a payload without `point` means the laser was lifted.
    public static let laserMoved = "laser.moved"
    /// Backup queue or last-run state changed (F068 → Cloud & Backup panel F070); query `backup.status` for details.
    public static let backupStatus = "backup.status"
}

/// Events carry refs, not payloads: subscribers query for details.
public struct NibEvent: Codable {
    public let seq: UInt64
    public let type: String
    /// Unix seconds.
    public let at: Double
    public let principal: Principal?
    public let doc: DocumentID?
    public let changes: ChangeSummary?
    public let payload: JSONValue?
}

public final class EventSubscription {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// App-wide event bus with a ring buffer (the MCP bridge long-polls it). Handlers run synchronously on the
/// emitting thread (normally main) — keep them cheap and hop queues for heavy work. Thread-safe.
public final class EventBus {
    public let capacity = 5_000
    private let lock = NSLock()
    private var seq: UInt64 = 0
    private var ring: [NibEvent] = []
    private var handlers: [UUID: (NibEvent) -> Void] = [:]

    public init() {}

    @discardableResult
    public func emit(_ type: String, principal: Principal? = nil, doc: DocumentID? = nil,
                     changes: ChangeSummary? = nil, payload: JSONValue? = nil) -> NibEvent {
        lock.lock()
        seq += 1
        let e = NibEvent(seq: seq, type: type, at: Date().timeIntervalSince1970, principal: principal, doc: doc,
                         changes: changes, payload: payload)
        ring.append(e)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        let hs = Array(handlers.values)
        lock.unlock()
        for h in hs { h(e) }
        return e
    }

    /// The handler lives until `cancel()` is called on the returned subscription.
    @discardableResult
    public func subscribe(_ handler: @escaping (NibEvent) -> Void) -> EventSubscription {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return EventSubscription { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.handlers[id] = nil
            self.lock.unlock()
        }
    }

    public func stream(where filter: @escaping (NibEvent) -> Bool = { _ in true }) -> AsyncStream<NibEvent> {
        AsyncStream { continuation in
            let sub = self.subscribe { e in
                if filter(e) { continuation.yield(e) }
            }
            continuation.onTermination = { _ in sub.cancel() }
        }
    }

    public var lastSeq: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return seq
    }

    public func events(since: UInt64, limit: Int = 500) -> [NibEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring.filter { $0.seq > since }.prefix(limit))
    }

    /// Long-poll: returns as soon as events newer than `since` exist, or after `timeout` seconds.
    public func poll(since: UInt64, timeout: TimeInterval) async -> [NibEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let e = events(since: since)
            if !e.isEmpty || Date() >= deadline { return e }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
```

### `NibKit/Sources/NibContracts/Core/Bus.swift`

```swift
import Foundation

/// A JSON-level command call (plugins, AI, MCP bridge, key commands, menus).
public struct Invocation {
    public var command: String
    public var params: JSONValue
    public var principal: Principal
    public var session: EditorSession?
    /// Undo group; nil = a fresh group. Pass the same group to make several calls one undo step.
    public var group: String?
    /// Run, collect the change summary, then roll back. Nothing is persisted, recorded or emitted.
    public var dryRun: Bool
    public var depth: Int
    /// Ask mode: this call and everything it calls (nested commands, plugin handlers, batches) must be `read`.
    public var readOnly: Bool
    /// Confirmation policy inherited from an outer non-user caller (e.g. the AI running a plugin command whose
    /// handler calls more commands); the stricter of this and the principal's own policy applies.
    public var inheritedPolicy: ConfirmationPolicy?
    /// Set when running a command hook, so hooks never trigger hooks.
    public var skipHooks: Bool

    public init(command: String, params: JSONValue = [:], principal: Principal = .user, session: EditorSession? = nil,
                group: String? = nil, dryRun: Bool = false, depth: Int = 0, readOnly: Bool = false,
                inheritedPolicy: ConfirmationPolicy? = nil, skipHooks: Bool = false) {
        self.command = command
        self.params = params
        self.principal = principal
        self.session = session
        self.group = group
        self.dryRun = dryRun
        self.depth = depth
        self.readOnly = readOnly
        self.inheritedPolicy = inheritedPolicy
        self.skipHooks = skipHooks
    }
}

/// A before-command hook (plugins' `contributes.commandHooks`, features). The hook command must be `read`; it gets
/// {"command": id, "params": …} and returns {"params": …} to transform the call, `{}` to let it pass, or throws to
/// veto it. Registered in `app.bus.hooks`.
public struct CommandHookDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    /// Exact command ids or namespace wildcards ("page.*").
    public var commands: [String]
    /// The hook command to run.
    public var command: String
    /// Principal the hook runs as (`.plugin(id)` for plugins).
    public var principal: Principal

    public init(id: String, owner: String, commands: [String], command: String, principal: Principal = .user, order: Int = 0) {
        self.id = id
        self.order = order
        self.owner = owner
        self.commands = commands
        self.command = command
        self.principal = principal
    }

    public func matches(_ commandID: String) -> Bool {
        commands.contains { $0 == commandID || ($0.hasSuffix(".*") && commandID.hasPrefix(String($0.dropLast(1)))) }
    }
}

public struct InvocationResult: Codable {
    public var value: JSONValue
    public var changes: ChangeSummary
    public var group: String

    public init(value: JSONValue, changes: ChangeSummary, group: String) {
        self.value = value
        self.changes = changes
        self.group = group
    }
}

/// Handed to every command run. The only source of `DocTransaction`s.
@MainActor
public final class CommandContext {
    public let bus: CommandBus
    public let principal: Principal
    public let group: String
    public let depth: Int
    public let dryRun: Bool
    /// The invoking window's session (nil for bridge/background callers; see `activeSession`).
    public let session: EditorSession?
    public let commandID: String
    public let title: String
    /// True in ask mode and inside `read` commands (unless the descriptor `forwardsCalls`): nested calls must be
    /// `read` and `mutate` throws `permission_denied`. Plugin runtimes copy it into the Invocations they build.
    public let readOnly: Bool
    /// Passed on to nested calls (see `Invocation.inheritedPolicy`).
    public let inheritedPolicy: ConfirmationPolicy?
    public private(set) var summary = ChangeSummary()

    init(bus: CommandBus, principal: Principal, group: String, depth: Int, dryRun: Bool, session: EditorSession?,
         commandID: String, title: String, readOnly: Bool = false, inheritedPolicy: ConfirmationPolicy? = nil) {
        self.bus = bus
        self.principal = principal
        self.group = group
        self.depth = depth
        self.dryRun = dryRun
        self.session = session
        self.commandID = commandID
        self.title = title
        self.readOnly = readOnly
        self.inheritedPolicy = inheritedPolicy
    }

    public var workspace: Workspace { bus.workspace }
    public var services: NibServices { bus.services }
    public var events: EventBus { bus.events }
    /// The invoking session, else the most recently active window's session.
    public var activeSession: EditorSession? { session ?? bus.services.sessions.active }

    /// Runs synchronous writes atomically. Throwing (or an invariant failure) rolls everything back.
    /// All `mutate` calls in one command (and nested commands) share the undo group.
    /// `undoable: false` = persisted but not undoable (tape reveal, study grading, per-document view state).
    @discardableResult
    public func mutate<T>(_ label: String? = nil, undoable: Bool = true, _ body: (DocTransaction) throws -> T) throws -> T {
        if readOnly {
            throw NibError(.permissionDenied, "'\(commandID)' runs read-only and cannot change documents",
                           hint: "switch to Edit mode (AI), or declare the command with a mutating effect")
        }
        let tx = DocTransaction(workspace: bus.workspace, principal: principal, group: group)
        let result: T
        do {
            result = try body(tx)
            try tx.validate()
        } catch {
            tx.rollback()
            throw error
        }
        if dryRun {
            summary.merge(Changeset.summarize(tx.mutations))
            tx.rollback()
        } else if !tx.mutations.isEmpty {
            let cs = bus.commit(tx, label: label ?? title, command: commandID, record: undoable)
            summary.merge(cs.summary)
        }
        return result
    }

    /// Calls another command as the same principal, in the same undo group, inheriting read-only mode and the
    /// confirmation policy. Permission checks apply. An unknown nested command throws `unavailable`.
    public func execute(_ command: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let inv = Invocation(command: command, params: params, principal: principal, session: session,
                             group: group, dryRun: dryRun, depth: depth + 1, readOnly: readOnly,
                             inheritedPolicy: inheritedPolicy)
        let r = try await bus.execute(inv)
        summary.merge(r.changes)
        return r.value
    }

    /// Typed nested call (goes through the registry like any other call).
    public func execute<C: NibCommand>(_ type: C.Type, _ params: C.Params) async throws -> C.Output {
        let json = try JSONValue.from(params)
        let value = try await execute(C.descriptor.id, json)
        return try CommandRegistry.decode(C.Output.self, from: value)
    }

    /// Resolves a url-typed parameter to a local file this command may read. Accepted:
    /// "tmp:<name>" (from `asset.upload`, renders, exports), "https://…" (downloaded to a temp file), and
    /// "file://…" only for the user principal or inside this app's tmp / Documents/Inbox folders — so the AI,
    /// plugins and the bridge can never read arbitrary sandbox paths (e.g. a locked document's package).
    public func inputFile(_ string: String) async throws -> URL {
        let fm = FileManager.default
        if string.hasPrefix("tmp:") {
            guard let url = services.assets?.temporaryURL(AssetRef(String(string.dropFirst(4)))) else {
                throw NibError.notFound("temporary asset \(string)")
            }
            return url
        }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            throw NibError.invalid("not a URL: \(string)")
        }
        switch scheme {
        case "https", "http" where principal.isUser:
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NibError(.unavailable, "download failed: \(url.absoluteString)")
            }
            let dest = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try fm.moveItem(at: tmp, to: dest)
            return dest
        case "file":
            if principal.isUser { return url }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let allowed = [fm.temporaryDirectory,
                           fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox")]
                .map { $0.resolvingSymlinksInPath().path + "/" }
            guard allowed.contains(where: { path.hasPrefix($0) }) else {
                throw NibError(.permissionDenied, "file URLs are only accepted from the user",
                               hint: "upload the bytes with asset.upload and pass the returned tmp: ref")
            }
            return url
        default:
            throw NibError.invalid("unsupported URL '\(string)'; use a tmp: ref from asset.upload or an https URL")
        }
    }
}

/// Executes commands, commits transactions, drives undo/redo and merges remote changes.
@MainActor
public final class CommandBus {
    public let registry: CommandRegistry
    public let workspace: Workspace
    public let gateway: Gateway
    public let services: NibServices
    public let events: EventBus
    public let history: UndoHistory
    /// Before-command hooks (plugins' `contributes.commandHooks`, features). Run for every JSON and typed call.
    public let hooks = Registry<CommandHookDescriptor>()
    private var seq: UInt64 = 0
    private var observers: [UUID: (Changeset) -> Void] = [:]

    public init(registry: CommandRegistry, workspace: Workspace, gateway: Gateway, services: NibServices, events: EventBus) {
        self.registry = registry
        self.workspace = workspace
        self.gateway = gateway
        self.services = services
        self.events = events
        self.history = UndoHistory()
    }

    // MARK: Execution

    /// Typed fast path for native UI code (no JSON). Non-user principals are still authorized. Commands with
    /// registered hooks go through the JSON path so hooks see (and may transform) the call.
    @discardableResult
    public func run<C: NibCommand>(_ type: C.Type, _ params: C.Params, principal: Principal = .user,
                                   session: EditorSession? = nil, group: String? = nil) async throws -> C.Output {
        let d = C.descriptor
        let g = group ?? NibID.make().raw
        if hooks.all.contains(where: { $0.matches(d.id) }) {
            let r = try await execute(Invocation(command: d.id, params: try JSONValue.from(params), principal: principal,
                                                 session: session, group: g))
            return try CommandRegistry.decode(C.Output.self, from: r.value)
        }
        if !principal.isUser {
            let json = try JSONValue.from(params)
            try await gateway.authorize(d, params: json, principal: principal, group: g)
        }
        let ctx = CommandContext(bus: self, principal: principal, group: g, depth: 0, dryRun: false,
                                 session: session, commandID: d.id, title: d.title,
                                 readOnly: d.effect == .read && !d.forwardsCalls,
                                 inheritedPolicy: principal.isUser ? nil : gateway.policy(principal))
        return try await C.run(params, ctx)
    }

    /// JSON path used by plugins, AI, the bridge, menus and key commands.
    public func execute(_ inv: Invocation) async throws -> InvocationResult {
        guard inv.depth <= NibLimits.maxNesting else {
            throw NibError.invalid("command nesting deeper than \(NibLimits.maxNesting)")
        }
        guard let entry = registry.entry(inv.command) else {
            if inv.depth > 0 {
                // Nested call into a feature that is disabled or still a stub (fan-out): an optional dependency.
                throw NibError(.unavailable, "command '\(inv.command)' is not installed",
                               hint: "the feature that provides it is disabled or not built yet")
            }
            throw NibError(.notFound, "unknown command '\(inv.command)'", hint: "call commands.list to see available commands")
        }
        let d = entry.descriptor
        if inv.readOnly && d.effect != .read {
            throw NibError(.permissionDenied, "'\(d.id)' changes content but this call is read-only",
                           hint: "ask mode and read commands can only run read commands; switch to Edit mode")
        }
        var params: JSONValue = inv.params == .null ? [:] : inv.params
        let group = inv.group ?? NibID.make().raw
        if !inv.skipHooks {
            for hook in hooks.all where hook.matches(d.id) {
                let r = try await execute(Invocation(command: hook.command, params: ["command": .string(d.id), "params": params],
                                                     principal: hook.principal, session: inv.session, group: group,
                                                     dryRun: inv.dryRun, depth: inv.depth + 1, readOnly: true, skipHooks: true))
                if let replaced = r.value["params"], replaced != .null { params = replaced }
            }
        }
        if !inv.principal.isUser, let error = d.params.validate(params).first {
            throw NibError(error.code, error.message, path: error.path,
                           hint: "call commands.describe {\"id\": \"\(inv.command)\"} for the schema and examples")
        }
        try await gateway.authorize(d, params: params, principal: inv.principal, group: group,
                                    inheritedPolicy: inv.inheritedPolicy)
        let inherited = inv.principal.isUser
            ? inv.inheritedPolicy
            : ConfirmationPolicy.stricter(inv.inheritedPolicy, gateway.policy(inv.principal))
        let ctx = CommandContext(bus: self, principal: inv.principal, group: group, depth: inv.depth, dryRun: inv.dryRun,
                                 session: inv.session, commandID: d.id, title: d.title,
                                 readOnly: inv.readOnly || (d.effect == .read && !d.forwardsCalls),
                                 inheritedPolicy: inherited)
        let value = try await entry.handler(params, ctx)
        return InvocationResult(value: value, changes: ctx.summary, group: group)
    }

    /// Convenience JSON call returning only the value.
    @discardableResult
    public func execute(_ command: String, _ params: JSONValue = [:], principal: Principal = .user,
                        session: EditorSession? = nil) async throws -> JSONValue {
        try await execute(Invocation(command: command, params: params, principal: principal, session: session)).value
    }

    // MARK: Commit + observers

    @discardableResult
    func commit(_ tx: DocTransaction, label: String, command: String, record: Bool) -> Changeset {
        seq += 1
        let cs = Changeset(seq: seq, principal: tx.principal, group: tx.group, label: label, command: command, mutations: tx.mutations)
        if record && !cs.principal.isSync { history.record(cs) }
        finish(cs)
        return cs
    }

    private func finish(_ cs: Changeset) {
        workspace.persist(cs)
        for o in Array(observers.values) { o(cs) }
        for doc in cs.documents {
            events.emit(NibEventType.committed, principal: cs.principal, doc: doc, changes: cs.summary(for: doc))
        }
    }

    /// Synchronous callback for every commit, undo and remote merge (tile invalidation, indexing, collaboration).
    @discardableResult
    public func observeCommits(_ handler: @escaping (Changeset) -> Void) -> EventSubscription {
        let id = UUID()
        observers[id] = handler
        return EventSubscription { [weak self] in
            Task { @MainActor in self?.observers[id] = nil }
        }
    }

    // MARK: Undo / redo / selective revert

    @discardableResult
    public func undo(_ doc: DocumentID) -> Bool {
        guard let entry = history.popUndo(doc) else { return false }
        let tx = DocTransaction(workspace: workspace, principal: .user, group: "undo:" + entry.group)
        _ = tx.revert(entry.mutations)
        history.pushRedo(UndoEntry(group: entry.group, label: entry.label, principal: entry.principal, mutations: tx.mutations), doc: doc)
        finishUnrecorded(tx, label: "Undo " + entry.label, command: CommandIDs.undo)
        return true
    }

    @discardableResult
    public func redo(_ doc: DocumentID) -> Bool {
        guard let entry = history.popRedo(doc) else { return false }
        let tx = DocTransaction(workspace: workspace, principal: .user, group: "redo:" + entry.group)
        _ = tx.revert(entry.mutations)
        history.pushUndo(UndoEntry(group: entry.group, label: entry.label, principal: entry.principal, mutations: tx.mutations), doc: doc)
        finishUnrecorded(tx, label: "Redo " + entry.label, command: CommandIDs.redo)
        return true
    }

    /// Reverts one undo group (e.g. an AI turn) even after later edits; records the revert as a new undo step.
    /// Returns nil when the group is not in the history.
    public func revert(group: String, doc: DocumentID, principal: Principal = .user) -> (reverted: Int, skipped: Int)? {
        guard let entry = history.removeEntry(group: group, doc: doc) else { return nil }
        let tx = DocTransaction(workspace: workspace, principal: principal, group: NibID.make().raw)
        let skipped = tx.revert(entry.mutations)
        let n = tx.mutations.count
        if n > 0 { commit(tx, label: "Revert " + entry.label, command: CommandIDs.revertGroup, record: true) }
        return (n, skipped)
    }

    private func finishUnrecorded(_ tx: DocTransaction, label: String, command: String) {
        guard !tx.mutations.isEmpty else { return }
        seq += 1
        finish(Changeset(seq: seq, principal: tx.principal, group: tx.group, label: label, command: command, mutations: tx.mutations))
    }

    // MARK: Remote changes (sync + collaboration only)

    /// Merges records from another device (folder sync) or a collaborator. Not recorded for undo.
    /// The document must be loaded; unloaded documents merge from disk when opened.
    @discardableResult
    public func applyRemote(_ patch: DocumentPatch, origin: String) -> ChangeSummary {
        guard workspace.isLoaded(patch.doc) else { return ChangeSummary() }
        guard let muts = try? workspace.merge(patch), !muts.isEmpty else { return ChangeSummary() }
        seq += 1
        let cs = Changeset(seq: seq, principal: .sync(origin), group: "sync", label: "Sync", command: "sync.merge", mutations: muts)
        finish(cs)
        return cs.summary
    }
}

extension Principal {
    var isSync: Bool {
        if case .sync = self { return true }
        return false
    }
}
```

### `NibKit/Sources/NibContracts/Core/Gateway.swift`

```swift
import Foundation

public enum ConfirmationPolicy: String, Codable, CaseIterable {
    /// Confirm every mutating command.
    case always
    /// Confirm destructive commands (default).
    case destructive
    /// Never confirm (irreversible, sensitive and plugin-management commands are still confirmed).
    case never

    private var rank: Int {
        switch self {
        case .always: return 2
        case .destructive: return 1
        case .never: return 0
        }
    }

    /// The stricter of two policies (nil = no constraint).
    public static func stricter(_ a: ConfirmationPolicy?, _ b: ConfirmationPolicy?) -> ConfirmationPolicy? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        return a.rank >= b.rank ? a : b
    }
}

public struct ConfirmationRequest {
    public let principal: Principal
    public let command: CommandDescriptor
    public let params: JSONValue

    public init(principal: Principal, command: CommandDescriptor, params: JSONValue) {
        self.principal = principal
        self.command = command
        self.params = params
    }
}

public enum ConfirmationDecision { case allow, allowRestOfGroup, deny }

/// Shows the confirmation sheet. The app shell installs a minimal alert-based presenter at launch (so plugins and
/// the bridge work without the AI chat feature); F085 wraps it with its richer sheet for AI turns.
@MainActor
public protocol ConfirmationPresenter: AnyObject {
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision
}

/// Permission, lock and confirmation checks for every non-user call.
@MainActor
public final class Gateway {
    /// Granted scopes per principal. The plugin host replaces this to answer for `.plugin(id)`.
    public var grants: (Principal) -> Set<Scope>
    /// Confirmation policy per principal (AI / bridge settings).
    public var policy: (Principal) -> ConfirmationPolicy
    /// True when a document is locked for non-user principals (Password Lock feature).
    public var isLocked: (DocumentID) -> Bool
    public weak var presenter: ConfirmationPresenter?
    private var allowedGroups = Set<String>()

    public init() {
        grants = { p in Gateway.defaultGrants(p) }
        policy = { _ in .destructive }
        isLocked = { _ in false }
    }

    public nonisolated static func defaultGrants(_ p: Principal) -> Set<Scope> {
        switch p {
        case .user: return Set(Scope.allCases)
        case .ai, .bridge: return Set(Scope.allCases).subtracting([.security])
        case .plugin, .sync: return []
        }
    }

    public func authorize(_ d: CommandDescriptor, params: JSONValue, principal: Principal, group: String,
                          inheritedPolicy: ConfirmationPolicy? = nil) async throws {
        if principal.isUser { return }
        if case .sync = principal { throw NibError(.permissionDenied, "sync cannot run commands") }
        guard d.exposure.contains(principal.exposure) else {
            throw NibError(.permissionDenied, "'\(d.id)' is not available to \(principal)")
        }
        if d.scopes.contains(.security) {
            throw NibError(.permissionDenied, "'\(d.id)' can only be run by the user")
        }
        let missing = d.scopes.subtracting(grants(principal))
        guard missing.isEmpty else {
            throw NibError(.permissionDenied, "missing permission(s): " + missing.map { $0.rawValue }.sorted().joined(separator: ", "),
                           hint: "the user must grant these permissions")
        }
        for doc in Gateway.referencedDocuments(params) where isLocked(doc) {
            throw NibError(.locked, "document \(doc) is locked", hint: "ask the user to unlock it first")
        }
        guard needsConfirmation(d, principal: principal, inheritedPolicy: inheritedPolicy),
              !allowedGroups.contains(group) else { return }
        guard let presenter = presenter else {
            throw NibError(.userDenied, "'\(d.title)' needs confirmation but no confirmation UI is available")
        }
        switch await presenter.confirm(ConfirmationRequest(principal: principal, command: d, params: params)) {
        case .allow: return
        case .allowRestOfGroup: allowedGroups.insert(group)
        case .deny: throw NibError(.userDenied, "the user declined '\(d.title)'")
        }
    }

    public func needsConfirmation(_ d: CommandDescriptor, principal: Principal,
                                  inheritedPolicy: ConfirmationPolicy? = nil) -> Bool {
        if principal.isUser { return false }
        if d.effect == .irreversible || d.sensitive || d.scopes.contains(.pluginsManage) { return true }
        switch ConfirmationPolicy.stricter(policy(principal), inheritedPolicy) ?? .destructive {
        case .always: return d.isMutating
        case .destructive: return d.destructive
        case .never: return false
        }
    }

    /// Documents referenced by ref strings anywhere in `params`, or by bare ids under doc/document/docId keys.
    public nonisolated static func referencedDocuments(_ params: JSONValue) -> Set<DocumentID> {
        var out = Set<DocumentID>()
        func walk(_ v: JSONValue, key: String?) {
            switch v {
            case .string(let s):
                if let ref = NodeRef(s), let d = ref.documentID {
                    out.insert(d)
                } else if let k = key, ["doc", "document", "docId", "documentId"].contains(k), NibID.isValid(s) {
                    out.insert(NibID(s))
                }
            case .array(let a):
                for x in a { walk(x, key: key) }
            case .object(let o):
                for (k, x) in o { walk(x, key: k) }
            default:
                break
            }
        }
        walk(params, key: nil)
        return out
    }
}
```

### `NibKit/Sources/NibContracts/Core/Session.swift`

```swift
import Foundation
import Combine

public struct Selection: Equatable {
    public var doc: DocumentID?
    public var page: PageID?
    public var items: [ElementID]
    /// Page-coordinate bounds of the selection (lasso polygon bounds or item union).
    public var bounds: Rect?

    public init(doc: DocumentID? = nil, page: PageID? = nil, items: [ElementID] = [], bounds: Rect? = nil) {
        self.doc = doc
        self.page = page
        self.items = items
        self.bounds = bounds
    }

    public var isEmpty: Bool { items.isEmpty }

    public var refs: [String] {
        guard let d = doc, let p = page else { return [] }
        return items.map { NodeRef.item(d, p, $0).description }
    }
}

public enum ReplayMode: String, Codable, CaseIterable {
    /// Ink ahead of the playhead is faded.
    case spotlight
    /// Ink appears progressively as it was written.
    case reveal
    /// Everything visible, no animation ("Static").
    case showAll = "static"
}

/// Note Replay state: wall-clock time (unix seconds) being played back.
public struct ReplayState: Equatable {
    public var time: Double
    public var mode: ReplayMode
    public init(time: Double, mode: ReplayMode) {
        self.time = time
        self.mode = mode
    }
}

public enum StylusMode: String, Codable, CaseIterable {
    /// Apple Pencil draws, fingers scroll/select.
    case pencilOnly
    /// Fingers, mouse and passive styluses draw ("Disconnect Apple Pencil").
    case anyInput
}

/// Per-window editor state (not persisted in documents). Changed by `.session` commands and editor UI.
@MainActor
public final class EditorSession: ObservableObject {
    /// The event bus of the app this session belongs to (set by `SessionRegistry.add`); changes are emitted there.
    /// Per session, not static, so two `NibApp`s in one process (two-device tests) never cross-talk.
    public weak var events: EventBus?

    public let id: NibID
    @Published public var document: DocumentID? = nil {
        didSet { if oldValue != document { notify(NibEventType.sessionDocument) } }
    }
    @Published public var page: PageID? = nil {
        didSet { if oldValue != page { notify(NibEventType.pageChanged) } }
    }
    /// Active canvas tool id ("pen", "lasso", "eraser", plugin tool ids…).
    @Published public var tool: String = "pen" {
        didSet {
            if oldValue != tool {
                previousTool = oldValue
                notify(NibEventType.toolChanged)
            }
        }
    }
    @Published public var previousTool: String? = nil
    @Published public var selection = Selection() {
        didSet { if oldValue != selection { notify(NibEventType.selectionChanged) } }
    }
    @Published public var zoom: Double = 1
    /// Visible part of the current page in page coordinates.
    @Published public var visibleRect: Rect? = nil
    @Published public var readOnly = false
    @Published public var activeLayer = 0
    /// Per-device layer visibility.
    @Published public var hiddenLayers: Set<Int> = []
    /// Note Replay in progress (the canvas passes it to the renderer).
    @Published public var replay: ReplayState? = nil
    /// True while a text view (text box, block, card field) is first responder; single-key shortcuts are off.
    public var isEditingText = false
    /// Transient per-tool options (current preset slot, eraser size…), keyed by tool id.
    public var toolOptions: [String: JSONValue] = [:]
    /// The editor view controller showing `document` (set by the editor).
    public weak var editor: DocumentEditing?

    public init(id: NibID = NibID.make()) {
        self.id = id
    }

    private func notify(_ kind: String) {
        events?.emit(kind, doc: document, payload: ["session": .string(id.raw)])
    }
}

@MainActor
public final class SessionRegistry {
    public private(set) var sessions: [EditorSession] = []
    public private(set) weak var active: EditorSession?
    /// Set by `NibApp.init`; handed to every added session.
    public weak var events: EventBus?

    public init() {}

    public func add(_ s: EditorSession) {
        if !sessions.contains(where: { $0 === s }) { sessions.append(s) }
        s.events = events
        active = s
    }

    public func remove(_ s: EditorSession) {
        sessions.removeAll { $0 === s }
        if active === s { active = sessions.last }
    }

    public func activate(_ s: EditorSession) { active = s }

    public func session(_ id: NibID) -> EditorSession? { sessions.first { $0.id == id } }
}
```

### `NibKit/Sources/NibContracts/Core/Services.swift`

```swift
import Foundation
import CoreGraphics

// MARK: - Library (implemented by the Library Store feature)

/// The library folder: folders are directories, documents are `.nib` packages, trash lives in `.nib-library/trash`.
@MainActor
public protocol LibraryService: AnyObject {
    /// Library root (security-scoped folder the user picked; default = app Documents).
    var rootURL: URL { get }
    /// `<root>/.nib-library` (trash, plugins, elements, templates, prefs, AI chats).
    var metadataURL: URL { get }
    /// All non-trashed folders and documents (cached catalog).
    func allNodes() -> [LibraryNode]
    func node(_ id: NibID) -> LibraryNode?
    /// Children of a folder (nil = root), non-trashed.
    func children(of folder: FolderID?) -> [LibraryNode]
    /// Main actor only. Off-main code (persistence I/O, AssetStore, renderers) uses `NibServices.packages`,
    /// which the implementation keeps in sync with its catalog.
    func packageURL(_ doc: DocumentID) -> URL?
    /// Writes a new package with `content` (first page(s) included) and returns its id.
    func createDocument(_ content: DocumentContent, title: String, in folder: FolderID?) throws -> DocumentID
    func createFolder(title: String, in parent: FolderID?, style: FolderStyle?) throws -> FolderID
    func rename(_ id: NibID, to title: String) throws
    /// Moves a folder or document into `folder` (nil = root).
    func move(_ id: NibID, to folder: FolderID?) throws
    func duplicate(_ id: NibID) throws -> NibID
    func setStyle(_ style: FolderStyle, folder: FolderID) throws
    func trash(_ id: NibID) throws
    func trashedNodes() -> [LibraryNode]
    /// Restores to the original location (or `folder` when given / when the original is gone).
    func restore(_ id: NibID, to folder: FolderID?) throws
    func deletePermanently(_ id: NibID) throws
    /// Copies an external `.nibnote` package (or a legacy `.nib` package, or a folder of them) into the library.
    func importPackage(at url: URL, into folder: FolderID?) throws -> DocumentID
    /// Rescans the disk (after sync, import, repair).
    func refresh()
    /// Switches the library to another folder (security-scoped URL chosen by the user).
    func setRoot(_ url: URL) throws
}

// MARK: - Package locations (thread-safe)

/// Document id → package URL, readable from any thread. The Library Store feature (F002) fills it whenever its
/// catalog changes; persistence and `AssetStore` capture it at registration (`app.services.packages`) and read it
/// off-main. Nothing that runs off-main may touch `NibApp`, `NibServices` or any other `@MainActor` type.
public final class PackageLocator {
    private var urls: [DocumentID: URL] = [:]
    private let lock = NSLock()

    public init() {}

    public func url(_ doc: DocumentID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls[doc]
    }

    public func set(_ url: URL?, for doc: DocumentID) {
        lock.lock()
        urls[doc] = url
        lock.unlock()
    }

    public func replaceAll(_ all: [DocumentID: URL]) {
        lock.lock()
        urls = all
        lock.unlock()
    }
}

// MARK: - Assets (implemented by the Document Store feature)

/// Content-addressed binary storage inside document packages. Thread-safe (drawers call it from render
/// threads); implementations find packages through a captured `PackageLocator`, never through `NibServices`.
public protocol AssetStore: AnyObject {
    /// Stores bytes as `assets/<sha256>.<ext>` in the document package (deduplicated).
    func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef
    func url(_ ref: AssetRef, doc: DocumentID) -> URL?
    func data(_ ref: AssetRef, doc: DocumentID) throws -> Data
    /// App-level scratch asset (renders for AI/bridge, clipboard). Expires after one hour.
    func putTemporary(_ data: Data, ext: String) throws -> AssetRef
    func temporaryURL(_ ref: AssetRef) -> URL?
}

// MARK: - Rendering (implemented by the Renderer feature)

public struct RenderRequest {
    public var doc: DocumentID
    public var page: PageID
    /// Page coordinates; nil = whole page (boards: content bounds).
    public var region: Rect?
    /// Pixels per point.
    public var scale: Double
    /// nil = the session's visible layers (all layers when rendering headless).
    public var layers: Set<Int>?
    public var background: Bool
    public var annotations: Bool
    public var hidden: Set<ElementID>
    /// Draw numbered boxes over items (Set-of-Mark prompting for vision models).
    public var marks: Bool
    public var replay: ReplayState?

    public init(doc: DocumentID, page: PageID, region: Rect? = nil, scale: Double = 2, layers: Set<Int>? = nil,
                background: Bool = true, annotations: Bool = true, hidden: Set<ElementID> = [], marks: Bool = false,
                replay: ReplayState? = nil) {
        self.doc = doc
        self.page = page
        self.region = region
        self.scale = scale
        self.layers = layers
        self.background = background
        self.annotations = annotations
        self.hidden = hidden
        self.marks = marks
        self.replay = replay
    }
}

public struct RenderResult {
    public var image: CGImage
    /// Page region actually rendered.
    public var region: Rect
    public var scale: Double
    /// Mark number → item ref (when `marks` was requested).
    public var marks: [String: String]

    public init(image: CGImage, region: Rect, scale: Double, marks: [String: String] = [:]) {
        self.image = image
        self.region = region
        self.scale = scale
        self.marks = marks
    }
}

public protocol PageRenderer: AnyObject {
    func render(_ request: RenderRequest) async throws -> RenderResult
    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage?
    /// Drop cached tiles/thumbnails for a page region (nil = whole page).
    func invalidate(doc: DocumentID, page: PageID, rect: Rect?)
    /// Memory pressure: drop every cache that can be rebuilt.
    func purgeCaches()
}

// MARK: - Recognition (implemented by the Search Index feature)

/// One recognised text block (named `TextRecognition`, not `RecognizedText`, to avoid the iOS 18 Vision type).
public struct TextRecognition: Codable, Equatable {
    public var text: String
    public var alternatives: [String]
    /// Page coordinates (image pixel coordinates for `recognize(image:)`).
    public var bbox: Rect
    /// Stroke/text items the text came from.
    public var itemIDs: [ElementID]
    /// "ink", "typed", "pdf", "scan", "image", "transcript".
    public var source: String
    public var confidence: Double

    public init(text: String, alternatives: [String] = [], bbox: Rect, itemIDs: [ElementID] = [], source: String, confidence: Double = 1) {
        self.text = text
        self.alternatives = alternatives
        self.bbox = bbox
        self.itemIDs = itemIDs
        self.source = source
        self.confidence = confidence
    }
}

public protocol TextRecognizer: AnyObject {
    /// Line-level recognition of stroke items (Vision on an ink-only render). Word boxes map back to stroke ids.
    func recognize(strokes: [Item], language: String) async throws -> [TextRecognition]
    func recognize(image: CGImage, language: String) async throws -> [TextRecognition]
}

// MARK: - PDF (implemented by the PDF Engine feature)

public struct PDFLinkInfo: Codable, Equatable {
    /// Page coordinates (top-left origin).
    public var rect: Rect
    public var url: String?
    /// Internal destination (0-based page index in the same PDF).
    public var pageIndex: Int?
    public init(rect: Rect, url: String? = nil, pageIndex: Int? = nil) {
        self.rect = rect
        self.url = url
        self.pageIndex = pageIndex
    }
}

public struct PDFOutlineNode: Codable, Equatable {
    public var title: String
    public var pageIndex: Int?
    public var children: [PDFOutlineNode]
    public init(title: String, pageIndex: Int?, children: [PDFOutlineNode] = []) {
        self.title = title
        self.pageIndex = pageIndex
        self.children = children
    }
}

/// PDF text, links and outline (PDFKit). Coordinates are converted to page points with a top-left origin.
public protocol PDFService: AnyObject {
    func pageCount(_ url: URL) -> Int
    func pageSize(_ url: URL, page: Int) -> PageSize?
    func text(_ url: URL, page: Int) -> String?
    func textBlocks(_ url: URL, page: Int) -> [TextRecognition]
    func links(_ url: URL, page: Int) -> [PDFLinkInfo]
    func outline(_ url: URL) -> [PDFOutlineNode]
    /// Text and line rects of a drag selection between two page points.
    func selection(_ url: URL, page: Int, from: Point, to: Point) -> (text: String, rects: [Rect])
}

// MARK: - Password lock (implemented by the Password Lock feature)

@MainActor
public protocol LockService: AnyObject {
    /// Locked and not unlocked in this app session.
    func isLocked(_ doc: DocumentID) -> Bool
    /// Prompts (Face ID / password). True when unlocked.
    func unlock(_ doc: DocumentID) async -> Bool
}

// MARK: - Container

/// Service locator filled by features in `register`. Never resolve services during `register`; resolve at use time.
@MainActor
public final class NibServices {
    public let settings: SettingsStore
    public let sessions: SessionRegistry
    /// Thread-safe package URLs (filled by the Library Store feature; see `PackageLocator`).
    public let packages = PackageLocator()
    public var library: LibraryService?
    public var assets: AssetStore?
    public var renderer: PageRenderer?
    public var recognizer: TextRecognizer?
    public var pdf: PDFService?
    public var ai: AIService?
    public var lock: LockService?
    private var extras: [String: AnyObject] = [:]

    public init(settings: SettingsStore) {
        self.settings = settings
        self.sessions = SessionRegistry()
    }

    /// Escape hatch for feature-to-feature services not in the contracts (key = "<featureId>.<name>").
    public func set(_ service: AnyObject?, for key: String) { extras[key] = service }
    public func get<T>(_ key: String, as type: T.Type = T.self) -> T? { extras[key] as? T }

    /// Unwraps an optional service or throws `unavailable`.
    public func require<T>(_ service: T?, _ name: String) throws -> T {
        guard let s = service else { throw NibError.unavailable(name) }
        return s
    }
}
```

### `NibKit/Sources/NibContracts/Core/AIService.swift`

```swift
import Foundation

/// Ask = read-only tools ("Create mode off"); edit = all tools ("Create mode on").
public enum AIMode: String, Codable, CaseIterable { case ask, edit }

public enum AIScopeKind: String, Codable, CaseIterable { case selection, page, document, library, block }

public struct AIScope: Codable, Equatable {
    public var kind: AIScopeKind
    public var doc: DocumentID?
    public var page: PageID?
    /// Selected item / block refs.
    public var refs: [String]

    public init(kind: AIScopeKind, doc: DocumentID? = nil, page: PageID? = nil, refs: [String] = []) {
        self.kind = kind
        self.doc = doc
        self.page = page
        self.refs = refs
    }
}

public struct AIMessage: Codable, Equatable {
    /// "user" | "assistant".
    public var role: String
    public var text: String
    /// Images stored with `AssetStore.putTemporary` or in the document.
    public var images: [AssetRef]?

    public init(role: String, text: String, images: [AssetRef]? = nil) {
        self.role = role
        self.text = text
        self.images = images
    }
}

public struct AIRequest {
    /// Continue a stored conversation (nil = new chat).
    public var chatID: String?
    /// Extra system instructions appended to Nib's system prompt.
    public var system: String?
    public var messages: [AIMessage]
    /// Command ids the model may call directly as tools; nil = the default catalogue for `mode`; [] = no tools.
    public var tools: [String]?
    public var mode: AIMode
    public var scope: AIScope?
    /// Tool calls run as this principal (plugins calling `nib.ai.complete` stay `.plugin(id)`).
    public var principal: Principal
    /// Undo group for everything the turn changes (nil = one fresh group per turn).
    public var group: String?
    public var maxSteps: Int
    /// Ask for a JSON-only answer (feature-internal prompts).
    public var jsonOutput: Bool

    public init(chatID: String? = nil, system: String? = nil, messages: [AIMessage], tools: [String]? = nil,
                mode: AIMode = .ask, scope: AIScope? = nil, principal: Principal = .ai("internal"), group: String? = nil,
                maxSteps: Int = 40, jsonOutput: Bool = false) {
        self.chatID = chatID
        self.system = system
        self.messages = messages
        self.tools = tools
        self.mode = mode
        self.scope = scope
        self.principal = principal
        self.group = group
        self.maxSteps = maxSteps
        self.jsonOutput = jsonOutput
    }
}

public struct AIUsage: Codable, Equatable {
    public var input: Int
    public var output: Int
    public init(input: Int = 0, output: Int = 0) {
        self.input = input
        self.output = output
    }
}

public struct AIResponse: Codable {
    public var text: String
    public var changes: ChangeSummary
    /// Undo group of the turn (for "Undo" / `history.revertGroup`).
    public var group: String?
    public var usage: AIUsage
    public var chatID: String?

    public init(text: String, changes: ChangeSummary = ChangeSummary(), group: String? = nil, usage: AIUsage = AIUsage(), chatID: String? = nil) {
        self.text = text
        self.changes = changes
        self.group = group
        self.usage = usage
        self.chatID = chatID
    }
}

public enum AIStreamEvent {
    case text(String)
    case toolStarted(name: String, arguments: JSONValue)
    case toolFinished(name: String, ok: Bool, changes: ChangeSummary?)
    case finished(AIResponse)
    case failed(NibError)
}

public struct AIChatSummary: Codable, Identifiable {
    public var id: String
    public var title: String
    public var doc: DocumentID?
    public var updated: Double
    public init(id: String, title: String, doc: DocumentID?, updated: Double) {
        self.id = id
        self.title = title
        self.doc = doc
        self.updated = updated
    }
}

/// Bring-your-own-AI service (implemented by the AI Agent feature). Every feature that needs a model
/// (summaries, math, meeting notes, title suggestions, plugins' `nib.ai.complete`) goes through this.
@MainActor
public protocol AIService: AnyObject {
    var isConfigured: Bool { get }
    var supportsVision: Bool { get }
    /// Streams a turn (text deltas, tool calls). Tool calls go through the command bus as `request.principal`.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
    /// Runs a turn to completion.
    func complete(_ request: AIRequest) async throws -> AIResponse
    func cancel(chatID: String)
    func chats(doc: DocumentID?) -> [AIChatSummary]
    func messages(chatID: String) -> [AIMessage]
    func deleteChat(_ chatID: String)
    /// Cloud transcription via the provider's audio endpoint; throws `unsupported` when unavailable.
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment]
    /// Image generation via the provider; throws `unsupported` when unavailable.
    func generateImage(prompt: String) async throws -> Data
}

// MARK: - Tool catalogue (AI.md §4), shared by the in-app agent (F084) and the MCP bridge (F090)

@MainActor
public enum ToolCatalog {
    /// The nine meta-tools. Their set never grows; every command is reachable through `nib_run`.
    public static let metaTools: [ToolSpec] = [
        spec("nib_context", "Where the user is: document, page, visible rect, tool, selection refs/bbox, tabs.", .empty),
        spec("nib_get", "Any node (library, folder, doc, page, item, block, card) as JSON; stroke points only with points=true.",
             .obj(["ref": .ref, "depth": .int(min: 0, max: 4), "points": .bool(), "fields": .arr(.str())], required: ["ref"])),
        spec("nib_find", "Find items by kind, layer, area (bbox), field equality (where) or text inside a page or document.",
             .obj(["in": .ref, "kinds": .arr(.str()), "layer": .int(min: 0, max: 4), "bbox": .rect, "where": .anything(),
                   "text": .str(), "limit": .int(min: 1, max: 500), "cursor": .str()], required: ["in"])),
        spec("nib_search", "Full-text search over handwriting, typed text, PDFs, titles and transcripts.",
             .obj(["query": .str(), "scope": .str("doc:D or lib")], required: ["query"])),
        spec("nib_page_text", "Recognised text blocks of a page with bboxes, sources and item ids.",
             .obj(["page": .ref], required: ["page"])),
        spec("nib_render", "Render a page (or region) as an image; marks=true numbers the items and returns mark → ref.",
             .obj(["page": .ref, "region": .rect, "scale": .num(min: 0.1, max: 8), "marks": .bool()], required: ["page"])),
        spec("nib_commands", "List the commands you may call (id, one-line summary, effect), optionally for one namespace.",
             .obj(["namespace": .str()])),
        spec("nib_command_schema", "Full JSON schema and examples of one command. Read it before using an unfamiliar command.",
             .obj(["id": .str()], required: ["id"])),
        spec("nib_run", "Run one command {command, params} or several {calls:[{command, params}]} as one undo step; dry_run previews.",
             .obj(["command": .str(), "params": .anything(), "calls": .arr(.obj(["command": .str(), "params": .anything()])),
                   "dry_run": .bool()]))
    ]

    /// Meta-tools plus the direct tools (command ids) visible to `exposure`; ask mode keeps only `read` commands.
    public static func tools(_ registry: CommandRegistry, exposure: Exposure, readOnly: Bool, direct: [String]) -> [ToolSpec] {
        var out = metaTools
        for id in direct {
            guard let d = registry.descriptor(id), d.exposure.contains(exposure), !readOnly || d.effect == .read else { continue }
            out.append(ToolSpec(name: d.toolName, description: d.summary, schema: d.params.toJSON()))
        }
        return out
    }

    /// The Invocation a tool call stands for (nil = unknown tool). `nib_render` maps to `render.page`: callers turn
    /// its `asset` into an image part (or page text for models without vision). `readOnly` = ask mode.
    public static func invocation(tool: String, arguments: JSONValue, registry: CommandRegistry, principal: Principal,
                                  group: String, readOnly: Bool, session: EditorSession? = nil) -> Invocation? {
        func inv(_ command: String, _ params: JSONValue, dryRun: Bool = false) -> Invocation {
            Invocation(command: command, params: params, principal: principal, session: session, group: group,
                       dryRun: dryRun, readOnly: readOnly)
        }
        let args = arguments == .null ? [:] : arguments
        switch tool {
        case "nib_context": return inv(CommandIDs.queryContext, [:])
        case "nib_get": return inv(CommandIDs.queryGet, args)
        case "nib_find": return inv(CommandIDs.queryFind, args)
        case "nib_search": return inv(CommandIDs.searchText, args)
        case "nib_page_text": return inv(CommandIDs.recognizePageText, args)
        case "nib_render": return inv(CommandIDs.renderPage, args)
        case "nib_commands": return inv(CommandIDs.commandsList, args)
        case "nib_command_schema": return inv(CommandIDs.commandsDescribe, args)
        case "nib_run":
            let dry = args["dry_run"]?.boolValue ?? false
            if let calls = args["calls"] { return inv(CommandIDs.batch, ["calls": calls], dryRun: dry) }
            return inv(args["command"]?.stringValue ?? "", args["params"] ?? [:], dryRun: dry)
        default:
            guard let d = registry.all().first(where: { $0.toolName == tool }) else { return nil }
            return inv(d.id, args)
        }
    }

    private static func spec(_ name: String, _ description: String, _ schema: JSONSchema) -> ToolSpec {
        ToolSpec(name: name, description: description, schema: schema.toJSON())
    }
}
```

### `NibKit/Sources/NibContracts/Core/Extensibility.swift`

```swift
import Foundation

/// Keys for services shared through `NibServices.set(_:for:)` / `get(_:as:)` (typed by the protocols below).
public enum ServiceKeys {
    /// `PluginRuntimeProviding` (Plugin Runtime feature).
    public static let pluginRuntime = "plugins.runtime"
    /// `PluginHosting` (Plugin Host feature).
    public static let pluginHost = "plugins.host"
    /// `PluginPanelFactory` (Plugin Panels feature).
    public static let pluginPanels = "plugins.panels"
    /// `AIProviderStore` (AI Providers feature).
    public static let aiProviders = "ai.providers"
    /// `CollabTransport` implementations.
    public static let collabMultipeer = "collab.transport.multipeer"
    public static let collabRelay = "collab.transport.relay"
}

// MARK: - Plugin manifest (see docs/PLUGIN_API.md)
// These types are built by decoding manifest JSON (tests: `PluginManifest.fixture(...)` in NibTesting).

public struct PluginNetwork: Codable, Equatable {
    /// Hostnames the plugin (and its panels) may reach with the "network" permission.
    public var hosts: [String]
    public init(hosts: [String]) { self.hosts = hosts }
}

public struct PluginCommandContribution: Codable, Equatable {
    /// Must start with the plugin id: "<pluginId>.<name>".
    public var id: String
    public var title: String
    public var summary: String
    /// JSON Schema of the params (flat subset recommended).
    public var params: JSONValue?
    /// "read" | "session" | "edit" | "library" | "irreversible" (default "edit").
    public var effect: String?
    /// "document" | "library" | "app" (default "document").
    public var target: String?
    public var destructive: Bool?
    public var examples: [JSONValue]?
    /// Exposed to the in-app AI (default true) and the MCP bridge (default true).
    public var ai: Bool?
    public var bridge: Bool?
    /// Offered to the AI as its own tool instead of only via nib_run.
    public var aiDirect: Bool?
    /// Allows handlers to run up to 300 s instead of 30 s.
    public var longRunning: Bool?
}

public struct PluginWhen: Codable, Equatable {
    /// Item kinds that must all be in the selection (e.g. ["stroke"]).
    public var selectionKinds: [String]?
    public var minSelection: Int?
    public var docKinds: [String]?
}

public struct PluginMenuContribution: Codable, Equatable {
    /// A `MenuLocation` raw value, e.g. "objectMenu", "documentMore", "libraryItem".
    public var location: String
    public var command: String
    public var title: String?
    public var icon: String?
    public var when: PluginWhen?
}

public struct PluginToolbarContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String
    /// "tools" | "accessories" (default "accessories").
    public var group: String?
    public var command: String?
    /// A plugin canvas tool id (from `tools`).
    public var tool: String?
}

public struct PluginToolContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    /// "stroke" (pts on lift) | "tap" (point) | "rect" (drag rectangle).
    public var input: String
    /// "ink" | "lasso" | "none" (host-drawn preview).
    public var preview: String?
    public var sticky: Bool?
    /// Command invoked with {page, pts, fmt, bbox} | {page, point} | {page, rect}.
    public var command: String
}

public struct PluginPanelContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    /// Path of the HTML file inside the plugin folder.
    public var entry: String
    /// A `PanelPlacement` raw value (default "floating").
    public var placement: String?
}

public struct PluginTemplateContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var category: String?
    /// "spec" (DisplayList with $param substitution) | "pdf" (file in the plugin folder).
    public var kind: String
    public var isCover: Bool?
    /// {"name": {"type": "number|color|choice|bool", "default": …, "choices": […]}}
    public var params: JSONValue?
    /// {"paper": "#FFFFFF", "ops": [DisplayOp…]} for kind "spec".
    public var spec: JSONValue?
    public var file: String?
    public var size: PageSize?
}

public struct PluginKeybinding: Codable, Equatable {
    /// e.g. "cmd+shift+f", "alt+1".
    public var key: String
    public var command: String
    public var title: String?
}

public struct PluginAIAction: Codable, Equatable {
    public var title: String
    public var prompt: String
    /// An `AIScopeKind` raw value (default "selection").
    public var scope: String?
    /// "ask" | "edit" (default "ask").
    public var mode: String?
    public var icon: String?
}

public struct PluginAIGuidance: Codable, Equatable {
    /// ≤ 1,000 characters appended to the AI system prompt while the plugin is enabled.
    public var instructions: String?
}

public struct PluginFileHandler: Codable, Equatable {
    public var extensions: [String]
    public var command: String
    public var title: String?
}

public struct PluginItemType: Codable, Equatable {
    /// Custom item `type`; items are `custom` items with `owner` = plugin id.
    public var type: String
    public var title: String
    /// Command called with {ref} when the item is double-tapped (optional).
    public var edit: String?
    /// JSON Schema of `data` fields shown as an inspector form (writes go through `item.update`).
    public var inspector: JSONValue?
    /// Dot path inside `data` holding the item's text; indexed by search and returned by `recognize.pageText`.
    public var textPath: String?
}

/// Offers finger taps / double-taps / long-presses to a plugin command before the active tool
/// (→ `TapHandlerDescriptor`). The command gets {page, point, ref?, gesture} and returns {handled}.
public struct PluginTapHandler: Codable, Equatable {
    /// "tap" | "doubleTap" | "longPress".
    public var gesture: String
    public var command: String
    /// Only when the topmost item under the point is one of these kinds / custom types of this plugin.
    public var itemKinds: [String]?
    public var itemTypes: [String]?
}

/// An options bar for a plugin canvas tool: a form over some of the plugin's `settings` keys.
public struct PluginToolOptions: Codable, Equatable {
    public var tool: String
    public var settings: [String]
}

/// A text-document block kind (`BlockKind.custom` with `CustomBlock.type`), offered in the slash menu and Turn Into.
public struct PluginBlockContribution: Codable, Equatable {
    public var type: String
    public var title: String
    public var icon: String?
    public var height: Double?
    /// Called with {doc, after?} to insert the block, and with {ref} when the block is tapped for editing.
    public var command: String
    public var aliases: [String]?
}

/// A stroke processor: the command runs once per finished stroke with {page, stroke} and may return {stroke} or
/// {drop: true}. 50 ms budget; on timeout or error the raw stroke is kept.
public struct PluginStrokeProcessor: Codable, Equatable {
    public var id: String
    public var command: String
    /// Tool ids it applies to (default: pen, pencil, highlighter).
    public var tools: [String]?
}

/// An action users can bind to Apple Pencil double-tap or squeeze (Pencil settings).
public struct PluginPencilAction: Codable, Equatable {
    /// "doubleTap" | "squeeze".
    public var gesture: String
    public var command: String
    public var title: String
}

/// A before-command hook (→ `CommandHookDescriptor`); the hook command must have effect "read".
public struct PluginCommandHook: Codable, Equatable {
    /// Command ids or namespace wildcards ("page.*").
    public var commands: [String]
    public var command: String
}

/// A sticker/element collection: fragment JSON files (clipboard fragment format) inside the plugin folder.
public struct PluginElementCollection: Codable, Equatable {
    public var id: String
    public var title: String
    public var files: [String]
}

/// A tape pattern tile (PNG, ~100 px) inside the plugin folder.
public struct PluginTapePattern: Codable, Equatable {
    public var id: String
    public var title: String
    public var file: String
}

/// A whiteboard framework for `board.insertTemplate`: `diagram` = diagram.create params without `page`, or `file` =
/// a fragment JSON file.
public struct PluginBoardTemplate: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    public var diagram: JSONValue?
    public var file: String?
}

public struct PluginContributions: Codable, Equatable {
    public var commands: [PluginCommandContribution]?
    public var menus: [PluginMenuContribution]?
    public var toolbar: [PluginToolbarContribution]?
    public var tools: [PluginToolContribution]?
    public var toolOptions: [PluginToolOptions]?
    public var panels: [PluginPanelContribution]?
    /// Papers and covers (`isCover: true`).
    public var templates: [PluginTemplateContribution]?
    public var keybindings: [PluginKeybinding]?
    /// JSON Schema object; values stored as settings "plugin.<id>.<key>".
    public var settings: JSONValue?
    public var aiActions: [PluginAIAction]?
    public var ai: PluginAIGuidance?
    public var importers: [PluginFileHandler]?
    public var exporters: [PluginFileHandler]?
    public var itemTypes: [PluginItemType]?
    public var tapHandlers: [PluginTapHandler]?
    public var blocks: [PluginBlockContribution]?
    public var strokeProcessors: [PluginStrokeProcessor]?
    public var pencilActions: [PluginPencilAction]?
    public var commandHooks: [PluginCommandHook]?
    /// Content packs.
    public var elements: [PluginElementCollection]?
    public var tapePatterns: [PluginTapePattern]?
    public var boardTemplates: [PluginBoardTemplate]?
}

public struct PluginManifest: Codable, Equatable {
    /// Reverse-DNS id, e.g. "dev.nib.cards". [a-z0-9.-]
    public var id: String
    public var name: String
    /// Semantic version "1.2.3".
    public var version: String
    /// Plugin API version (currently 1).
    public var api: Int
    public var author: String?
    public var description: String?
    /// Single-file JS bundle, e.g. "main.js".
    public var entry: String
    /// Scope raw values: "document:read", "document:write", "library:read", "library:write", "destructive",
    /// "app", "ai", "network". ("plugins:manage" and "security" are never granted to plugins.)
    public var permissions: [String]
    public var network: PluginNetwork?
    public var contributes: PluginContributions?
    public var homepage: String?
}

public struct PluginInfo: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var enabled: Bool
    /// Present on disk (e.g. synced from another device) but not yet approved on this device.
    public var needsReview: Bool
    public var permissions: [String]
    public var sha256: String
    public var source: String?

    public init(id: String, name: String, version: String, enabled: Bool, needsReview: Bool, permissions: [String],
                sha256: String, source: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.needsReview = needsReview
        self.permissions = permissions
        self.sha256 = sha256
        self.source = source
    }
}

/// A running plugin (JavaScriptCore context).
@MainActor
public protocol PluginRuntimeHandle: AnyObject {
    var manifest: PluginManifest { get }
    /// Recent console output (ring buffer).
    var logs: [String] { get }
    /// Calls a command handler registered by the plugin's JS (`nib.commands.register`).
    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue
    func deliver(_ event: NibEvent)
    /// Delivers a message to the plugin's `nib.events.on("plugin.message")` handlers.
    func postMessage(from panel: String, message: JSONValue)
    /// Developer console: evaluates JS in the plugin context and returns the result as text.
    func evaluate(_ javascript: String) async -> String
    func stop()
}

@MainActor
public protocol PluginRuntimeProviding: AnyObject {
    /// Creates the context, evaluates the prelude and the entry bundle. `folder` = the installed plugin folder.
    func start(_ manifest: PluginManifest, folder: URL) async throws -> PluginRuntimeHandle
}

@MainActor
public protocol PluginHosting: AnyObject {
    var installed: [PluginInfo] { get }
    func handle(_ id: String) -> PluginRuntimeHandle?
    func folder(_ id: String) -> URL?
    /// (Re)loads a plugin from its folder: validates, maps contributions, starts the runtime.
    func load(_ id: String) async throws
    func unload(_ id: String)
    func setEnabled(_ id: String, _ enabled: Bool) async throws
    /// `ai.instructions` of enabled plugins (appended to the AI system prompt).
    var aiInstructions: [String] { get }
}

// MARK: - AI providers (bring your own model)

public enum AIProviderKind: String, Codable, CaseIterable {
    /// Anthropic Messages API.
    case anthropic
    /// OpenAI Chat Completions and compatible servers (OpenAI, OpenRouter, Ollama, LM Studio, vLLM, Groq…).
    case openAICompatible
    /// The user's own endpoint speaking the Nib Agent Protocol (docs/AI.md §3).
    case nibHTTP
}

public struct AIProviderConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: URL
    public var model: String
    /// Non-secret headers (e.g. OpenRouter HTTP-Referer / X-Title).
    public var extraHeaders: [String: String]
    public var supportsVision: Bool
    public var supportsTools: Bool
    public var contextTokens: Int?
    public var maxOutputTokens: Int
    /// Optional OpenAI-compatible audio transcription model (e.g. "whisper-1").
    public var transcriptionModel: String?
    /// Optional image generation model (e.g. "gpt-image-1").
    public var imageModel: String?

    public init(id: UUID = UUID(), name: String, kind: AIProviderKind, baseURL: URL, model: String,
                extraHeaders: [String: String] = [:], supportsVision: Bool = true, supportsTools: Bool = true,
                contextTokens: Int? = nil, maxOutputTokens: Int = 4096, transcriptionModel: String? = nil, imageModel: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.extraHeaders = extraHeaders
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.transcriptionModel = transcriptionModel
        self.imageModel = imageModel
    }

    /// Keychain location of the API key: service "app.nib.ai", account = id.
    public static let keychainService = "app.nib.ai"
    public var keychainAccount: String { id.uuidString }
}

public enum ChatRole: String, Codable { case user, assistant, tool }

public enum ChatPart: Equatable {
    case text(String)
    case image(data: Data, mime: String)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case toolResult(id: String, parts: [ChatPart], isError: Bool)
}

public struct ChatMessage: Equatable {
    public var role: ChatRole
    public var parts: [ChatPart]
    public init(role: ChatRole, parts: [ChatPart]) {
        self.role = role
        self.parts = parts
    }
}

public struct ToolSpec: Equatable {
    /// [a-zA-Z0-9_-]{1,64}
    public var name: String
    public var description: String
    /// JSON Schema object.
    public var schema: JSONValue
    public init(name: String, description: String, schema: JSONValue) {
        self.name = name
        self.description = description
        self.schema = schema
    }
}

public struct ChatRequest {
    public var model: String
    public var system: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var maxTokens: Int
    public var temperature: Double?
    public init(model: String, system: String, messages: [ChatMessage], tools: [ToolSpec] = [], maxTokens: Int = 4096,
                temperature: Double? = nil) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public enum ChatEvent: Equatable {
    case textDelta(String)
    /// Emitted once the call's arguments are complete.
    case toolCall(id: String, name: String, arguments: JSONValue)
    case usage(input: Int, output: Int)
    case stop(reason: String)
}

/// One wire protocol adapter bound to a config (+ its Keychain secret).
public protocol AIProvider: AnyObject {
    var config: AIProviderConfig { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func listModels() async throws -> [String]
    /// Throws `NibError(.unsupported)` when the provider has no transcription endpoint.
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment]
    /// Throws `NibError(.unsupported)` when the provider has no image endpoint.
    func generateImage(prompt: String) async throws -> Data
}

@MainActor
public protocol AIProviderStore: AnyObject {
    var configs: [AIProviderConfig] { get }
    var activeID: UUID? { get set }
    /// Saves the config; a non-nil `apiKey` is written to the Keychain ("" deletes it).
    func save(_ config: AIProviderConfig, apiKey: String?) throws
    func delete(_ id: UUID)
    /// nil id = the active provider.
    func provider(_ id: UUID?) -> AIProvider?
}

// MARK: - Collaboration transports

public struct CollabPeer: Codable, Hashable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A message pipe between collaborators (Multipeer on the local network, WebSocket relay over the internet).
@MainActor
public protocol CollabTransport: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var peers: [CollabPeer] { get }
    var maxPeers: Int { get }
    var onMessage: ((CollabPeer, Data) -> Void)? { get set }
    var onPeersChanged: (([CollabPeer]) -> Void)? { get set }
    func host(code: String, displayName: String) async throws
    func join(code: String, displayName: String) async throws
    /// nil = everyone.
    func send(_ data: Data, to peers: [CollabPeer]?) throws
    func leave()
}
```

### `NibKit/Sources/NibContracts/Core/Settings.swift`

```swift
import Foundation
import Security

/// A typed setting. `synced` settings live in the library (travel with the library folder);
/// the rest are per device (UserDefaults). Names starting with "security." can only be changed by the user.
public struct SettingKey<Value: Codable> {
    public let name: String
    public let defaultValue: Value
    public let synced: Bool

    public init(_ name: String, default defaultValue: Value, synced: Bool = false) {
        self.name = name
        self.defaultValue = defaultValue
        self.synced = synced
    }
}

/// Library-level synced settings storage (implemented by the Library Store feature: `.nib-library/prefs.<device>.json`,
/// merged per key by rev). Collections are stored as ONE KEY PER ENTRY ("calendar.notes.<eventId>",
/// "writing.dictionary.<word>", "timer.history.<id>", "text.styles.<name>"; null = removed) so concurrent additions
/// on two devices never overwrite each other.
public protocol SyncedSettingsBackend: AnyObject {
    func value(_ name: String) -> JSONValue?
    func setValue(_ name: String, _ value: JSONValue?)
    /// Every stored name (for prefix enumeration).
    func names() -> [String]
}

/// Metadata of a declared setting: sync routing, `settings.list` / `settings.describe`, validation.
public struct SettingDescriptor {
    /// Full name, or a prefix ending in "." for a family of per-entry keys.
    public let name: String
    public let synced: Bool
    public let summary: String
    public let owner: String
    public let schema: JSONSchema
    public let defaultValue: JSONValue
    /// Only code writes it (e.g. "managed.*"): `settings.set` rejects it for every caller.
    public let readOnly: Bool
    public var isPrefix: Bool { name.hasSuffix(".") }
    /// "security.*": commands may read or change it only as the user.
    public var userOnly: Bool { name.hasPrefix("security.") }
}

/// Thread-safe settings store. Posts `SettingsStore.didChange` with userInfo ["name": String].
/// Every setting is DECLARED at register time (`declare` / `declarePrefix`); `NibApp.init` declares `NibSettings`.
public final class SettingsStore {
    public static let didChange = Notification.Name("NibSettingsDidChange")
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var synced: [String: Bool] = [:]
    private var declared: [String: SettingDescriptor] = [:]
    private var prefixes: [String: SettingDescriptor] = [:]
    private var undeclared = Set<String>()
    public var syncedBackend: SyncedSettingsBackend?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Declarations

    /// Declares a typed setting (call once in `register`). Declared names route to the synced backend even for
    /// untyped callers (AI, plugins, bridge), appear in `settings.list`, and `settings.set` validates against `schema`.
    public func declare<V: Codable>(_ key: SettingKey<V>, summary: String, owner: String,
                                    schema: JSONSchema = .anything(), readOnly: Bool = false) {
        let d = SettingDescriptor(name: key.name, synced: key.synced, summary: summary, owner: owner, schema: schema,
                                  defaultValue: (try? JSONValue.from(key.defaultValue)) ?? .null, readOnly: readOnly)
        lock.lock()
        declared[key.name] = d
        synced[key.name] = key.synced
        lock.unlock()
    }

    /// Declares a family of per-entry keys sharing `prefix` (must end in "."), e.g. "calendar.notes.", "plugin.<id>.".
    public func declarePrefix(_ prefix: String, synced flag: Bool, summary: String, owner: String,
                              schema: JSONSchema = .anything(), readOnly: Bool = false) {
        let d = SettingDescriptor(name: prefix, synced: flag, summary: summary, owner: owner, schema: schema,
                                  defaultValue: .null, readOnly: readOnly)
        lock.lock()
        prefixes[prefix] = d
        lock.unlock()
    }

    /// Exact declaration, else the longest declared prefix.
    public func descriptor(_ name: String) -> SettingDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        if let d = declared[name] { return d }
        return prefixes.values.filter { name.hasPrefix($0.name) }.max { $0.name.count < $1.name.count }
    }

    public var declaredSettings: [SettingDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return (Array(declared.values) + Array(prefixes.values)).sorted { $0.name < $1.name }
    }

    /// Typed keys read or written without a declaration (conformance fails on any).
    public var undeclaredNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return undeclared.sorted()
    }

    /// Stored names starting with `prefix` (synced backend and this device).
    public func names(prefix: String) -> [String] {
        var out = Set(syncedBackend?.names().filter { $0.hasPrefix(prefix) } ?? [])
        let device = "nib.setting."
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(device + prefix) {
            out.insert(String(k.dropFirst(device.count)))
        }
        return out.sorted()
    }

    // MARK: Access

    public func get<V: Codable>(_ key: SettingKey<V>) -> V {
        remember(key.name, synced: key.synced)
        guard let json = raw(key.name, synced: key.synced), let v = try? json.decode(V.self) else { return key.defaultValue }
        return v
    }

    public func set<V: Codable>(_ key: SettingKey<V>, _ value: V) {
        remember(key.name, synced: key.synced)
        guard let json = try? JSONValue.from(value) else { return }
        store(key.name, json, synced: key.synced)
    }

    /// Untyped access (settings.get / settings.set commands, plugin settings "plugin.<id>.<key>").
    public func json(_ name: String) -> JSONValue? {
        raw(name, synced: isSynced(name))
    }

    public func setJSON(_ name: String, _ value: JSONValue?) {
        store(name, value, synced: isSynced(name))
    }

    /// Names seen so far (declared or used).
    public var knownNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return synced.keys.sorted()
    }

    private func remember(_ name: String, synced flag: Bool) {
        let isDeclared = descriptor(name) != nil
        lock.lock()
        synced[name] = flag
        if !isDeclared { undeclared.insert(name) }
        lock.unlock()
    }

    private func isSynced(_ name: String) -> Bool {
        if let d = descriptor(name) { return d.synced }
        lock.lock()
        defer { lock.unlock() }
        return synced[name] ?? false
    }

    private func raw(_ name: String, synced flag: Bool) -> JSONValue? {
        if flag, let backend = syncedBackend { return backend.value(name) }
        guard let s = defaults.string(forKey: "nib.setting." + name) else { return nil }
        return try? JSONValue.parse(s)
    }

    private func store(_ name: String, _ value: JSONValue?, synced flag: Bool) {
        if flag, let backend = syncedBackend {
            backend.setValue(name, value)
        } else if let v = value {
            defaults.set(v.jsonString(), forKey: "nib.setting." + name)
        } else {
            defaults.removeObject(forKey: "nib.setting." + name)
        }
        NotificationCenter.default.post(name: SettingsStore.didChange, object: self, userInfo: ["name": name])
    }
}

/// Settings shared by several features. Feature-private settings use "<featureId>.<name>".
public enum NibSettings {
    public static let authorName = SettingKey("profile.authorName", default: "")
    public static let scrollDirection = SettingKey("editing.scrollDirection", default: ScrollDirection.vertical, synced: true)
    public static let openAsTabs = SettingKey("editing.openAsTabs", default: true, synced: true)
    public static let undoButtonsOnRight = SettingKey("editing.undoOnRight", default: false, synced: true)
    public static let objectTapSelection = SettingKey("editing.objectTapSelection", default: true, synced: true)
    public static let alignObjects = SettingKey("editing.alignObjects", default: true, synced: true)
    public static let snapToGrid = SettingKey("editing.snapToGrid", default: false, synced: true)
    public static let hideStatusBar = SettingKey("editing.hideStatusBar", default: false)
    public static let zoomAutoAdvance = SettingKey("editing.zoomAutoAdvance", default: true, synced: true)
    public static let sidebarOnRight = SettingKey("editing.sidebarOnRight", default: false, synced: true)
    public static let stylusMode = SettingKey("stylus.mode", default: StylusMode.pencilOnly)
    /// 0 = low (recommended), 1 = medium, 2 = high.
    public static let palmSensitivity = SettingKey("stylus.palmSensitivity", default: 0)
    /// 0…7: handedness × wrist angle illustration index.
    public static let writingPosture = SettingKey("stylus.posture", default: 0)
    public static let reduceLatency = SettingKey("pen.reduceLatency", default: true, synced: true)
    public static let defaultLanguage = SettingKey("language.default", default: "en-US", synced: true)
    public static let indexHandwriting = SettingKey("search.indexHandwriting", default: true)
    public static let spellcheckNewDocuments = SettingKey("writing.spellcheckNewDocuments", default: false, synced: true)
    public static let mathAssistSuggestions = SettingKey("writing.mathAssist", default: false, synced: true)
    /// Personal dictionary: one synced key per word ("writing.dictionary.<word>" = true; null = removed).
    public static let dictionaryPrefix = "writing.dictionary."
    public static func dictionaryWord(_ word: String) -> SettingKey<Bool> {
        SettingKey(dictionaryPrefix + word.lowercased(), default: false, synced: true)
    }
    public static let aiConfirmationPolicy = SettingKey("security.ai.confirmationPolicy", default: ConfirmationPolicy.destructive)
    public static let bridgeConfirmationPolicy = SettingKey("security.bridge.confirmationPolicy", default: ConfirmationPolicy.destructive)
    /// Expose plugin commands that opted out with `ai: false` / `bridge: false` anyway (user only).
    public static let exposeHiddenPluginCommands = SettingKey("security.plugins.exposeHiddenCommands", default: false)
    public static let pluginGalleries = SettingKey("plugins.galleries", default: [String](), synced: true)
    public static let experimental = SettingKey("advanced.experimental", default: [String: Bool]())
    public static let defaultPaper = SettingKey("templates.defaultPaper", default: TemplateRef("builtin.ruled"), synced: true)
    public static let defaultCover = SettingKey("templates.defaultCover", default: TemplateRef("cover.solid"), synced: true)
    public static let defaultPageSize = SettingKey("templates.defaultSize", default: PageSize.a4, synced: true)
    public static let coverByDefault = SettingKey("templates.coverByDefault", default: true, synced: true)

    public static let presetTools = ["pen", "pencil", "highlighter", "tape", "shape", "drawShape"]

    /// Color / thickness presets of a writing tool (`presetTools`).
    public static func presets(_ tool: String) -> SettingKey<ToolPresets> {
        SettingKey("presets." + tool, default: ToolPresets.defaults(for: tool), synced: true)
    }

    /// Declares every shared setting (called by `NibApp.init`; owner "builtin").
    public static func declareAll(_ s: SettingsStore) {
        let bool = JSONSchema.bool()
        s.declare(authorName, summary: "Author name shown on sticky notes, comments and collaboration.", owner: "builtin", schema: .str())
        s.declare(scrollDirection, summary: "Default page scrolling for new documents.", owner: "builtin",
                  schema: .str(choices: ScrollDirection.allCases.map { $0.rawValue }))
        s.declare(openAsTabs, summary: "Open documents as tabs instead of replacing the current one.", owner: "builtin", schema: bool)
        s.declare(undoButtonsOnRight, summary: "Show undo/redo on the right of the toolbar.", owner: "builtin", schema: bool)
        s.declare(objectTapSelection, summary: "Finger tap selects objects (quick selection).", owner: "builtin", schema: bool)
        s.declare(alignObjects, summary: "Show alignment guides while moving objects.", owner: "builtin", schema: bool)
        s.declare(snapToGrid, summary: "Snap moved objects to the template grid.", owner: "builtin", schema: bool)
        s.declare(hideStatusBar, summary: "Hide the iOS status bar in documents.", owner: "builtin", schema: bool)
        s.declare(zoomAutoAdvance, summary: "Zoom Window advances automatically.", owner: "builtin", schema: bool)
        s.declare(sidebarOnRight, summary: "Show the document sidebar on the right.", owner: "builtin", schema: bool)
        s.declare(stylusMode, summary: "pencilOnly = fingers scroll; anyInput = fingers draw.", owner: "builtin",
                  schema: .str(choices: StylusMode.allCases.map { $0.rawValue }))
        s.declare(palmSensitivity, summary: "Palm rejection sensitivity 0 low, 1 medium, 2 high.", owner: "builtin", schema: .int(min: 0, max: 2))
        s.declare(writingPosture, summary: "Writing posture 0…7 (handedness × wrist angle).", owner: "builtin", schema: .int(min: 0, max: 7))
        s.declare(reduceLatency, summary: "Use predicted touches for lower ink latency.", owner: "builtin", schema: bool)
        s.declare(defaultLanguage, summary: "Default handwriting recognition language (BCP-47).", owner: "builtin", schema: .str())
        s.declare(indexHandwriting, summary: "Index handwriting for search on this device.", owner: "builtin", schema: bool)
        s.declare(spellcheckNewDocuments, summary: "Turn on handwriting spellcheck for new documents.", owner: "builtin", schema: bool)
        s.declare(mathAssistSuggestions, summary: "Offer Math Assist answers for handwritten equations.", owner: "builtin", schema: bool)
        s.declarePrefix(dictionaryPrefix, synced: true, summary: "Personal dictionary words (true = in dictionary).",
                        owner: "builtin", schema: bool)
        s.declare(aiConfirmationPolicy, summary: "When AI actions need confirmation (user only).", owner: "builtin",
                  schema: .str(choices: ConfirmationPolicy.allCases.map { $0.rawValue }))
        s.declare(bridgeConfirmationPolicy, summary: "When bridge actions need confirmation (user only).", owner: "builtin",
                  schema: .str(choices: ConfirmationPolicy.allCases.map { $0.rawValue }))
        s.declare(exposeHiddenPluginCommands, summary: "Expose plugin commands marked ai:false/bridge:false (user only).",
                  owner: "builtin", schema: bool)
        s.declare(pluginGalleries, summary: "Gallery index URLs for plugins and content packs.", owner: "builtin", schema: .arr(.str()))
        s.declare(experimental, summary: "Experimental feature toggles.", owner: "builtin")
        s.declare(defaultPaper, summary: "Default paper template {id, params}.", owner: "builtin")
        s.declare(defaultCover, summary: "Default cover template {id, params}.", owner: "builtin")
        s.declare(defaultPageSize, summary: "Default page size {width, height} in points.", owner: "builtin")
        s.declare(coverByDefault, summary: "New notebooks get a cover page.", owner: "builtin", schema: bool)
        for tool in presetTools {
            s.declare(presets(tool), summary: "Colour and thickness presets of the \(tool) tool.", owner: "builtin")
        }
        s.declarePrefix("managed.", synced: false, summary: "Managed App Configuration values (read-only).",
                        owner: "builtin", readOnly: true)
    }
}

// MARK: - Keychain

/// Where `Keychain` keeps secrets. Swappable because hostless package tests have no entitlements (SecItemAdd fails
/// with -34018); `Harness` installs NibTesting's `InMemorySecretStore`.
public protocol SecretStore: AnyObject {
    func set(_ data: Data?, service: String, account: String) -> Bool
    func get(service: String, account: String) -> Data?
}

/// The system Keychain (generic passwords, this device only).
public final class SystemKeychainStore: SecretStore {
    public init() {}

    public func set(_ data: Data?, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let data = data else { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func get(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

/// Secrets (API keys, WebDAV passwords, bridge token). Device-only, never synced, never exposed to plugins or AI.
/// Re-signing with another team changes the Keychain access group: features that find a secret missing show
/// "credentials missing — re-enter" instead of failing silently.
public enum Keychain {
    public static var store: SecretStore = SystemKeychainStore()

    @discardableResult
    public static func set(_ data: Data?, service: String, account: String) -> Bool {
        store.set(data, service: service, account: account)
    }

    public static func get(service: String, account: String) -> Data? {
        store.get(service: service, account: account)
    }

    @discardableResult
    public static func setString(_ value: String?, service: String, account: String) -> Bool {
        set(value.map { Data($0.utf8) }, service: service, account: account)
    }

    public static func getString(service: String, account: String) -> String? {
        get(service: service, account: account).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Stable random per-install device id (HLC tiebreaker, per-device package files). Mirrored to
/// Application Support/Nib/device-id, which wins over the Keychain: a re-signed build (new Keychain access group)
/// or a failing Keychain keeps the same id instead of starting a new set of per-device files every launch.
public enum DeviceIdentity {
    private static var cached: UInt32?

    static var mirrorURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib/device-id")
    }

    public static var current: UInt32 {
        if let c = cached { return c }
        func decode(_ d: Data?) -> UInt32? {
            guard let d = d, d.count == 4 else { return nil }
            return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        let mirrored = decode(mirrorURL.flatMap { try? Data(contentsOf: $0) })
        let stored = decode(Keychain.get(service: "app.nib.device", account: "id"))
        let value = mirrored ?? stored ?? UInt32.random(in: 1...UInt32.max)
        var le = value
        let data = Data(bytes: &le, count: 4)
        if stored != value { Keychain.set(data, service: "app.nib.device", account: "id") }
        if mirrored == nil, let url = mirrorURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        cached = value
        return value
    }

    /// 8 lowercase hex characters, used in package file names ("doc.<hex>.json").
    public static var hex: String { String(format: "%08x", current) }
}

/// Optional App Group container — a progressive enhancement, never required. AltStore/SideStore register app
/// groups even for free Apple IDs and list the rewritten ids in Info.plist "ALTAppGroups"; "NibAppGroups" lists the
/// ids the build asked for. nil when no group is usable: callers fall back (static widgets, pasteboard hand-off).
public enum AppGroup {
    public static var containerURL: URL? {
        let info = Bundle.main.infoDictionary ?? [:]
        let ids = ((info["ALTAppGroups"] as? [String]) ?? []) + ((info["NibAppGroups"] as? [String]) ?? [])
        for id in ids {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) { return url }
        }
        return nil
    }
}
```

### `NibKit/Sources/NibContracts/Core/Registries.swift`

```swift
import Foundation
import CoreGraphics
import BackgroundTasks

/// Anything registered by a feature or plugin. `owner` = feature id or plugin id (used to unregister).
public protocol Registrable {
    var id: String { get }
    var order: Int { get }
    var owner: String { get }
}

/// Thread-safe ordered registry keyed by id (re-registering an id replaces it). Posts `.nibRegistryDidChange`.
public final class Registry<D: Registrable> {
    private var items: [D] = []
    private let lock = NSLock()

    public init() {}

    /// Sorted by (order, id).
    public var all: [D] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    public func register(_ d: D) {
        lock.lock()
        items.removeAll { $0.id == d.id }
        items.append(d)
        items.sort { ($0.order, $0.id) < ($1.order, $1.id) }
        lock.unlock()
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(id: String) {
        lock.lock()
        items.removeAll { $0.id == id }
        lock.unlock()
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(owner: String) {
        lock.lock()
        items.removeAll { $0.owner == owner }
        lock.unlock()
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func get(_ id: String) -> D? {
        lock.lock()
        defer { lock.unlock() }
        return items.first { $0.id == id }
    }
}

// MARK: - Templates

public struct TemplateParam: Codable, Equatable {
    public var name: String
    public var title: String
    /// "color" | "number" | "choice" | "bool".
    public var kind: String
    public var choices: [String]?
    public var minimum: Double?
    public var maximum: Double?

    public init(name: String, title: String, kind: String, choices: [String]? = nil, minimum: Double? = nil, maximum: Double? = nil) {
        self.name = name
        self.title = title
        self.kind = kind
        self.choices = choices
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct TemplateRender {
    public var paper: RGBA
    /// Page-coordinate drawing ops (lines, grids, dots, planner boxes, text).
    public var display: DisplayList

    public init(paper: RGBA, display: DisplayList = DisplayList()) {
        self.paper = paper
        self.display = display
    }
}

/// A parametric paper or cover template. Built-ins and plugin templates use the same type.
public struct TemplateDefinition: Registrable {
    public var id: String
    public var title: String
    /// "Essentials", "Writing", "Planners", "Music", "Whiteboard", "Covers", or a plugin category.
    public var category: String
    public var isCover: Bool
    public var order: Int
    public var owner: String
    public var params: [TemplateParam]
    public var defaults: [String: JSONValue]
    public var preferredSize: PageSize?
    /// Default Zoom Window return height (points).
    public var zoomReturnHeight: Double?
    /// Pure and thread-safe (called on render threads). `scale` = pixels per point so grids can adapt to zoom.
    public var render: (_ params: [String: JSONValue], _ size: PageSize, _ scale: Double) -> TemplateRender

    public init(id: String, title: String, category: String, isCover: Bool = false, order: Int = 0, owner: String,
                params: [TemplateParam] = [], defaults: [String: JSONValue] = [:], preferredSize: PageSize? = nil,
                zoomReturnHeight: Double? = nil,
                render: @escaping (_ params: [String: JSONValue], _ size: PageSize, _ scale: Double) -> TemplateRender) {
        self.id = id
        self.title = title
        self.category = category
        self.isCover = isCover
        self.order = order
        self.owner = owner
        self.params = params
        self.defaults = defaults
        self.preferredSize = preferredSize
        self.zoomReturnHeight = zoomReturnHeight
        self.render = render
    }
}

// MARK: - Item drawing

public struct DrawContext {
    /// Already scaled so that 1 unit = 1 page point; origin = page top-left.
    public let cg: CGContext
    /// Pixels per point.
    public let scale: Double
    public let doc: DocumentID
    public let page: PageID
    /// Dark paper: highlighters switch blend, drawers may lighten dark ink.
    public let darkPaper: Bool
    public let assets: AssetStore?
    /// Note Replay state; nil = draw everything normally.
    public let replay: ReplayState?

    public init(cg: CGContext, scale: Double, doc: DocumentID, page: PageID, darkPaper: Bool = false,
                assets: AssetStore? = nil, replay: ReplayState? = nil) {
        self.cg = cg
        self.scale = scale
        self.doc = doc
        self.page = page
        self.darkPaper = darkPaper
        self.assets = assets
        self.replay = replay
    }
}

/// Draws one kind of item into a tile, a thumbnail or an export. Must be thread-safe (render threads).
public protocol ItemDrawer: AnyObject {
    func draw(_ item: Item, in context: DrawContext)
}

/// Registered under `Item.drawKey` ("shape", "text", "stroke.tape", "custom.<owner>.<type>") or a kind name.
public struct ItemDrawerEntry: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var drawer: ItemDrawer

    public init(key: String, owner: String, drawer: ItemDrawer, order: Int = 0) {
        self.id = key
        self.order = order
        self.owner = owner
        self.drawer = drawer
    }
}

// MARK: - Import / export

public struct ImportTarget {
    /// Destination folder for new documents (nil = root / current folder).
    public var folder: FolderID?
    /// Insert pages into this existing document instead of creating one.
    public var document: DocumentID?
    public var position: PagePosition
    public var anchorPage: PageID?

    public init(folder: FolderID? = nil, document: DocumentID? = nil, position: PagePosition = .end, anchorPage: PageID? = nil) {
        self.folder = folder
        self.document = document
        self.position = position
        self.anchorPage = anchorPage
    }
}

public struct ImporterDescriptor: Registrable {
    public var id: String
    public var title: String
    /// Lowercased, without dot.
    public var fileExtensions: [String]
    public var utTypes: [String]
    public var order: Int
    public var owner: String
    /// Returns the created (or modified) documents.
    public var handler: @MainActor (URL, ImportTarget, CommandContext) async throws -> [DocumentID]

    public init(id: String, title: String, fileExtensions: [String], utTypes: [String] = [], order: Int = 0, owner: String,
                handler: @escaping @MainActor (URL, ImportTarget, CommandContext) async throws -> [DocumentID]) {
        self.id = id
        self.title = title
        self.fileExtensions = fileExtensions
        self.utTypes = utTypes
        self.order = order
        self.owner = owner
        self.handler = handler
    }
}

public struct ExportRequest: Codable {
    public var documents: [DocumentID]
    /// Restrict to these pages (nil = all live pages).
    public var pages: [PageID]?
    /// Exporter-specific options (PDF: {"mode":"editable|flattened","background":true,"annotations":true,...}).
    public var options: JSONValue
    public var fileName: String?

    public init(documents: [DocumentID], pages: [PageID]? = nil, options: JSONValue = [:], fileName: String? = nil) {
        self.documents = documents
        self.pages = pages
        self.options = options
        self.fileName = fileName
    }
}

public struct ExporterDescriptor: Registrable {
    public var id: String
    public var title: String
    public var fileExtension: String
    public var utType: String
    public var order: Int
    public var owner: String
    /// Writes files to a temporary folder and returns their URLs.
    public var handler: @MainActor (ExportRequest, CommandContext) async throws -> [URL]

    public init(id: String, title: String, fileExtension: String, utType: String, order: Int = 0, owner: String,
                handler: @escaping @MainActor (ExportRequest, CommandContext) async throws -> [URL]) {
        self.id = id
        self.title = title
        self.fileExtension = fileExtension
        self.utType = utType
        self.order = order
        self.owner = owner
        self.handler = handler
    }
}

// MARK: - AI quick actions

public struct AIActionDescriptor: Registrable {
    public var id: String
    public var title: String
    /// SF Symbol.
    public var icon: String
    /// Prompt sent to the agent; the scope (selection/page/document) is attached automatically.
    public var prompt: String
    public var scope: AIScopeKind
    public var mode: AIMode
    public var docKinds: Set<DocumentKind>
    public var order: Int
    public var owner: String

    public init(id: String, title: String, icon: String, prompt: String, scope: AIScopeKind, mode: AIMode,
                docKinds: Set<DocumentKind> = Set(DocumentKind.allCases), order: Int = 0, owner: String) {
        self.id = id
        self.title = title
        self.icon = icon
        self.prompt = prompt
        self.scope = scope
        self.mode = mode
        self.docKinds = docKinds
        self.order = order
        self.owner = owner
    }
}

// MARK: - Stroke processors

/// Adjusts a finished stroke before it is committed (stabilization, straight highlighter, ruler projection).
@MainActor
public protocol StrokeProcessor: AnyObject {
    /// Return false to drop the stroke (e.g. it was consumed as a gesture).
    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool
}

public struct StrokeProcessorEntry: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var processor: StrokeProcessor

    public init(id: String, order: Int, owner: String, processor: StrokeProcessor) {
        self.id = id
        self.order = order
        self.owner = owner
        self.processor = processor
    }
}

// MARK: - Keyboard

public struct KeyModifiers: OptionSet, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let shift = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
}

public struct KeyShortcut: Hashable, Codable {
    /// A single character ("p", "2", "["), or "up" | "down" | "left" | "right" | "escape" | "delete" | "tab" | "return" | "space".
    public var key: String
    public var modifiers: KeyModifiers

    public init(_ key: String, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum KeyScope: String, Codable, CaseIterable {
    case global, library, document
    /// Only while no text field is being edited (single-key tool shortcuts).
    case canvas
}

public struct KeyCommandDescriptor: Registrable {
    public var id: String
    /// Shown in the ⌘-hold discoverability overlay.
    public var title: String
    public var shortcut: KeyShortcut
    public var command: String
    public var params: JSONValue
    public var scope: KeyScope
    public var order: Int
    public var owner: String

    public init(id: String, title: String, shortcut: KeyShortcut, command: String, params: JSONValue = [:],
                scope: KeyScope = .document, order: Int = 0, owner: String) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.command = command
        self.params = params
        self.scope = scope
        self.order = order
        self.owner = owner
    }
}

// MARK: - Background tasks

public enum BackgroundTaskKind: String, Codable, CaseIterable { case refresh, processing }

/// A BGTaskScheduler task. Features ONLY fill `content.backgroundTasks` and call `NibApp.scheduleBackgroundTask`;
/// they never call `BGTaskScheduler` directly. The app shell registers every identifier listed in Info.plist
/// `BGTaskSchedulerPermittedIdentifiers` synchronously in `didFinishLaunching` (the only legal moment) and routes
/// each launch to the descriptor with that id (a task without a descriptor is completed immediately).
/// Hostless package tests never touch BGTaskScheduler.
public struct BackgroundTaskDescriptor: Registrable {
    /// The task identifier, e.g. "app.nib.backup" (must be in the Info.plist list).
    public var id: String
    public var kind: BackgroundTaskKind
    public var order: Int
    public var owner: String
    /// Does the work; return true on success. `Task.isCancelled` becomes true when the system expires the task.
    public var handler: @MainActor (BGTask) async -> Bool

    public init(id: String, kind: BackgroundTaskKind, owner: String, order: Int = 0,
                handler: @escaping @MainActor (BGTask) async -> Bool) {
        self.id = id
        self.kind = kind
        self.order = order
        self.owner = owner
        self.handler = handler
    }
}

// MARK: - Canvas gestures routed to commands

public enum CanvasGesture: String, Codable, CaseIterable { case tap, doubleTap, longPress }

/// Offers finger taps / double-taps / long-presses on the canvas to a command BEFORE the active tool (replaces the
/// old fixed tap chain). Lowest `order` first; the first handler whose command returns {"handled": true} wins.
/// The command gets {"page", "point", "ref"?, "gesture"} where `ref` is the topmost live item under the point.
/// Built-ins: tape.tapAt 100, comment.tapAt 200, link.tapAt 300, selection.tapAt 400.
public struct TapHandlerDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var gesture: CanvasGesture
    /// Offered only when the topmost item under the point has one of these kinds (nil = always).
    public var itemKinds: Set<ItemKind>?
    /// Offered only when the topmost item's `Item.drawKey` is one of these (custom types: "custom.<owner>.<type>").
    public var drawKeys: Set<String>?
    /// Also offered in read-only mode.
    public var worksInReadOnly: Bool
    public var command: String

    public init(id: String, owner: String, gesture: CanvasGesture, command: String, order: Int = 500,
                itemKinds: Set<ItemKind>? = nil, drawKeys: Set<String>? = nil, worksInReadOnly: Bool = false) {
        self.id = id
        self.order = order
        self.owner = owner
        self.gesture = gesture
        self.itemKinds = itemKinds
        self.drawKeys = drawKeys
        self.worksInReadOnly = worksInReadOnly
        self.command = command
    }
}

// MARK: - Content packs, block kinds, custom item types, pencil actions

/// A whiteboard framework inserted by `board.insertTemplate` (built-ins by F044, plugins' `boardTemplates`).
public struct BoardTemplateDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var order: Int
    public var owner: String
    /// `diagram.create` params without `page`/`origin`, or {"fragment": <clipboard fragment JSON>}.
    public var spec: JSONValue

    public init(id: String, title: String, icon: String = "rectangle.3.group", order: Int = 0, owner: String, spec: JSONValue) {
        self.id = id
        self.title = title
        self.icon = icon
        self.order = order
        self.owner = owner
        self.spec = spec
    }
}

/// A tape pattern tile offered by the tape tool (F033 built-ins and custom images, plugins' `tapePatterns`).
public struct TapePatternDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    /// PNG tile bytes (thread-safe).
    public var load: () throws -> Data

    public init(id: String, title: String, order: Int = 0, owner: String, load: @escaping () throws -> Data) {
        self.id = id
        self.title = title
        self.order = order
        self.owner = owner
        self.load = load
    }
}

public struct ElementEntry: Codable, Equatable {
    public var id: String
    public var title: String
    /// Clipboard fragment JSON ({format: "nib-fragment/1", items, assets, bounds}).
    public var fragment: JSONValue

    public init(id: String, title: String, fragment: JSONValue) {
        self.id = id
        self.title = title
        self.fragment = fragment
    }
}

/// A read-only element collection contributed by a plugin/content pack (user collections live in F035's store).
public struct ElementCollectionDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    public var load: () throws -> [ElementEntry]

    public init(id: String, title: String, order: Int = 0, owner: String, load: @escaping () throws -> [ElementEntry]) {
        self.id = id
        self.title = title
        self.order = order
        self.owner = owner
        self.load = load
    }
}

/// One entry of the text-document slash menu and Turn Into menu. F047 registers the built-in kinds and builds both
/// menus from this registry; tables (F048) and plugins' `blocks` add theirs.
public struct BlockKindDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var order: Int
    public var owner: String
    /// Built-in kind, or `.custom` with `customType` = "<owner>.<type>".
    public var kind: BlockKind
    public var customType: String?
    /// Command that inserts the block ({doc, after?} merged over `params`); nil = plain `block.insert` of `kind`.
    public var command: String?
    public var params: JSONValue
    public var aliases: [String]

    public init(id: String, title: String, icon: String, kind: BlockKind, owner: String, order: Int = 0,
                customType: String? = nil, command: String? = nil, params: JSONValue = [:], aliases: [String] = []) {
        self.id = id
        self.title = title
        self.icon = icon
        self.order = order
        self.owner = owner
        self.kind = kind
        self.customType = customType
        self.command = command
        self.params = params
        self.aliases = aliases
    }
}

/// Describes a custom item type (id = "custom.<owner>.<type>", the item's `drawKey`), so search, recognition,
/// accessibility and the AI can read its text without knowing the owner.
public struct CustomItemTypeDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    /// Dot path inside `CustomItem.data` holding the item's text (e.g. "title" or "series.label").
    public var textPath: String?
    /// Command called with {ref} to edit the item (double-tap, inspector "Edit").
    public var editCommand: String?

    public init(owner: String, type: String, title: String, textPath: String? = nil, editCommand: String? = nil, order: Int = 0) {
        self.id = "custom." + owner + "." + type
        self.title = title
        self.order = order
        self.owner = owner
        self.textPath = textPath
        self.editCommand = editCommand
    }
}

/// An action users can bind to Apple Pencil double-tap or squeeze (offered by F043's settings).
public struct PencilActionDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    public var gestures: Set<String>
    public var command: String
    public var params: JSONValue

    public init(id: String, title: String, owner: String, command: String, params: JSONValue = [:],
                gestures: Set<String> = ["doubleTap", "squeeze"], order: Int = 0) {
        self.id = id
        self.title = title
        self.order = order
        self.owner = owner
        self.gestures = gestures
        self.command = command
        self.params = params
    }
}

// MARK: - Container

/// Non-UI registries (thread-safe; templates and drawers are read on render threads).
public final class ContentRegistries {
    public let templates = Registry<TemplateDefinition>()
    public let drawers = Registry<ItemDrawerEntry>()
    public let importers = Registry<ImporterDescriptor>()
    public let exporters = Registry<ExporterDescriptor>()
    public let aiActions = Registry<AIActionDescriptor>()
    public let strokeProcessors = Registry<StrokeProcessorEntry>()
    public let keyCommands = Registry<KeyCommandDescriptor>()
    public let backgroundTasks = Registry<BackgroundTaskDescriptor>()
    public let tapHandlers = Registry<TapHandlerDescriptor>()
    public let boardTemplates = Registry<BoardTemplateDescriptor>()
    public let tapePatterns = Registry<TapePatternDescriptor>()
    public let elementCollections = Registry<ElementCollectionDescriptor>()
    public let blockKinds = Registry<BlockKindDescriptor>()
    public let customItemTypes = Registry<CustomItemTypeDescriptor>()
    public let pencilActions = Registry<PencilActionDescriptor>()

    public init() {}

    public func drawer(for item: Item) -> ItemDrawer? {
        drawers.get(item.drawKey)?.drawer ?? drawers.get(item.kind.rawValue)?.drawer
    }

    public func template(_ ref: TemplateRef) -> TemplateDefinition? { templates.get(ref.id) }

    public func importer(forExtension ext: String) -> ImporterDescriptor? {
        let e = ext.lowercased()
        return importers.all.first { $0.fileExtensions.contains(e) }
    }
}
```

### `NibKit/Sources/NibContracts/Core/CoreCommands.swift`

```swift
import Foundation

/// Commands that live in the contracts layer and are registered by `NibApp.init`.
enum CoreCommands {
    @MainActor
    static func register(_ r: CommandRegistry) {
        r.register(EditUndo.self)
        r.register(EditRedo.self)
        r.register(HistoryList.self)
        r.register(HistoryRevertGroup.self)
        r.register(CommandsList.self)
        r.register(CommandsDescribe.self)
        r.register(CommandsBatch.self)
        r.register(ToolSelect.self)
        r.register(SettingsGet.self)
        r.register(SettingsSet.self)
        r.register(SettingsList.self)
        r.register(SettingsDescribe.self)
    }
}

struct DocParams: Codable {
    var doc: String
}

struct EditUndo: NibCommand {
    struct Output: Codable {
        var done: Bool
        var label: String?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.undo, title: "Undo",
        summary: "Undo the last change in a document (same as the Undo button). A whole AI turn or plugin call undoes as one step.",
        params: .obj(["doc": .ref], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]], effect: .edit)

    static func run(_ p: DocParams, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        let label = ctx.bus.history.undoLabel(doc)
        return Output(done: ctx.bus.undo(doc), label: label)
    }
}

struct EditRedo: NibCommand {
    struct Output: Codable {
        var done: Bool
        var label: String?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.redo, title: "Redo",
        summary: "Redo the last undone change in a document.",
        params: .obj(["doc": .ref], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]], effect: .edit)

    static func run(_ p: DocParams, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        let label = ctx.bus.history.redoLabel(doc)
        return Output(done: ctx.bus.redo(doc), label: label)
    }
}

struct HistoryList: NibCommand {
    struct Params: Codable {
        var doc: String
        var limit: Int?
    }
    struct Row: Codable {
        var group: String
        var label: String
        var principal: String
        var changes: Int
        var at: Double
    }
    struct Output: Codable {
        var entries: [Row]
        var canRedo: Bool
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.historyList, title: "History",
        summary: "List undoable changes in a document, newest first, with their undo group ids (for history.revertGroup).",
        params: .obj(["doc": .ref, "limit": .int(min: 1, max: 200)], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01", "limit": 10]], effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        let rows = ctx.bus.history.entries(doc).reversed().prefix(p.limit ?? 50).map {
            Row(group: $0.group, label: $0.label, principal: $0.principal.description, changes: $0.mutations.count,
                at: $0.at.timeIntervalSince1970)
        }
        return Output(entries: Array(rows), canRedo: ctx.bus.history.canRedo(doc))
    }
}

struct HistoryRevertGroup: NibCommand {
    struct Params: Codable {
        var doc: String
        var group: String
    }
    struct Output: Codable {
        var reverted: Int
        var skipped: Int
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.revertGroup, title: "Revert Changes",
        summary: "Revert one undo group (e.g. everything an AI turn did) even after later edits; records changed since are skipped.",
        params: .obj(["doc": .ref, "group": .str("undo group id from history.list or an AI turn")], required: ["doc", "group"]),
        examples: [["doc": "doc:FIXTUREDOC01", "group": "G0"]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        guard let r = ctx.bus.revert(group: p.group, doc: doc, principal: ctx.principal) else {
            throw NibError.notFound("undo group '\(p.group)'")
        }
        return Output(reverted: r.reverted, skipped: r.skipped)
    }
}

struct CommandsList: NibCommand {
    struct Params: Codable {
        var namespace: String?
    }
    struct Row: Codable {
        var id: String
        var title: String
        var summary: String
        var effect: String
        var destructive: Bool
    }
    struct Output: Codable {
        var commands: [Row]
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.commandsList, title: "List Commands",
        summary: "List the commands you may call (id, one-line summary, effect). Optional namespace prefix such as 'page' or 'shape'.",
        params: .obj(["namespace": .str("namespace prefix, e.g. 'ink'")]),
        examples: [[:], ["namespace": "edit"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let exposure = ctx.principal.exposure
        let rows = ctx.bus.registry.all().filter { d in
            let visible = ctx.principal.isUser || d.exposure.contains(exposure)
            let inNamespace = p.namespace.map { d.id == $0 || d.id.hasPrefix($0 + ".") } ?? true
            return visible && inNamespace
        }.map { Row(id: $0.id, title: $0.title, summary: $0.summary, effect: $0.effect.rawValue, destructive: $0.destructive) }
        return Output(commands: rows)
    }
}

struct CommandsDescribe: NibCommand {
    struct Params: Codable {
        var id: String
    }
    struct Output: Codable {
        var id: String
        var title: String
        var summary: String
        var params: JSONValue
        var examples: [JSONValue]
        var effect: String
        var destructive: Bool
        var scopes: [String]
        var owner: String
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.commandsDescribe, title: "Describe Command",
        summary: "Full JSON schema, examples, effect and required permissions of one command.",
        params: .obj(["id": .str("command id, e.g. 'ink.addStrokes'")], required: ["id"]),
        examples: [["id": "edit.undo"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let d = ctx.bus.registry.descriptor(p.id),
              ctx.principal.isUser || d.exposure.contains(ctx.principal.exposure) else {
            throw NibError(.notFound, "unknown command '\(p.id)'", hint: "call commands.list")
        }
        return Output(id: d.id, title: d.title, summary: d.summary, params: d.params.toJSON(), examples: d.examples,
                      effect: d.effect.rawValue, destructive: d.destructive, scopes: d.scopes.map { $0.rawValue }.sorted(),
                      owner: d.owner)
    }
}

struct CommandsBatch: NibCommand {
    struct Call: Codable {
        var command: String
        var params: JSONValue?
    }
    struct Params: Codable {
        var calls: [Call]
        var stopOnError: Bool?
    }
    struct Outcome: Codable {
        var ok: Bool
        var value: JSONValue?
        var error: NibError?
    }
    struct Output: Codable {
        var results: [Outcome]
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.batch, title: "Batch",
        summary: "Run several commands in order as ONE undo step (each is permission-checked). Give new items your own ids to link them.",
        params: .obj(["calls": .arr(.obj(["command": .str(), "params": .obj([:])], required: ["command"])),
                      "stopOnError": .bool("default true")], required: ["calls"]),
        examples: [["calls": [["command": "commands.list", "params": ["namespace": "edit"]]]]],
        effect: .read, target: .app, forwardsCalls: true)   // effect = the calls' effects: each call is authorized,
                                                            // and in ask mode every call must be `read`

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        var out: [Outcome] = []
        for call in p.calls {
            do {
                let v = try await ctx.execute(call.command, call.params ?? [:])
                out.append(Outcome(ok: true, value: v, error: nil))
            } catch {
                out.append(Outcome(ok: false, value: nil, error: NibError.wrap(error)))
                if p.stopOnError ?? true { break }
            }
        }
        return Output(results: out)
    }
}

struct ToolSelect: NibCommand {
    struct Params: Codable {
        var tool: String
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.toolSelect, title: "Select Tool",
        summary: "Activate a canvas tool in the current window: pen, pencil, highlighter, eraser, lasso, shape, text, tape, laser, or a plugin tool id.",
        params: .obj(["tool": .str("tool id")], required: ["tool"]),
        examples: [["tool": "pen"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let session = ctx.activeSession else { throw NibError.unavailable("an open editor window") }
        session.tool = p.tool
        return NoResult()
    }
}

struct SettingsGet: NibCommand {
    struct Params: Codable {
        var name: String
    }
    struct Output: Codable {
        var name: String
        var value: JSONValue?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsGet, title: "Get Setting",
        summary: "Read a setting by name, e.g. 'editing.scrollDirection' or 'plugin.<id>.<key>' (see settings.list).",
        params: .obj(["name": .str()], required: ["name"]),
        examples: [["name": "editing.scrollDirection"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if p.name.hasPrefix("security.") && !ctx.principal.isUser {
            throw NibError(.permissionDenied, "security settings can only be read by the user")
        }
        return Output(name: p.name, value: ctx.services.settings.json(p.name))
    }
}

struct SettingsSet: NibCommand {
    struct Params: Codable {
        var name: String
        var value: JSONValue?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsSet, title: "Change Setting",
        summary: "Change a declared setting (null resets it); the value is validated. 'security.*' is user-only, 'managed.*' read-only.",
        params: .obj(["name": .str(), "value": .anything("new value; null resets to default")], required: ["name"]),
        examples: [["name": "editing.scrollDirection", "value": "horizontal"]], effect: .edit, target: .app,
        undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let d = ctx.services.settings.descriptor(p.name) else {
            throw NibError(.notFound, "unknown setting '\(p.name)'", hint: "call settings.list to see setting names")
        }
        if d.userOnly && !ctx.principal.isUser {
            throw NibError(.permissionDenied, "security settings can only be changed by the user")
        }
        if d.readOnly { throw NibError(.permissionDenied, "'\(p.name)' is read-only (managed configuration)") }
        if let v = p.value, v != .null, let e = d.schema.validate(v, path: "$.value").first {
            throw NibError(e.code, e.message, path: e.path, hint: "call settings.describe {\"name\": \"\(p.name)\"}")
        }
        ctx.services.settings.setJSON(p.name, p.value)
        return NoResult()
    }
}

struct SettingsList: NibCommand {
    struct Params: Codable {
        var prefix: String?
    }
    struct Row: Codable {
        var name: String
        var summary: String
        var synced: Bool
        var owner: String
    }
    struct Output: Codable {
        var settings: [Row]
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsList, title: "List Settings",
        summary: "List declared settings (name, summary, synced, owner), optionally under a name prefix like 'editing.'.",
        params: .obj(["prefix": .str("name prefix, e.g. 'editing.'")]),
        examples: [[:], ["prefix": "editing."]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let rows = ctx.services.settings.declaredSettings
            .filter { p.prefix.map($0.name.hasPrefix) ?? true }
            .filter { ctx.principal.isUser || !$0.userOnly }
            .map { Row(name: $0.name, summary: $0.summary, synced: $0.synced, owner: $0.owner) }
        return Output(settings: rows)
    }
}

struct SettingsDescribe: NibCommand {
    struct Params: Codable {
        var name: String
    }
    struct Output: Codable {
        var name: String
        var summary: String
        var schema: JSONValue
        var defaultValue: JSONValue
        var synced: Bool
        var readOnly: Bool
        var userOnly: Bool
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsDescribe, title: "Describe Setting",
        summary: "Schema, default value and flags of one setting (or of the family a per-entry name belongs to).",
        params: .obj(["name": .str()], required: ["name"]),
        examples: [["name": "editing.scrollDirection"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let d = ctx.services.settings.descriptor(p.name) else {
            throw NibError(.notFound, "unknown setting '\(p.name)'", hint: "call settings.list")
        }
        return Output(name: d.name, summary: d.summary, schema: d.schema.toJSON(), defaultValue: d.defaultValue,
                      synced: d.synced, readOnly: d.readOnly, userOnly: d.userOnly)
    }
}
```

### `NibKit/Sources/NibContracts/UI/UIBridges.swift`

```swift
import UIKit
import PencilKit

// MARK: - CoreGraphics / UIKit conversions

public extension Point {
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

public extension Rect {
    init(_ r: CGRect) { self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height)) }
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public extension Affine {
    init(_ t: CGAffineTransform) {
        self.init(a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d), tx: Double(t.tx), ty: Double(t.ty))
    }
    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

public extension RGBA {
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            _ = color.getWhite(&white, alpha: &a)
            r = white
            g = white
            b = white
        }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(byte(r), byte(g), byte(b), byte(a))
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    var cgColor: CGColor { uiColor.cgColor }
}

// MARK: - PencilKit bridge

/// Converts between the platform-neutral `Stroke` model and PencilKit. Used by the canvas (wet ink capture),
/// the renderer (drawing strokes with PencilKit's ink look) and anything that needs `PKDrawing`s.
public enum PKBridge {
    public static func inkType(_ style: InkStyle) -> PKInk.InkType {
        switch style.tool {
        case .pencil: return .pencil
        case .highlighter: return .marker
        case .tape: return .monoline
        case .pen:
            switch style.pen ?? .fountain {
            case .fountain: return .fountainPen
            case .ball: return .monoline
            case .brush: return .pen
            }
        }
    }

    public static func ink(_ style: InkStyle) -> PKInk {
        PKInk(inkType(style), color: style.color.uiColor)
    }

    public static func pkStroke(_ stroke: Stroke) -> PKStroke {
        var s = stroke
        InkModel.prepare(&s)                       // densifies synthetic (zero-width) strokes; no-op for captured ink
        var pts = s.points
        InkModel.fillSizes(&pts, style: s.style)
        let controls = pts.map { p in
            PKStrokePoint(location: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)),
                          timeOffset: TimeInterval(p.t),
                          size: CGSize(width: CGFloat(p.width), height: CGFloat(p.height)),
                          opacity: CGFloat(p.opacity),
                          force: CGFloat(p.force),
                          azimuth: CGFloat(p.azimuth),
                          altitude: CGFloat(p.altitude))
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: stroke.t0))
        return PKStroke(ink: ink(stroke.style), path: path)
    }

    public static func drawing(_ strokes: [Stroke]) -> PKDrawing {
        PKDrawing(strokes: strokes.map { pkStroke($0) })
    }

    /// Converts a captured PencilKit stroke (canvas coordinates == page coordinates) into the model.
    /// `rolls` are barrel-roll samples (time offset in seconds, radians) captured separately (Pencil Pro).
    public static func stroke(from pk: PKStroke, style: InkStyle, rolls: [(t: Double, roll: Double)] = []) -> Stroke {
        let transform = pk.transform
        var pts: [StrokePoint] = []
        pts.reserveCapacity(pk.path.count)
        for p in pk.path {
            let loc = p.location.applying(transform)
            pts.append(StrokePoint(x: Float(loc.x), y: Float(loc.y), t: Float(p.timeOffset), force: Float(p.force),
                                   azimuth: Float(p.azimuth), altitude: Float(p.altitude),
                                   roll: Float(roll(at: p.timeOffset, in: rolls)),
                                   width: Float(p.size.width), height: Float(p.size.height), opacity: Float(p.opacity)))
        }
        return Stroke(style: style, points: pts, t0: pk.path.creationDate.timeIntervalSince1970)
    }

    static func roll(at t: Double, in rolls: [(t: Double, roll: Double)]) -> Double {
        guard !rolls.isEmpty else { return 0 }
        var best = rolls[0]
        for r in rolls where abs(r.t - t) < abs(best.t - t) { best = r }
        return best.roll
    }
}

// MARK: - Rich text bridge

public extension NSAttributedString.Key {
    /// ListKind raw value on every character of a list paragraph.
    static let nibList = NSAttributedString.Key("nib.list")
    /// Marks generated bullet / number / checkbox text (stripped when converting back).
    static let nibListMarker = NSAttributedString.Key("nib.listMarker")
    static let nibChecked = NSAttributedString.Key("nib.checked")
    static let nibIndent = NSAttributedString.Key("nib.indent")
    static let nibParagraphStyle = NSAttributedString.Key("nib.paragraphStyle")
}

/// `RichText` ⇄ `NSAttributedString` (TextKit editing and drawing). Links use `nib://` URLs for
/// page and audio targets: nib://open/<doc>/<page>, nib://audio/<doc>/<clip>?t=<seconds>.
public enum RichTextBridge {
    public static var defaultFontFamily = "Helvetica"
    public static var defaultFontSize: Double = 17
    public static let indentStep: CGFloat = 24

    public static func font(_ a: TextAttributes, base: TextAttributes = TextAttributes()) -> UIFont {
        let size = CGFloat(a.size ?? base.size ?? defaultFontSize)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if a.bold ?? base.bold ?? false { traits.insert(.traitBold) }
        if a.italic ?? base.italic ?? false { traits.insert(.traitItalic) }
        if a.code ?? base.code ?? false {
            return UIFont.monospacedSystemFont(ofSize: size, weight: traits.contains(.traitBold) ? .bold : .regular)
        }
        var desc = UIFontDescriptor(fontAttributes: [.family: a.font ?? base.font ?? defaultFontFamily])
        if !traits.isEmpty, let d = desc.withSymbolicTraits(traits) { desc = d }
        return UIFont(descriptor: desc, size: size)
    }

    public static func attributes(_ a: TextAttributes, base: TextAttributes = TextAttributes()) -> [NSAttributedString.Key: Any] {
        var d: [NSAttributedString.Key: Any] = [:]
        var sized = a
        if let b = a.baseline, b != 0 {
            let size = a.size ?? base.size ?? defaultFontSize
            sized.size = size * 0.7
            d[.baselineOffset] = CGFloat(Double(b) * size * 0.35)
        }
        d[.font] = font(sized, base: base)
        d[.foregroundColor] = (a.color ?? base.color ?? .black).uiColor
        if let h = a.highlight ?? base.highlight { d[.backgroundColor] = h.uiColor }
        if a.underline ?? base.underline ?? false { d[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if a.strikethrough ?? base.strikethrough ?? false { d[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let l = a.link, let u = linkURL(l) { d[.link] = u }
        return d
    }

    public static func attributed(_ text: RichText, base: TextAttributes = TextAttributes()) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var number = 0
        for (i, p) in text.paragraphs.enumerated() {
            let ps = NSMutableParagraphStyle()
            ps.alignment = alignment(p.align)
            if let ls = p.lineSpacing { ps.lineSpacing = CGFloat(ls) }
            let indent = CGFloat(p.indent) * indentStep
            ps.firstLineHeadIndent = indent
            ps.headIndent = indent + (p.list == .plain ? 0 : 20)
            var paragraphAttrs: [NSAttributedString.Key: Any] = [.paragraphStyle: ps, .nibList: p.list.rawValue, .nibIndent: p.indent]
            if p.checked { paragraphAttrs[.nibChecked] = true }
            if let s = p.style { paragraphAttrs[.nibParagraphStyle] = s }
            number = (p.list == .number || p.list == .numberParen) ? number + 1 : 0
            if let marker = marker(p.list, number: number, checked: p.checked) {
                var a = attributes(p.runs.first?.attrs ?? TextAttributes(), base: base)
                a.merge(paragraphAttrs) { $1 }
                a[.nibListMarker] = true
                out.append(NSAttributedString(string: marker, attributes: a))
            }
            for r in p.runs {
                var a = attributes(r.attrs, base: base)
                a.merge(paragraphAttrs) { $1 }
                out.append(NSAttributedString(string: r.text, attributes: a))
            }
            if i < text.paragraphs.count - 1 {
                var a = attributes(p.runs.last?.attrs ?? TextAttributes(), base: base)
                a.merge(paragraphAttrs) { $1 }
                out.append(NSAttributedString(string: "\n", attributes: a))
            }
        }
        return out
    }

    public static func richText(_ s: NSAttributedString) -> RichText {
        let ns = s.string as NSString
        let length = ns.length
        var paragraphs: [Paragraph] = []
        var start = 0
        repeat {
            let range = ns.paragraphRange(for: NSRange(location: start, length: 0))
            var content = range
            if content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            paragraphs.append(paragraph(s, content))
            start = NSMaxRange(range)
        } while start < length
        if length > 0 && ns.character(at: length - 1) == 10 { paragraphs.append(Paragraph()) }
        return RichText(paragraphs: paragraphs.isEmpty ? [Paragraph()] : paragraphs)
    }

    public static func textAttributes(_ a: [NSAttributedString.Key: Any]) -> TextAttributes {
        var t = TextAttributes()
        if let f = a[.font] as? UIFont {
            t.size = Double(f.pointSize)
            let traits = f.fontDescriptor.symbolicTraits
            if traits.contains(.traitBold) { t.bold = true }
            if traits.contains(.traitItalic) { t.italic = true }
            if traits.contains(.traitMonoSpace) {
                t.code = true
            } else if f.familyName != defaultFontFamily {
                t.font = f.familyName
            }
        }
        if let c = a[.foregroundColor] as? UIColor {
            let rgba = RGBA(c)
            if rgba != .black { t.color = rgba }
        }
        if let c = a[.backgroundColor] as? UIColor { t.highlight = RGBA(c) }
        if let u = a[.underlineStyle] as? Int, u != 0 { t.underline = true }
        if let u = a[.strikethroughStyle] as? Int, u != 0 { t.strikethrough = true }
        if let b = a[.baselineOffset] as? CGFloat, b != 0 {
            t.baseline = b > 0 ? 1 : -1
            if let s = t.size { t.size = (s / 0.7).rounded() }
        }
        if let url = a[.link] as? URL {
            t.link = link(from: url)
        } else if let s = a[.link] as? String, let url = URL(string: s) {
            t.link = link(from: url)
        }
        return t
    }

    public static func linkURL(_ link: TextLink) -> URL? {
        if let u = link.url { return URL(string: u) }
        guard let doc = link.document else { return nil }
        var c = URLComponents()
        c.scheme = NibFormat.urlScheme
        if let clip = link.audioClip {
            c.host = "audio"
            c.path = "/" + doc.raw + "/" + clip.raw
            c.queryItems = [URLQueryItem(name: "t", value: String(link.audioTime ?? 0))]
        } else {
            c.host = "open"
            c.path = "/" + doc.raw + (link.page.map { "/" + $0.raw } ?? "")
        }
        return c.url
    }

    public static func link(from url: URL) -> TextLink {
        guard url.scheme == NibFormat.urlScheme else { return TextLink(url: url.absoluteString) }
        let parts = url.path.split(separator: "/").map { String($0) }
        if url.host == "audio", parts.count >= 2 {
            let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "t" }?.value.flatMap { Double($0) }
            return TextLink(document: NibID(parts[0]), audioClip: NibID(parts[1]), audioTime: t)
        }
        if url.host == "open", let d = parts.first {
            return TextLink(document: NibID(d), page: parts.count > 1 ? NibID(parts[1]) : nil)
        }
        return TextLink(url: url.absoluteString)
    }

    // MARK: Private

    static func alignment(_ a: ParagraphAlignment) -> NSTextAlignment {
        switch a {
        case .natural: return .natural
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
    }

    static func alignment(_ a: NSTextAlignment) -> ParagraphAlignment {
        switch a {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        default: return .natural
        }
    }

    static func marker(_ list: ListKind, number: Int, checked: Bool) -> String? {
        switch list {
        case .plain: return nil
        case .bullet: return "• "
        case .number: return "\(number). "
        case .numberParen: return "\(number)) "
        case .todo: return checked ? "☑ " : "☐ "
        }
    }

    static func paragraph(_ s: NSAttributedString, _ range: NSRange) -> Paragraph {
        var p = Paragraph()
        guard s.length > 0 else { return p }
        let probe = min(range.location, s.length - 1)
        let attrs = s.attributes(at: probe, effectiveRange: nil)
        if let ps = attrs[.paragraphStyle] as? NSParagraphStyle {
            p.align = alignment(ps.alignment)
            p.lineSpacing = ps.lineSpacing > 0 ? Double(ps.lineSpacing) : nil
        }
        if let indent = attrs[.nibIndent] as? Int { p.indent = indent }
        if let l = attrs[.nibList] as? String, let k = ListKind(rawValue: l) { p.list = k }
        p.checked = (attrs[.nibChecked] as? Bool) ?? false
        p.style = attrs[.nibParagraphStyle] as? String
        guard range.length > 0 else { return p }
        var runs: [TextRun] = []
        s.enumerateAttributes(in: range, options: []) { a, r, _ in
            if a[.nibListMarker] != nil { return }
            let text = (s.string as NSString).substring(with: r)
            let attrs = textAttributes(a)
            if let last = runs.last, last.attrs == attrs {
                runs[runs.count - 1].text += text
            } else {
                runs.append(TextRun(text, attrs))
            }
        }
        p.runs = runs
        return p
    }
}
```

### `NibKit/Sources/NibContracts/UI/Canvas.swift`

```swift
import UIKit

public enum CanvasInputMode {
    /// The canvas captures ink with PencilKit (wet ink) and hands the finished stroke to the tool.
    case pencilKit
    /// The tool receives raw samples and draws its own preview into `CanvasHost.overlayLayer`.
    case samples
    /// Taps only (text, sticky, image placement…).
    case taps
}

public struct CanvasSample {
    public var page: PageID
    /// Page coordinates.
    public var location: Point
    public var force: Double
    public var azimuth: Double
    public var altitude: Double
    /// Apple Pencil Pro barrel roll (radians), 0 when unavailable.
    public var roll: Double
    public var timestamp: TimeInterval
    public var isPencil: Bool
    public var isPredicted: Bool
    public var modifiers: KeyModifiers

    public init(page: PageID, location: Point, force: Double = 0.5, azimuth: Double = 0, altitude: Double = .pi / 2,
                roll: Double = 0, timestamp: TimeInterval = 0, isPencil: Bool = true, isPredicted: Bool = false,
                modifiers: KeyModifiers = []) {
        self.page = page
        self.location = location
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.roll = roll
        self.timestamp = timestamp
        self.isPencil = isPencil
        self.isPredicted = isPredicted
        self.modifiers = modifiers
    }
}

/// What the canvas (Canvas feature) offers to tools, gesture handlers and the Pencil handler.
@MainActor
public protocol CanvasHost: AnyObject {
    var app: NibApp { get }
    var session: EditorSession { get }
    var documentID: DocumentID { get }
    /// Current zoom (view points per page point).
    var zoomScale: Double { get }
    /// The scrolling canvas view (for presenting menus, loupes, pencil palettes). Named `canvasView` so a
    /// UIViewController (whose `view` is `UIView!`) can conform.
    var canvasView: UIView { get }
    /// Transient drawing layer of the ACTIVE TOOL in `canvasView` coordinates (previews, lasso path). Cleared by tools.
    /// Anything persistent (selection handles, underlines, presence cursors, minimap…) is a `CanvasAttachment`.
    var overlayLayer: CALayer { get }
    func viewPoint(_ p: Point, page: PageID) -> CGPoint
    /// Page under a view point, with the point in page coordinates.
    func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)?
    /// Page frame in `view` coordinates, nil when not laid out.
    func pageFrame(_ page: PageID) -> CGRect?
    /// Temporarily hide items (drag previews); pass [] to show again.
    func setHidden(_ ids: Set<ElementID>, page: PageID)
    func invalidate(page: PageID, rect: Rect?)
    /// Commits a finished stroke through `ink.addStrokes` (applies stroke processors first).
    func commitStroke(_ stroke: Stroke, page: PageID)
    /// Cancels the in-progress PencilKit stroke (Draw-and-Hold takes over).
    func cancelWetStroke()
    /// Keeps a live view (animated GIF, video, plugin view) positioned over an item's frame; nil removes it.
    func attachLiveView(_ view: UIView?, item: ElementID, page: PageID)
}

/// A canvas tool. Registered via `UIRegistries.canvasTools`; activated by `tool.select`.
@MainActor
public protocol CanvasTool: AnyObject {
    var id: String { get }
    var inputMode: CanvasInputMode { get }
    /// Sticky tools stay active; non-sticky tools return to the previous tool after one use.
    var isSticky: Bool { get }
    /// `.pencilKit` tools: the ink to capture with.
    func inkStyle(_ host: CanvasHost) -> InkStyle?
    func activate(_ host: CanvasHost)
    func deactivate(_ host: CanvasHost)
    /// `.pencilKit`: a stroke finished (processors not yet applied). Default commits it.
    func strokeFinished(_ stroke: Stroke, page: PageID, host: CanvasHost)
    /// `.pencilKit`: the pen was held still at the end of a stroke. Return true to consume it: the wet stroke is
    /// cancelled and the rest of that touch arrives through `touchesMoved` / `touchesEnded` (Draw-and-Hold).
    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost)
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost)
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost)
    func touchesCancelled(host: CanvasHost)
    func tap(_ sample: CanvasSample, host: CanvasHost)
    /// Touch held still for 0.5 s on the page (after attachments and `content.tapHandlers` declined it).
    func longPress(_ sample: CanvasSample, host: CanvasHost)
    func hover(_ sample: CanvasSample?, host: CanvasHost)
}

@MainActor
public extension CanvasTool {
    var isSticky: Bool { true }
    func inkStyle(_ host: CanvasHost) -> InkStyle? { nil }
    func activate(_ host: CanvasHost) {}
    func deactivate(_ host: CanvasHost) {}
    func strokeFinished(_ stroke: Stroke, page: PageID, host: CanvasHost) { host.commitStroke(stroke, page: page) }
    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool { false }
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {}
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesCancelled(host: CanvasHost) {}
    func tap(_ sample: CanvasSample, host: CanvasHost) {}
    func longPress(_ sample: CanvasSample, host: CanvasHost) {}
    func hover(_ sample: CanvasSample?, host: CanvasHost) {}
}

/// Something that lives on the canvas independently of the active tool: selection handles (F012), shape control
/// points (F031), connector bends and quick-diagram dots (F032), spellcheck underlines (F104), Math Assist glow
/// (F106), presence cursors (F108), minimap (F044), ruler (F039), zoom box (F038), plugin decorations
/// (`canvas.decorate`), answer-zone widgets (F099). Registered through `ui.canvasAttachments`; the canvas creates
/// one instance per canvas host and gives it its own layer/view.
@MainActor
public protocol CanvasAttachment: AnyObject {
    /// Add sublayers/subviews to `host.canvasView` here; called once per canvas (document opened).
    func attach(to host: CanvasHost)
    func detach(from host: CanvasHost)
    /// Scroll, zoom, page layout, selection or a commit changed: reposition what you draw.
    func canvasDidChange(_ host: CanvasHost)
    /// True = this attachment takes the touch that starts at `viewPoint` (asked before tap handlers and the active
    /// tool, in registry order); the touch's samples then go to the touch methods below.
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost)
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost)
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost)
    func touchesCancelled(host: CanvasHost)
}

@MainActor
public extension CanvasAttachment {
    func detach(from host: CanvasHost) {}
    func canvasDidChange(_ host: CanvasHost) {}
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool { false }
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {}
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesCancelled(host: CanvasHost) {}
}

public struct CanvasAttachmentDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var docKinds: Set<DocumentKind>
    public var make: @MainActor (CanvasHost) -> CanvasAttachment

    public init(id: String, owner: String, order: Int = 0, docKinds: Set<DocumentKind> = [.notebook, .whiteboard],
                make: @escaping @MainActor (CanvasHost) -> CanvasAttachment) {
        self.id = id
        self.order = order
        self.owner = owner
        self.docKinds = docKinds
        self.make = make
    }
}

/// Apple Pencil hardware events forwarded by the canvas (Pencil Hardware feature).
@MainActor
public protocol PencilEventHandler: AnyObject {
    func pencilDoubleTap(session: EditorSession, host: CanvasHost)
    func pencilSqueeze(began: Bool, location: CGPoint?, session: EditorSession, host: CanvasHost)
    func pencilHover(_ sample: CanvasSample?, session: EditorSession, host: CanvasHost)
}

/// Implemented by every document editor view controller (canvas, text document, study set).
@MainActor
public protocol DocumentEditing: AnyObject {
    var documentID: DocumentID { get }
    var session: EditorSession { get }
    /// nil for editors without a page canvas.
    var canvasHost: CanvasHost? { get }
    func reveal(page: PageID, rect: Rect?, animated: Bool)
    func reloadAll()
}
```

### `NibKit/Sources/NibContracts/UI/UIRegistries.swift`

```swift
import SwiftUI
import UIKit

// MARK: - Toolbar

public enum ToolbarGroup: String, Codable, CaseIterable {
    /// Fixed first slot (Lasso).
    case lasso
    /// Writing tools (pen, pencil, highlighter, eraser, tape, shapes…).
    case tools
    /// Accessories (audio, ruler, zoom window, timer, laser…).
    case accessories
    /// Document nav bar, left side (library, sidebar, search, AI, read-only).
    case navLeading
    /// Document nav bar, right side (add page, share/export, more).
    case navTrailing
}

/// Every toolbar button is either a canvas tool (activated via `tool.select`) or a command. No other actions exist.
public struct ToolbarItemDescriptor: Registrable {
    public var id: String
    public var title: String
    /// SF Symbol name.
    public var icon: String
    public var group: ToolbarGroup
    public var order: Int
    public var owner: String
    public var toolID: String?
    public var command: String?
    public var params: JSONValue
    public var shortcut: KeyShortcut?
    /// Can be hidden in Toolbar Customization (Lasso cannot).
    public var hideable: Bool
    public var docKinds: Set<DocumentKind>
    /// Contextual options bar shown while this tool is active (presets, colors, sizes).
    public var activeToolMenu: (@MainActor (EditorSession) -> AnyView)?
    /// Settings popover shown when the already-selected tool is tapped again.
    public var settings: (@MainActor (EditorSession) -> AnyView)?

    public init(id: String, title: String, icon: String, group: ToolbarGroup, order: Int, owner: String,
                toolID: String? = nil, command: String? = nil, params: JSONValue = [:], shortcut: KeyShortcut? = nil,
                hideable: Bool = true, docKinds: Set<DocumentKind> = [.notebook, .whiteboard],
                activeToolMenu: (@MainActor (EditorSession) -> AnyView)? = nil,
                settings: (@MainActor (EditorSession) -> AnyView)? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.group = group
        self.order = order
        self.owner = owner
        self.toolID = toolID
        self.command = command
        self.params = params
        self.shortcut = shortcut
        self.hideable = hideable
        self.docKinds = docKinds
        self.activeToolMenu = activeToolMenu
        self.settings = settings
    }
}

// MARK: - Menus

public enum MenuLocation: String, Codable, CaseIterable {
    /// Quick-action icon row / full list above a selection.
    case objectMenu
    /// Long-press on empty page area.
    case pageLongPress
    /// Document "More (…)" menu.
    case documentMore
    /// Tap on the document title.
    case documentTitle
    /// Add Page (+) menu.
    case addPage
    /// Share & Export menu.
    case shareExport
    /// Per-item menu in the library.
    case libraryItem
    /// New (+) creation menu in the library.
    case libraryNew
    /// Actions for a multi-selection in the library.
    case librarySelection
    /// App menu (avatar / gear in the library).
    case appMenu
    /// Page thumbnail menu in the sidebar.
    case sidebarPage
    /// Actions for selected thumbnails.
    case sidebarSelection
    /// Selected typed text (text boxes, blocks).
    case textSelection
    /// Audio clip row.
    case audioClip
    /// Text-document block handle menu.
    case block
    /// Study-set card menu.
    case card
    /// Whiteboard board (Boards sidebar) menu.
    case board
    /// Outline entry menu.
    case outlineEntry
    /// Comment thread menu.
    case comment
    /// Transcript line menu.
    case transcriptSegment
    /// Document tab menu.
    case tab
}

public struct MenuContext {
    public var app: NibApp
    public var session: EditorSession?
    public var doc: DocumentID?
    public var page: PageID?
    /// Long-press location in page coordinates.
    public var point: Point?
    public var selection: Selection
    public var itemKinds: Set<ItemKind>
    /// Library selection (items, folders) or sidebar selection (pages).
    public var nodes: [NibID]
    /// The ref the menu is for (block, card, board page, outline entry, comment item, audio clip, tab document);
    /// transcript lines use "audio:D/A" plus `index`.
    public var ref: String?
    public var index: Int?

    public init(app: NibApp, session: EditorSession? = nil, doc: DocumentID? = nil, page: PageID? = nil, point: Point? = nil,
                selection: Selection = Selection(), itemKinds: Set<ItemKind> = [], nodes: [NibID] = [],
                ref: String? = nil, index: Int? = nil) {
        self.app = app
        self.session = session
        self.doc = doc
        self.page = page
        self.point = point
        self.selection = selection
        self.itemKinds = itemKinds
        self.nodes = nodes
        self.ref = ref
        self.index = index
    }
}

/// A menu entry always runs a command (so plugins, AI and the bridge can do the same thing).
public struct MenuItemDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String?
    public var location: MenuLocation
    public var order: Int
    public var owner: String
    public var command: String
    public var params: @MainActor (MenuContext) -> JSONValue
    public var isVisible: @MainActor (MenuContext) -> Bool
    public var destructive: Bool
    /// Shown as an icon in the object menu's quick row.
    public var quick: Bool
    /// Sub-menu title this entry is grouped under (nil = top level).
    public var submenu: String?

    public init(id: String, title: String, icon: String? = nil, location: MenuLocation, order: Int, owner: String,
                command: String,
                params: @escaping @MainActor (MenuContext) -> JSONValue = { _ in [:] },
                isVisible: @escaping @MainActor (MenuContext) -> Bool = { _ in true },
                destructive: Bool = false, quick: Bool = false, submenu: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.location = location
        self.order = order
        self.owner = owner
        self.command = command
        self.params = params
        self.isVisible = isVisible
        self.destructive = destructive
        self.quick = quick
        self.submenu = submenu
    }
}

// MARK: - Panels, settings pages, inspectors

public enum PanelPlacement: String, Codable, CaseIterable {
    /// A tab in the document sidebar (Pages, Outline, Audio, Boards, Search, Layers…).
    case sidebarTab
    /// Draggable floating panel (AI chat, timer, plugin panels).
    case floating
    case sheet
    /// Library sidebar section (Documents, Favorites, Shared, Trash, Gallery…).
    case libraryTab
    case fullScreen
}

public struct PanelContext {
    public var app: NibApp
    public var session: EditorSession?
    public var navigator: SceneNavigator?
    public var dismiss: @MainActor () -> Void

    public init(app: NibApp, session: EditorSession?, navigator: SceneNavigator?, dismiss: @escaping @MainActor () -> Void) {
        self.app = app
        self.session = session
        self.navigator = navigator
        self.dismiss = dismiss
    }
}

public struct PanelDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var placement: PanelPlacement
    public var order: Int
    public var owner: String
    /// nil = any (library tabs ignore it).
    public var docKinds: Set<DocumentKind>?
    public var makeView: @MainActor (PanelContext) -> AnyView

    public init(id: String, title: String, icon: String, placement: PanelPlacement, order: Int, owner: String,
                docKinds: Set<DocumentKind>? = nil, makeView: @escaping @MainActor (PanelContext) -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.placement = placement
        self.order = order
        self.owner = owner
        self.docKinds = docKinds
        self.makeView = makeView
    }
}

public enum SettingsSection: String, Codable, CaseIterable {
    case general, editing, stylus, writing, ai, sync, plugins, bridge, advanced, about
}

public struct SettingsPageDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var section: SettingsSection
    public var order: Int
    public var owner: String
    public var makeView: @MainActor (NibApp) -> AnyView

    public init(id: String, title: String, icon: String, section: SettingsSection, order: Int, owner: String,
                makeView: @escaping @MainActor (NibApp) -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.section = section
        self.order = order
        self.owner = owner
        self.makeView = makeView
    }
}

public struct InspectorContext {
    public var app: NibApp
    public var session: EditorSession
    public var doc: DocumentID
    public var page: PageID
    public var items: [Item]

    public init(app: NibApp, session: EditorSession, doc: DocumentID, page: PageID, items: [Item]) {
        self.app = app
        self.session = session
        self.doc = doc
        self.page = page
        self.items = items
    }
}

/// Style editor shown for a selection of certain item kinds (text formatting, shape style, image crop…).
public struct InspectorDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var itemKinds: Set<ItemKind>
    /// Further restricts to these `Item.drawKey`s (custom item types: "custom.<owner>.<type>"); nil = any.
    public var drawKeys: Set<String>?
    public var order: Int
    public var owner: String
    public var makeView: @MainActor (InspectorContext) -> AnyView

    public init(id: String, title: String, icon: String, itemKinds: Set<ItemKind>, order: Int, owner: String,
                drawKeys: Set<String>? = nil, makeView: @escaping @MainActor (InspectorContext) -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.itemKinds = itemKinds
        self.drawKeys = drawKeys
        self.order = order
        self.owner = owner
        self.makeView = makeView
    }
}

/// Contextual options bar for the active tool (presets, colors, sizes). Registered under the tool id; takes
/// precedence over `ToolbarItemDescriptor.activeToolMenu` so one feature can serve several tools.
public struct ToolMenuDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var makeView: @MainActor (EditorSession) -> AnyView

    public init(tool: String, owner: String, order: Int = 0, makeView: @escaping @MainActor (EditorSession) -> AnyView) {
        self.id = tool
        self.order = order
        self.owner = owner
        self.makeView = makeView
    }
}

public struct BlockViewContext {
    public var app: NibApp
    public var session: EditorSession
    public var doc: DocumentID
    public var block: TextBlock
    /// Call when the view's preferred height changes.
    public var heightChanged: @MainActor (CGFloat) -> Void

    public init(app: NibApp, session: EditorSession, doc: DocumentID, block: TextBlock,
                heightChanged: @escaping @MainActor (CGFloat) -> Void) {
        self.app = app
        self.session = session
        self.doc = doc
        self.block = block
        self.heightChanged = heightChanged
    }
}

/// Renders one Text Document block kind that the text document editor does not render itself (e.g. tables).
/// Custom blocks without a view are drawn by the editor from `CustomBlock.display`.
public struct BlockViewDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var make: @MainActor (BlockViewContext) -> UIView

    public init(kind: BlockKind, owner: String, order: Int = 0, make: @escaping @MainActor (BlockViewContext) -> UIView) {
        self.id = kind.rawValue
        self.order = order
        self.owner = owner
        self.make = make
    }

    /// A view for one custom block type (id "custom.<owner>.<type>").
    public init(customType: String, owner: String, order: Int = 0, make: @escaping @MainActor (BlockViewContext) -> UIView) {
        self.id = "custom." + customType
        self.order = order
        self.owner = owner
        self.make = make
    }
}

/// Builds a plugin's HTML panel (Plugin Panels feature; shared via `ServiceKeys.pluginPanels`).
@MainActor
public protocol PluginPanelFactory: AnyObject {
    func makePanel(manifest: PluginManifest, folder: URL, entry: String, context: PanelContext) -> AnyView
}

// MARK: - Canvas tools and document editors

public struct CanvasToolDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    public var make: @MainActor () -> CanvasTool

    public init(id: String, title: String, order: Int = 0, owner: String, make: @escaping @MainActor () -> CanvasTool) {
        self.id = id
        self.title = title
        self.order = order
        self.owner = owner
        self.make = make
    }
}

/// Editor for one document kind (id = DocumentKind raw value). The view controller must adopt `DocumentEditing`.
public struct DocumentEditorDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var make: @MainActor (DocumentID, EditorSession, NibApp) -> UIViewController

    public init(kind: DocumentKind, owner: String, order: Int = 0,
                make: @escaping @MainActor (DocumentID, EditorSession, NibApp) -> UIViewController) {
        self.id = kind.rawValue
        self.order = order
        self.owner = owner
        self.make = make
    }
}

// MARK: - Shell

public enum OpenMode { case replace, newTab, newWindow }

/// One per window scene (implemented by the app shell's root view controller).
@MainActor
public protocol SceneNavigator: AnyObject {
    var session: EditorSession { get }
    /// Open tabs, in order.
    var openDocuments: [DocumentID] { get }
    var activeDocument: DocumentID? { get }
    var rootViewController: UIViewController? { get }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode)
    func closeDocument(_ doc: DocumentID)
    func showLibrary(folder: FolderID?)
    func showSettings(page: String?)
    func presentModal(_ viewController: UIViewController)
}

/// Window lifecycle hooks (Tabs & Windows feature).
@MainActor
public protocol SceneHooks: AnyObject {
    func sceneDidConnect(_ scene: UIWindowScene, options: UIScene.ConnectionOptions, navigator: SceneNavigator)
    func restorationActivity(_ navigator: SceneNavigator) -> NSUserActivity?
    /// Tab strip shown above the document chrome (nil = none).
    func makeTabBar(_ navigator: SceneNavigator) -> UIView?
}

/// Screen factories filled by features. The shell falls back to minimal built-in screens when nil.
@MainActor
public final class ScreenRegistry {
    public var libraryRoot: (@MainActor (NibApp, SceneNavigator) -> UIViewController)?
    /// Wraps an editor view controller with the document chrome (nav bar, toolbar, sidebar, panels).
    public var documentContainer: (@MainActor (UIViewController, DocumentID, NibApp, SceneNavigator) -> UIViewController)?
    public var settingsRoot: (@MainActor (NibApp, SceneNavigator) -> UIViewController)?
    /// Returns nil when onboarding is complete.
    public var onboarding: (@MainActor (NibApp, SceneNavigator) -> UIViewController?)?
    /// The document toolbar view (Toolbar feature); embedded by the document chrome.
    public var toolbar: (@MainActor (EditorSession, NibApp) -> UIView)?

    public init() {}
}

@MainActor
public final class UIRegistries {
    public let toolbar = Registry<ToolbarItemDescriptor>()
    public let menus = Registry<MenuItemDescriptor>()
    public let panels = Registry<PanelDescriptor>()
    public let settingsPages = Registry<SettingsPageDescriptor>()
    public let inspectors = Registry<InspectorDescriptor>()
    public let canvasTools = Registry<CanvasToolDescriptor>()
    public let editors = Registry<DocumentEditorDescriptor>()
    public let toolMenus = Registry<ToolMenuDescriptor>()
    public let blockViews = Registry<BlockViewDescriptor>()
    /// Persistent canvas overlays and touch targets that are not the active tool (see `CanvasAttachment`).
    public let canvasAttachments = Registry<CanvasAttachmentDescriptor>()
    public let screens: ScreenRegistry
    public var sceneHooks: SceneHooks?
    public var pencilHandler: PencilEventHandler?
    /// Root view controller for an external display scene (Presentation feature); nil = system mirroring.
    public var externalDisplay: (@MainActor (UIWindowScene) -> UIViewController)?
    /// Awaited before a document opens (Password Lock feature); false cancels the open.
    public var openGate: (@MainActor (DocumentID) async -> Bool)?
    /// Navigator of the most recently active window.
    public weak var activeNavigator: SceneNavigator?

    public init() {
        screens = ScreenRegistry()
    }

    public func menuItems(_ location: MenuLocation, _ context: MenuContext) -> [MenuItemDescriptor] {
        menus.all.filter { $0.location == location && $0.isVisible(context) }
    }

    public func toolbarItems(for kind: DocumentKind) -> [ToolbarItemDescriptor] {
        toolbar.all.filter { $0.docKinds.contains(kind) }
    }
}
```

### `NibKit/Sources/NibContracts/UI/NibApp.swift`

```swift
import Foundation
import UIKit
import BackgroundTasks

/// Every module (feature, engine, plugin host) exposes exactly one public type conforming to this,
/// named `<ModuleName>Feature`, e.g. `FeatPenFeature`. The app shell registers them all at launch.
@MainActor
public protocol NibFeature {
    /// Stable id, e.g. "pen". Used as `owner` of everything the feature registers.
    static var id: String { get }
    /// Register commands, services, drawers, templates, toolbar items, menus, panels, settings pages.
    /// Must be fast and must not resolve services or touch documents.
    static func register(_ app: NibApp)
    /// Called once after every feature registered (start watchers, restore state, load plugins).
    static func start(_ app: NibApp) async
}

@MainActor
public extension NibFeature {
    static func start(_ app: NibApp) async {}
}

/// The composition root: one per process, created by the app shell.
@MainActor
public final class NibApp {
    public private(set) static var shared: NibApp?
    /// True inside package tests (set by `Harness`): no app bundle, Info.plist or entitlements. Features must then
    /// skip system singletons that crash or prompt there — UNUserNotificationCenter, BGTaskScheduler, microphone /
    /// camera / Speech / EventKit / Photos authorization, live WKWebView — and throw `unavailable` instead.
    public static var isHostlessTest = false

    public let events: EventBus
    public let clock: HLCClock
    public let settings: SettingsStore
    public let workspace: Workspace
    public let commands: CommandRegistry
    public let gateway: Gateway
    public let services: NibServices
    public let bus: CommandBus
    public let content: ContentRegistries
    public let ui: UIRegistries
    public private(set) var featureIDs: [String] = []

    public init(persistence: DocumentPersistence = InMemoryPersistence(), defaults: UserDefaults = .standard,
                deviceID: UInt32 = DeviceIdentity.current, makeShared: Bool = true) {
        let events = EventBus()
        let clock = HLCClock(device: deviceID)
        let settings = SettingsStore(defaults: defaults)
        let workspace = Workspace(clock: clock, persistence: persistence, events: events)
        let commands = CommandRegistry()
        let gateway = Gateway()
        let services = NibServices(settings: settings)
        self.events = events
        self.clock = clock
        self.settings = settings
        self.workspace = workspace
        self.commands = commands
        self.gateway = gateway
        self.services = services
        self.bus = CommandBus(registry: commands, workspace: workspace, gateway: gateway, services: services, events: events)
        self.content = ContentRegistries()
        self.ui = UIRegistries()
        services.sessions.events = events
        CoreCommands.register(commands)
        NibSettings.declareAll(settings)
        if makeShared { NibApp.shared = self }
    }

    /// Registers features in order. Commands a feature registers with owner "builtin" are stamped with its id.
    public func register(_ features: [NibFeature.Type]) {
        for f in features {
            commands.defaultOwner = f.id
            f.register(self)
            commands.defaultOwner = nil
            featureIDs.append(f.id)
        }
    }

    /// Asks iOS to run the registered background task `id` (see `BackgroundTaskDescriptor`) no earlier than
    /// `earliestIn` seconds from now. The ONLY way features schedule BGTaskScheduler work; no-op in hostless tests.
    public func scheduleBackgroundTask(_ id: String, earliestIn: TimeInterval) {
        guard !NibApp.isHostlessTest, let d = content.backgroundTasks.get(id) else { return }
        let request: BGTaskRequest
        switch d.kind {
        case .refresh: request = BGAppRefreshTaskRequest(identifier: id)
        case .processing: request = BGProcessingTaskRequest(identifier: id)
        }
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestIn)
        try? BGTaskScheduler.shared.submit(request)
    }

    public func start(_ features: [NibFeature.Type]) async {
        for f in features { await f.start(self) }
    }

    /// Runs a command as the user from UI code (menus, buttons); errors are reported to the user by the shell.
    public func perform(_ command: String, _ params: JSONValue = [:], session: EditorSession? = nil) {
        Task { @MainActor in
            do {
                try await self.bus.execute(command, params, session: session ?? self.services.sessions.active)
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: self,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
            }
        }
    }
}

public extension Notification.Name {
    /// userInfo: ["command": String, "error": NibError]. The shell shows a toast.
    static let nibCommandFailed = Notification.Name("NibCommandFailed")
}

/// Crash-loop protection: if two launches in a row die before `endLaunch`, the next launch is in safe mode
/// (plugins are not started, `SafeMode.disabledFeatures` are skipped).
public enum SafeMode {
    private static let crashKey = "nib.safemode.pendingLaunches"
    private static let disabledKey = "nib.safemode.disabledFeatures"

    public static var isActive: Bool { UserDefaults.standard.integer(forKey: crashKey) >= 2 }

    public static var disabledFeatures: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledKey) }
    }

    public static func beginLaunch() {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: crashKey) + 1, forKey: crashKey)
    }

    public static func endLaunch() {
        UserDefaults.standard.set(0, forKey: crashKey)
    }
}
```

### `NibKit/Sources/NibContracts/UI/Drawing.swift`

```swift
import UIKit

// Shared drawing used by the renderer (F004), export (F066), template thumbnails (F045), custom items, custom
// blocks and plugin decorations — so nobody re-implements it. Pure and thread-safe (render threads).

public extension DisplayList {
    /// Draws the ops into `cg` (1 unit = 1 page point, y down), offset by `origin` (a custom item's or block's
    /// top-left; `.zero` for templates). `image` ops read their asset from `assets` in document `doc`.
    func draw(in cg: CGContext, origin: Point = .zero, assets: AssetStore? = nil, doc: DocumentID? = nil) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: CGFloat(origin.x), y: CGFloat(origin.y))
        for op in ops { DisplayList.draw(op, in: cg, assets: assets, doc: doc) }
    }

    private static func draw(_ op: DisplayOp, in cg: CGContext, assets: AssetStore?, doc: DocumentID?) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setLineWidth(CGFloat(op.width ?? 1))
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        if let dash = op.dash, !dash.isEmpty { cg.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) }) }
        if let s = op.stroke { cg.setStrokeColor(s.cgColor) }
        if let f = op.fill { cg.setFillColor(f.cgColor) }
        let r = op.rect?.cg ?? .zero
        func paint(_ path: CGPath, closed: Bool) {
            if closed && op.fill != nil {
                cg.addPath(path)
                cg.fillPath()
            }
            if op.stroke != nil {
                cg.addPath(path)
                cg.strokePath()
            }
        }
        switch op.op {
        case .rect:
            let radius = CGFloat(op.radius ?? 0)
            paint(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2),
                         transform: nil), closed: true)
        case .ellipse:
            paint(CGPath(ellipseIn: r, transform: nil), closed: true)
        case .line, .polyline, .polygon:
            let pts = (op.points ?? []).map { $0.cg }
            guard pts.count >= 2 else { return }
            let path = CGMutablePath()
            path.addLines(between: pts)
            if op.op == .polygon { path.closeSubpath() }
            paint(path, closed: op.op == .polygon)
        case .text:
            guard let text = op.text else { return }
            let size = CGFloat(op.fontSize ?? 14)
            let font = op.fontName.flatMap { UIFont(name: $0, size: size) } ?? UIFont.systemFont(ofSize: size)
            UIGraphicsPushContext(cg)
            (text as NSString).draw(in: r, withAttributes: [.font: font,
                                                             .foregroundColor: (op.stroke ?? op.fill ?? .black).uiColor])
            UIGraphicsPopContext()
        case .image:
            guard let asset = op.asset, let doc = doc, let data = try? assets?.data(asset, doc: doc),
                  let image = UIImage(data: data)?.cgImage else { return }
            cg.translateBy(x: r.minX, y: r.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(image, in: CGRect(origin: .zero, size: r.size))
        case .hlines, .vlines:
            let step = CGFloat(max(op.spacing ?? 24, 1))
            let path = CGMutablePath()
            if op.op == .hlines {
                var y = r.minY + step
                while y <= r.maxY {
                    path.move(to: CGPoint(x: r.minX, y: y))
                    path.addLine(to: CGPoint(x: r.maxX, y: y))
                    y += step
                }
            } else {
                var x = r.minX + step
                while x <= r.maxX {
                    path.move(to: CGPoint(x: x, y: r.minY))
                    path.addLine(to: CGPoint(x: x, y: r.maxY))
                    x += step
                }
            }
            if op.stroke != nil {
                cg.addPath(path)
                cg.strokePath()
            }
        case .dots:
            let step = CGFloat(max(op.spacing ?? 24, 1))
            let radius = CGFloat(op.radius ?? 1)
            if op.fill == nil, let s = op.stroke { cg.setFillColor(s.cgColor) }
            var y = r.minY + step
            while y <= r.maxY {
                var x = r.minX + step
                while x <= r.maxX {
                    cg.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
                    x += step
                }
                y += step
            }
        }
    }
}

/// Variable-width outline of a stroke as one closed polygon (left edge, round end cap, right edge reversed, round
/// start cap) built from each point's rendered width. Used for vector PDF export (F066), dashed strokes (F004) and
/// SVG. Synthetic strokes are prepared first (`InkModel.prepare`), so the outline matches what PencilKit draws.
public enum InkOutline {
    public static func polygon(_ stroke: Stroke, capSegments: Int = 6) -> [Point] {
        var s = stroke
        InkModel.prepare(&s)
        var raw = s.points
        InkModel.fillSizes(&raw, style: s.style)
        var p: [StrokePoint] = []
        for q in raw where p.last.map({ $0.x != q.x || $0.y != q.y }) ?? true { p.append(q) }
        guard let first = p.first else { return [] }
        if p.count == 1 { return cap(first.location, offset: Point(Double(max(first.width, 0.1)) / 2, 0), steps: 12, full: true) }
        var left: [Point] = []
        var right: [Point] = []
        var normals: [Point] = []
        for i in p.indices {
            let a = p[max(i - 1, 0)].location
            let b = p[min(i + 1, p.count - 1)].location
            let len = max(a.distance(to: b), 1e-9)
            let n = Point(-(b.y - a.y) / len, (b.x - a.x) / len)
            let r = Double(max(p[i].width, 0.1)) / 2
            let c = p[i].location
            left.append(c + n * r)
            right.append(c - n * r)
            normals.append(n * r)
        }
        let endCap = cap(p[p.count - 1].location, offset: normals[normals.count - 1], steps: capSegments, full: false)
        let startCap = cap(p[0].location, offset: normals[0] * -1, steps: capSegments, full: false)
        return left + endCap + right.reversed() + startCap
    }

    public static func path(_ stroke: Stroke) -> CGPath {
        let pts = polygon(stroke)
        let path = CGMutablePath()
        guard pts.count > 2 else { return path }
        path.addLines(between: pts.map { $0.cg })
        path.closeSubpath()
        return path
    }

    /// Points strictly between `center + offset` and `center - offset`, sweeping clockwise on screen (a full
    /// circle when `full`).
    static func cap(_ center: Point, offset: Point, steps: Int, full: Bool) -> [Point] {
        let n = max(steps, 2)
        let sweep = full ? 2 * Double.pi : Double.pi
        return (1..<(full ? n + 1 : n)).map { k in
            let th = -sweep * Double(k) / Double(n)
            return Point(center.x + offset.x * cos(th) - offset.y * sin(th), center.y + offset.x * sin(th) + offset.y * cos(th))
        }
    }
}
```

### `NibKit/Sources/NibTesting/TestHarness.swift`

```swift
import Foundation
import UIKit
import NibContracts

/// Fixed ids used by command `examples` and tests. Every record kind exists, so every `.edit` example can target a
/// real record:
/// - FIXTUREDOC01 notebook — FIXTUREPG001 (A4 ruled) holds one item of EVERY kind (stroke, shape, text, sticky, tape,
///   connector shape→sticky, comment, math, image, custom); FIXTUREPG002 is empty; FIXTUREPG003's background is a
///   one-page PDF asset. Outline entry FIXTUREOUT01; audio clip FIXTUREAUD01 with a two-line transcript.
/// - FIXTUREDOC02 text document — heading FIXTUREBLK01, paragraph FIXTUREBLK02 (block comment FIXTURECMB01),
///   2×2 table FIXTUREBLK03.
/// - FIXTUREDOC03 study set — cards FIXTURECRD01 (text/text) and FIXTURECRD02 (text/image, with SRS state).
/// - FIXTUREDOC04 whiteboard — one infinite board FIXTUREBRD01 holding shape FIXTUREBSH01.
/// Every document also holds the assets `pngAsset` and `pdfAsset`.
public enum Fixtures {
    public static let docID: DocumentID = "FIXTUREDOC01"
    public static let textDocID: DocumentID = "FIXTUREDOC02"
    public static let studySetID: DocumentID = "FIXTUREDOC03"
    public static let whiteboardID: DocumentID = "FIXTUREDOC04"
    public static let allDocuments: [DocumentID] = [docID, textDocID, studySetID, whiteboardID]

    public static let page1: PageID = "FIXTUREPG001"
    public static let page2: PageID = "FIXTUREPG002"
    public static let pdfPage: PageID = "FIXTUREPG003"
    public static let boardID: PageID = "FIXTUREBRD01"

    public static let strokeID: ElementID = "FIXTURESTK01"
    public static let shapeID: ElementID = "FIXTURESHP01"
    public static let textID: ElementID = "FIXTURETXT01"
    public static let stickyID: ElementID = "FIXTURESTY01"
    public static let tapeID: ElementID = "FIXTURETAP01"
    public static let connectorID: ElementID = "FIXTURECON01"
    public static let commentID: ElementID = "FIXTURECMT01"
    public static let commentMessageID: NibID = "FIXTUREMSG01"
    public static let mathID: ElementID = "FIXTUREMTH01"
    public static let imageID: ElementID = "FIXTUREIMG01"
    public static let customID: ElementID = "FIXTURECUS01"
    public static let boardShapeID: ElementID = "FIXTUREBSH01"

    public static let outlineID: NibID = "FIXTUREOUT01"
    public static let audioID: NibID = "FIXTUREAUD01"
    public static let headingBlockID: NibID = "FIXTUREBLK01"
    public static let paragraphBlockID: NibID = "FIXTUREBLK02"
    public static let tableBlockID: NibID = "FIXTUREBLK03"
    public static let blockCommentID: NibID = "FIXTURECMB01"
    public static let card1: NibID = "FIXTURECRD01"
    public static let card2: NibID = "FIXTURECRD02"
    public static let folderID: FolderID = "FIXTUREFLD01"

    /// Installed in every fixture document under these fixed names.
    public static let pngAsset = AssetRef("fixture-image.png")
    public static let pdfAsset = AssetRef("fixture-page.pdf")
    /// A 1×1 PNG.
    public static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// A one-page A4 PDF with one line of text.
    public static func pdfData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89)).pdfData { ctx in
            ctx.beginPage()
            ("Fixture PDF text" as NSString).draw(at: CGPoint(x: 72, y: 72),
                                                  withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
    }

    static let base = Rev(wallMs: 1, counter: 0, device: 0)

    static func stamped(_ items: [Item]) -> [Item] {
        items.map { i -> Item in
            var i = i
            i.rev = base
            return i
        }
    }

    /// The notebook FIXTUREDOC01.
    public static func sampleContent() -> (DocumentContent, [PageID: [Item]]) {
        var meta = DocumentMeta(id: docID, kind: .notebook, createdAt: 1_700_000_000)
        meta.rev = base
        var p1 = PageRecord(id: page1, order: "V", size: .a4, background: .ofTemplate("builtin.ruled"))
        var p2 = PageRecord(id: page2, order: "k", size: .a4, background: .ofTemplate("builtin.ruled"))
        var p3 = PageRecord(id: pdfPage, order: "t", size: .a4, background: .ofPDF(pdfAsset, page: 0))
        p1.rev = base
        p2.rev = base
        p3.rev = base
        var outline = OutlineEntry(id: outlineID, title: "Fixture section", page: page1, order: "V")
        outline.rev = base
        var clip = AudioClip(id: audioID, name: "Fixture recording", file: "audio/FIXTUREAUD01.caf",
                             start: 1_700_000_000, duration: 600, page: page1)
        clip.transcriptFile = "audio/FIXTUREAUD01.transcript"
        clip.rev = base
        let content = DocumentContent(meta: meta, pages: [p1, p2, p3], outline: [outline], audio: [clip])

        let z = FractionalIndex.sequence(after: nil, count: 10)
        let pts = (0..<20).map { i in StrokePoint(x: Float(72 + i * 4), y: Float(120 + (i % 5)), t: Float(i) * 0.01) }
        let tapePts = [StrokePoint(x: 80, y: 600, width: 18, height: 18), StrokePoint(x: 260, y: 600, width: 18, height: 18)]
        let box = DisplayList(ops: [DisplayOp(op: .rect, rect: Rect(x: 0, y: 0, width: 100, height: 50), stroke: .black)])
        let items: [Item] = [
            Item(id: strokeID, kind: .stroke, z: z[0], stroke: Stroke(style: .defaultPen, points: pts, t0: 1_700_000_100)),
            Item(id: shapeID, kind: .shape, z: z[1],
                 shape: ShapeItem(shape: .rectangle, frame: Frame(x: 100, y: 200, w: 160, h: 90))),
            Item(id: textID, kind: .text, z: z[2],
                 text: TextBoxItem(frame: Frame(x: 72, y: 400, w: 300, h: 40), text: RichText(plain: "Hello Nib"))),
            Item(id: stickyID, kind: .sticky, z: z[3],
                 sticky: StickyItem(frame: Frame(x: 400, y: 120, w: 140, h: 140), text: RichText(plain: "Remember"))),
            Item(id: tapeID, kind: .stroke, z: z[4], stroke: Stroke(style: .defaultTape, points: tapePts, t0: 1_700_000_200)),
            Item(id: connectorID, kind: .connector, z: z[5],
                 connector: ConnectorItem(from: ConnectorEnd(point: Point(260, 245), item: shapeID, side: 1, t: 0.5),
                                          to: ConnectorEnd(point: Point(400, 190), item: stickyID, side: 3, t: 0.5))),
            Item(id: commentID, kind: .comment, z: z[6],
                 comment: CommentItem(anchor: Point(560, 400), messages: [
                     CommentMessage(id: commentMessageID, author: "Fixture", text: "Check this", at: 1_700_000_300)])),
            Item(id: mathID, kind: .math, z: z[7],
                 math: MathItem(frame: Frame(x: 72, y: 480, w: 120, h: 40), latex: ["\\frac{a}{b}"])),
            Item(id: imageID, kind: .image, z: z[8],
                 image: ImageItem(frame: Frame(x: 320, y: 480, w: 64, h: 64), asset: pngAsset)),
            Item(id: customID, kind: .custom, z: z[9],
                 custom: CustomItem(owner: "nib.fixture", type: "box", frame: Frame(x: 72, y: 700, w: 100, h: 50),
                                    data: ["title": "Fixture box"], display: box))
        ]
        return (content, [page1: stamped(items), page2: [], pdfPage: []])
    }

    /// Every fixture document with its page items and library title.
    public static func documents() -> [(content: DocumentContent, items: [PageID: [Item]], title: String)] {
        let (notebook, notebookItems) = sampleContent()

        var textMeta = DocumentMeta(id: textDocID, kind: .textDocument, createdAt: 1_700_000_000)
        textMeta.rev = base
        var heading = TextBlock(id: headingBlockID, kind: .heading1, text: RichText(plain: "Fixture Text"), order: "V")
        var paragraph = TextBlock(id: paragraphBlockID, kind: .paragraph, text: RichText(plain: "Hello blocks"), order: "k")
        paragraph.comments = [BlockComment(id: blockCommentID, author: "Fixture", text: "Nice", at: 1_700_000_300,
                                           rangeStart: 0, rangeLength: 5)]
        var table = TextBlock(id: tableBlockID, kind: .table, order: "t")
        table.table = TableData(rows: [[TableCell(text: RichText(plain: "A1")), TableCell(text: RichText(plain: "B1"))],
                                       [TableCell(text: RichText(plain: "A2")), TableCell(text: RichText(plain: "B2"))]])
        heading.rev = base
        paragraph.rev = base
        table.rev = base
        let textDoc = DocumentContent(meta: textMeta, blocks: [heading, paragraph, table])

        var studyMeta = DocumentMeta(id: studySetID, kind: .studySet, createdAt: 1_700_000_000)
        studyMeta.rev = base
        var c1 = StudyCard(id: card1, front: CardFace(text: RichText(plain: "Term")),
                           back: CardFace(text: RichText(plain: "Definition")), order: "V")
        var c2 = StudyCard(id: card2, front: CardFace(text: RichText(plain: "Picture")),
                           back: CardFace(kind: .image, asset: pngAsset), order: "k")
        c2.srs = SRSState(due: 1_700_086_400, interval: 1, reps: 1)
        c1.rev = base
        c2.rev = base
        let studySet = DocumentContent(meta: studyMeta, cards: [c1, c2])

        var boardMeta = DocumentMeta(id: whiteboardID, kind: .whiteboard, createdAt: 1_700_000_000)
        boardMeta.rev = base
        var board = PageRecord(id: boardID, order: "V", size: nil, background: .ofTemplate("builtin.whiteboardDots"),
                               title: "Board 1")
        board.rev = base
        let whiteboard = DocumentContent(meta: boardMeta, pages: [board])
        let boardItems = stamped([Item(id: boardShapeID, kind: .shape, z: "V",
                                       shape: ShapeItem(shape: .ellipse, frame: Frame(x: 0, y: 0, w: 200, h: 120)))])

        return [(notebook, notebookItems, "Fixture Notebook"),
                (textDoc, [:], "Fixture Text Document"),
                (studySet, [:], "Fixture Study Set"),
                (whiteboard, [boardID: boardItems], "Fixture Whiteboard")]
    }

    @MainActor
    public static func install(into persistence: InMemoryPersistence, library: InMemoryLibrary, assets: InMemoryAssetStore) {
        _ = try? library.createFolder(title: "Fixtures", in: nil, style: nil, id: folderID)
        let pdf = pdfData()
        for doc in documents() {
            let id = doc.content.meta.id
            _ = try? library.createDocument(doc.content, title: doc.title, in: folderID)
            for (page, list) in doc.items { persistence.pageItems[id, default: [:]][page] = list }
            assets.install(pngData, as: pngAsset, doc: id)
            assets.install(pdf, as: pdfAsset, doc: id)
        }
        let transcript = [TranscriptSegment(index: 0, start: 0, duration: 4, text: "Welcome to the fixture lecture."),
                          TranscriptSegment(index: 1, start: 4, duration: 5, text: "Velocity is displacement over time.")]
        if let url = try? persistence.fileURL(docID, relativePath: "audio/FIXTUREAUD01.transcript.json"),
           let data = try? JSONEncoder().encode(transcript) {
            try? data.write(to: url)
        }
    }
}

/// In-memory `LibraryService` for tests (and the app shell when no Library Store feature is present).
@MainActor
public final class InMemoryLibrary: LibraryService {
    public let rootURL: URL
    public var metadataURL: URL { rootURL.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true) }
    public private(set) var nodes: [NibID: LibraryNode] = [:]
    private let persistence: InMemoryPersistence
    private let locator: PackageLocator?

    /// `locator` (usually `app.services.packages`) is kept in sync, like the real Library Store does.
    public init(persistence: InMemoryPersistence, locator: PackageLocator? = nil) {
        self.persistence = persistence
        self.rootURL = persistence.root
        self.locator = locator
    }

    public func allNodes() -> [LibraryNode] {
        nodes.values.filter { $0.trashedAt == nil }.sorted { $0.title < $1.title }
    }

    public func node(_ id: NibID) -> LibraryNode? { nodes[id] }

    public func children(of folder: FolderID?) -> [LibraryNode] {
        allNodes().filter { $0.parent == folder }
    }

    public func packageURL(_ doc: DocumentID) -> URL? {
        nodes[doc] == nil ? nil : rootURL.appendingPathComponent(doc.raw + "." + NibFormat.packageExtension, isDirectory: true)
    }

    public func createDocument(_ content: DocumentContent, title: String, in folder: FolderID?) throws -> DocumentID {
        let id = content.meta.id
        persistence.heads[id] = content
        let now = Date().timeIntervalSince1970
        nodes[id] = LibraryNode(id: id, kind: .document, title: title, path: title, parent: folder,
                                documentKind: content.meta.kind, modified: now, created: now,
                                pageCount: content.livePages.count)
        locator?.set(packageURL(id), for: id)
        return id
    }

    public func createFolder(title: String, in parent: FolderID?, style: FolderStyle?) throws -> FolderID {
        try createFolder(title: title, in: parent, style: style, id: NibID.make())
    }

    public func createFolder(title: String, in parent: FolderID?, style: FolderStyle?, id: FolderID) throws -> FolderID {
        let now = Date().timeIntervalSince1970
        nodes[id] = LibraryNode(id: id, kind: .folder, title: title, path: title, parent: parent, modified: now,
                                created: now, style: style)
        return id
    }

    public func rename(_ id: NibID, to title: String) throws {
        guard var n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        n.title = title
        nodes[id] = n
    }

    public func move(_ id: NibID, to folder: FolderID?) throws {
        guard var n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        n.parent = folder
        nodes[id] = n
    }

    public func duplicate(_ id: NibID) throws -> NibID {
        guard let n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        guard n.kind == .document, var content = persistence.heads[id] else {
            return try createFolder(title: n.title + " copy", in: n.parent, style: n.style)
        }
        let newID = NibID.make()
        content.meta.id = newID
        persistence.pageItems[newID] = persistence.pageItems[id]
        return try createDocument(content, title: n.title + " copy", in: n.parent)
    }

    public func setStyle(_ style: FolderStyle, folder: FolderID) throws {
        guard var n = nodes[folder] else { throw NibError.notFound("folder \(folder)") }
        n.style = style
        n.favorite = style.favorite
        nodes[folder] = n
    }

    public func trash(_ id: NibID) throws {
        guard var n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        n.trashedAt = Date().timeIntervalSince1970
        nodes[id] = n
    }

    public func trashedNodes() -> [LibraryNode] { nodes.values.filter { $0.trashedAt != nil } }

    public func restore(_ id: NibID, to folder: FolderID?) throws {
        guard var n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        n.trashedAt = nil
        if let f = folder { n.parent = f }
        nodes[id] = n
    }

    public func deletePermanently(_ id: NibID) throws {
        nodes[id] = nil
        persistence.heads[id] = nil
        persistence.pageItems[id] = nil
        locator?.set(nil, for: id)
    }

    public func importPackage(at url: URL, into folder: FolderID?) throws -> DocumentID {
        throw NibError.unsupported("package import in InMemoryLibrary")
    }

    public func refresh() {}

    public func setRoot(_ url: URL) throws {
        throw NibError.unsupported("changing the root of InMemoryLibrary")
    }
}

/// Content-addressed assets kept in memory (files are written on demand for `url`).
public final class InMemoryAssetStore: AssetStore {
    private var blobs: [String: Data] = [:]
    private let lock = NSLock()
    private let root: URL

    public init(root: URL) { self.root = root }

    public func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let ref = AssetRef(String(format: "%016llx", h) + "." + ext.lowercased())
        lock.lock()
        blobs[doc.raw + "/" + ref.name] = data
        lock.unlock()
        return ref
    }

    public func url(_ ref: AssetRef, doc: DocumentID) -> URL? {
        guard let data = try? self.data(ref, doc: doc) else { return nil }
        let url = root.appendingPathComponent(doc.raw, isDirectory: true).appendingPathComponent("assets/" + ref.name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        return url
    }

    public func data(_ ref: AssetRef, doc: DocumentID) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let d = blobs[doc.raw + "/" + ref.name] else { throw NibError.notFound("asset \(ref.name)") }
        return d
    }

    /// Stores `data` under a fixed name (fixtures).
    public func install(_ data: Data, as ref: AssetRef, doc: DocumentID) {
        lock.lock()
        blobs[doc.raw + "/" + ref.name] = data
        lock.unlock()
    }

    public func putTemporary(_ data: Data, ext: String) throws -> AssetRef {
        try put(data, ext: ext, doc: NibID("_tmp"))
    }

    public func temporaryURL(_ ref: AssetRef) -> URL? { url(ref, doc: NibID("_tmp")) }
}

/// Confirms (or denies) every request and records it.
@MainActor
public final class AutoConfirm: ConfirmationPresenter {
    public var decision: ConfirmationDecision = .allow
    public private(set) var requests: [ConfirmationRequest] = []
    public init() {}
    public func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        requests.append(request)
        return decision
    }
}

/// A ready-to-use app for tests: in-memory storage and secrets, every fixture document, one session, auto-confirm.
/// Marks the process as a hostless test (`NibApp.isHostlessTest`). Test classes using it must be `@MainActor`.
@MainActor
public final class Harness {
    public let app: NibApp
    public let persistence: InMemoryPersistence
    public let library: InMemoryLibrary
    public let assets: InMemoryAssetStore
    public let session: EditorSession
    public let confirmer: AutoConfirm

    /// `deviceID` lets two-device tests (sync, collaboration) give each app its own HLC device id (e.g. 7 and 8).
    public init(features: [NibFeature.Type] = [], fixtures: Bool = true, deviceID: UInt32 = 7) {
        NibApp.isHostlessTest = true
        if !(Keychain.store is InMemorySecretStore) { Keychain.store = InMemorySecretStore() }
        let persistence = InMemoryPersistence()
        let defaults = UserDefaults(suiteName: "nib.tests." + UUID().uuidString) ?? .standard
        let app = NibApp(persistence: persistence, defaults: defaults, deviceID: deviceID)
        let library = InMemoryLibrary(persistence: persistence, locator: app.services.packages)
        let assets = InMemoryAssetStore(root: persistence.root)
        app.services.library = library
        app.services.assets = assets
        let session = EditorSession()
        app.services.sessions.add(session)
        let confirmer = AutoConfirm()
        app.gateway.presenter = confirmer
        self.app = app
        self.persistence = persistence
        self.library = library
        self.assets = assets
        self.session = session
        self.confirmer = confirmer
        if fixtures {
            Fixtures.install(into: persistence, library: library, assets: assets)
            session.document = Fixtures.docID
            session.page = Fixtures.page1
        }
        app.register(features)
        // Features may install real services in `register`; tests keep the in-memory ones.
        app.workspace.persistence = persistence
        app.services.library = library
        app.services.assets = assets
        app.settings.syncedBackend = nil
    }

    /// Runs a command through the JSON path (validation, permissions, confirmation) and returns its value.
    @discardableResult
    public func run(_ command: String, _ params: JSONValue = [:], as principal: Principal = .user) async throws -> JSONValue {
        try await app.bus.execute(Invocation(command: command, params: params, principal: principal, session: session)).value
    }

    /// Undo-stack depth of a document.
    public func undoDepth(_ doc: DocumentID) -> Int { app.bus.history.entries(doc).count }

    /// Undo-stack depths of every fixture document.
    public func undoDepths() -> [DocumentID: Int] {
        Dictionary(uniqueKeysWithValues: Fixtures.allDocuments.map { ($0, undoDepth($0)) })
    }

    /// Document state without revisions and tombstones (for before/after comparisons).
    public func snapshot(_ doc: DocumentID = Fixtures.docID) throws -> JSONValue {
        var c = try app.workspace.content(doc)
        c.meta.rev = .zero
        c.pages = c.pages.filter { !$0.deleted }.map { p -> PageRecord in
            var p = p
            p.rev = .zero
            return p
        }.sorted { $0.id < $1.id }
        c.outline = c.outline.filter { !$0.deleted }.map { e -> OutlineEntry in
            var e = e
            e.rev = .zero
            return e
        }.sorted { $0.id < $1.id }
        c.blocks = c.blocks.filter { !$0.deleted }.map { b -> TextBlock in
            var b = b
            b.rev = .zero
            return b
        }.sorted { $0.id < $1.id }
        c.cards = c.cards.filter { !$0.deleted }.map { x -> StudyCard in
            var x = x
            x.rev = .zero
            return x
        }.sorted { $0.id < $1.id }
        c.audio = c.audio.filter { !$0.deleted }.map { a -> AudioClip in
            var a = a
            a.rev = .zero
            return a
        }.sorted { $0.id < $1.id }
        var pages: [String: JSONValue] = [:]
        for p in c.pages {
            let items = try app.workspace.items(doc, page: p.id).map { i -> Item in
                var i = i
                i.rev = .zero
                i.createdBy = nil
                return i
            }.sorted { $0.id < $1.id }
            pages[p.id.raw] = try JSONValue.from(items)
        }
        let contentJSON = try JSONValue.from(c)
        return ["content": contentJSON, "items": .object(pages)]
    }

    /// Snapshot of every fixture document.
    public func snapshotAll() throws -> JSONValue {
        var o: [String: JSONValue] = [:]
        for d in Fixtures.allDocuments { o[d.raw] = try snapshot(d) }
        return .object(o)
    }
}

/// Registry-wide checks run in CI (see ConformanceTests). Returns human-readable problems (empty = pass):
/// - descriptor hygiene (id pattern, one-line summary, examples that validate);
/// - every feature command is owned by its feature (not "builtin") and no id is registered twice;
/// - every example of every `.edit` command: undo of every fixture document it touched restores all of them
///   (`undoable: false` commands must instead leave every undo stack unchanged);
/// - `.edit`/`.library` commands that create records and return `ref`/`refs` declare a caller-chosen `id`/`ids`
///   param, and a given `id` is honoured;
/// - every typed setting used while running examples was declared.
/// `unavailable`/`unsupported` results (missing optional features, hostless limits) are skipped.
@MainActor
public enum CommandConformance {
    public static func check(features: [NibFeature.Type], owners: Set<String>? = nil) async -> [String] {
        var problems: [String] = []
        let core = Set(Harness(features: []).app.commands.all().map { $0.id })
        let probe = Harness(features: features)
        var undeclared = Set(probe.app.settings.undeclaredNames)
        for id in probe.app.commands.duplicateIDs {
            problems.append("\(id): registered twice (the later registration replaced the earlier one)")
        }
        let pattern = "^[a-z][a-zA-Z0-9]*(\\.[a-zA-Z0-9]+)+$"
        for d in probe.app.commands.all() where owners.map({ $0.contains(d.owner) }) ?? true {
            if d.owner == "builtin" && !core.contains(d.id) {
                problems.append("\(d.id): owner is 'builtin'; register feature commands inside the feature's register(_:)")
            }
            if d.summary.contains("\n") || d.summary.count > 200 { problems.append("\(d.id): summary must be one line of at most 200 characters") }
            if d.id.range(of: pattern, options: .regularExpression) == nil { problems.append("\(d.id): id must look like namespace.verb") }
            if d.toolName.count > 64 { problems.append("\(d.id): id too long for LLM tool names") }
            if d.examples.isEmpty && d.exposure.contains(.ai) { problems.append("\(d.id): needs at least one example") }
            for ex in d.examples {
                for e in d.params.validate(ex) { problems.append("\(d.id): example \(ex.jsonString()) fails schema: \(e)") }
            }
            // userPresence and sensitive commands (system UI, microphone, networking) are not executed here.
            guard d.effect == .edit || d.effect == .library, !d.userPresence, !d.sensitive, !core.contains(d.id) else { continue }
            for ex in d.examples {
                let h = Harness(features: features)
                do {
                    let before = try h.snapshotAll()
                    let depths = h.undoDepths()
                    let r = try await h.app.bus.execute(Invocation(command: d.id, params: ex, session: h.session))
                    undeclared.formUnion(h.app.settings.undeclaredNames)
                    if !r.changes.created.isEmpty, r.value["ref"] != nil || r.value["refs"] != nil, !declaresID(d) {
                        problems.append("\(d.id): creates records and returns refs but has no caller-chosen `id`/`ids` param")
                    }
                    guard d.effect == .edit else { continue }
                    if d.undoable {
                        for doc in Fixtures.allDocuments where h.undoDepth(doc) > (depths[doc] ?? 0) { h.app.bus.undo(doc) }
                        if try h.snapshotAll() != before {
                            problems.append("\(d.id): undo did not restore the documents for example \(ex.jsonString())")
                        }
                    } else if h.undoDepths() != depths {
                        problems.append("\(d.id): declared undoable: false but added undo entries")
                    }
                } catch let e as NibError where e.code == .unavailable || e.code == .unsupported {
                    continue
                } catch {
                    if d.effect == .edit { problems.append("\(d.id): example \(ex.jsonString()) failed: \(error)") }
                }
            }
            if declaresID(d), let ex = d.examples.first, case .object(var params) = ex {
                params["id"] = "CONFORMID0001"
                let h = Harness(features: features)
                if let r = try? await h.app.bus.execute(Invocation(command: d.id, params: .object(params), session: h.session)),
                   let ref = r.value["ref"]?.stringValue, !ref.hasSuffix("CONFORMID0001") {
                    problems.append("\(d.id): ignores the caller-chosen id (returned \(ref))")
                }
            }
        }
        for name in undeclared.sorted() {
            problems.append("setting '\(name)' is used but never declared (SettingsStore.declare in register)")
        }
        return problems
    }

    static func declaresID(_ d: CommandDescriptor) -> Bool {
        if case let .object(properties, _, _) = d.params { return properties["id"] != nil || properties["ids"] != nil }
        return false
    }
}
```

### `NibKit/Sources/NibTesting/Fakes.swift`

```swift
import Foundation
import UIKit
import NibContracts

// Service fakes shared by every feature's tests, so nobody writes their own. Install what you need:
//   let h = Harness(); let ai = FakeAIService(); h.app.services.ai = ai

/// Secrets in memory (hostless tests have no Keychain entitlement). `Harness` installs one as `Keychain.store`.
public final class InMemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func set(_ data: Data?, service: String, account: String) -> Bool {
        lock.lock()
        values[service + "/" + account] = data
        lock.unlock()
        return true
    }

    public func get(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[service + "/" + account]
    }
}

/// Renders blank images of the requested size; `marks` is returned verbatim when requested.
public final class FakeRenderer: PageRenderer {
    public var marks: [String: String] = [:]
    public private(set) var requests: [RenderRequest] = []
    public private(set) var invalidations: [(DocumentID, PageID, Rect?)] = []
    public var pageSize = PageSize.a4

    public init() {}

    public func render(_ request: RenderRequest) async throws -> RenderResult {
        requests.append(request)
        let region = request.region ?? Rect(x: 0, y: 0, width: pageSize.width, height: pageSize.height)
        let size = CGSize(width: max(1, region.width * request.scale), height: max(1, region.height * request.scale))
        return RenderResult(image: FakeRenderer.blank(size), region: region, scale: request.scale,
                            marks: request.marks ? marks : [:])
    }

    public func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        FakeRenderer.blank(CGSize(width: maxPixelSize, height: maxPixelSize))
    }

    public func invalidate(doc: DocumentID, page: PageID, rect: Rect?) { invalidations.append((doc, page, rect)) }
    public func purgeCaches() {}

    public static func blank(_ size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.cgImage!
    }
}

/// Returns `script` for every recognition call (set it per test); records calls.
public final class FakeRecognizer: TextRecognizer {
    public var script: [TextRecognition] = []
    public private(set) var strokeCalls = 0
    public private(set) var imageCalls = 0

    public init(_ script: [TextRecognition] = []) { self.script = script }

    public func recognize(strokes: [Item], language: String) async throws -> [TextRecognition] {
        strokeCalls += 1
        return script
    }

    public func recognize(image: CGImage, language: String) async throws -> [TextRecognition] {
        imageCalls += 1
        return script
    }
}

/// Scripted AI: each turn pops the next `responses` entry (else echoes), first running its `toolCalls` through the
/// bus as the request's principal in the turn's undo group (so "one turn = one undo step" is testable).
@MainActor
public final class FakeAIService: AIService {
    public struct Turn {
        public var text: String
        public var toolCalls: [(command: String, params: JSONValue)]
        public init(text: String, toolCalls: [(command: String, params: JSONValue)] = []) {
            self.text = text
            self.toolCalls = toolCalls
        }
    }

    public var isConfigured = true
    public var supportsVision = true
    public var responses: [Turn] = []
    public var transcript: [TranscriptSegment] = []
    public private(set) var requests: [AIRequest] = []
    /// Needed only when turns carry tool calls.
    public weak var bus: CommandBus?
    private var store: [String: [AIMessage]] = [:]

    public init(responses: [Turn] = [], bus: CommandBus? = nil) {
        self.responses = responses
        self.bus = bus
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        requests.append(request)
        let turn = responses.isEmpty ? Turn(text: request.messages.last?.text ?? "") : responses.removeFirst()
        let group = request.group ?? NibID.make().raw
        var changes = ChangeSummary()
        for call in turn.toolCalls {
            guard let bus = bus else { throw NibError.unavailable("FakeAIService.bus") }
            let r = try await bus.execute(Invocation(command: call.command, params: call.params, principal: request.principal,
                                                     group: group, readOnly: request.mode == .ask))
            changes.merge(r.changes)
        }
        let chat = request.chatID ?? "fake-chat"
        store[chat, default: []] += request.messages + [AIMessage(role: "assistant", text: turn.text)]
        return AIResponse(text: turn.text, changes: changes, group: group, chatID: chat)
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let r = try await self.complete(request)
                    continuation.yield(.text(r.text))
                    continuation.yield(.finished(r))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancel(chatID: String) {}
    public func chats(doc: DocumentID?) -> [AIChatSummary] {
        store.keys.sorted().map { AIChatSummary(id: $0, title: $0, doc: doc, updated: 0) }
    }
    public func messages(chatID: String) -> [AIMessage] { store[chatID] ?? [] }
    public func deleteChat(_ chatID: String) { store[chatID] = nil }
    public func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] { transcript }
    public func generateImage(prompt: String) async throws -> Data { Fixtures.pngData }
}

/// Scripted PDF facts keyed by file name (`url.lastPathComponent`).
public final class FakePDFService: PDFService {
    public var pages: [String: Int] = [:]
    public var texts: [String: String] = [:]
    public var linkMap: [String: [PDFLinkInfo]] = [:]
    public var outlines: [String: [PDFOutlineNode]] = [:]

    public init() {}

    public func pageCount(_ url: URL) -> Int { pages[url.lastPathComponent] ?? 1 }
    public func pageSize(_ url: URL, page: Int) -> PageSize? { .a4 }
    public func text(_ url: URL, page: Int) -> String? { texts[url.lastPathComponent] }
    public func textBlocks(_ url: URL, page: Int) -> [TextRecognition] {
        texts[url.lastPathComponent].map { [TextRecognition(text: $0, bbox: Rect(x: 72, y: 72, width: 400, height: 20), source: "pdf")] } ?? []
    }
    public func links(_ url: URL, page: Int) -> [PDFLinkInfo] { linkMap[url.lastPathComponent] ?? [] }
    public func outline(_ url: URL) -> [PDFOutlineNode] { outlines[url.lastPathComponent] ?? [] }
    public func selection(_ url: URL, page: Int, from: Point, to: Point) -> (text: String, rects: [Rect]) {
        (texts[url.lastPathComponent] ?? "", [Rect(x: from.x, y: from.y, width: max(1, to.x - from.x), height: 18)])
    }
}

/// Locks the documents in `locked`; `unlock` succeeds when `unlockSucceeds`.
@MainActor
public final class FakeLockService: LockService {
    public var locked: Set<DocumentID> = []
    public var unlockSucceeds = true

    public init(locked: Set<DocumentID> = []) { self.locked = locked }

    public func isLocked(_ doc: DocumentID) -> Bool { locked.contains(doc) }
    public func unlock(_ doc: DocumentID) async -> Bool {
        if unlockSucceeds { locked.remove(doc) }
        return unlockSucceeds
    }
}

public extension PluginManifest {
    /// Builds a manifest from JSON (the manifest types have no public memberwise inits by design).
    static func fixture(id: String = "dev.test.plugin", permissions: [String] = ["document:read", "document:write"],
                        contributes: JSONValue = [:], entry: String = "main.js") throws -> PluginManifest {
        let json: JSONValue = ["id": .string(id), "name": .string(id), "version": "1.0.0", "api": 1, "entry": .string(entry),
                               "permissions": .array(permissions.map { .string($0) }), "contributes": contributes]
        return try json.decode(PluginManifest.self)
    }
}

/// A view-less canvas for tool, attachment and gesture tests: `pages` stacked top to bottom (`pageSize`, `gap`, page
/// points) and scaled by `zoomScale` into view coordinates. Records what the code under test asked of the canvas.
/// `commitStroke` only records (register a stand-in `ink.addStrokes` if a test needs the real commit path).
@MainActor
public final class FakeCanvasHost: CanvasHost {
    public let app: NibApp
    public let session: EditorSession
    public let documentID: DocumentID
    public var zoomScale: Double = 1
    public var pages: [PageID]
    public var pageSize = PageSize.a4
    public var gap: Double = 20
    public let canvasView: UIView
    public let overlayLayer = CALayer()
    public private(set) var hidden: [PageID: Set<ElementID>] = [:]
    public private(set) var invalidations: [(page: PageID, rect: Rect?)] = []
    public private(set) var committed: [(stroke: Stroke, page: PageID)] = []
    public private(set) var wetStrokeCancels = 0
    public private(set) var liveViews: [ElementID: UIView] = [:]

    public init(app: NibApp, session: EditorSession, doc: DocumentID = Fixtures.docID,
                pages: [PageID] = [Fixtures.page1, Fixtures.page2]) {
        self.app = app
        self.session = session
        self.documentID = doc
        self.pages = pages
        canvasView = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        canvasView.layer.addSublayer(overlayLayer)
    }

    /// The Harness's app and session on the fixture document.
    public convenience init(_ harness: Harness) { self.init(app: harness.app, session: harness.session) }

    public func pageFrame(_ page: PageID) -> CGRect? {
        guard let i = pages.firstIndex(of: page) else { return nil }
        return CGRect(x: 0, y: Double(i) * (pageSize.height + gap) * zoomScale,
                      width: pageSize.width * zoomScale, height: pageSize.height * zoomScale)
    }

    public func viewPoint(_ p: Point, page: PageID) -> CGPoint {
        let o = pageFrame(page)?.origin ?? .zero
        return CGPoint(x: Double(o.x) + p.x * zoomScale, y: Double(o.y) + p.y * zoomScale)
    }

    public func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)? {
        for page in pages {
            if let f = pageFrame(page), f.contains(v) {
                return (page, Point(Double(v.x - f.minX) / zoomScale, Double(v.y - f.minY) / zoomScale))
            }
        }
        return nil
    }

    public func setHidden(_ ids: Set<ElementID>, page: PageID) { hidden[page] = ids.isEmpty ? nil : ids }
    public func invalidate(page: PageID, rect: Rect?) { invalidations.append((page, rect)) }
    public func commitStroke(_ stroke: Stroke, page: PageID) { committed.append((stroke, page)) }
    public func cancelWetStroke() { wetStrokeCancels += 1 }
    public func attachLiveView(_ view: UIView?, item: ElementID, page: PageID) { liveViews[item] = view }
}

/// Collaboration transport inside one process: transports sharing a `Hub` that host/join the same code exchange
/// messages synchronously (two-Harness collaboration tests). `leave()` then `join` simulates suspend and rejoin.
@MainActor
public final class InMemoryCollabTransport: CollabTransport {
    /// Switchboard shared by the transports of one test: code → transports in that session.
    @MainActor
    public final class Hub {
        fileprivate var rooms: [String: [InMemoryCollabTransport]] = [:]
        public init() {}
    }

    public let id = "memory"
    public let hub: Hub
    /// This participant as the other transports see it.
    public private(set) var me: CollabPeer
    public var displayName: String { me.name }
    public var maxPeers = 8
    public var onMessage: ((CollabPeer, Data) -> Void)?
    public var onPeersChanged: (([CollabPeer]) -> Void)?
    /// Every payload this transport sent, in order.
    public private(set) var sent: [Data] = []
    private var code: String?

    public init(hub: Hub, peerID: String = NibID.make().raw) {
        self.hub = hub
        self.me = CollabPeer(id: peerID, name: "")
    }

    private var room: [InMemoryCollabTransport] { code.flatMap { hub.rooms[$0] } ?? [] }
    public var peers: [CollabPeer] { room.filter { $0 !== self }.map(\.me) }

    public func host(code: String, displayName: String) async throws { try enter(code, displayName) }

    public func join(code: String, displayName: String) async throws {
        guard hub.rooms[code]?.isEmpty == false else { throw NibError.notFound("collaboration session \(code)") }
        try enter(code, displayName)
    }

    public func send(_ data: Data, to peers: [CollabPeer]?) throws {
        guard code != nil else { throw NibError.unavailable("collaboration session") }
        sent.append(data)
        for t in room where t !== self && (peers?.contains(t.me) ?? true) { t.onMessage?(me, data) }
    }

    public func leave() {
        guard let c = code else { return }
        hub.rooms[c]?.removeAll { $0 === self }
        code = nil
        for t in hub.rooms[c] ?? [] { t.onPeersChanged?(t.peers) }
    }

    private func enter(_ code: String, _ name: String) throws {
        leave()
        guard (hub.rooms[code]?.count ?? 0) < maxPeers else { throw NibError.unavailable("collaboration session is full") }
        me.name = name
        self.code = code
        hub.rooms[code, default: []].append(self)
        for t in room { t.onPeersChanged?(t.peers) }
    }
}
```

### `NibKit/Tests/NibContractsTests/NibContractsTests.swift`

```swift
import XCTest
import NibContracts
import NibTesting

@MainActor
final class NibContractsTests: XCTestCase {
    func testFractionalIndexOrdering() {
        var keys: [String] = []
        var last: String?
        for _ in 0..<200 {
            let k = FractionalIndex.between(last, nil)
            if let l = last { XCTAssertLessThan(l, k) }
            keys.append(k)
            last = k
        }
        for i in 0..<(keys.count - 1) {
            let m = FractionalIndex.between(keys[i], keys[i + 1])
            XCTAssertLessThan(keys[i], m)
            XCTAssertLessThan(m, keys[i + 1])
            XCTAssertFalse(m.hasSuffix("0"))
        }
        let first = FractionalIndex.between(nil, "1")
        XCTAssertLessThan(first, "1")
    }

    func testRevCodingAndOrder() throws {
        let a = Rev(wallMs: 10, counter: 1, device: 2)
        let b = Rev(wallMs: 10, counter: 2, device: 1)
        XCTAssertLessThan(a, b)
        XCTAssertEqual(Rev(string: a.description), a)
        XCTAssertLessThan(a.description, b.description)
        let data = try JSONEncoder().encode([a])
        XCTAssertEqual(try JSONDecoder().decode([Rev].self, from: data), [a])
    }

    func testStrokeCodecBothForms() throws {
        let s = Stroke(style: InkStyle(), points: [StrokePoint(x: 1, y: 2, t: 0.5, force: 0.7), StrokePoint(x: 3, y: 4)], t0: 100)
        let plain = try JSONValue.from(s)
        XCTAssertEqual(plain["fmt"], "full")
        let back = try plain.decode(Stroke.self)
        XCTAssertEqual(back.points.count, 2)
        XCTAssertEqual(back.points[0].force, 0.7, accuracy: 0.001)

        let encoder = JSONEncoder()
        encoder.userInfo[.nibCompactPoints] = true
        let compact = try JSONDecoder().decode(Stroke.self, from: try encoder.encode(s))
        XCTAssertEqual(compact.points, s.points)

        let aiStroke = try JSONValue.parse(#"{"fmt":"xy","pts":[10,10,20,20,30,15]}"#).decode(Stroke.self)
        XCTAssertEqual(aiStroke.points.count, 3)
        XCTAssertEqual(aiStroke.style.tool, .pen)
    }

    func testItemPayloadValidation() {
        var bad = Item(kind: .shape, stroke: Stroke(style: InkStyle(), points: []))
        XCTAssertFalse(bad.isValid)
        bad.kind = .stroke
        XCTAssertTrue(bad.isValid)
    }

    func testRichTextAcceptsPlainString() throws {
        let rt = try JSONValue.string("a\nb").decode(RichText.self)
        XCTAssertEqual(rt.paragraphs.count, 2)
        XCTAssertEqual(rt.plainText, "a\nb")
    }

    func testMutateCommitsAndUndoRestores() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let ctx = try await probeContext(h)
        try ctx.mutate("Delete") { tx in
            try tx.delete(item: Fixtures.strokeID, doc: Fixtures.docID, page: Fixtures.page1)
        }
        XCTAssertNotEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertNotEqual(try h.snapshot(), before)
    }

    func testRollbackOnError() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let ctx = try await probeContext(h)
        XCTAssertThrowsError(try ctx.mutate { tx in
            try tx.delete(item: Fixtures.shapeID, doc: Fixtures.docID, page: Fixtures.page1)
            throw NibError.invalid("boom")
        })
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testSelectiveRevertSkipsLaterEdits() async throws {
        let h = Harness()
        let ctx = try await probeContext(h)
        try ctx.mutate { tx in
            var it = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            it.locked = true
            try tx.put(it, doc: Fixtures.docID, page: Fixtures.page1)
        }
        let group = ctx.group
        let later = try await probeContext(h)
        try later.mutate { tx in
            var it = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            it.layer = 2
            try tx.put(it, doc: Fixtures.docID, page: Fixtures.page1)
        }
        let r = h.app.bus.revert(group: group, doc: Fixtures.docID)
        XCTAssertEqual(r?.skipped, 1)
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).layer, 2)
    }

    func testRemoteMergeIsLastWriterWins() throws {
        let h = Harness()
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        item.rev = Rev(wallMs: UInt64.max / 2, counter: 0, device: 99)
        item.locked = true
        let patch = DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page1.raw: [item]])
        XCTAssertEqual(h.app.bus.applyRemote(patch, origin: "test").updated.count, 1)
        XCTAssertTrue(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).locked)
        item.locked = false
        item.rev = Rev(wallMs: 5, counter: 0, device: 99)
        _ = h.app.bus.applyRemote(DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page1.raw: [item]]), origin: "test")
        XCTAssertTrue(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).locked)
    }

    func testGatewayPermissions() async throws {
        let h = Harness()
        do {
            try await h.run("settings.set", ["name": "security.ai.confirmationPolicy", "value": "never"], as: .ai("t"))
            XCTFail("AI must not change security settings")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("edit.undo", ["doc": "doc:FIXTUREDOC01"], as: .plugin("x"))
            XCTFail("plugin without grants must be denied")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        let list = try await h.run("commands.list", ["namespace": "edit"], as: .ai("t"))
        XCTAssertEqual(list["commands"]?.arrayValue?.count, 2)
    }

    func testSchemaValidation() {
        let s = JSONSchema.obj(["page": .ref, "n": .int(min: 1)], required: ["page"])
        XCTAssertTrue(s.validate(["page": "page:A/B", "n": 2]).isEmpty)
        XCTAssertEqual(s.validate(["n": 0]).count, 2)
    }

    func testCoreCommandsConform() async {
        let problems = await CommandConformance.check(features: [])
        XCTAssertEqual(problems, [])
    }

    func testMinimalJSONDecodesForEveryRecordAndPayload() throws {
        func ok<T: Decodable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNoThrow(try JSONValue.parse(json).decode(T.self), "\(T.self) from \(json)", file: file, line: line)
        }
        ok(Item.self, #"{"kind":"shape","shape":{"shape":"rectangle","frame":{"x":1,"y":2,"w":3,"h":4}}}"#)
        ok(ShapeItem.self, #"{"shape":"line","points":[[0,0],[10,10]]}"#)
        ok(ConnectorItem.self, #"{"from":{"point":[0,0]},"to":{"item":"FIXTURESHP01","side":1}}"#)
        ok(TextBoxItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(ImageItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10},"asset":"a.png"}"#)
        ok(StickyItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(MathItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(CommentItem.self, #"{"anchor":[5,5]}"#)
        ok(CommentMessage.self, #"{"text":"hi"}"#)
        ok(CustomItem.self, #"{"owner":"p","type":"t","frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(DisplayList.self, #"{}"#)
        ok(PageRecord.self, #"{"size":{"width":595,"height":842}}"#)
        ok(OutlineEntry.self, #"{"title":"x"}"#)
        ok(AudioClip.self, #"{}"#)
        ok(TranscriptSegment.self, #"{"text":"x"}"#)
        ok(TextBlock.self, #"{"text":"plain"}"#)
        ok(CustomBlock.self, #"{"owner":"p","type":"t"}"#)
        ok(TableData.self, #"{}"#)
        ok(TableCell.self, #"{}"#)
        ok(TableMerge.self, #"{"row":0,"column":0}"#)
        ok(BlockComment.self, #"{"text":"x"}"#)
        ok(StudyCard.self, #"{"front":"Term","back":{"text":"Definition"}}"#)
        ok(CardFace.self, #""just text""#)
        ok(SRSState.self, #"{}"#)
        ok(DocumentMeta.self, #"{}"#)
        ok(LayerInfo.self, #"{"index":2}"#)
        ok(DocumentContent.self, #"{"meta":{}}"#)
        let face = try JSONValue.parse(#"{"ink":[{"fmt":"xy","pts":[0,0,5,5]}]}"#).decode(CardFace.self)
        XCTAssertEqual(face.kind, .ink)
    }

    func testDensifyClampsTheSplineEnds() {
        var s = Stroke(style: InkStyle(), points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 10, y: 0), StrokePoint(x: 10, y: 10)])
        InkModel.prepare(&s)
        XCTAssertEqual(s.points.prefix(3).map { $0.x }, [0, 0, 0])
        XCTAssertEqual(s.points.suffix(3).map { $0.y }, [10, 10, 10])
        XCTAssertTrue(s.points.allSatisfy { $0.width > 0 })
        for (a, b) in zip(s.points, s.points.dropFirst()) { XCTAssertLessThanOrEqual(a.location.distance(to: b.location), 1.5 + 1e-4) }
        let captured = Stroke(style: InkStyle(), points: [StrokePoint(x: 0, y: 0, width: 2, height: 2), StrokePoint(x: 50, y: 0, width: 2, height: 2)])
        var copy = captured
        InkModel.prepare(&copy)
        XCTAssertEqual(copy, captured, "PencilKit-captured strokes are untouched")
    }

    func testFeatureCommandsAreOwnedByTheirFeature() {
        let h = Harness(features: [ProbeFeature.self])
        XCTAssertEqual(h.app.commands.descriptor("probe.stamp")?.owner, "probe")
        XCTAssertEqual(h.app.commands.descriptor("edit.undo")?.owner, "builtin")
        h.app.commands.unregister(owner: "probe")
        XCTAssertNil(h.app.commands.descriptor("probe.stamp"))
    }

    func testReadOnlyCallsCannotMutate() async throws {
        let h = Harness(features: [ProbeFeature.self])
        do {
            try await h.app.bus.execute(Invocation(command: "probe.stamp", principal: .ai("t"), readOnly: true))
            XCTFail("ask mode must refuse edit commands")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("probe.sneaky")
            XCTFail("a read command must not mutate")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("probe.nested")
            XCTFail("unknown nested commands are unavailable")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
    }

    func testProvenanceCannotBeForged() async throws {
        let h = Harness(features: [ProbeFeature.self])
        let r = try await h.run("probe.stamp", ["createdBy": "user"], as: .ai("chat1"))
        let ref = try XCTUnwrap(r["ref"]?.stringValue)
        guard case let .item(d, p, i)? = NodeRef(ref) else { return XCTFail("bad ref") }
        XCTAssertEqual(try h.app.workspace.item(d, page: p, id: i).createdBy, "ai:chat1")
    }

    func testSettingsAreDeclaredValidatedAndGuarded() async throws {
        let h = Harness()
        try await h.run("settings.set", ["name": "editing.openAsTabs", "value": false], as: .ai("t"))
        XCTAssertFalse(h.app.settings.get(NibSettings.openAsTabs))
        for (name, value, code) in [("nope.nothing", JSONValue.bool(true), NibError.Code.notFound),
                                    ("editing.openAsTabs", JSONValue.string("yes"), .invalidParams),
                                    ("managed.iCloudAllowed", JSONValue.bool(true), .permissionDenied)] {
            do {
                try await h.run("settings.set", ["name": .string(name), "value": value], as: .ai("t"))
                XCTFail("\(name) must be rejected")
            } catch let e as NibError {
                XCTAssertEqual(e.code, code, name)
            }
        }
        do {
            try await h.run("settings.get", ["name": "security.ai.confirmationPolicy"], as: .plugin("p"))
            XCTFail("security settings are user-only")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
    }

    func testFarFutureRevisionsLoseToCorrectlyClockedEdits() {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var normal = OutlineEntry(id: "OUTLINEX0001", title: "edited today", page: nil)
        normal.rev = Rev(wallMs: nowMs, counter: 0, device: 1)
        var skewed = normal
        skewed.title = "device clock 30 days ahead"
        skewed.rev = Rev(wallMs: nowMs + 30 * 86_400_000, counter: 0, device: 9)
        XCTAssertEqual(LWW.merge([normal], [skewed]).first?.title, "edited today")
        XCTAssertEqual(LWW.merge([], [skewed]).first?.title, "device clock 30 days ahead")
    }

    func testSharedCanvasAndCollabFakes() async throws {
        let h = Harness()
        let canvas = FakeCanvasHost(h)
        canvas.zoomScale = 2
        let back = try XCTUnwrap(canvas.pagePoint(canvas.viewPoint(Point(10, 20), page: Fixtures.page2)))
        XCTAssertEqual(back.page, Fixtures.page2)
        XCTAssertEqual(back.point.x, 10, accuracy: 1e-9)
        XCTAssertEqual(back.point.y, 20, accuracy: 1e-9)
        XCTAssertNil(canvas.pagePoint(CGPoint(x: -1, y: -1)))

        let hub = InMemoryCollabTransport.Hub()
        let a = InMemoryCollabTransport(hub: hub)
        let b = InMemoryCollabTransport(hub: hub)
        var received: [Data] = []
        b.onMessage = { _, data in received.append(data) }
        try await a.host(code: "ROOM01", displayName: "A")
        try await b.join(code: "ROOM01", displayName: "B")
        try a.send(Data([1]), to: nil)
        XCTAssertEqual(received, [Data([1])])
        XCTAssertEqual(a.peers.map(\.name), ["B"])
        b.leave()
        XCTAssertTrue(a.peers.isEmpty)
    }

    /// A context as a command would receive it (via a throwaway registered command).
    private func probeContext(_ h: Harness) async throws -> CommandContext {
        var captured: CommandContext?
        let d = CommandDescriptor(id: "test.probe", title: "Probe", summary: "test", effect: .edit, exposure: .ui)
        h.app.commands.register(d) { _, ctx in
            captured = ctx
            return .null
        }
        try await h.run("test.probe")
        return try XCTUnwrap(captured)
    }
}

/// A tiny feature used by the contract tests.
enum ProbeFeature: NibFeature {
    static let id = "probe"

    static func register(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: "probe.stamp", title: "Stamp", summary: "Adds a sticky note (test).",
                                                examples: [[:]], effect: .edit)) { params, ctx in
            let item = try ctx.mutate { tx -> Item in
                var it = Item.makeSticky(StickyItem(frame: Frame(x: 10, y: 10, w: 50, h: 50)))
                it.createdBy = params["createdBy"]?.stringValue
                return try tx.put(it, doc: Fixtures.docID, page: Fixtures.page1)
            }
            return ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, item.id).description)]
        }
        app.commands.register(CommandDescriptor(id: "probe.sneaky", title: "Sneaky", summary: "A read command that tries to write (test).",
                                                examples: [[:]], effect: .read)) { _, ctx in
            try ctx.mutate { tx in try tx.delete(item: Fixtures.stickyID, doc: Fixtures.docID, page: Fixtures.page1) }
            return .null
        }
        app.commands.register(CommandDescriptor(id: "probe.nested", title: "Nested", summary: "Calls a missing command (test).",
                                                examples: [[:]], effect: .edit)) { _, ctx in
            try await ctx.execute("missing.command")
        }
    }
}
```

### `NibKit/Tests/NibContractsTests/NameLookupCanaryTests.swift`

```swift
// Compiles every public NibContracts name UNQUALIFIED next to every framework a feature may import. A clash such as
// Combine.Empty, SwiftUI.Transaction, SwiftUI.ShapeStyle or the iOS 18 Vision RecognizedText only shows up in a
// client module that imports both, so this file must compile before contracts-v1 is tagged (green baseline).
// If a line fails with "is ambiguous for type lookup", rename the contract type (e.g. Point/Rect → PagePoint/PageRect).
import XCTest
import SwiftUI
import UIKit
import Combine
import CoreGraphics
import Vision
import VisionKit
import PDFKit
import PencilKit
import JavaScriptCore
import WebKit
import Network
import Speech
import AVFoundation
import EventKit
import MultipeerConnectivity
import NaturalLanguage
import AppIntents
import Charts
import BackgroundTasks
import UserNotifications
import LocalAuthentication
import PhotosUI
import NibContracts
import NibTesting

enum NameLookupCanary {
    static let types: [Any.Type] = [
        JSONValue.self, NibFormat.self, NibLimits.self, NibID.self, Rev.self,
        HLCClock.self, FractionalIndex.self, RGBA.self, AssetRef.self, Point.self,
        Rect.self, Frame.self, Affine.self, Geo.self, InkTool.self,
        PenStyle.self, StrokePattern.self, InkStyle.self, StrokePoint.self, Stroke.self,
        InkModel.self, TextLink.self, TextAttributes.self, TextRun.self, ParagraphAlignment.self,
        ListKind.self, Paragraph.self, RichText.self, ItemKind.self, ShapeKind.self,
        ShapeItemStyle.self, ShapeItem.self, ConnectorEnd.self, ConnectorRoute.self, ConnectorItem.self,
        TextBoxStyle.self, TextBoxItem.self, ImageItem.self, StickyItem.self, MathItem.self,
        CommentMessage.self, CommentItem.self, DisplayOpKind.self, DisplayOp.self, DisplayList.self,
        CustomItem.self, Item.self, LWW.self, DocumentKind.self, ScrollDirection.self,
        LayerInfo.self, PageSize.self, TemplateRef.self, BackgroundKind.self, Background.self,
        DocumentMeta.self, PageRecord.self, OutlineEntry.self, TranscriptSegment.self, AudioClip.self,
        BlockKind.self, TableCell.self, TableMerge.self, TableData.self, CustomBlock.self,
        BlockComment.self, TextBlock.self, CardFaceKind.self, CardFace.self, SRSState.self,
        StudyCard.self, PagePosition.self, DocumentContent.self, PresetSwatch.self, ToolPresets.self,
        FolderStyle.self, LibraryNodeKind.self, SyncBadge.self, LibraryNode.self, NodeRef.self,
        NibError.self, Principal.self, Effect.self, CommandTarget.self, Scope.self,
        Exposure.self, JSONSchema.self, CommandDescriptor.self, NoResult.self, CommandRegistry.self,
        CommandIDs.self, ChangeSummary.self, Mutation.self, Changeset.self, DocumentPatch.self,
        DocumentPersistence.self, InMemoryPersistence.self, Workspace.self, DocTransaction.self, UndoEntry.self,
        UndoHistory.self, NibEventType.self, NibEvent.self, EventSubscription.self, EventBus.self,
        Invocation.self, CommandHookDescriptor.self, InvocationResult.self, CommandContext.self, CommandBus.self,
        ConfirmationPolicy.self, ConfirmationRequest.self, ConfirmationDecision.self, ConfirmationPresenter.self, Gateway.self,
        Selection.self, ReplayMode.self, ReplayState.self, StylusMode.self, EditorSession.self,
        SessionRegistry.self, LibraryService.self, PackageLocator.self, AssetStore.self, RenderRequest.self,
        RenderResult.self, PageRenderer.self, TextRecognition.self, TextRecognizer.self, PDFLinkInfo.self,
        PDFOutlineNode.self, PDFService.self, LockService.self, NibServices.self, AIMode.self,
        AIScopeKind.self, AIScope.self, AIMessage.self, AIRequest.self, AIUsage.self,
        AIResponse.self, AIStreamEvent.self, AIChatSummary.self, AIService.self, ToolCatalog.self,
        ServiceKeys.self, PluginNetwork.self, PluginCommandContribution.self, PluginWhen.self, PluginMenuContribution.self,
        PluginToolbarContribution.self, PluginToolContribution.self, PluginPanelContribution.self, PluginTemplateContribution.self, PluginKeybinding.self,
        PluginAIAction.self, PluginAIGuidance.self, PluginFileHandler.self, PluginItemType.self, PluginTapHandler.self,
        PluginToolOptions.self, PluginBlockContribution.self, PluginStrokeProcessor.self, PluginPencilAction.self, PluginCommandHook.self,
        PluginElementCollection.self, PluginTapePattern.self, PluginBoardTemplate.self, PluginContributions.self, PluginManifest.self,
        PluginInfo.self, PluginRuntimeHandle.self, PluginRuntimeProviding.self, PluginHosting.self, AIProviderKind.self,
        AIProviderConfig.self, ChatRole.self, ChatPart.self, ChatMessage.self, ToolSpec.self,
        ChatRequest.self, ChatEvent.self, AIProvider.self, AIProviderStore.self, CollabPeer.self,
        CollabTransport.self, SettingKey<Bool>.self, SyncedSettingsBackend.self, SettingDescriptor.self, SettingsStore.self,
        NibSettings.self, SecretStore.self, SystemKeychainStore.self, Keychain.self, DeviceIdentity.self,
        AppGroup.self, Registrable.self, Registry<TemplateDefinition>.self, TemplateParam.self, TemplateRender.self,
        TemplateDefinition.self, DrawContext.self, ItemDrawer.self, ItemDrawerEntry.self, ImportTarget.self,
        ImporterDescriptor.self, ExportRequest.self, ExporterDescriptor.self, AIActionDescriptor.self, StrokeProcessor.self,
        StrokeProcessorEntry.self, KeyModifiers.self, KeyShortcut.self, KeyScope.self, KeyCommandDescriptor.self,
        BackgroundTaskKind.self, BackgroundTaskDescriptor.self, CanvasGesture.self, TapHandlerDescriptor.self, BoardTemplateDescriptor.self,
        TapePatternDescriptor.self, ElementEntry.self, ElementCollectionDescriptor.self, BlockKindDescriptor.self, CustomItemTypeDescriptor.self,
        PencilActionDescriptor.self, ContentRegistries.self, PKBridge.self, RichTextBridge.self, CanvasInputMode.self,
        CanvasSample.self, CanvasHost.self, CanvasTool.self, CanvasAttachment.self, CanvasAttachmentDescriptor.self,
        PencilEventHandler.self, DocumentEditing.self, ToolbarGroup.self, ToolbarItemDescriptor.self, MenuLocation.self,
        MenuContext.self, MenuItemDescriptor.self, PanelPlacement.self, PanelContext.self, PanelDescriptor.self,
        SettingsSection.self, SettingsPageDescriptor.self, InspectorContext.self, InspectorDescriptor.self, ToolMenuDescriptor.self,
        BlockViewContext.self, BlockViewDescriptor.self, PluginPanelFactory.self, CanvasToolDescriptor.self, DocumentEditorDescriptor.self,
        OpenMode.self, SceneNavigator.self, SceneHooks.self, ScreenRegistry.self, UIRegistries.self,
        NibFeature.self, NibApp.self, SafeMode.self, InkOutline.self, FakeCanvasHost.self,
        InMemoryCollabTransport.self
    ]

    /// Protocols with associated types / Self requirements are checked as generic constraints.
    static func constraints<C: NibCommand, R: LWWRecord>(_ command: C.Type, _ record: R.Type) {}
}

/// A SwiftUI view in the same file as commands, the way feature modules are written.
@MainActor
struct CanaryView: View {
    let app: NibApp

    var body: some View {
        Button("Undo") { app.perform(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"]) }
    }
}

@MainActor
struct CanaryCommand: NibCommand {
    struct Params: Codable { var page: String }
    struct Output: Codable { var ok: Bool }
    static let descriptor = CommandDescriptor(id: "canary.check", title: "Canary", summary: "Name lookup canary.",
                                              params: .obj(["page": .ref], required: ["page"]), effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let r: Result<Int, Error> = .success(1)                       // Swift.Result stays usable
        _ = r
        _ = NoResult()
        return Output(ok: true)
    }
}

@MainActor
final class NameLookupCanaryTests: XCTestCase {
    func testEveryContractNameResolves() {
        XCTAssertGreaterThan(NameLookupCanary.types.count, 200)
        NameLookupCanary.constraints(CanaryCommand.self, OutlineEntry.self)
        let h = Harness()
        _ = CanaryView(app: h.app).body
    }
}
```

## Part B — Package manifest and generated lists

These files are generated from `forge-spec.json` by the architect's generator (module order = registration order). The scaffold writes them verbatim. To add or remove a module, update the spec and regenerate; never hand-edit these files.

### `NibKit/Package.swift`

```swift
// swift-tools-version:5.10
// GENERATED from docs/forge-spec.json (module list). Edit the spec, not this file, when adding a module.
import PackageDescription

let zip: Target.Dependency = .product(name: "ZIPFoundation", package: "ZIPFoundation")
let swiftMath: Target.Dependency = .product(name: "SwiftMath", package: "SwiftMath")
// Reserved design system (tokens, droplet/"liquid" components, Metal shaders), filled by a later design stage.
// Every ui/fullstack feature module depends on it; core modules do not (ARCHITECTURE.md §3).
let design: Target.Dependency = "NibDesign"

struct Module {
    let name: String
    var deps: [Target.Dependency] = []
    var resources: [Resource] = []
    var testResources: [Resource] = []
}

let modules: [Module] = [
    Module(name: "NibStore"),
    Module(name: "NibLibrary"),
    Module(name: "FeatQuery"),
    Module(name: "NibRender"),
    Module(name: "NibTemplates"),
    Module(name: "FeatCanvas", deps: [design]),
    Module(name: "FeatPen", deps: [design]),
    Module(name: "FeatPresets", deps: [design]),
    Module(name: "FeatHighlighter", deps: [design]),
    Module(name: "FeatEraser", deps: [design]),
    Module(name: "FeatLasso", deps: [design]),
    Module(name: "FeatTransform", deps: [design]),
    Module(name: "FeatObjectMenu", deps: [design]),
    Module(name: "FeatClipboard", deps: [design]),
    Module(name: "FeatUndoUI", deps: [design]),
    Module(name: "FeatToolbar", deps: [design]),
    Module(name: "FeatDocChrome", deps: [design]),
    Module(name: "FeatWindows", deps: [design]),
    Module(name: "FeatLibraryUI", deps: [design]),
    Module(name: "FeatLibraryOrganize", deps: [design]),
    Module(name: "FeatCreate", deps: [design]),
    Module(name: "FeatPages", deps: [design]),
    Module(name: "FeatSidebar", deps: [design]),
    Module(name: "NibPDF"),
    Module(name: "NibSync"),
    Module(name: "FeatTextBox", deps: [design]),
    Module(name: "FeatSettings", deps: [design]),
    Module(name: "FeatPageText", deps: [design]),
    Module(name: "FeatLinks", deps: [design]),
    Module(name: "FeatShapeRecognition", deps: [design]),
    Module(name: "FeatShapes", deps: [design]),
    Module(name: "FeatDiagrams", deps: [design]),
    Module(name: "FeatTape", deps: [design]),
    Module(name: "FeatImages", deps: [design]),
    Module(name: "FeatElements", deps: [design, zip]),
    Module(name: "FeatSticky", deps: [design]),
    Module(name: "FeatComments", deps: [design]),
    Module(name: "FeatZoomWindow", deps: [design]),
    Module(name: "FeatRuler", deps: [design]),
    Module(name: "FeatLaser", deps: [design]),
    Module(name: "FeatLayers", deps: [design]),
    Module(name: "FeatReadOnly", deps: [design]),
    Module(name: "FeatPencilHardware", deps: [design]),
    Module(name: "FeatWhiteboard", deps: [design]),
    Module(name: "FeatTemplateUI", deps: [design]),
    Module(name: "FeatOutline", deps: [design]),
    Module(name: "FeatTextDoc", deps: [design]),
    Module(name: "FeatTextDocTables", deps: [design]),
    Module(name: "FeatStudyEditor", deps: [design]),
    Module(name: "FeatStudySession", deps: [design]),
    Module(name: "FeatStudyIO"),
    Module(name: "FeatAudio", deps: [design]),
    Module(name: "FeatReplay", deps: [design]),
    Module(name: "FeatTranscription", deps: [design]),
    Module(name: "NibIndex"),
    Module(name: "FeatSearchUI", deps: [design]),
    Module(name: "FeatConvertText", deps: [design]),
    Module(name: "FeatSmartInk", deps: [design]),
    Module(name: "FeatInkSynth", deps: [design]),
    Module(name: "FeatMath", deps: [design, swiftMath]),
    Module(name: "FeatMathAssist", deps: [design]),
    Module(name: "FeatTimeKeeper", deps: [design]),
    Module(name: "FeatPresentation", deps: [design]),
    Module(name: "FeatImport", deps: [design, zip]),
    Module(name: "FeatScan", deps: [design]),
    Module(name: "NibExport", deps: [zip]),
    Module(name: "FeatExportUI", deps: [design]),
    Module(name: "FeatBackup", deps: [design, zip]),
    Module(name: "FeatWebDAV"),
    Module(name: "FeatSyncUI", deps: [design]),
    Module(name: "FeatLock", deps: [design]),
    Module(name: "FeatCollab", deps: [design, zip]),
    Module(name: "FeatKeyboard", deps: [design]),
    Module(name: "FeatSystemIntegration", deps: [design]),
    Module(name: "FeatCalendar", deps: [design]),
    Module(name: "FeatDiagnostics", deps: [design]),
    Module(name: "NibPluginRuntime", resources: [.copy("Resources/prelude.js")]),
    Module(name: "NibPluginHost"),
    Module(name: "FeatPluginInstall", deps: [design, zip]),
    Module(name: "FeatPluginManager", deps: [design]),
    Module(name: "FeatPluginPanels", deps: [design]),
    Module(name: "NibAIProviders", testResources: [.copy("Fixtures")]),
    Module(name: "NibAIAgent"),
    Module(name: "FeatAIChat", deps: [design]),
    Module(name: "FeatAISettings", deps: [design]),
    Module(name: "FeatAIActions"),
    Module(name: "FeatAIMath", deps: [design]),
    Module(name: "FeatMeetingAI", deps: [design]),
    Module(name: "NibBridge"),
    Module(name: "FeatBridgeUI", deps: [design]),
    Module(name: "FeatRelay"),
    Module(name: "FeatOnboarding", deps: [design]),
    Module(name: "FeatAppearance", deps: [design]),
    Module(name: "FeatA11y", deps: [design]),
    Module(name: "FeatManagedConfig"),
    Module(name: "FeatAbout", deps: [design]),
    Module(name: "FeatTeacher", deps: [design]),
    Module(name: "FeatPerformance"),
]

var targets: [Target] = [
    .target(name: "NibContracts"),
    .target(name: "NibDesign"),
    .target(name: "NibTesting", dependencies: ["NibContracts"]),
    .testTarget(name: "NibContractsTests", dependencies: ["NibContracts", "NibTesting"]),
    .testTarget(name: "ConformanceTests",
                dependencies: ["NibContracts", "NibTesting"] + modules.map { Target.Dependency.target(name: $0.name) }),
    // Example plugins call doc.create, card.add, ink.writeText, panels and nib.ai, so they run against every module
    // (with NibTesting's FakeAIService); cross-feature acceptance scenarios live in IntegrationTests (F111).
    .testTarget(name: "ExamplePluginsTests",
                dependencies: ["NibContracts", "NibTesting"] + modules.map { Target.Dependency.target(name: $0.name) }),
    .testTarget(name: "IntegrationTests",
                dependencies: ["NibContracts", "NibTesting"] + modules.map { Target.Dependency.target(name: $0.name) }),
]

for m in modules {
    targets.append(.target(name: m.name, dependencies: ["NibContracts"] + m.deps,
                           resources: m.resources.isEmpty ? nil : m.resources))
    targets.append(.testTarget(name: m.name + "Tests",
                               dependencies: [.target(name: m.name), "NibContracts", "NibTesting"],
                               resources: m.testResources.isEmpty ? nil : m.testResources))
}

let package = Package(
    name: "NibKit",
    platforms: [.iOS(.v17)],
    // Two products, so Xcode always generates the aggregate "NibKit-Package" scheme CI tests with.
    products: [.library(name: "NibKit", targets: ["NibContracts", "NibDesign"] + modules.map { $0.name }),
               .library(name: "NibTesting", targets: ["NibTesting"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.0.0"),
    ],
    targets: targets
)
```

### `Nib/App/FeatureList.swift`

```swift
// GENERATED from docs/forge-spec.json. Registration order = this order (services first; the second half of a
// split feature right after its first half).
import NibContracts
import NibStore
import NibLibrary
import FeatQuery
import NibRender
import NibTemplates
import FeatCanvas
import FeatPen
import FeatPresets
import FeatHighlighter
import FeatEraser
import FeatLasso
import FeatTransform
import FeatObjectMenu
import FeatClipboard
import FeatUndoUI
import FeatToolbar
import FeatDocChrome
import FeatWindows
import FeatLibraryUI
import FeatLibraryOrganize
import FeatCreate
import FeatPages
import FeatSidebar
import NibPDF
import NibSync
import FeatTextBox
import FeatSettings
import FeatPageText
import FeatLinks
import FeatShapeRecognition
import FeatShapes
import FeatDiagrams
import FeatTape
import FeatImages
import FeatElements
import FeatSticky
import FeatComments
import FeatZoomWindow
import FeatRuler
import FeatLaser
import FeatLayers
import FeatReadOnly
import FeatPencilHardware
import FeatWhiteboard
import FeatTemplateUI
import FeatOutline
import FeatTextDoc
import FeatTextDocTables
import FeatStudyEditor
import FeatStudySession
import FeatStudyIO
import FeatAudio
import FeatReplay
import FeatTranscription
import NibIndex
import FeatSearchUI
import FeatConvertText
import FeatSmartInk
import FeatInkSynth
import FeatMath
import FeatMathAssist
import FeatTimeKeeper
import FeatPresentation
import FeatImport
import FeatScan
import NibExport
import FeatExportUI
import FeatBackup
import FeatWebDAV
import FeatSyncUI
import FeatLock
import FeatCollab
import FeatKeyboard
import FeatSystemIntegration
import FeatCalendar
import FeatDiagnostics
import NibPluginRuntime
import NibPluginHost
import FeatPluginInstall
import FeatPluginManager
import FeatPluginPanels
import NibAIProviders
import NibAIAgent
import FeatAIChat
import FeatAISettings
import FeatAIActions
import FeatAIMath
import FeatMeetingAI
import NibBridge
import FeatBridgeUI
import FeatRelay
import FeatOnboarding
import FeatAppearance
import FeatA11y
import FeatManagedConfig
import FeatAbout
import FeatTeacher
import FeatPerformance

enum FeatureList {
    static let all: [NibFeature.Type] = [
        NibStoreFeature.self,
        NibLibraryFeature.self,
        FeatQueryFeature.self,
        NibRenderFeature.self,
        NibTemplatesFeature.self,
        FeatCanvasFeature.self,
        FeatCanvasInputFeature.self,
        FeatPenFeature.self,
        FeatPresetsFeature.self,
        FeatHighlighterFeature.self,
        FeatEraserFeature.self,
        FeatLassoFeature.self,
        FeatTransformFeature.self,
        FeatObjectMenuFeature.self,
        FeatClipboardFeature.self,
        FeatUndoUIFeature.self,
        FeatToolbarFeature.self,
        FeatDocChromeFeature.self,
        FeatWindowsFeature.self,
        FeatLibraryUIFeature.self,
        FeatLibraryOrganizeFeature.self,
        FeatCreateFeature.self,
        FeatPagesFeature.self,
        FeatSidebarFeature.self,
        NibPDFFeature.self,
        NibSyncFeature.self,
        FeatTextBoxFeature.self,
        FeatSettingsFeature.self,
        FeatPageTextFeature.self,
        FeatLinksFeature.self,
        FeatShapeRecognitionFeature.self,
        FeatShapesFeature.self,
        FeatDiagramsFeature.self,
        FeatTapeFeature.self,
        FeatImagesFeature.self,
        FeatElementsFeature.self,
        FeatStickyFeature.self,
        FeatCommentsFeature.self,
        FeatZoomWindowFeature.self,
        FeatRulerFeature.self,
        FeatLaserFeature.self,
        FeatLayersFeature.self,
        FeatReadOnlyFeature.self,
        FeatPencilHardwareFeature.self,
        FeatWhiteboardFeature.self,
        FeatTemplateUIFeature.self,
        FeatOutlineFeature.self,
        FeatTextDocFeature.self,
        FeatTextDocEditingFeature.self,
        FeatTextDocExtrasFeature.self,
        FeatTextDocTablesFeature.self,
        FeatStudyEditorFeature.self,
        FeatStudySessionFeature.self,
        FeatStudyIOFeature.self,
        FeatAudioFeature.self,
        FeatReplayFeature.self,
        FeatTranscriptionFeature.self,
        NibIndexFeature.self,
        FeatSearchUIFeature.self,
        FeatConvertTextFeature.self,
        FeatSmartInkFeature.self,
        FeatInkSynthFeature.self,
        FeatSpellcheckFeature.self,
        FeatRestyleFeature.self,
        FeatMathFeature.self,
        FeatMathAssistFeature.self,
        FeatMathAssistOverlayFeature.self,
        FeatMathGraphFeature.self,
        FeatTimeKeeperFeature.self,
        FeatPresentationFeature.self,
        FeatImportFeature.self,
        FeatScanFeature.self,
        NibExportFeature.self,
        FeatExportUIFeature.self,
        FeatBackupFeature.self,
        FeatWebDAVFeature.self,
        FeatSyncUIFeature.self,
        FeatLockFeature.self,
        FeatCollabFeature.self,
        FeatCollabPresenceFeature.self,
        FeatKeyboardFeature.self,
        FeatSystemIntegrationFeature.self,
        FeatCalendarFeature.self,
        FeatDiagnosticsFeature.self,
        NibPluginRuntimeFeature.self,
        NibPluginHostFeature.self,
        FeatPluginInstallFeature.self,
        FeatPluginManagerFeature.self,
        FeatPluginPanelsFeature.self,
        NibAIProvidersFeature.self,
        NibAIAgentFeature.self,
        FeatAIChatFeature.self,
        FeatAISettingsFeature.self,
        FeatAIActionsFeature.self,
        FeatAIMathFeature.self,
        FeatMeetingAIFeature.self,
        NibBridgeFeature.self,
        FeatBridgeUIFeature.self,
        FeatRelayFeature.self,
        FeatOnboardingFeature.self,
        FeatAppearanceFeature.self,
        FeatA11yFeature.self,
        FeatManagedConfigFeature.self,
        FeatAboutFeature.self,
        FeatTeacherFeature.self,
        FeatTeacherLessonsFeature.self,
        FeatTeacherInsightsFeature.self,
        FeatPerformanceFeature.self
    ]
}
```

### `NibKit/Tests/ConformanceTests/AllFeatures.swift`

```swift
// GENERATED from docs/forge-spec.json.
import NibContracts
import NibStore
import NibLibrary
import FeatQuery
import NibRender
import NibTemplates
import FeatCanvas
import FeatPen
import FeatPresets
import FeatHighlighter
import FeatEraser
import FeatLasso
import FeatTransform
import FeatObjectMenu
import FeatClipboard
import FeatUndoUI
import FeatToolbar
import FeatDocChrome
import FeatWindows
import FeatLibraryUI
import FeatLibraryOrganize
import FeatCreate
import FeatPages
import FeatSidebar
import NibPDF
import NibSync
import FeatTextBox
import FeatSettings
import FeatPageText
import FeatLinks
import FeatShapeRecognition
import FeatShapes
import FeatDiagrams
import FeatTape
import FeatImages
import FeatElements
import FeatSticky
import FeatComments
import FeatZoomWindow
import FeatRuler
import FeatLaser
import FeatLayers
import FeatReadOnly
import FeatPencilHardware
import FeatWhiteboard
import FeatTemplateUI
import FeatOutline
import FeatTextDoc
import FeatTextDocTables
import FeatStudyEditor
import FeatStudySession
import FeatStudyIO
import FeatAudio
import FeatReplay
import FeatTranscription
import NibIndex
import FeatSearchUI
import FeatConvertText
import FeatSmartInk
import FeatInkSynth
import FeatMath
import FeatMathAssist
import FeatTimeKeeper
import FeatPresentation
import FeatImport
import FeatScan
import NibExport
import FeatExportUI
import FeatBackup
import FeatWebDAV
import FeatSyncUI
import FeatLock
import FeatCollab
import FeatKeyboard
import FeatSystemIntegration
import FeatCalendar
import FeatDiagnostics
import NibPluginRuntime
import NibPluginHost
import FeatPluginInstall
import FeatPluginManager
import FeatPluginPanels
import NibAIProviders
import NibAIAgent
import FeatAIChat
import FeatAISettings
import FeatAIActions
import FeatAIMath
import FeatMeetingAI
import NibBridge
import FeatBridgeUI
import FeatRelay
import FeatOnboarding
import FeatAppearance
import FeatA11y
import FeatManagedConfig
import FeatAbout
import FeatTeacher
import FeatPerformance

enum AllFeatures {
    static let list: [NibFeature.Type] = [
        NibStoreFeature.self,
        NibLibraryFeature.self,
        FeatQueryFeature.self,
        NibRenderFeature.self,
        NibTemplatesFeature.self,
        FeatCanvasFeature.self,
        FeatCanvasInputFeature.self,
        FeatPenFeature.self,
        FeatPresetsFeature.self,
        FeatHighlighterFeature.self,
        FeatEraserFeature.self,
        FeatLassoFeature.self,
        FeatTransformFeature.self,
        FeatObjectMenuFeature.self,
        FeatClipboardFeature.self,
        FeatUndoUIFeature.self,
        FeatToolbarFeature.self,
        FeatDocChromeFeature.self,
        FeatWindowsFeature.self,
        FeatLibraryUIFeature.self,
        FeatLibraryOrganizeFeature.self,
        FeatCreateFeature.self,
        FeatPagesFeature.self,
        FeatSidebarFeature.self,
        NibPDFFeature.self,
        NibSyncFeature.self,
        FeatTextBoxFeature.self,
        FeatSettingsFeature.self,
        FeatPageTextFeature.self,
        FeatLinksFeature.self,
        FeatShapeRecognitionFeature.self,
        FeatShapesFeature.self,
        FeatDiagramsFeature.self,
        FeatTapeFeature.self,
        FeatImagesFeature.self,
        FeatElementsFeature.self,
        FeatStickyFeature.self,
        FeatCommentsFeature.self,
        FeatZoomWindowFeature.self,
        FeatRulerFeature.self,
        FeatLaserFeature.self,
        FeatLayersFeature.self,
        FeatReadOnlyFeature.self,
        FeatPencilHardwareFeature.self,
        FeatWhiteboardFeature.self,
        FeatTemplateUIFeature.self,
        FeatOutlineFeature.self,
        FeatTextDocFeature.self,
        FeatTextDocEditingFeature.self,
        FeatTextDocExtrasFeature.self,
        FeatTextDocTablesFeature.self,
        FeatStudyEditorFeature.self,
        FeatStudySessionFeature.self,
        FeatStudyIOFeature.self,
        FeatAudioFeature.self,
        FeatReplayFeature.self,
        FeatTranscriptionFeature.self,
        NibIndexFeature.self,
        FeatSearchUIFeature.self,
        FeatConvertTextFeature.self,
        FeatSmartInkFeature.self,
        FeatInkSynthFeature.self,
        FeatSpellcheckFeature.self,
        FeatRestyleFeature.self,
        FeatMathFeature.self,
        FeatMathAssistFeature.self,
        FeatMathAssistOverlayFeature.self,
        FeatMathGraphFeature.self,
        FeatTimeKeeperFeature.self,
        FeatPresentationFeature.self,
        FeatImportFeature.self,
        FeatScanFeature.self,
        NibExportFeature.self,
        FeatExportUIFeature.self,
        FeatBackupFeature.self,
        FeatWebDAVFeature.self,
        FeatSyncUIFeature.self,
        FeatLockFeature.self,
        FeatCollabFeature.self,
        FeatCollabPresenceFeature.self,
        FeatKeyboardFeature.self,
        FeatSystemIntegrationFeature.self,
        FeatCalendarFeature.self,
        FeatDiagnosticsFeature.self,
        NibPluginRuntimeFeature.self,
        NibPluginHostFeature.self,
        FeatPluginInstallFeature.self,
        FeatPluginManagerFeature.self,
        FeatPluginPanelsFeature.self,
        NibAIProvidersFeature.self,
        NibAIAgentFeature.self,
        FeatAIChatFeature.self,
        FeatAISettingsFeature.self,
        FeatAIActionsFeature.self,
        FeatAIMathFeature.self,
        FeatMeetingAIFeature.self,
        NibBridgeFeature.self,
        FeatBridgeUIFeature.self,
        FeatRelayFeature.self,
        FeatOnboardingFeature.self,
        FeatAppearanceFeature.self,
        FeatA11yFeature.self,
        FeatManagedConfigFeature.self,
        FeatAboutFeature.self,
        FeatTeacherFeature.self,
        FeatTeacherLessonsFeature.self,
        FeatTeacherInsightsFeature.self,
        FeatPerformanceFeature.self
    ]
}
```

### `NibKit/Tests/ConformanceTests/ConformanceTests.swift`

```swift
import XCTest
import NibContracts
import NibTesting

/// Runs against EVERY feature module (AllFeatures.swift is generated from docs/forge-spec.json).
@MainActor
final class ConformanceTests: XCTestCase {
    func testEveryCommandConforms() async {
        let problems = await CommandConformance.check(features: AllFeatures.list)
        XCTAssertTrue(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
    }

    func testFeatureIDsAreUnique() {
        let h = Harness(features: AllFeatures.list)
        XCTAssertEqual(Set(h.app.featureIDs).count, h.app.featureIDs.count)
    }
}
```
## Part C — App shell (app target)

The shell is intentionally thin. It creates `NibApp`, registers the features, hosts one `ShellViewController` per window scene, turns `KeyCommandDescriptor`s into `UIKeyCommand`s, routes URLs and quick actions to commands, awaits `ui.openGate`, and shows fallback screens when a provider feature is missing.

### `Nib/App/AppDelegate.swift`

```swift
import UIKit
import BackgroundTasks
import NibContracts

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Minimal confirmation UI, so plugins and the bridge work without the AI chat feature (F085 wraps it).
    static let confirmer = ShellConfirmationPresenter()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SafeMode.beginLaunch()
        let app = NibApp()
        app.gateway.presenter = AppDelegate.confirmer
        let disabled = SafeMode.disabledFeatures
        let features = FeatureList.all.filter { !disabled.contains($0.id) }
        app.register(features)
        registerBackgroundTasks(app)   // must run before this method returns
        Task { @MainActor in
            await app.start(features)
            SafeMode.endLaunch()
        }
        return true
    }

    /// Registers every identifier in Info.plist `BGTaskSchedulerPermittedIdentifiers` exactly once, synchronously
    /// (registering after launch throws NSInternalInconsistencyException), and routes each launch to the
    /// `BackgroundTaskDescriptor` with that id; a task without a descriptor (feature disabled) completes at once.
    private func registerBackgroundTasks(_ app: NibApp) {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        for id in ids {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak app] task in
                Task { @MainActor in
                    guard let app = app, let descriptor = app.content.backgroundTasks.get(id) else {
                        task.setTaskCompleted(success: true)
                        return
                    }
                    let work = Task { @MainActor in await descriptor.handler(task) }
                    task.expirationHandler = { work.cancel() }
                    task.setTaskCompleted(success: await work.value)
                }
            }
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let role = connectingSceneSession.role
        let config = UISceneConfiguration(name: nil, sessionRole: role)
        if role == .windowExternalDisplayNonInteractive {
            if NibApp.shared?.ui.externalDisplay != nil { config.delegateClass = ExternalDisplaySceneDelegate.self }
        } else {
            config.delegateClass = SceneDelegate.self
        }
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var shell: ShellViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let app = NibApp.shared else { return }
        let shell = ShellViewController(app: app)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = shell
        window.makeKeyAndVisible()
        self.window = window
        self.shell = shell
        app.ui.sceneHooks?.sceneDidConnect(windowScene, options: connectionOptions, navigator: shell)
        for context in connectionOptions.urlContexts { shell.handle(url: context.url) }
        if let item = connectionOptions.shortcutItem {
            app.perform(CommandIDs.appQuickAction, ["type": .string(item.type)], session: shell.session)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        NibApp.shared?.perform(CommandIDs.appQuickAction, ["type": .string(shortcutItem.type)], session: shell?.session)
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { shell?.handle(url: context.url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let shell = shell, let app = NibApp.shared else { return }
        app.ui.activeNavigator = shell
        app.services.sessions.activate(shell.session)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let shell = shell else { return }
        NibApp.shared?.services.sessions.remove(shell.session)
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let shell = shell else { return nil }
        return NibApp.shared?.ui.sceneHooks?.restorationActivity(shell)
    }
}

/// Alert-based confirmation for non-user principals (plugins, bridge, AI): who asks, which command, the params.
@MainActor
final class ShellConfirmationPresenter: ConfirmationPresenter {
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        guard let root = NibApp.shared?.ui.activeNavigator?.rootViewController else { return .deny }
        let details = String(request.params.jsonString(pretty: true).prefix(600))
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: request.command.title,
                                          message: "\(request.principal) wants to run \(request.command.id).\n\n\(details)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Deny"), style: .cancel) { _ in
                continuation.resume(returning: .deny)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Allow Rest of This Turn"), style: .default) { _ in
                continuation.resume(returning: .allowRestOfGroup)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Allow"), style: .default) { _ in
                continuation.resume(returning: .allow)
            })
            var top = root
            while let presented = top.presentedViewController { top = presented }
            top.present(alert, animated: true)
        }
    }
}

/// External display (AirPlay / HDMI) scene; content comes from the Presentation feature.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let root = NibApp.shared?.ui.externalDisplay?(windowScene) else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        window.isHidden = false
        self.window = window
    }
}
```

### `Nib/App/ShellViewController.swift`

```swift
import UIKit
import SwiftUI
import NibContracts

/// Root of every window. Owns the tab model and implements `SceneNavigator`; everything visible is provided by
/// features through `app.ui.screens` (library, document chrome, settings, onboarding) with minimal fallbacks.
@MainActor
final class ShellViewController: UIViewController, SceneNavigator {
    let app: NibApp
    let session: EditorSession
    private(set) var openDocuments: [DocumentID] = []
    private(set) var activeDocument: DocumentID?
    private var content: UIViewController?
    private var tabBar: UIView?
    private var failureObserver: NSObjectProtocol?

    init(app: NibApp) {
        self.app = app
        self.session = EditorSession()
        super.init(nibName: nil, bundle: nil)
        app.services.sessions.add(session)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var rootViewController: UIViewController? { self }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        failureObserver = NotificationCenter.default.addObserver(forName: .nibCommandFailed, object: nil, queue: .main) { [weak self] note in
            let message = (note.userInfo?["error"] as? NibError)?.message ?? "Something went wrong"
            Task { @MainActor in self?.toast(message) }
        }
        if let onboarding = app.ui.screens.onboarding?(app, self) {
            display(onboarding)
        } else {
            showLibrary(folder: nil)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        if let bar = tabBar {
            bar.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: 36)
            content?.view.frame = CGRect(x: 0, y: top + 36, width: view.bounds.width, height: max(0, view.bounds.height - top - 36))
        } else {
            content?.view.frame = view.bounds
        }
    }

    // MARK: SceneNavigator

    func showLibrary(folder: FolderID?) {
        session.document = nil
        display(app.ui.screens.libraryRoot?(app, self) ?? FallbackLibraryViewController(app: app, navigator: self))
    }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        if let gate = app.ui.openGate, mode != .newWindow {
            Task { @MainActor in
                if await gate(doc) { self.performOpen(doc, page: page, mode: mode) }
            }
        } else {
            performOpen(doc, page: page, mode: mode)
        }
    }

    private func performOpen(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        if mode == .newWindow {
            let activity = NSUserActivity(activityType: "app.nib.openDocument")
            activity.userInfo = ["doc": doc.raw, "page": page?.raw ?? ""]
            let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity, options: nil)
            UIApplication.shared.activateSceneSession(for: request, errorHandler: nil)
            return
        }
        guard let docContent = try? app.workspace.content(doc) else {
            toast("Could not open the document")
            return
        }
        let asTab = mode == .newTab || app.settings.get(NibSettings.openAsTabs)
        if !openDocuments.contains(doc) {
            if !asTab, let current = activeDocument, let i = openDocuments.firstIndex(of: current) {
                openDocuments[i] = doc
            } else {
                openDocuments.append(doc)
            }
        }
        activeDocument = doc
        session.document = doc
        session.selection = Selection()
        session.page = page ?? docContent.livePages.first?.id
        let kind = docContent.meta.kind
        let editor = app.ui.editors.get(kind.rawValue)?.make(doc, session, app)
            ?? FallbackEditorViewController(message: "No editor is installed for \(kind.rawValue) documents.")
        display(app.ui.screens.documentContainer?(editor, doc, app, self) ?? editor)
        if let p = page { session.editor?.reveal(page: p, rect: nil, animated: false) }
    }

    func closeDocument(_ doc: DocumentID) {
        openDocuments.removeAll { $0 == doc }
        guard activeDocument == doc else {
            refreshTabBar()
            return
        }
        activeDocument = nil
        if let next = openDocuments.last {
            openDocument(next, page: nil, mode: .replace)
        } else {
            showLibrary(folder: nil)
        }
    }

    func showSettings(page: String?) {
        let root = app.ui.screens.settingsRoot?(app, self) ?? FallbackSettingsViewController(app: app)
        presentModal(UINavigationController(rootViewController: root))
    }

    func presentModal(_ viewController: UIViewController) {
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(viewController, animated: true)
    }

    // MARK: Keyboard (every shortcut is a registered KeyCommandDescriptor that runs a command)

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let inDocument = activeDocument != nil
        return app.content.keyCommands.all.compactMap { d -> UIKeyCommand? in
            switch d.scope {
            case .global: break
            case .library: if inDocument { return nil }
            case .document: if !inDocument { return nil }
            case .canvas: if !inDocument || session.isEditingText { return nil }
            }
            let command = UIKeyCommand(title: d.title, action: #selector(runKeyCommand(_:)),
                                       input: ShellViewController.keyInput(d.shortcut.key),
                                       modifierFlags: ShellViewController.modifierFlags(d.shortcut.modifiers),
                                       propertyList: d.id)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func runKeyCommand(_ sender: UIKeyCommand) {
        guard let id = sender.propertyList as? String, let d = app.content.keyCommands.get(id) else { return }
        app.perform(d.command, d.params, session: session)
    }

    private static func keyInput(_ key: String) -> String {
        switch key {
        case "up": return UIKeyCommand.inputUpArrow
        case "down": return UIKeyCommand.inputDownArrow
        case "left": return UIKeyCommand.inputLeftArrow
        case "right": return UIKeyCommand.inputRightArrow
        case "escape": return UIKeyCommand.inputEscape
        case "delete": return UIKeyCommand.inputDelete
        case "tab": return "\t"
        case "return": return "\r"
        case "space": return " "
        default: return key
        }
    }

    private static func modifierFlags(_ m: KeyModifiers) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if m.contains(.command) { flags.insert(.command) }
        if m.contains(.shift) { flags.insert(.shift) }
        if m.contains(.option) { flags.insert(.alternate) }
        if m.contains(.control) { flags.insert(.control) }
        return flags
    }

    // MARK: URLs

    /// File URLs (Open In / share sheet) go to `import.files`; nib:// URLs to `app.openURL`.
    func handle(url: URL) {
        if url.isFileURL {
            app.perform(CommandIDs.importFiles, ["urls": [.string(url.absoluteString)]], session: session)
        } else {
            app.perform(CommandIDs.appOpenURL, ["url": .string(url.absoluteString)], session: session)
        }
    }

    // MARK: Private

    private func display(_ vc: UIViewController) {
        if let old = content {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(vc)
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        content = vc
        refreshTabBar()
    }

    private func refreshTabBar() {
        tabBar?.removeFromSuperview()
        tabBar = nil
        if activeDocument != nil, let bar = app.ui.sceneHooks?.makeTabBar(self) {
            view.addSubview(bar)
            tabBar = bar
        }
        view.setNeedsLayout()
    }

    private func toast(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        let width = min(view.bounds.width - 32, 480)
        let size = label.sizeThatFits(CGSize(width: width - 24, height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: (view.bounds.width - size.width - 24) / 2,
                             y: view.bounds.height - view.safeAreaInsets.bottom - size.height - 48,
                             width: size.width + 24, height: size.height + 16)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 2.5, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

// MARK: - Fallback screens (used only when the providing feature is missing or disabled)

final class FallbackLibraryViewController: UITableViewController {
    private let app: NibApp
    private weak var navigator: SceneNavigator?
    private var nodes: [LibraryNode] = []

    init(app: NibApp, navigator: SceneNavigator) {
        self.app = app
        self.navigator = navigator
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        nodes = app.services.library?.allNodes().filter { $0.kind == .document } ?? []
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(nodes.count, 1) }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = nodes.isEmpty ? "No documents (library feature not installed)" : nodes[indexPath.row].title
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.row < nodes.count else { return }
        navigator?.openDocument(nodes[indexPath.row].id, page: nil, mode: .replace)
    }
}

final class FallbackEditorViewController: UIViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 32, dy: 32)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}

final class FallbackSettingsViewController: UITableViewController {
    private let app: NibApp
    private var pages: [SettingsPageDescriptor] { app.ui.settingsPages.all }

    init(app: NibApp) {
        self.app = app
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { pages.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = pages[indexPath.row].title
        config.image = UIImage(systemName: pages[indexPath.row].icon)
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let page = pages[indexPath.row]
        navigationController?.pushViewController(UIHostingController(rootView: page.makeView(app)), animated: true)
    }
}
```
## Part D — Project and CI

`project.yml` (XcodeGen), the GitHub Actions workflow (macos-26 with Xcode 26.6 pinned: a fast `feature` job on `feat/**` branches, the `test` ∥ `ipa` jobs everywhere else) and the three Python helpers. Unsigned build (ad-hoc signed in CI only to carry the optional App Group entitlement); see ARCHITECTURE.md §19 for sideloading.

### `project.yml`

```yaml
name: Nib
options:
  bundleIdPrefix: app.nib
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
  developmentLanguage: en
settings:
  base:
    SWIFT_VERSION: "5.0"
    SWIFT_STRICT_CONCURRENCY: minimal
    IPHONEOS_DEPLOYMENT_TARGET: "17.0"
    TARGETED_DEVICE_FAMILY: "1,2"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    CODE_SIGNING_ALLOWED: "NO"
    CODE_SIGNING_REQUIRED: "NO"
    CODE_SIGN_IDENTITY: ""
    DEVELOPMENT_TEAM: ""
    ENABLE_USER_SCRIPT_SANDBOXING: "NO"
packages:
  NibKit:
    path: NibKit
targets:
  Nib:
    type: application
    platform: iOS
    sources:
      - path: Nib
    dependencies:
      - package: NibKit
        product: NibKit
      - target: NibWidgets
      - target: NibShare
    entitlements:
      path: Nib/Nib.entitlements
      properties:
        com.apple.security.application-groups: [group.app.nib.Nib]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.nib.Nib
        PRODUCT_NAME: Nib
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    info:
      path: Nib/Info.plist
      properties:
        CFBundleDisplayName: Nib
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSRequiresIPhoneOS: true
        UILaunchScreen: {}
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: true
        UIRequiresFullScreen: false
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UIBackgroundModes: [audio, fetch, processing]
        # Registered by AppDelegate before launch returns; each id maps to a BackgroundTaskDescriptor
        # (backup F068 processing, index F055 processing, webdav F069 refresh, sync F025 refresh).
        BGTaskSchedulerPermittedIdentifiers: [app.nib.backup, app.nib.index, app.nib.webdav, app.nib.sync]
        # App Group ids the build asks for (progressive enhancement; AltStore/SideStore add ALTAppGroups).
        NibAppGroups: [group.app.nib.Nib]
        NSCameraUsageDescription: Nib uses the camera to insert photos and scan documents.
        NSMicrophoneUsageDescription: Nib records audio alongside your notes.
        NSPhotoLibraryUsageDescription: Nib inserts images from your photo library.
        NSPhotoLibraryAddUsageDescription: Nib saves images and exports to your photo library.
        NSSpeechRecognitionUsageDescription: Nib transcribes your recordings on this device.
        NSFaceIDUsageDescription: Nib uses Face ID to unlock password-protected notebooks.
        NSLocalNetworkUsageDescription: Nib uses the local network for live collaboration and the AI bridge.
        NSCalendarsFullAccessUsageDescription: Nib shows your calendar events and creates notes for meetings.
        NSCalendarsUsageDescription: Nib shows your calendar events and creates notes for meetings.
        NSBonjourServices: [_nib._tcp, _nib-collab._tcp, _nib-collab._udp]
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        NSUserActivityTypes: [app.nib.openDocument]
        CFBundleURLTypes:
          - CFBundleURLName: app.nib
            CFBundleURLSchemes: [nib]
        UIApplicationShortcutItems:
          - UIApplicationShortcutItemType: app.nib.quicknote
            UIApplicationShortcutItemTitle: QuickNote
            UIApplicationShortcutItemIconSymbolName: square.and.pencil
        CFBundleDocumentTypes:
          - CFBundleTypeName: Nib Document
            CFBundleTypeRole: Editor
            LSHandlerRank: Owner
            LSTypeIsPackage: true
            LSItemContentTypes: [app.nib.document]
          - CFBundleTypeName: Nib Plugin
            CFBundleTypeRole: Viewer
            LSHandlerRank: Owner
            LSItemContentTypes: [app.nib.plugin]
          - CFBundleTypeName: Nib Element Collection
            CFBundleTypeRole: Viewer
            LSHandlerRank: Owner
            LSItemContentTypes: [app.nib.collection]
          - CFBundleTypeName: PDF
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [com.adobe.pdf]
          - CFBundleTypeName: Image
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.image]
          - CFBundleTypeName: Importable files
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes:
              - org.openxmlformats.wordprocessingml.document
              - com.microsoft.word.doc
              - org.openxmlformats.presentationml.presentation
              - com.microsoft.powerpoint.ppt
              - public.comma-separated-values-text
              - public.tab-separated-values-text
              - public.plain-text
              - public.zip-archive
        UTExportedTypeDeclarations:
          - UTTypeIdentifier: app.nib.document
            UTTypeDescription: Nib Document
            UTTypeConformsTo: [com.apple.package, public.composite-content]
            UTTypeTagSpecification:
              public.filename-extension: [nibnote]
          - UTTypeIdentifier: app.nib.plugin
            UTTypeDescription: Nib Plugin
            UTTypeConformsTo: [public.zip-archive]
            UTTypeTagSpecification:
              public.filename-extension: [nibplugin]
          - UTTypeIdentifier: app.nib.collection
            UTTypeDescription: Nib Element Collection
            UTTypeConformsTo: [public.zip-archive]
            UTTypeTagSpecification:
              public.filename-extension: [nibcollection]
          - UTTypeIdentifier: app.nib.fragment
            UTTypeDescription: Nib Fragment
            UTTypeConformsTo: [public.json]
          - UTTypeIdentifier: app.nib.pages
            UTTypeDescription: Nib Pages
            UTTypeConformsTo: [public.json]
  NibWidgets:
    type: app-extension
    platform: iOS
    sources:
      - path: NibWidgets
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.nib.Nib.widgets
        PRODUCT_NAME: NibWidgets
        SKIP_INSTALL: "YES"
    info:
      path: NibWidgets/Info.plist
      properties:
        CFBundleDisplayName: Nib
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
        NibAppGroups: [group.app.nib.Nib]
    entitlements:
      path: NibWidgets/NibWidgets.entitlements
      properties:
        com.apple.security.application-groups: [group.app.nib.Nib]
  NibShare:
    # Optional share extension (F064): writes into the App Group inbox when one exists, else hands small payloads
    # to the app through the pasteboard (nib://import?from=pasteboard). Removed in Nib-unsigned-noextensions.ipa.
    type: app-extension
    platform: iOS
    sources:
      - path: NibShare
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.nib.Nib.share
        PRODUCT_NAME: NibShare
        SKIP_INSTALL: "YES"
    info:
      path: NibShare/Info.plist
      properties:
        CFBundleDisplayName: Nib
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        NibAppGroups: [group.app.nib.Nib]
        NSExtension:
          NSExtensionPointIdentifier: com.apple.share-services
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ShareViewController
          NSExtensionAttributes:
            NSExtensionActivationRule:
              NSExtensionActivationSupportsImageWithMaxCount: 20
              NSExtensionActivationSupportsText: true
              NSExtensionActivationSupportsWebURLWithMaxCount: 1
              NSExtensionActivationSupportsFileWithMaxCount: 20
    entitlements:
      path: NibShare/NibShare.entitlements
      properties:
        com.apple.security.application-groups: [group.app.nib.Nib]
schemes:
  Nib:
    build:
      targets:
        Nib: all
    run:
      config: Debug
    archive:
      config: Release
```

### `.github/workflows/ios.yml`

```yaml
name: iOS

on:
  push:
    branches: [main, 'feat/**']
  pull_request:
  workflow_dispatch:

concurrency:
  group: ios-${{ github.ref }}
  cancel-in-progress: true

env:
  # Xcode 26.6 = iOS 26 SDK, because the locked UI uses Liquid Glass. The deployment target stays iOS 17.0 and Swift 5
  # language mode; every iOS 26+ API sits behind #available. Bump the dd-x26.6-* cache keys together with this path.
  XCODE: /Applications/Xcode_26.6.app
  HOMEBREW_NO_AUTO_UPDATE: 1

jobs:
  # feat/<FeatureID> branches (one per feature agent): lint that feature, build and run ONLY its test target(s), and
  # build the app only when the feature owns files in Nib/, NibWidgets/ or NibShare/. No full suite, no IPA.
  feature:
    if: startsWith(github.ref, 'refs/heads/feat/')
    runs-on: macos-26
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # Scripts/restore_mtimes.py reads the history

      - name: Resolve feature from branch
        id: feat
        run: |
          python3 - "$GITHUB_REF_NAME" >> "$GITHUB_OUTPUT" <<'EOF'
          import json, os, re, sys
          m = re.match(r"feat/(F\d{3})\b", sys.argv[1])
          if not m:
              sys.exit("branch %s is not feat/<FeatureID> (e.g. feat/F012)" % sys.argv[1])
          spec = json.load(open("docs/forge-spec.json", encoding="utf-8"))
          f = next((x for x in spec["features"] if x["id"] == m.group(1)), None)
          if f is None:
              sys.exit("%s is not a feature in docs/forge-spec.json" % m.group(1))
          tests = sorted({p.split("/")[2] for p in f.get("tests", []) if p.startswith("NibKit/Tests/")})
          app = any(p.split("/")[0] in ("Nib", "NibWidgets", "NibShare") for p in f["files"] + f.get("tests", []))
          # A package scheme that builds only these test targets and their dependencies (not all ~200 targets).
          ref = ('<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{0}" BuildableName = "{0}" '
                 'BlueprintName = "{0}" ReferencedContainer = "container:"></BuildableReference>')
          entries = "".join('<BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" '
                            'buildForArchiving = "NO" buildForAnalyzing = "NO">' + ref.format(t) + "</BuildActionEntry>"
                            for t in tests)
          testables = "".join('<TestableReference skipped = "NO">' + ref.format(t) + "</TestableReference>" for t in tests)
          scheme_dir = "NibKit/.swiftpm/xcode/xcshareddata/xcschemes"
          os.makedirs(scheme_dir, exist_ok=True)
          with open(scheme_dir + "/NibFeature.xcscheme", "w") as out:
              out.write('<?xml version="1.0" encoding="UTF-8"?>\n<Scheme LastUpgradeVersion = "2600" version = "1.7">'
                        '<BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES"><BuildActionEntries>'
                        + entries + '</BuildActionEntries></BuildAction><TestAction buildConfiguration = "Debug" '
                        'selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" '
                        'selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" '
                        'shouldUseLaunchSchemeArgsEnv = "YES"><Testables>' + testables + "</Testables></TestAction></Scheme>\n")
          print("id=" + f["id"])
          print("tests=" + " ".join(tests))
          print("app=" + ("true" if app else "false"))
          print("%s (%s): test targets [%s], app build %s" % (f["id"], f["module"], " ".join(tests), app), file=sys.stderr)
          EOF

      - name: Lint (this feature's module + spec + docs)
        run: python3 Scripts/lint.py --feature ${{ steps.feat.outputs.id }}

      - name: Select Xcode 26.6
        run: |
          if [ ! -d "$XCODE" ]; then
            echo "::error::$XCODE is not on this runner image any more; pick another Xcode 26.x in ios.yml (env.XCODE)"
            ls -d /Applications/Xcode*.app
            exit 1
          fi
          sudo xcode-select -s "$XCODE/Contents/Developer"
          xcodebuild -version

      - name: Restore file times (keeps the restored DerivedData incremental)
        run: |
          python3 Scripts/restore_mtimes.py
          defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES

      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: build/SourcePackages
          key: spm-${{ hashFiles('NibKit/Package.swift') }}

      - name: Restore DerivedData from main
        # Read-only: feature branches never save (111 branches x GBs would evict main's cache). Main's cache already
        # holds NibContracts, NibTesting and the SDK modules, so only this feature's module and tests compile.
        uses: actions/cache/restore@v4
        with:
          path: build/DerivedData
          key: dd-x26.6-main-${{ hashFiles('NibKit/Package.swift', 'NibKit/Sources/**', 'NibKit/Tests/**') }}
          restore-keys: dd-x26.6-main-

      - name: Pick simulator
        id: sim
        if: steps.feat.outputs.tests != ''
        run: echo "udid=$(python3 Scripts/pick_sim.py)" >> "$GITHUB_OUTPUT"

      - name: Build and test ${{ steps.feat.outputs.tests }}
        if: steps.feat.outputs.tests != ''
        working-directory: NibKit
        run: |
          set -o pipefail
          mkdir -p ../build
          SCHEME=NibFeature
          if ! xcodebuild -list -json 2>/dev/null | grep -q '"NibFeature"'; then
            echo "::warning::generated NibFeature scheme not picked up; falling back to NibKit-Package (builds every target)"
            SCHEME=NibKit-Package
          fi
          ONLY=""
          for t in ${{ steps.feat.outputs.tests }}; do ONLY="$ONLY -only-testing:$t"; done
          COMMON="-scheme $SCHEME -destination id=${{ steps.sim.outputs.udid }} -derivedDataPath ../build/DerivedData"
          COMMON="$COMMON -clonedSourcePackagesDirPath ../build/SourcePackages -skipPackagePluginValidation $ONLY"
          xcodebuild build-for-testing $COMMON 2>&1 | tee ../build/feature-build.log
          xcodebuild test-without-building $COMMON -parallel-testing-enabled NO \
            -resultBundlePath ../build/Feature.xcresult 2>&1 | tee ../build/feature-tests.log

      - name: Build the app (feature owns app-target files)
        if: steps.feat.outputs.app == 'true'
        run: |
          set -o pipefail
          mkdir -p build
          brew install xcodegen
          swift Scripts/make_icons.swift
          xcodegen generate
          xcodebuild build -project Nib.xcodeproj -scheme Nib -configuration Debug -destination 'generic/platform=iOS' \
            -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
            -skipPackagePluginValidation \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" 2>&1 | tee build/app-build.log

      - name: Upload logs
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: feature-logs
          path: |
            build/*.log
            build/*.xcresult

  test:
    if: ${{ !startsWith(github.ref, 'refs/heads/feat/') }}
    runs-on: macos-26
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # Scripts/restore_mtimes.py reads the history

      - name: Select Xcode 26.6
        run: |
          if [ ! -d "$XCODE" ]; then
            echo "::error::$XCODE is not on this runner image any more; pick another Xcode 26.x in ios.yml (env.XCODE)"
            ls -d /Applications/Xcode*.app
            exit 1
          fi
          sudo xcode-select -s "$XCODE/Contents/Developer"
          xcodebuild -version

      - name: Restore file times (keeps the restored DerivedData incremental)
        run: |
          python3 Scripts/restore_mtimes.py
          defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES

      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: build/SourcePackages
          key: spm-${{ hashFiles('NibKit/Package.swift') }}

      - name: Restore DerivedData
        id: dd
        uses: actions/cache/restore@v4
        with:
          path: build/DerivedData
          key: dd-x26.6-main-${{ hashFiles('NibKit/Package.swift', 'NibKit/Sources/**', 'NibKit/Tests/**') }}
          restore-keys: dd-x26.6-main-

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate icons
        run: swift Scripts/make_icons.swift

      - name: Lint (code + docs)
        run: python3 Scripts/lint.py

      - name: Generate project
        run: xcodegen generate

      - name: Relay self-test
        run: |
          if [ -f tools/relay/relay.mjs ]; then node tools/relay/relay.mjs --selftest; else echo "relay not built yet"; fi

      - name: Pick simulator
        id: sim
        run: echo "udid=$(python3 Scripts/pick_sim.py)" >> "$GITHUB_OUTPUT"

      - name: Package tests (contracts, canary, conformance, integration, every module)
        working-directory: NibKit
        run: |
          set -o pipefail
          mkdir -p ../build
          xcodebuild test -scheme NibKit-Package \
            -destination "id=${{ steps.sim.outputs.udid }}" \
            -parallel-testing-enabled NO \
            -derivedDataPath ../build/DerivedData \
            -clonedSourcePackagesDirPath ../build/SourcePackages \
            -skipPackagePluginValidation \
            -resultBundlePath ../build/NibKitTests.xcresult 2>&1 | tee ../build/package-tests.log

      - name: Save DerivedData (main only; feature branches restore it)
        if: (success() || failure()) && github.ref == 'refs/heads/main' && steps.dd.outputs.cache-hit != 'true'
        uses: actions/cache/save@v4
        with:
          path: build/DerivedData
          key: ${{ steps.dd.outputs.cache-primary-key }}

      - name: Upload test logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-logs
          path: |
            build/*.log
            build/*.xcresult

  ipa:
    # Independent of `test`, so an IPA is produced even when tests fail. The archive compiles the app.
    if: ${{ !startsWith(github.ref, 'refs/heads/feat/') }}
    runs-on: macos-26
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode 26.6
        run: |
          if [ ! -d "$XCODE" ]; then echo "::error::$XCODE missing; update env.XCODE"; exit 1; fi
          sudo xcode-select -s "$XCODE/Contents/Developer"

      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: build/SourcePackages
          key: spm-${{ hashFiles('NibKit/Package.swift') }}

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate icons and project
        run: |
          swift Scripts/make_icons.swift
          xcodegen generate

      - name: Archive
        run: |
          set -o pipefail
          mkdir -p build
          xcodebuild archive -project Nib.xcodeproj -scheme Nib -configuration Release \
            -destination 'generic/platform=iOS' -archivePath build/Nib.xcarchive \
            -clonedSourcePackagesDirPath build/SourcePackages \
            -skipPackagePluginValidation \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" 2>&1 | tee build/archive.log

      - name: Package IPAs
        run: |
          set -e
          rm -rf build/Payload && mkdir -p build/Payload
          cp -R build/Nib.xcarchive/Products/Applications/Nib.app build/Payload/
          APP=build/Payload/Nib.app
          test -d "$APP/PlugIns/NibWidgets.appex" || { echo "::error::NibWidgets.appex missing from the IPA"; exit 1; }
          # Ad-hoc sign with the entitlements (App Group) so sideloading tools that honour them can register the group.
          for ext in "$APP"/PlugIns/*.appex; do
            name=$(basename "$ext" .appex)
            codesign --force --sign - --entitlements "$name/$name.entitlements" "$ext" || true
          done
          codesign --force --sign - --entitlements Nib/Nib.entitlements "$APP" || true
          (cd build && zip -qry Nib-unsigned.ipa Payload)
          rm -rf "$APP/PlugIns"
          codesign --force --sign - --entitlements Nib/Nib.entitlements "$APP" || true
          (cd build && zip -qry Nib-unsigned-noextensions.ipa Payload)

      - name: Upload IPAs
        uses: actions/upload-artifact@v4
        with:
          name: Nib-unsigned-ipa
          path: |
            build/Nib-unsigned.ipa
            build/Nib-unsigned-noextensions.ipa

      - name: Upload archive log
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: archive-log
          path: build/archive.log
```

### `Scripts/pick_sim.py`

```python
#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest iOS runtime that the selected SDK supports."""
import json
import subprocess
import sys

sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
sdk_major = int(sdk.split(".")[0])
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
best = None
for runtime, devices in data["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(x) for x in runtime.split(".iOS-")[-1].split("-") if x.isdigit())
    if not version or version[0] > sdk_major:
        continue  # a runtime newer than the SDK cannot run what we build
    for d in devices:
        if not d.get("isAvailable", True):
            continue
        score = (version, "iPhone" in d["name"], "Pro" in d["name"])
        if best is None or score > best[0]:
            best = (score, d["udid"], d["name"], runtime)
if best is None:
    sys.exit("no available iOS simulator for SDK %s" % sdk)
print(best[1])
print("picked %s (%s) for SDK %s" % (best[2], best[3], sdk), file=sys.stderr)
```

### `Scripts/restore_mtimes.py`

```python
#!/usr/bin/env python3
"""Set every tracked file's mtime to the time of the last commit that touched it (CI; needs checkout fetch-depth 0).

A fresh checkout stamps every file "now", so a restored DerivedData would recompile everything. With commit times,
files a commit did not touch look unchanged and only what changed recompiles (ios.yml also sets XCBuild's
IgnoreFileSystemDeviceInodeChanges). Files missing from the history keep "now", which only costs a rebuild.
"""
import os
import subprocess

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
log =subprocess.run(["git", "-c", "core.quotePath=false", "log", "--format=@%ct", "--name-only", "--no-renames"],
                     capture_output=True, text=True, check=True).stdout
seen, when = set(), 0
for line in log.splitlines():
    if line.startswith("@"):
        when = int(line[1:])
    elif line and line not in seen:
        seen.add(line)  # newest commit first, so the first time a path appears is its last change
        if os.path.isfile(line):
            os.utime(line, (when, when))
print("restore_mtimes: %d paths" % len(seen))
```

### `Scripts/lint.py`

```python
#!/usr/bin/env python3
"""Nib repository lint (runs in CI before building).

Errors (exit 1):
  * a feature module imports another NibKit module (only NibContracts, NibDesign, its own module, ZIPFoundation,
    SwiftMath and Apple frameworks are allowed; Package.swift gives NibDesign to ui/fullstack modules only);
  * `applyRemote(` outside NibSync / FeatCollab;
  * `UserDefaults.standard` outside NibContracts / NibTesting / FeatManagedConfig;
  * `BGTaskScheduler` used by a feature (register BackgroundTaskDescriptors instead; the shell registers them);
  * a forge-spec feature file listed for a module that lives in another module's folder;
  * a file path owned by two features (files + tests);
  * docs lint: a Markdown table row in docs/*.md whose cell count differs from its header (unescaped `|`).
Warnings: print( / fatalError( in package sources, spec files missing on disk, module files not listed in the spec,
  settings/Keychain/.nib-library writes outside a command file, and a feature registering command ids other than
  exactly its "Commands owned" list.
Usage: python3 Scripts/lint.py [--feature F012]   (--feature: code rules only for that feature's module; CI's
  feat/<FeatureID> run uses it, so another module's problems never fail your branch)
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "NibKit", "Sources")
SPEC = os.path.join(ROOT, "docs", "forge-spec.json")
REMOTE_OK = {"NibSync", "FeatCollab"}
DEFAULTS_OK = {"NibContracts", "FeatManagedConfig", "NibTesting"}
SHARED = ("NibContracts", "NibTesting", "NibDesign")  # architect-owned, importable modules (not features)

errors, warnings = [], []
modules = sorted(d for d in os.listdir(SRC) if os.path.isdir(os.path.join(SRC, d))) if os.path.isdir(SRC) else []
module_set = set(modules)
feature_filter = None
if len(sys.argv) > 2 and sys.argv[1] == "--feature":
    feature_filter = sys.argv[2]

spec = json.load(open(SPEC, encoding="utf-8")) if os.path.exists(SPEC) else {"features": []}
owned = {}
for f in spec["features"]:
    for p in f["files"] + f.get("tests", []):
        if p in owned:
            errors.append("%s is listed by both %s and %s" % (p, owned[p], f["id"]))
        owned[p] = f["id"]


def rel(p):
    return os.path.relpath(p, ROOT).replace(os.sep, "/")


def owned_commands(desc):
    """Command ids from a feature's 'Commands owned: …' list."""
    i = desc.find("Commands owned: ")
    if i < 0:
        return set()
    text = desc[i + len("Commands owned: "):]
    cut = text.find(". Module ")
    text = text[:cut] if cut >= 0 else text
    return set(re.findall(r'(?<![\w.`"])([a-z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9]+)+) \{', text))


scan = modules
if feature_filter:
    scan = sorted({f["module"] for f in spec["features"] if f["id"] == feature_filter} & module_set)
    if not any(f["id"] == feature_filter for f in spec["features"]):
        errors.append("unknown feature %s (not in docs/forge-spec.json)" % feature_filter)

for m in scan:
    if m in SHARED:
        continue
    for dirpath, _, files in os.walk(os.path.join(SRC, m)):
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            path = os.path.join(dirpath, fn)
            text = open(path, encoding="utf-8", errors="replace").read()
            r = rel(path)
            for imp in re.findall(r"^\s*(?:@testable\s+)?import\s+(?:class\s+|struct\s+|enum\s+|func\s+)?([A-Za-z_][A-Za-z0-9_]*)", text, re.M):
                if imp in module_set and imp not in ("NibContracts", "NibDesign", m):
                    errors.append("%s imports feature module %s (use commands/services instead)" % (r, imp))
            if "applyRemote(" in text and m not in REMOTE_OK:
                errors.append("%s calls applyRemote (only NibSync/FeatCollab may)" % r)
            if "UserDefaults.standard" in text and m not in DEFAULTS_OK:
                errors.append("%s uses UserDefaults.standard (use SettingsStore / SettingKey)" % r)
            if "BGTaskScheduler" in text:
                errors.append("%s uses BGTaskScheduler (register a BackgroundTaskDescriptor; app.scheduleBackgroundTask)" % r)
            if re.search(r"(?<![A-Za-z_.])print\(", text):
                warnings.append("%s uses print( (use os.Logger)" % r)
            if "fatalError(" in text and "init(coder" not in text:
                warnings.append("%s uses fatalError(" % r)
            is_command_file = "NibCommand" in text or "CommandDescriptor(" in text
            if not is_command_file and re.search(r"settings\.set(JSON)?\(|Keychain\.set(String)?\(|\.nib-library/", text):
                warnings.append("%s writes settings/Keychain/.nib-library outside a command file (make it a command)" % r)
            if r not in owned and not re.search(r"Feature\.swift$", fn):
                warnings.append("%s is not listed in forge-spec.json" % r)

for f in spec["features"]:
    if feature_filter and f["id"] != feature_filter:
        continue
    for p in f["files"]:
        if p.startswith("NibKit/Sources/"):
            mod = p.split("/")[2]
            if mod != f["module"]:
                errors.append("%s lists %s outside its module %s" % (f["id"], p, f["module"]))
        if feature_filter and not os.path.exists(os.path.join(ROOT, p)):
            warnings.append("%s: %s does not exist yet" % (f["id"], p))
    present = [os.path.join(ROOT, p) for p in f["files"] if p.endswith(".swift") and os.path.exists(os.path.join(ROOT, p))]
    if present:
        registered = set()
        for p in present:
            registered |= set(re.findall(r'CommandDescriptor\(\s*id:\s*"([^"]+)"', open(p, encoding="utf-8", errors="replace").read()))
        expected = owned_commands(f["description"])
        for extra in sorted(registered - expected):
            warnings.append("%s registers %s, which ARCHITECTURE §6.5 does not list for it" % (f["id"], extra))
        if feature_filter:
            for missing in sorted(expected - registered):
                warnings.append("%s does not register %s yet" % (f["id"], missing))

# Docs lint: every Markdown table row has as many cells as its header.
for md in sorted(glob.glob(os.path.join(ROOT, "docs", "*.md"))):
    header, in_code = None, False
    for n, line in enumerate(open(md, encoding="utf-8").read().split("\n"), 1):
        if line.strip().startswith("```"):
            in_code = not in_code
        if in_code or not line.startswith("|"):
            header = None
            continue
        parts = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]
        cells = len(parts)
        if header is None:
            header = cells
        elif cells != header:
            errors.append("%s:%d: table row has %d cells, header has %d (escape | as \\|)" % (rel(md), n, cells, header))
        elif md.endswith("ARCHITECTURE.md") and cells == 5 and re.match(r"`[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+)+`$", parts[0]):
            # §6.5 catalogue row: | `id` | effect | params | Fxxx | summary |
            if not re.match(r"F\d{3}$", parts[3]) or not re.match(r"(read|session|edit|library|irreversible)\b", parts[1]):
                errors.append("%s:%d: catalogue row %s is malformed (effect '%s', owner '%s')" % (rel(md), n, parts[0], parts[1], parts[3]))

for w in warnings:
    print("warning: " + w)
for e in errors:
    print("error: " + e)
print("lint: %d error(s), %d warning(s)" % (len(errors), len(warnings)))
sys.exit(1 if errors else 0)
```
