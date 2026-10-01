import Foundation
import SwiftUI
import NibContracts
import NibDesign

/// Stable, bounded class order. The UI uses doc.open / lesson.setState for navigation and teaching modes.
struct ClassNavigator {
    var copies: [InsightCopy]
    var current: String?
    var index: Int? { copies.firstIndex { $0.id == current } }
    var previous: InsightCopy? {
        guard let index, index > 0 else { return nil }
        return copies[index - 1]
    }
    var next: InsightCopy? {
        guard let index else { return copies.first }
        return copies.indices.contains(index + 1) ? copies[index + 1] : nil
    }
    var position: String {
        guard let index else { return String(localized: "Choose a student") }
        return String(localized: "\(index + 1) of \(copies.count)")
    }
}

@MainActor
struct ClassNavigatorView: View {
    let navigator: ClassNavigator
    let busy: Bool
    let open: (InsightCopy) -> Void
    let mode: (String) -> Void
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            Text(String(localized: "Class Navigator")).font(NibFont.headline)
            Text(navigator.position).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
            Picker(String(localized: "Student copy"), selection: Binding(get: { navigator.current ?? "" }, set: { ref in
                if let copy = navigator.copies.first(where: { $0.id == ref }) { open(copy) }
            })) {
                Text(String(localized: "Choose a student")).tag("")
                ForEach(navigator.copies) { Text($0.student).tag($0.id) }
            }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                .labelsHidden().accessibilityLabel(String(localized: "Student copy"))
            if widthClass == .compact || typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NibSpacing.s) { steps; modes }
            } else { HStack(spacing: NibSpacing.s) { steps; Spacer(); modes } }
        }.disabled(busy || navigator.copies.isEmpty)
    }

    @ViewBuilder
    private var steps: some View {
        if widthClass == .compact || typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NibSpacing.s) { stepButtons }
        } else { HStack(spacing: NibSpacing.s) { stepButtons } }
    }
    private var stepButtons: some View {
        Group {
            NibButton(String(localized: "Previous Student"), symbol: .back, kind: .plain) {
                if let copy = navigator.previous { open(copy) }
            }.disabled(navigator.previous == nil).keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            NibButton(String(localized: "Next Student"), symbol: .forward, kind: .plain) {
                if let copy = navigator.next { open(copy) }
            }.disabled(navigator.next == nil).keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }
    }
    private var modes: some View {
        Group {
            NibButton(String(localized: "Present Copy"), symbol: .present, kind: .plain) { mode("present") }
                .disabled(navigator.current == nil)
            NibButton(String(localized: "Write Feedback"), symbol: .pen, kind: .plain) { mode("feedback") }
                .disabled(navigator.current == nil)
        }
    }
}

/// A small per-window cache of read results lets the class navigator stay on the canvas during teaching.
@MainActor
final class InsightRuntime {
    static let key = "teacherinsights.runtime"
    private final class Window {
        weak var session: EditorSession?
        var source: String
        var copies: [InsightCopy]
        var page: PageID?
        var privateCopies: [String: String] = [:]
        init(collection: InsightCollection, session: EditorSession) {
            self.session = session; source = collection.source; copies = collection.copies
            page = collection.page.flatMap { NodeRef($0)?.pageID }
        }
    }
    private var windows: [String: Window] = [:]
    func update(_ collection: InsightCollection, session: EditorSession) {
        windows = windows.filter { $0.value.session != nil }
        let key = session.id.raw
        if let window = windows[key], window.source == collection.source {
            window.copies = collection.copies
            window.page = collection.page.flatMap { NodeRef($0)?.pageID }
        } else { windows[key] = Window(collection: collection, session: session) }
    }
    func navigator(_ session: EditorSession) -> ClassNavigator? {
        guard let window = windows[session.id.raw], let document = session.document else { return nil }
        let ref = NodeRef.document(document).description
        let copy = window.privateCopies[ref] ?? ref
        guard window.copies.contains(where: { $0.id == copy }) else { return nil }
        return ClassNavigator(copies: window.copies, current: copy)
    }
    func page(_ session: EditorSession) -> PageID? { windows[session.id.raw]?.page }
    func rememberPrivate(_ ref: String, copy: String, session: EditorSession) {
        windows[session.id.raw]?.privateCopies[ref] = copy
    }
}

@MainActor
struct ClassNavigatorBar: View {
    let context: ChromeContext
    @State private var busy = false

    private var runtime: InsightRuntime? { context.app.services.get(InsightRuntime.key, as: InsightRuntime.self) }
    private var navigator: ClassNavigator? { runtime?.navigator(context.session) }

    var body: some View {
        if let navigator {
            HStack(spacing: NibSpacing.s) {
                NibToolbarItem(.back, label: String(localized: "Previous Student"), shortcut: KeyboardShortcut(.leftArrow, modifiers: [.command, .option])) {
                    if let copy = navigator.previous { open(copy) }
                }.disabled(busy || navigator.previous == nil)
                NibHUDText(navigator.copies.first { $0.id == navigator.current }?.student ?? "", secondary: navigator.position)
                NibToolbarItem(.forward, label: String(localized: "Next Student"), shortcut: KeyboardShortcut(.rightArrow, modifiers: [.command, .option])) {
                    if let copy = navigator.next { open(copy) }
                }.disabled(busy || navigator.next == nil)
                if !context.isCompact {
                    NibToolbarItem(.present, label: String(localized: "Present Student Copy")) { mode("present", navigator: navigator) }.disabled(busy)
                    NibToolbarItem(.pen, label: String(localized: "Write Student Feedback")) { mode("feedback", navigator: navigator) }.disabled(busy)
                }
                NibToolbarItem(.pages, label: String(localized: "Review Class Answers")) {
                    perform(CommandIDs.panelOpen, ["id": .string(FeatTeacherInsightsFeature.panelID), "doc": .string(navigator.current ?? "")])
                }.disabled(busy)
            }
        }
    }

    private func open(_ copy: InsightCopy) {
        var params: [String: JSONValue] = ["doc": .string(copy.id)]
        if let page = context.session.page ?? runtime?.page(context.session) {
            params["page"] = .string(NodeRef.page(NodeRef.documentID(from: copy.id), page).description)
        }
        perform(CommandIDs.docOpen, .object(params))
    }
    private func mode(_ mode: String, navigator: ClassNavigator) {
        guard let copy = navigator.current else { return }
        perform(CommandIDs.lessonSetState, ["doc": .string(copy), "state": .string(mode)]) { value in
            if mode == "present", let ref = value["ref"]?.stringValue {
                runtime?.rememberPrivate(ref, copy: copy, session: context.session)
                context.app.ui.setNeedsChromeUpdate(context.session)
            }
        }
    }
    private func perform(_ command: String, _ params: JSONValue, completion: @escaping (JSONValue) -> Void = { _ in }) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            do {
                let value = try await context.app.bus.execute(command, params, session: context.session)
                busy = false; completion(value)
                context.app.ui.setNeedsChromeUpdate(context.session)
            } catch {
                busy = false
                context.floatingHost?.postToast(NibError.wrap(error).message)
            }
        }
    }
}
