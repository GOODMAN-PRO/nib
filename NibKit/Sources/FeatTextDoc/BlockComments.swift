import UIKit
import SwiftUI
import Combine
import os
import NibContracts
import NibDesign

// Inline comments on selected text of text-document blocks (D-131). A comment is a `BlockComment` stored on its block
// with a UTF-16 range of the block's plain text; a reply is a new comment on the same range, so a thread is every
// comment of one block that shares a range. The four commands below own every change; the editor adds ⇧⌘M, the
// edit-menu and block-menu entries, the highlight on commented text, the comment card and the Comments tab.

// MARK: - block.comment

struct BlockCommentAdd: NibCommand {
    struct Params: Codable {
        var ref: String
        var range: [Int]
        var text: String
        var id: String?
    }

    struct Output: Codable {
        /// The block the comment is on (block:D/B).
        var block: String
        /// The new comment's id (pass it to block.editComment / deleteComment / resolveComment).
        var comment: String
    }

    private static let ex1: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "range": [6, 6],
                                         "text": "Is this the right word?"]
    private static let ex2: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK01", "range": [0, 7],
                                         "text": "A shorter title?", "id": "CMTTITLE0001"]

    static let descriptor = CommandDescriptor(
        id: "block.comment", title: "Add Comment",
        summary: "Comment on text in a text-document block: range [start, length] in UTF-16 units of its plain text. A reply is another comment on the same range.",
        params: .obj([
            "ref": .ref,
            "range": .arr(.int(min: 0), "[start, length] in UTF-16 units of the block's plain text (query.get shows the text); length at least 1"),
            "text": .str("the comment"),
            "id": .str("your own id for the comment, [A-Za-z0-9_-]{1,64}")
        ], required: ["ref", "range", "text"]),
        examples: [ex1, ex2],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, id) = try BlockRules.blockRef(p.ref, path: "$.ref")
        if let c = p.id, !NibID.isValid(c) {
            throw NibError.invalid("id must be 1-64 characters of [A-Za-z0-9_-]", path: "$.id")
        }
        let text = try BlockCommentRules.text(p.text, path: "$.text")
        try BlockCommentRules.checkWritable(doc, ctx)
        let author = BlockCommentRules.author(for: ctx.principal, settings: ctx.services.settings)
        let commentID = p.id.map { NibID($0) } ?? NibID.make()
        try ctx.mutate { (tx: DocTransaction) -> Void in
            var b = try BlockRules.liveBlock(id, doc: doc, in: tx.content(doc), path: "$.ref")
            try BlockCommentRules.commentable(b, path: "$.ref")
            let r = try BlockCommentRules.range(p.range, length: BlockCommentRules.length(of: b), path: "$.range",
                                                allowEmpty: false)
            var comments = b.comments ?? []
            guard !comments.contains(where: { $0.id == commentID }) else {
                throw NibError(.invalidParams, "block \(id.raw) already has a comment \(commentID.raw)", path: "$.id",
                               hint: "choose another id or leave it out")
            }
            comments.append(BlockComment(id: commentID, author: author, text: text, at: Date().timeIntervalSince1970,
                                         resolved: false, rangeStart: r.location, rangeLength: r.length))
            b.comments = comments
            try tx.put(b, doc: doc)
        }
        return Output(block: NodeRef.block(doc, id).description, comment: commentID.raw)
    }
}

// MARK: - block.editComment

struct BlockCommentEdit: NibCommand {
    struct Params: Codable {
        var ref: String
        var comment: String
        var text: String
        /// Additive (ARCHITECTURE §6.1): moves the comment to another range of the block's text (of `block`'s text when
        /// that is given).
        var range: [Int]?
        /// Additive: moves the comment to another block of the same document (block:D/B), with `range` in that
        /// block's text. Its id, author, time and state stay. The comment may come from a block deleted in the same
        /// change (a block merged into the one before it keeps its comments this way).
        var block: String?
    }

    private static let ex1: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "comment": "FIXTURECMB01",
                                         "text": "Nice opening"]
    private static let ex2: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "comment": "FIXTURECMB01",
                                         "text": "Nice", "range": [6, 6]]
    private static let ex3: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "comment": "FIXTURECMB01",
                                         "text": "Nice", "block": "block:FIXTUREDOC02/FIXTUREBLK01", "range": [0, 7]]

    static let descriptor = CommandDescriptor(
        id: "block.editComment", title: "Edit Comment",
        summary: "Change the text of a comment on a text-document block; optionally move it to range [start, length] of its block, or of another block.",
        params: .obj([
            "ref": .ref,
            "comment": .str("the comment's id (query.get lists a block's comments)"),
            "text": .str("the new text of the comment"),
            "range": .arr(.int(min: 0), "optional: [start, length] to move the comment to, in UTF-16 units of the block's plain text"),
            "block": .str("optional: block:<doc>/<block> of the same document to move the comment to (range is then required, in that block's text)")
        ], required: ["ref", "comment", "text"]),
        examples: [ex1, ex2, ex3],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, id) = try BlockRules.blockRef(p.ref, path: "$.ref")
        let text = try BlockCommentRules.text(p.text, path: "$.text")
        try BlockCommentRules.checkWritable(doc, ctx)
        if let raw = p.block {
            let (targetDoc, target) = try BlockRules.blockRef(raw, path: "$.block")
            guard targetDoc == doc else {
                throw NibError(.invalidParams, "a comment moves only to a block of its own document", path: "$.block",
                               hint: "pass a block of doc:\(doc.raw)")
            }
            if target != id { return try move(p, text: text, doc: doc, from: id, to: target, ctx) }
        }
        let current = try BlockRules.liveBlock(id, doc: doc, in: ctx.workspace.content(doc), path: "$.ref")
        let i = try BlockCommentRules.index(of: p.comment, in: current, path: "$.comment")
        var edited = current.comments?[i] ?? BlockComment(author: "", text: text)
        edited.text = text
        if let raw = p.range {
            let r = try BlockCommentRules.range(raw, length: BlockCommentRules.length(of: current), path: "$.range",
                                                allowEmpty: true)
            edited.rangeStart = r.location
            edited.rangeLength = r.length
        }
        // Nothing changes: no write, so no empty undo step.
        guard edited != current.comments?[i] else { return NoResult() }
        try ctx.mutate { (tx: DocTransaction) -> Void in
            var b = try BlockRules.liveBlock(id, doc: doc, in: tx.content(doc), path: "$.ref")
            let j = try BlockCommentRules.index(of: p.comment, in: b, path: "$.comment")
            var c = b.comments?[j] ?? edited
            c.text = edited.text
            c.rangeStart = edited.rangeStart
            c.rangeLength = edited.rangeLength
            b.comments?[j] = c
            try tx.put(b, doc: doc)
        }
        return NoResult()
    }

    /// Takes the comment off `source` (a live block, or one deleted earlier in the same change) and adds it to the live
    /// text block `target` at `range`, in one write.
    private static func move(_ p: Params, text: String, doc: DocumentID, from source: NibID, to target: NibID,
                             _ ctx: CommandContext) throws -> NoResult {
        guard let raw = p.range else {
            throw NibError(.invalidParams, "moving a comment to another block needs its range there", path: "$.range",
                           hint: "pass range: [start, length] in the target block's plain text")
        }
        try ctx.mutate { (tx: DocTransaction) -> Void in
            let content = try tx.content(doc)
            guard var from = BlockCommentRules.block(source, holding: p.comment, in: content) else {
                guard content.blocks.contains(where: { $0.id == source }) else {
                    throw BlockRules.missing(source, doc: doc, path: "$.ref")
                }
                throw BlockCommentRules.missingComment(p.comment, block: source, path: "$.comment")
            }
            var to = try BlockRules.liveBlock(target, doc: doc, in: content, path: "$.block")
            try BlockCommentRules.commentable(to, path: "$.block")
            guard !(to.comments ?? []).contains(where: { $0.id.raw == p.comment }) else {
                throw NibError(.invalidParams, "block \(target.raw) already has a comment \(p.comment)", path: "$.block",
                               hint: "a block's comment ids are unique; delete that one first")
            }
            let r = try BlockCommentRules.range(raw, length: BlockCommentRules.length(of: to), path: "$.range",
                                                allowEmpty: true)
            let i = try BlockCommentRules.index(of: p.comment, in: from, path: "$.comment")
            var comments = from.comments ?? []
            var c = comments.remove(at: i)
            from.comments = comments.isEmpty ? nil : comments
            c.text = text
            c.rangeStart = r.location
            c.rangeLength = r.length
            to.comments = (to.comments ?? []) + [c]
            try tx.put(from, doc: doc)
            try tx.put(to, doc: doc)
        }
        return NoResult()
    }
}

// MARK: - block.deleteComment

struct BlockCommentDelete: NibCommand {
    struct Params: Codable {
        var ref: String
        var comment: String
    }

