import Foundation
import CryptoKit
import UIKit
import os
import ZIPFoundation
import NibContracts

// Live collaboration (F072): one document shared from a host to up to `transport.maxPeers - 1` guests.
//
// - Star topology: guests talk only to the host, which admits them (approval), holds the roster and roles, and
//   relays every patch and presence payload. The rules are therefore enforced in one place, whatever the transport
//   (Multipeer nearby, the WebSocket relay of F092, NibTesting's in-memory hub).
// - Sync: every local `Changeset` for the shared document becomes `Changeset.patch(for:)` JSON; incoming patches go
//   through `CommandBus.applyRemote(_:origin:)` (last writer wins, never recorded for undo). A (re)join catches up with
//   a snapshot diff: each side sends a digest (record id → revision) and gets back the records it lacks or holds older.
// - Joiners without the document receive a zipped package snapshot into a "Shared" folder.

// MARK: - Join codes

/// Six-character join codes from an alphabet without look-alikes (no 0/O, 1/I/L), shown as "K7M 2QX".
enum CollabCode {
    static let alphabet: [Character] = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let length = 6

    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(rng.next(upperBound: UInt32(alphabet.count)))] })
    }

    /// The code in what someone typed, pasted or scanned ("k7m 2qx", "K7M-2QX", "nib://collab/join?code=K7M2QX");
    /// nil when it is not a join code.
    static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URLComponents(string: text), url.scheme?.lowercased() == NibFormat.urlScheme,
           let value = url.queryItems?.first(where: { $0.name == "code" })?.value {
            text = value
        }
        let cleaned = String(text.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "." })
        guard cleaned.count == length, cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return cleaned
    }

    /// "K7M 2QX".
    static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    /// "K, 7, M, 2, Q, X" for VoiceOver.
    static func spoken(_ code: String) -> String { code.map { String($0) }.joined(separator: ", ") }

    /// What the QR code carries (the deep link a camera hands to Nib).
    static func joinURL(_ code: String) -> String { "\(NibFormat.urlScheme)://collab/join?code=\(code)" }

    /// Advertised on the local network instead of the code, so the code itself is never broadcast.
    static func discoveryHash(_ code: String) -> String { String(hex("nib-collab/discover/" + code).prefix(16)) }

    /// Sent with a Multipeer invitation: proves the joiner knows the code (the advertisement does not reveal it).
    static func joinProof(_ code: String) -> String { hex("nib-collab/join/" + code) }

    private static func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Gating and caps (S-100, S-101)

enum CollabGate {
    /// The format every participant can read: the oldest participant's `NibFormat.version`. Features newer than it stay
    /// off in the shared document until everyone updates.
    static func effectiveFormat(_ participants: [CollabParticipant]) -> Int {
        participants.filter { $0.state != .pending }.map(\.format).min() ?? NibFormat.version
    }

    /// A participant whose Nib is older than the document's format can view it but not edit it.
    static func canEdit(format: Int, documentFormat: Int) -> Bool { format >= documentFormat }

    /// True when one more participant would pass the transport's cap (the host counts).
    static func isFull(count: Int, cap: Int) -> Bool { count >= cap }

    /// The folder-sync fallback past the cap.
    static func fullMessage(cap: Int) -> String {
        String(localized: "This live session is full (\(cap) people). Open the document from a shared library folder instead: folder sync keeps it up to date.")
    }
}

// MARK: - Digests (snapshot diff)

/// Every record of a document by id with its revision: what a participant has. Two digests give the records each side
/// lacks, so a re-join after a suspend exchanges only what changed while the connection was down.
struct CollabDigest: Codable, Equatable {
    var meta: Rev?
    var pages: [String: Rev]
    var outline: [String: Rev]
    var blocks: [String: Rev]
    var cards: [String: Rev]
    var audio: [String: Rev]
    /// Page id → item id → revision (tombstones included).
    var items: [String: [String: Rev]]

    init(meta: Rev? = nil, pages: [String: Rev] = [:], outline: [String: Rev] = [:], blocks: [String: Rev] = [:],
         cards: [String: Rev] = [:], audio: [String: Rev] = [:], items: [String: [String: Rev]] = [:]) {
        self.meta = meta
        self.pages = pages
        self.outline = outline
        self.blocks = blocks
        self.cards = cards
        self.audio = audio
        self.items = items
    }

    init(content: DocumentContent, items pageItems: [PageID: [Item]]) {
        func table<T: LWWRecord>(_ records: [T]) -> [String: Rev] {
            Dictionary(records.map { ($0.id.raw, $0.rev) }, uniquingKeysWith: { max($0, $1) })
        }
        self.init(meta: content.meta.rev, pages: table(content.pages), outline: table(content.outline),
                  blocks: table(content.blocks), cards: table(content.cards), audio: table(content.audio),
                  items: Dictionary(pageItems.map { ($0.key.raw, table($0.value)) }, uniquingKeysWith: { a, _ in a }))
    }

    enum CodingKeys: String, CodingKey { case meta, pages, outline, blocks, cards, audio, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decodeIfPresent(Rev.self, forKey: .meta)
        pages = try c.decodeIfPresent([String: Rev].self, forKey: .pages) ?? [:]
        outline = try c.decodeIfPresent([String: Rev].self, forKey: .outline) ?? [:]
        blocks = try c.decodeIfPresent([String: Rev].self, forKey: .blocks) ?? [:]
        cards = try c.decodeIfPresent([String: Rev].self, forKey: .cards) ?? [:]
        audio = try c.decodeIfPresent([String: Rev].self, forKey: .audio) ?? [:]
        items = try c.decodeIfPresent([String: [String: Rev]].self, forKey: .items) ?? [:]
    }

    var recordCount: Int {
        (meta == nil ? 0 : 1) + pages.count + outline.count + blocks.count + cards.count + audio.count
            + items.values.reduce(0) { $0 + $1.count }
    }

    /// True when `local` should replace what the other side holds (it lacks the record or holds an older revision;
    /// far-future revisions are distrusted exactly as `Workspace.merge` does).
    static func isNewer(_ local: Rev, than remote: Rev?) -> Bool {
        guard let remote = remote else { return true }
        return local.effective() > remote.effective()
    }

    /// The records of `content` and `items` that `other` lacks or holds at an older revision, as a patch for `doc`.
    static func delta(content: DocumentContent, items: [PageID: [Item]], against other: CollabDigest,
                      doc: DocumentID) -> DocumentPatch {
        var patch = DocumentPatch(doc: doc)
        if isNewer(content.meta.rev, than: other.meta) { patch.meta = content.meta }
        patch.pages = content.pages.filter { isNewer($0.rev, than: other.pages[$0.id.raw]) }
        patch.outline = content.outline.filter { isNewer($0.rev, than: other.outline[$0.id.raw]) }
        patch.blocks = content.blocks.filter { isNewer($0.rev, than: other.blocks[$0.id.raw]) }
        patch.cards = content.cards.filter { isNewer($0.rev, than: other.cards[$0.id.raw]) }
        patch.audio = content.audio.filter { isNewer($0.rev, than: other.audio[$0.id.raw]) }
        for (page, list) in items {
            let theirs = other.items[page.raw] ?? [:]
            let newer = list.filter { isNewer($0.rev, than: theirs[$0.id.raw]) }
            if !newer.isEmpty { patch.items[page.raw] = newer }
        }
        return patch
    }
}

// MARK: - Wire messages

/// One message of the collaboration protocol. Every field but `kind` and `from` is optional so a newer Nib can add
/// fields; an unknown `kind` decodes as `.unknown` and is ignored.
struct CollabMessage: Codable {
    static let protocolVersion = 1

    enum Kind: String, Codable {
        case hello, pending, welcome, denied, roster, patch, sync, syncReply, needSnapshot, snapshot, revoked, ended, bye,
             status, presence, unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    /// Why a join was refused (`denied`): the error code the joiner reports.
    enum Denial: String, Codable {
        case declined, full, update, removed, identity, failed

        var errorCode: NibError.Code {
            switch self {
            case .declined, .removed: return .userDenied
            case .full, .failed: return .unavailable
            case .update: return .unsupported
            case .identity: return .conflict
            }
        }
    }

    struct Hello: Codable {
        var name: String
        var format: Int
        var protocolVersion: Int
        /// Issued at admission; a re-join that presents it skips approval.
        var secret: String?
    }

    struct Welcome: Codable {
        var doc: DocumentID
        var title: String
        var kind: DocumentKind
        var hostName: String
        var hostID: String
        var role: CollabRole
        var secret: String
        var sessionFormat: Int
        var documentFormat: Int
        var cap: Int
        var transport: String
    }

    enum SnapshotFormat: String, Codable {
        /// The zipped `.nibnote` package (assets and audio included).
        case package
        /// The document records only, when the host's library keeps no package on disk.
        case content
    }

