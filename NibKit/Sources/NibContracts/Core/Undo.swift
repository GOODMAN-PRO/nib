import Foundation

public struct UndoEntry {
    public let group: String
    public var label: String
    public let principal: Principal
    public var mutations: [Mutation]
    public let at: Date
    /// contracts-v2: the group's entries in OTHER documents undo and redo together with this one
    /// (`CommandContext.linkUndoAcrossDocuments()`, e.g. a page moved between two documents).
    public var linked: Bool = false

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
                top.mutations.append(contentsOf: muts)
                top.linked = top.linked || linked
                stack[stack.count - 1] = top
            } else {
                var entry = UndoEntry(group: cs.group, label: cs.label, principal: cs.principal, mutations: muts)
                entry.linked = linked
                stack.append(entry)
                if stack.count > limit { stack.removeFirst(stack.count - limit) }
            }
            undoStacks[doc] = stack
            redoStacks[doc] = []
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

    func removeEntry(group: String, doc: DocumentID) -> UndoEntry? {
        guard let i = undoStacks[doc]?.lastIndex(where: { $0.group == group }) else { return nil }
        return undoStacks[doc]?.remove(at: i)
    }
}