    private static let ex1: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "comment": "FIXTURECMB01"]

    static let descriptor = CommandDescriptor(
        id: "block.deleteComment", title: "Delete Comment",
        summary: "Delete one comment from a text-document block (its replies are separate comments and stay). Undoable.",
        params: .obj([
            "ref": .ref,
            "comment": .str("the comment's id (query.get lists a block's comments)")
        ], required: ["ref", "comment"]),
        examples: [ex1],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, id) = try BlockRules.blockRef(p.ref, path: "$.ref")
        try BlockCommentRules.checkWritable(doc, ctx)
        try ctx.mutate { (tx: DocTransaction) -> Void in
            var b = try BlockRules.liveBlock(id, doc: doc, in: tx.content(doc), path: "$.ref")
            let i = try BlockCommentRules.index(of: p.comment, in: b, path: "$.comment")
            var comments = b.comments ?? []
            comments.remove(at: i)
            b.comments = comments.isEmpty ? nil : comments
            try tx.put(b, doc: doc)
        }
        return NoResult()
    }
}

// MARK: - block.resolveComment

struct BlockCommentResolve: NibCommand {
    struct Params: Codable {
        var ref: String
        var comment: String
        var resolved: Bool
    }

    private static let ex1: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "comment": "FIXTURECMB01",
                                         "resolved": true]

    static let descriptor = CommandDescriptor(
        id: "block.resolveComment", title: "Resolve Comment",
        summary: "Mark a comment on a text-document block as resolved (true) or open it again (false).",
        params: .obj([
            "ref": .ref,
            "comment": .str("the comment's id (query.get lists a block's comments)"),
            "resolved": .bool("true = resolved, false = open")
        ], required: ["ref", "comment", "resolved"]),
        examples: [ex1],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, id) = try BlockRules.blockRef(p.ref, path: "$.ref")
        try BlockCommentRules.checkWritable(doc, ctx)
        let current = try BlockRules.liveBlock(id, doc: doc, in: ctx.workspace.content(doc), path: "$.ref")
        let i = try BlockCommentRules.index(of: p.comment, in: current, path: "$.comment")
        guard current.comments?[i].resolved != p.resolved else { return NoResult() }
        try ctx.mutate { (tx: DocTransaction) -> Void in
            var b = try BlockRules.liveBlock(id, doc: doc, in: tx.content(doc), path: "$.ref")
            let j = try BlockCommentRules.index(of: p.comment, in: b, path: "$.comment")
            b.comments?[j].resolved = p.resolved
            try tx.put(b, doc: doc)
        }
        return NoResult()
    }
}

// MARK: - Rules (pure, shared with the editor and the tests)

enum BlockCommentRules {
    static let maxTextLength = 10_000

    /// The comment's text, trimmed; never empty, at most `maxTextLength` characters.
    static func text(_ raw: String, path: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            throw NibError(.invalidParams, "the comment is empty", path: path, hint: "pass the comment's text")
        }
        guard t.count <= maxTextLength else {
            throw NibError(.invalidParams, "a comment is at most \(maxTextLength) characters", path: path,
                           hint: "shorten it, or continue in a reply (block.comment on the same range)")
        }
        return t
    }

    /// Length of the text comments point into (UTF-16 units of the block's plain text).
    static func length(of b: TextBlock) -> Int { (b.text.plainText as NSString).length }

    static func commentable(_ b: TextBlock, path: String) throws {
        guard BlockRules.isText(b.kind) else {
            throw NibError(.invalidParams, "a \(b.kind.rawValue) block has no text to comment on", path: path,
                           hint: "comment on a paragraph, heading, list item, to-do, quote or code block")
        }
    }

    /// `[start, length]` inside a text of `length` UTF-16 units. `allowEmpty` admits a zero length (a comment whose
    /// words were deleted keeps its place).
    static func range(_ a: [Int], length: Int, path: String, allowEmpty: Bool) throws -> NSRange {
        guard a.count == 2 else {
            throw NibError(.invalidParams, "range must be [start, length]", path: path,
                           hint: "for example [0, 5] for the first five characters")
        }
        let start = a[0], count = a[1]
        guard start >= 0, start <= length, count >= (allowEmpty ? 0 : 1), count <= length - start else {
            throw NibError(.invalidParams, "range [\(start), \(count)] is not inside the block's text (\(length) UTF-16 units)",
                           path: path, hint: "pass [start, length] with length ≥ 1 and start + length ≤ \(length)")
        }
        return NSRange(location: start, length: count)
    }

    /// The record of block `id` that holds `comment`: the live one first, else one deleted (a comment moves out of a
    /// block merged away in the same change).
    static func block(_ id: NibID, holding comment: String, in content: DocumentContent) -> TextBlock? {
        let records = content.blocks.filter { $0.id == id && ($0.comments ?? []).contains { $0.id.raw == comment } }
        return records.first { !$0.deleted } ?? records.first
    }

    static func index(of comment: String, in b: TextBlock, path: String) throws -> Int {
        guard let i = b.comments?.firstIndex(where: { $0.id.raw == comment }) else {
            throw missingComment(comment, block: b.id, path: path)
        }
        return i
    }

    static func missingComment(_ comment: String, block: NibID, path: String) -> NibError {
        NibError(.notFound, "comment \(comment) not found on block \(block.raw)", path: path,
                 hint: "query.get {ref: \"block:…\"} lists the block's comments and their ids")
    }

    /// The author stored on a comment: the profile name for the user, "Assistant" for the AI, else the plugin or
    /// bridge client id (the same rule as page comments, F037).
    static func author(for principal: Principal, settings: SettingsStore) -> String {
        switch principal {
        case .user: return settings.get(NibSettings.authorName).trimmingCharacters(in: .whitespacesAndNewlines)
        case .ai: return "Assistant"
        case .plugin(let id), .bridge(let id): return id
        case .sync: return ""
        }
    }

    /// Documents a newer Nib wrote open read-only (ARCHITECTURE §4.2): their comments cannot change here.
    @MainActor
    static func checkWritable(_ doc: DocumentID, _ ctx: CommandContext) throws {
        if ctx.isReadOnly(doc) {
            throw NibError(.unsupported, "doc:\(doc.raw) is read-only on this device",
                           hint: "a newer version of Nib saved it; update Nib to change it")
        }
    }
}

/// Keeps comment ranges on their words when a block's text changes: the change is the one span between the common
/// prefix and suffix of the old and new text (exact for typing, pasting and deleting), and every range is mapped
/// through it.
enum CommentAnchors {
    /// The changed span: `start..<oldEnd` of the old text became `start..<newEnd` of the new one (UTF-16 offsets).
    struct Edit: Equatable {
        let start: Int
        let oldEnd: Int
        let newEnd: Int
        var delta: Int { newEnd - oldEnd }
    }

    static func edit(from old: String, to new: String) -> Edit? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return nil }
        let shorter = min(a.count, b.count)
        var p = 0
        while p < shorter && a[p] == b[p] { p += 1 }
        var s = 0
        while s < shorter - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return Edit(start: p, oldEnd: a.count - s, newEnd: b.count - s)
    }

    /// Where `range` goes. Text inserted at a range's start or end stays outside it; text replaced inside it (or
    /// across one of its ends) becomes part of it; a range whose text is deleted collapses to where it was.
    static func map(_ range: NSRange, through e: Edit) -> NSRange {
        func start(_ x: Int) -> Int {
            if x < e.start { return x }
            if x >= e.oldEnd { return x + e.delta }
            return e.start
        }
        func end(_ x: Int) -> Int {
            if x <= e.start { return x }
            if x >= e.oldEnd { return x + e.delta }
            return e.newEnd
        }
        let lo = start(range.location)
        guard range.length > 0 else { return NSRange(location: lo, length: 0) }
        let hi = max(lo, end(range.location + range.length))
        return NSRange(location: lo, length: hi - lo)
    }

    /// `comments` moved from `old` to `new` text; unchanged when the text is the same.
    static func rebase(_ comments: [BlockComment], from old: String, to new: String) -> [BlockComment] {
        guard let e = edit(from: old, to: new) else { return comments }
        let length = (new as NSString).length
        return comments.map { c in
            let r = clamp(map(NSRange(location: c.rangeStart, length: c.rangeLength), through: e), length: length)
            var out = c
            out.rangeStart = r.location
            out.rangeLength = r.length
            return out
        }
    }

    /// A range cut to a text of `length` UTF-16 units (ranges stored by others may point past the end).
    static func clamp(_ r: NSRange, length: Int) -> NSRange {
        let lo = min(max(0, r.location), length)
        let hi = min(max(lo, r.location + max(0, r.length)), length)
        return NSRange(location: lo, length: hi - lo)
    }

    static func range(of c: BlockComment, length: Int) -> NSRange {
        clamp(NSRange(location: c.rangeStart, length: c.rangeLength), length: length)
    }

    // MARK: Text moving between blocks

    /// One block's text change within an undo group: its text before and after (plain), its comments before.
    struct TextEdit {
        let block: NibID
        let old: String
        let new: String
        let comments: [BlockComment]
    }

    /// A comment to move, and its range in the block it goes to.
    struct Carried: Equatable {
        let comment: NibID
        let range: NSRange
    }

    /// Return in the middle of a block: one of `edits` cut its block's text to a head, and a new block starts with the
    /// `inserted` text that was cut off (a selection Return replaced may be gone between them). The comments that lay
    /// wholly in that rest go to the new block, measured from its start. The newest matching edit wins.
    static func split(_ edits: [TextEdit], inserted: String) -> [(block: NibID, comment: NibID, range: NSRange)] {
        let tail = Array(inserted.utf16)
        guard !tail.isEmpty else { return [] }
        for e in edits.reversed() where !e.comments.isEmpty {
            let old = Array(e.old.utf16), head = Array(e.new.utf16)
            guard head.count + tail.count <= old.count, old.starts(with: head),
                  old.suffix(tail.count).elementsEqual(tail) else { continue }
            let start = old.count - tail.count
            return e.comments.compactMap { c in
                guard c.rangeLength > 0, c.rangeStart >= start, c.rangeStart + c.rangeLength <= old.count else { return nil }
                return (e.block, c.id, NSRange(location: c.rangeStart - start, length: c.rangeLength))
            }
        }
        return []
    }

    /// Joining: one of `edits` appended exactly the `deleted` block's text to its block, and that block was deleted in
    /// the same change. Its comments move over, after the text that was there. Nil when no edit joined it.
    static func join(_ edits: [TextEdit], deleted: String, comments: [BlockComment]) -> (block: NibID, comments: [Carried])? {
        let text = Array(deleted.utf16)
        for e in edits.reversed() {
            let old = Array(e.old.utf16), joined = Array(e.new.utf16)
            guard !text.isEmpty, joined.count == old.count + text.count, joined.starts(with: old),
                  joined.suffix(text.count).elementsEqual(text) else { continue }
            let carried = comments.map { c -> Carried in
                let r = clamp(NSRange(location: c.rangeStart, length: c.rangeLength), length: text.count)
                return Carried(comment: c.id, range: NSRange(location: r.location + old.count, length: r.length))
            }
            return (e.block, carried)
        }
        return nil
    }
}