    struct SnapshotContent: Codable {
        var content: DocumentContent
        /// Page id → every item, tombstones included.
        var items: [String: [Item]]
    }

    struct Snapshot: Codable {
        var doc: DocumentID
        var title: String
        var kind: DocumentKind
        var format: SnapshotFormat
        var data: Data?
        var content: SnapshotContent?
    }

    struct Status: Codable {
        /// The page the sender looks at, in host ids ("page:D/P").
        var page: String?
    }

    var v: Int = CollabMessage.protocolVersion
    var kind: Kind
    var session: String = ""
    /// Participant id of the author (kept when the host relays).
    var from: String
    /// Presence addressed to one participant (nil = everyone).
    var to: String? = nil
    var hello: Hello? = nil
    var welcome: Welcome? = nil
    var roster: [CollabParticipant]? = nil
    var patch: DocumentPatch? = nil
    var digest: CollabDigest? = nil
    var snapshot: Snapshot? = nil
    var status: Status? = nil
    var payload: JSONValue? = nil
    var reason: String? = nil
    var denial: Denial? = nil
}

// MARK: - Frames

/// Messages on the wire: JSON (stroke points as compact Float32), LZFSE-compressed past 1 KB, split into frames of at
/// most 60 KB so every transport (Multipeer, a WebSocket relay) carries a whole package snapshot.
///
/// Frame: "N", format 1, flags (bit 0 compressed, bit 1 part), then the body; a part adds a 16-byte message id and
/// big-endian UInt32 index and count before its slice of the body.
enum CollabFrames {
    static let magic: UInt8 = 0x4E
    static let formatVersion: UInt8 = 1
    static let compressedFlag: UInt8 = 1
    static let partFlag: UInt8 = 2
    static let maxFrameBytes = 60 * 1024
    static let compressionThreshold = 1024
    static let partHeaderBytes = 3 + 16 + 4 + 4
    /// About 960 MB of body.
    static let maxParts = 16_384

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.userInfo[.nibCompactPoints] = true
        return e
    }

    static func frames(for message: CollabMessage) throws -> [Data] {
        var body = try makeEncoder().encode(message)
        var flags: UInt8 = 0
        if body.count > compressionThreshold, let packed = try? (body as NSData).compressed(using: .lzfse) as Data,
           packed.count < body.count {
            body = packed
            flags |= compressedFlag
        }
        if body.count + 3 <= maxFrameBytes {
            var frame = Data([magic, formatVersion, flags])
            frame.append(body)
            return [frame]
        }
        let chunk = maxFrameBytes - partHeaderBytes
        let count = (body.count + chunk - 1) / chunk
        guard count <= maxParts else {
            throw NibError(.unsupported, String(localized: "This document is too large to share live."),
                           hint: "share it through a synced library folder instead")
        }
        let id = UUID()
        let idBytes = withUnsafeBytes(of: id.uuid) { Data($0) }
        var frames: [Data] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            var frame = Data([magic, formatVersion, flags | partFlag])
            frame.append(idBytes)
            frame.append(contentsOf: bigEndian(UInt32(i)))
            frame.append(contentsOf: bigEndian(UInt32(count)))
            let start = body.startIndex + i * chunk
            frame.append(body.subdata(in: start..<min(start + chunk, body.endIndex)))
            frames.append(frame)
        }
        return frames
    }

    static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func uint32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func decode(body: Data, flags: UInt8) throws -> CollabMessage {
        var json = body
        if flags & compressedFlag != 0 {
            guard let raw = try? (body as NSData).decompressed(using: .lzfse) as Data else {
                throw NibError.invalid("damaged collaboration message")
            }
            json = raw
        }
        return try JSONDecoder().decode(CollabMessage.self, from: json)
    }

    /// Reassembles parts per sender. Incomplete messages are dropped after two minutes.
    final class Assembler {
        private struct Partial {
            var count: Int
            var flags: UInt8
            var parts: [Int: Data]
            var bytes: Int
            var started: Date
        }

        static let maxPendingBytes = 512 * 1_048_576
        static let staleAfter: TimeInterval = 120
        private var partials: [String: Partial] = [:]

        var pendingMessages: Int { partials.count }

        /// The message this frame completes, nil while parts are missing. Throws on frames that are not Nib's.
        func feed(_ frame: Data, from peer: String, now: Date = Date()) throws -> CollabMessage? {
            let header = [UInt8](frame.prefix(CollabFrames.partHeaderBytes))
            guard header.count >= 3, header[0] == CollabFrames.magic else {
                throw NibError.invalid("not a Nib collaboration frame")
            }
            guard header[1] == CollabFrames.formatVersion else {
                throw NibError(.unsupported, String(localized: "A participant uses a newer version of Nib."))
            }
            let flags = header[2]
            if flags & CollabFrames.partFlag == 0 {
                return try CollabFrames.decode(body: frame.subdata(in: (frame.startIndex + 3)..<frame.endIndex), flags: flags)
            }
            guard header.count == CollabFrames.partHeaderBytes else { throw NibError.invalid("truncated collaboration frame") }
            purge(now)
            let id = header[3..<19].map { String(format: "%02x", $0) }.joined()
            let index = Int(CollabFrames.uint32(header[19..<23]))
            let count = Int(CollabFrames.uint32(header[23..<27]))
            guard count > 0, count <= CollabFrames.maxParts, index < count else {
                throw NibError.invalid("damaged collaboration frame")
            }
            let key = peer + "/" + id
            var partial = partials[key]
                ?? Partial(count: count, flags: flags & ~CollabFrames.partFlag, parts: [:], bytes: 0, started: now)
            guard partial.count == count else {
                partials[key] = nil
                throw NibError.invalid("damaged collaboration frame")
            }
            if partial.parts[index] == nil {
                let slice = frame.subdata(in: (frame.startIndex + CollabFrames.partHeaderBytes)..<frame.endIndex)
                partial.parts[index] = slice
                partial.bytes += slice.count
            }
            guard partial.bytes <= Assembler.maxPendingBytes else {
                partials[key] = nil
                throw NibError(.unsupported, String(localized: "This document is too large to share live."))
            }
            guard partial.parts.count == count else {
                partials[key] = partial
                return nil
            }
            partials[key] = nil
            var body = Data(capacity: partial.bytes)
            for i in 0..<count {
                guard let part = partial.parts[i] else { throw NibError.invalid("damaged collaboration frame") }
                body.append(part)
            }
            return try CollabFrames.decode(body: body, flags: partial.flags)
        }

        /// Drops half-received messages from a sender that left.
        func forget(peer: String) {
            partials = partials.filter { !$0.key.hasPrefix(peer + "/") }
        }

        private func purge(_ now: Date) {
            partials = partials.filter { now.timeIntervalSince($0.value.started) < Assembler.staleAfter }
        }
    }
}

// MARK: - Package snapshots

/// Zips a document package for a joiner and unpacks one safely. Runs off the main actor (file I/O only).
enum CollabPackageIO {
    /// Largest expanded snapshot accepted (1 GB).
    static let maxExpandedBytes: UInt64 = 1 << 30

