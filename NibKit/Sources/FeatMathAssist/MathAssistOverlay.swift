import UIKit
import SwiftUI
import NibContracts
import NibDesign

/// Page-space geometry shared by rendering, VoiceOver, floating anchors and both input kinds.
@MainActor
enum AssistGeometry {
    static func glowRect(_ line: AssistLine, zoom: Double) -> Rect {
        let target = Double(NibMetrics.hitTarget) / max(zoom, 0.1)
        let bounds = line.bounds
        let width = max(target, max(8, bounds.height * 0.5))
        return Rect(x: bounds.maxX - width / 2,
                    y: bounds.maxY + Double(NibSpacing.xs) - target / 2,
                    width: width, height: target)
    }

    static func anchorID(_ page: String, line: AssistLine) -> String { "mathassist.anchor.\(page).\(line.key)" }
}

/// A transparent sibling of page tiles, preserving UIKit's discovery of the canvas's existing content.
@MainActor
private final class AssistOverlayView: UIView {
    var traitsChanged: (() -> Void)?
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { traitsChanged?() }
    }
}

@MainActor
final class MathAssistOverlay: CanvasAttachment {
    private let runtime: MathAssistWatcher
    private weak var host: CanvasHost?
    private let layer = CAShapeLayer()
    private let view = AssistOverlayView()
    private var subscriptions: [EventSubscription] = []
    private var accessibility: [UIAccessibilityElement] = []
    private var anchorIDs = Set<String>()

    init(runtime: MathAssistWatcher) { self.runtime = runtime }