// MARK: - Threads

/// The comments of one block that share one range: the first is the comment, the others are its replies.
struct CommentThread: Identifiable, Equatable {
    let block: NibID
    var range: NSRange
    /// Oldest first.
    var comments: [BlockComment]

    var id: String { block.raw + "/" + (comments.first?.id.raw ?? "") }
    var isResolved: Bool { !comments.isEmpty && comments.allSatisfy { $0.resolved } }
    var replyCount: Int { max(0, comments.count - 1) }

    func contains(_ comment: NibID) -> Bool { comments.contains { $0.id == comment } }
}

enum CommentThreads {
    /// A block's threads in text order (then by time).
    static func threads(in block: TextBlock) -> [CommentThread] {
        guard let comments = block.comments, !comments.isEmpty else { return [] }
        var order: [[Int]] = []
        var byRange: [[Int]: [BlockComment]] = [:]
        for c in comments {
            let key = [c.rangeStart, c.rangeLength]
            if byRange[key] == nil { order.append(key) }
            byRange[key, default: []].append(c)
        }
        var out: [CommentThread] = order.map { key in
            let list = (byRange[key] ?? []).sorted { ($0.at, $0.id.raw) < ($1.at, $1.id.raw) }
            return CommentThread(block: block.id, range: NSRange(location: key[0], length: key[1]), comments: list)
        }
        out.sort { a, b in
            let ta = a.comments.first?.at ?? 0, tb = b.comments.first?.at ?? 0
            return (a.range.location, ta, a.id) < (b.range.location, tb, b.id)
        }
        return out
    }

    /// Every thread of a document, in block order.
    static func threads(in blocks: [TextBlock]) -> [CommentThread] {
        blocks.flatMap { threads(in: $0) }
    }

    /// Threads whose text meets `range`: overlapping a selection, or around a caret (its ends included).
    static func threads(in block: TextBlock, touching range: NSRange) -> [CommentThread] {
        threads(in: block).filter { touches($0.range, range) }
    }

    static func touches(_ a: NSRange, _ b: NSRange) -> Bool {
        let aEnd = a.location + a.length, bEnd = b.location + b.length
        if a.length == 0 || b.length == 0 { return a.location <= bEnd && b.location <= aEnd }
        return a.location < bEnd && b.location < aEnd
    }