    /// The package folder as a zip that keeps its "<Title>.nibnote" folder name.
    static func zip(_ package: URL) throws -> Data {
        let fm = FileManager()
        let dir = fm.temporaryDirectory.appendingPathComponent("nib-collab-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("snapshot.zip")
        try fm.zipItem(at: package, to: zipURL, shouldKeepParent: true, compressionMethod: .deflate)
        return try Data(contentsOf: zipURL)
    }

    /// Unpacks a snapshot into a fresh temporary folder and returns the package folder inside it. Refuses archives
    /// that expand past `maxExpandedBytes` or hold no package; ZIPFoundation refuses entries outside the folder.
    static func unzip(_ data: Data) throws -> URL {
        let fm = FileManager()
        let dir = fm.temporaryDirectory.appendingPathComponent("nib-collab-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("snapshot.zip")
        try data.write(to: zipURL)
        let archive = try Archive(url: zipURL, accessMode: .read)
        var total: UInt64 = 0
        for entry in archive {
            let (sum, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= maxExpandedBytes else {
                throw NibError(.unsupported, String(localized: "The shared document is too large to open."))
            }
            total = sum
        }
        let out = dir.appendingPathComponent("package", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try fm.unzipItem(at: zipURL, to: out)
        try? fm.removeItem(at: zipURL)
        let children = try fm.contentsOfDirectory(at: out, includingPropertiesForKeys: [.isDirectoryKey])
        let packages = [NibFormat.packageExtension, NibFormat.legacyPackageExtension]
        guard let package = children.first(where: { packages.contains($0.pathExtension.lowercased()) }) else {
            throw NibError.invalid(String(localized: "The shared document arrived damaged."))
        }
        return package
    }

    /// The temporary folder `unzip` created for `package`.
    static func scratchFolder(of package: URL) -> URL {
        package.deletingLastPathComponent().deletingLastPathComponent()
    }
}

// MARK: - Guard for view-only participants

enum CollabGuard {
    /// Param names that carry a bare document id.
    static let documentKeys: Set<String> = ["doc", "document", "source", "target", "from", "to"]

    /// Whether a command's params point into `doc`: any ref naming it, a bare id under a document key, or (when the
    /// params name no document at all) the invoking window's document (session defaults, §6.1).
    static func touches(_ params: JSONValue, doc: DocumentID, sessionDocument: DocumentID?) -> Bool {
        var named = false
        var hit = false
        func visit(_ value: JSONValue, key: String?, depth: Int) {
            guard depth < 8, !hit else { return }
            switch value {
            case .string(let s):
                if let ref = NodeRef(s), let d = ref.documentID {
                    named = true
                    if d == doc { hit = true }
                } else if let key = key, documentKeys.contains(key), NibID.isValid(s) {
                    named = true
                    if s == doc.raw { hit = true }
                }
            case .array(let list):
                for v in list { visit(v, key: key, depth: depth + 1) }
            case .object(let o):
                for (k, v) in o { visit(v, key: k, depth: depth + 1) }
            default:
                return
            }
        }
        visit(params, key: nil, depth: 0)
        if hit { return true }
        if named { return false }
        return sessionDocument == doc
    }
}

// MARK: - Timing

struct CollabTiming {
    /// How long a joiner waits for the host to approve (and the document to arrive).
    var approvalTimeout: TimeInterval = 180
    /// One re-join attempt.
    var rejoinTimeout: TimeInterval = 20
    /// Pauses between re-join attempts after the host is lost; then folder sync takes over.
    var retryDelays: [TimeInterval] = [1, 3, 6, 12, 20]
    /// iOS drops Multipeer and WebSocket sessions about 30 s after backgrounding: past this the connection is re-made.
    var suspendThreshold: TimeInterval = 25
}

// MARK: - Session

/// One live session, as the host or as a guest. Main actor only; transports deliver on main.
@MainActor
final class CollabSession {
    enum Side: String { case host, guest }

    /// `applyRemote` origin of merged collaborator changes ("collab:<participant>"), so they are never echoed back.
    static let originPrefix = "collab:"
    static let viewGuardID = "collab.viewOnly"

    let side: Side
    let code: String
    let transportKey: String
    let transport: CollabTransport
    let me: String
    let myName: String
    let startedAt = Date().timeIntervalSince1970
    var defaultRole: CollabRole
    private unowned let service: CollabService
    private var app: NibApp { service.app }

    private(set) var id: String
    private(set) var phase: CollabPhase
    private(set) var myRole: CollabRole
    private(set) var remoteDoc: DocumentID?
    private(set) var localDoc: DocumentID?
    private(set) var title = ""
    private(set) var kind: DocumentKind?
    private(set) var documentFormat = NibFormat.version
    private(set) var hostName = ""
    private(set) var hostID: String?
    private(set) var participants: [String: CollabParticipant] = [:]
    private(set) var order: [String] = []
    private(set) var endReason: String?
    private(set) var isClosed = false

    // Host: transport peers of admitted and waiting participants.
    private var peerOf: [String: CollabPeer] = [:]
    private var participantOf: [String: String] = [:]
    private var secrets: [String: String] = [:]
    private var blockedPeers = Set<String>()
    private var removed = Set<String>()

    // Guest.
    private(set) var secret: String?
    private var hostPeer: CollabPeer?
    /// Local edits made while disconnected; the next digest exchange sends them.
    private(set) var hasUnsentChanges = false
    /// The document arrived as a snapshot (this library did not have it).
    private(set) var receivedSnapshot = false

    private let assembler = CollabFrames.Assembler()
    private var inbox: [(CollabPeer, Data)] = []
    private var draining = false
    private var commitSubscription: EventSubscription?
    private var eventSubscription: EventSubscription?
    private var registryObserver: NSObjectProtocol?
    private var lastPage: String??
    private var readOnlySessions: [NibID] = []
    private var guardPatterns: [String] = []
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var readyTimer: Task<Void, Never>?
    private let log = Logger(subsystem: "app.nib", category: "collab")

    /// A host session for `doc`.
    init(hosting doc: DocumentID, content: DocumentContent, title: String, code: String, transportKey: String,
         transport: CollabTransport, defaultRole: CollabRole, service: CollabService, me: String, name: String) {
        side = .host
        self.code = code
        self.transportKey = transportKey
        self.transport = transport
        self.defaultRole = defaultRole
        self.service = service
        self.me = me
        myName = name
        id = NibID.make().raw
        phase = .active
        myRole = .edit
        remoteDoc = doc
        localDoc = doc
        self.title = title
        kind = content.meta.kind
        documentFormat = content.meta.format
        hostName = name
        hostID = me
        participants[me] = CollabParticipant(id: me, name: name, role: .edit, state: .active, isHost: true, colorIndex: 0)
        order = [me]
    }

    /// A guest session joining `code`.
    init(joining code: String, transportKey: String, transport: CollabTransport, service: CollabService, me: String,
         name: String) {
        side = .guest
        self.code = code
        self.transportKey = transportKey
        self.transport = transport
        defaultRole = .edit
        self.service = service
        self.me = me
        myName = name
        id = ""
        phase = .connecting
        myRole = .view
    }

    // MARK: Reading

    var roster: [CollabParticipant] { order.compactMap { participants[$0] } }

    /// What guests see: everyone admitted (waiting joiners stay private to the host).
    var publicRoster: [CollabParticipant] { roster.filter { $0.state != .pending } }

    var sessionFormat: Int { CollabGate.effectiveFormat(roster) }

    var isConnectedToHost: Bool {
        guard let h = hostPeer else { return false }
        return transport.peers.contains { $0.id == h.id }
    }

    var hasAdmittedGuests: Bool { participants.values.contains { !$0.isHost && $0.state != .pending } }

    var info: CollabSessionInfo {
        CollabSessionInfo(id: id, code: code, isHost: side == .host, me: me, myRole: side == .host ? .edit : myRole,
                          doc: localDoc, remoteDoc: remoteDoc, title: title, kind: kind, hostName: hostName,
                          transport: transportKey, phase: phase, sessionFormat: sessionFormat, cap: transport.maxPeers,
                          startedAt: startedAt)
    }

    /// A participant by id, or by a name that only one participant has (models and people type names).
    func resolveParticipant(_ key: String) throws -> CollabParticipant {
        if let p = participants[key] { return p }
        let named = participants.values.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if named.count == 1, let p = named.first { return p }
        throw NibError(.notFound, String(localized: "No participant “\(key)” in this live session."),
                       hint: "call collab.participants for participant ids")
    }

    // MARK: Lifecycle

    func install() {
        transport.onMessage = { [weak self] peer, data in self?.receive(data, from: peer) }
        transport.onPeersChanged = { [weak self] peers in self?.peersChanged(peers) }
        commitSubscription = app.bus.observeCommits { [weak self] cs in self?.committed(cs) }
        eventSubscription = app.events.subscribe { [weak self] e in
            guard e.type == NibEventType.pageChanged || e.type == NibEventType.sessionDocument
                || e.type == NibEventType.sessionActivated else { return }
            CollabSession.onMain { self?.windowsChanged() }
        }
        registryObserver = NotificationCenter.default.addObserver(forName: .nibRegistryDidChange, object: app.commands,
                                                                  queue: nil) { [weak self] _ in
            CollabSession.onMain { self?.refreshViewGuard() }
        }
        service.hooks.presenceSender = { [weak self] payload, to in self?.sendPresence(payload, to: to) ?? false }
    }

    /// Joins as a guest: connect, say hello, and wait until the host admits us and the document is here.
    func join() async throws {
        phase = .connecting
        changed()
        try await transport.join(code: code, displayName: myName)
        guard !isClosed else { throw NibError(.userDenied, String(localized: "You stopped joining.")) }
        let hello = helloMessage()
        try await waitUntilReady(timeout: service.timing.approvalTimeout) { _ = transmit(hello, to: nil) }
    }

    /// Re-joins after the connection dropped, presenting the admission secret (no second approval).
    func rejoin() async throws {
        guard side == .guest, !isClosed else { return }
        phase = .reconnecting
        hostPeer = nil
        changed()
        try await transport.join(code: code, displayName: myName)
        guard !isClosed else { throw NibError(.userDenied, String(localized: "You left the live session.")) }
        let hello = helloMessage()
        try await waitUntilReady(timeout: service.timing.rejoinTimeout) { _ = transmit(hello, to: nil) }
    }

    /// The host advertises again after its connection dropped; admitted guests re-join with their secrets.
    func rehost() async throws {
        guard side == .host, !isClosed else { return }
        for pid in order where pid != me {
            if participants[pid]?.state == .active { participants[pid]?.state = .away }
            unbind(pid)
        }
        try await transport.host(code: code, displayName: myName)
        rosterChanged()
    }

    func markReconnecting() {
        guard side == .guest, !isClosed else { return }
        phase = .reconnecting
        changed()
    }

    /// Ends the session. `notify` tells the others (host: `ended` to everyone; guest: `bye`).
    func end(reason: String?, notify: Bool, error: Error? = nil) {
        guard !isClosed else { return }
        // Closed first, so nothing the others do while they hear about it (leaving, answering) reaches this session.
        isClosed = true
        if notify {
            switch side {
            case .host:
                let m = CollabMessage(kind: .ended, session: id, from: me, reason: reason)
                let everyone = Array(peerOf.values)
                if !everyone.isEmpty { _ = transmit(m, to: everyone) }
            case .guest:
                _ = sendToHost(CollabMessage(kind: .bye, session: id, from: me))
            }
        }
        phase = .ended
        endReason = reason
        transport.onMessage = nil
        transport.onPeersChanged = nil
        transport.leave()
        commitSubscription?.cancel()
        eventSubscription?.cancel()
        if let o = registryObserver { NotificationCenter.default.removeObserver(o) }
        registryObserver = nil
        removeViewGuard()
        restoreReadOnlyWindows()
        service.hooks.presenceSender = nil
        inbox.removeAll()
        resolveReady(error ?? NibError(.unavailable, reason ?? String(localized: "The live session ended.")))
        service.sessionDidEnd(self, reason: reason)
    }

    // MARK: Host actions (collab.approve / setRole / revoke)

    @discardableResult
    func approve(_ pid: String, allow: Bool) throws -> CollabParticipant? {
        try requireHost()
        guard let p = participants[pid] else { throw NibError.notFound("participant \(pid)") }
        guard p.state == .pending else {
            throw NibError(.conflict, String(localized: "\(p.name) is already in the live session."),
                           hint: "call collab.participants")
        }
        service.notifier.clear(participant: pid)
        if allow {
            participants[pid]?.state = .active
            secrets[pid] = CollabSession.makeSecret()
            sendWelcome(pid)
            rosterChanged()
            service.notice(String(localized: "\(p.name) joined the live session."))
            return participants[pid]
        }
        if let peer = peerOf[pid] {
            _ = transmit(CollabMessage(kind: .denied, session: id, from: me,
                                       reason: String(localized: "The host declined your request to join."),
                                       denial: .declined), to: [peer])
            blockedPeers.insert(peer.id)
        }
        drop(pid)
        rosterChanged()
        return nil
    }

    func setRole(_ pid: String, _ role: CollabRole) throws -> CollabParticipant {
        try requireHost()
        guard var p = participants[pid] else { throw NibError.notFound("participant \(pid)") }
        guard !p.isHost else {
            throw NibError(.invalidParams, String(localized: "The host can always edit."), path: "$.participant")
        }
        if role == .edit, p.needsUpdate {
            throw NibError(.unsupported, String(localized: "\(p.name) uses an older Nib that can't edit this document."),
                           hint: "they can edit after updating Nib")
        }
        p.role = role
        participants[pid] = p
        rosterChanged()
        return p
    }

    func revoke(_ pid: String) throws -> CollabParticipant {
        try requireHost()
        guard let p = participants[pid] else { throw NibError.notFound("participant \(pid)") }
        guard !p.isHost else {
            throw NibError(.invalidParams, String(localized: "To stop sharing, end the live session."),
                           path: "$.participant", hint: "call collab.leave")
        }
        if let peer = peerOf[pid] {
            _ = transmit(CollabMessage(kind: .revoked, session: id, from: me,
                                       reason: String(localized: "The host removed you from the live session."),
                                       denial: .removed), to: [peer])
            blockedPeers.insert(peer.id)
        }
        removed.insert(pid)
        drop(pid)
        rosterChanged()
        service.notice(String(localized: "\(p.name) was removed from the live session."))
        return p
    }

    private func requireHost() throws {
        guard side == .host else {
            throw NibError(.permissionDenied, String(localized: "Only the host of the live session can do that."),
                           hint: "call collab.participants to see who hosts")
        }
        guard !isClosed else { throw NibError(.notFound, String(localized: "The live session has ended.")) }
    }

    // MARK: Presence (F108)

    @discardableResult
    func sendPresence(_ payload: JSONValue, to target: String?) -> Bool {
        guard !isClosed, phase == .active else { return false }
        let m = CollabMessage(kind: .presence, session: id, from: me, to: target, payload: payload)
        switch side {
        case .host:
            if let t = target {
                guard t != me, participants[t]?.state == .active else { return false }
                return send(m, to: t)
            }
            broadcast(m, except: nil)
            return true
        case .guest:
            return sendToHost(m)
        }
    }

    // MARK: Receiving

    private func receive(_ data: Data, from peer: CollabPeer) {
        guard !isClosed else { return }
        inbox.append((peer, data))
        // Transports may deliver synchronously from inside our own sends (NibTesting's hub does): queue and drain in
        // order so a reply never runs in the middle of the handler that caused it.
        guard !draining else { return }
        draining = true
        while !inbox.isEmpty, !isClosed {
            let (p, d) = inbox.removeFirst()
            handleFrame(d, from: p)
        }
        draining = false
    }

    private func handleFrame(_ data: Data, from peer: CollabPeer) {
        let message: CollabMessage
        do {
            guard let m = try assembler.feed(data, from: peer.id) else { return }
            message = m
        } catch {
            log.error("collab: dropped a frame from \(peer.id, privacy: .public): \(NibError.wrap(error).message, privacy: .public)")
            return
        }
        // A declined or removed connection may only ask again (a removed participant is then told no).
        if side == .host, blockedPeers.contains(peer.id), message.kind != .hello { return }
        switch side {
        case .host: hostHandle(message, from: peer)
        case .guest: guestHandle(message, from: peer)
        }
    }

    private func hostHandle(_ m: CollabMessage, from peer: CollabPeer) {
        if m.kind == .hello {
            hostHello(m, from: peer)
            return
        }
        // Everything else must come from the participant this peer joined as, in this session.
        guard m.session == id, let pid = participantOf[peer.id], pid == m.from, let p = participants[pid] else { return }
        switch m.kind {
        case .patch:
            // Approval and roles are enforced here: waiting, away and view-only participants never change the document.
            guard p.canEdit, let patch = m.patch else {
                log.info("collab: dropped a patch from \(pid, privacy: .public) (\(p.role.rawValue, privacy: .public))")
                return
            }
            applyRemote(patch, author: pid)
            broadcast(m, except: pid)
        case .sync:
            guard p.state == .active, let digest = m.digest else { return }
            answerSync(digest, to: pid)
        case .needSnapshot:
            guard p.state == .active else { return }
            sendSnapshot(to: pid)
        case .status:
            guard p.state == .active else { return }
            let page = m.status?.page.flatMap { ref -> String? in
                guard case let .page(d, _)? = NodeRef(ref), d == remoteDoc else { return nil }
                return ref
            }
            guard participants[pid]?.page != page else { return }
            participants[pid]?.page = page
            rosterChanged()
        case .presence:
            guard p.state == .active, let payload = m.payload else { return }
            if m.to == nil || m.to == me { service.hooks.publish(.presence(participant: pid, payload: payload)) }
            if let target = m.to {
                if target != me, participants[target]?.state == .active { _ = send(m, to: target) }
            } else {
                broadcast(m, except: pid)
            }
        case .bye:
            secrets[pid] = nil
            drop(pid)
            rosterChanged()
            service.notice(String(localized: "\(p.name) left the live session."))
        default:
            return
        }
    }

    private func hostHello(_ m: CollabMessage, from peer: CollabPeer) {
        let pid = m.from
        guard let hello = m.hello, NibID.isValid(pid), pid != me else { return }
        guard hello.protocolVersion == CollabMessage.protocolVersion else {
            deny(peer, .update, String(localized: "This live session needs the same version of Nib on every device. Update Nib and try again."))
            return
        }
        guard !removed.contains(pid) else {
            deny(peer, .removed, String(localized: "The host removed you from the live session."))
            return
        }
        let name = CollabSession.cleanName(hello.name)
        if let presented = hello.secret, let known = secrets[pid], presented == known, participants[pid] != nil {
            // An admitted participant coming back (suspend, out of range): no second approval.
            if let old = peerOf[pid], old.id != peer.id { participantOf[old.id] = nil }
            bind(pid, peer)
            participants[pid]?.state = .active
            participants[pid]?.name = name
            participants[pid]?.format = hello.format
            sendWelcome(pid)
            rosterChanged()
            return
        }
        if let existing = participants[pid] {
            guard existing.state == .pending else {
                deny(peer, .identity, String(localized: "A device with the same identity is already in this session."))
                return
            }
            bind(pid, peer)
            _ = send(CollabMessage(kind: .pending, session: id, from: me), to: pid)
            return
        }
        guard !CollabGate.isFull(count: participants.count, cap: transport.maxPeers) else {
            deny(peer, .full, CollabGate.fullMessage(cap: transport.maxPeers))
            return
        }
        let editable = CollabGate.canEdit(format: hello.format, documentFormat: documentFormat)
        let p = CollabParticipant(id: pid, name: name, role: editable ? defaultRole : .view, state: .pending, isHost: false,
                                  colorIndex: nextColorIndex(), format: hello.format, needsUpdate: !editable)
        participants[pid] = p
        order.append(pid)
        bind(pid, peer)
        _ = send(CollabMessage(kind: .pending, session: id, from: me), to: pid)
        changed()
        service.joinRequested(p, title: title)
    }

    private func guestHandle(_ m: CollabMessage, from peer: CollabPeer) {
        // Before the host answers, the first pending / welcome / denied names the host; afterwards only it speaks.
        if let h = hostPeer, h.id != peer.id { return }
        switch m.kind {
        case .pending:
            guard phase == .connecting || phase == .reconnecting || phase == .waiting else { return }
            hostPeer = peer
            id = m.session
            phase = .waiting
            changed()
        case .denied:
            guard phase != .active else { return }
            let denial = m.denial ?? .declined
            let reason = m.reason ?? String(localized: "The host declined your request to join.")
            let hint = denial == .full ? "open the document from a shared library folder: folder sync keeps it up to date" : nil
            end(reason: reason, notify: false, error: NibError(denial.errorCode, reason, hint: hint))
        case .welcome:
            guard let w = m.welcome, phase == .connecting || phase == .waiting || phase == .reconnecting else { return }
            welcome(w, roster: m.roster ?? [], session: m.session, from: peer)
        default:
            guard !id.isEmpty, m.session == id, hostPeer != nil else { return }
            switch m.kind {
            case .roster:
                setRoster(m.roster ?? [])
            case .patch:
                guard phase == .active, let patch = m.patch, authorMayEdit(m.from) else { return }
                applyRemote(patch, author: m.from)
            case .syncReply:
                if let patch = m.patch { applyRemote(patch, author: m.from) }
                if let digest = m.digest { sendDelta(against: digest) }
            case .snapshot:
                guard phase == .receiving, let s = m.snapshot else { return }
                receiveSnapshot(s)
            case .presence:
                guard phase == .active, let payload = m.payload else { return }
                service.hooks.publish(.presence(participant: m.from, payload: payload))
            case .revoked:
                let reason = m.reason ?? String(localized: "The host removed you from the live session.")
                end(reason: reason, notify: false, error: NibError(.userDenied, reason))
            case .ended:
                let reason = String(localized: "The host ended the live session.")
                end(reason: reason, notify: false, error: NibError(.unavailable, reason))
            default:
                return
            }
        }
    }

    private func welcome(_ w: CollabMessage.Welcome, roster: [CollabParticipant], session: String, from peer: CollabPeer) {
        id = session
        hostPeer = peer
        hostID = w.hostID
        remoteDoc = w.doc
        title = w.title
        kind = w.kind
        hostName = w.hostName
        myRole = w.role
        secret = w.secret
        documentFormat = w.documentFormat
        setRoster(roster)
        if let local = localDoc ?? service.localDocument(for: w.doc) {
            localDoc = local
            becomeActive()
        } else {
            phase = .receiving
            changed()
            _ = sendToHost(CollabMessage(kind: .needSnapshot, session: id, from: me))
        }
    }

    /// Admitted and the document is here: enforce the role, then catch up both ways (the host answers our digest with
    /// what we lack plus its own digest; we then send what it lacks).
    private func becomeActive() {
        guard let doc = localDoc, !isClosed else { return }
        _ = try? app.workspace.content(doc)
        phase = .active
        applyRoleLocally()
        service.didBecomeActive(self)
        changed()
        resolveReady(nil)
        if let digest = try? digest(of: doc) {
            hasUnsentChanges = !sendToHost(CollabMessage(kind: .sync, session: id, from: me, digest: digest))
        }
        reportPage()
    }

    private func receiveSnapshot(_ s: CollabMessage.Snapshot) {
        let host = hostID ?? ""
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let local = try await self.service.importSnapshot(s, author: host)
                guard !self.isClosed, self.phase == .receiving else { return }
                self.localDoc = local
                self.receivedSnapshot = true
                self.becomeActive()
            } catch {
                let e = NibError.wrap(error)
                self.end(reason: String(localized: "The shared document couldn't be saved: \(e.message)"), notify: true,
                         error: e)
            }
        }
    }

    // MARK: Host internals

    private func bind(_ pid: String, _ peer: CollabPeer) {
        blockedPeers.remove(peer.id)
        if let old = peerOf[pid], old.id != peer.id { participantOf[old.id] = nil }
        peerOf[pid] = peer
        participantOf[peer.id] = pid
    }

    private func unbind(_ pid: String) {
        if let peer = peerOf.removeValue(forKey: pid) {
            participantOf[peer.id] = nil
            assembler.forget(peer: peer.id)
        }
    }

    private func drop(_ pid: String) {
        unbind(pid)
        participants[pid] = nil
        order.removeAll { $0 == pid }
        service.notifier.clear(participant: pid)
    }

    private func deny(_ peer: CollabPeer, _ denial: CollabMessage.Denial, _ reason: String) {
        _ = transmit(CollabMessage(kind: .denied, session: id, from: me, reason: reason, denial: denial), to: [peer])
    }

    private func sendWelcome(_ pid: String) {
        guard let p = participants[pid], let doc = remoteDoc else { return }
        let secret = secrets[pid] ?? CollabSession.makeSecret()
        secrets[pid] = secret
        let w = CollabMessage.Welcome(doc: doc, title: title, kind: kind ?? .notebook, hostName: hostName, hostID: me,
                                      role: p.role, secret: secret, sessionFormat: sessionFormat,
                                      documentFormat: documentFormat, cap: transport.maxPeers, transport: transportKey)
        _ = send(CollabMessage(kind: .welcome, session: id, from: me, welcome: w, roster: publicRoster), to: pid)
    }

    private func answerSync(_ digest: CollabDigest, to pid: String) {
        guard let doc = localDoc, let state = try? documentState(doc) else { return }
        let patch = CollabDigest.delta(content: state.content, items: state.items, against: digest, doc: doc)
        let mine = CollabDigest(content: state.content, items: state.items)
        _ = send(CollabMessage(kind: .syncReply, session: id, from: me, patch: patch.isEmpty ? nil : patch, digest: mine),
                 to: pid)
    }

    private func sendSnapshot(to pid: String) {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let snapshot = try await self.makeSnapshot()
                guard !self.isClosed, self.participants[pid]?.state == .active else { return }
                _ = self.send(CollabMessage(kind: .snapshot, session: self.id, from: self.me, snapshot: snapshot), to: pid)
            } catch {
                let e = NibError.wrap(error)
                self.log.error("collab: snapshot failed: \(e.message, privacy: .public)")
                _ = self.send(CollabMessage(kind: .denied, session: self.id, from: self.me,
                                            reason: String(localized: "The host couldn't send the document: \(e.message)"),
                                            denial: .failed), to: pid)
            }
        }
    }