    func attach(to host: CanvasHost) {
        self.host = host
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        host.canvasView.addSubview(view)
        view.traitsChanged = { [weak self] in
            guard let self, let host = self.host else { return }
            self.canvasDidChange(host)
        }
        layer.fillColor = nil
        layer.lineWidth = NibStroke.ring
        host.canvasView.layer.addSublayer(layer)
        if let subscription = runtime.observe({ [weak self] in
            guard let self, let host = self.host else { return }; self.canvasDidChange(host)
        }) { subscriptions.append(subscription) }
        subscriptions.append(host.session.inking.observe { [weak self] signal in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self?.layer.isHidden = signal.isInking
            self?.view.isHidden = signal.isInking
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
        view.traitsChanged = nil
        view.removeFromSuperview()
        self.host = nil
    }

    private func removeAccessibility(_ host: CanvasHost) {
        for id in anchorIDs { host.session.floatingHost?.removeAnchor(id) }
        anchorIDs.removeAll()
        view.accessibilityElements = []
        accessibility = []
        view.subviews.forEach { $0.removeFromSuperview() }
    }

    private func enabled(_ host: CanvasHost) -> Bool {
        !host.session.readOnly && !host.app.isReadOnly(host.documentID) &&
            host.app.services.lock?.isLocked(host.documentID) != true &&
            host.app.settings.get(NibSettings.mathAssistSuggestions) &&
            (try? host.app.workspace.content(host.documentID).meta.mathAssist) == true
    }

    func hitTest(_ viewPoint: CGPoint, isPencil: Bool, host: CanvasHost) -> Bool {
        guard isPencil, enabled(host), let location = host.pagePoint(viewPoint) else { return false }
        let page = NodeRef.page(host.documentID, location.page).description
        return runtime.pages[page]?.contains {
            $0.isQuestion && !host.session.hiddenLayers.contains($0.ink.first?.layer ?? 0) &&
                AssistGeometry.glowRect($0, zoom: host.session.zoom).contains(location.point)
        } == true
    }

    func gesture(_ gesture: CanvasGesture, at sample: CanvasSample, host: CanvasHost) -> Bool {
        guard gesture == .tap, sample.isPencil,
              hitTest(host.viewPoint(sample.location, page: sample.page), isPencil: true, host: host) else { return false }
        host.app.perform(CommandIDs.mathassistTapAt,
            ["page": .string(NodeRef.page(host.documentID, sample.page).description),
             "point": [.number(sample.location.x), .number(sample.location.y)], "gesture": "tap"], session: host.session)
        return true
    }

    func canvasDidChange(_ host: CanvasHost) {
        removeAccessibility(host)
        view.frame = CGRect(origin: .zero, size: host.canvasView.bounds.size)
        let path = UIBezierPath()
        guard enabled(host) else { layer.path = nil; return }
        for (page, lines) in runtime.pages where NodeRef(page)?.documentID == host.documentID {
            guard let pageID = NodeRef(page)?.pageID, host.pageFrame(pageID) != nil,
                  let transform = host.pageTransform(pageID) else { continue }
            for line in lines where line.isQuestion && !host.session.hiddenLayers.contains(line.ink.first?.layer ?? 0) {
                let glow = AssistGeometry.glowRect(line, zoom: host.session.zoom)
                let a = host.viewPoint(Point(glow.minX, glow.midY), page: pageID)
                let b = host.viewPoint(Point(glow.maxX, glow.midY), page: pageID)
                path.move(to: a); path.addLine(to: b)
                let rect = CGRect(x: glow.x, y: glow.y, width: glow.width, height: glow.height).applying(transform)
                let anchor = AssistGeometry.anchorID(page, line: line)
                anchorIDs.insert(anchor)
                host.session.floatingHost?.setAnchor(anchor, rect: rect, in: host.canvasView)
                let element = AssistAccessibilityElement(accessibilityContainer: view)
                element.accessibilityLabel = String(localized: "Math Assist") + ": " + line.latex
                element.accessibilityValue = line.answer?.answer ?? line.failure
                element.accessibilityHint = String(localized: "Show answer formats and edit LaTeX")
                element.accessibilityTraits = .button
                element.accessibilityFrameInContainerSpace = rect
                element.activate = { [weak host] in
                    host?.app.perform(CommandIDs.mathassistTapAt,
                        ["page": .string(page), "point": [.number(glow.midX), .number(glow.midY)]], session: host?.session)
                }
                accessibility.append(element)
                if let answer = line.answer?.answer, !answer.isEmpty {
                    let label = UILabel()
                    label.text = answer
                    label.font = NibUIFont.body
                    label.textColor = NibUIColor.accent.resolvedColor(with: host.canvasView.traitCollection)
                    label.alpha = NibOpacity.ghostInk
                    label.isAccessibilityElement = false
                    label.sizeToFit()
                    // Scale the preview to the source handwriting at the same position ink.writeText uses.
                    let scale = min(80, max(12, line.bounds.height)) / max(label.bounds.height, 1)
                    let width = label.bounds.width * scale, height = label.bounds.height * scale
                    let at = Point(line.bounds.maxX + Double(NibSpacing.s), line.bounds.minY)
                    label.center = host.viewPoint(Point(at.x + width / 2, at.y + height / 2), page: pageID)
                    label.transform = CGAffineTransform(a: transform.a * scale, b: transform.b * scale,
                        c: transform.c * scale, d: transform.d * scale, tx: 0, ty: 0)
                    view.addSubview(label)
                }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.path = path.cgPath
        layer.isHidden = host.session.inking.isInking
        view.isHidden = host.session.inking.isInking
        layer.strokeColor = NibUIColor.accent.resolvedColor(with: host.canvasView.traitCollection).cgColor
        CATransaction.commit()
        view.accessibilityElements = accessibility
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
        NibBudPopover(id: "mathassist.options", source: AssistGeometry.anchorID(page, line: line), isPresented: $presented,
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
                    }
                    .accessibilityIdentifier("cmd." + CommandIDs.mathAssist).disabled(evaluating || preview == nil || !latex.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("="))
                    NibInspectorSection(String(localized: "Strategies")) {
                        NibButton(String(localized: "Calculate on device"), kind: .plain) { Task { await evaluatePreview() } }
                        NibButton(String(localized: "Show steps"), kind: .plain) { solve("solve") }
                            .disabled(app.ui.panels.get("aimath.panel") == nil)
                        NibButton(String(localized: "Help me work it out"), kind: .plain) { solve("teach") }
                            .disabled(app.ui.panels.get("aimath.panel") == nil)
                        if app.ui.panels.get("aimath.panel") == nil {
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
        app.perform(CommandIDs.panelOpen, ["id": "aimath.panel", "latex": .string(latex),
            "refs": .array(line.refs.map(JSONValue.string)), "mode": .string(mode)], session: session)
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
