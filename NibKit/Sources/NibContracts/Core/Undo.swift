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