    /// The zipped package when the library keeps one on disk, else the document's records.
    private func makeSnapshot() async throws -> CollabMessage.Snapshot {
        guard let doc = localDoc else { throw NibError.notFound("shared document") }
        let content = try app.workspace.content(doc)
        app.workspace.persistence.flush(doc)
        if let url = app.services.library?.packageURL(doc), FileManager.default.fileExists(atPath: url.path) {
            let data = try await Task.detached(priority: .userInitiated) { try CollabPackageIO.zip(url) }.value
            return CollabMessage.Snapshot(doc: doc, title: title, kind: content.meta.kind, format: .package, data: data,
                                          content: nil)
        }
        let state = try documentState(doc)
        let items = Dictionary(state.items.map { ($0.key.raw, $0.value) }, uniquingKeysWith: { a, _ in a })
        return CollabMessage.Snapshot(doc: doc, title: title, kind: content.meta.kind, format: .content, data: nil,
                                      content: CollabMessage.SnapshotContent(content: state.content, items: items))
    }

    private func nextColorIndex() -> Int {
        let used = Set(participants.values.map(\.colorIndex))
        let count = NibPresenceColour.hexes.count
        return (0..<count).first { !used.contains($0) } ?? participants.count % count
    }

    private func rosterChanged() {
        if side == .host {
            let m = CollabMessage(kind: .roster, session: id, from: me, roster: publicRoster)
            broadcast(m, except: nil)
        }
        changed()
    }

