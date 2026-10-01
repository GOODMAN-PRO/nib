import UIKit
import SwiftUI
import NibContracts
import NibDesign

/// A quiet static underline and equals marker. No blur, shader or glass touches handwriting or wet ink.
@MainActor
final class MathAssistOverlay: CanvasAttachment {
    private let runtime: MathAssistWatcher
    private weak var host: CanvasHost?
    private let layer = CAShapeLayer()
    private var subscriptions: [EventSubscription] = []
    private var accessibility: [UIAccessibilityElement] = []
    private var anchorIDs = Set<String>()

    init(runtime: MathAssistWatcher) { self.runtime = runtime }

    func attach(to host: CanvasHost) {
        self.host = host
        layer.fillColor = nil
        layer.lineWidth = NibStroke.ring
        layer.strokeColor = NibUIColor.accent.cgColor
        host.canvasView.layer.addSublayer(layer)
        if let subscription = runtime.observe({ [weak self] in
            guard let self, let host = self.host else { return }; self.canvasDidChange(host)
        }) { subscriptions.append(subscription) }
        subscriptions.append(host.session.inking.observe { [weak self] signal in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self?.layer.isHidden = signal.isInking
            if !signal.isInking, let self, let host = self.host, let page = host.session.page {
                self.runtime.schedule(NodeRef.page(host.documentID, page).description)
            }
            CATransaction.commit()
        })
        canvasDidChange(host)
    }

    func detach(from host: CanvasHost) {
        subscriptions.forEach { $0.cancel() }; subscriptions = []
        layer.removeFromSuperlayer()
        removeAccessibility(host)
        self.host = nil
    }

    private func removeAccessibility(_ host: CanvasHost) {
        for id in anchorIDs { host.session.floatingHost?.removeAnchor(id) }
        anchorIDs.removeAll()
        let old = Set(accessibility.map(ObjectIdentifier.init))
        host.canvasView.accessibilityElements = (host.canvasView.accessibilityElements ?? []).filter {
            guard let element = $0 as? UIAccessibilityElement else { return true }
            return !old.contains(ObjectIdentifier(element))
        }
        accessibility = []
    }

    func canvasDidChange(_ host: CanvasHost) {
        removeAccessibility(host)
        let path = UIBezierPath()
        guard !host.session.readOnly, !host.app.isReadOnly(host.documentID),
              host.app.services.lock?.isLocked(host.documentID) != true,
              host.app.settings.get(NibSettings.mathAssistSuggestions),
              (try? host.app.workspace.content(host.documentID).meta.mathAssist) == true else {
            layer.path = nil; return
        }
        for (page, lines) in runtime.pages where NodeRef(page)?.documentID == host.documentID {
            guard let pageID = NodeRef(page)?.pageID, host.pageFrame(pageID) != nil else { continue }
            for (index, line) in lines.enumerated() where line.isQuestion && !host.session.hiddenLayers.contains(line.ink.first?.layer ?? 0) {
                let bounds = line.bounds
                let a = host.viewPoint(Point(bounds.maxX - max(8, bounds.height * 0.5), bounds.maxY + Double(NibSpacing.xs)), page: pageID)
                let b = host.viewPoint(Point(bounds.maxX, bounds.maxY + Double(NibSpacing.xs)), page: pageID)
                path.move(to: a); path.addLine(to: b)
                let rect = CGRect(x: min(a.x, b.x) - NibMetrics.hitTarget / 2,
                    y: a.y - NibMetrics.hitTarget / 2, width: max(NibMetrics.hitTarget, abs(a.x - b.x)), height: NibMetrics.hitTarget)
                let anchor = "mathassist.anchor.\(page).\(index)"
                anchorIDs.insert(anchor)
                host.session.floatingHost?.setAnchor(anchor, rect: rect, in: host.canvasView)
                let element = AssistAccessibilityElement(accessibilityContainer: host.canvasView)
                element.accessibilityLabel = String(localized: "Math Assist") + ": " + line.latex
                element.accessibilityValue = line.answer?.answer ?? line.failure
                element.accessibilityHint = String(localized: "Show answer formats and edit LaTeX")
                element.accessibilityTraits = .button
                element.accessibilityFrameInContainerSpace = rect
                element.activate = { [weak host] in
                    host?.app.perform(CommandIDs.mathassistTapAt,
                        ["page": .string(page), "point": .array([.number(bounds.maxX), .number(bounds.midY)])], session: host?.session)
                }
                accessibility.append(element)
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.path = path.cgPath
        layer.isHidden = host.session.inking.isInking
        layer.strokeColor = NibUIColor.accent.cgColor
        CATransaction.commit()
        host.canvasView.accessibilityElements = (host.canvasView.accessibilityElements ?? []) + accessibility
    }
}

@MainActor
private final class AssistAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
}

@MainActor
struct MathAssistOptions: View {
    let app: NibApp
    let session: EditorSession?
    let page: String
    let index: Int
    let line: AssistLine
    let floating: FloatingHosting
    @State private var presented = true
    @State private var latex: String
    @State private var format = "auto"
    @State private var preview: MathAnswer?
    @State private var error: String?
    @State private var evaluating = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(app: NibApp, session: EditorSession?, page: String, index: Int, line: AssistLine, floating: FloatingHosting) {
        self.app = app; self.session = session; self.page = page; self.index = index; self.line = line; self.floating = floating
        _latex = State(initialValue: line.latex)
        _preview = State(initialValue: line.answer)
    }