    /// The commented words as one line (for cards, lists and VoiceOver); empty when they were deleted.
    static func excerpt(_ range: NSRange, in block: TextBlock, limit: Int = 140) -> String {
        let text = block.text.plainText as NSString
        let r = CommentAnchors.clamp(range, length: text.length)
        guard r.length > 0 else { return "" }
        let words = text.substring(with: r).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard words.count > limit else { return words }
        return String(words.prefix(limit)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

// MARK: - Keeping comments on their words

/// Moves comment ranges with the text they point at. When a commit changes a block's text but not its comments
/// (typing, block.update from the assistant, a plugin or the bridge), the comments are re-anchored right after with
/// block.editComment in the SAME undo group, so undo restores text and ranges together (the pattern of
/// ARCHITECTURE §6.3 rebasing: a commit observer finishing a change in its group). Undo, redo, selective revert and
/// sync write whole records, comments included, and are left alone.
///
/// Text that moves to another block within one undo group takes its comments along (block.editComment with `block`):
/// Return in the middle of a block cuts it and starts a new block with the rest (the comments on the rest go to the new
/// block), and joining a block to the one before it (Delete at its start, forward delete at the end of the one before)
/// appends its text there and deletes it (its comments move over, after the text that was there).
@MainActor
final class CommentAnchorKeeper {
    static let serviceKey = "textdocextras.commentAnchors"
    /// Text edits are remembered for this many recent undo groups (a split or a join is recognised within one group),
    /// at most `editsPerGroup` each.
    static let rememberedGroups = 8
    static let editsPerGroup = 4

    private struct Key: Hashable {
        let doc: DocumentID
        let block: NibID
    }

    private struct Pending {
        /// The comments as the block stores them now (still on the old text).
        var stored: [BlockComment]
        /// The same comments on the block's newest text.
        var target: [BlockComment]
        var group: String
    }

    /// A comment going to another block of its document, at `range` there.
    private struct Move {
        let doc: DocumentID
        let comment: NibID
        let from: NibID
        let to: NibID
        let range: NSRange
        let group: String
    }

    private weak var app: NibApp?
    private var subscription: EventSubscription?
    private var pending: [Key: Pending] = [:]
    private var moves: [Move] = []
    private var recent: [(group: String, edits: [CommentAnchors.TextEdit])] = []
    private var tail: Task<Void, Never>?
    private let log = Logger(subsystem: "app.nib", category: "textdocextras")

    /// Installs the keeper once per app and returns it.
    @discardableResult
    static func install(in app: NibApp) -> CommentAnchorKeeper {
        if let k = app.services.get(serviceKey, as: CommentAnchorKeeper.self) { return k }
        let keeper = CommentAnchorKeeper()
        keeper.app = app
        keeper.subscription = app.bus.observeCommits { [weak keeper] changeset in keeper?.observe(changeset) }
        app.services.set(keeper, for: serviceKey)
        return keeper
    }

    deinit {
        subscription?.cancel()
    }

    /// Returns once every re-anchoring scheduled so far has been written.
    func idle() async {
        await tail?.value
    }

    func observe(_ cs: Changeset) {
        if case .sync = cs.principal { return }
        switch cs.command {
        case CommandIDs.undo, CommandIDs.redo, CommandIDs.revertGroup: return
        default: break
        }
        var scheduled = false
        for m in cs.mutations {
            guard case let .block(doc, before, after) = m else { continue }
            if let before = before, !before.deleted, !after.deleted, BlockRules.isText(before.kind),
               BlockRules.isText(after.kind), before.text != after.text {
                remember(CommentAnchors.TextEdit(block: after.id, old: before.text.plainText, new: after.text.plainText,
                                                 comments: before.comments ?? []),
                         doc: doc, group: cs.group)
                if rebase(doc: doc, before: before, after: after, group: cs.group) { scheduled = true }
            } else if before?.deleted ?? true, !after.deleted, BlockRules.isText(after.kind) {
                // A new block: the rest of a block cut by Return?
                let edits = remembered(cs.group, doc: doc).filter { $0.block != after.id }
                for found in CommentAnchors.split(edits, inserted: after.text.plainText) {
                    moves.append(Move(doc: doc, comment: found.comment, from: found.block, to: after.id,
                                      range: found.range, group: cs.group))
                    scheduled = true
                }
            } else if let before = before, !before.deleted, after.deleted, let comments = before.comments,
                      !comments.isEmpty, BlockRules.isText(before.kind) {
                // A block deleted with comments: joined to another block in the same change?
                let edits = remembered(cs.group, doc: doc).filter { $0.block != before.id }
                if let found = CommentAnchors.join(edits, deleted: before.text.plainText, comments: comments) {
                    for c in found.comments {
                        moves.append(Move(doc: doc, comment: c.comment, from: before.id, to: found.block,
                                          range: c.range, group: cs.group))
                    }
                    scheduled = true
                }
            }
        }
        guard scheduled else { return }
        let previous = tail
        tail = Task { @MainActor [weak self] in
            await previous?.value
            await self?.flush()
        }
    }

    /// Schedules the re-anchoring of a block's comments after its text changed; true when something is to write.
    private func rebase(doc: DocumentID, before: TextBlock, after: TextBlock, group: String) -> Bool {
        guard let stored = after.comments, !stored.isEmpty, before.comments == after.comments else { return false }
        let key = Key(doc: doc, block: after.id)
        // A re-anchoring still waiting for its turn is continued from where it left the comments.
        let base = pending[key].flatMap { $0.stored == stored ? $0.target : nil } ?? stored
        let target = CommentAnchors.rebase(base, from: before.text.plainText, to: after.text.plainText)
        if target == stored {
            pending[key] = nil
            return false
        }
        pending[key] = Pending(stored: stored, target: target, group: group)
        return true
    }

    private func remember(_ edit: CommentAnchors.TextEdit, doc: DocumentID, group: String) {
        let key = group + "\u{1F}" + doc.raw
        if let i = recent.firstIndex(where: { $0.group == key }) {
            recent[i].edits.append(edit)
            if recent[i].edits.count > Self.editsPerGroup { recent[i].edits.removeFirst() }
        } else {
            recent.append((key, [edit]))
            if recent.count > Self.rememberedGroups { recent.removeFirst() }
        }
    }

    /// The text edits of `group` in `doc`, oldest first.
    private func remembered(_ group: String, doc: DocumentID) -> [CommentAnchors.TextEdit] {
        let key = group + "\u{1F}" + doc.raw
        return recent.first { $0.group == key }?.edits ?? []
    }

    private func flush() async {
        let moving = moves
        let work = pending
        moves = []
        pending = [:]
        guard let app = app else { return }
        // Moves first: a comment that goes to another block is not re-anchored in the block it leaves.
        for m in moving {
            guard let content = try? app.workspace.content(m.doc),
                  let from = BlockCommentRules.block(m.from, holding: m.comment.raw, in: content),
                  let c = from.comments?.first(where: { $0.id == m.comment }), Self.hasText(c),
                  let to = content.blocks.first(where: { $0.id == m.to && !$0.deleted }), BlockRules.isText(to.kind),
                  !(to.comments ?? []).contains(where: { $0.id == m.comment }) else { continue }
            let range = CommentAnchors.clamp(m.range, length: BlockCommentRules.length(of: to))
            await edit(["ref": .string(NodeRef.block(m.doc, m.from).description), "comment": .string(m.comment.raw),
                        "text": .string(c.text), "block": .string(NodeRef.block(m.doc, m.to).description),
                        "range": CommentActions.range(range)], group: m.group)
        }
        for (key, job) in work.sorted(by: { ($0.key.doc.raw, $0.key.block.raw) < ($1.key.doc.raw, $1.key.block.raw) }) {
            guard let content = try? app.workspace.content(key.doc),
                  let block = content.blocks.first(where: { $0.id == key.block && !$0.deleted }) else { continue }
            let now = Dictionary((block.comments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let was = Dictionary(job.stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let length = BlockCommentRules.length(of: block)
            let ref = NodeRef.block(key.doc, key.block).description
            for c in job.target {
                // Only a comment still where the change found it: one moved, edited or deleted since keeps that.
                guard let current = now[c.id], let stored = was[c.id], Self.hasText(current),
                      current.rangeStart == stored.rangeStart, current.rangeLength == stored.rangeLength,
                      c.rangeStart != stored.rangeStart || c.rangeLength != stored.rangeLength else { continue }
                let range = CommentAnchors.clamp(NSRange(location: c.rangeStart, length: c.rangeLength), length: length)
                await edit(["ref": .string(ref), "comment": .string(c.id.raw), "text": .string(current.text),
                            "range": CommentActions.range(range)], group: job.group)
            }
        }
    }

    private static func hasText(_ c: BlockComment) -> Bool {
        !c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func edit(_ params: JSONValue, group: String) async {
        guard let app = app else { return }
        do {
            let inv = Invocation(command: BlockCommentEdit.descriptor.id, params: params, principal: .user, group: group)
            _ = try await app.bus.execute(inv)
        } catch {
            let comment = params["comment"]?.stringValue ?? ""
            log.info("comment \(comment, privacy: .public) kept its place: \(NibError.wrap(error).description, privacy: .public)")
        }
    }
}

// MARK: - The editor: ⇧⌘M, menus, highlights

@MainActor
enum BlockCommentsEditor {
    static let keyID = TextDocExtrasHookIDs.prefix + "key.comment"
    static let shortcut = KeyShortcut("m", [.command, .shift])

    /// ⇧⌘M as a registered key command (contracts-v2.2), live only in text documents, so the command bar, the keyboard
    /// settings and plugins see it. While a block is edited the editor serves the same key itself (`TextDocHooks`,
    /// closer to the first responder), and the comment card buds from the selected words; scope `.canvas` keeps the
    /// shell's copy out of the way then. While no text is edited the shell runs panel.open for the Comments tab, with
    /// a composer on the words selected last (`sessionParams`), else the list.
    static func keyDescriptor(owner: String) -> KeyCommandDescriptor {
        var d = KeyCommandDescriptor(id: keyID, title: String(localized: "Add Comment"), shortcut: shortcut,
                                     command: CommandIDs.panelOpen, params: ["id": .string(TextDocCommentsPanel.panelID)],
                                     scope: .canvas, order: 700, owner: owner)
        d.docKinds = [.textDocument]
        d.sessionParams = { session in BlockCommentsEditor.keyParams(session) }
        return d
    }

    /// What ⇧⌘M adds to panel.open in `session`'s window: a composer on the words selected last in its text document
    /// ({block, range, compose: true}), or nothing (the Comments tab opens on its list).
    static func keyParams(_ session: EditorSession) -> JSONValue {
        guard let editor = session.editor as? TextDocViewController, !editor.isReadOnly,
              let selection = TextDocExtrasState.of(editor).lastSelection, let block = editor.block(selection.block),
              BlockRules.isText(block.kind) else { return [:] }
        let range = CommentAnchors.clamp(selection.range, length: BlockCommentRules.length(of: block))
        guard range.length > 0 else { return [:] }
        return ["block": .string(editor.blockRef(block.id)), "range": CommentActions.range(range), "compose": true]
    }

    static func install() {
        let p = TextDocExtrasHookIDs.prefix
        TextDocHooks.addKeyCommandSet(p + "comments.keys", order: 100) { editor in
            guard !editor.isReadOnly, editor.focusedBlockID != nil else { return [] }
            return [TextDocKeyCommand(id: keyID, title: String(localized: "Add Comment"), input: shortcut.key,
                                      modifiers: [.command, .shift]) { editor in beginComment(in: editor) }]
        }
        TextDocHooks.addSelectionObserver(p + "comments.selection", order: 100) { editor in
            rememberSelection(in: editor)
        }
        TextDocHooks.addEditMenuProvider(p + "comments.menu", order: 100) { block, range, isCaption, editor in
            editMenu(block: block, range: range, isCaption: isCaption, editor: editor)
        }
        TextDocHooks.addBlockMenuProvider(p + "comments.block", order: 100) { block, editor in
            blockMenu(block: block, editor: editor)
        }
        TextDocHooks.addCellDecorator(p + "comments.highlight", order: 100) { cell, block, editor in
            decorate(cell, block: block, editor: editor)
        }
    }

    /// Keeps the words selected in a block's text for ⇧⌘M after the keyboard goes; a caret, or a caption, forgets them.
    static func rememberSelection(in editor: TextDocViewController) {
        // The keyboard went (focus left the text): the words selected last stay.
        guard let tv = editor.focusedTextView else { return }
        let state = TextDocExtrasState.of(editor)
        guard tv.role == .body, let id = tv.blockID, tv.selectedRange.length > 0 else {
            if state.lastSelection != nil { state.lastSelection = nil }
            return
        }
        let selection = TextDocSelection(block: id, range: tv.selectedRange)
        if state.lastSelection != selection { state.lastSelection = selection }
    }

    /// ⇧⌘M: a comment on the selection; with only a caret, on the word it is in (else the whole block).
    static func beginComment(in editor: TextDocViewController) {
        guard !editor.isReadOnly, let id = editor.focusedBlockID, let block = editor.block(id),
              BlockRules.isText(block.kind), let tv = editor.focusedTextView, tv.role == .body else { return }
        var range = tv.selectedRange
        if range.length == 0 { range = wordRange(in: tv, at: range.location) ?? NSRange(location: 0, length: tv.textStorage.length) }
        guard range.length > 0 else { return }
        CommentPresenter.newComment(in: editor, block: id, range: range)
    }

    static func editMenu(block: TextBlock, range: NSRange, isCaption: Bool, editor: TextDocViewController) -> [UIMenuElement] {
        guard !isCaption, BlockRules.isText(block.kind) else { return [] }
        var out: [UIMenuElement] = []
        let id = block.id
        if range.length > 0, !editor.isReadOnly {
            out.append(UIAction(title: String(localized: "Add Comment"), image: UIImage(nib: .comment)) { _ in
                CommentPresenter.newComment(in: editor, block: id, range: range)
            })
        }
        let threads = CommentThreads.threads(in: block, touching: range).filter { !$0.isResolved }
        if let first = threads.first {
            let title = threads.count == 1 ? String(localized: "Show Comment") : String(localized: "Show Comments")
            out.append(UIAction(title: title, image: UIImage(nib: .comment)) { _ in
                CommentPresenter.showThread(in: editor, block: id, thread: first)
            })
        }
        guard !out.isEmpty else { return [] }
        return [UIMenu(title: "", options: .displayInline, children: out)]
    }

    static func blockMenu(block: TextBlock, editor: TextDocViewController) -> [UIMenuElement] {
        guard BlockRules.isText(block.kind) else { return [] }
        var out: [UIMenuElement] = []
        let id = block.id
        let length = BlockCommentRules.length(of: block)
        if !editor.isReadOnly, length > 0 {
            out.append(UIAction(title: String(localized: "Comment on Block"), image: UIImage(nib: .comment)) { _ in
                CommentPresenter.newComment(in: editor, block: id, range: NSRange(location: 0, length: length))
            })
        }
        if CommentThreads.threads(in: block).contains(where: { !$0.isResolved }) {
            out.append(UIAction(title: String(localized: "Show Comments"), image: UIImage(nib: .comment)) { _ in
                let params: JSONValue = ["id": .string(TextDocCommentsPanel.panelID),
                                         "block": .string(editor.blockRef(id))]
                editor.app.perform(CommandIDs.panelOpen, params, session: editor.session)
            })
        }
        return out
    }

    /// Washes the commented words of open comments (with a dotted accent underline, so the mark is never colour
    /// alone) and adds VoiceOver actions for them. Drawing attributes only: nothing enters the block's text.
    static func decorate(_ cell: BlockCell, block: TextBlock, editor: TextDocViewController) {
        let tv = cell.textView
        guard BlockRules.isText(block.kind) else {
            CommentHighlighter.apply([], to: tv)
            return
        }
        let open = CommentThreads.threads(in: block).filter { !$0.isResolved }
        let length = tv.textStorage.length
        CommentHighlighter.apply(open.map { CommentAnchors.clamp($0.range, length: length) }.filter { $0.length > 0 }, to: tv)
        guard let first = open.first else {
            tv.accessibilityHint = nil
            return
        }
        let count = open.reduce(0) { $0 + $1.comments.count }
        tv.accessibilityHint = count == 1 ? String(localized: "Has a comment") : String(localized: "Has \(count) comments")
        let id = block.id
        let show = UIAccessibilityCustomAction(name: String(localized: "Show Comments")) { [weak editor] _ in
            guard let editor = editor else { return false }
            CommentPresenter.showThread(in: editor, block: id, thread: first)
            return true
        }
        tv.accessibilityCustomActions = (tv.accessibilityCustomActions ?? []) + [show]
    }

    /// The word around a caret (nil between words).
    static func wordRange(in tv: UITextView, at offset: Int) -> NSRange? {
        guard let position = tv.position(from: tv.beginningOfDocument, offset: offset) else { return nil }
        let tokenizer = tv.tokenizer
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        let backward = UITextDirection(rawValue: UITextStorageDirection.backward.rawValue)
        guard let word = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: forward)
            ?? tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: backward) else { return nil }
        let start = tv.offset(from: tv.beginningOfDocument, to: word.start)
        let end = tv.offset(from: tv.beginningOfDocument, to: word.end)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}

/// Paints comment ranges as drawing-only attributes of the text view's layout (TextKit 2 rendering attributes, or
/// TextKit 1 temporary attributes when the view already runs on TextKit 1), never as text attributes: the text view's
/// text is what the editor writes back to the block, and a highlight there would become the user's highlight.
@MainActor
enum CommentHighlighter {
    static func apply(_ ranges: [NSRange], to tv: UITextView) {
        let wash = NibUIColor.accentWash
        let line = NibUIColor.accent
        if let layout = tv.textLayoutManager {
            let underline = NSUnderlineStyle.single.union(.patternDot).rawValue
            let whole = layout.documentRange
            layout.removeRenderingAttribute(.backgroundColor, for: whole)
            layout.removeRenderingAttribute(.underlineStyle, for: whole)
            layout.removeRenderingAttribute(.underlineColor, for: whole)
            guard let storage = layout.textContentManager as? NSTextContentStorage else { return }
            let origin = storage.documentRange.location
            for r in ranges {
                guard let start = storage.location(origin, offsetBy: r.location),
                      let end = storage.location(start, offsetBy: r.length),
                      let range = NSTextRange(location: start, end: end) else { continue }
                layout.addRenderingAttribute(.backgroundColor, value: wash, for: range)
                layout.addRenderingAttribute(.underlineStyle, value: underline, for: range)
                layout.addRenderingAttribute(.underlineColor, value: line, for: range)
            }
            return
        }
        // Already on TextKit 1 (another part of the app asked the view for its layoutManager). iOS has no temporary
        // attributes, so the wash is a shape layer behind the glyphs, with an accent rule under each line of it.
        let marks: CAShapeLayer
        if let existing = tv.layer.sublayers?.first(where: { $0.name == markLayerName }) as? CAShapeLayer {
            marks = existing
        } else {
            marks = CAShapeLayer()
            marks.name = markLayerName
            tv.layer.insertSublayer(marks, at: 0)
        }
        let rules: CAShapeLayer
        if let existing = marks.sublayers?.first as? CAShapeLayer {
            rules = existing
        } else {
            rules = CAShapeLayer()
            rules.lineDashPattern = [NSNumber(value: Double(NibStroke.hairline * 2)), NSNumber(value: Double(NibStroke.hairline * 2))]
            marks.addSublayer(rules)
        }
        let manager = tv.layoutManager
        let inset = tv.textContainerInset
        let length = tv.textStorage.length
        let fill = CGMutablePath()
        let stroke = CGMutablePath()
        for r in ranges where NSMaxRange(r) <= length {
            let glyphs = manager.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: tv.textContainer) { rect, _ in
                let box = rect.offsetBy(dx: inset.left, dy: inset.top)
                fill.addRect(box)
                stroke.move(to: CGPoint(x: box.minX, y: box.maxY - NibStroke.hairline))
                stroke.addLine(to: CGPoint(x: box.maxX, y: box.maxY - NibStroke.hairline))
            }
        }
        marks.frame = tv.layer.bounds
        marks.path = fill
        marks.fillColor = wash.resolvedColor(with: tv.traitCollection).cgColor
        rules.frame = marks.bounds
        rules.path = stroke
        rules.fillColor = nil
        rules.lineWidth = NibStroke.hairline
        rules.strokeColor = line.resolvedColor(with: tv.traitCollection).cgColor
    }

    private static let markLayerName = TextDocExtrasHookIDs.prefix + "comment.marks"
}

// MARK: - Presenting the comment card

/// Shows the comment card beside the commented words: a Deep popover budded from them through the window's floating
/// host on regular width (DESIGN §13.1), a system sheet on compact width or where the window has no floating host.
@MainActor
enum CommentPresenter {
    static let presentationID = TextDocExtrasHookIDs.prefix + "comment.card"
    static let anchorID = TextDocExtrasHookIDs.prefix + "comment.anchor"

    static func newComment(in editor: TextDocViewController, block id: NibID, range: NSRange) {
        guard !editor.isReadOnly, let block = editor.block(id) else { return }
        let runner = TextDocCommandRunner(app: editor.app, session: editor.session, doc: editor.documentID)
        let excerpt = CommentThreads.excerpt(range, in: block)
        let ref = editor.blockRef(id)
        present(in: editor, block: id, range: range, title: String(localized: "New Comment")) { chrome, dismiss in
            CommentComposerView(excerpt: excerpt, chrome: chrome, onCancel: dismiss) { text in
                dismiss()
                Task { @MainActor in
                    let params: JSONValue = ["ref": .string(ref), "range": [.number(Double(range.location)), .number(Double(range.length))],
                                             "text": .string(text)]
                    guard await runner.run(BlockCommentAdd.descriptor.id, params) != nil else { return }
                    UIAccessibility.post(notification: .announcement, argument: String(localized: "Comment added"))
                }
            }
        }
    }

    static func showThread(in editor: TextDocViewController, block id: NibID, thread: CommentThread) {
        let runner = TextDocCommandRunner(app: editor.app, session: editor.session, doc: editor.documentID)
        let model = CommentThreadModel(runner: runner, block: id, thread: thread)
        present(in: editor, block: id, range: thread.range, title: String(localized: "Comment")) { chrome, dismiss in
            CommentThreadView(model: model, chrome: chrome, showsQuote: true, onClose: dismiss)
        }
    }

    private static func present<Content: View>(in editor: TextDocViewController, block id: NibID, range: NSRange, title: String,
                                               @ViewBuilder content: @escaping (CommentChrome, @escaping @MainActor () -> Void) -> Content) {
        dismiss(in: editor)
        let tv = editor.cell(for: id)?.textView
        let regular = editor.traitCollection.horizontalSizeClass == .regular
        if regular, let tv = tv, let host = editor.session.floatingHost, let rect = textRect(in: tv, range: range),
           host.setAnchor(anchorID, rect: rect, in: tv) {
            let close: @MainActor () -> Void = { [weak host] in
                host?.dismiss(presentationID)
                host?.removeAnchor(anchorID)
            }
            host.present(presentationID, content: AnyView(
                CommentPopover(title: title, onDismiss: close) { content(.popover, close) }))
            return
        }
        let state = TextDocExtrasState.of(editor)
        let hosting = UIHostingController(rootView: AnyView(EmptyView()))
        let close: @MainActor () -> Void = { [weak hosting] in hosting?.presentingViewController?.dismiss(animated: true) }
        hosting.rootView = AnyView(content(.sheet(title), close).background(NibColor.backgroundSecondary))
        hosting.view.backgroundColor = NibUIColor.backgroundSecondary
        hosting.modalPresentationStyle = regular ? .formSheet : .pageSheet
        if let sheet = hosting.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = !regular
        }
        state.commentSheet = hosting
        editor.present(hosting, animated: true)
    }

    /// Closes the card this editor shows, if any.
    static func dismiss(in editor: TextDocViewController) {
        if let host = editor.session.floatingHost, host.isPresenting(presentationID) {
            host.dismiss(presentationID)
            host.removeAnchor(anchorID)
        }
        let state = TextDocExtrasState.of(editor)
        if let sheet = state.commentSheet, sheet.presentingViewController != nil {
            sheet.presentingViewController?.dismiss(animated: false)
        }
        state.commentSheet = nil
    }

    /// The first line rect of `range` in `tv` (the bud grows out of the commented words).
    static func textRect(in tv: UITextView, range: NSRange) -> CGRect? {
        guard let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let end = tv.position(from: start, offset: max(range.length, 0)),
              let textRange = tv.textRange(from: start, to: end) else { return nil }
        let rect = tv.firstRect(for: textRange)
        guard !rect.isNull, !rect.isInfinite, rect.width.isFinite else { return nil }
        return rect.width > 0 ? rect : rect.insetBy(dx: -NibSpacing.xxs, dy: 0)
    }
}

/// Where a comment view sits: a budded popover, a system sheet (its header carries the title), or a sidebar row.
enum CommentChrome: Equatable {
    case popover
    case sheet(String)
    case panel
}

/// The budded popover around a comment view; tapping outside closes it (the bud sets `isPresented` to false).
struct CommentPopover<Content: View>: View {
    let title: String
    let onDismiss: @MainActor () -> Void
    let content: Content
    @State private var isPresented = true

    init(title: String, onDismiss: @escaping @MainActor () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        NibBudPopover(id: CommentPresenter.presentationID, source: CommentPresenter.anchorID, isPresented: $isPresented,
                      title: title, placement: .below) {
            content
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { onDismiss() }
        }
    }
}

// MARK: - Actions and models

@MainActor
enum CommentActions {
    static func range(_ r: NSRange) -> JSONValue { [.number(Double(r.location)), .number(Double(r.length))] }

    /// A reply is a new comment on the thread's range.
    static func reply(_ runner: TextDocCommandRunner, block: NibID, range: NSRange, text: String) async -> Bool {
        let params: JSONValue = ["ref": .string(runner.blockRef(block)), "range": Self.range(range), "text": .string(text)]
        return await runner.run(BlockCommentAdd.descriptor.id, params) != nil
    }

    static func edit(_ runner: TextDocCommandRunner, block: NibID, comment: NibID, text: String) async -> Bool {
        let params: JSONValue = ["ref": .string(runner.blockRef(block)), "comment": .string(comment.raw), "text": .string(text)]
        return await runner.run(BlockCommentEdit.descriptor.id, params) != nil
    }

    static func delete(_ runner: TextDocCommandRunner, block: NibID, comments: [NibID]) async {
        let group = NibID.make().raw
        for c in comments {
            let params: JSONValue = ["ref": .string(runner.blockRef(block)), "comment": .string(c.raw)]
            guard await runner.run(BlockCommentDelete.descriptor.id, params, group: group) != nil else { return }
        }
        runner.toast(comments.count == 1 ? String(localized: "Comment deleted") : String(localized: "Comments deleted"),
                     undo: true)
    }

    /// Resolves (or opens again) every comment of a thread as one undo step.
    static func setResolved(_ runner: TextDocCommandRunner, thread: CommentThread, resolved: Bool) async {
        let group = NibID.make().raw
        for c in thread.comments where c.resolved != resolved {
            let params: JSONValue = ["ref": .string(runner.blockRef(thread.block)), "comment": .string(c.id.raw),
                                     "resolved": .bool(resolved)]
            guard await runner.run(BlockCommentResolve.descriptor.id, params, group: group) != nil else { return }
        }
        UIAccessibility.post(notification: .announcement,
                             argument: resolved ? String(localized: "Comment resolved") : String(localized: "Comment reopened"))
    }
}

/// One thread on screen (card or expanded sidebar row), following the document as it changes.
@MainActor
final class CommentThreadModel: ObservableObject {
    @Published private(set) var thread: CommentThread?
    @Published private(set) var excerpt = ""
    @Published var reply = ""
    @Published var editing: NibID?
    @Published var editDraft = ""
    @Published private(set) var isBusy = false

    let runner: TextDocCommandRunner
    let block: NibID
    /// Comment ids seen in the thread: it is found again after its range moved or its first comment went.
    private var known: Set<NibID>
    private var subscription: EventSubscription?

    init(runner: TextDocCommandRunner, block: NibID, thread: CommentThread) {
        self.runner = runner
        self.block = block
        self.known = Set(thread.comments.map { $0.id })
        self.thread = thread
        refresh()
        let doc = runner.doc
        subscription = runner.app.bus.observeCommits { [weak self] changeset in
            guard changeset.headChanged(doc) else { return }
            self?.refresh()
        }
    }

    deinit {
        subscription?.cancel()
    }

    var isReadOnly: Bool { runner.isReadOnly }

    func refresh() {
        guard let b = runner.liveBlock(block) else {
            thread = nil
            excerpt = ""
            return
        }
        let t = CommentThreads.threads(in: b).first { t in t.comments.contains { known.contains($0.id) } }
        if let t = t { known.formUnion(t.comments.map { $0.id }) }
        if t != thread { thread = t }
        let e = t.map { CommentThreads.excerpt($0.range, in: b) } ?? ""
        if e != excerpt { excerpt = e }
        if let editing = editing, t?.contains(editing) != true { self.editing = nil }
    }

    func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let t = thread, !text.isEmpty, !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            if await CommentActions.reply(runner, block: block, range: t.range, text: text) { reply = "" }
            isBusy = false
            refresh()
        }
    }

    func beginEdit(_ c: BlockComment) {
        editDraft = c.text
        editing = c.id
    }

    func cancelEdit() {
        editing = nil
        editDraft = ""
    }

    func saveEdit() {
        let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = editing, !text.isEmpty else { return }
        editing = nil
        Task { @MainActor in
            _ = await CommentActions.edit(runner, block: block, comment: id, text: text)
            refresh()
        }
    }

    func delete(_ c: BlockComment) {
        Task { @MainActor in
            await CommentActions.delete(runner, block: block, comments: [c.id])
            refresh()
        }
    }

    func deleteThread() {
        guard let t = thread else { return }
        Task { @MainActor in
            await CommentActions.delete(runner, block: block, comments: t.comments.map { $0.id })
            refresh()
        }
    }

    func setResolved(_ resolved: Bool) {
        guard let t = thread else { return }
        Task { @MainActor in
            await CommentActions.setResolved(runner, thread: t, resolved: resolved)
            refresh()
        }
    }
}

enum CommentFormat {
    static func author(_ c: BlockComment) -> String {
        c.author.isEmpty ? String(localized: "You") : c.author
    }

    static func time(_ c: BlockComment) -> String {
        Date(timeIntervalSince1970: c.at).formatted(.relative(presentation: .named))
    }
}

// MARK: - Views

/// The commented words above a comment: an accent rule (the mark the text carries) and the words in footnote.
struct CommentQuoteView: View {
    let excerpt: String

    var body: some View {
        HStack(alignment: .top, spacing: NibSpacing.s) {
            Capsule()
                .fill(NibColor.accent)
                .frame(width: NibSpacing.xxs)
                .accessibilityHidden(true)
            Text(excerpt.isEmpty ? String(localized: "The commented text was deleted.") : excerpt)
                .font(NibFont.footnote)
                .foregroundStyle(excerpt.isEmpty ? NibColor.labelTertiary : NibColor.labelSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(excerpt.isEmpty ? String(localized: "The commented text was deleted.")
                                            : String(localized: "On \u{201C}\(excerpt)\u{201D}"))
    }
}

/// A new comment: the words it is on, a field, and Comment (⌘↩) / Cancel (⎋). A sheet puts both in its header.
struct CommentComposerView: View {
    let excerpt: String
    let chrome: CommentChrome
    var isPosting = false
    let onCancel: @MainActor () -> Void
    let onPost: @MainActor (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sheetTitle: String? {
        if case .sheet(let title) = chrome { return title }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            if let title = sheetTitle {
                NibSheetHeader(title, primaryTitle: String(localized: "Comment"),
                               isPrimaryEnabled: !trimmed.isEmpty && !isPosting,
                               onCancel: { onCancel() }, onPrimary: { post() })
            }
            VStack(alignment: .leading, spacing: NibSpacing.m) {
                CommentQuoteView(excerpt: excerpt)
                NibField(text: $draft, prompt: String(localized: "Add a comment"), lines: 1...6)
                    .focused($focused)
                    .accessibilityLabel(String(localized: "Comment"))
                if sheetTitle == nil {
                    HStack(spacing: NibSpacing.s) {
                        Spacer(minLength: 0)
                        NibButton(String(localized: "Cancel"), kind: .plain, size: .compact, shortcut: .cancelAction) { onCancel() }
                        NibButton(String(localized: "Comment"), kind: .primary, size: .compact,
                                  shortcut: KeyboardShortcut(.return, modifiers: .command)) { post() }
                            .disabled(trimmed.isEmpty || isPosting)
                    }
                }
            }
            .padding(.horizontal, sheetTitle == nil ? 0 : NibSpacing.l)
            if sheetTitle != nil { Spacer(minLength: 0) }
        }
        .onAppear { focused = true }
    }

    private func post() {
        guard !trimmed.isEmpty, !isPosting else { return }
        onPost(trimmed)
    }
}

/// A thread: every comment with author and time, Edit and Delete in each one's menu, Reply (⌘↩), Resolve / Reopen.
struct CommentThreadView: View {
    @ObservedObject var model: CommentThreadModel
    let chrome: CommentChrome
    let showsQuote: Bool
    let onClose: @MainActor () -> Void
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            if case .sheet(let title) = chrome {
                NibSheetHeader(title, cancelTitle: String(localized: "Done"), onCancel: { onClose() })
            }
            if let thread = model.thread {
                content(thread)
                    .padding(.horizontal, isSheet ? NibSpacing.l : 0)
            } else {
                Text(String(localized: "This comment was deleted."))
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
                    .padding(.horizontal, isSheet ? NibSpacing.l : 0)
            }
            if isSheet { Spacer(minLength: 0) }
        }
    }

    private var isSheet: Bool {
        if case .sheet = chrome { return true }
        return false
    }

    @ViewBuilder
    private func content(_ thread: CommentThread) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            if showsQuote { CommentQuoteView(excerpt: model.excerpt) }
            ForEach(thread.comments, id: \.id) { c in
                CommentMessageRow(model: model, comment: c)
                if c.id != thread.comments.last?.id {
                    Rectangle()
                        .fill(NibColor.separatorSoft)
                        .frame(height: NibStroke.hairline)
                        .accessibilityHidden(true)
                }
            }
            if !model.isReadOnly && model.editing == nil {
                if !thread.isResolved {
                    NibField(text: $model.reply, prompt: String(localized: "Reply"), lines: 1...5)
                        .focused($replyFocused)
                        .accessibilityLabel(String(localized: "Reply"))
                }
                HStack(spacing: NibSpacing.s) {
                    NibButton(thread.isResolved ? String(localized: "Reopen") : String(localized: "Resolve"),
                              symbol: thread.isResolved ? nil : .checkmark, kind: .secondary, size: .compact) {
                        model.setResolved(!thread.isResolved)
                    }
                    Spacer(minLength: 0)
                    if !thread.isResolved {
                        NibButton(String(localized: "Reply"), kind: .primary, size: .compact,
                                  shortcut: KeyboardShortcut(.return, modifiers: .command)) {
                            model.sendReply()
                        }
                        .disabled(model.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                    }
                }
            }
        }
    }
}

/// One comment of a thread; it turns into a field while it is edited.
struct CommentMessageRow: View {
    @ObservedObject var model: CommentThreadModel
    let comment: BlockComment