    // MARK: Guest internals

    private func helloMessage() -> CollabMessage {
        CollabMessage(kind: .hello, session: id, from: me,
                      hello: CollabMessage.Hello(name: myName, format: NibFormat.version,
                                                 protocolVersion: CollabMessage.protocolVersion, secret: secret))
    }

    private func setRoster(_ list: [CollabParticipant]) {
        var unique: [String: CollabParticipant] = [:]
        var ids: [String] = []
        for p in list where unique[p.id] == nil {
            unique[p.id] = p
            ids.append(p.id)
        }
        participants = unique
        order = ids
        if let mine = unique[me], mine.role != myRole {
            let wasActive = phase == .active
            myRole = mine.role
            if wasActive {
                applyRoleLocally()
                service.notice(myRole == .edit ? String(localized: "You can now edit this document.")
                                                : String(localized: "You can now view this document, not edit it."))
            }
        }
        changed()
    }

    private func authorMayEdit(_ author: String) -> Bool {
        author == hostID || participants[author]?.canEdit == true
    }

    private func sendDelta(against digest: CollabDigest) {
        guard side == .guest, myRole == .edit, let doc = localDoc, let remote = remoteDoc,
              let state = try? documentState(doc) else { return }
        let patch = CollabDigest.delta(content: state.content, items: state.items, against: digest, doc: doc)
        hasUnsentChanges = false
        guard !patch.isEmpty else { return }
        let m = CollabMessage(kind: .patch, session: id, from: me, patch: CollabSession.rewrite(patch, to: remote))
        if !sendToHost(m) { hasUnsentChanges = true }
    }

