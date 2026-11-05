import Foundation

public struct UndoEntry {
    /// Stable across coalescing, revision rebasing and undo/redo.
    public let id: String
    public let group: String
    public var label: String
    public let principal: Principal
    public var mutations: [Mutation]
    public let at: Date
    /// contracts-v2: the group's entries in OTHER documents undo and redo together with this one
    /// (`CommandContext.linkUndoAcrossDocuments()`, e.g. a page moved between two documents).
    public var linked: Bool = false

    public init(group: String, label: String, principal: Principal, mutations: [Mutation], at: Date = Date(), id: String = UUID().uuidString) {
        self.id = id
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
    /// Groups whose entries undo across documents together (bounded: oldest dropped first).
    private var linkedGroups: [String] = []

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

    /// True when `group` was linked across documents (`CommandContext.linkUndoAcrossDocuments()`).
    public func isLinked(_ group: String) -> Bool { linkedGroups.contains(group) }

    func link(_ group: String) {
        guard !linkedGroups.contains(group) else { return }
        linkedGroups.append(group)
        if linkedGroups.count > 64 { linkedGroups.removeFirst(linkedGroups.count - 64) }
        for (doc, stack) in undoStacks {
            guard let top = stack.last, top.group == group else { continue }
            undoStacks[doc]?[stack.count - 1].linked = true
        }
    }

    func record(_ cs: Changeset) {
        let linked = linkedGroups.contains(cs.group)
        for doc in cs.documents {
            let muts = cs.mutations.filter { $0.document == doc }
            var stack = undoStacks[doc] ?? []
            if var top = stack.last, top.group == cs.group {
                UndoHistory.appendCompacting(muts, to: &top.mutations)
                top.linked = top.linked || linked
                stack[stack.count - 1] = top
            } else {
                var compact: [Mutation] = []
                UndoHistory.appendCompacting(muts, to: &compact)
                var entry = UndoEntry(group: cs.group, label: cs.label, principal: cs.principal, mutations: compact)
                entry.linked = linked
                stack.append(entry)
                if stack.count > limit { stack.removeFirst(stack.count - limit) }
            }
            undoStacks[doc] = stack
            redoStacks[doc] = []
        }
    }

    /// Keep the first before-value and last after-value of a revision-linked run. A remote edit breaks the
    /// chain, so its surrounding segments stay separate and selective undo still skips the conflicting segment.
    private static func appendCompacting(_ writes: [Mutation], to stored: inout [Mutation]) {
        var latest: [RecordKey: Int] = [:]
        for (i, mutation) in stored.enumerated() { latest[mutation.recordKey] = i }
        for write in writes {
            let key = write.recordKey
            if let i = latest[key], let merged = stored[i].followed(by: write) {
                stored[i] = merged
            } else {
                latest[key] = stored.count
                stored.append(write)
            }
        }
    }

    /// Moves stored after-revisions that an undo, redo or revert re-stamped (see `RevRebase`), in every stack.
    func rebase(_ r: RevRebase) {
        guard !r.isEmpty else { return }
        for doc in r.documents {
            if var stack = undoStacks[doc] {
                for i in stack.indices { stack[i].mutations = stack[i].mutations.map { r.apply($0) } }
                undoStacks[doc] = stack
            }
            if var stack = redoStacks[doc] {
                for i in stack.indices { stack[i].mutations = stack[i].mutations.map { r.apply($0) } }
                redoStacks[doc] = stack
            }
        }
    }

    /// Documents (other than `doc`) whose top undo (or redo) entry belongs to `group`.
    func linkedDocuments(_ group: String, except doc: DocumentID, redo: Bool) -> [DocumentID] {
        let stacks = redo ? redoStacks : undoStacks
        return stacks.compactMap { d, stack in d != doc && stack.last?.group == group ? d : nil }
            .sorted { $0.raw < $1.raw }
    }

    func popUndo(_ doc: DocumentID) -> UndoEntry? { undoStacks[doc]?.popLast() }
    func popRedo(_ doc: DocumentID) -> UndoEntry? { redoStacks[doc]?.popLast() }
    func pushUndo(_ e: UndoEntry, doc: DocumentID) { undoStacks[doc, default: []].append(e) }
    func pushRedo(_ e: UndoEntry, doc: DocumentID) { redoStacks[doc, default: []].append(e) }

    func removeEntry(id: String, doc: DocumentID) -> UndoEntry? {
        guard let i = undoStacks[doc]?.lastIndex(where: { $0.id == id }) else { return nil }
        return undoStacks[doc]?.remove(at: i)
    }
}

private extension Mutation {
    func followed(by next: Mutation) -> Mutation? {
        guard recordKey == next.recordKey, afterRev == next.beforeRev else { return nil }
        switch (self, next) {
        case let (.item(d, p, b, _), .item(_, _, _, a)): return .item(d, p, before: b, after: a)
        case let (.page(d, b, _), .page(_, _, a)): return .page(d, before: b, after: a)
        case let (.meta(d, b, _), .meta(_, _, a)): return .meta(d, before: b, after: a)
        case let (.block(d, b, _), .block(_, _, a)): return .block(d, before: b, after: a)
        case let (.card(d, b, _), .card(_, _, a)): return .card(d, before: b, after: a)
        case let (.audio(d, b, _), .audio(_, _, a)): return .audio(d, before: b, after: a)
        case let (.outline(d, b, _), .outline(_, _, a)): return .outline(d, before: b, after: a)
        default: return nil
        }
    }
}

/// contracts-v2.2: where ⌘Z / ⇧⌘Z acts in one window. A key command that runs `edit.undo` / `edit.redo` undoes the
/// document's history while it has a step; when it has none, or no document is open, the shell falls back to the
/// window's UndoManager, where window-level steps live (the toolbar's "Move Palette"). The shell also validates the
/// key (menu, ⌘-hold overlay) with it, so ⌘Z is enabled exactly when one of the two can act.
public enum UndoRoute: Equatable {
    /// Run the command on this document's history.
    case document(DocumentID)
    /// Undo (redo) the window's UndoManager.
    case window
    /// Nothing to undo (redo) in either (not named `none`, so it never reads as `Optional.none`).
    case nothing

    /// The document's history while it has a step, else the window's UndoManager while it has one, else `.nothing`.
    /// `doc` nil = no document is open; `window` nil = the window has no UndoManager.
    @MainActor
    public static func resolve(redo: Bool, doc: DocumentID?, history: UndoHistory, window: UndoManager?) -> UndoRoute {
        if let doc, redo ? history.canRedo(doc) : history.canUndo(doc) { return .document(doc) }
        if let window, redo ? window.canRedo : window.canUndo { return .window }
        return .nothing
    }

    /// The route of a key command about to run `command` with its resolved `params`: nil unless the command is
    /// `edit.undo` or `edit.redo`. The document is the one `params` name in `doc`, else the session's document.
    @MainActor
    public static func forCommand(_ command: String, params: JSONValue, session: EditorSession?, history: UndoHistory,
                                  window: UndoManager?) -> UndoRoute? {
        let redo: Bool
        switch command {
        case CommandIDs.undo: redo = false
        case CommandIDs.redo: redo = true
        default: return nil
        }
        let named = params["doc"]?.stringValue.flatMap { $0.isEmpty ? nil : NodeRef.documentID(from: $0) }
        return resolve(redo: redo, doc: named ?? session?.document, history: history, window: window)
    }
}
