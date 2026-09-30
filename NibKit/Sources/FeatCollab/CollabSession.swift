import Foundation
import CryptoKit
import CommonCrypto
import Compression
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
//   a snapshot diff: each side sends a digest (record id → revision, plus the files it holds) and gets back the
//   records and files it lacks or holds older.
// - Files (images, PDF and image backgrounds, text attachments, card images, audio) travel as raw blobs ahead of the
//   records that need them; joiners without the document receive the zipped package the same way into a "Shared"
//   folder. Blobs are streamed from and to disk in batches off the main actor.

// MARK: - Join codes

/// Six-character join codes from an alphabet without look-alikes (no 0/O, 1/I/L), shown as "K7M 2QX".
enum CollabCode {
    static let alphabet: [Character] = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let length = 6
    /// PBKDF2 rounds of the key a Multipeer advertisement and invitation derive from: each guess of the code costs a
    /// slow hash, so what a nearby device overhears can't be matched against all 31^6 codes in seconds.
    static let rounds: UInt32 = 20_000

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

    /// What the QR code carries (the deep link F074 routes to the join sheet).
    static func joinURL(_ code: String) -> String { "\(NibFormat.urlScheme)://collab/join?code=\(code)" }

    /// A fresh random salt per hosted session, advertised in the clear next to the discovery tag.
    static func makeSalt() -> String {
        var rng = SystemRandomNumberGenerator()
        return hex((0..<12).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// The slow key both sides derive from the code and the session's salt (PBKDF2-SHA256).
    static func sessionKey(_ code: String, salt: String) -> SymmetricKey {
        let length = 32
        var out = [UInt8](repeating: 0, count: length)
        let saltBytes = [UInt8](("nib-collab/" + salt).utf8)
        let saltCount = saltBytes.count
        let password = "nib-collab/" + code
        let status = password.withCString { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p, strlen(p), saltBytes, saltCount,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, length)
        }
        if status != 0 { out = Array(SHA256.hash(data: Data((password + "/" + salt).utf8))) }
        return SymmetricKey(data: out)
    }

    /// Advertised instead of the code: matches only for someone who knows the code (and pays the slow hash).
    static func discoveryTag(key: SymmetricKey) -> String { String(mac(key, "discover").prefix(16)) }

    /// Sent with a Multipeer invitation: proves the joiner knows the code, bound to the joiner's own peer name so a
    /// proof overheard on the network is no use to another device.
    static func joinProof(key: SymmetricKey, peer: String) -> String { mac(key, "join/" + peer) }

    /// Compares two proofs or secrets in constant time.
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return Swift.zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func mac(_ key: SymmetricKey, _ text: String) -> String {
        hex(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
    }
}

// MARK: - Gating and caps (S-100, S-101)

enum CollabGate {
    /// The oldest admitted participant's `NibFormat.version` (shown to F108 and the UI).
    static func effectiveFormat(_ participants: [CollabParticipant]) -> Int {
        participants.filter { $0.state != .pending }.map(\.format).min() ?? NibFormat.version
    }

    /// The newest format in the session: the host's own and every admitted participant's. A record the newest Nib
    /// wrote may hold fields an older Nib drops when it rewrites the record (decoding is lenient), and last writer
    /// wins would spread that loss, so only participants at this format edit.
    static func newestFormat(host: Int, participants: [CollabParticipant]) -> Int {
        participants.filter { !$0.isHost && $0.state != .pending }.map(\.format).reduce(host, max)
    }

    /// A participant whose Nib is older than the newest one in the session can view but not edit.
    static func canEdit(format: Int, newest: Int) -> Bool { format >= newest }

    /// True when one more participant would pass the transport's cap (the host counts).
    static func isFull(count: Int, cap: Int) -> Bool { count >= cap }

    static let fullHint = "open the document from a shared library folder: folder sync keeps it up to date"

    /// The folder-sync fallback past the cap.
    static func fullMessage(cap: Int) -> String {
        String(localized: "This live session is full (\(cap) people). Open the document from a shared library folder instead: folder sync keeps it up to date.")
    }

    /// What a joiner reports when the session is full (the host's `denied .full`, or a transport that advertises it).
    static func fullError(cap: Int) -> NibError { NibError(.unavailable, fullMessage(cap: cap), hint: fullHint) }
}

// MARK: - Files the records point at

/// The files a document's records reference: content-addressed assets ("<hash>.<ext>" in the package's assets folder)
/// and package files ("audio/<id>.m4a"). Live sync sends the bytes a peer lacks ahead of the records that need them.
enum CollabAssets {
    /// Largest asset or package file accepted live (512 MB).
    static let maxBytes = 512 * 1_048_576

    /// Every file the live records of `patch` reference: page backgrounds, item assets (images, tape patterns, display
    /// ops, inline text attachments), text-document blocks, study-card faces and audio clips.
    static func names(in patch: DocumentPatch) -> Set<String> {
        var out = Set<String>()
        func add(_ ref: AssetRef?) {
            if let r = ref, isAssetName(r.name) { out.insert(r.name) }
        }
        func rich(_ text: RichText?) {
            guard let text = text else { return }
            for paragraph in text.paragraphs {
                for run in paragraph.runs { add(run.attrs.attachment) }
            }
        }
        for p in patch.pages where !p.deleted { add(p.background.asset) }
        for list in patch.items.values {
            for item in list where !item.deleted {
                for ref in NibFragment.assetRefs(item) { add(ref) }
            }
        }
        for b in patch.blocks where !b.deleted {
            add(b.asset)
            rich(b.text)
            rich(b.caption)
            for row in b.table?.rows ?? [] {
                for cell in row { rich(cell.text) }
            }
            for op in b.custom?.display.ops ?? [] { add(op.asset) }
        }
        for c in patch.cards where !c.deleted {
            for face in [c.front, c.back] {
                add(face.asset)
                rich(face.text)
            }
        }
        for a in patch.audio where !a.deleted && isPackageFile(a.file) { out.insert(a.file) }
        return out
    }

    /// Every file a whole document references.
    static func names(content: DocumentContent, items: [PageID: [Item]]) -> Set<String> {
        var patch = DocumentPatch(doc: content.meta.id, pages: content.pages, blocks: content.blocks, cards: content.cards,
                                  audio: content.audio)
        patch.items = Dictionary(items.map { ($0.key.raw, $0.value) }, uniquingKeysWith: { a, _ in a })
        return names(in: patch)
    }

    /// "<name>.<ext>": letters, digits, "-" and "_", one dot, an extension of at most 8 letters and digits; never a
    /// path.
    static func isAssetName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...128).contains(parts[0].count), (1...8).contains(parts[1].count) else { return false }
        return parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// "audio/<name>.<ext>" inside the package.
    static func isPackageFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "audio" else { return false }
        return isAssetName(String(parts[1]))
    }

    /// The SHA-256 a content-addressed name carries ("<64 hex>.<ext>"), nil for names from another scheme.
    static func sha256Stem(_ name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        return stem.count == 64 && stem.allSatisfy(\.isHexDigit) ? stem : nil
    }
}

// MARK: - Digests (snapshot diff)

/// Every record of a document by id with its revision, and the files it holds: what a participant has. Two digests
/// give what each side lacks, so a re-join after a suspend exchanges only what changed while the connection was down.
struct CollabDigest: Codable, Equatable {
    var meta: Rev?
    var pages: [String: Rev]
    var outline: [String: Rev]
    var blocks: [String: Rev]
    var cards: [String: Rev]
    var audio: [String: Rev]
    /// Page id → item id → revision (tombstones included).
    var items: [String: [String: Rev]]
    /// Asset names and package files this side holds (see `CollabAssets`).
    var assets: [String]

    init(meta: Rev? = nil, pages: [String: Rev] = [:], outline: [String: Rev] = [:], blocks: [String: Rev] = [:],
         cards: [String: Rev] = [:], audio: [String: Rev] = [:], items: [String: [String: Rev]] = [:],
         assets: [String] = []) {
        self.meta = meta
        self.pages = pages
        self.outline = outline
        self.blocks = blocks
        self.cards = cards
        self.audio = audio
        self.items = items
        self.assets = assets
    }

    init(content: DocumentContent, items pageItems: [PageID: [Item]], assets: [String] = []) {
        func table<T: LWWRecord>(_ records: [T]) -> [String: Rev] {
            Dictionary(records.map { ($0.id.raw, $0.rev) }, uniquingKeysWith: { max($0, $1) })
        }
        self.init(meta: content.meta.rev, pages: table(content.pages), outline: table(content.outline),
                  blocks: table(content.blocks), cards: table(content.cards), audio: table(content.audio),
                  items: Dictionary(pageItems.map { ($0.key.raw, table($0.value)) }, uniquingKeysWith: { a, _ in a }),
                  assets: assets)
    }