    private func hostLost() {
        switch phase {
        case .active:
            phase = .reconnecting
            changed()
            service.scheduleRejoin()
        case .waiting, .receiving, .connecting:
            let reason = String(localized: "Lost the connection to the host.")
            end(reason: reason, notify: false, error: NibError(.unavailable, reason))
        default:
            return
        }
    }

    // MARK: Both sides

    private func peersChanged(_ peers: [CollabPeer]) {
        guard !isClosed else { return }
        let present = Set(peers.map(\.id))
        switch side {
        case .host:
            var changedAny = false
            for (pid, peer) in peerOf where !present.contains(peer.id) {
                unbind(pid)
                guard let p = participants[pid] else { continue }
                if p.state == .pending {
                    participants[pid] = nil
                    order.removeAll { $0 == pid }
                    service.notifier.clear(participant: pid)
                } else {
                    participants[pid]?.state = .away
                }
                changedAny = true
            }
            if changedAny { rosterChanged() }
        case .guest:
            guard let h = hostPeer, !present.contains(h.id) else { return }
            hostLost()
        }
    }

    /// A local commit: send it (host to everyone, guest to the host), or remember it while disconnected.
    private func committed(_ cs: Changeset) {
        guard !isClosed, let doc = localDoc, let remote = remoteDoc, cs.documents.contains(doc) else { return }
        if case let .sync(origin) = cs.principal, origin.hasPrefix(CollabSession.originPrefix) { return }
        // Locked documents are never sent: locking the shared copy ends the host's session, or takes a guest out.
        if cs.mutations.contains(where: { m in
            if case let .meta(d, before, after) = m { return d == doc && after.locked && !before.locked }
            return false
        }) {
            service.endSession(reason: side == .host
                ? String(localized: "The document was locked, so the live session ended.")
                : String(localized: "You locked your copy, so you left the live session."))
            return
        }
        guard side == .host || myRole == .edit else { return }
        let patch = CollabSession.rewrite(cs.patch(for: doc), to: remote)
        guard !patch.isEmpty else { return }
        guard phase == .active else {
            hasUnsentChanges = true
            return
        }
        let m = CollabMessage(kind: .patch, session: id, from: me, patch: patch)
        if side == .host {
            broadcast(m, except: nil)
        } else if !sendToHost(m) {
            hasUnsentChanges = true
        }
    }

    private func applyRemote(_ patch: DocumentPatch, author: String) {
        guard let doc = localDoc else { return }
        // A collaborator's patch must land even when no window shows the document.
        _ = try? app.workspace.content(doc)
        var local = CollabSession.rewrite(patch, to: doc)
        if let meta = local.meta, let current = try? app.workspace.content(doc).meta {
            local.meta = CollabSession.keepingLocalFields(meta, of: current)
        }
        let summary = app.bus.applyRemote(local, origin: CollabSession.originPrefix + author)
        guard !summary.isEmpty else { return }
        let pages = Set(local.items.keys.map { PageID($0) })
        service.hooks.publish(.remoteChanges(participant: author, doc: doc, summary: summary, pages: pages))
    }

    /// The page this device looks at, reported to everyone ("Participants with names, pages and roles").
    private func windowsChanged() {
        guard !isClosed else { return }
        if side == .guest, myRole == .view, phase == .active { setReadOnlyWindows() }
        reportPage()
    }

    private func reportPage() {
        guard phase == .active, let doc = localDoc, let remote = remoteDoc else { return }
        let active = app.services.sessions.active
        let page = active?.document == doc ? active?.page.map { NodeRef.page(remote, $0).description } : nil
        if let last = lastPage, last == page { return }
        lastPage = .some(page)
        if side == .host {
            participants[me]?.page = page
            rosterChanged()
        } else {
            _ = sendToHost(CollabMessage(kind: .status, session: id, from: me, status: CollabMessage.Status(page: page)))
        }
    }

    private func digest(of doc: DocumentID) throws -> CollabDigest {
        let state = try documentState(doc)
        return CollabDigest(content: state.content, items: state.items)
    }

    private func documentState(_ doc: DocumentID) throws -> (content: DocumentContent, items: [PageID: [Item]]) {
        let content = try app.workspace.content(doc)
        var items: [PageID: [Item]] = [:]
        for p in content.pages { items[p.id] = try app.workspace.allItems(doc, page: p.id) }
        return (content, items)
    }

    private func changed() {
        service.sessionChanged(self)
    }

    // MARK: Sending

    @discardableResult
    private func transmit(_ m: CollabMessage, to peers: [CollabPeer]?) -> Bool {
        do {
            for frame in try CollabFrames.frames(for: m) { try transport.send(frame, to: peers) }
            return true
        } catch {
            log.error("collab: send failed: \(NibError.wrap(error).message, privacy: .public)")
            return false
        }
    }

    private func send(_ m: CollabMessage, to pid: String) -> Bool {
        guard let peer = peerOf[pid] else { return false }
        return transmit(m, to: [peer])
    }

    private func sendToHost(_ m: CollabMessage) -> Bool {
        guard let h = hostPeer else { return false }
        return transmit(m, to: [h])
    }

    private func broadcast(_ m: CollabMessage, except: String?) {
        let targets = order.compactMap { pid -> CollabPeer? in
            guard pid != me, pid != except, participants[pid]?.state == .active else { return nil }
            return peerOf[pid]
        }
        guard !targets.isEmpty else { return }
        transmit(m, to: targets)
    }

    // MARK: Ready

