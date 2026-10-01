import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

public enum FeatMathGraphFeature: NibFeature {
    public static let id = "mathgraph"

    public static func register(_ app: NibApp) {
        app.commands.register(GraphCreate.self)
        app.commands.register(GraphSetViewport.self)
        app.content.customItemTypes.register(CustomItemTypeDescriptor(
            owner: GraphBuilder.owner, type: GraphBuilder.type, title: String(localized: "Maths Graph"),
            textPath: "expressions", editCommand: CommandIDs.mathGraphSetViewport))
        app.content.drawers.register(ItemDrawerEntry(key: GraphBuilder.drawKey, owner: id, drawer: GraphDrawer()))
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: "mathgraph.doubleTap", owner: id, gesture: .doubleTap, command: CommandIDs.mathGraphSetViewport,
            drawKeys: [GraphBuilder.drawKey]))
        var panel = PanelDescriptor(id: GraphCommands.panelID, title: String(localized: "Maths Graph"),
                                    icon: NibSymbol.graph.name, placement: .sheet, order: 0, owner: id,
                                    docKinds: [.notebook, .whiteboard]) { AnyView(GraphEditor(context: $0)) }
        panel.providesHeader = true
        app.ui.panels.register(panel)
        app.ui.menus.register(MenuItemDescriptor(
            id: "mathgraph.insert", title: String(localized: "Insert Graph"), icon: NibSymbol.graph.name,
            location: .pageLongPress, order: 107, owner: id, command: CommandIDs.mathGraphCreate,
            params: { context in
                guard let doc = context.doc, let page = context.page else { return [:] }
                var params: JSONValue = ["page": .string(NodeRef.page(doc, page).description)]
                if let point = context.point {
                    params = params.merging(["rect": .array([point.x, point.y, 400, 280].map(JSONValue.number))])
                }
                return params
            }, isVisible: { $0.page != nil && $0.session?.readOnly != true }))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "mathgraph.insert", title: String(localized: "Insert Graph"), icon: NibSymbol.graph.name,
            group: .accessories, order: 107, owner: id, command: CommandIDs.mathGraphCreate))
        var key = KeyCommandDescriptor(id: "mathgraph.insert", title: String(localized: "Insert Graph"),
                                       shortcut: KeyShortcut("g", [.command, .shift]),
                                       command: CommandIDs.mathGraphCreate, scope: .document, owner: id)
        key.docKinds = [.notebook, .whiteboard]
        app.content.keyCommands.register(key)
    }
}

/// The display remains portable when the feature is disabled. This drawer additionally clips defensive imported
/// data and applies rotation, exactly as the shared DisplayList's frame-relative coordinate convention requires.
final class GraphDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {
        guard let custom = item.custom else { return }
        let f = custom.frame
        let cg = context.cg
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: f.center.x, y: f.center.y)
        cg.rotate(by: f.rotation)
        cg.translateBy(x: -f.w / 2, y: -f.h / 2)
        cg.clip(to: CGRect(x: 0, y: 0, width: f.w, height: f.h))
        custom.display.draw(in: cg)
    }
    func paintBounds(_ item: Item) -> Rect? { item.custom?.frame.bounds }
}

