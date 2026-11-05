import XCTest
import UIKit
import ObjectiveC

struct QAState: Decodable {
    struct Offset: Decodable { let x: Double; let y: Double }
    struct Dock: Decodable { let edge: String; let along: Double }
    let keyResponder: String?
    let keyResponderIsText: Bool?
    /// The app's last hardware key events (fixture mode): window presses, the responder that took each, the command run.
    let keyLog: [String]?
    let keyLogTotal: Int?
    let screen: String
    let document: String?
    let page: String?
    let pageCount: Int
    let tool: String
    let toolSettingsOpen: String?
    let zoom: Double
    let contentOffset: Offset
    let itemCountOnPage: Int
    let strokeCountOnPage: Int
    let selectionCount: Int
    let undoAvailable: Bool
    let redoAvailable: Bool
    let openPanels: [String]
    let paletteDock: Dock?
    let fixtureError: String?
    let fixtureScenario: String?
    let boardReadReceipts: [String: String?]?
    let boardSeenBaseline: String?
    let unseenFixturePages: [String]?
    let renderFailureCount: Int?
    let rendererCachePurgeCount: Int?
    let memoryWarningCount: Int?
    let cachedPageCount: Int?
    let clipboardChangeCount: Int?
}

/// All coordinates are normalized to the real canvas viewport, not the whole device screen.
@MainActor
final class NibUI {
    let app = XCUIApplication()
    var probe: XCUIElement { app.otherElements["nib.qa.state"].firstMatch }
    private(set) var formRevealFailure: String?
    var canvas: XCUIElement { app.scrollViews["nib.canvas"].firstMatch }

    /// Explicit prerequisites; no test-name detection and no changes to the standard fixture.
    enum FixtureScenario: String { case standard, failedRender, largeDocument, unseenBoards }