    enum CodingKeys: String, CodingKey { case meta, pages, outline, blocks, cards, audio, items, assets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decodeIfPresent(Rev.self, forKey: .meta)
        pages = try c.decodeIfPresent([String: Rev].self, forKey: .pages) ?? [:]
        outline = try c.decodeIfPresent([String: Rev].self, forKey: .outline) ?? [:]
        blocks = try c.decodeIfPresent([String: Rev].self, forKey: .blocks) ?? [:]
        cards = try c.decodeIfPresent([String: Rev].self, forKey: .cards) ?? [:]
        audio = try c.decodeIfPresent([String: Rev].self, forKey: .audio) ?? [:]
        items = try c.decodeIfPresent([String: [String: Rev]].self, forKey: .items) ?? [:]
        assets = try c.decodeIfPresent([String].self, forKey: .assets) ?? []
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
        case hello, pending, welcome, denied, roster, patch, sync, syncReply, needSnapshot, snapshot, asset, revoked,
             ended, bye, status, presence, unknown

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
        /// Issued at admission and kept on the device; a re-join that presents it skips approval.
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
        /// The zipped `.nibnote` package (assets and audio included), sent as a blob.
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
        var content: SnapshotContent?
    }

    struct Status: Codable {
        /// The page the sender looks at, in host ids ("page:D/P").
        var page: String?
    }

    /// Raw bytes that follow this message as blob frames (never JSON, never compressed): a package snapshot or a file.
    struct Blob: Codable, Equatable {
        /// 32 hex characters, the id its frames carry.
        var id: String
        var bytes: Int
        var sha256: String
    }

    /// A file that follows as a blob.
    struct Asset: Codable, Equatable {
        /// An asset name ("<hash>.<ext>") or a package file ("audio/<id>.m4a").
        var name: String
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
    var blob: Blob? = nil
    var asset: Asset? = nil
}

// MARK: - Frames

/// Messages on the wire: JSON (stroke points as compact Float32), LZFSE-compressed past 1 KB, split into frames of at
/// most 60 KB so every transport (Multipeer, a WebSocket relay) carries them. Package snapshots and files travel as
/// blobs instead: a small JSON header message, then raw frames straight from and to disk (never base64, never
/// compressed again).
///
/// Frame: "N", format 2, flags (bit 0 compressed, bit 1 part, bit 2 blob), then
/// - a whole message: [big-endian UInt32 uncompressed length when compressed] body;
/// - a message part: 16-byte message id, UInt32 index, UInt32 count, UInt32 uncompressed length, its slice of the body;
/// - a blob part: 16-byte blob id, UInt32 index, UInt32 count, its slice of the bytes.
enum CollabFrames {
    static let magic: UInt8 = 0x4E
    static let formatVersion: UInt8 = 2
    static let compressedFlag: UInt8 = 1
    static let partFlag: UInt8 = 2
    static let blobFlag: UInt8 = 4
    static let maxFrameBytes = 60 * 1024
    static let compressionThreshold = 1024
    static let prefixBytes = 3
    static let partHeaderBytes = prefixBytes + 16 + 4 + 4 + 4
    static let blobHeaderBytes = prefixBytes + 16 + 4 + 4
    /// Bytes of a blob in one frame.
    static let blobChunk = maxFrameBytes - blobHeaderBytes
    /// Blob frames read from disk per hop to the main actor (about 2 MB).
    static let blobBatch = 32
    /// Largest JSON message, uncompressed (128 MB).
    static let maxMessageBytes = 128 * 1_048_576
    /// Largest blob (a package snapshot, 1 GB).
    static let maxBlobBytes = 1 << 30

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.userInfo[.nibCompactPoints] = true
        return e
    }

    static func tooLarge() -> NibError {
        NibError(.unsupported, String(localized: "This document is too large to share live."),
                 hint: "share it through a synced library folder instead")
    }

    static func damaged() -> NibError { NibError.invalid("damaged collaboration frame") }

