import Foundation
import CoreGraphics

struct LibrarySelection {
    var isSelecting = false
    var refs = Set<String>()
    private var baseline = Set<String>()
    private var anchor: Int?

    mutating func toggle(_ ref: String) {
        isSelecting = true
        if !refs.insert(ref).inserted { refs.remove(ref) }
    }
    mutating func selectAll(_ order: [String]) { isSelecting = true; refs = Set(order) }
    mutating func clear() { refs.removeAll(); isSelecting = false; anchor = nil }
    mutating func retain(_ order: [String]) { refs.formIntersection(order) }
    mutating func beginRange(at index: Int) { baseline = refs; anchor = index }
    mutating func extendRange(to index: Int, order: [String]) {
        guard let anchor, order.indices.contains(anchor), order.indices.contains(index) else { return }
        refs = baseline.union(order[min(anchor, index)...max(anchor, index)])
    }
    mutating func beginMarquee() { baseline = refs }
    mutating func marquee(_ rect: CGRect, frames: [String: CGRect]) {
        refs = baseline.union(frames.compactMap { rect.intersects($0.value) ? $0.key : nil })
    }
}


extension LibrarySelection {
    var statusText: String {
        refs.isEmpty ? String(localized: "Select items") : String(localized: "\(refs.count) selected")
    }
}

/// The baseline belongs to one physical gesture, never to the next pickup.
struct LibrarySelectionDrag {
    private(set) var active = false
    var selection = LibrarySelection()
    var marquee: CGRect?

    mutating func begin(selection current: LibrarySelection, anchor: Int?) {
        guard !active else { return }
        active = true
        selection = current
        if let anchor { selection.beginRange(at: anchor) }
        else { selection.beginMarquee() }
    }

    mutating func cancel() {
        active = false
        marquee = nil
        selection = LibrarySelection()
    }
}