    var body: some View {
        NibBudPopover(id: "mathassist.options", source: "mathassist.anchor.\(page).\(index)", isPresented: $presented,
            title: String(localized: "Math Assist"), width: sizeClass == .compact ? NibMetrics.popoverWidth : NibMetrics.panelWidth(typeSize)) {
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.m) {
                    if let preview {
                        Text(verbatim: preview.answer).font(NibFont.title3).foregroundStyle(NibColor.label)
                            .accessibilityLabel(String(localized: "Answer") + ": " + preview.answer)
                        if !preview.exact { Text(String(localized: "Approximate answer")).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary) }
                    }
                    if let warning = line.warning { Text(verbatim: warning).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary) }
                    NibInspectorSection(String(localized: "Answer format")) {
                        Picker(String(localized: "Answer format"), selection: $format) {
                            Text(String(localized: "Automatic")).tag("auto")
                            Text(String(localized: "Fraction")).tag("fraction")
                            Text(String(localized: "Mixed number")).tag("mixed")
                            Text(String(localized: "Decimal")).tag("decimal")
                        }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
                    }
                    NibInspectorSection(String(localized: "Edit LaTeX")) {
                        NibField(text: $latex, prompt: String(localized: "Equation ending in ="), lines: 1...6)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityLabel(String(localized: "Correct recognised LaTeX"))
                    }
                    if evaluating { ProgressView().accessibilityLabel(String(localized: "Calculating answer")) }
                    if let error { Text(verbatim: error).font(NibFont.footnote).foregroundStyle(NibColor.destructive) }
                    NibButton(String(localized: "Write answer"), kind: .primary, shortcut: KeyboardShortcut(.return, modifiers: .command)) {
                        app.perform(CommandIDs.mathAssist, ["page": .string(page), "line": .number(Double(index)),
                            "format": .string(format), "latex": .string(latex), "refs": .array(line.refs.map(JSONValue.string))], session: session)
                    }.disabled(evaluating || preview == nil || !latex.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("="))
                    NibInspectorSection(String(localized: "Strategies")) {
                        NibButton(String(localized: "Calculate on device"), kind: .plain) { Task { await evaluatePreview() } }
                        NibButton(String(localized: "Show steps"), kind: .plain) { solve("solve") }
                            .disabled(app.commands.entry(CommandIDs.mathSolve) == nil)
                        NibButton(String(localized: "Help me work it out"), kind: .plain) { solve("teach") }
                            .disabled(app.commands.entry(CommandIDs.mathSolve) == nil)
                        if app.commands.entry(CommandIDs.mathSolve) == nil {
                            Text(String(localized: "Enable AI Solve for steps and hints.")).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                        }
                    }
                    NibButton(String(localized: "Close"), kind: .plain, shortcut: KeyboardShortcut(.escape, modifiers: [])) {
                        dismiss()
                    }
                }.padding(NibSpacing.xs)
            }.frame(maxHeight: NibMetrics.popoverMaxHeight)
        }
        .task(id: latex + "\u{0}" + format) { await evaluatePreview() }
        .onChange(of: presented) { _, showing in if !showing { dismiss() } }
    }

    private func dismiss() {
        app.perform(CommandIDs.mathassistTapAt, ["page": .string(page), "point": [0, 0], "action": "dismiss"], session: session)
    }

    private func solve(_ mode: String) {
        app.perform(CommandIDs.mathSolve, ["latex": .array([.string(latex)]), "mode": .string(mode)], session: session)
    }

    private func evaluatePreview() async {
        evaluating = true; error = nil
        defer { evaluating = false }
        do {
            try await Task.sleep(nanoseconds: 200_000_000)
            let context = line.context
            let result = try await app.bus.execute(CommandIDs.mathEvaluate,
                ["expression": .string((context + [latex]).joined(separator: "\n")), "format": .string(format)], session: session)
            try Task.checkCancellation()
            preview = try result.decode(MathAnswer.self)
        } catch is CancellationError { }
        catch { preview = nil; self.error = NibError.wrap(error).message }
    }
}