    private var isEditing: Bool { model.editing == comment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                Text(CommentFormat.author(comment))
                    .font(NibFont.footnoteEmphasis)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1)
                Text(CommentFormat.time(comment))
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
                    .lineLimit(1)
                if comment.resolved {
                    NibBadge(.capsule(String(localized: "Resolved")))
                }
                Spacer(minLength: NibSpacing.s)
                if !model.isReadOnly && !isEditing {
                    Menu {
                        Button {
                            model.beginEdit(comment)
                        } label: {
                            Label { Text(String(localized: "Edit")) } icon: { Image(nib: .documentWrite) }
                        }
                        Button(role: .destructive) {
                            model.delete(comment)
                        } label: {
                            Label { Text(String(localized: "Delete")) } icon: { Image(nib: .trash) }
                        }
                    } label: {
                        Image(nib: .more)
                            .font(NibFont.glyph(.panel))
                            .foregroundStyle(NibColor.labelSecondary)
                            .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(localized: "More actions"))
                    .padding(.vertical, -NibSpacing.m)
                }
            }
            if isEditing {
                NibField(text: $model.editDraft, prompt: String(localized: "Edit comment"), lines: 1...6)
                    .accessibilityLabel(String(localized: "Edit comment"))
                HStack(spacing: NibSpacing.s) {
                    Spacer(minLength: 0)
                    NibButton(String(localized: "Cancel"), kind: .plain, size: .compact, shortcut: .cancelAction) {
                        model.cancelEdit()
                    }
                    NibButton(String(localized: "Save"), kind: .primary, size: .compact,
                              shortcut: KeyboardShortcut(.return, modifiers: .command)) {
                        model.saveEdit()
                    }
                    .disabled(model.editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(comment.text)
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityActions {
            if !model.isReadOnly && !isEditing {
                Button(String(localized: "Edit")) { model.beginEdit(comment) }
                Button(String(localized: "Delete")) { model.delete(comment) }
            }
        }
    }
}

// MARK: - Comments sidebar tab

/// The Comments tab of text documents: every thread in document order, open or resolved. A row reveals its words in
/// the editor and opens into the full thread (replies, edit, delete, resolve).
///
/// `panel.open {id: "textdocextras.comments", …}` params: `block` (block:D/B) opens that block's first thread, with
/// `comment` the thread of that comment; `block` + `range` ([start, length] of its plain text) + `compose: true` puts a
/// composer for a new comment on those words at the top (⇧⌘M while no text is edited).
struct TextDocCommentsPanel: View {
    static let panelID = TextDocExtrasHookIDs.prefix + "comments"

    static func descriptor(owner: String) -> PanelDescriptor {
        PanelDescriptor(id: panelID, title: String(localized: "Comments"), icon: NibSymbol.comment.name,
                        placement: .sidebarTab, order: 460, owner: owner, docKinds: [.textDocument]) { context in
            AnyView(TextDocCommentsPanel(context: context))
        }
    }

    private let params: JSONValue
    @StateObject private var model: CommentsPanelModel

    init(context: PanelContext) {
        params = context.params
        _model = StateObject(wrappedValue: CommentsPanelModel(app: context.app, session: context.session,
                                                              params: context.params))
    }

    var body: some View {
        VStack(spacing: 0) {
            NibSegmentedControl(selection: $model.filter, options: CommentsPanelModel.Filter.allCases) { $0.title }
                .padding(.horizontal, NibSpacing.m)
                .padding(.vertical, NibSpacing.xs)
            if let draft = model.draft {
                CommentComposerView(excerpt: draft.excerpt, chrome: .panel, isPosting: model.isPosting,
                                    onCancel: { model.cancelDraft() }) { text in
                    model.postDraft(text)
                }
                .id(draft)
                .padding(NibSpacing.m)
                .background(NibColor.fill3, in: RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous))
                .padding(.horizontal, NibSpacing.s)
                .padding(.bottom, NibSpacing.xs)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "New Comment"))
            }
            if model.rows.isEmpty {
                if model.draft == nil {
                    ScrollView {
                        NibEmptyState(symbol: .comment, title: model.filter.emptyTitle, message: model.filter.emptyMessage)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Spacer(minLength: 0)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: NibSpacing.xs) {
                            ForEach(model.rows) { row in
                                CommentsPanelRow(model: model, row: row)
                                    .id(row.id)
                            }
                        }
                        .padding(.horizontal, NibSpacing.s)
                        .padding(.vertical, NibSpacing.s)
                    }
                    .onChange(of: model.scrollTarget) { _, target in
                        guard let target = target else { return }
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Comments"))
        // panel.open again while the tab is on screen: the chrome hands the same view new params.
        .onChange(of: params) { _, next in model.apply(next) }
    }
}

struct CommentsPanelRow: View {
    @ObservedObject var model: CommentsPanelModel
    let row: CommentsPanelModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            if let expanded = model.expanded, model.expandedID == row.id {
                CommentQuoteView(excerpt: row.excerpt)
                CommentThreadView(model: expanded, chrome: .panel, showsQuote: false) { model.collapse() }
                NibButton(String(localized: "Show in Document"), symbol: .forward, kind: .plain, size: .compact) {
                    model.reveal(row)
                }
            } else {
                Button {
                    model.open(row)
                } label: {
                    summary
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .contextMenu { menu }
                .accessibilityHint(String(localized: "Shows the comment and where it is"))
            }
        }
        .padding(NibSpacing.m)
        .background(model.expandedID == row.id ? NibColor.fill3 : Color.clear,
                    in: RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            CommentQuoteView(excerpt: row.excerpt)
            if let first = row.thread.comments.first {
                HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                    Text(CommentFormat.author(first))
                        .font(NibFont.footnoteEmphasis)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(1)
                    Text(CommentFormat.time(first))
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(1)
                }
                Text(first.text)
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if row.thread.replyCount > 0 {
                Text(row.thread.replyCount == 1 ? String(localized: "1 reply")
                                                 : String(localized: "\(row.thread.replyCount) replies"))
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var menu: some View {
        Button {
            model.reveal(row)
        } label: {
            Label { Text(String(localized: "Show in Document")) } icon: { Image(nib: .forward) }
        }
        if !model.isReadOnly {
            Button {
                model.open(row)
            } label: {
                Label { Text(String(localized: "Reply")) } icon: { Image(nib: .comment) }
            }
            Button {
                model.setResolved(row, !row.thread.isResolved)
            } label: {
                Label { Text(row.thread.isResolved ? String(localized: "Reopen") : String(localized: "Resolve")) } icon: {
                    Image(nib: .checkmark)
                }
            }
            Button(role: .destructive) {
                model.delete(row)
            } label: {
                Label { Text(String(localized: "Delete Thread")) } icon: { Image(nib: .trash) }
            }
        }
    }
}

/// The Comments tab's state: the window's text document, its threads, the filter and the one open thread.
@MainActor
final class CommentsPanelModel: ObservableObject {
    enum Filter: String, CaseIterable, Hashable {
        case open, resolved

        var title: String {
            switch self {
            case .open: return String(localized: "Open")
            case .resolved: return String(localized: "Resolved")
            }
        }

        var emptyTitle: String {
            switch self {
            case .open: return String(localized: "No comments")
            case .resolved: return String(localized: "No resolved comments")
            }
        }

        var emptyMessage: String? {
            switch self {
            case .open: return String(localized: "Select text and choose Add Comment, or press Shift-Command-M.")
            case .resolved: return nil
            }
        }
    }

    struct Row: Identifiable, Equatable {
        var thread: CommentThread
        var excerpt: String
        var id: String { thread.id }
    }

    /// A new comment being written in the tab: the words it will be on.
    struct Draft: Hashable {
        var block: NibID
        var range: NSRange
        var excerpt: String
    }

    @Published var filter: Filter = .open {
        didSet { if filter != oldValue { collapse(); rebuild() } }
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var expandedID: String?
    @Published private(set) var expanded: CommentThreadModel?
    @Published private(set) var scrollTarget: String?
    @Published private(set) var isReadOnly = false
    @Published private(set) var draft: Draft?
    @Published private(set) var isPosting = false

    let app: NibApp
    let session: EditorSession?
    private var doc: DocumentID?
    private var commits: EventSubscription?
    private var cancellables = Set<AnyCancellable>()
    private var scheduled = false
    /// A block or comment `panel.open` asked for: opened once the rows exist.
    private var requested: (block: NibID?, comment: NibID?)?
    /// Words `panel.open {block, range, compose: true}` asked to comment on: a draft once the document is known.
    private var requestedDraft: (block: NibID, range: [Int])?

    init(app: NibApp, session: EditorSession?, params: JSONValue) {
        self.app = app
        self.session = session
        read(params)
        commits = app.bus.observeCommits { [weak self] changeset in
            guard let self = self, let doc = self.doc, changeset.headChanged(doc) else { return }
            self.schedule()
        }
        session?.$document.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        session?.$readOnly.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        rebuild()
    }

    deinit {
        commits?.cancel()
    }

    private var runner: TextDocCommandRunner? {
        doc.map { TextDocCommandRunner(app: app, session: session, doc: $0) }
    }

    private func read(_ params: JSONValue) {
        let block: NibID? = params["block"]?.stringValue.flatMap { ref in
            if case let .block(_, b)? = NodeRef(ref) { return b }
            return nil
        }
        if params["compose"]?.boolValue == true, let b = block,
           let range = params["range"]?.arrayValue?.compactMap({ $0.intValue }), range.count == 2 {
            requestedDraft = (b, range)
        } else if block != nil || params["comment"]?.stringValue != nil {
            requested = (block, params["comment"]?.stringValue.map { NibID($0) })
        }
    }

    /// New `panel.open` params for the tab already on screen.
    func apply(_ params: JSONValue) {
        read(params)
        rebuild()
    }

    /// Coalesces bursts of commits (typing) into one rebuild after they landed.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.scheduled = false
            self.rebuild()
        }
    }

    func rebuild() {
        let next = session?.document
        if next != doc {
            doc = next
            collapse()
        }
        guard let runner = runner, (try? app.workspace.content(runner.doc).meta.kind) == .textDocument else {
            if !rows.isEmpty { rows = [] }
            if draft != nil { draft = nil }
            return
        }
        let readOnly = runner.isReadOnly
        if readOnly != isReadOnly { isReadOnly = readOnly }
        resolveDraft(runner)
        var out: [Row] = []
        for b in runner.liveBlocks() {
            for t in CommentThreads.threads(in: b) where t.isResolved == (filter == .resolved) {
                out.append(Row(thread: t, excerpt: CommentThreads.excerpt(t.range, in: b)))
            }
        }
        if out != rows { rows = out }
        if let expandedID = expandedID, !out.contains(where: { $0.id == expandedID }) {
            // A thread's id follows its first comment: when that one goes, the open thread keeps its place under the
            // id of the comment now first; a thread that left this filter (resolved, deleted) closes.
            let ids = Set(expanded?.thread?.comments.map { $0.id } ?? [])
            if let row = out.first(where: { r in r.thread.comments.contains { ids.contains($0.id) } }) {
                self.expandedID = row.id
            } else {
                collapse()
            }
        }
        if let request = requested, !out.isEmpty {
            requested = nil
            let row = out.first { r in request.comment.map { r.thread.contains($0) } ?? false }
                ?? out.first { r in request.block.map { r.thread.block == $0 } ?? false }
            if let row = row {
                open(row)
                scrollTarget = row.id
            }
        }
    }

    /// Turns a requested composer into a draft on the block's text as it is now; a draft whose block went, or that
    /// the window can no longer edit, closes.
    private func resolveDraft(_ runner: TextDocCommandRunner) {
        if let request = requestedDraft {
            requestedDraft = nil
            if !isReadOnly, let b = runner.liveBlock(request.block), BlockRules.isText(b.kind) {
                let range = CommentAnchors.clamp(NSRange(location: request.range[0], length: max(0, request.range[1])),
                                                 length: BlockCommentRules.length(of: b))
                if range.length > 0 {
                    draft = Draft(block: b.id, range: range, excerpt: CommentThreads.excerpt(range, in: b))
                    if filter != .open { filter = .open }
                }
            }
        }
        if let d = draft, isReadOnly || runner.liveBlock(d.block).map({ BlockRules.isText($0.kind) }) != true {
            draft = nil
        }
    }

    func cancelDraft() {
        draft = nil
    }

    /// Posts the draft with block.comment; the new thread then opens in the list. A failed call keeps the composer
    /// and its text (the shell shows why).
    func postDraft(_ text: String) {
        guard let runner = runner, let d = draft, !isPosting else { return }
        let id = NibID.make()
        let params: JSONValue = ["ref": .string(runner.blockRef(d.block)), "range": CommentActions.range(d.range),
                                 "text": .string(text), "id": .string(id.raw)]
        isPosting = true
        Task { @MainActor in
            let ok = await runner.run(BlockCommentAdd.descriptor.id, params) != nil
            isPosting = false
            guard ok else { return }
            if draft == d { draft = nil }
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Comment added"))
            if filter != .open { filter = .open }
            requested = (d.block, id)
            rebuild()
        }
    }

    /// Opens a thread in place and shows its words in the editor.
    func open(_ row: Row) {
        guard let runner = runner else { return }
        if expandedID != row.id {
            expanded = CommentThreadModel(runner: runner, block: row.thread.block, thread: row.thread)
            expandedID = row.id
        }
        reveal(row)
    }

    func collapse() {
        expanded = nil
        expandedID = nil
    }

    /// Scrolls the editor to the commented words and selects them (read-only windows only scroll).
    func reveal(_ row: Row) {
        guard let editor = runner?.editor else { return }
        let id = row.thread.block
        editor.reveal(block: id, animated: true)
        guard !editor.isReadOnly else { return }
        editor.focus(id, at: row.thread.range.location)
        if let tv = editor.cell(for: id)?.textView, tv.isFirstResponder {
            tv.selectedRange = CommentAnchors.clamp(row.thread.range, length: tv.textStorage.length)
        }
    }

    func setResolved(_ row: Row, _ resolved: Bool) {
        guard let runner = runner else { return }
        Task { @MainActor in await CommentActions.setResolved(runner, thread: row.thread, resolved: resolved) }
    }

    func delete(_ row: Row) {
        guard let runner = runner else { return }
        if expandedID == row.id { collapse() }
        Task { @MainActor in
            await CommentActions.delete(runner, block: row.thread.block, comments: row.thread.comments.map { $0.id })
        }
    }
}