    /// Reject hidden SwiftUI menu copies before asking AX for an activation point (zero frames can raise).
    func hasVisibleFrame(_ element: XCUIElement, in viewport: CGRect? = nil) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let visible = frame.intersection(viewport ?? app.windows.firstMatch.frame)
        return !frame.isNull && !frame.isInfinite && !visible.isNull && visible.width > 1 && visible.height > 1
    }

    func nativeEditorHittability(_ element: XCUIElement) -> Bool? {
        guard let snapshot = try? element.snapshot(), !snapshot.frame.isNull, !snapshot.frame.isInfinite,
              snapshot.frame.minX.isFinite, snapshot.frame.minY.isFinite else { return nil }
        guard let reader = NSClassFromString("NibUIReadiness") as? NSObject.Type,
              let value = reader.perform(NSSelectorFromString("hittabilityOfElement:"), with: element)?
                .takeUnretainedValue() as? NSNumber else { return nil }
        return value.boolValue
    }

    /// Exact, bounded matches only. Native editors precede their identically labelled captions.
    /// Offscreen matches remain available to revealFormElement so it can find the actual containing form.
    func findControl(_ name: String, type: XCUIElement.ElementType = .any,
                     actionable: Bool = true, in scope: XCUIElement? = nil) -> XCUIElement? {
        let priority: [XCUIElement.ElementType] = [.textField, .textView, .searchField, .secureTextField,
            .switch, .button, .slider, .cell, .segmentedControl, .staticText, .other]
        let predicate = NSPredicate(format:
            "(identifier == %@ OR label == %@ OR placeholderValue == %@) AND (NOT identifier BEGINSWITH 'tool.' OR identifier == %@)",
            name, name, name, name)
        let command = ["cmd.", "tool.", "menu.", "sheet."].contains { name.hasPrefix($0) }
        let kind: XCUIElement.ElementType = type == .any && command ? .button : type
        let matches = (scope ?? app).descendants(matching: kind).matching(predicate)
        let first = matches.firstMatch
        // A missing control should cost one query, not every typed query on each poll.
        guard first.exists else { return nil }
        if kind != .any {
            if !actionable, matches.count == 1 { return first }
            if hasVisibleFrame(first), !first.isEnabled || first.isHittable { return first }
        }
        var candidates: [(XCUIElement, XCUIElementSnapshot)] = []
        let indexed = min(matches.count, 16)
        for index in 0..<indexed {
            let element = matches.element(boundBy: index)
            guard element.exists, let snapshot = try? element.snapshot() else { continue }
            candidates.append((element, snapshot))
        }
        candidates.sort {
            (priority.firstIndex(of: $0.1.elementType) ?? priority.count)
                < (priority.firstIndex(of: $1.1.elementType) ?? priority.count)
        }
        let viewport = app.windows.firstMatch.frame
        for (element, snapshot) in candidates {
            let visible = snapshot.frame.intersection(viewport)
            guard !visible.isNull, visible.width > 1, visible.height > 1 else { continue }
            if !snapshot.isEnabled || (element.exists && element.isHittable) { return element }
        }
        // Remote picker trees can lose an indexed Any match between count and exists (the Files picker's
        // Cancel button). Only then resolve concrete first matches, so ordinary lookups cost what they did.
        if actionable, kind == .any, candidates.count < indexed {
            for candidateType in priority {
                let candidate = (scope ?? app).descendants(matching: candidateType).matching(predicate).firstMatch
                if candidate.exists, hasVisibleFrame(candidate), !candidate.isEnabled || candidate.isHittable {
                    return candidate
                }
            }
        }
        return actionable ? nil : candidates.first?.0
    }

    func requireControl(_ name: String, type: XCUIElement.ElementType = .any,
                        scroll: Bool = false, timeout: TimeInterval = 3) throws -> XCUIElement {
        if let found = findControl(name, type: type) { return found }
        if scroll {
            // Virtualized native rows do not exist until their collection view scrolls.
            revealFormElement {
                self.findControl(name, type: type, actionable: false)
                    ?? self.app.descendants(matching: type).matching(NSPredicate(
                        format: "identifier == %@ OR label == %@ OR placeholderValue == %@", name, name, name)).firstMatch
            }
            if let failure = formRevealFailure { throw Failure.message(failure) }
            if let found = findControl(name, type: type) { return found }
        }
        var found: XCUIElement?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            found = findControl(name, type: type)
            return found != nil
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed, let found else {
            throw Failure.message("Missing hittable control: \(name)\n\(app.debugDescription)")
        }
        return found
    }

    /// The labelled SwiftUI row owns the value; its nested native switch owns the touch.
    func setSwitch(_ element: XCUIElement, to enabled: Bool) throws {
        guard element.exists else { throw Failure.message("Missing labelled switch: " + elementFacts(element)) }
        let expected = enabled ? "1" : "0"
        if element.value as? String != expected {
            let native = element.descendants(matching: .switch).firstMatch
            var hasNative = native.exists
            var target = hasNative ? native : element
            if target.exists && !target.isHittable {
                revealFormElement(element)
                if let failure = formRevealFailure { throw Failure.message(failure) }
                hasNative = native.exists
                target = hasNative ? native : element
            }
            let facts = "row: " + elementFacts(element) + "\nthumb: " + elementFacts(target, includeOverlaps: true)
            logQA("Switch before press", facts)
            guard target.isEnabled && target.isHittable else {
                throw Failure.message("Switch thumb must be enabled and visible\n" + facts)
            }
            target.coordinate(withNormalizedOffset: CGVector(dx: hasNative ? 0.5 : 0.92, dy: 0.5))
                .press(forDuration: 0.05)
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.value as? String == expected
        }, object: nil)
        guard XCTWaiter.wait(for: [changed], timeout: 8) == .completed else {
            let facts = elementFacts(element, includeOverlaps: true)
            logQA("Switch value failed", "expected=\(expected) " + facts)
            throw Failure.message("Switch must become \(enabled)\n" + facts)
        }
    }

    /// Waits for a target in its actual form, searching both directions until the visible rows stop changing.
    /// Existing callers pass lazy firstMatch queries; the closure overload also supports fresh section-scoped queries.
    func revealFormElement(_ element: XCUIElement) { revealFormElement { element } }

    /// Reacquires the target after each scroll and stops at a repeated visible range, avoiding stale virtualized indices.
    func revealFormElement(in form: XCUIElement? = nil, target: () -> XCUIElement) {
        formRevealFailure = nil
        var ancestorClip: CGRect?
        var containerIsTransient = false
        func ancestry(_ target: XCUIElementSnapshot, in root: XCUIElementSnapshot) -> (clip: CGRect, transient: Bool)? {
            func visit(_ node: XCUIElementSnapshot, clip: CGRect, transient: Bool) -> (clip: CGRect, transient: Bool)? {
                let frame = node.frame
                let clipped = frame.isNull || frame.isInfinite || frame.isEmpty ? clip : clip.intersection(frame)
                // UIKit's native context menu in L:#0 exposes Other ancestors and a Preview sibling,
                // rather than a Menu node. Keep that observed surface distinct from ordinary forms.
                let isTransient = transient || node.elementType == .menu || node.elementType == .popover
                    || (node.elementType == .other && node.children.contains { $0.elementType == .other && $0.label == "Preview" })
                if node.elementType == target.elementType && node.identifier == target.identifier
                    && node.label == target.label && node.frame == target.frame { return (clipped, isTransient) }
                for child in node.children {
                    if let match = visit(child, clip: clipped, transient: isTransient) { return match }
                }
                return nil
            }
            return visit(root, clip: app.windows.firstMatch.frame, transient: false)
        }
        func containerLost(_ detail: String) {
            let message = "Reveal drag dismissed or replaced its menu/popover/container: " + detail
            formRevealFailure = message
            recordDiagnostics("Form container changed", facts: message)
            XCTFail(message)
        }
        let initial = target()
        let initialSnapshot = initial.exists ? (try? initial.snapshot()) : nil
        // Unlabelled native thumbs are not unique identities; keep the caller's scoped query.
        let identity = initialSnapshot.flatMap { $0.identifier.isEmpty && $0.label.isEmpty ? nil : $0 }
        func liveList() -> XCUIElement? {
            if let form, form.exists, hasVisibleFrame(form) {
                ancestorClip = nil
                containerIsTransient = false
                // Ordinary explicit forms keep the cheap window clip. Only inspect ancestry
                // within a presented transient surface; native UIKit menus use a Preview sibling.
                let surfaces = app.popovers.allElementsBoundByIndex + app.menus.allElementsBoundByIndex
                let hasNativeMenu = app.otherElements["Preview"].firstMatch.exists
                if !surfaces.isEmpty || hasNativeMenu, let node = try? form.snapshot() {
                    for surface in surfaces where hasVisibleFrame(surface) {
                        if let root = try? surface.snapshot(), let context = ancestry(node, in: root) {
                            ancestorClip = context.clip
                            containerIsTransient = context.transient
                            break
                        }
                    }
                    if ancestorClip == nil, hasNativeMenu, let root = try? app.snapshot(),
                       let context = ancestry(node, in: root), context.transient {
                        ancestorClip = context.clip
                        containerIsTransient = true
                    }
                }
                return form
            }
            guard let root = try? app.snapshot() else {
                logQA("Form reveal unavailable", "snapshotCandidates=0; app snapshot unavailable; candidates not collected")
                return nil
            }
            let window = app.windows.firstMatch.frame
            var candidates: [(node: XCUIElementSnapshot, surface: Int, contains: Bool, overflow: Bool)] = []
            var surfaceOrder = 0
            func containsTarget(_ node: XCUIElementSnapshot) -> Bool {
                guard let identity else { return false }
                if node.elementType == identity.elementType && node.identifier == identity.identifier
                    && node.label == identity.label { return true }
                return node.children.contains { containsTarget($0) }
            }
            func overflows(_ node: XCUIElementSnapshot, frame: CGRect) -> Bool {
                if node.label.hasPrefix("Vertical scroll bar,") {
                    let words = node.label.split(separator: " ")
                    if words.count > 3, let pages = Int(words[3]), pages > 1 { return true }
                }
                if node.frame.height > frame.height + 2 && node.frame.width <= frame.width + 2 { return true }
                return node.children.contains { overflows($0, frame: frame) }
            }
            func visit(_ node: XCUIElementSnapshot, surface: Int) {
                var scope = surface
                if [.sheet, .popover, .alert].contains(node.elementType), node.frame.intersects(window) {
                    surfaceOrder += 1; scope = surfaceOrder
                }
                let frame = node.frame
                if [.collectionView, .table, .scrollView].contains(node.elementType), node.identifier != "nib.canvas",
                   frame.width > 200, frame.height > 100, frame.intersects(window) {
                    candidates.append((node, scope, containsTarget(node), overflows(node, frame: frame)))
                }
                for child in node.children {
                    visit(child, surface: scope)
                }
            }
            visit(root, surface: 0)
            let foremost = surfaceOrder
            // Surface traversal is a preference, not z-order. Rank from the snapshot, then probe
            // only successive winners; retained modal copies must not hide the live form.
            // Keeping all candidates also covers a foremost popover with no scrolling content.
            func smallerNamedCopy(_ node: XCUIElementSnapshot, surface: Int) -> Bool {
                !node.label.isEmpty && candidates.contains {
                    $0.surface == surface && $0.node.label == node.label
                        && $0.node.frame.width * $0.node.frame.height > node.frame.width * node.frame.height
                }
            }
            let ranked = candidates.sorted {
                if ($0.surface == foremost) != ($1.surface == foremost) { return $0.surface == foremost }
                if $0.surface != $1.surface { return $0.surface > $1.surface }
                let firstArea = $0.node.frame.width * $0.node.frame.height
                let secondArea = $1.node.frame.width * $1.node.frame.height
                let firstCopy = smallerNamedCopy($0.node, surface: $0.surface)
                let secondCopy = smallerNamedCopy($1.node, surface: $1.surface)
                if firstCopy != secondCopy { return !firstCopy }
                if $0.contains != $1.contains { return $0.contains }
                if $0.contains { return firstArea < secondArea }
                // Lazy rows are absent: overflow, native detail type, then area (never narrowest).
                if $0.overflow != $1.overflow { return $0.overflow }
                let firstNative = [.collectionView, .table].contains($0.node.elementType)
                let secondNative = [.collectionView, .table].contains($1.node.elementType)
                if firstNative != secondNative { return firstNative }
                return firstArea > secondArea
            }
            var diagnostics: [String] = []
            var fallback: (element: XCUIElement, rank: Int, frame: CGRect)?
            func chosen(_ element: XCUIElement, rank: Int, frame: CGRect, hittable: Bool) -> XCUIElement {
                let node = ranked[rank].node
                let context = ancestry(node, in: root)
                ancestorClip = context?.clip
                containerIsTransient = context?.transient ?? false
                logQA("Form reveal container", "type=\(node.elementType) label=\(node.label) frame=\(frame) rank=\(rank + 1)/\(ranked.count) hittable=\(hittable)")
                return element
            }
            for (rank, candidate) in ranked.enumerated() {
                let node = candidate.node
                // Snapshot child ordinals are not live query ordinals. Bind by native type and
                // available identity, then verify all four edges against the ranked snapshot.
                var query = app.descendants(matching: node.elementType)
                if !node.identifier.isEmpty {
                    query = query.matching(NSPredicate(format: "identifier == %@", node.identifier))
                }
                if !node.label.isEmpty {
                    query = query.matching(NSPredicate(format: "label == %@", node.label))
                }
                var walked = 0, existing = 0
                var resolved: (element: XCUIElement, frame: CGRect, hittable: Bool)?
                for index in 0..<min(query.count, 24) {
                    walked += 1
                    let element = query.element(boundBy: index)
                    guard element.exists else { continue }
                    existing += 1
                    let frame = element.frame
                    guard abs(frame.minX - node.frame.minX) <= 1,
                          abs(frame.minY - node.frame.minY) <= 1,
                          abs(frame.maxX - node.frame.maxX) <= 1,
                          abs(frame.maxY - node.frame.maxY) <= 1 else { continue }
                    resolved = (element, frame, element.isHittable)
                    break
                }
                if rank < 8 {
                    // Separate lets keep each interpolation trivial for the type checker.
                    let matched = resolved != nil
                    let exists = matched ? "true" : "n/a"
                    let hittable = resolved.map { String($0.hittable) } ?? "n/a"
                    let nodeFacts = "rank=\(rank + 1) type=\(node.elementType) label=\(node.label) frame=\(node.frame)"
                    let rankFacts = "surface=\(candidate.surface) contains=\(candidate.contains) overflow=\(candidate.overflow)"
                    let probeFacts = "walked=\(walked) existing=\(existing) frameMatched=\(matched) exists=\(exists) isHittable=\(hittable)"
                    diagnostics.append([nodeFacts, rankFacts, probeFacts].joined(separator: " "))
                }
                guard let resolved else { continue }
                if resolved.hittable {
                    return chosen(resolved.element, rank: rank, frame: resolved.frame, hittable: true)
                }
                let visible = resolved.frame.intersection(window)
                if fallback == nil, !visible.isNull, visible.width > 1, visible.height > 1 {
                    fallback = (resolved.element, rank, resolved.frame)
                }
            }
            // Some native forms report a non-hittable container while their rows accept input.
            // Drags use app coordinates; this element supplies only snapshots and scoped queries.
            // Verified frame identity/window overlap replaces the retained off-screen-copy filter.
            if let fallback {
                return chosen(fallback.element, rank: fallback.rank, frame: fallback.frame, hittable: false)
            }
            logQA("Form reveal unavailable", "snapshotCandidates=\(ranked.count); no resolved hittable or in-window container\n"
                + diagnostics.joined(separator: "\n"))
            return nil
        }
        guard var list = liveList(), let firstSnapshot = try? list.snapshot() else {
            logQA("Form reveal unavailable", "No live container snapshot; caller retains its wait/fallback")
            return
        }
        let window = app.windows.firstMatch.frame
        let obstructions = app.keyboards.allElementsBoundByIndex.filter { $0.exists }.map(\.frame)
            + app.otherElements.matching(identifier: "inputAssistantView").allElementsBoundByIndex.filter { $0.exists }.map(\.frame)
        var snapshot = firstSnapshot
        var visited = Set<String>()
        var direction: Bool?
        var reversed = false
        var endSignatures: [String] = []
        for _ in 0..<16 {
            let listFrame = snapshot.frame
            var clippedViewport = NibUITestScrollGeometry.viewport(
                scroll: listFrame.intersection(ancestorClip ?? window), window: window, obstructions: obstructions)
            if clippedViewport == nil, let ancestorClip {
                logQA("Form viewport fallback", "Unusable ancestor clip=\(ancestorClip); using container=\(listFrame) intersected with window=\(window)")
                clippedViewport = NibUITestScrollGeometry.viewport(
                    scroll: listFrame, window: window, obstructions: obstructions)
            }
            guard let viewport = clippedViewport else { return }
            let element: XCUIElement
            if let identity {
                element = list.descendants(matching: identity.elementType).matching(NSPredicate(
                    format: "identifier == %@ AND label == %@", identity.identifier, identity.label)).firstMatch
            } else { element = target() }
            let targetFrame = element.exists ? element.frame : nil
            if let targetFrame, viewport.contains(CGPoint(x: targetFrame.midX, y: targetFrame.midY)),
               element.isHittable { return }
            let signature = formVisibleRange(snapshot, viewport: viewport).joined(separator: "\n")
            if !visited.insert(signature).inserted {
                endSignatures.append(signature)
                guard !reversed else {
                    logQA("Form search exhausted", "both ends=\(endSignatures)")
                    return
                }
                reversed = true
                direction = !(direction ?? false)
                visited = [signature]
            }
            if direction == nil { direction = targetFrame.map { $0.midY < viewport.midY } ?? false }
            let down = direction ?? false
            guard let start = formDragStart(snapshot, viewport: viewport, down: down) else { return }
            let end = CGPoint(x: start.x, y: down ? viewport.maxY - 24 : viewport.minY + 24)
            let values = formControlValues(snapshot)
            let wasTransient = containerIsTransient
            logQA("Form drag before", "point=\(start) container=\(listFrame) rows=\(signature)")
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: start.x - app.frame.minX, dy: start.y - app.frame.minY))
                .press(forDuration: 0.01, thenDragTo: origin.withOffset(
                    CGVector(dx: end.x - app.frame.minX, dy: end.y - app.frame.minY)), withVelocity: .slow, thenHoldForDuration: 0)
            // Library grids can replace their containers while scrolling. Keep the cheap cached query
            // normally, but reacquire it if that container disappears or its snapshot becomes unavailable.
            var nextSnapshot: XCUIElementSnapshot? = list.exists ? (try? list.snapshot()) : nil
            if nextSnapshot == nil, let replacement = liveList() {
                list = replacement
                nextSnapshot = try? replacement.snapshot()
            }
            guard let after = nextSnapshot else {
                if wasTransient {
                    containerLost("container disappeared after drag: before=\(snapshot.elementType) \(listFrame)")
                } else {
                    logQA("Form reveal unavailable", "Container snapshot unavailable after drag; before=\(listFrame); caller retains its wait/fallback")
                }
                return
            }
            let dx0: CGFloat = abs(after.frame.minX - listFrame.minX)
            let dy0: CGFloat = abs(after.frame.minY - listFrame.minY)
            let dx1: CGFloat = abs(after.frame.maxX - listFrame.maxX)
            let dy1: CGFloat = abs(after.frame.maxY - listFrame.maxY)
            let sameFrame = dx0 <= 1.0 && dy0 <= 1.0 && dx1 <= 1.0 && dy1 <= 1.0
            if wasTransient && (after.elementType != snapshot.elementType || !sameFrame) {
                containerLost("before=\(snapshot.elementType) \(listFrame) after=\(after.elementType) \(after.frame)")
                return
            }
            if after.elementType != snapshot.elementType || !sameFrame {
                logQA("Form container changed", "Ordinary form rebuilt or resized; before=\(listFrame) after=\(after.frame); continuing with new snapshot")
                // A previous ordinary ancestor clip can be stale after a resize or lazy-query rebind.
                ancestorClip = nil
            }
            logQA("Form drag after", "point=\(start) container=\(after.frame) rows=\(formVisibleRange(after, viewport: viewport))")
            snapshot = after // Reuse this post-drag snapshot as the next iteration's before state.
            let afterValues = formControlValues(after)
            // Virtualization can renumber repeated identities. Compare only unchanged-size groups.
            let changed = values.keys.filter {
                guard let before = values[$0], let after = afterValues[$0], before.count == after.count else { return false }
                return before != after
            }
            guard changed.isEmpty else {
                logQA("Form drag changed controls", "before=\(values) after=\(afterValues)")
                XCTFail("Reveal drag changed slider/switch values: \(changed)"); return
            }
        }
        logQA("Form search bounded", "ends=\(endSignatures) visited=\(visited.sorted())")
    }

    /// Frames and control identities only: numeric captions and control values are not scroll progress.
    private func formVisibleRange(_ snapshot: XCUIElementSnapshot, viewport: CGRect) -> [String] {
        let frame = snapshot.frame
        let rowTypes: [XCUIElement.ElementType] = [.button, .switch, .slider, .textField, .textView,
            .searchField, .secureTextField, .stepper, .segmentedControl, .picker, .pickerWheel]
        let own = rowTypes.contains(snapshot.elementType)
            && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
            ? ["\(snapshot.elementType.rawValue)|\(snapshot.identifier)|\(snapshot.label)|\(frame)"] : []
        return own + snapshot.children.flatMap { formVisibleRange($0, viewport: viewport) }
    }

    private func formControlValues(_ snapshot: XCUIElementSnapshot) -> [String: [String]] {
        var result: [String: [String]] = [:]
        func visit(_ node: XCUIElementSnapshot, parent: String) {
            let identity = "\(node.elementType.rawValue)|\(node.identifier)|\(node.label)"
            let path = parent + "/" + identity
            if [.slider, .switch].contains(node.elementType) {
                result[path, default: []].append(String(describing: node.value))
            }
            // A native row exposes a labelled switch plus an unlabelled thumb. Keep its parent identity,
            // so virtualizing another row cannot renumber unrelated thumbs and report a false mutation.
            let ancestor = [.slider, .switch].contains(node.elementType) ? path : parent
            node.children.forEach { visit($0, parent: ancestor) }
        }
        visit(snapshot, parent: "")
        return result
    }

    /// Search real row gaps first, then a row of plain buttons, then the leading inset of a dense form.
    private func formDragStart(_ snapshot: XCUIElementSnapshot, viewport: CGRect, down: Bool) -> CGPoint? {
        let interactive: [XCUIElement.ElementType] = [.slider, .switch, .button, .textField, .textView,
            .secureTextField, .searchField, .stepper, .segmentedControl, .picker, .pickerWheel, .link]
        func controls(_ node: XCUIElementSnapshot) -> [(String, CGRect)] {
            let own = interactive.contains(node.elementType) ? [(node.label, node.frame)] : []
            return own + node.children.flatMap { controls($0) }
        }
        // Controls that keep a touch which starts on or near them. NibSlider takes the touch at touch down
        // (DragGesture(minimumDistance: 0)) and its touch area is taller than its accessibility frame: in run
        // 41985396100 a drag that began 23.5 pt away from a slider frame changed its value. Plain buttons and
        // links do not keep a drag, the scroll view cancels their press, and menus made only of button rows
        // (the More menu) offer no other place to start: the same run logged "Form no safe point" 28 times.
        func frames(_ node: XCUIElementSnapshot, of types: [XCUIElement.ElementType]) -> [CGRect] {
            let own = types.contains(node.elementType) ? [node.frame] : []
            return own + node.children.flatMap { frames($0, of: types) }
        }
        let sliders = frames(snapshot, of: [.slider])
        let holding = frames(snapshot, of: [.switch, .textField, .textView, .secureTextField, .searchField,
                                            .stepper, .segmentedControl, .picker, .pickerWheel])
        func verticalMargin(_ rects: [CGRect], _ y: CGFloat) -> CGFloat {
            rects.map { max($0.minY - y, y - $0.maxY) }.min() ?? viewport.height
        }
        let blocked = controls(snapshot)
        let preferredY = viewport.minY + viewport.height * (down ? 0.25 : 0.75)
        let ys = stride(from: viewport.minY + 24, through: viewport.maxY - 24, by: 4).sorted {
            abs($0 - preferredY) < abs($1 - preferredY)
        }
        let endY = down ? viewport.maxY - 24 : viewport.minY + 24
        // First pass ignores x: every interactive frame must be at least 32pt away vertically.
        for y in ys where abs(endY - y) >= 24 {
            let clearance = blocked.map { max($0.1.minY - y, y - $0.1.maxY) }.min() ?? viewport.height
            if clearance >= 32 {
                let point = CGPoint(x: viewport.midX, y: y)
                logQA("Form drag point", "pass=row-gap point=\(point) verticalMargin=\(clearance) viewport=\(viewport)")
                return point
            }
        }
        // Second pass: any row that is 40pt away from every slider and 12pt away from the other holding
        // controls, which in practice is a row of plain buttons or captions.
        for y in ys where abs(endY - y) >= 24 {
            let sliderMargin = verticalMargin(sliders, y)
            let holdingMargin = verticalMargin(holding, y)
            if sliderMargin >= 40, holdingMargin >= 12 {
                let point = CGPoint(x: viewport.midX, y: y)
                logQA("Form drag point", "pass=plain-row point=\(point) sliderMargin=\(sliderMargin) holdingMargin=\(holdingMargin) viewport=\(viewport)")
                return point
            }
        }
        // Third pass: only the leading inset, retaining the 4pt horizontal exclusion.
        let x = viewport.minX + 6
        var best: (point: CGPoint, clearance: CGFloat)?
        for y in ys {
            guard abs(endY - y) >= 24 else { continue }
            let point = CGPoint(x: x, y: y)
            let relevant = blocked.filter { x >= $0.1.minX - 4 && x <= $0.1.maxX + 4 }
            let clearance = relevant.map { max($0.1.minY - y, y - $0.1.maxY) }.min() ?? viewport.height
            if clearance >= 32, verticalMargin(sliders, y) >= 40 {
                logQA("Form drag point", "pass=leading-inset point=\(point) verticalMargin=\(clearance) horizontalMargin=4 viewport=\(viewport) controls=\(blocked)")
                return point
            }
            // Never start inside an interactive frame, and never within a slider's touch area, even in the
            // best-effort fallback: failing to scroll is better than changing a setting.
            if clearance > 0, verticalMargin(sliders, y) >= 40, clearance > (best?.clearance ?? 0) {
                best = (point, clearance)
            }
        }
        if let best {
            logQA("Form best clearance", "pass=leading-inset point=\(best.point) verticalMargin=\(best.clearance) horizontalMargin=4 viewport=\(viewport) controls=\(blocked)")
            return best.point
        }
        logQA("Form no safe point", "container=\(snapshot.frame) viewport=\(viewport) controls=\(blocked)")
        return nil
    }

    /// Runner NSLog is exported in ui.log; text attachments are not. Bound every line, including long trees.
    func logQA(_ prefix: String, _ facts: String) {
        let characters = Array(facts)
        if characters.isEmpty { NSLog("[Nib QA] %@", prefix); return }
        for start in stride(from: 0, to: characters.count, by: 1200) {
            let chunk = String(characters[start..<min(start + 1200, characters.count)])
            NSLog("[Nib QA] %@ [%ld] %@", prefix, start / 1200, chunk)
        }
    }

    func logStateStep(_ step: String) {
        // The attribute, not a snapshot: snapshots truncate the probe's long JSON value.
        let value = probe.exists ? probe.value : nil
        logQA("State step", "\(step) probe=\(String(describing: value))")
    }

    private static var idleSelectorClasses: Set<String> = []

    /// Discovery only: do not invoke, replace or swizzle any private XCTest waiting selector.
    func logIdleSelectors(for testClass: String) {
        guard Self.idleSelectorClasses.insert(testClass).inserted else { return }
        for name in ["XCUIApplicationProcess", "XCUIApplicationImpl"] {
            guard let cls = NSClassFromString(name) else {
                logQA("XCTest idle selectors", "testClass=\(testClass) class=\(name) unavailable")
                continue
            }
            var count: UInt32 = 0
            guard let methods = class_copyMethodList(cls, &count) else {
                logQA("XCTest idle selectors", "testClass=\(testClass) class=\(name) no instance methods")
                continue
            }
            defer { free(methods) }
            let names = (0..<Int(count)).map { NSStringFromSelector(method_getName(methods[$0])) }.filter {
                let lower = $0.lowercased()
                return lower.contains("uiescen") || lower.contains("idle") || lower.contains("nimation")
            }.sorted()
            logQA("XCTest idle selectors", "testClass=\(testClass) class=\(name) selectors=\(names)")
        }
    }

    /// Complete Files' New Folder action using the editor supplied by the OS.
    /// iOS 26 uses an inline text view and Done; older pickers use an alert and Create.
    func nameNewFilesFolder(_ title: String) throws {
        let inline = app.textViews["DOC.inlineRenameField"]
        let alertField = app.alerts.textFields.firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            inline.isHittable || alertField.isHittable
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 12) == .completed else {
            throw Failure.message("Files must expose its new-folder name editor")
        }
        let usesInlineEditor = inline.isHittable
        let field = usesInlineEditor ? inline : alertField
        try replaceNativeText(in: field, with: title)
        if usesInlineEditor {
            field.typeText("\n")
        } else {
            let create = app.alerts.buttons["Create"]
            guard create.isHittable && create.isEnabled else { throw Failure.message("Files Create must be available") }
            create.tap()
        }
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !field.exists }, object: nil)
        guard XCTWaiter.wait(for: [finished], timeout: 12) == .completed else {
            throw Failure.message("Files must finish naming the new folder")
        }
    }

    /// Waits for the actual microphone prompt (or an already-authorized Recording HUD), then for system alerts to disappear.
    /// Startup/teardown callers drain outstanding known authorization prompts without accepting unrelated dialogs.
    func handleAuthorizationAlerts(waitForMicrophone: Bool = false, waitForCountdown: (() -> Bool)? = nil) throws {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = NSPredicate(format: "label CONTAINS[c] 'microphone' OR label CONTAINS[c] 'calendar' OR label CONTAINS[c] 'photos' OR label CONTAINS[c] 'notification'")
        /// Reads the currently visible authorization without waiting; the outer expectation handles asynchronous presentation.
        func alert(microphoneOnly: Bool = false) -> XCUIElement? {
            let filter = microphoneOnly ? NSPredicate(format: "label CONTAINS[c] 'microphone'") : permission
            let title = system.alerts.matching(filter).firstMatch
            if title.exists { return title }
            let content = system.alerts.containing(filter).firstMatch
            if content.exists { return content }
            return nil
        }
        if waitForMicrophone {
            let recording = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Recording' AND value != nil")).firstMatch
            let requested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                alert(microphoneOnly: true) != nil || recording.exists
            }, object: nil)
            guard XCTWaiter.wait(for: [requested], timeout: 15) == .completed else {
                throw Failure.message("Quick Record produced neither microphone authorization nor Recording HUD\n\(system.debugDescription)")
            }
        }
        if let waitForCountdown {
            let requested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                alert() != nil || waitForCountdown()
            }, object: nil)
            guard XCTWaiter.wait(for: [requested], timeout: 12) == .completed else {
                throw Failure.message("Start Timer produced neither authorization nor countdown")
            }
        }
        for _ in 0..<3 {
            guard let prompt = alert() else { return }
            let notification = prompt.label.localizedCaseInsensitiveContains("notification")
                || prompt.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'notification'")).firstMatch.exists
            let allow = notification ? prompt.buttons.matching(NSPredicate(
                format: "label BEGINSWITH 'Don' AND label ENDSWITH 'Allow'")).firstMatch : prompt.buttons.matching(NSPredicate(
                format: "label IN {'Allow', 'OK', 'Allow Full Access', 'Allow Access to All Photos'}")).firstMatch
            guard allow.isHittable else { throw Failure.message("Authorization has no observed permission action\n\(system.debugDescription)") }
            allow.tap()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !prompt.exists }, object: nil)
            guard XCTWaiter.wait(for: [gone], timeout: 8) == .completed else {
                throw Failure.message("Authorization alert must disappear before continuing\n\(system.debugDescription)")
            }
        }
        guard alert() == nil else { throw Failure.message("Outstanding authorization survived cleanup") }
    }

    /// The display in screen points, in the current orientation, measured from a screenshot of the device rather
    /// than from the runner's UIScreen (which reports the runner's compatibility size on large iPads). A screenshot
    /// image carries the device scale when XCTest sets it; otherwise its size is in pixels and the runner's scale,
    /// which is the device's, converts it.
    private static var displayRects: [Int: CGRect] = [:]

    static func displayRect() -> CGRect {
        let orientation = XCUIDevice.shared.orientation
        if let cached = displayRects[orientation.rawValue] { return cached }
        let image = XCUIScreen.main.screenshot().image
        let scale = image.scale > 1 ? CGFloat(1) : UIScreen.main.scale
        let rect = CGRect(origin: .zero, size: CGSize(width: image.size.width / scale, height: image.size.height / scale))
        // Never poison the cache with an image captured during an orientation transition or face-up/unknown state.
        if (orientation.isLandscape && rect.width > rect.height) || (orientation.isPortrait && rect.height > rect.width) {
            displayRects[orientation.rawValue] = rect
        }
        return rect
    }

    /// Waits for the main window to cover the physical display before any orientation assertion.
    /// Fixture data resets do not reset iPadOS window placement left by an earlier gesture.
    func establishFullScreen(allowFixtureRelaunch: Bool = false) throws {
        if app.state != .runningForeground { app.activate() }
        // The screenshot is the device's display in its current orientation. The runner's own UIScreen is not:
        // on an iPad Pro 13-inch it reports the runner's 768 x 1024 compatibility bounds while the app window is
        // 1032 x 1376 points, and it keeps portrait bounds after the foreground app rotates.
        let screen = NibUI.displayRect()
        /// Reads current window edges without waiting; the enclosing expectation waits for fullscreen placement.
        func fillsScreen() -> Bool {
            let window = app.windows.firstMatch
            guard window.exists else { return false }
            let f = window.frame
            return abs(f.minX - screen.minX) <= 2 && abs(f.minY - screen.minY) <= 2
                && abs(f.maxX - screen.maxX) <= 2 && abs(f.maxY - screen.maxY) <= 2
        }
        if fillsScreen() { return }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func waitForPlacement(_ timeout: TimeInterval) -> Bool {
            if fillsScreen() { return true }
            return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                fillsScreen()
            }, object: nil)], timeout: timeout) == .completed
        }
        func expandWindow() -> Bool {
            let controls = system.buttons.matching(identifier: "window-controls:app.nib.Nib").firstMatch
            let named = system.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Window Controls, Nib'")).firstMatch
            let opener = controls.exists ? controls : named
            if opener.exists && opener.isHittable { opener.tap() }
            let fullScreen = system.buttons.matching(NSPredicate(
                format: "label ==[c] 'Full Screen' OR label ==[c] 'Enter Full Screen'")).firstMatch
            let menuItem = system.menuItems.matching(NSPredicate(
                format: "label ==[c] 'Full Screen' OR label ==[c] 'Enter Full Screen'")).firstMatch
            let menuReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (fullScreen.exists && fullScreen.isHittable) || (menuItem.exists && menuItem.isHittable)
            }, object: nil)
            if XCTWaiter.wait(for: [menuReady], timeout: 3) == .completed {
                if fullScreen.exists && fullScreen.isHittable { fullScreen.tap() } else { menuItem.tap() }
                return waitForPlacement(5)
            }
            return fillsScreen()
        }
        if expandWindow() { return }
        // Only fixture setup may reset the scene. Mid-test orientation/restoration checks must preserve the document.
        if allowFixtureRelaunch && app.launchArguments.contains("-NibUITestFixture") {
            recordDiagnostics("Full-screen recovery needs fixture relaunch", facts: system.debugDescription)
            app.terminate()
            app.launch()
            _ = try waitForState(timeout: 30) { $0.screen == "library" }
            prepareLaunchKeyRoute()
            if waitForPlacement(3) || expandWindow() { return }
        }
        throw Failure.message("Full-screen recovery failed: display \(screen), window \(app.windows.firstMatch.frame)\n\(system.debugDescription)\n\(app.debugDescription)")
    }

    /// Waits for visible palette anchors, then uses an unobstructed adjacent gap or a verified container edge.
    /// Records the frames for CI and checks that the gesture leaves the app window fixed.
    func dragPalette(to destination: CGPoint) throws {
        let before = app.windows.firstMatch.frame
        // Never ask AX for these buttons' activation points: hidden dock-transition copies can raise.
        // Both anchors and obstruction checks come from the SAME visible Tools subtree snapshot.
        func targets(_ node: XCUIElementSnapshot) -> [(identifier: String, label: String, frame: CGRect)] {
            let actionable: [XCUIElement.ElementType] = [.button, .switch, .slider, .textField, .cell]
            if actionable.contains(node.elementType)
                || (node.children.isEmpty && (node.identifier.hasPrefix("cmd.") || node.identifier.hasPrefix("tool."))) {
                return [(node.identifier, node.label, node.frame)]
            }
            return node.children.flatMap { targets($0) }
        }
        var paletteFrame = CGRect.zero
        var a = CGRect.zero, b = CGRect.zero
        var controls: [(identifier: String, label: String, frame: CGRect)] = []
        func resolveAnchors() -> Bool {
            let palettes = app.otherElements.matching(NSPredicate(format: "label == 'Tools'"))
            for palette in palettes.allElementsBoundByIndex.prefix(8) {
                guard palette.exists, let snapshot = try? palette.snapshot() else { continue }
                let frame = snapshot.frame
                guard !frame.isNull, !frame.isInfinite, frame.width > 1, frame.height > 1,
                      before.contains(frame) else { continue }
                let candidates = targets(snapshot)
                func visible(_ rect: CGRect) -> Bool {
                    !rect.isNull && !rect.isInfinite && rect.width > 1 && rect.height > 1
                        && frame.contains(rect) && before.contains(rect)
                }
                guard let more = candidates.first(where: { $0.identifier == "tool.more" && visible($0.frame) }),
                      let colour = candidates.first(where: {
                          $0.identifier == "cmd.preset.select" && $0.label == "Colour 1" && visible($0.frame)
                      }) else { continue }
                paletteFrame = frame; a = more.frame; b = colour.frame; controls = candidates
                return true
            }
            return false
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in resolveAnchors() }, object: nil)
        guard resolveAnchors() || XCTWaiter.wait(for: [ready], timeout: 8) == .completed else {
            recordDiagnostics("Palette anchors unavailable", facts: "window=\(before); require More tools and Colour 1 in one visible Tools container")
            throw Failure.message("Palette separator grip needs visible More tools and Colour 1 in Tools")
        }
        let vertical = abs(a.midY - b.midY) > abs(a.midX - b.midX)
        let leading = vertical ? min(a.maxY, b.maxY) : min(a.maxX, b.maxX)
        let trailing = vertical ? max(a.minY, b.minY) : max(a.minX, b.minX)
        let gap = trailing - leading
        let crossMin = vertical ? max(a.minX, b.minX) : max(a.minY, b.minY)
        let crossMax = vertical ? min(a.maxX, b.maxX) : min(a.maxY, b.maxY)
        let separator = vertical
            ? CGRect(x: crossMin, y: leading, width: max(0, crossMax - crossMin), height: max(0, gap))
            : CGRect(x: leading, y: crossMin, width: max(0, gap), height: max(0, crossMax - crossMin))
        let midpoint = CGPoint(x: separator.midX, y: separator.midY)
        // The canvas and decorative leaf Other/Image nodes cover this gap in AX but are not palette controls.
        let visible = before.insetBy(dx: 8, dy: 8)
        func clear(_ point: CGPoint) -> Bool {
            visible.contains(point) && paletteFrame.contains(point)
                && !controls.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
        }
        // Test the actual contact, not the entire gap rectangle: adjacent button edges touch that rectangle.
        let adjacent = gap >= 4 && gap <= 40 && crossMax - crossMin >= 8 && clear(midpoint)
        var chosen: CGPoint? = adjacent ? midpoint : nil
        if chosen == nil {
            let edges = vertical
                ? [CGPoint(x: paletteFrame.midX, y: paletteFrame.minY + 6), CGPoint(x: paletteFrame.midX, y: paletteFrame.maxY - 6)]
                : [CGPoint(x: paletteFrame.minX + 6, y: paletteFrame.midY), CGPoint(x: paletteFrame.maxX - 6, y: paletteFrame.midY)]
            let thickness = vertical ? paletteFrame.width : paletteFrame.height
            let anchorThickness = vertical ? max(a.width, b.width) : max(a.height, b.height)
            if thickness <= anchorThickness + 16 { chosen = edges.first(where: clear) }
        }
        XCTContext.runActivity(named: "Palette drag anchor geometry") { activity in
            let frames = controls.map { "\($0.identifier) | \($0.label): \($0.frame)" }.joined(separator: "\n")
            let attachment = XCTAttachment(string: "More \(a), Colour 1 \(b), window \(before)\n"
                + "gap \(gap), separator \(separator), adjacent \(adjacent), palette \(String(describing: paletteFrame))\n"
                + "chosen \(String(describing: chosen)), destination \(destination)\n\(frames)")
            attachment.name = "palette-drag-frames"; attachment.lifetime = .keepAlways; activity.add(attachment)
        }
        guard let grip = chosen else {
            throw Failure.message("No unobstructed palette separator or container edge: More \(a), colour \(b), window \(before)")
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: grip.x - app.frame.minX, dy: grip.y - app.frame.minY))
            .press(forDuration: 0.15, thenDragTo: app.coordinate(withNormalizedOffset:
                CGVector(dx: destination.x, dy: destination.y)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let after = app.windows.firstMatch.frame
        guard abs(after.minX - before.minX) <= 2, abs(after.minY - before.minY) <= 2,
              abs(after.width - before.width) <= 2, abs(after.height - before.height) <= 2 else {
            throw Failure.message("Palette gesture moved the app window: \(before) -> \(after); grip \(grip)")
        }
    }

    func launchFixture(scenario: FixtureScenario = .standard) throws {
        app.launchArguments = ["-NibUITestFixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-NibUITestScenario", scenario.rawValue]
        app.launch()
        // Cold package creation and service startup share the machine with builds.
        // Keep the readiness assertion, but do not give launch the short deadline
        // used for an already-running command.
        try handleAuthorizationAlerts()
        _ = try waitForState(timeout: 120) { $0.screen == "library" }
        try handleAuthorizationAlerts()
        // Rotate only the running app, not SpringBoard or a previous test's system service. Repeated portrait
        // resets add an unrelated orientation-confirmation race before Nib even launches.
        // Re-request orientation only if the device or this scene still disagrees; SpringBoard's orientation
        // alone does not prove that the launched scene has rotated.
        if XCUIDevice.shared.orientation != .landscapeLeft || app.windows.firstMatch.frame.width <= app.windows.firstMatch.frame.height {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            // The application's union frame includes transient system windows.
            // Validate the main app window using one fresh snapshot per poll.
            let window = app.windows.firstMatch
            guard window.exists else { return false }
            let frame = window.frame
            return frame.width > frame.height && frame.height > 0
        }, object: nil)
        let frame = app.windows.firstMatch.frame
        guard (frame.width > frame.height && frame.height > 0)
            || XCTWaiter.wait(for: [landscape], timeout: 30) == .completed else {
            throw Failure.message("Nib's launched scene did not reach landscape")
        }
        try establishFullScreen(allowFixtureRelaunch: true)
        _ = try waitForState { $0.screen == "library" }
        try handleAuthorizationAlerts()
        prepareLaunchKeyRoute()
    }

    /// Activates this scene, waits for non-text focus without editing/navigating, and verifies the chord's action.
    /// The activity records requested modifiers beside the shell's existing Key routing / Library key diagnostic logs.
    func chord(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags,
               verifying postcondition: () throws -> Void) throws {
        let before = try state()
        guard before.keyResponderIsText != true else {
            throw Failure.message("Dismiss text editing before global chord; responder=\(before.keyResponder ?? "unknown")")
        }
        let window = app.windows.firstMatch
        let recipient = try globalKeyboardRecipient()
        let focused = try state()
        guard focused.document == before.document, focused.page == before.page,
              focused.strokeCountOnPage == before.strokeCountOnPage,
              focused.itemCountOnPage == before.itemCountOnPage, focused.selectionCount == before.selectionCount,
              focused.undoAvailable == before.undoAvailable, focused.redoAvailable == before.redoAvailable,
              focused.zoom == before.zoom, focused.contentOffset.x == before.contentOffset.x,
              focused.contentOffset.y == before.contentOffset.y, focused.openPanels == before.openPanels,
              !app.keyboards.firstMatch.exists else {
            throw Failure.message("Keyboard focus preparation changed document content or navigation; before=\(before); after=\(focused)")
        }
        try XCTContext.runActivity(named: "Requested chord \(key), modifiers \(modifiers.rawValue)") { [self] activity in
            let request = XCTAttachment(string: "key=\(key) modifiers=\(modifiers.rawValue) route=runner hardware event responder=\(recipient) window=\(window.frame)\n\(probe.value ?? "missing")")
            request.lifetime = .keepAlways; activity.add(request)
            // Deliver at device level after verifying UIKit focus; non-text responders have no AX recipient.
            let deliveryBefore = chordProbeSnapshot()
            let logBeforeDelivery = deliveryBefore.state?.keyLog ?? focused.keyLog ?? []
            try hardwareKey(key, modifiers)
            // The app's own account of the key (window press, responder, command run) goes into the test log
            // for passing and failing chords alike.
            defer {
                XCTContext.runActivity(named: "App key log: "
                    + ((try? state())?.keyLog?.joined(separator: " | ") ?? "unavailable")) { _ in }
            }
            do { try postcondition() }
            catch {
                // Allow the caller's bounded postcondition to observe delivery before declaring
                // the key log unchanged; an immediate snapshot can race a late app log entry.
                let deliveryAfter = chordProbeSnapshot()
                if let prior = deliveryBefore.state, let after = deliveryAfter.state,
                   let priorLog = prior.keyLog, let afterLog = after.keyLog,
                   priorLog == afterLog, prior.keyLogTotal == after.keyLogTotal {
                    logQA("Chord no new key event", "key=\(key) modifiers=\(modifiers.rawValue)\nbefore delivery: "
                        + deliveryBefore.facts + "\nafter failed postcondition: " + deliveryAfter.facts)
                }
                // Retry only a proven modifier loss on a fresh printable press outside text editing.
                // In particular, missing events and control keys are not retry evidence.
                if let current = try? state(), current.keyResponderIsText != true,
                   let observed = missingChordModifiers(key, modifiers, before: logBeforeDelivery,
                                                        after: current.keyLog ?? []) {
                    logQA("Chord modifier loss retry", "key=\(key) requested=\(modifiers.rawValue) observed=\(observed)")
                    try sendHardwareKey(key, modifiers)
                    do { try postcondition(); return }
                    catch {
                        recordDiagnostics("Chord retry postcondition failed", facts: "key=\(key) modifiers=\(modifiers.rawValue)")
                        throw error
                    }
                }
                recordDiagnostics("Chord postcondition failed", facts: "key=\(key) modifiers=\(modifiers.rawValue)")
                throw error
            }
        }
    }

    private func chordProbeSnapshot() -> (state: QAState?, facts: String) {
        let raw = (try? probe.snapshot())?.value as? String
        let decoded = raw.flatMap { try? JSONDecoder().decode(QAState.self, from: Data($0.utf8)) }
        // Current probe exposes responder/log but not key-window identity/frame. Preserve the raw
        // probe for future optional fields and identify the AX frame as a separate observation.
        let object = raw.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        let keyWindowValue = object?["keyWindow"]
        let windowFrameValue = object?["windowFrame"]
        let keyWindow = keyWindowValue.map { String(describing: $0) } ?? "unavailable in probe"
        let probeFrame = windowFrameValue.map { String(describing: $0) } ?? "unavailable in probe"
        let window = app.windows.firstMatch
        let axFrame = window.exists ? String(describing: window.frame) : "absent"
        let facts = "keyWindow=\(keyWindow) probeWindowFrame=\(probeFrame) AXFirstWindowFrame=\(axFrame)"
            + " responder=\(decoded?.keyResponder ?? "unavailable") probe=\(raw ?? "unavailable")"
        return (decoded, facts)
    }

    private func missingChordModifiers(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags,
                                       before: [String], after: [String]) -> String? {
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
              scalar.value >= 32, scalar.value < 127 else { return nil }
        var expected = 0
        if modifiers.contains(.shift) { expected |= 1 << 17 }
        if modifiers.contains(.control) { expected |= 1 << 18 }
        if modifiers.contains(.alternate) { expected |= 1 << 19 }
        if modifiers.contains(.command) { expected |= 1 << 20 }
        let supported: XCUIElement.KeyModifierFlags = [.shift, .control, .alternate, .command]
        guard expected != 0, modifiers.subtracting(supported).isEmpty else { return nil }
        // keyLog is bounded: match the retained tail, never mistake an older bare press for this chord.
        var overlap = min(before.count, after.count)
        while overlap > 0 && Array(before.suffix(overlap)) != Array(after.prefix(overlap)) { overlap -= 1 }
        guard before.isEmpty || overlap > 0 else { return nil }
        let prefix = "window press '\(key)' code "
        guard let press = after.dropFirst(overlap).last(where: { $0.hasPrefix(prefix) }),
              let flagsText = press.components(separatedBy: " flags ").last?.split(separator: " ").first,
              let flags = Int(flagsText), flags & expected != expected else { return nil }
        return press
    }

    /// Best effort at process launch, before a native editor can receive its first modified key.
    func prepareLaunchKeyRoute() {
        do { try openHardwareKeyRoute() }
        catch { logQA("Hardware key route unobserved", "launch: \(error)") }
    }

    /// Global responders deliberately have no AX keyboard focus. The fixture probe observes UIKit's responder.
    private func globalKeyboardRecipient() throws -> String {
        let current = try state()
        guard current.keyResponderIsText != true else {
            throw Failure.message("Global chord rejected text responder: \(current.keyResponder ?? "unknown")")
        }
        if app.state != .runningForeground { app.activate() }
        if let responder = current.keyResponder {
            guard current.keyResponderIsText == false else {
                throw Failure.message("Cannot classify existing keyboard responder: \(responder)")
            }
            return responder
        }

        func tapInertHeader(in surface: XCUIElement, modal: Bool) throws {
            // One snapshot avoids per-control AX round trips. Conservatively exclude every control frame,
            // including all button frames, so no hittable library button can become the focus target.
            let snapshot = try surface.snapshot()
            let interactive: [XCUIElement.ElementType] = [.button, .cell, .link, .switch, .slider,
                .segmentedControl, .textField, .textView, .searchField, .secureTextField, .picker, .pickerWheel]
            func occupiedFrames(_ node: XCUIElementSnapshot) -> [CGRect] {
                let own = interactive.contains(node.elementType) ? [node.frame] : []
                return own + node.children.flatMap { occupiedFrames($0) }
            }
            let occupied = occupiedFrames(snapshot)
            let visible = snapshot.frame.intersection(app.windows.firstMatch.frame)
            guard !visible.isNull, !visible.isInfinite, visible.width > 16, visible.height > 16 else {
                throw Failure.message("No visible surface for keyboard focus tap")
            }
            let offsets: [CGFloat] = modal ? [24, 40, 56] : [70, 56, 40]
            let fractions: [CGFloat] = [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8]
            var points = offsets.flatMap { offset in
                fractions.map { fraction in
                    CGPoint(x: visible.minX + visible.width * fraction, y: visible.minY + offset)
                }
            }
            var chromeInsets: [CGPoint] = []
            if !modal, canvas.exists {
                // The whiteboard extends behind window-header whitespace. Only use the inset of
                // an observed bar group (NavBar/NibBarGroup) or Tabs droplet (TabStripView), not that desk.
                let anchors: Set<String> = ["menu.title", "cmd.edit.redo", "cmd.search.open"]
                func hasAnchor(_ node: XCUIElementSnapshot) -> Bool {
                    anchors.contains(node.identifier) || node.children.contains { hasAnchor($0) }
                }
                func chromeFrames(_ node: XCUIElementSnapshot) -> [CGRect] {
                    let children = node.children.flatMap { chromeFrames($0) }
                    if !children.isEmpty { return children } // Innermost group, never the whole nav row.
                    guard node.elementType == .other, node.frame.height > 16, node.frame.height <= 60,
                          node.frame.width < visible.width * 0.75,
                          node.label == "Tabs" || hasAnchor(node) else { return [] }
                    return [node.frame]
                }
                chromeInsets = chromeFrames(snapshot).flatMap { frame in
                    [CGPoint(x: frame.minX + 3, y: frame.midY), CGPoint(x: frame.maxX - 3, y: frame.midY)]
                }.filter { point in
                    visible.contains(point) && !occupied.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
                }
                let drawingSurface = canvas.frame
                points = points.filter { !drawingSurface.contains($0) }
            }
            guard let point = chromeInsets.first ?? points.first(where: { point in
                visible.insetBy(dx: 8, dy: 8).contains(point)
                    && !occupied.contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
            }) else { throw Failure.message("No inert header focus target inside the presented surface") }
            logQA("Keyboard focus header", "point=\(point) modal=\(modal) surface=\(visible) chromeInsets=\(chromeInsets)")
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        }

        // A tap behind a modal can hit its dimming view and dismiss it. Keep focus preparation inside
        // the foremost presented surface; if it has no inert header point, fail without tapping the desk.
        let surface = [app.alerts.firstMatch, app.descendants(matching: .popover).firstMatch,
                       app.sheets.firstMatch].first { hasVisibleFrame($0) }
        if let surface {
            try tapInertHeader(in: surface, modal: true)
        } else if canvas.exists {
            // NavBar inserts NibBarSeparator between editingOrder 1 (Redo) and 2 (Search).
            // Chrome.swift defines a non-action Rectangle, 0.5pt + 6pt padding on either side,
            // within the fixed bar droplet. Never use empty window space over the whiteboard.
            let redo = app.buttons["cmd.edit.redo"].firstMatch
            let search = app.buttons["cmd.search.open"].firstMatch
            var separatorFocused = false
            if redo.exists, search.exists {
                let left = redo.frame, right = search.frame
                let gap = right.minX - left.maxX
                let point = CGPoint(x: (left.maxX + right.minX) / 2, y: left.midY)
                if abs(gap - 12.5) <= 2, abs(left.midY - right.midY) < 1,
                   app.windows.firstMatch.frame.contains(point) {
                    app.coordinate(withNormalizedOffset: .zero).withOffset(
                        CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
                    // An inert separator is not itself a responder. Observe recovery before relying on it;
                    // a missing responder is a bounded fallback condition, not a failed chord assertion.
                    let focused = try? waitForState(timeout: 2) { $0.keyResponder != nil }
                    if let focused {
                        guard focused.keyResponderIsText == false else {
                            throw Failure.message("Separator focus reached unclassified/text responder: \(focused.keyResponder ?? "unknown")")
                        }
                        separatorFocused = true
                    }
                } else {
                    logQA("Keyboard focus fallback", "Separator geometry unavailable: redo=\(left) search=\(right)")
                }
            }
            if !separatorFocused {
                logQA("Keyboard focus fallback", "Separator absent or no responder after tap; trying inert header")
                try tapInertHeader(in: app.windows.firstMatch, modal: false)
            }
        } else {
            // The shell's library tap recognizer schedules reclaimKeyFocusIfNeeded after a real window tap.
            try tapInertHeader(in: app.windows.firstMatch, modal: false)
        }
        let focused = try waitForState(timeout: 5) {
            $0.keyResponderIsText == true || ($0.keyResponder != nil && $0.keyResponderIsText == false)
        }
        guard focused.keyResponderIsText == false, let responder = focused.keyResponder else {
            throw Failure.message("Focus tap reached text responder: \(focused.keyResponder ?? "unknown")")
        }
        return responder
    }

    /// Runner-only hardware delivery, also usable for native popover dismissal without inventing AX focus.
    /// XCTest's synthesized keyboard loses the modifier keys of the first key event a newly launched app process
    /// receives: in runs 41924805545, 41947110795 and 41948098661, 73 of 74 chords sent as the first key of a
    /// process arrived bare or not at all (the app's keyLog shows no modifier press), while every later chord
    /// in the same process arrived intact. So before the first key of a process, open the route with one unbound
    /// plain key and wait until the app reports a press. Skipped while text has the keyboard: it would be typed.
    private func openHardwareKeyRoute() throws {
        let before = try state()
        guard before.keyResponderIsText != true, let log = before.keyLog, log.isEmpty else { return }
        for attempt in 1...3 {
            try sendHardwareKey(";", [])
            if (try? waitForState(timeout: 3) { !($0.keyLog ?? []).isEmpty }) != nil {
                logQA("Hardware key route opened", "attempt \(attempt)")
                return
            }
        }
        // A press delivered to another window of the app is not in keyLog; the caller's postcondition decides.
        logQA("Hardware key route unobserved", "no window press reported after three unbound keys")
    }

    func hardwareKey(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = []) throws {
        try openHardwareKeyRoute()
        try sendHardwareKey(key, modifiers)
    }

    /// Keyboard-page HID usage for the keys XCTest's text-input synthesis cannot produce. typeKey maps characters
    /// through the keyboard layout: the probe runs 41986732631 and 41990900260 (KeyProbeUITests) showed that
    /// Escape, Delete and Forward Delete never reach the app that way, with or without text focus, while the
    /// same keys sent as a HID device event do, and that Return arrives only when sent as a line feed.
    private func hidUsage(forKey key: String) -> UInt? {
        if key == XCUIKeyboardKey.escape.rawValue { return 0x29 }
        if key == XCUIKeyboardKey.delete.rawValue || key == "\u{8}" || key == "\u{7F}" { return 0x2A }
        if key == XCUIKeyboardKey.forwardDelete.rawValue { return 0x4C }
        return nil
    }

    private func sendHIDKey(_ usage: UInt) throws {
        try XCTContext.runActivity(named: "Hardware key HID usage \(usage)") { _ in
            let done = XCTestExpectation(description: "HID key delivered")
            var failure: Error?
            NibTouchPaths.sendHIDUsage(usage, page: 0x07, duration: 0.05) { error in
                failure = error; done.fulfill()
            }
            guard XCTWaiter.wait(for: [done], timeout: 10) == .completed else {
                throw Failure.message("HID key synthesis timed out")
            }
            if let failure { throw failure }
        }
    }

    private func sendHardwareKey(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags) throws {
        if let usage = hidUsage(forKey: key) {
            if modifiers.isEmpty {
                try sendHIDKey(usage)
                return
            }
            // A device event cannot hold a modifier; the typed route below is known not to deliver this key.
            logQA("Hardware key without a working route", "usage=\(usage) modifiers=\(modifiers.rawValue)")
        }
        // The carriage return XCUIKeyboardKey.return carries is dropped; a line feed produces the Return key.
        try sendTypedKey(key == XCUIKeyboardKey.return.rawValue ? "\n" : key, modifiers)
    }

    private func sendTypedKey(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags) throws {
        try XCTContext.runActivity(named: "Hardware key \(key), modifiers \(modifiers.rawValue)") { activity in
            let route = XCTAttachment(string: "route=NibTouchPaths key=\(key) modifiers=\(modifiers.rawValue); SPI route is in runner log")
            route.lifetime = .keepAlways; activity.add(route)
            let done = XCTestExpectation(description: "Hardware key delivered")
            var failure: Error?
            NibTouchPaths.typeKey(key, modifiers: modifiers.rawValue) { error in
                failure = error; done.fulfill()
            }
            guard XCTWaiter.wait(for: [done], timeout: 10) == .completed else {
                throw Failure.message("Hardware key synthesis timed out")
            }
            if let failure { throw failure }
        }
    }

    func state() throws -> QAState {
        if let state = try readState() { return state }
        return try waitForState(timeout: 10) { _ in true }
    }

    /// Waits for this paste's result or the exact native Allow Paste prompt, then for dismissal and completion.
    /// Only the requesting app and SpringBoard are searched; unrelated authorization dialogs are never accepted.
    func waitForPaste(timeout: TimeInterval = 15, result: @escaping () -> Bool) throws {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func allowButton() -> XCUIElement? {
            for source in [app, system] {
                let button = source.buttons["Allow Paste"].firstMatch
                if button.exists && button.isHittable { return button }
            }
            return nil
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            allowButton() != nil || result()
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else {
            throw Failure.message("Paste produced neither its expected result nor Allow Paste")
        }
        if let allow = allowButton() {
            allow.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in allowButton() == nil }, object: nil)
            guard XCTWaiter.wait(for: [dismissed], timeout: 8) == .completed else {
                throw Failure.message("Allow Paste must dismiss before observing pasted content")
            }
        }
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in result() }, object: nil)
        guard XCTWaiter.wait(for: [completed], timeout: timeout) == .completed else {
            throw Failure.message("Authorized paste did not produce the expected content\n\(app.debugDescription)")
        }
    }

    /// Photos on iOS 26 exposes assets as Images under photos_sectioned_layout, not collection cells.
    func photoAsset(diagnostics: Bool = false) throws -> XCUIElement {
        let assets = app.otherElements["photos_sectioned_layout"].images.matching(
            NSPredicate(format: "identifier == 'PXGGridLayout-Info' AND label BEGINSWITH 'Photo,'"))
        let legacy = app.collectionViews.cells.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'"))
        func inspect(_ stage: String) {
            guard diagnostics else { return }
            let first = assets.firstMatch
            logQA("Photos assets " + stage, "first.exists=\(first.exists)")
            for asset in assets.allElementsBoundByIndex.prefix(8) {
                logQA("Photos assets " + stage, elementFacts(asset))
            }
            recordDiagnostics("Photos assets " + stage, includeHierarchy: false)
        }
        inspect("before lookup")
        defer { inspect("after lookup") }
        func candidate() -> XCUIElement? {
            let grid = app.otherElements["photos_sectioned_layout"].firstMatch
            let first = assets.firstMatch
            if grid.exists, hasVisibleFrame(first) {
                let frame = first.frame
                if grid.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) { return first }
            }
            let old = legacy.firstMatch
            if hasVisibleFrame(old), old.isHittable { return old }
            return nil
        }
        if let asset = candidate() { return asset }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in candidate() != nil }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 12) == .completed, let asset = candidate() else {
            throw Failure.message("Photos must expose a selectable asset in its grid\n\(app.debugDescription)")
        }
        return asset
    }

    func tapPhotoAsset(_ asset: XCUIElement) throws {
        guard hasVisibleFrame(asset) else { throw Failure.message("Photos asset lost its visible frame") }
        let frame = asset.frame, origin = app.frame.origin
        let grid = app.otherElements["photos_sectioned_layout"].firstMatch
        let picker = app.otherElements.matching(NSPredicate(format: "label == 'Photos'")).firstMatch
        let selectionScope = picker.exists ? picker : app
        func pickerGone() -> Bool { !grid.exists && !asset.exists && !picker.exists }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y)).tap()
        var outcome = "unobserved"
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if pickerGone() { outcome = "picker closed"; return true }
            if asset.exists, let snapshot = try? asset.snapshot() {
                let value = (snapshot.value as? String ?? "").lowercased()
                if snapshot.isSelected || value == "1" || value == "selected" {
                    outcome = "asset selected value=\(value)"; return true
                }
            }
            // iOS 26 exposes "1 Photo, Location Included" as a Button, not static text.
            for kind in [XCUIElement.ElementType.button, .staticText] {
                let count = selectionScope.descendants(matching: kind).matching(NSPredicate(
                    format: "label MATCHES[c] '^1 Photo([, ].*)?$'")).firstMatch
                if count.exists { outcome = "selection count: " + count.label; return true }
            }
            return false
        }, object: nil)
        let result = XCTWaiter.wait(for: [selected], timeout: 8)
        logQA("Photos asset coordinate selection", "frame=\(frame) outcome=\(outcome) wait=\(result.rawValue)")
        guard result == .completed else {
            recordDiagnostics("Photos asset selection unobserved")
            throw Failure.message("Coordinate tap did not select the Photos asset")
        }
        if pickerGone() { return }
        // The title-bar confirm is a sibling of the inner Other labelled Photos (baseline
        // id=Add, label=Done), so inventory the app once and clip to the picker's observed frame.
        let bounds = selectionScope.frame
        guard let snapshot = try? app.snapshot() else {
            throw Failure.message("Selected Photos picker has no button inventory")
        }
        func buttons(_ node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
            (node.elementType == .button ? [node] : []) + node.children.flatMap { buttons($0) }
        }
        let inventory = buttons(snapshot).filter { button in
            bounds.contains(CGPoint(x: button.frame.midX, y: button.frame.midY))
        }
        for button in inventory {
            let identity = "label=\(button.label) id=\(button.identifier)"
            logQA("Photos picker buttons", "\(identity) frame=\(button.frame) enabled=\(button.isEnabled)")
        }
        // The evidenced iOS 26 checkmark is in the top-right title bar, above the Private Access
        // banner's Close button. Require an actual inventoried button in that region, never a guessed point.
        var candidates = inventory.filter { button in
            let f = button.frame
            let visible = !f.isEmpty && !f.isNull && !f.isInfinite && bounds.contains(CGPoint(x: f.midX, y: f.midY))
            let excluded = ["close", "cancel", "back"].contains(button.label.lowercased())
            let titleBar = f.midX > bounds.maxX - 80 && f.midY < bounds.minY + 60
            let named = button.label == "Add" || button.label == "Done"
            return visible && button.isEnabled && !excluded && (titleBar || named)
        }
        // Remote trees can expose the same control twice. Geometry, not snapshot ordinal, identifies it.
        var frames: [CGRect] = []
        candidates = candidates.filter { button in
            guard !frames.contains(button.frame) else { return false }
            frames.append(button.frame); return true
        }
        guard candidates.count == 1, let confirm = candidates.first else {
            recordDiagnostics("Photos confirm unresolved")
            throw Failure.message("Selected Photos picker must expose one confirmation button; candidates=\(candidates.count)")
        }
        logQA("Photos picker confirm", "id=\(confirm.identifier) label=\(confirm.label) frame=\(confirm.frame)")
        if !confirm.identifier.isEmpty {
            let identified = app.buttons.matching(identifier: confirm.identifier)
            let button = identified.firstMatch
            if identified.count == 1, button.exists, button.frame == confirm.frame {
                try pressWithoutIdle(at: CGPoint(x: button.frame.midX, y: button.frame.midY), duration: 0.05)
            } else {
                try pressWithoutIdle(at: CGPoint(x: confirm.frame.midX, y: confirm.frame.midY), duration: 0.05)
            }
        } else {
            try pressWithoutIdle(at: CGPoint(x: confirm.frame.midX, y: confirm.frame.midY), duration: 0.05)
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pickerGone() }, object: nil)
        guard XCTWaiter.wait(for: [dismissed], timeout: 8) == .completed else {
            recordDiagnostics("Photos confirmation did not dismiss")
            throw Failure.message("Photos picker must close after confirmation")
        }
    }

    /// Exports the current share sheet to a uniquely named Files directory and waits for the real PNG bytes on disk.
    /// The runner only reads the export; it never reads a background UIPasteboard or generates an expected image.
    func saveSharedPNG() throws -> Data {
        var finished = false
        defer {
            if !finished { recordDiagnostics("Save to Files PNG export failed") }
        }
        func shareAction(_ name: String, actionable: Bool = true) -> XCUIElement? {
            for type in [XCUIElement.ElementType.button, .cell, .staticText] {
                if let found = findControl(name, type: type, actionable: actionable) { return found }
            }
            return nil
        }
        if shareAction("Save to Files", actionable: false) == nil {
            var more: XCUIElement?
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                more = shareAction("View More")
                return more != nil || shareAction("Save to Files") != nil
            }, object: nil)
            guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
                throw Failure.message("PNG share sheet must offer Save to Files or View More")
            }
            if shareAction("Save to Files") == nil, let more {
                more.tap()
                logQA("PNG share View More", app.debugDescription)
            }
        }
        if shareAction("Save to Files") == nil {
            revealFormElement {
                shareAction("Save to Files", actionable: false) ?? self.app.cells["Save to Files"].firstMatch
            }
            if let failure = formRevealFailure { throw Failure.message(failure) }
        }
        var action: XCUIElement?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            action = shareAction("Save to Files"); return action != nil
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed, let action else {
            throw Failure.message("PNG share sheet must offer Save to Files")
        }
        action.tap()
        let local = app.cells["DOC.sidebar.item.On My iPad"].firstMatch
        guard local.waitForExistence(timeout: 10), local.isHittable else { throw Failure.message("Files local provider missing") }
        local.tap()
        let nib = app.cells["Nib, Container"].firstMatch
        if nib.waitForExistence(timeout: 3) && nib.isHittable { nib.tap() }
        else {
            guard app.buttons["Nib, Actions Menu"].exists else { throw Failure.message("Export must target Nib Documents") }
        }
        let folder = "QA Screenshot " + UUID().uuidString
        let newFolder = app.buttons["New Folder"].firstMatch
        if !newFolder.isHittable { app.buttons["More"].firstMatch.tap() }
        guard newFolder.waitForExistence(timeout: 5), newFolder.isHittable else { throw Failure.message("Files New Folder missing") }
        newFolder.tap()
        try nameNewFilesFolder(folder)
        let entered = app.buttons[folder + ", Actions Menu"].firstMatch
        let directory = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in entered.exists || directory.exists }, object: nil)
        guard XCTWaiter.wait(for: [created], timeout: 8) == .completed else { throw Failure.message("Files did not create PNG destination") }
        if !entered.exists { directory.tap() }
        guard entered.waitForExistence(timeout: 8) else { throw Failure.message("Files must enter the unique PNG destination") }
        let save = app.buttons["Save"].firstMatch
        guard save.isEnabled && save.isHittable else { throw Failure.message("Files Save unavailable") }
        save.tap()
        // Unverified until simulator CI: Files labels and runner access to sibling app containers.
        // The native picker saves into the app container. The unique directory prevents stale exports matching.
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let destinations = try FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("Documents").appendingPathComponent(folder) }
        var bytes: Data?
        let exported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            for destination in destinations {
                let files = (try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension.lowercased() == "png" {
                    if let data = try? Data(contentsOf: file), UIImage(data: data) != nil { bytes = data; return true }
                }
            }
            return false
        }, object: nil)
        guard XCTWaiter.wait(for: [exported], timeout: 15) == .completed, let bytes else {
            throw Failure.message("Save to Files must produce a decodable PNG in the unique destination")
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !entered.exists }, object: nil)
        guard XCTWaiter.wait(for: [dismissed], timeout: 8) == .completed else { throw Failure.message("Files must finish exporting") }
        finished = true
        return bytes
    }

    /// Drags the visible custom track, then waits for the caller's playback-position oracle; native slider endpoints are absent.
    func dragSlider(_ slider: XCUIElement, to fraction: CGFloat, verifying result: () throws -> Void) throws {
        guard slider.exists && slider.isHittable && slider.frame.width > 28 else {
            throw Failure.message("Custom slider needs a visible track: \(slider)")
        }
        // NibSlider reserves 14 points at each end for its bead; map the fraction onto the actual track.
        let targetX = (14 + min(1, max(0, fraction)) * (slider.frame.width - 28)) / slider.frame.width
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.01, thenDragTo: slider.coordinate(withNormalizedOffset:
                CGVector(dx: targetX, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0)
        try result()
    }

    /// Samples the live probe once, without nesting a state wait inside another expectation.
    func matchesState(_ predicate: (QAState) -> Bool) -> Bool {
        guard let current = try? readState() else { return false }
        return predicate(current)
    }

    /// Reads XCTest's native focus diagnostic, allowing input into an already-focused but keyboard-occluded editor.
    func isKeyboardFocused(_ field: XCUIElement, allowingAttributeFallback: Bool = false,
                           in container: XCUIElement? = nil) -> Bool {
        guard field.exists else { return false }
        let identifier = field.identifier, label = field.label
        if !identifier.isEmpty || !label.isEmpty {
            let identity = !identifier.isEmpty ? NSPredicate(format: "identifier == %@", identifier)
                : NSPredicate(format: "label == %@", label)
            // Query the AX snapshot, never KVC-evaluate this SDK-dependent key on XCUIElement itself.
            let scope = container ?? nativeFormContainer()
            func focused(in source: XCUIElement) -> Bool {
                let match = source.descendants(matching: field.elementType).matching(identity)
                    .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
                return match.exists && match.frame == field.frame
            }
            if focused(in: scope) { return true }
            if scope !== app, focused(in: app) { return true }
            // GIPHY and LaTeX expose focus in Attributes but not the predicate on this OS.
            // Only explicit native-editor callers opt in; ordinary discovery stays cheap.
        }
        guard allowingAttributeFallback else { return false }
        // debugDescription includes the whole application tree after the Attributes line.
        // A different focused field (Duration) must not qualify this field (Timer name).
        return field.debugDescription.components(separatedBy: "\n").first?.contains("Keyboard Focused") == true
    }

    /// Prefer the native dismissal control; floating number pads can expose an unusable AX frame.
    /// Escape is a fallback only. Synthesis completion is not proof that the keyboard disappeared.
    func dismissNativeKeyboard(in application: XCUIApplication? = nil, diagnoseWidth: Bool = false,
                               inertHeader: XCUIElement? = nil) throws {
        let source = application ?? app
        guard source.keyboards.firstMatch.exists else { return }
        let viewport = source.windows.firstMatch.frame
        let hide = source.keyboards.buttons.matching(NSPredicate(
            format: "label IN {'Hide keyboard', 'Dismiss keyboard'}")).allElementsBoundByIndex.prefix(8).first {
                hasVisibleFrame($0, in: viewport)
            }
        let route = inertHeader != nil ? "inert sheet header" :
            (hide == nil ? "hardware Escape (no hittable dismissal control)" : "native Hide/Dismiss keyboard button")
        let keyboardBefore = source.keyboards.firstMatch.frame
        func inspect(_ stage: String) {
            guard diagnoseWidth else { return }
            for button in source.keyboards.buttons.allElementsBoundByIndex {
                logQA("Width keyboard " + stage, "label=\(button.label) frame=\(button.frame)")
            }
            let width = source.textFields["Width in millimetres"].firstMatch
            recordDiagnostics("Width keyboard " + stage,
                facts: "route=\(route) width.exists=\(width.exists) focused=\(width.exists && isKeyboardFocused(width, allowingAttributeFallback: true))",
                includeHierarchy: false)
        }
        inspect("before Hide")
        defer {
            inspect("completion")
            if diagnoseWidth {
                let after = source.keyboards.firstMatch.exists ? String(describing: source.keyboards.firstMatch.frame) : "absent"
                logQA("Width keyboard frame", "route=\(route) before=\(keyboardBefore) after=\(after)")
            }
        }
        try XCTContext.runActivity(named: "Dismiss native keyboard") { activity in
            let attachment = XCTAttachment(string: "route=\(route)")
            attachment.lifetime = .keepAlways; activity.add(attachment)
            if let inertHeader {
                guard hasVisibleFrame(inertHeader), inertHeader.elementType == .staticText else {
                    throw Failure.message("Numeric keyboard dismissal requires the inert sheet heading")
                }
                let frame = inertHeader.frame
                guard !frame.intersects(keyboardBefore) else {
                    throw Failure.message("Numeric keyboard covers the sheet heading")
                }
                source.coordinate(withNormalizedOffset: .zero).withOffset(
                    CGVector(dx: frame.midX - source.frame.minX, dy: frame.midY - source.frame.minY)).tap()
            } else if let hide {
                // Floating keypad keys can report an invalid activation point: isHittable and tap() then record
                // "Failed to determine hittability". Tap the visible frame's centre by coordinate instead.
                let centre = CGPoint(x: hide.frame.midX, y: hide.frame.midY)
                source.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: centre.x - source.frame.minX, dy: centre.y - source.frame.minY)).tap()
            } else { try hardwareKey(XCUIKeyboardKey.escape.rawValue) }
        }
        inspect("after Hide")
        // In the custom-size decimal editor the first outside tap dismisses only the floating pad.
        // A second contact is justified only by a still-present keyboard, never by a fixed delay.
        let firstDismissal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !source.keyboards.firstMatch.exists }, object: nil)
        if inertHeader != nil, source.keyboards.firstMatch.exists,
           XCTWaiter.wait(for: [firstDismissal], timeout: 2) != .completed,
           source.keyboards.firstMatch.exists {
            guard let dockedHide = source.keyboards.buttons.matching(NSPredicate(
                format: "label IN {'Hide keyboard', 'Dismiss keyboard'}")).allElementsBoundByIndex.prefix(8).first(where: {
                    hasVisibleFrame($0, in: viewport)
                }) else {
                logQA("Decimal keyboard remaining", source.keyboards.debugDescription)
                throw Failure.message("Decimal keyboard remains but exposes no visible Hide keyboard key")
            }
            let frame = dockedHide.frame
            logQA("Decimal keyboard remaining", "second contact on Hide keyboard frame=\(frame)")
            source.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: frame.midX - source.frame.minX, dy: frame.midY - source.frame.minY)).tap()
            inspect("after docked Hide")
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !source.keyboards.firstMatch.exists }, object: nil)
        guard !source.keyboards.firstMatch.exists || XCTWaiter.wait(for: [gone], timeout: 5) == .completed else {
            throw Failure.message("Keyboard did not dismiss after \(route)")
        }
    }

    /// Explicit opt-in for four known covered controls, not a global tap policy.
    func prepareCoveredControl(_ name: String) throws {
        let target = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
        let keyboards = app.keyboards.allElementsBoundByIndex.map(\.frame)
        let alert = app.alerts.firstMatch
        let region = app.otherElements["PopoverDismissRegion"].firstMatch
        let numberPad = name == "Move Ruler" && alert.exists && region.exists && app.popovers.firstMatch.exists
        let frame = target.exists ? target.frame : nil
        let covered = frame.map { rect in keyboards.contains { $0.intersects(rect) } } ?? false
        // Ivory is lazy: its Format container, rather than the absent swatch, proves the obstruction.
        let format = app.scrollViews["Format"].firstMatch
        let lazyCovered = name == "Ivory" && format.exists && keyboards.contains { $0.intersects(format.frame) }
        guard numberPad || covered || lazyCovered else { return }
        let editors = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .allElementsBoundByIndex.prefix(4).compactMap { element -> (XCUIElement, String)? in
                guard let snapshot = try? element.snapshot(),
                      [XCUIElement.ElementType.textField, .textView, .searchField, .secureTextField].contains(snapshot.elementType),
                      let value = snapshot.value as? String else { return nil }
                // Rebind without the focus predicate: that predicate stops matching after dismissal.
                let candidates = app.descendants(matching: snapshot.elementType).matching(
                    NSPredicate(format: "identifier == %@ AND label == %@", snapshot.identifier, snapshot.label))
                guard let stable = candidates.allElementsBoundByIndex.first(where: { $0.frame == snapshot.frame }) else {
                    return nil
                }
                return (stable, value)
            }
        logQA("Covered control preparation", "name=\(name) target=\(String(describing: frame)) keyboards=\(keyboards) numberPad=\(numberPad)")
        if numberPad {
            let window = app.windows.firstMatch.frame
            let alertFrame = alert.frame
            let popovers = app.popovers.allElementsBoundByIndex.map(\.frame)
            let points = [CGPoint(x: window.minX + 24, y: window.maxY - 24),
                          CGPoint(x: window.maxX - 24, y: window.maxY - 24)]
            guard let point = points.first(where: { point in
                region.frame.contains(point) && !alertFrame.contains(point)
                    && !popovers.contains(where: { $0.contains(point) })
            }) else {
                throw Failure.message("No number-pad dismissal point outside the alert")
            }
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in !app.popovers.firstMatch.exists }, object: nil)
            guard XCTWaiter.wait(for: [gone], timeout: 5) == .completed else {
                throw Failure.message("Number-pad popover did not dismiss")
            }
        } else { try dismissNativeKeyboard() }
        for (editor, value) in editors {
            guard editor.exists, editor.value as? String == value else {
                throw Failure.message("Keyboard dismissal changed the typed value before \(name)")
            }
        }
    }

    /// Resolve the presented form once for a batch; use typed queries inside it for each editor.
    private func nativeFormContainer() -> XCUIElement {
        for surface in [app.alerts.firstMatch, app.sheets.firstMatch, app.popovers.firstMatch] {
            if surface.exists { return surface }
        }
        return app
    }

    @discardableResult
    func fillNativeForm(_ values: [(String, String)]) throws -> XCUIElement {
        let container = nativeFormContainer()
        var last: XCUIElement?
        for (name, value) in values {
            let started = Date()
            defer { logQA("Native form field duration", "field=\(name) seconds=\(Date().timeIntervalSince(started))") }
            let field = container.textFields.matching(NSPredicate(
                format: "identifier == %@ OR label == %@ OR placeholderValue == %@", name, name, name)).firstMatch
            if !field.exists {
                revealFormElement { field }
                if let failure = formRevealFailure { throw Failure.message(failure) }
            }
            guard field.waitForExistence(timeout: 8) else { throw Failure.message("Missing form field: " + name) }
            try replaceNativeText(in: field, with: value, container: container)
            last = field
        }
        guard let last else { throw Failure.message("Native form needs at least one field") }
        return last
    }

    /// A focused field under a floating keypad can be non-hittable and still be the correct typing target.
    func textEditor(_ name: String, timeout: TimeInterval = 8) throws -> XCUIElement {
        let container = nativeFormContainer()
        var field: XCUIElement?
        func locate() -> Bool {
            let scopes = container === app ? [app] : [container, app]
            for scope in scopes {
                for type in [XCUIElement.ElementType.textField, .textView, .searchField, .secureTextField] {
                    if let found = findControl(name, type: type, actionable: false, in: scope) { field = found; return true }
                }
            }
            return false
        }
        if !locate() {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in locate() }, object: nil)
            guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else {
                throw Failure.message("Missing native text editor: \(name)")
            }
        }
        guard let field else { throw Failure.message("Missing native text editor: \(name)") }
        try focusField(field)
        return field
    }

    /// Waits for native field focus without retapping an existing selection or moving focus to global chrome.
    func focusField(_ field: XCUIElement, in container: XCUIElement? = nil) throws {
        let scope = container ?? nativeFormContainer()
        if isKeyboardFocused(field, in: scope) { return }
        if !hasVisibleFrame(field) || !field.isHittable {
            revealFormElement(field)
            if let failure = formRevealFailure { throw Failure.message(failure) }
        }
        guard hasVisibleFrame(field) && field.isHittable else {
            // Only a keyboard-occluded editor justifies the expensive Attributes-line check (GIPHY, LaTeX).
            if isKeyboardFocused(field, allowingAttributeFallback: true, in: scope) { return }
            throw Failure.message("Native field cannot receive focus: \(field)")
        }
        field.tap()
        // Cheap evidence establishes text focus, not the identity of the editor. Exact text
        // postconditions remain with callers; remote editors retain the field-specific fallback.
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            app.keyboards.firstMatch.exists && (try? readState())?.keyResponderIsText == true
        }, object: nil)
        guard XCTWaiter.wait(for: [focused], timeout: 5) == .completed
                || isKeyboardFocused(field, allowingAttributeFallback: true, in: scope) else {
            throw Failure.message("Native field did not gain keyboard focus: \(field.debugDescription)")
        }
    }

    /// Delivers modifiers while preserving native focus; callers verify the relevant text or formatting result.
    func nativeKey(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = .command, in field: XCUIElement) throws {
        try focusField(field)
        try deliverNativeKey(key, modifiers, in: field)
    }

    private func deliverNativeKey(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags,
                                  in field: XCUIElement) throws {
        try timedAction("Native key \(key), modifiers \(modifiers.rawValue)") {
            if key.lowercased() == "a", modifiers.contains(.command) {
                guard (try? readState())?.keyResponderIsText == true
                        || isKeyboardFocused(field, allowingAttributeFallback: true) else {
                    throw Failure.message("Native Select All rejected: text does not have the keyboard")
                }
            }
            XCTContext.runActivity(named: "Native field key route") { activity in
                let attachment = XCTAttachment(string: "route=XCUIElement.typeKey field=\(field.label) key=\(key) modifiers=\(modifiers.rawValue) probe=\(probe.value ?? "missing")")
                attachment.lifetime = .keepAlways; activity.add(attachment)
            }
            if modifiers.isEmpty, let usage = hidUsage(forKey: key) {
                // XCUIElement.typeKey cannot produce Escape or Delete either (see hidUsage(forKey:)).
                try sendHIDKey(usage)
            } else {
                field.typeKey(key == XCUIKeyboardKey.return.rawValue ? "\n" : key, modifierFlags: modifiers)
            }
        }
    }

    /// Clear is an observable prerequisite, so a failed Select All can never append replacement text.
    func clearNativeText(in field: XCUIElement, container: XCUIElement? = nil) throws {
        // focusField taps an unfocused editor and verifies focus before nativeKey can send Select All.
        try focusField(field, in: container)
        guard let value = field.value as? String else { throw Failure.message("Native editor has no readable value") }
        if value.isEmpty || value == field.placeholderValue { return }
        try deliverNativeKey("a", .command, in: field)
        // Deletion proves the extent of Select All: a partial/absent selection leaves a nonempty value.
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        let remainingValue = field.value as? String
        guard let remaining = remainingValue ?? (field.elementType == .textView ? "" : nil) else {
            throw Failure.message("Native editor lost its value after deletion")
        }
        if !remaining.isEmpty && remaining != field.placeholderValue {
            // typeText inserts arrow raw values literally. Place the caret after the text with a real tap.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: field.elementType == .textView ? 0.98 : 0.5)).tap()
            guard let current = (field.value as? String) ?? (field.elementType == .textView ? "" : nil),
                  current.count <= 4096 else { throw Failure.message("Native clear needs a readable bounded value after caret tap") }
            logQA("Native clear", "field=\(field.identifier) frame=\(field.frame) deleteCount=\(current.count)")
            if !current.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)) }
        }
        try waitForNativeText(in: field, equals: "")
    }

    /// Waits for exact replacement, including empty fields, after proving the old content is gone.
    func replaceNativeText(in field: XCUIElement, with text: String, container: XCUIElement? = nil) throws {
        let started = Date()
        defer { logQA("Native replacement duration", "seconds=\(Date().timeIntervalSince(started))") }
        try clearNativeText(in: field, container: container)
        if !text.isEmpty {
            timedAction("Native replacement delivery (\(text.count) characters)") { field.typeText(text) }
        }
        try waitForNativeText(in: field, equals: text)
    }

    /// Waits for the native editor's actual text; a placeholder represents an empty value, not user content.
    func waitForNativeText(in field: XCUIElement, equals text: String) throws {
        func matches() -> Bool {
            guard field.exists else { return false }
            guard let value = field.value as? String else { return text.isEmpty && field.elementType == .textView }
            return value == text || (text.isEmpty && value == field.placeholderValue)
        }
        if matches() { return }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in matches() }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 8) == .completed else {
            throw Failure.message("Native replacement mismatch: expected \(text.debugDescription), got \(String(describing: field.value))")
        }
    }

    /// Waits for native Cut and Copy availability, which requires a nonempty selection, without editing or undoing.
    /// The callers' rich-text/range assertions verify its extent; this probe preserves text, focus and selection.
    func verifyNativeSelection(in field: XCUIElement, fullText: String) throws {
        // iPad's input assistant exposes these even when a hardware shortcut does not present the edit menu.
        // Never accept cmd.clipboard.*: those controls describe Nib's object selection, not this native field.
        func available(_ title: String, assistant: String) -> Bool {
            let shortcut = app.buttons.matching(identifier: assistant).firstMatch
            if shortcut.exists && shortcut.isEnabled && shortcut.isHittable { return true }
            for type in [XCUIElement.ElementType.menuItem, .button] {
                let action = app.descendants(matching: type).matching(NSPredicate(
                    format: "label ==[c] %@ AND NOT (identifier BEGINSWITH 'cmd.')", title)).firstMatch
                if action.exists && action.isEnabled && action.isHittable { return true }
            }
            return false
        }
        func hasSelection() -> Bool {
            isKeyboardFocused(field, allowingAttributeFallback: true) && field.value as? String == fullText
                && available("Cut", assistant: "assistantCut") && available("Copy", assistant: "assistantCopy")
        }
        if !hasSelection() {
            // Command-A can be routed outside a presented editor. Select through UIKit's edit
            // menu instead; never delete/reinsert text to manufacture a selection or test it.
            try focusField(field)
            func selectAll() -> XCUIElement? {
                for kind in [XCUIElement.ElementType.menuItem, .button] {
                    let action = app.descendants(matching: kind).matching(NSPredicate(
                        format: "label ==[c] 'Select All' AND NOT (identifier BEGINSWITH 'cmd.')")).firstMatch
                    if hasVisibleFrame(action), action.isEnabled, action.isHittable { return action }
                }
                return nil
            }
            func waitForSelectAll() -> XCUIElement? {
                if let action = selectAll() { return action }
                var action: XCUIElement?
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    action = selectAll(); return action != nil
                }, object: nil)
                _ = XCTWaiter.wait(for: [ready], timeout: 2)
                return action
            }
            field.doubleTap()
            var action = waitForSelectAll()
            if action == nil {
                // Collapse the word selection before requesting the caret's Select All menu.
                field.tap()
                field.press(forDuration: 0.8)
                action = waitForSelectAll()
            }
            guard let action else {
                throw Failure.message("Native edit menu must offer Select All after lost Command-A\n\(app.debugDescription)")
            }
            action.tap()
        }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in hasSelection() }, object: nil)
        guard hasSelection() || XCTWaiter.wait(for: [selected], timeout: 8) == .completed else {
            throw Failure.message("Native selection must enable Cut and Copy without changing text\n\(app.debugDescription)")
        }
        try waitForNativeText(in: field, equals: fullText)
    }

    private func readState() throws -> QAState? {
        // Read the attribute itself: an XCUIElementSnapshot truncates long values, and the probe's JSON is long.
        // The snapshot-based read of round 8 failed the first decode of the smoke gate (run 41996886696,
        // "The given data was not valid JSON ... Unexpected end of file").
        guard probe.exists,
              let state = try NibUITestSnapshot.decode(probe.value, as: QAState.self) else { return nil }
        if let failure = state.fixtureError { throw Failure.message("Fixture failed: \(failure)") }
        return state
    }

    @discardableResult
    func waitForState(timeout: TimeInterval = 30, _ matches: @escaping (QAState) -> Bool) throws -> QAState {
        if let current = try readState(), matches(current) { return current }
        var latest: QAState?
        var error: Error?
        let predicate = NSPredicate { [self] _, _ in
            do {
                // Do not assert inside the polling loop: XCTest can omit an element/value for one snapshot even
                // after waitForExistence succeeded. Decode only fresh values and keep the original deadline.
                guard let state = try readState() else { return false }
                latest = state
                return matches(state)
            }
            catch let caught { error = caught; return true }
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
        if let error { throw error }
        guard result == .completed, let latest else {
            throw Failure.message("State did not converge (missing or unmatched nib.qa.state): \(String(describing: latest))\n\(app.debugDescription)")
        }
        return latest
    }

    func openDocument(_ title: String) throws {
        _ = try waitForState { $0.screen == "library" }
        let document = app.buttons.matching(identifier: "cmd.doc.open")
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        guard document.exists || document.waitForExistence(timeout: 15) else { throw Failure.message("Document missing: \(title); state: \(String(describing: probe.value))\n\(app.debugDescription)") }
        // The card's decorative accessibility group can also have a button trait.
        // Only the command-bearing outer button owns document navigation.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: document)
        guard (document.isHittable && document.isEnabled) || XCTWaiter.wait(for: [ready], timeout: 15) == .completed else { throw Failure.message("Document is not hittable: \(title)") }
        // Hittable means that some of the card is visible, not that its centre
        // lies in the library's scroll viewport. A clipped card must receive the
        // same visible tap a person can make, never a tap on chrome below it.
        var visible = app.windows.firstMatch.frame
        for scroll in app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex {
            let cards = scroll.buttons.matching(identifier: "cmd.doc.open")
                .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ","))
            if cards.count > 0 { visible = visible.intersection(scroll.frame) }
        }
        guard let point = NibUITestScrollGeometry.tapPoint(control: document.frame, viewport: visible) else {
            throw Failure.message("Document has no visible tap area: \(title)")
        }
        try pressWithoutIdle(at: point, duration: 0.05)
        _ = try waitForState { $0.screen == "document" && $0.document != nil }
    }

    func tapCommand(_ id: String, diagnostics: Bool = false) throws {
        try tapControl("cmd." + id, overflow: ["menu.more", "tool.more"], diagnostics: diagnostics)
    }

    /// Uses the real Copy control and reads its actual pasteboard output in the writing app. A background runner's
    /// UIPasteboard.data read can be denied or stall indefinitely; clipboard contents are not a session-state proxy.
    func copyFragment() throws -> Data {
        struct Snapshot: Decodable {
            let changeCount: Int
            let fragment: Data?
        }
        let before = try XCTUnwrap(state().clipboardChangeCount, "Missing clipboard revision")
        try tapCommand("clipboard.copy")
        _ = try waitForState(timeout: 8) { ($0.clipboardChangeCount ?? before) > before }
        let probe = app.descendants(matching: .any)["nib.qa.clipboard"].firstMatch
        var fragment: Data?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = probe.value as? String,
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Data(value.utf8)),
                  snapshot.changeCount > before, let data = snapshot.fragment else { return false }
            fragment = data
            return true
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 8) == .completed, let fragment else {
            throw Failure.message("Copy must export a fresh app.nib.fragment")
        }
        return fragment
    }

    func selectTool(_ id: String) throws {
        // Reselecting toggles its options strip (or settings for a tool without a strip).
        if try state().tool != id { try tapControl("tool." + id, overflow: ["tool.more"]) }
        _ = try waitForState { $0.tool == id }
    }

    /// Follow the visible UI: unfold a hidden strip, then use its settings chevron.
    /// Tools without a strip still open settings on reselection.
    func openToolSettings(_ id: String) throws {
        try selectTool(id)
        if try state().toolSettingsOpen == id { return }
        if let chevron = try? requireControl("menu.toolSettings", type: .button, timeout: 3) {
            chevron.tap()
        } else {
            try tapControl("tool." + id, overflow: ["tool.more"])
            if try state().toolSettingsOpen != id {
                try requireControl("menu.toolSettings", type: .button, timeout: 8).tap()
            }
        }
        _ = try waitForState { $0.toolSettingsOpen == id }
    }

    private func tapControl(_ id: String, overflow: [String], diagnostics: Bool = false) throws {
        func activate(_ control: XCUIElement) {
            if diagnostics { recordDiagnostics("Command tap resolved", facts: elementFacts(control, includeOverlaps: true)) }
            control.tap()
            if diagnostics { recordDiagnostics("Command tap returned", facts: "command=\(id)", includeHierarchy: false) }
        }
        func candidate(_ identifier: String) -> XCUIElement? {
            guard let control = findControl(identifier, type: .button), control.isEnabled else { return nil }
            return control
        }
        // XCTest taps the hittable activation point; do not scan every retained scroll host
        // for a control already available on screen (Add Page previously cost 40-50s per tap).
        if let control = candidate(id) { activate(control); return }
        let target = app.buttons.matching(identifier: id).firstMatch
        if target.exists {
            revealFormElement { self.app.buttons.matching(identifier: id).firstMatch }
            if let failure = formRevealFailure { throw Failure.message(failure) }
            if let control = candidate(id) { activate(control); return }
        }
        for identifier in overflow {
            guard let menu = candidate(identifier) else { continue }
            menu.tap()
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                app.buttons.matching(identifier: id).firstMatch.exists
            }, object: nil)
            if !app.buttons.matching(identifier: id).firstMatch.exists {
                _ = XCTWaiter.wait(for: [ready], timeout: 3)
            }
            revealFormElement { self.app.buttons.matching(identifier: id).firstMatch }
            if let failure = formRevealFailure { throw Failure.message(failure) }
            if let control = candidate(id) { activate(control); return }
            if menu.exists && menu.isHittable { menu.tap() }
        }
        throw Failure.message("No enabled control \(id)\n\(app.debugDescription)")
    }

    func coordinate(_ point: CGPoint) -> XCUICoordinate {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: point.x, dy: point.y))
    }

    /// Accessibility frames and app-coordinate offsets use interface space, unlike screenPoint in landscape.
    func interfacePoint(_ normalized: CGPoint) -> CGPoint {
        let frame = canvas.frame
        return CGPoint(x: frame.minX + normalized.x * frame.width, y: frame.minY + normalized.y * frame.height)
    }

    /// Captures interface geometry at the action boundary for comparison with accessibility frames.
    func recordGeometry(_ name: String, touches: [CGPoint], selection: CGRect? = nil) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(string: "All frames and touches are interface points.\n"
                + "app=\(app.frame) window=\(app.windows.firstMatch.frame) canvas=\(canvas.frame)\n"
                + "touches=\(touches) selection=\(String(describing: selection))\n\(probe.value ?? "missing")")
            attachment.name = name; attachment.lifetime = .keepAlways; activity.add(attachment)
        }
    }

    /// Records monotonic timestamps before and after one UI action, including any XCTest idle wait in that action.
    /// The first attachment is emitted before touching AX so an idle stall still leaves a precise last-started action.
    @discardableResult
    func timedAction<T>(_ name: String, action: () throws -> T) rethrows -> T {
        try XCTContext.runActivity(named: name) { activity in
            let started = ProcessInfo.processInfo.systemUptime
            let start = XCTAttachment(string: "start uptime=\(started) wall=\(Date())")
            start.name = "action-start"; start.lifetime = .keepAlways; activity.add(start)
            defer {
                let end = XCTAttachment(string: "end uptime=\(ProcessInfo.processInfo.systemUptime) elapsed=\(ProcessInfo.processInfo.systemUptime - started)")
                end.name = "action-end"; end.lifetime = .keepAlways; activity.add(end)
            }
            return try action()
        }
    }

    /// Captures screen/probe/facts; routine checkpoints can omit the expensive full AX tree.
    func recordDiagnostics(_ name: String, facts: String = "", includeHierarchy: Bool = true) {
        XCTContext.runActivity(named: name) { activity in
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = name + "-screen"; screen.lifetime = .keepAlways; activity.add(screen)
            let hierarchy = includeHierarchy ? "\n" + app.debugDescription : ""
            logQA(name, "uptime=\(ProcessInfo.processInfo.systemUptime) \(facts) probe=\(probe.value ?? "missing")\(hierarchy)")
            let tree = XCTAttachment(string: "uptime=\(ProcessInfo.processInfo.systemUptime)\n\(facts)\n"
                + "probe=\(probe.value ?? "missing")\(hierarchy)")
            tree.name = name + "-state-and-tree"; tree.lifetime = .keepAlways; activity.add(tree)
        }
    }

    func elementFacts(_ element: XCUIElement, includeOverlaps: Bool = false) -> String {
        guard element.exists else { return "exists=false popovers=\(app.popovers.count) menus=\(app.menus.count) window=\(app.windows.firstMatch.frame)" }
        guard let snapshot = try? element.snapshot() else { return "exists=true snapshot unavailable" }
        let frame = snapshot.frame
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        func covering(_ node: XCUIElementSnapshot) -> [String] {
            guard node.frame.contains(centre) else { return [] }
            let own = "\(node.elementType.rawValue):\(node.identifier):\(node.label):\(node.frame)"
            return [own] + node.children.flatMap { covering($0) }
        }
        // XCUITest has no public UIKit hitTest API. Report overlapping AX frames, not an invented hit result.
        let overlaps = includeOverlaps ? ((try? app.snapshot()).map { covering($0) } ?? []) : []
        return "exists=true id=\(snapshot.identifier) label=\(snapshot.label) frame=\(frame) enabled=\(snapshot.isEnabled) hittable=\(element.isHittable) value=\(String(describing: snapshot.value)) popovers=\(app.popovers.count) menus=\(app.menus.count) window=\(app.windows.firstMatch.frame) centreOverlaps=\(overlaps)"
    }

    /// Observe the same decisive action on success or failure; no retry, alternate tap or softened oracle.
    func diagnoseAction<T>(_ name: String, facts: () -> String, action: () throws -> T) rethrows -> T {
        recordDiagnostics(name + " before", facts: facts(), includeHierarchy: false)
        defer { recordDiagnostics(name + " after", facts: facts(), includeHierarchy: false) }
        return try action()
    }

    /// Two points use the public coordinate press-and-drag API. Longer polylines keep one finger down using
    /// XCTest's event synthesizer (test runner only); no commands or app-side gesture injection are used.
    func drawStroke(_ path: [CGPoint], duration: TimeInterval = 0.35) throws {
        guard path.count >= 2 else { throw Failure.message("A stroke needs at least two points") }
        if path.count == 2 {
            let start = coordinate(path[0]), end = coordinate(path[1])
            let a = interfacePoint(path[0]), b = interfacePoint(path[1])
            let distance = hypot(b.x - a.x, b.y - a.y)
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: distance / duration), thenHoldForDuration: 0)
        } else {
            try synthesize([path], duration: duration)
        }
    }

    /// Start on the canvas desk by default, clear of PencilKit and the floating controls.
    /// Pass a paper coordinate to exercise navigation through a particular tool's input surface.
    func pinchZoom(scale: CGFloat, velocity: CGFloat = 1, at centre: CGPoint = CGPoint(x: 0.18, y: 0.65)) throws {
        guard scale > 0, velocity != 0 else { throw Failure.message("Pinch needs a positive scale and nonzero velocity") }
        let radius: CGFloat = min(0.055, 0.055 / scale)
        let duration = min(2, max(0.25, Double(abs(scale - 1) / abs(velocity))))
        let paths = [CGFloat(-1), CGFloat(1)].map { direction in
            [CGPoint(x: centre.x + direction * radius, y: centre.y),
             CGPoint(x: centre.x + direction * radius * scale, y: centre.y)]
        }
        recordGeometry("Pinch focal point and contact paths", touches: [interfacePoint(centre)]
            + paths.flatMap { $0.map { interfacePoint($0) } })
        try synthesize(paths, duration: duration)
    }
    func doubleTap(at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) { coordinate(point).doubleTap() }

    /// Keeps every touch in a small desk patch, never XCTest's automatically chosen window-edge hit points.
    func canvasMultiTap(touches: Int, taps: Int = 2) throws {
        guard (2...3).contains(touches), (1...2).contains(taps) else { throw Failure.message("Unsupported multi-tap") }
        let before = app.windows.firstMatch.frame
        let centre = coordinate(CGPoint(x: 0.18, y: 0.65)).screenPoint
        let points = (0..<touches).map { index in
            CGPoint(x: centre.x + CGFloat(index - 1) * 20, y: centre.y)
        }
        let interfaceCentre = interfacePoint(CGPoint(x: 0.18, y: 0.65))
        // Contacts are at most 20pt from the centre in any device orientation.
        guard before.insetBy(dx: 80, dy: 80).contains(interfaceCentre) else {
            throw Failure.message("Multi-tap must stay clear of system window edges")
        }
        recordGeometry("Stationary multi-tap centre (contacts within 20pt)", touches: [interfaceCentre])
        let done = XCTestExpectation(description: "Stationary multi-tap completed")
        var failure: Error?
        NibTouchPaths.tap(at: points.map { NSValue(cgPoint: $0) }, count: UInt(taps)) { error in
            failure = error; done.fulfill()
        }
        guard XCTWaiter.wait(for: [done], timeout: 10) == .completed else { throw Failure.message("Multi-tap timed out") }
        if let failure { throw failure }
        let after = app.windows.firstMatch.frame
        guard abs(after.minX - before.minX) <= 2, abs(after.minY - before.minY) <= 2,
              abs(after.width - before.width) <= 2, abs(after.height - before.height) <= 2 else {
            throw Failure.message("Multi-tap moved the app window: \(before) -> \(after)")
        }
    }

    func twoFingerScroll(from: CGPoint, to: CGPoint, duration: TimeInterval = 0.4) throws {
        let spacing = min(0.035, 24 / canvas.frame.width)
        try synthesize([[CGPoint(x: from.x - spacing, y: from.y), CGPoint(x: to.x - spacing, y: to.y)],
                        [CGPoint(x: from.x + spacing, y: from.y), CGPoint(x: to.x + spacing, y: to.y)]], duration: duration)
    }

    /// Native context menus do not reliably let XCTest reach idle. Every menu contact is synthesized.
    /// A path includes submenu openers, e.g. ["Move", "Move Up"]. Never retry the opening press.
    func nativeContextMenu(_ element: XCUIElement, path: [String]) throws {
        guard !path.isEmpty else { throw Failure.message("Context menu needs an action path") }
        let started = Date()
        // Native menus may expose only buttons under Preview. Remember existing controls so
        // an app-wide fallback cannot mistake persistent Delete/Move chrome for a new item.
        var existingFrames: [String: [CGRect]] = [:]
        for name in path {
            var frames: [CGRect] = []
            for kind in [XCUIElement.ElementType.button, .menuItem] {
                let matches = app.descendants(matching: kind).matching(NSPredicate(
                    format: "label == %@ OR identifier == %@", name, name))
                for candidate in matches.allElementsBoundByIndex.prefix(16) {
                    if hasVisibleFrame(candidate), candidate.isHittable { frames.append(candidate.frame) }
                }
            }
            existingFrames[name] = frames
        }
        var previous: CGRect?
        var settled: CGRect?
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard hasVisibleFrame(element), element.isEnabled, element.isHittable else {
                previous = nil; return false
            }
            let frame = element.frame
            defer { previous = frame }
            guard previous == frame else { return false }
            settled = frame
            return true
        }, object: nil)
        guard XCTWaiter.wait(for: [stable], timeout: 8) == .completed, let frame = settled else {
            throw Failure.message("Context menu target did not settle: " + elementFacts(element))
        }
        logQA("Native menu opening", "path=\(path) frame=\(frame)")
        try pressWithoutIdle(at: CGPoint(x: frame.midX, y: frame.midY), duration: 0.8)
        var activated: [(item: XCUIElement, frame: CGRect)] = []
        for name in path {
            var found: XCUIElement?
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                let menus = Array(app.menus.allElementsBoundByIndex.prefix(8))
                let preview = app.otherElements["Preview"].firstMatch
                let scopes = menus + (preview.exists ? [preview] : []) + [app]
                for scope in scopes {
                    for kind in [XCUIElement.ElementType.button, .menuItem] {
                        let matches = scope.descendants(matching: kind).matching(NSPredicate(
                            format: "label == %@ OR identifier == %@", name, name))
                        for candidate in matches.allElementsBoundByIndex.prefix(16) {
                            guard hasVisibleFrame(candidate), candidate.isEnabled, candidate.isHittable else { continue }
                            if scope === app, existingFrames[name, default: []].contains(candidate.frame) { continue }
                            found = candidate; return true
                        }
                    }
                }
                return false
            }, object: nil)
            guard XCTWaiter.wait(for: [ready], timeout: 8) == .completed, let item = found else {
                let facts = "path=\(path) missing=\(name) target=" + elementFacts(element)
                let state = " probe=\(String(describing: probe.exists ? probe.value : nil))"
                let message = "Native context menu item absent: " + facts + state
                logQA("Native menu missing", message)
                recordDiagnostics("Native menu missing", includeHierarchy: true)
                throw Failure.message(message)
            }
            activated.append((item, item.frame))
            logQA("Native menu item", "path=\(path) item=" + elementFacts(item))
            try tapWithoutIdle(item)
        }
        var previouslyGone = false
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let menuVisible = app.menus.firstMatch.exists || app.otherElements["Preview"].firstMatch.exists
            let itemsGone = !menuVisible && activated.allSatisfy { action in
                if !action.item.exists { return true }
                // Lazy queries may now resolve to a same-named confirmation anywhere in the
                // app, including an iPad popover or a SwiftUI form with no Sheet AX ancestor.
                return action.item.frame != action.frame
            }
            defer { previouslyGone = itemsGone }
            return previouslyGone && itemsGone
        }, object: nil)
        guard XCTWaiter.wait(for: [gone], timeout: 8) == .completed else {
            recordDiagnostics("Native menu dismissal failed")
            throw Failure.message("Native menu must disappear before ordinary input: \(path)")
        }
        logQA("Native menu dismissed", "path=\(path) seconds=\(Date().timeIntervalSince(started))")
    }

    /// Caller must follow delivery with a bounded UI/state postcondition; completion only proves delivery.
    func pressWithoutIdle(_ element: XCUIElement, duration: TimeInterval) throws {
        guard element.exists, element.isEnabled, element.isHittable else {
            throw Failure.message("Non-idle press requires an enabled hittable element: " + elementFacts(element))
        }
        let frame = element.frame
        guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else {
            throw Failure.message("Non-idle press has invalid frame: \(frame)")
        }
        try pressWithoutIdle(at: CGPoint(x: frame.midX, y: frame.midY), duration: duration)
    }

    func tapWithoutIdle(_ element: XCUIElement) throws {
        try pressWithoutIdle(element, duration: 0.05)
    }

    /// Continuous coordinate path for a partial row swipe; caller verifies the revealed action.
    func dragWithoutIdle(from start: XCUICoordinate, to end: XCUICoordinate,
                         duration: TimeInterval) throws {
        try synthesize(screenPaths: [[start.screenPoint, end.screenPoint]], duration: duration)
    }

    private func pressWithoutIdle(at point: CGPoint, duration: TimeInterval) throws {
        let frame = app.frame
        let screen = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY)).screenPoint
        try synthesize(screenPaths: [[screen]], duration: duration)
    }

    private func synthesize(_ paths: [[CGPoint]], duration: TimeInterval) throws {
        try synthesize(screenPaths: paths.map { $0.map { coordinate($0).screenPoint } }, duration: duration)
    }

    private func synthesize(screenPaths: [[CGPoint]], duration: TimeInterval) throws {
        let points = screenPaths.map { $0.map { NSValue(cgPoint: $0) } }
        let done = XCTestExpectation(description: "Touch path completed")
        var failure: Error?
        logTouchPaths(points)
        NibTouchPaths.perform(points, duration: duration) { error in failure = error; done.fulfill() }
        guard XCTWaiter.wait(for: [done], timeout: duration + 15) == .completed else { throw Failure.message("Gesture synthesis timed out") }
        if let failure { throw failure }
    }

    func logTouchPaths(_ paths: [[NSValue]]) {
        for (index, path) in paths.enumerated() {
            logQA("Touch path orientation", "orientation=\(XCUIDevice.shared.orientation.rawValue) path=\(index) first=\(String(describing: path.first?.cgPointValue)) last=\(String(describing: path.last?.cgPointValue))")
        }
    }

    /// AX windows are not UIScenes (keyboard/overlay windows also appear). Log each probe's own
    /// keyWindowState, not an inferred key scene from window ordering or the global responder class.
    func logWindowScenes(_ step: String) {
        let windows = app.windows.allElementsBoundByIndex
        var probeWindows = 0
        for (index, window) in windows.enumerated() {
            let probes = window.otherElements.matching(identifier: "nib.qa.state").allElementsBoundByIndex
            if !probes.isEmpty { probeWindows += 1 }
            logQA("Window scene probe", "step=\(step) axWindow=\(index) " + elementFacts(window))
            for (probeIndex, stateProbe) in probes.enumerated() {
                let raw = stateProbe.value
                logQA("Window scene probe", "step=\(step) axWindow=\(index) probe=\(probeIndex) raw=\(String(describing: raw))")
            }
        }
        let evidence = probeWindows > 1 ? "multiple probe-bearing windows observed" : "not established by AX"
        logQA("Window scene count", "step=\(step) axWindows=\(windows.count) probeWindows=\(probeWindows) moreThanOneScene=\(evidence); scene IDs and keyboard-focus owner scene are not exposed")
    }

    /// Keep the caller's missing-control assertion. A miss gathers evidence before/after pointer hover.
    func systemWindowControls(in application: XCUIApplication? = nil) -> XCUIElement {
        let primary = application ?? app
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let predicate = NSPredicate(format: "label CONTAINS[c] 'multitasking' OR label == 'Window Controls' OR identifier CONTAINS[c] 'window-controls'")
        func candidate() -> XCUIElement? {
            for source in [primary, springboard] {
                let button = source.buttons.matching(predicate).firstMatch
                if button.exists, button.isHittable { return button }
            }
            return nil
        }
        var found: XCUIElement?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            found = candidate(); return found != nil
        }, object: nil)
        if XCTWaiter.wait(for: [ready], timeout: 5) == .completed, let found { return found }
        var sources: [(String, XCUIApplication)] = [("Nib", app), ("SpringBoard", springboard)]
        if application != nil { sources.append(("Foreground app", primary)) }
        func inventory(_ stage: String) {
            for (name, source) in sources {
                guard let snapshot = try? source.snapshot() else {
                    logQA("Window top controls", "stage=\(stage) source=\(name) snapshot unavailable"); continue
                }
                func visit(_ node: XCUIElementSnapshot, top: CGFloat) {
                    let windowTop = node.elementType == .window ? node.frame.minY : top
                    if node.elementType == .button, node.frame.maxY > windowTop, node.frame.minY < windowTop + 100 {
                        let identity = "id=\(node.identifier) label=\(node.label)"
                        logQA("Window top controls", "stage=\(stage) source=\(name) \(identity) frame=\(node.frame)")
                    }
                    for child in node.children { visit(child, top: windowTop) }
                }
                visit(snapshot, top: snapshot.frame.minY)
                logQA("Window control hierarchy " + name + " " + stage, source.debugDescription)
            }
            logWindowScenes(stage)
        }
        inventory("before hover")
        for (name, source) in sources where name != "SpringBoard" {
            let window = source.windows.firstMatch
            guard window.exists, window.isHittable, window.frame.width > 24, window.frame.height > 24 else {
                logQA("Window control hover", "source=\(name) no visible hittable window"); continue
            }
            let target = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 16, dy: 16))
            let hover = NSSelectorFromString("hover")
            if target.responds(to: hover) {
                _ = target.perform(hover)
                logQA("Window control hover", "source=\(name) top-leading +16pt")
            } else { logQA("Window control hover", "source=\(name) runtime hover selector unavailable") }
        }
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            found = candidate(); return found != nil
        }, object: nil)
        _ = XCTWaiter.wait(for: [appeared], timeout: 3)
        inventory("after hover")
        recordDiagnostics("Window controls after hover", includeHierarchy: false)
        if let found { return found }
        for source in [primary, springboard] {
            let button = source.buttons.matching(predicate).firstMatch
            if button.exists { return button }
        }
        return primary.buttons.matching(predicate).firstMatch
    }

    func diagnoseWindowControls() {
        let predicate = NSPredicate(format: "label CONTAINS[c] 'multitasking' OR label CONTAINS[c] 'Window Controls' OR identifier CONTAINS[c] 'window-controls' OR label CONTAINS[c] 'Split View'")
        for (name, source) in [("Nib", app), ("SpringBoard", XCUIApplication(bundleIdentifier: "com.apple.springboard"))] {
            let matches = source.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
            logQA("Window control inventory", "source=\(name) matches=\(matches.count)")
            for element in matches {
                guard let snapshot = try? element.snapshot() else { continue }
                logQA("Window control inventory", "source=\(name) type=\(snapshot.elementType.rawValue) id=\(snapshot.identifier) label=\(snapshot.label) frame=\(snapshot.frame) value=\(String(describing: snapshot.value))")
            }
            logQA("Window control hierarchy " + name, source.debugDescription)
        }
        recordDiagnostics("Window controls before lookup", includeHierarchy: false)
    }

    func cancelConfirmation(action: String) throws {
        let surface = app.sheets.allElementsBoundByIndex.first {
            hasVisibleFrame($0) && $0.buttons[action].exists
        } ?? app.popovers.allElementsBoundByIndex.first {
            hasVisibleFrame($0) && $0.buttons[action].exists
        }
        guard let surface else { throw Failure.message("Missing confirmation for \(action)") }
        let heading = surface.label
        guard !heading.isEmpty else { throw Failure.message("Confirmation must expose its heading") }
        if let cancel = findControl("Cancel", type: .button, in: surface), cancel.isEnabled && cancel.isHittable {
            cancel.tap()
        } else {
            let region = app.otherElements["PopoverDismissRegion"].firstMatch
            let window = app.windows.firstMatch.frame
            let surfaces = app.popovers.allElementsBoundByIndex.map(\.frame) + [surface.frame]
            let points = [CGPoint(x: window.minX + 24, y: window.maxY - 24),
                          CGPoint(x: window.maxX - 24, y: window.minY + 24)]
            guard region.exists, let point = points.first(where: { point in
                region.frame.contains(point) && !surfaces.contains { $0.contains(point) }
            }) else { throw Failure.message("Confirmation has no safe outside dismissal point") }
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        }
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", heading)).firstMatch
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !title.exists }, object: nil)
        guard XCTWaiter.wait(for: [gone], timeout: 8) == .completed else {
            throw Failure.message("Cancelled confirmation heading remains: \(heading)")
        }
    }

    func dismissSheets() throws {
        // Modal form sheets are plain containers in the accessibility tree (only confirmation dialogs are
        // typed Sheet, run 41961796255), so the close control is looked up app-wide as before. A panel's own
        // close button counts only until something else was dismissed: after Audio's share sheet closes,
        // the loop must not go on to close the Audio panel behind it (D:controls-forms#9).
        var dismissedSurface = false
        for _ in 0..<8 {
            var close: XCUIElement?
            for id in ["sheet.dismiss", "cmd.panel.close", "Cancel", "Done", "Close", "Close export options"] {
                if dismissedSurface, id == "cmd.panel.close" { continue }
                if let found = findControl(id, type: .button), found.isEnabled { close = found; break }
            }
            if let close {
                if close.identifier != "cmd.panel.close" { dismissedSurface = true }
                close.tap()
                continue
            }
            if let sheet = app.sheets.allElementsBoundByIndex.first(where: { hasVisibleFrame($0) && $0.isHittable }) {
                sheet.swipeDown(); continue
            }
            return
        }
        throw Failure.message("Sheet did not dismiss\n\(app.debugDescription)")
    }

    enum Failure: Error { case message(String) }
}