    static func frames(for message: CollabMessage) throws -> [Data] {
        let json = try makeEncoder().encode(message)
        guard json.count <= maxMessageBytes else { throw tooLarge() }
        var body = json
        var flags: UInt8 = 0
        if json.count > compressionThreshold, let packed = compress(json) {
            body = packed
            flags |= compressedFlag
        }
        let lengthBytes = flags & compressedFlag != 0 ? 4 : 0
        if prefixBytes + lengthBytes + body.count <= maxFrameBytes {
            var frame = Data(capacity: prefixBytes + lengthBytes + body.count)
            frame.append(contentsOf: [magic, formatVersion, flags])
            if lengthBytes > 0 { frame.append(contentsOf: bigEndian(UInt32(json.count))) }
            frame.append(body)
            return [frame]
        }
        let chunk = maxFrameBytes - partHeaderBytes
        let count = (body.count + chunk - 1) / chunk
        let idBytes = CollabBlobIO.newID()
        var frames: [Data] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            let start = body.startIndex + i * chunk
            let end = min(start + chunk, body.endIndex)
            var frame = Data(capacity: partHeaderBytes + end - start)
            frame.append(contentsOf: [magic, formatVersion, flags | partFlag])
            frame.append(idBytes)
            frame.append(contentsOf: bigEndian(UInt32(i)))
            frame.append(contentsOf: bigEndian(UInt32(count)))
            frame.append(contentsOf: bigEndian(UInt32(json.count)))
            frame.append(body.subdata(in: start..<end))
            frames.append(frame)
        }
        return frames
    }

    /// How many frames a blob of `bytes` takes.
    static func blobPartCount(_ bytes: Int) -> Int { bytes <= 0 ? 0 : (bytes + blobChunk - 1) / blobChunk }

    static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func uint32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// LZFSE, or nil when it doesn't make the data smaller.
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var out = Data(count: data.count)
        let capacity = data.count
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, capacity, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0, written < data.count else { return nil }
        out.count = written
        return out
    }

    /// Decompresses into a buffer of exactly `rawLength` bytes (at most `limit`): a body that expands further is
    /// damaged, so a small frame can never inflate into unbounded memory.
    static func decompress(_ body: Data, rawLength: Int, limit: Int) throws -> Data {
        guard rawLength > 0, rawLength <= limit, !body.isEmpty else { throw damaged() }
        var out = Data(count: rawLength + 1)
        let capacity = rawLength + 1
        let sourceCount = body.count
        let written = out.withUnsafeMutableBytes { dst -> Int in
            body.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s, sourceCount, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == rawLength else { throw NibError.invalid("damaged collaboration message") }
        out.count = rawLength
        return out
    }

    static func decode(json: Data) throws -> CollabMessage {
        try JSONDecoder().decode(CollabMessage.self, from: json)
    }

    /// Reassembles messages and blobs per sender, within limits. A peer that is not admitted (`trusted` false) may
    /// send only whole frames of at most 8 KB (64 KB expanded): its hello. An admitted one may have at most two
    /// half-received messages (64 MB per peer, 128 MB in all) and four blobs, and a blob is accepted only when the
    /// session expects it (`blobPolicy` names its largest size): its frames are written to a file as they arrive.
    /// Anything that makes no progress for two minutes is dropped.
    final class Assembler {
        struct Limits {
            var peerBytes = 64 * 1_048_576
            var totalBytes = 128 * 1_048_576
            var partialsPerPeer = 2
            var blobsPerPeer = 4
            var untrustedFrameBytes = 8 * 1024
            var untrustedMessageBytes = 64 * 1024
            var staleAfter: TimeInterval = 120
        }

        enum Output {
            case message(CollabMessage)
            /// A message and the file its blob arrived in (the receiver removes the file).
            case blob(CollabMessage, URL)
        }

        private struct Partial {
            var count: Int
            var flags: UInt8
            var rawLength: Int
            var parts: [Int: Data]
            var bytes: Int
            var touched: Date
        }

        private struct Incoming {
            var message: CollabMessage
            var bytes: Int
            var count: Int
            var received: Set<Int>
            var handle: FileHandle
            var url: URL
            var touched: Date
        }

        var limits = Limits()
        private var partials: [String: [String: Partial]] = [:]
        private var blobs: [String: [String: Incoming]] = [:]
        private var folder: URL?

        init() {}

        deinit { reset() }

        /// Half-received messages.
        var pendingMessages: Int { partials.values.reduce(0) { $0 + $1.count } }
        /// Blobs still arriving.
        var pendingBlobs: Int { blobs.values.reduce(0) { $0 + $1.count } }
        /// Bytes held in memory for half-received messages.
        var pendingBytes: Int { partials.values.reduce(0) { sum, list in sum + list.values.reduce(0) { $0 + $1.bytes } } }

        /// What this frame completes: a message, a message whose blob has fully arrived, or nil while parts are
        /// missing (or when a blob frame belongs to nothing expected). Throws on frames that are not Nib's or break the
        /// limits (the peer's half-received messages are then dropped).
        func feed(_ frame: Data, from peer: String, trusted: Bool, now: Date = Date(),
                  blobPolicy: (CollabMessage) -> Int? = { _ in nil }) throws -> Output? {
            purge(now)
            let header = [UInt8](frame.prefix(CollabFrames.partHeaderBytes))
            guard header.count >= CollabFrames.prefixBytes, header[0] == CollabFrames.magic else {
                throw NibError.invalid("not a Nib collaboration frame")
            }
            guard header[1] == CollabFrames.formatVersion else {
                throw NibError(.unsupported, String(localized: "A participant uses a newer version of Nib."))
            }
            let flags = header[2]
            if !trusted {
                guard flags & (CollabFrames.partFlag | CollabFrames.blobFlag) == 0,
                      frame.count <= limits.untrustedFrameBytes else {
                    throw NibError(.permissionDenied, "a large message from someone who isn't in the live session")
                }
            }
            if flags & CollabFrames.blobFlag != 0 { return try blobPart(frame, header: header, from: peer, now: now) }
            let message: CollabMessage
            if flags & CollabFrames.partFlag == 0 {
                message = try whole(frame, header: header, flags: flags,
                                    limit: trusted ? CollabFrames.maxMessageBytes : limits.untrustedMessageBytes)
            } else {
                guard let m = try part(frame, header: header, flags: flags, from: peer, now: now) else { return nil }
                message = m
            }
            return try deliver(message, from: peer, trusted: trusted, now: now, policy: blobPolicy)
        }

        /// Drops everything half-received from a sender that left.
        func forget(peer: String) {
            partials[peer] = nil
            for incoming in (blobs.removeValue(forKey: peer) ?? [:]).values { discard(incoming) }
        }

        /// Drops everything (the session ended).
        func reset() {
            partials = [:]
            for list in blobs.values {
                for incoming in list.values { discard(incoming) }
            }
            blobs = [:]
            if let f = folder { try? FileManager.default.removeItem(at: f) }
            folder = nil
        }

        private func whole(_ frame: Data, header: [UInt8], flags: UInt8, limit: Int) throws -> CollabMessage {
            let start = frame.startIndex
            if flags & CollabFrames.compressedFlag != 0 {
                guard header.count >= CollabFrames.prefixBytes + 4 else { throw CollabFrames.damaged() }
                let raw = Int(CollabFrames.uint32(header[3..<7]))
                let body = frame.subdata(in: (start + CollabFrames.prefixBytes + 4)..<frame.endIndex)
                return try CollabFrames.decode(json: CollabFrames.decompress(body, rawLength: raw, limit: limit))
            }
            let body = frame.subdata(in: (start + CollabFrames.prefixBytes)..<frame.endIndex)
            guard body.count <= limit else { throw CollabFrames.tooLarge() }
            return try CollabFrames.decode(json: body)
        }

        private func part(_ frame: Data, header: [UInt8], flags: UInt8, from peer: String, now: Date) throws -> CollabMessage? {
            guard header.count == CollabFrames.partHeaderBytes else { throw NibError.invalid("truncated collaboration frame") }
            let id = CollabCode.hex(header[3..<19])
            let index = Int(CollabFrames.uint32(header[19..<23]))
            let count = Int(CollabFrames.uint32(header[23..<27]))
            let raw = Int(CollabFrames.uint32(header[27..<31]))
            let chunk = CollabFrames.maxFrameBytes - CollabFrames.partHeaderBytes
            guard count > 1, index < count, raw > 0, raw <= CollabFrames.maxMessageBytes,
                  count <= (CollabFrames.maxMessageBytes + chunk - 1) / chunk else {
                throw CollabFrames.damaged()
            }
            var mine = partials[peer] ?? [:]
            if mine[id] == nil, mine.count >= limits.partialsPerPeer {
                partials[peer] = nil
                throw NibError(.unsupported, "too many half-received messages from one participant")
            }
            let bodyFlags = flags & ~CollabFrames.partFlag
            var partial = mine[id] ?? Partial(count: count, flags: bodyFlags, rawLength: raw, parts: [:], bytes: 0, touched: now)
            guard partial.count == count, partial.rawLength == raw, partial.flags == bodyFlags else {
                mine[id] = nil
                partials[peer] = mine.isEmpty ? nil : mine
                throw CollabFrames.damaged()
            }
            if partial.parts[index] == nil {
                let slice = frame.subdata(in: (frame.startIndex + CollabFrames.partHeaderBytes)..<frame.endIndex)
                partial.parts[index] = slice
                partial.bytes += slice.count
            }
            partial.touched = now
            let others = mine.filter { $0.key != id }.values.reduce(0) { $0 + $1.bytes }
            let elsewhere = pendingBytes - (partials[peer]?.values.reduce(0) { $0 + $1.bytes } ?? 0)
            guard others + partial.bytes <= limits.peerBytes, elsewhere + others + partial.bytes <= limits.totalBytes else {
                partials[peer] = nil
                throw CollabFrames.tooLarge()
            }
            guard partial.parts.count == count else {
                mine[id] = partial
                partials[peer] = mine
                return nil
            }
            mine[id] = nil
            partials[peer] = mine.isEmpty ? nil : mine
            var body = Data(capacity: partial.bytes)
            for i in 0..<count {
                guard let slice = partial.parts[i] else { throw CollabFrames.damaged() }
                body.append(slice)
            }
            if partial.flags & CollabFrames.compressedFlag != 0 {
                body = try CollabFrames.decompress(body, rawLength: raw, limit: CollabFrames.maxMessageBytes)
            } else {
                guard body.count == raw else { throw CollabFrames.damaged() }
            }
            return try CollabFrames.decode(json: body)
        }

        /// A message that announces a blob starts receiving it (when the session expects one); others pass through.
        private func deliver(_ m: CollabMessage, from peer: String, trusted: Bool, now: Date,
                             policy: (CollabMessage) -> Int?) throws -> Output? {
            guard let blob = m.blob else { return .message(m) }
            guard trusted, let allowed = policy(m), blob.bytes >= 0, blob.bytes <= min(allowed, CollabFrames.maxBlobBytes),
                  blob.id.count == 32, blob.id.allSatisfy(\.isHexDigit) else {
                throw NibError(.permissionDenied, "an unexpected file from a participant")
            }
            var mine = blobs[peer] ?? [:]
            guard mine[blob.id] == nil, mine.count < limits.blobsPerPeer else {
                throw NibError(.unsupported, "too many files at once from one participant")
            }
            let url = try newFile()
            if blob.bytes == 0 { return .blob(m, url) }
            let handle = try FileHandle(forWritingTo: url)
            mine[blob.id] = Incoming(message: m, bytes: blob.bytes, count: CollabFrames.blobPartCount(blob.bytes),
                                     received: [], handle: handle, url: url, touched: now)
            blobs[peer] = mine
            return nil
        }

        private func blobPart(_ frame: Data, header: [UInt8], from peer: String, now: Date) throws -> Output? {
            guard header.count >= CollabFrames.blobHeaderBytes else { throw NibError.invalid("truncated collaboration frame") }
            let id = CollabCode.hex(header[3..<19])
            // Frames of a blob nobody announced (or one that was refused) are dropped without a word.
            guard var incoming = blobs[peer]?[id] else { return nil }
            let index = Int(CollabFrames.uint32(header[19..<23]))
            let count = Int(CollabFrames.uint32(header[23..<27]))
            let length = min(CollabFrames.blobChunk, incoming.bytes - index * CollabFrames.blobChunk)
            guard count == incoming.count, index < count, frame.count - CollabFrames.blobHeaderBytes == length else {
                dropBlob(id, of: peer)
                throw CollabFrames.damaged()
            }
            if !incoming.received.contains(index) {
                do {
                    try incoming.handle.seek(toOffset: UInt64(index * CollabFrames.blobChunk))
                    try incoming.handle.write(contentsOf: frame.subdata(in: (frame.startIndex + CollabFrames.blobHeaderBytes)..<frame.endIndex))
                } catch {
                    dropBlob(id, of: peer)
                    throw NibError.wrap(error)
                }
                incoming.received.insert(index)
            }
            incoming.touched = now
            guard incoming.received.count == incoming.count else {
                blobs[peer]?[id] = incoming
                return nil
            }
            try? incoming.handle.close()
            blobs[peer]?[id] = nil
            if blobs[peer]?.isEmpty == true { blobs[peer] = nil }
            return .blob(incoming.message, incoming.url)
        }

        private func newFile() throws -> URL {
            let fm = FileManager()
            let dir: URL
            if let f = folder {
                dir = f
            } else {
                dir = fm.temporaryDirectory.appendingPathComponent("nib-collab-in-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                folder = dir
            }
            let url = dir.appendingPathComponent(UUID().uuidString)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw NibError(.unavailable, String(localized: "There isn't enough space to receive the shared file."))
            }
            return url
        }

        private func dropBlob(_ id: String, of peer: String) {
            guard let incoming = blobs[peer]?[id] else { return }
            discard(incoming)
            blobs[peer]?[id] = nil
            if blobs[peer]?.isEmpty == true { blobs[peer] = nil }
        }

        private func discard(_ incoming: Incoming) {
            try? incoming.handle.close()
            try? FileManager.default.removeItem(at: incoming.url)
        }

        private func purge(_ now: Date) {
            let stale = limits.staleAfter
            for (peer, list) in partials {
                let fresh = list.filter { now.timeIntervalSince($0.value.touched) < stale }
                partials[peer] = fresh.isEmpty ? nil : fresh
            }
            for (peer, list) in blobs {
                var fresh: [String: Incoming] = [:]
                for (id, incoming) in list {
                    if now.timeIntervalSince(incoming.touched) < stale { fresh[id] = incoming } else { discard(incoming) }
                }
                blobs[peer] = fresh.isEmpty ? nil : fresh
            }
        }
    }
}

