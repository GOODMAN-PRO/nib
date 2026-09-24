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