/// Drives Calendar's real event editor. EventKit injection would bypass the UI-only
/// fixture contract; an unlabeled toolbar symbol must not prevent ordinary input.
@MainActor
extension NibUI {
    static func openCalendarEvent(in calendar: XCUIApplication, log: ((String, String) -> Void)? = nil) throws {
        let title = calendar.textFields["Title"]
        // iPadOS 26 exposes the toolbar action as add-plus-button / lowercase "add".
        // Prefer its stable identifier; localized display casing is not a command contract.
        func addButton() -> XCUIElement? {
            let identified = calendar.buttons.matching(identifier: "add-plus-button").allElementsBoundByIndex
            let labelled = calendar.buttons.matching(NSPredicate(
                format: "label ==[c] 'Add' OR label IN {'Add Event', 'New Event', 'Create Event', 'Create'}"))
                .allElementsBoundByIndex
            return (identified + labelled).first { $0.isEnabled && $0.isHittable }
        }
        func editorIsReady() -> Bool { title.exists && title.isEnabled && title.isHittable }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let alerts = springboard.alerts
            let count = alerts.count
            let add = calendar.buttons["add-plus-button"].firstMatch
            let facts = add.exists ? "enabled=\(add.isEnabled) hittable=\(add.isHittable) frame=\(add.frame)" : "absent"
            log?("Calendar readiness", "springboardAlerts=\(count) Add=\(facts)")
            if count > 0 {
                let alert = alerts.firstMatch
                let allow = alert.buttons.matching(NSPredicate(
                    format: "label IN {'Allow While Using App', 'Allow', 'OK'} OR label CONTAINS 'Allow Full Access'")).firstMatch
                if allow.exists && allow.isHittable { allow.tap() }
                return false // Re-observe after dismissal before resolving Add.
            }
            return editorIsReady() || addButton() != nil
        }, object: nil)
        let readiness = XCTWaiter.wait(for: [ready], timeout: 15)
        if readiness != .completed {
            log?("Calendar readiness failed", springboard.debugDescription + "\n" + calendar.debugDescription)
            if springboard.alerts.firstMatch.exists {
                throw NibUI.Failure.message("Calendar permission alert did not dismiss")
            }
            // Preserve the native Command-N fallback when Calendar omits a usable Add control.
        }
        if editorIsReady() { return }
        addButton()?.tap()
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editorIsReady() }, object: nil)
        if XCTWaiter.wait(for: [opened], timeout: 10) == .completed { return }

        // Calendar's New Event keyboard command also reaches the native editor when
        // iPadOS omits the visible + symbol's accessibility label. Unlike a screen
        // coordinate this remains valid across orientation and toolbar layouts.
        log?("Calendar Command-N", "Add did not open editor; delivering native key to Calendar")
        calendar.typeKey("n", modifierFlags: [.command])
        let shortcutOpened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editorIsReady() }, object: nil)
        guard XCTWaiter.wait(for: [shortcutOpened], timeout: 10) == .completed else {
            throw NibUI.Failure.message("Calendar did not open its New Event editor through Add or Command-N\n"
                                        + calendar.debugDescription)
        }
    }
}