// MARK: - Blob files

/// Hashing and framing of blob files, off the main actor.
enum CollabBlobIO {
    static func newID() -> Data { withUnsafeBytes(of: UUID().uuid) { Data($0) } }

    /// Size and SHA-256 of a file, read in 1 MB chunks.
    static func digest(of url: URL) throws -> (bytes: Int, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += chunk.count
        }
        return (total, CollabCode.hex(hasher.finalize()))
    }

    /// The file to send, measured and hashed: a copy in a scratch folder when the source may still grow (a recording),
    /// so the bytes sent are the bytes hashed.
    static func prepare(_ source: URL, copy: Bool) throws -> (url: URL, scratch: URL?, bytes: Int, sha256: String) {
        guard copy else {
            let d = try digest(of: source)
            return (source, nil, d.bytes, d.sha256)
        }
        let fm = FileManager()
        let dir = fm.temporaryDirectory.appendingPathComponent("nib-collab-out-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: url)
            let d = try digest(of: url)
            return (url, dir, d.bytes, d.sha256)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// Blob frames `parts` of a file of `bytes` bytes.
    static func frames(file url: URL, id: Data, parts: Range<Int>, count: Int, bytes: Int) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunk = CollabFrames.blobChunk
        try handle.seek(toOffset: UInt64(parts.lowerBound * chunk))
        var out: [Data] = []
        out.reserveCapacity(parts.count)
        for i in parts {
            let length = min(chunk, bytes - i * chunk)
            guard length > 0, let slice = try handle.read(upToCount: length), slice.count == length else {
                throw NibError.invalid("the file changed while it was being sent")
            }
            var frame = Data(capacity: CollabFrames.blobHeaderBytes + length)
            frame.append(contentsOf: [CollabFrames.magic, CollabFrames.formatVersion, CollabFrames.blobFlag])
            frame.append(id)
            frame.append(contentsOf: CollabFrames.bigEndian(UInt32(i)))
            frame.append(contentsOf: CollabFrames.bigEndian(UInt32(count)))
            frame.append(slice)
            out.append(frame)
        }
        return out
    }
}

// MARK: - Package snapshots

/// Zips a document package for a joiner and unpacks one safely. Runs off the main actor (file I/O only).
enum CollabPackageIO {
    /// Largest expanded snapshot accepted (1 GB).
    static let maxExpandedBytes: UInt64 = 1 << 30