    private func waitUntilReady(timeout: TimeInterval, after start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiter?.resume(throwing: NibError(.conflict, String(localized: "Joining started again.")))
            readyWaiter = continuation
            readyTimer?.cancel()
            readyTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.timedOut()
            }
            start()
        }
    }

    private func timedOut() {
        guard readyWaiter != nil, !isClosed else { return }
        if phase == .reconnecting {
            resolveReady(NibError(.timeout, String(localized: "The host didn't answer.")))
            return
        }
        let reason = phase == .waiting ? String(localized: "The host didn't answer your request to join.")
                                       : String(localized: "The live session didn't answer.")
        end(reason: reason, notify: true, error: NibError(.timeout, reason, hint: "ask the host to approve you, then try again"))
    }

    private func resolveReady(_ error: Error?) {
        readyTimer?.cancel()
        readyTimer = nil
        guard let waiter = readyWaiter else { return }
        readyWaiter = nil
        if let error = error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    // MARK: View-only enforcement (guest)

    private func applyRoleLocally() {
        guard side == .guest else { return }
        if myRole == .view {
            refreshViewGuard()
            setReadOnlyWindows()
        } else {
            removeViewGuard()
            restoreReadOnlyWindows()
        }
    }

    /// A command hook over every namespace (refreshed when commands are registered) that vetoes document edits of the
    /// shared copy from any caller while this device may only view it.
    private func refreshViewGuard() {
        guard !isClosed, side == .guest, myRole == .view, localDoc != nil else {
            removeViewGuard()
            return
        }
        let namespaces = app.commands.all().compactMap { d -> String? in
            d.id.split(separator: ".").first.map { String($0) + ".*" }
        }
        let patterns: [String] = Set(namespaces).sorted()
        guard patterns != guardPatterns || app.bus.hooks.get(CollabSession.viewGuardID) == nil else { return }
        guardPatterns = patterns
        app.bus.hooks.register(CommandHookDescriptor.guarding(id: CollabSession.viewGuardID, owner: FeatCollabFeature.id,
                                                              commands: patterns) { [weak self] command, params, ctx in
            try self?.vetoIfViewOnly(command: command, params: params, ctx: ctx)
            return nil
        })
    }

    private func removeViewGuard() {
        guard app.bus.hooks.get(CollabSession.viewGuardID) != nil else { return }
        app.bus.hooks.unregister(id: CollabSession.viewGuardID)
        guardPatterns = []
    }

    private func vetoIfViewOnly(command: String, params: JSONValue, ctx: CommandContext) throws {
        guard !isClosed, side == .guest, myRole == .view, let doc = localDoc else { return }
        let window = ctx.activeSession
        if command == CommandIDs.viewSetReadOnly, window?.document == doc {
            let turnsOff = params["on"]?.boolValue.map { !$0 } ?? (window?.readOnly == true)
            guard turnsOff else { return }
            throw NibError(.permissionDenied, String(localized: "The host of the live session gave you view access, so this document stays read-only."),
                           hint: "ask the host to change your role with collab.setRole")
        }
        guard let d = app.commands.descriptor(command), d.target == .document,
              d.effect == .edit || d.effect == .irreversible else { return }
        guard CollabGuard.touches(params, doc: doc, sessionDocument: window?.document) else { return }
        throw NibError(.permissionDenied, String(localized: "You can view this document but not edit it: the host of the live session gave you view access."),
                       hint: "ask the host to change your role with collab.setRole")
    }

    /// Windows showing the shared copy enter read-only mode (F042's `view.setReadOnly` when installed).
    private func setReadOnlyWindows() {
        guard let doc = localDoc else { return }
        for s in app.services.sessions.sessions where s.document == doc && !s.readOnly && !readOnlySessions.contains(s.id) {
            readOnlySessions.append(s.id)
            setReadOnly(s, true)
        }
    }

    private func restoreReadOnlyWindows() {
        let ids = readOnlySessions
        readOnlySessions = []
        for id in ids {
            guard let s = app.services.sessions.session(id), s.readOnly else { continue }
            setReadOnly(s, false)
        }
    }

    private func setReadOnly(_ s: EditorSession, _ on: Bool) {
        guard app.commands.entry(CommandIDs.viewSetReadOnly) != nil else {
            s.readOnly = on
            return
        }
        let bus = app.bus
        Task { @MainActor in
            _ = try? await bus.execute(Invocation(command: CommandIDs.viewSetReadOnly, params: ["on": .bool(on)],
                                                  principal: .user, session: s))
        }
    }

    // MARK: Helpers

    /// The patch as addressed to `doc` (the host's id on the wire, this library's id locally); the meta record carries
    /// the document id too.
    static func rewrite(_ patch: DocumentPatch, to doc: DocumentID) -> DocumentPatch {
        var p = patch
        p.doc = doc
        p.meta?.id = doc
        return p
    }

    /// A collaborator's document meta with this library's own settings kept: favourite, the password lock (a lock is
    /// per device), where it was trashed from and its external source file are not the collaborator's to change.
    static func keepingLocalFields(_ incoming: DocumentMeta, of current: DocumentMeta) -> DocumentMeta {
        var m = incoming
        m.favorite = current.favorite
        m.locked = current.locked
        m.trashedFrom = current.trashedFrom
        m.sourceBookmark = current.sourceBookmark
        return m
    }

    /// The same for a document arriving in this library for the first time.
    static func receivedMeta(_ incoming: DocumentMeta) -> DocumentMeta {
        var m = incoming
        m.favorite = false
        m.locked = false
        m.trashedFrom = nil
        m.sourceBookmark = nil
        return m
    }

    static func makeSecret() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    /// A display name from the wire: one line, at most 40 characters.
    static func cleanName(_ raw: String) -> String {
        let line = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let name = String(line.prefix(40))
        return name.isEmpty ? String(localized: "Guest") : name
    }

    /// Runs `body` on the main actor now when already on main, else on the main queue.
    nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}

// MARK: - Service

/// What the UI shows: the session (if any), its roster and the last notice.
struct CollabState: Equatable {
    var session: CollabSessionInfo?
    var participants: [CollabParticipant] = []
    /// Why the last session ended, or what went wrong.
    var message: String?

    var pending: [CollabParticipant] { participants.filter { $0.state == .pending } }
    var admitted: [CollabParticipant] { participants.filter { $0.state != .pending } }
}

/// Sends local notifications for join requests while Nib is in the background (P-090: local only, no APNs).
@MainActor
protocol CollabNotifier: AnyObject {
    func joinRequest(participant: String, name: String, title: String)
    func clear(participant: String)
}

/// One per app: runs the current live session, resolves transports, re-joins after a suspend and publishes state.
@MainActor
final class CollabService: ObservableObject {
    static let serviceKey = "collab.service"

    static func of(_ app: NibApp) -> CollabService? { app.services.get(serviceKey, as: CollabService.self) }