@MainActor
struct GraphEditor: View {
    let context: PanelContext
    @State private var expressions = ""
    @State private var centreX = "0"
    @State private var centreY = "0"
    @State private var scale = "32"
    @State private var frame = Frame(x: 0, y: 0, w: 400, h: 280)
    @State private var revision: String?
    @State private var display = DisplayList()
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false
    @State private var previewCancellation: MathCancellation?
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    private var ref: String? { context.params["ref"]?.stringValue }
    private var lines: [String] {
        expressions.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var viewport: GraphViewport? {
        guard let x = Double(centreX), let y = Double(centreY), let s = Double(scale) else { return nil }
        return GraphViewport(x: x, y: y, scale: s)
    }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(ref == nil ? String(localized: "Insert Graph") : String(localized: "Edit Graph"),
                           primaryTitle: ref == nil ? String(localized: "Insert Graph") : String(localized: "Save Graph"),
                           isPrimaryEnabled: !loading && !saving && !lines.isEmpty && viewport != nil,
                           onCancel: close, onPrimary: save)
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    if loading { ProgressView().accessibilityLabel(String(localized: "Loading graph")) }
                    if !display.ops.isEmpty { preview }
                    Text(String(localized: "Expressions"))
                        .font(NibFont.bodyEmphasis).foregroundStyle(NibColor.label)
                    Text(String(localized: "One function per line, such as y = x² or sin(x)."))
                        .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $expressions)
                        .font(NibFont.body).foregroundStyle(NibColor.label)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: NibMetrics.hitTarget * 3)
                        .padding(NibSpacing.s)
                        .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.field))
                        .accessibilityLabel(String(localized: "Graph expressions, one per line"))
                    if ref != nil {
                        Text(String(localized: "Viewport"))
                            .font(NibFont.bodyEmphasis).foregroundStyle(NibColor.label)
                        if sizeClass == .compact || typeSize.isAccessibilitySize {
                            viewportFields
                        } else {
                            HStack(alignment: .top, spacing: NibSpacing.m) { viewportFields }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: NibSpacing.s) { zoomButtons }
                            VStack(alignment: .leading, spacing: NibSpacing.s) { zoomButtons }
                        }
                    }
                    if let error {
                        Text(error).font(NibFont.footnote).foregroundStyle(NibColor.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(String(localized: "Graph error: \(error)"))
                    }
                    if saving { ProgressView().accessibilityLabel(String(localized: "Saving graph")) }
                }
                .padding(NibSpacing.xl)
            }
            .disabled(loading || saving)
        }
        .background(NibColor.backgroundSecondary)
        .task { await load() }
        .onChange(of: expressions) { _, _ in refreshPreview() }
        .onChange(of: centreX) { _, _ in refreshPreview() }
        .onChange(of: centreY) { _, _ in refreshPreview() }
        .onChange(of: scale) { _, _ in refreshPreview() }
        .onDisappear { previewCancellation?.cancel(); previewTask?.cancel() }
    }

    @ViewBuilder private var viewportFields: some View {
        numberField(String(localized: "Centre x"), text: $centreX)
        numberField(String(localized: "Centre y"), text: $centreY)
        numberField(String(localized: "Points per unit"), text: $scale)
    }
    private func numberField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            Text(label).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
            TextField(label, text: text)
                .font(NibFont.body).foregroundStyle(NibColor.label)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .frame(minHeight: NibMetrics.hitTarget)
                .padding(.horizontal, NibSpacing.m)
                .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.field))
                .accessibilityLabel(label)
        }
    }
    @ViewBuilder private var zoomButtons: some View {
        NibButton(String(localized: "Zoom Out"), symbol: .minus, shortcut: KeyboardShortcut("-")) { zoom(0.5) }
        NibButton(String(localized: "Zoom In"), symbol: .plus, shortcut: KeyboardShortcut("=")) { zoom(2) }
        NibButton(String(localized: "Reset View"), shortcut: KeyboardShortcut("0")) {
            centreX = "0"; centreY = "0"; scale = "32"
        }
    }
    private var preview: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                context.withCGContext { cg in
                    cg.scaleBy(x: size.width / frame.w, y: size.height / frame.h)
                    display.draw(in: cg)
                }
            }
            .gesture(DragGesture().onEnded { value in
                guard ref != nil, let v = viewport else { return }
                centreX = MathEngine.numberText(v.x - Double(value.translation.width / geometry.size.width) * frame.w / v.scale)
                centreY = MathEngine.numberText(v.y + Double(value.translation.height / geometry.size.height) * frame.h / v.scale)
            })
            .simultaneousGesture(MagnificationGesture().onEnded { zoom(Double($0)) })
        }
        .aspectRatio(frame.w / frame.h, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Graph preview"))
        .accessibilityValue(lines.joined(separator: "; "))
        .accessibilityHint(ref == nil ? String(localized: "Preview of the expressions to insert.") : String(localized: "Drag to pan or pinch to zoom. Centre and scale fields provide precise control. Save Graph applies these changes."))
        .accessibilityAction(named: String(localized: "Zoom In")) { zoom(2) }
        .accessibilityAction(named: String(localized: "Zoom Out")) { zoom(0.5) }
    }
    private func zoom(_ factor: Double) {
        guard ref != nil, let v = viewport, factor.isFinite, factor > 0 else { return }
        scale = MathEngine.numberText(min(GraphViewport.scaleRange.upperBound,
                                        max(GraphViewport.scaleRange.lowerBound, v.scale * factor)))
    }

    private func load() async {
        defer { loading = false; refreshPreview() }
        do {
            if let ref {
                // All document reads in UI go through the public query command.
                let result = try await context.app.bus.execute(CommandIDs.queryGet, ["ref": .string(ref), "fields": ["custom", "rev"]], session: context.session)
                let record = result["record"] ?? result
                let customJSON = record["custom"] ?? record
                let custom = try customJSON.decode(GraphEditorRecord.self)
                guard custom.owner == GraphBuilder.owner, custom.type == GraphBuilder.type else {
                    throw NibError.unsupported("editing this item as a maths graph")
                }
                let data = try custom.data.decode(GraphData.self)
                frame = custom.frame
                expressions = data.expressions.joined(separator: "\n")
                centreX = MathEngine.numberText(data.viewport.x)
                centreY = MathEngine.numberText(data.viewport.y)
                scale = MathEngine.numberText(data.viewport.scale)
                revision = record["rev"]?.stringValue
            } else if let rect = context.params["rect"], let values = try? rect.decode([Double].self),
                      let parsed = Frame(array: values) { frame = parsed }
        } catch { self.error = NibError.wrap(error).message }
    }

    private func refreshPreview() {
        let previous = previewTask
        previewCancellation?.cancel()
        previewTask?.cancel()
        guard !loading, let viewport, !lines.isEmpty else { display = DisplayList(); return }
        let lines = self.lines, frame = self.frame
        let cancellation = MathCancellation()
        previewCancellation = cancellation
        previewTask = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let built = try await MathStack.perform {
                    try GraphBuilder.build(expressions: lines, frame: frame, viewport: viewport, cancellation: cancellation)
                }
                guard !Task.isCancelled else { return }
                display = built
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                display = DisplayList()
                self.error = NibError.wrap(error).message
            }
        }
    }
    private func close() {
        context.app.perform(CommandIDs.panelClose, ["id": .string(GraphCommands.panelID)], session: context.session)
    }
    private func save() {
        guard let viewport, !saving else { return }
        saving = true
        previewCancellation?.cancel()
        previewTask?.cancel()
        Task { @MainActor in
            defer { saving = false }
            do {
                var params: JSONValue = ["expressions": .array(lines.map(JSONValue.string))]
                let command: String
                if let ref {
                    command = CommandIDs.mathGraphSetViewport
                    params = params.merging(["ref": .string(ref)])
                    params = params.merging(["x": .number(viewport.x)])
                    params = params.merging(["y": .number(viewport.y)])
                    params = params.merging(["scale": .number(viewport.scale)])
                    if let revision { params = params.merging(["revision": .string(revision)]) }
                } else {
                    command = CommandIDs.mathGraphCreate
                    if let page = context.params["page"] { params = params.merging(["page": page]) }
                    if let rect = context.params["rect"] { params = params.merging(["rect": rect]) }
                    if let id = context.params["itemID"] { params = params.merging(["id": id]) }
                }
                _ = try await context.app.bus.execute(command, params, session: context.session)
                close()
            } catch { self.error = NibError.wrap(error).message }
        }
    }
}

/// Query projections can trim the large display list; the editor reads only the original graph inputs.
private struct GraphEditorRecord: Decodable {
    var owner: String
    var type: String
    var frame: Frame
    var data: JSONValue
}