    /// The package folder as a zip file (keeping its "<Title>.nibnote" folder name) in a fresh scratch folder, which
    /// the caller removes (`zipURL.deletingLastPathComponent()`).
    static func zipFile(_ package: URL) throws -> URL {
        let fm = FileManager()
        let dir = fm.temporaryDirectory.appendingPathComponent("nib-collab-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("snapshot.zip")
        do {
            try fm.zipItem(at: package, to: zipURL, shouldKeepParent: true, compressionMethod: .deflate)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        return zipURL
    }

    /// The zip in memory (tests and small packages).
    static func zip(_ package: URL) throws -> Data {
        let url = try zipFile(package)
        defer { try? FileManager().removeItem(at: url.deletingLastPathComponent()) }
        return try Data(contentsOf: url)
    }

    /// Unpacks a snapshot file into a fresh temporary folder and returns the package folder inside it. Refuses
    /// archives that expand past `maxExpandedBytes` or hold no package; ZIPFoundation refuses entries outside the
    /// folder.
    static func unzip(file zipURL: URL) throws -> URL {
        let fm = FileManager()
        let archive = try Archive(url: zipURL, accessMode: .read)
        var total: UInt64 = 0
        for entry in archive {
            let (sum, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= maxExpandedBytes else {
                throw NibError(.unsupported, String(localized: "The shared document is too large to open."))
            }
            total = sum
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("nib-collab-" + UUID().uuidString, isDirectory: true)
        let out = dir.appendingPathComponent("package", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            try fm.unzipItem(at: zipURL, to: out)
            let children = try fm.contentsOfDirectory(at: out, includingPropertiesForKeys: [.isDirectoryKey])
            let packages = [NibFormat.packageExtension, NibFormat.legacyPackageExtension]
            guard let package = children.first(where: { packages.contains($0.pathExtension.lowercased()) }) else {
                throw NibError.invalid(String(localized: "The shared document arrived damaged."))
            }
            return package
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// Unpacks a snapshot held in memory.
    static func unzip(_ data: Data) throws -> URL {
        let fm = FileManager()
        let dir = fm.temporaryDirectory.appendingPathComponent("nib-collab-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("snapshot.zip")
        try data.write(to: zipURL)
        return try unzip(file: zipURL)
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

/// A transport that knows which peer it joined through (Multipeer: the advertiser it invited). Before the host is
/// known, a guest accepts `pending`, `welcome` and `denied` only from that peer, so another participant of a mesh
/// can't pose as the host.
@MainActor
protocol CollabJoinedHost: AnyObject {
    var joinedHostPeerID: String? { get }
}

// MARK: - Session

/// One live session, as the host or as a guest. Main actor only; transports deliver on main.
@MainActor
final class CollabSession {
    enum Side: String { case host, guest }

    /// Where messages go: to the host (from a guest) or to one participant (from the host). What is posted to a route
    /// leaves in order, so the bytes of a file always precede the records that need them.
    enum Route: Hashable {
        case host
        case participant(String)
    }

    /// `applyRemote` origin of merged collaborator changes ("collab:<participant>"), so they are never echoed back.
    static let originPrefix = "collab:"
    /// `applyRemote` origin of this device's own bookkeeping (a received copy's device-local meta): never sent.
    static let localOrigin = originPrefix + "local"
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
    /// The role the host chose for each participant; the effective role is view while they need a newer Nib (S-100).
    private var chosenRoles: [String: CollabRole] = [:]

    // Guest.
    private(set) var secret: String?
    private var hostPeer: CollabPeer?
    /// Local edits made while disconnected; the next digest exchange sends them.
    private(set) var hasUnsentChanges = false
    /// The document arrived as a snapshot (this library did not have it).
    private(set) var receivedSnapshot = false

    // Files: the names each route is known to hold (its digest, plus what was sent), and the size a package file had
    // when it was sent (a recording grows).
    private var knownAssets: [Route: Set<String>] = [:]
    private var sentFileSizes: [Route: [String: Int]] = [:]

    private let assembler = CollabFrames.Assembler()
    private var deliveries: [(CollabPeer, CollabFrames.Assembler.Output)] = []
    private var draining = false
    /// While a received file is verified and stored (or a snapshot imported), deliveries wait: records never land
    /// before their bytes, and the host relays a patch only once it holds the files the patch needs.
    private var holds = 0
    private var outbox: [Route: Task<Void, Never>] = [:]
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
        participants[me] = CollabParticipant(id: me, name: name, role: .edit, state: .active, isHost: true, colorIndex: 0,
                                             format: service.formatVersion)
        order = [me]
    }

    /// A guest session joining `code`; `secret` is the admission secret this device kept from an earlier join of the
    /// same session (the app was relaunched), so the host lets it back in without asking again.
    init(joining code: String, transportKey: String, transport: CollabTransport, service: CollabService, me: String,
         name: String, secret: String? = nil) {
        side = .guest
        self.code = code
        self.transportKey = transportKey
        self.transport = transport
        defaultRole = .edit
        self.service = service
        self.me = me
        myName = name
        self.secret = secret
        id = ""
        phase = .connecting
        myRole = .view
    }

    // MARK: Reading

    var roster: [CollabParticipant] { order.compactMap { participants[$0] } }

    /// What guests see: everyone admitted (waiting joiners stay private to the host).
    var publicRoster: [CollabParticipant] { roster.filter { $0.state != .pending } }

    var sessionFormat: Int { CollabGate.effectiveFormat(roster) }

    /// The newest Nib in the session: only participants at this format edit (S-100).
    var newestFormat: Int { CollabGate.newestFormat(host: service.formatVersion, participants: roster) }

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
        cancelOutbox()
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
                if let h = hostPeer { _ = transmit(CollabMessage(kind: .bye, session: id, from: me), to: [h]) }
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
        cancelOutbox()
        for (_, out) in deliveries {
            if case let .blob(_, url) = out { try? FileManager.default.removeItem(at: url) }
        }
        deliveries.removeAll()
        assembler.reset()
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
            regate()
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
        chosenRoles[pid] = role
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
        // Frames are assembled at once (a blob's frames go straight to disk); what they complete is delivered in order.
        do {
            if let out = try assembler.feed(data, from: peer.id, trusted: isTrusted(peer),
                                            blobPolicy: { m in self.blobAllowance(m, from: peer) }) {
                deliveries.append((peer, out))
            }
        } catch {
            log.error("collab: dropped a frame from \(peer.id, privacy: .public): \(NibError.wrap(error).message, privacy: .public)")
        }
        drain()
    }

    /// Transports may deliver synchronously from inside our own sends (NibTesting's hub does): deliveries queue and
    /// run in order, so a reply never runs in the middle of the handler that caused it.
    private func drain() {
        guard !draining else { return }
        draining = true
        while holds == 0, !deliveries.isEmpty, !isClosed {
            let (peer, out) = deliveries.removeFirst()
            switch out {
            case .message(let m):
                // A declined or removed connection may only ask again (a removed participant is then told no).
                if side == .host, blockedPeers.contains(peer.id), m.kind != .hello { continue }
                switch side {
                case .host: hostHandle(m, from: peer)
                case .guest: guestHandle(m, from: peer)
                }
            case let .blob(m, url):
                handleBlob(m, file: url, from: peer)
            }
        }
        draining = false
    }

    /// Admitted participants (host) and the host (guest) may send large messages and files; everyone else only
    /// small single frames (a hello, before admission).
    private func isTrusted(_ peer: CollabPeer) -> Bool {
        switch side {
        case .host:
            guard !blockedPeers.contains(peer.id), let pid = participantOf[peer.id] else { return false }
            return participants[pid]?.state == .active
        case .guest:
            return hostPeer?.id == peer.id
        }
    }

    /// The largest blob this session accepts with `m` from `peer`, nil when it expects none: the host takes files
    /// only from participants who may edit; a guest takes the snapshot it asked for and files from the host.
    private func blobAllowance(_ m: CollabMessage, from peer: CollabPeer) -> Int? {
        guard !isClosed, m.session == id else { return nil }
        switch side {
        case .host:
            guard m.kind == .asset, let pid = participantOf[peer.id], pid == m.from,
                  participants[pid]?.canEdit == true else { return nil }
            return CollabAssets.maxBytes
        case .guest:
            guard hostPeer?.id == peer.id else { return nil }
            switch m.kind {
            case .snapshot: return phase == .receiving ? CollabFrames.maxBlobBytes : nil
            case .asset: return CollabAssets.maxBytes
            default: return nil
            }
        }
    }

    private func handleBlob(_ m: CollabMessage, file: URL, from peer: CollabPeer) {
        switch m.kind {
        case .snapshot where side == .guest && phase == .receiving && hostPeer?.id == peer.id:
            if let s = m.snapshot {
                receiveSnapshot(s, blob: m.blob, file: file)
                return
            }
        case .asset:
            storeAsset(m, file: file, from: peer)
            return
        default:
            break
        }
        try? FileManager.default.removeItem(at: file)
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
            broadcastPatch(m, patch: patch, except: pid)
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
        if let existing = participants[pid], existing.state != .pending, let presented = hello.secret,
           let known = secrets[pid], CollabCode.matches(presented, known) {
            // An admitted participant coming back (suspend, relaunch, out of range): no second approval.
            bind(pid, peer)
            participants[pid]?.state = .active
            participants[pid]?.name = name
            participants[pid]?.format = hello.format
            regate()
            sendWelcome(pid)
            rosterChanged()
            return
        }
        if let existing = participants[pid] {
            // Someone else is connected as this participant right now: identities are self-reported, so the first
            // connection keeps it.
            if existing.state != .away, let bound = peerOf[pid], bound.id != peer.id, isConnected(bound) {
                deny(peer, .identity, String(localized: "A device with the same identity is already in this session."))
                return
            }
            // Waiting, away without its secret (the app was relaunched), or its old connection is gone: the host
            // decides again.
            let asksAgain = existing.state != .pending
            participants[pid]?.state = .pending
            participants[pid]?.name = name
            participants[pid]?.format = hello.format
            secrets[pid] = nil
            bind(pid, peer)
            regate()
            _ = send(CollabMessage(kind: .pending, session: id, from: me), to: pid)
            if asksAgain {
                rosterChanged()
                if let p = participants[pid] { service.joinRequested(p, title: title) }
            } else {
                changed()
            }
            return
        }
        guard !CollabGate.isFull(count: participants.count, cap: transport.maxPeers) else {
            deny(peer, .full, CollabGate.fullMessage(cap: transport.maxPeers))
            return
        }
        chosenRoles[pid] = defaultRole
        participants[pid] = CollabParticipant(id: pid, name: name, role: defaultRole, state: .pending, isHost: false,
                                              colorIndex: nextColorIndex(), format: hello.format)
        order.append(pid)
        bind(pid, peer)
        regate()
        _ = send(CollabMessage(kind: .pending, session: id, from: me), to: pid)
        changed()
        if let p = participants[pid] { service.joinRequested(p, title: title) }
    }

    private func guestHandle(_ m: CollabMessage, from peer: CollabPeer) {
        // Before the host answers, only the peer the transport joined through (when it knows) may name the host;
        // afterwards only the host speaks.
        if let h = hostPeer, h.id != peer.id { return }
        if hostPeer == nil, let joined = (transport as? CollabJoinedHost)?.joinedHostPeerID, joined != peer.id { return }
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
            end(reason: reason, notify: false,
                error: NibError(denial.errorCode, reason, hint: denial == .full ? CollabGate.fullHint : nil))
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
                if let digest = m.digest { knownAssets[.host] = Set(digest.assets) }
                if let patch = m.patch { applyRemote(patch, author: m.from) }
                if let digest = m.digest { sendDelta(against: digest) }
            case .snapshot:
                guard phase == .receiving, let s = m.snapshot else { return }
                receiveSnapshot(s, blob: nil, file: nil)
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
            // A locked copy is never sent, nor merged into: this device stays out of the session.
            if service.isLocked(local) {
                let reason = String(localized: "Your copy of “\(w.title)” is locked. Remove the password lock to join the live session.")
                end(reason: reason, notify: true, error: NibError(.locked, reason, hint: "remove the password lock first"))
                return
            }
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
        guard let doc = localDoc, !isClosed, ensureUnlocked() else { return }
        _ = try? app.workspace.content(doc)
        phase = .active
        applyRoleLocally()
        service.didBecomeActive(self)
        changed()
        resolveReady(nil)
        if let digest = try? digest(of: doc) {
            hasUnsentChanges = !post(CollabMessage(kind: .sync, session: id, from: me, digest: digest), to: .host)
        }
        reportPage()
    }

    private func receiveSnapshot(_ s: CollabMessage.Snapshot, blob: CollabMessage.Blob?, file: URL?) {
        let host = hostID ?? ""
        holds += 1
        Task { [weak self] in
            let service = self?.service
            var result: Result<DocumentID, Error> = .failure(NibError(.unavailable, String(localized: "The live session ended.")))
            if let service = service {
                do {
                    result = .success(try await service.importSnapshot(s, blob: blob, file: file, author: host))
                } catch {
                    result = .failure(error)
                }
            }
            if let file = file { try? FileManager.default.removeItem(at: file) }
            guard let self = self else { return }
            self.holds -= 1
            switch result {
            case .success(let local):
                if !self.isClosed, self.phase == .receiving {
                    self.localDoc = local
                    self.receivedSnapshot = true
                    self.becomeActive()
                }
            case .failure(let error):
                let e = NibError.wrap(error)
                self.end(reason: String(localized: "The shared document couldn't be saved: \(e.message)"), notify: true,
                         error: e)
            }
            self.drain()
        }
    }

    // MARK: Files

    /// Stores a received file after checking it is exactly what was announced, and (host) passes it on to everyone
    /// else who lacks it.
    private func storeAsset(_ m: CollabMessage, file: URL, from peer: CollabPeer) {
        let fm = FileManager.default
        guard let doc = localDoc, let name = m.asset?.name, let blob = m.blob, !service.isLocked(doc),
              senderMaySendFiles(m, peer: peer) else {
            try? fm.removeItem(at: file)
            return
        }
        var destination: URL?
        if CollabAssets.isPackageFile(name) {
            destination = try? app.workspace.persistence.fileURL(doc, relativePath: name)
            guard destination != nil else {
                try? fm.removeItem(at: file)
                return
            }
        } else {
            guard CollabAssets.isAssetName(name), app.services.assets != nil else {
                try? fm.removeItem(at: file)
                return
            }
        }
        let assets = app.services.assets
        let author = m.from
        let target = destination
        holds += 1
        Task { [weak self] in
            let stored = await Task.detached(priority: .userInitiated) {
                CollabSession.store(file: file, blob: blob, name: name, destination: target, assets: assets, doc: doc)
            }.value
            guard let self = self else { return }
            self.holds -= 1
            if stored {
                self.fileArrived(name, from: author)
            } else {
                self.log.error("collab: refused a file that didn't match its name: \(name, privacy: .public)")
            }
            self.drain()
        }
    }

    private func senderMaySendFiles(_ m: CollabMessage, peer: CollabPeer) -> Bool {
        guard !isClosed, m.session == id else { return false }
        switch side {
        case .host:
            guard let pid = participantOf[peer.id], pid == m.from else { return false }
            return participants[pid]?.canEdit == true
        case .guest:
            return hostPeer?.id == peer.id
        }
    }

    /// Verifies and stores a received file off the main actor: the bytes must hash to what the blob announced, and
    /// an asset must be stored under exactly the name the records use (content addressing), so a participant can't
    /// slip other bytes under an existing name. Package files replace a shorter local copy only.
    nonisolated static func store(file: URL, blob: CollabMessage.Blob, name: String, destination: URL?,
                                  assets: AssetStore?, doc: DocumentID) -> Bool {
        let fm = FileManager()
        defer { try? fm.removeItem(at: file) }
        do {
            let (bytes, sha) = try CollabBlobIO.digest(of: file)
            guard bytes == blob.bytes, sha == blob.sha256.lowercased() else { return false }
            if let destination = destination {
                if fm.fileExists(atPath: destination.path) {
                    let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard bytes > size else { return true }
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: file, to: destination)
                return true
            }
            guard let assets = assets else { return false }
            let ref = AssetRef(name)
            let data = try Data(contentsOf: file, options: .alwaysMapped)
            if let stem = CollabAssets.sha256Stem(name) {
                guard stem == sha else { return false }
            } else {
                // Another naming scheme: this store must name these bytes exactly as the sender's did.
                guard (try? assets.putTemporary(data, ext: ref.ext))?.name == name else { return false }
            }
            return try assets.put(data, ext: ref.ext, doc: doc).name == name
        } catch {
            return false
        }
    }

    private func fileArrived(_ name: String, from author: String) {
        switch side {
        case .guest:
            knownAssets[.host, default: []].insert(name)
        case .host:
            knownAssets[.participant(author), default: []].insert(name)
            // Everyone else who may lack it gets it now (ahead of the patch that needs it, which waited for this).
            for pid in order where pid != me && pid != author && participants[pid]?.state == .active {
                sendFiles([name], to: .participant(pid))
            }
        }
    }

    /// Sends the files among `names` that this device holds and `route` isn't known to hold, ahead of whatever is
    /// posted to the route next.
    private func sendFiles(_ names: Set<String>, to route: Route) {
        guard let doc = localDoc, !names.isEmpty, !isClosed else { return }
        var known = knownAssets[route] ?? []
        var sizes = sentFileSizes[route] ?? [:]
        for name in names.sorted() {
            let isFile = CollabAssets.isPackageFile(name)
            guard let source = localFile(name, doc: doc) else { continue }
            if isFile {
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if known.contains(name), sizes[name].map({ $0 >= size }) ?? true { continue }
                sizes[name] = size
            } else if known.contains(name) {
                continue
            }
            known.insert(name)
            let header = CollabMessage(kind: .asset, session: id, from: me, asset: CollabMessage.Asset(name: name))
            postBlob(header, source: source, copy: isFile, cleanup: nil, to: route)
        }
        knownAssets[route] = known
        sentFileSizes[route] = sizes
    }

    /// The file behind `name` when this device has it.
    private func localFile(_ name: String, doc: DocumentID) -> URL? {
        let fm = FileManager.default
        if CollabAssets.isPackageFile(name) {
            guard let url = try? app.workspace.persistence.fileURL(doc, relativePath: name),
                  fm.fileExists(atPath: url.path) else { return nil }
            return url
        }
        guard CollabAssets.isAssetName(name), let url = app.services.assets?.url(AssetRef(name), doc: doc),
              fm.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The referenced files this device holds (a digest's `assets`).
    private func heldFiles(_ names: Set<String>, doc: DocumentID) -> [String] {
        names.filter { localFile($0, doc: doc) != nil }.sorted()
    }

    // MARK: Host internals

    private func bind(_ pid: String, _ peer: CollabPeer) {
        blockedPeers.remove(peer.id)
        if let old = peerOf[pid], old.id != peer.id {
            participantOf[old.id] = nil
            assembler.forget(peer: old.id)
        }
        if let other = participantOf[peer.id], other != pid { peerOf[other] = nil }
        peerOf[pid] = peer
        participantOf[peer.id] = pid
    }

    private func unbind(_ pid: String) {
        if let peer = peerOf.removeValue(forKey: pid) {
            participantOf[peer.id] = nil
            assembler.forget(peer: peer.id)
        }
        knownAssets[.participant(pid)] = nil
        sentFileSizes[.participant(pid)] = nil
    }

    private func drop(_ pid: String) {
        unbind(pid)
        participants[pid] = nil
        chosenRoles[pid] = nil
        order.removeAll { $0 == pid }
        service.notifier.clear(participant: pid)
        regate()
    }

    private func isConnected(_ peer: CollabPeer) -> Bool { transport.peers.contains { $0.id == peer.id } }

    /// S-100: only participants at the newest format in the session edit. Someone newer arriving turns older
    /// participants to view; once they update (or the newer one leaves) they get the role the host chose back.
    private func regate() {
        guard side == .host else { return }
        let newest = newestFormat
        for pid in order where pid != me {
            guard var p = participants[pid] else { continue }
            p.needsUpdate = !CollabGate.canEdit(format: p.format, newest: newest)
            p.role = p.needsUpdate ? .view : (chosenRoles[pid] ?? defaultRole)
            participants[pid] = p
        }
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
        guard let doc = localDoc, ensureUnlocked(), let state = try? documentState(doc) else { return }
        let route = Route.participant(pid)
        knownAssets[route] = Set(digest.assets)
        sentFileSizes[route] = [:]
        let names = CollabAssets.names(content: state.content, items: state.items)
        let patch = CollabDigest.delta(content: state.content, items: state.items, against: digest, doc: doc)
        let mine = CollabDigest(content: state.content, items: state.items, assets: heldFiles(names, doc: doc))
        sendFiles(names, to: route)
        _ = post(CollabMessage(kind: .syncReply, session: id, from: me, patch: patch.isEmpty ? nil : patch, digest: mine),
                 to: route)
    }

    /// The zipped package when the library keeps one on disk (streamed as a blob), else the document's records.
    private func sendSnapshot(to pid: String) {
        guard let doc = localDoc else { return }
        let route = Route.participant(pid)
        do {
            let content = try app.workspace.content(doc)
            app.workspace.persistence.flush(doc)
            if let url = app.services.library?.packageURL(doc), FileManager.default.fileExists(atPath: url.path) {
                let header = CollabMessage(kind: .snapshot, session: id, from: me,
                                           snapshot: CollabMessage.Snapshot(doc: doc, title: title, kind: content.meta.kind,
                                                                            format: .package, content: nil))
                let previous = outbox[route]
                let task = Task { [weak self] in
                    await previous?.value
                    do {
                        let zipped = try await Task.detached(priority: .userInitiated) { try CollabPackageIO.zipFile(url) }.value
                        let scratch = zipped.deletingLastPathComponent()
                        guard let self = self else {
                            try? FileManager.default.removeItem(at: scratch)
                            return
                        }
                        let sent = await self.streamBlob(header, source: zipped, copy: false, cleanup: scratch, to: route)
                        if !sent {
                            self.snapshotFailed(NibError(.unavailable, String(localized: "The connection dropped.")), to: pid)
                        }
                    } catch {
                        self?.snapshotFailed(error, to: pid)
                    }
                }
                enqueue(task, on: route)
                return
            }
            let state = try documentState(doc)
            let items = Dictionary(state.items.map { ($0.key.raw, $0.value) }, uniquingKeysWith: { a, _ in a })
            let snapshot = CollabMessage.Snapshot(doc: doc, title: title, kind: content.meta.kind, format: .content,
                                                  content: CollabMessage.SnapshotContent(content: state.content, items: items))
            if !post(CollabMessage(kind: .snapshot, session: id, from: me, snapshot: snapshot), to: route) {
                snapshotFailed(CollabFrames.tooLarge(), to: pid)
            }
        } catch {
            snapshotFailed(error, to: pid)
        }
    }

    private func snapshotFailed(_ error: Error, to pid: String) {
        guard !isClosed, participants[pid]?.state == .active else { return }
        let e = NibError.wrap(error)
        log.error("collab: snapshot failed: \(e.message, privacy: .public)")
        _ = send(CollabMessage(kind: .denied, session: id, from: me,
                               reason: String(localized: "The host couldn't send the document: \(e.message)"),
                               denial: .failed), to: pid)
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
                      hello: CollabMessage.Hello(name: myName, format: service.formatVersion,
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
                if myRole == .edit {
                    service.notice(String(localized: "You can now edit this document."))
                } else if mine.needsUpdate {
                    service.notice(String(localized: "Someone joined with a newer Nib, so you can view this document until you update."))
                } else {
                    service.notice(String(localized: "You can now view this document, not edit it."))
                }
            }
        }
        changed()
    }

    private func authorMayEdit(_ author: String) -> Bool {
        author == hostID || participants[author]?.canEdit == true
    }

    private func sendDelta(against digest: CollabDigest) {
        guard side == .guest, myRole == .edit, let doc = localDoc, let remote = remoteDoc, ensureUnlocked(),
              let state = try? documentState(doc) else { return }
        let patch = CollabDigest.delta(content: state.content, items: state.items, against: digest, doc: doc)
        hasUnsentChanges = false
        sendFiles(CollabAssets.names(content: state.content, items: state.items), to: .host)
        guard !patch.isEmpty else { return }
        let m = CollabMessage(kind: .patch, session: id, from: me, patch: CollabSession.rewrite(patch, to: remote))
        if !post(m, to: .host) { hasUnsentChanges = true }
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
                    chosenRoles[pid] = nil
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

    /// Locked documents are never sent nor merged into: a lock on the shared copy (set now, or already there) ends
    /// the host's session, or takes a guest out of it. False when the session ended for that reason.
    private func ensureUnlocked() -> Bool {
        guard let doc = localDoc, service.isLocked(doc) else { return true }
        let reason = side == .host ? String(localized: "The document was locked, so the live session ended.")
                                   : String(localized: "Your copy is locked, so you left the live session.")
        end(reason: reason, notify: true, error: NibError(.locked, reason, hint: "remove the password lock first"))
        return false
    }

    /// A local commit: send it (host to everyone, guest to the host) with the files it needs, or remember it while
    /// disconnected.
    private func committed(_ cs: Changeset) {
        guard !isClosed, let doc = localDoc, let remote = remoteDoc, cs.documents.contains(doc) else { return }
        if case let .sync(origin) = cs.principal, origin.hasPrefix(CollabSession.originPrefix) { return }
        guard ensureUnlocked() else { return }
        guard side == .host || myRole == .edit else { return }
        let patch = CollabSession.rewrite(cs.patch(for: doc), to: remote)
        guard !patch.isEmpty else { return }
        guard phase == .active else {
            hasUnsentChanges = true
            return
        }
        let m = CollabMessage(kind: .patch, session: id, from: me, patch: patch)
        if side == .host {
            broadcastPatch(m, patch: patch, except: nil)
        } else {
            sendFiles(CollabAssets.names(in: patch), to: .host)
            if !post(m, to: .host) { hasUnsentChanges = true }
        }
    }

    /// Host: a patch to every other admitted participant, each preceded by the files it needs that they lack.
    private func broadcastPatch(_ m: CollabMessage, patch: DocumentPatch, except: String?) {
        let frames: [Data]
        do {
            frames = try CollabFrames.frames(for: m)
        } catch {
            log.error("collab: send failed: \(NibError.wrap(error).message, privacy: .public)")
            return
        }
        let names = CollabAssets.names(in: patch)
        for pid in order where pid != me && pid != except && participants[pid]?.state == .active {
            let route = Route.participant(pid)
            sendFiles(names, to: route)
            _ = post(frames: frames, to: route)
        }
    }

    private func applyRemote(_ patch: DocumentPatch, author: String) {
        guard let doc = localDoc, ensureUnlocked() else { return }
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
        let held = heldFiles(CollabAssets.names(content: state.content, items: state.items), doc: doc)
        return CollabDigest(content: state.content, items: state.items, assets: held)
    }

    /// Every record of the document. Pages loaded only for this are evicted again, so a join or re-join doesn't
    /// leave the whole notebook in memory.
    private func documentState(_ doc: DocumentID) throws -> (content: DocumentContent, items: [PageID: [Item]]) {
        let content = try app.workspace.content(doc)
        let cached = app.workspace.cachedPages(doc)
        defer {
            if app.workspace.cachedPages(doc).count > cached.count { app.workspace.evictPages(doc, keeping: cached) }
        }
        var items: [PageID: [Item]] = [:]
        for p in content.pages { items[p.id] = try app.workspace.allItems(doc, page: p.id) }
        return (content, items)
    }

    private func changed() {
        service.sessionChanged(self)
    }

    // MARK: Sending

    /// Sends now, to explicit transport peers (hello, denials, ended); not ordered behind files.
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

    /// Sends now to one participant (presence, roster, welcome).
    private func send(_ m: CollabMessage, to pid: String) -> Bool {
        guard let peer = peerOf[pid] else { return false }
        return transmit(m, to: [peer])
    }

    private func sendToHost(_ m: CollabMessage) -> Bool {
        guard let h = hostPeer else { return false }
        return transmit(m, to: [h])
    }

    /// Presence and roster to every admitted participant, now.
    private func broadcast(_ m: CollabMessage, except: String?) {
        let targets = order.compactMap { pid -> CollabPeer? in
            guard pid != me, pid != except, participants[pid]?.state == .active else { return nil }
            return peerOf[pid]
        }
        guard !targets.isEmpty else { return }
        transmit(m, to: targets)
    }

    private func peers(for route: Route) -> [CollabPeer]? {
        switch route {
        case .host: return hostPeer.map { [$0] }
        case .participant(let pid): return peerOf[pid].map { [$0] }
        }
    }

    /// Sends `m` to `route` behind any file still streaming there. False when it can't be sent.
    @discardableResult
    private func post(_ m: CollabMessage, to route: Route) -> Bool {
        do {
            return post(frames: try CollabFrames.frames(for: m), to: route)
        } catch {
            log.error("collab: send failed: \(NibError.wrap(error).message, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func post(frames: [Data], to route: Route) -> Bool {
        guard let previous = outbox[route] else { return deliver(frames, to: route) }
        guard peers(for: route) != nil else { return false }
        let task = Task { [weak self] in
            await previous.value
            _ = self?.deliver(frames, to: route)
        }
        enqueue(task, on: route)
        return true
    }

    private func postBlob(_ header: CollabMessage, source: URL, copy: Bool, cleanup: URL?, to route: Route) {
        let previous = outbox[route]
        let task = Task { [weak self] in
            await previous?.value
            guard let self = self else {
                if let c = cleanup { try? FileManager.default.removeItem(at: c) }
                return
            }
            _ = await self.streamBlob(header, source: source, copy: copy, cleanup: cleanup, to: route)
        }
        enqueue(task, on: route)
    }

    private func enqueue(_ task: Task<Void, Never>, on route: Route) {
        outbox[route] = task
        Task { [weak self] in
            await task.value
            guard let self = self, self.outbox[route] == task else { return }
            self.outbox[route] = nil
        }
    }

    private func cancelOutbox() {
        for task in outbox.values { task.cancel() }
        outbox = [:]
    }

    private func deliver(_ frames: [Data], to route: Route) -> Bool {
        guard !isClosed, let targets = peers(for: route) else { return false }
        do {
            for frame in frames { try transport.send(frame, to: targets) }
            return true
        } catch {
            log.error("collab: send failed: \(NibError.wrap(error).message, privacy: .public)")
            return false
        }
    }

    /// Streams a file as a blob: measured and hashed off the main actor, then the header, then its frames read from
    /// disk in batches of about 2 MB, each batch handed to the transport on the main actor. Stops when the session
    /// ends or the route's connection changes. `cleanup` is removed afterwards.
    private func streamBlob(_ header: CollabMessage, source: URL, copy: Bool, cleanup: URL?, to route: Route) async -> Bool {
        defer { if let c = cleanup { try? FileManager.default.removeItem(at: c) } }
        guard !isClosed, let first = peers(for: route) else { return false }
        let prepared: (url: URL, scratch: URL?, bytes: Int, sha256: String)
        do {
            prepared = try await Task.detached(priority: .utility) { try CollabBlobIO.prepare(source, copy: copy) }.value
        } catch {
            log.error("collab: couldn't read a file to send: \(NibError.wrap(error).message, privacy: .public)")
            return false
        }
        defer { if let s = prepared.scratch { try? FileManager.default.removeItem(at: s) } }
        guard prepared.bytes <= CollabFrames.maxBlobBytes else { return false }
        let blobID = CollabBlobIO.newID()
        var m = header
        m.blob = CollabMessage.Blob(id: CollabCode.hex(blobID), bytes: prepared.bytes, sha256: prepared.sha256)
        let headerFrames: [Data]
        do {
            headerFrames = try CollabFrames.frames(for: m)
        } catch {
            return false
        }
        guard !isClosed, peers(for: route) == first, deliver(headerFrames, to: route) else { return false }
        let count = CollabFrames.blobPartCount(prepared.bytes)
        var next = 0
        while next < count {
            let range = next..<min(next + CollabFrames.blobBatch, count)
            let file = prepared.url
            let bytes = prepared.bytes
            let frames: [Data]
            do {
                frames = try await Task.detached(priority: .utility) {
                    try CollabBlobIO.frames(file: file, id: blobID, parts: range, count: count, bytes: bytes)
                }.value
            } catch {
                log.error("collab: couldn't read a file to send: \(NibError.wrap(error).message, privacy: .public)")
                return false
            }
            guard !isClosed, !Task.isCancelled, peers(for: route) == first, deliver(frames, to: route) else { return false }
            next = range.upperBound
        }
        return true
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

/// `collab.session` (contracts-v2 G3 typed payload): `event` is "session" (a phase or roster change: `phase`,
/// `participants`) or "request" (someone asks to join: `participant`, `name`). `NibEvent.doc` is the shared document.
struct CollabSessionEventPayload: NibEventPayload, Equatable {
    static let eventType = CollabIDs.event

    var event: String
    var phase: String?
    var participants: Int?
    var participant: String?
    var name: String?

    init(event: String, phase: String? = nil, participants: Int? = nil, participant: String? = nil, name: String? = nil) {
        self.event = event
        self.phase = phase
        self.participants = participants
        self.participant = participant
        self.name = name
    }
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
    /// The `NibFormat.version` this device reports in a session (tests stand in for an older Nib with it).
    var formatVersion = NibFormat.version
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

    /// True when `doc` carries a password lock (or is locked in this app session): it is never hosted, sent or merged
    /// into live.
    func isLocked(_ doc: DocumentID) -> Bool {
        if (try? app.workspace.peekContent(doc))?.meta.locked == true { return true }
        return app.services.lock?.isLocked(doc) ?? false
    }

    // MARK: Host and join

    func host(doc: DocumentID, transportKey: String?, role: CollabRole) async throws -> CollabSession {
        if let s = session, !s.isClosed {
            if s.side == .host, s.localDoc == doc { return s }
            throw NibError(.conflict, String(localized: "Another live session is running. Leave it before starting a new one."),
                           hint: "call collab.leave")
        }
        let content = try app.workspace.content(doc)
        if isLocked(doc) {
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
    /// it is a fresh join. A device that was admitted to this session before (and was relaunched since) presents the
    /// secret it kept, so the host lets it back in without asking again.
    func join(code raw: String, transportKey: String?) async throws -> (session: CollabSession, fresh: Bool) {
        guard let code = CollabCode.normalize(raw) else {
            throw NibError(.invalidParams, String(localized: "“\(raw)” isn't a join code."), path: "$.code",
                           hint: "a join code has 6 letters and digits, e.g. K7M2QX")
        }
        if let s = session, !s.isClosed {
            if s.side == .guest, s.code == code {
                if let local = s.localDoc, isLocked(local) {
                    let reason = String(localized: "Your copy is locked, so you left the live session.")
                    let e = NibError(.locked, reason, hint: "remove the password lock first")
                    s.end(reason: reason, notify: true, error: e)
                    throw e
                }
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
        let kept = sharedDocuments().first { $0.role == "guest" && $0.code == code && $0.secret != nil }?.secret
        let s = CollabSession(joining: code, transportKey: key, transport: transport, service: self, me: myID, name: myName,
                              secret: kept)
        session = s
        state.message = nil
        s.install()
        do {
            try await s.join()
        } catch {
            let e = NibError.wrap(error)
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

    /// Tries to re-join after each delay; when every attempt fails, the session ends (and folder sync takes over when
    /// the copy is the same document).
    private func runRejoin(_ delays: [TimeInterval]) async {
        for delay in delays {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if Task.isCancelled { return }
            guard let s = session, s.side == .guest, !s.isClosed else { return }
            if s.phase == .active, s.isConnectedToHost { return }
            do {
                try await s.rejoin()
                return
            } catch let e as NibError where e.code == .userDenied || e.code == .unsupported || e.code == .locked {
                if !s.isClosed { s.end(reason: e.message, notify: false, error: e) }
                return
            } catch {
                log.info("collab: re-join attempt failed: \(NibError.wrap(error).message, privacy: .public)")
            }
        }
        guard let s = session, s.side == .guest, !s.isClosed, !(s.phase == .active && s.isConnectedToHost) else { return }
        // A folder-synced copy is the host's own document; a copy received into Shared is not synced with the host.
        let synced = s.localDoc != nil && s.localDoc == s.remoteDoc
        let reason = synced
            ? String(localized: "Couldn't reconnect to the live session. Your copy stays in the library, and changes arrive through folder sync.")
            : String(localized: "Couldn't reconnect to the live session. Your copy stays in the Shared folder, and your changes are sent when you join the session again.")
        s.end(reason: reason, notify: false, error: NibError(.unavailable, reason))
        if synced, app.commands.entry(CommandIDs.syncNow) != nil {
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
        app.events.emit(CollabSessionEventPayload(event: "request", participant: p.id, name: p.name), doc: session?.localDoc)
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

    /// A guest is in: remember the copy, and the admission secret so a relaunched app gets back in without approval.
    func didBecomeActive(_ s: CollabSession) {
        guard let local = s.localDoc, let remote = s.remoteDoc else { return }
        rememberShared(local: local, remote: remote, role: "guest", title: s.title, code: s.code, secret: s.secret)
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
                app.events.emit(CollabSessionEventPayload(event: "session",
                                                          phase: info?.phase.rawValue ?? CollabPhase.idle.rawValue,
                                                          participants: roster.count), doc: info?.doc)
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