    unowned let app: NibApp
    let hooks: CollabHooks
    var notifier: CollabNotifier
    var timing = CollabTiming()
    @Published private(set) var state = CollabState()
    private(set) var session: CollabSession?
    private var rejoinTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var lifecycle: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "app.nib", category: "collab")

    init(app: NibApp, hooks: CollabHooks, notifier: CollabNotifier) {
        self.app = app
        self.hooks = hooks
        self.notifier = notifier
    }

    /// This device's participant id.
    var myID: String { app.deviceHex }

    /// The author name (Settings › Profile), else the device's name.
    var myName: String {
        let name = app.settings.get(NibSettings.authorName).trimmingCharacters(in: .whitespacesAndNewlines)
        return CollabSession.cleanName(name.isEmpty ? UIDevice.current.name : name)
    }

    /// True when the internet relay (F092) is installed.
    var relayAvailable: Bool { app.services.get(ServiceKeys.collabRelay, as: CollabTransport.self) != nil }

    /// Most people a session over `key` takes, the host included (8 nearby, the relay's own cap).
    func capacity(_ key: String) -> Int {
        (try? resolveTransport(key))?.transport.maxPeers ?? MultipeerTransport.cap
    }

    func resolveTransport(_ key: String?) throws -> (key: String, transport: CollabTransport) {
        let name = (key ?? "multipeer").lowercased()
        let serviceKey: String
        switch name {
        case "multipeer", "nearby":
            serviceKey = ServiceKeys.collabMultipeer
        case "relay", "internet":
            serviceKey = ServiceKeys.collabRelay
        default:
            throw NibError(.invalidParams, "unknown transport '\(name)'", path: "$.transport", hint: "use multipeer or relay")
        }
        guard let transport = app.services.get(serviceKey, as: CollabTransport.self) else {
            if serviceKey == ServiceKeys.collabRelay {
                throw NibError(.unavailable, String(localized: "The internet relay isn't set up."),
                               hint: "set the relay URL with relay.configure and enter its token in Settings")
            }
            throw NibError.unavailable("nearby collaboration")
        }
        return (serviceKey == ServiceKeys.collabRelay ? "relay" : "multipeer", transport)
    }

    // MARK: Host and join

    func host(doc: DocumentID, transportKey: String?, role: CollabRole) async throws -> CollabSession {
        if let s = session, !s.isClosed {
            if s.side == .host, s.localDoc == doc { return s }
            throw NibError(.conflict, String(localized: "Another live session is running. Leave it before starting a new one."),
                           hint: "call collab.leave")
        }
        let content = try app.workspace.content(doc)
        if content.meta.locked || (app.services.lock?.isLocked(doc) ?? false) {
            throw NibError(.locked, String(localized: "Locked documents can't be shared live."),
                           hint: "remove the password lock first")
        }
        if app.isReadOnly(doc) || content.meta.format > NibFormat.version {
            throw NibError(.unsupported, String(localized: "This document was saved by a newer Nib, so this device can't share it live."))
        }
        let (key, transport) = try resolveTransport(transportKey)
        let title = app.services.library?.node(doc)?.title ?? String(localized: "Untitled")
        let s = CollabSession(hosting: doc, content: content, title: title, code: CollabCode.generate(), transportKey: key,
                              transport: transport, defaultRole: role, service: self, me: myID, name: myName)
        session = s
        state.message = nil
        s.install()
        do {
            try await transport.host(code: s.code, displayName: myName)
        } catch {
            s.end(reason: nil, notify: false)
            throw NibError.wrap(error)
        }
        refresh()
        return s
    }

    /// Joins (or, for the same code after a dropped connection, re-joins) a session. Returns the session and whether
    /// it is a fresh join.
    func join(code raw: String, transportKey: String?) async throws -> (session: CollabSession, fresh: Bool) {
        guard let code = CollabCode.normalize(raw) else {
            throw NibError(.invalidParams, String(localized: "“\(raw)” isn't a join code."), path: "$.code",
                           hint: "a join code has 6 letters and digits, e.g. K7M2QX")
        }
        if let s = session, !s.isClosed {
            if s.side == .guest, s.code == code {
                if s.phase == .active, s.isConnectedToHost { return (s, false) }
                rejoinTask?.cancel()
                rejoinTask = nil
                try await s.rejoin()
                return (s, false)
            }
            throw NibError(.conflict, String(localized: "Another live session is running. Leave it before joining this one."),
                           hint: "call collab.leave")
        }
        let (key, transport) = try resolveTransport(transportKey)
        let s = CollabSession(joining: code, transportKey: key, transport: transport, service: self, me: myID, name: myName)
        session = s
        state.message = nil
        s.install()
        do {
            try await s.join()
        } catch {
            var e = NibError.wrap(error)
            if e.code == .unavailable, e.message.lowercased().contains("full") {
                e = NibError(.unavailable, CollabGate.fullMessage(cap: transport.maxPeers),
                             hint: "open the document from a shared library folder: folder sync keeps it up to date")
            }
            if !s.isClosed { s.end(reason: nil, notify: true, error: e) }
            throw e
        }
        return (s, true)
    }

    /// Leaves (guest) or ends (host) the session. False when there was none.
    @discardableResult
    func leave() -> (left: Bool, wasHost: Bool) {
        rejoinTask?.cancel()
        rejoinTask = nil
        guard let s = session, !s.isClosed else {
            session = nil
            refresh()
            return (false, false)
        }
        let wasHost = s.side == .host
        s.end(reason: nil, notify: true, error: NibError(.userDenied, String(localized: "You left the live session.")))
        return (true, wasHost)
    }

    func endSession(reason: String) {
        session?.end(reason: reason, notify: true)
    }

    // MARK: Suspend and re-join

    func didEnterBackground() {
        backgroundedAt = Date()
    }

    /// Back in the foreground: a guest whose host is gone re-joins with the same code and catches up; a host whose
    /// connection dropped advertises again.
    func resumeAfterSuspend() async {
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        guard let s = session, !s.isClosed else { return }
        switch s.side {
        case .guest:
            guard s.phase == .reconnecting || !s.isConnectedToHost || away >= timing.suspendThreshold else { return }
            rejoinTask?.cancel()
            rejoinTask = nil
            s.markReconnecting()
            await runRejoin([0] + timing.retryDelays)
        case .host:
            guard away >= timing.suspendThreshold || (s.transport.peers.isEmpty && s.hasAdmittedGuests) else { return }
            do {
                try await s.rehost()
            } catch {
                let e = NibError.wrap(error)
                s.end(reason: String(localized: "The live session couldn't restart: \(e.message)"), notify: false)
            }
        }
    }

    func scheduleRejoin() {
        guard rejoinTask == nil, let s = session, s.side == .guest, !s.isClosed else { return }
        let delays = timing.retryDelays
        rejoinTask = Task { [weak self] in
            await self?.runRejoin(delays)
            self?.rejoinTask = nil
        }
    }

    /// Tries to re-join after each delay; when every attempt fails, the session ends and folder sync takes over.
    private func runRejoin(_ delays: [TimeInterval]) async {
        for delay in delays {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if Task.isCancelled { return }
            guard let s = session, s.side == .guest, !s.isClosed else { return }
            if s.phase == .active, s.isConnectedToHost { return }
            do {
                try await s.rejoin()
                return
            } catch let e as NibError where e.code == .userDenied || e.code == .unsupported {
                if !s.isClosed { s.end(reason: e.message, notify: false, error: e) }
                return
            } catch {
                log.info("collab: re-join attempt failed: \(NibError.wrap(error).message, privacy: .public)")
            }
        }
        guard let s = session, s.side == .guest, !s.isClosed, !(s.phase == .active && s.isConnectedToHost) else { return }
        let reason = String(localized: "Couldn't reconnect to the live session. Your copy stays in the library, and changes arrive through folder sync.")
        s.end(reason: reason, notify: false, error: NibError(.unavailable, reason))
        if app.commands.entry(CommandIDs.syncNow) != nil {
            _ = try? await app.bus.execute(Invocation(command: CommandIDs.syncNow, principal: .user))
        }
    }

    func startLifecycle() {
        guard lifecycle.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycle.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        lifecycle.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                Task { await self.resumeAfterSuspend() }
            }
        })
    }

    // MARK: From the session

    func sessionChanged(_ s: CollabSession) {
        guard s === session else { return }
        refresh()
    }

    func sessionDidEnd(_ s: CollabSession, reason: String?) {
        guard s === session else { return }
        session = nil
        rejoinTask?.cancel()
        rejoinTask = nil
        state.message = reason
        refresh()
        if let reason = reason { notice(reason) }
    }

    func joinRequested(_ p: CollabParticipant, title: String) {
        notifier.joinRequest(participant: p.id, name: p.name, title: title)
        // Document windows show the request HUD; a library window gets a toast with Approve.
        if let navigator = app.ui.activeNavigator, navigator.activeDocument == nil {
            let pid = p.id
            navigator.floatingHost?.postToast(String(localized: "\(p.name) wants to join “\(title)”."),
                                              actionTitle: String(localized: "Approve"),
                                              action: { [weak self] in self?.approveFromToast(pid) })
        }
        app.events.emit(CollabIDs.event, doc: session?.localDoc,
                        payload: ["event": "request", "participant": .string(p.id), "name": .string(p.name)])
    }

    private func approveFromToast(_ participant: String) {
        let app = self.app
        Task { @MainActor [weak self] in
            do {
                _ = try await app.bus.execute(Invocation(command: CommandIDs.collabApprove,
                                                         params: ["participant": .string(participant), "allow": true],
                                                         principal: .user, session: app.services.sessions.active))
            } catch {
                self?.notice(NibError.wrap(error).message)
            }
        }
    }

    func didBecomeActive(_ s: CollabSession) {
        guard let local = s.localDoc, let remote = s.remoteDoc else { return }
        rememberShared(local: local, remote: remote, role: "guest", title: s.title, code: s.code)
    }

    /// A toast in the active window (P-090 in-app messages).
    func notice(_ message: String) {
        app.ui.activeNavigator?.floatingHost?.postToast(message)
    }

    /// This library's copy of the host's document: a copy received earlier, or the same document (folder sync).
    func localDocument(for remote: DocumentID) -> DocumentID? {
        if let record = sharedRecord(remote), exists(record.local) { return record.local }
        return exists(remote) ? remote : nil
    }

    private func exists(_ doc: DocumentID) -> Bool {
        if let library = app.services.library {
            guard let node = library.node(doc) else { return false }
            return node.kind == .document && node.trashedAt == nil
        }
        return (try? app.workspace.peekContent(doc)) != nil
    }

    func refresh() {
        let info = session.map { $0.info }
        let roster = session?.roster ?? []
        let previous = state
        var next = state
        next.session = info
        next.participants = roster
        if next != previous {
            state = next
            let phaseChanged = info?.phase != previous.session?.phase || (info == nil) != (previous.session == nil)
            let peopleChanged = previous.participants.map { "\($0.id):\($0.state.rawValue):\($0.role.rawValue)" }
                != roster.map { "\($0.id):\($0.state.rawValue):\($0.role.rawValue)" }
            if phaseChanged || peopleChanged {
                app.events.emit(CollabIDs.event, doc: info?.doc,
                                payload: ["event": "session", "phase": .string(info?.phase.rawValue ?? CollabPhase.idle.rawValue),
                                          "participants": .number(Double(roster.count))])
            }
        }
        hooks.update(session: info, participants: roster)
        app.ui.setNeedsChromeUpdate()
    }
}

/// Ids the module shares between its files.
enum CollabIDs {
    static let sharePanel = "collab.share"
    static let joinPanel = "collab.join"
    static let requestOverlay = "collab.request"
    static let shareKey = "collab.shareLive"
    static let joinKey = "collab.joinLive"
    /// Event emitted on session changes and join requests (plugins, the bridge's long poll).
    static let event = "collab.session"
}
