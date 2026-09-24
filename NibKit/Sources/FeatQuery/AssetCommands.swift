import Foundation
import NibContracts

/// Byte inputs of the asset commands: base64 (optionally a data: URL) or a url resolved by `ctx.inputFile`.
@MainActor
enum AssetBytes {
    static func ext(_ s: String) throws -> String {
        var e = s.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        guard (1...10).contains(e.count), e.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw NibError(.invalidParams, "ext must be a file extension such as png, jpg, gif or pdf", path: "$.ext")
        }
        return e
    }

    static func decode(_ base64: String, path: String) throws -> Data {
        var s = base64
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") { s = String(s[s.index(after: comma)...]) }
        guard let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw NibError(.invalidParams, "not valid base64 data", path: path)
        }
        return data
    }

    /// tmp: refs, https and (user only) file:// all go through `ctx.inputFile`; the read happens off the main actor.
    static func load(base64: String?, url: String?, _ ctx: CommandContext) async throws -> Data {
        switch (base64, url) {
        case (.some(let b), .none):
            return try decode(b, path: "$.base64")
        case (.none, .some(let u)):
            let file = try await ctx.inputFile(u)
            do {
                return try await Task.detached { try Data(contentsOf: file) }.value
            } catch {
                throw NibError(.notFound, "cannot read \(u)", path: "$.url", hint: "upload the bytes with asset.upload")
            }
        default:
            throw NibError(.invalidParams, "pass exactly one of base64 or url", path: "$.base64",
                           hint: "url takes a tmp: ref from asset.upload or an https URL")
        }
    }
}

// MARK: - asset.put

struct AssetPut: NibCommand {
    struct Params: Codable {
        var doc: String
        var base64: String?
        var url: String?
        var ext: String
    }

    struct Output: Codable {
        var asset: String
        var doc: String
        var bytes: Int
    }

    static let descriptor = CommandDescriptor(
        id: "asset.put", title: "Store Asset",
        summary: "Store a binary asset in a document from base64 or a url (tmp: ref from asset.upload, or https); returns the asset name for image/pdf/tape items.",
        params: .obj(["doc": .ref, "base64": .str("file bytes as base64"),
                      "url": .str("tmp:<name> from asset.upload, or https://…"),
                      "ext": .str("file extension: png, jpg, gif, pdf…")], required: ["doc", "ext"]),
        examples: [["doc": "doc:FIXTUREDOC01", "ext": "png",
                    "base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        try Shapes.requireUnlocked(doc, ctx)
        _ = try ctx.workspace.content(doc)
        let ext = try AssetBytes.ext(p.ext)
        let data = try await AssetBytes.load(base64: p.base64, url: p.url, ctx)
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        // Hashing and writing large files stays off the main actor (AssetStore is thread-safe).
        let ref = try await Task.detached { try store.put(data, ext: ext, doc: doc) }.value
        return Output(asset: ref.name, doc: NodeRef.document(doc).description, bytes: data.count)
    }
}

// MARK: - asset.get

struct AssetGet: NibCommand {
    struct Params: Codable {
        var doc: String
        var asset: String
    }

    struct Output: Codable {
        var asset: String
        var url: String
        var ext: String
        var bytes: Int
        var base64: String?
    }

    static let descriptor = CommandDescriptor(
        id: "asset.get", title: "Get Asset",
        summary: "Read a document asset: a tmp: url usable by any url-taking command, plus base64 when it is small (≤ 12 KB).",
        params: .obj(["doc": .ref, "asset": .str("asset name, e.g. from an image item's 'asset'")], required: ["doc", "asset"]),
        examples: [["doc": "doc:FIXTUREDOC01", "asset": "fixture-image.png"]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        try Shapes.requireUnlocked(doc, ctx)
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        var name = p.asset
        if name.hasPrefix("assets/") { name.removeFirst("assets/".count) }
        let ref = AssetRef(name)
        let ext = ref.ext.isEmpty ? "bin" : ref.ext
        let result: (Data, AssetRef)
        do {
            result = try await Task.detached { () throws -> (Data, AssetRef) in
                let data = try store.data(ref, doc: doc)
                return (data, try store.putTemporary(data, ext: ext))
            }.value
        } catch let e as NibError {
            throw e
        } catch {
            throw NibError(.notFound, "asset \(name) not found in document \(doc)", path: "$.asset")
        }
        let (data, tmp) = result
        return Output(asset: ref.name, url: "tmp:" + tmp.name, ext: ext, bytes: data.count,
                      base64: data.count <= Shapes.inlineAssetBytes ? data.base64EncodedString() : nil)
    }
}

// MARK: - asset.upload

struct AssetUpload: NibCommand {
    struct Params: Codable {
        var base64: String
        var ext: String
    }

    struct Output: Codable {
        var url: String
        var bytes: Int
    }

    static let descriptor = CommandDescriptor(
        id: "asset.upload", title: "Upload Temporary Asset",
        summary: "Store bytes as a temporary asset (1 h) and return its tmp: url for any url-taking command (asset.put, import.files, image.insert…).",
        params: .obj(["base64": .str("file bytes as base64"), "ext": .str("file extension: png, jpg, pdf…")],
                     required: ["base64", "ext"]),
        examples: [["ext": "png",
                    "base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let ext = try AssetBytes.ext(p.ext)
        let data = try AssetBytes.decode(p.base64, path: "$.base64")
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        let tmp = try await Task.detached { try store.putTemporary(data, ext: ext) }.value
        return Output(url: "tmp:" + tmp.name, bytes: data.count)
    }
}
