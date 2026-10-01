import SwiftUI
import UIKit
import NibContracts
import NibDesign

/// An opaque native sheet keeps editing controls and preview away from live ink.
/// It uses the host window's session throughout, including undo and presentation.
@MainActor
struct MathEditorSheet: View {
    let context: PanelContext
    @State private var lines: [String] = []
    @State private var ref: String?
    @State private var refs: [String] = []
    @State private var warning: String?
    @State private var error: String?
    @State private var busy = false
    @State private var applied = false
    @State private var undoGroup: String?
    @State private var preview: UIImage?
    @State private var previewError: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(ref == nil ? String(localized: "Convert to Maths") : String(localized: "Edit LaTeX"),
                cancelTitle: String(localized: "Done"), primaryTitle: applied ? nil : String(localized: "Apply"),
                isPrimaryEnabled: !busy && !lines.isEmpty && previewError == nil,
                onCancel: context.dismiss, onPrimary: { apply() })
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    if busy { NibTraceRow(String(localized: "Recognising the selected handwriting…"), phase: .running) }
                    if let warning { NibBanner(warning, style: .info) }
                    if let error {
                        NibBanner(error, action: NibAction(String(localized: "Retry")) { Task { await load() } })
                    }
                    if !lines.isEmpty {
                        Text(String(localized: "Preview"))
                            .font(NibFont.headline).accessibilityAddTraits(.isHeader)
                        if let preview {
                            Image(uiImage: preview).resizable().scaledToFit()
                                .frame(maxHeight: NibMetrics.floatingPanelSize.height)
                                .padding(NibSpacing.l)
                                .background(NibColor.background)
                                .accessibilityLabel(String(localized: "Typeset maths preview"))
                                .accessibilityValue(lines.joined(separator: "; "))
                        }
                        if let previewError { NibBanner(previewError) }
                    }
                    Text(String(localized: "LaTeX lines"))
                        .font(NibFont.headline).accessibilityAddTraits(.isHeader)
                    ForEach(lines.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: NibSpacing.s) {
                            Text(String(localized: "Line \(index + 1)")).font(NibFont.caption1)
                                .foregroundStyle(NibColor.labelSecondary)
                            NibField(text: Binding(get: { lines[index] }, set: { lines[index] = $0; applied = false }),
                                     prompt: String(localized: "Enter LaTeX"), lines: 1...8)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityLabel(String(localized: "LaTeX line \(index + 1)"))
                            NibButton(String(localized: "Remove line"), kind: .plain) {
                                lines.remove(at: index); applied = false
                            }
                        }
                    }
                    NibButton(String(localized: "Add line"), symbol: .plus, kind: .plain) {
                        lines.append(""); applied = false
                    }.disabled(lines.count >= 64 || busy)
                    if applied, let undoGroup {
                        NibBanner(String(localized: "Maths updated."), style: .info,
                            action: NibAction(String(localized: "Undo")) {
                                if let doc = ref.flatMap({ NodeRef($0)?.documentID }) ?? context.session?.document {
                                    context.app.perform(CommandIDs.revertGroup, ["group": .string(undoGroup), "doc": .string(NodeRef.document(doc).description)], session: context.session)
                                }
                                context.dismiss()
                            })
                    }
                    if let ref {
                        transferActions(ref)
                    }
                }
                .padding(NibSpacing.xl)
                .frame(maxWidth: sizeClass == .compact || typeSize.isAccessibilitySize ? .infinity : NibMetrics.textColumnWidth,
                       alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(NibColor.label)
        .background(NibColor.backgroundSecondary)
        .task { await load() }
        .onChange(of: lines) { _, _ in refreshPreview() }
    }

    @ViewBuilder
    private func transferActions(_ ref: String) -> some View {
        NibInspectorSection(String(localized: "Copy or share")) {
            ForEach(["latex", "image", "handwriting"], id: \.self) { format in
                let title = format == "latex" ? String(localized: "LaTeX")
                    : format == "image" ? String(localized: "Image") : String(localized: "Handwriting")
                ViewThatFits(in: .horizontal) {
                    HStack {
                        NibButton(String(localized: "Copy \(title)"), symbol: .copy) { transfer(ref, format, "copy") }
                        NibButton(String(localized: "Share \(title)"), symbol: .share) { transfer(ref, format, "share") }
                    }
                    VStack(alignment: .leading) {
                        NibButton(String(localized: "Copy \(title)"), symbol: .copy) { transfer(ref, format, "copy") }
                        NibButton(String(localized: "Share \(title)"), symbol: .share) { transfer(ref, format, "share") }
                    }
                }
            }
        }
    }

    private func transfer(_ ref: String, _ format: String, _ action: String) {
        context.app.perform(MathTransfer.descriptor.id, ["ref": .string(ref), "as": .string(format), "action": .string(action)],
                            session: context.session)
    }

    private func refreshPreview() {
        do {
            preview = try MathTypesetter.shared.image(lines: lines, color: RGBA(NibUIColor.label))
            previewError = nil
        } catch {
            preview = nil
            previewError = NibError.wrap(error).message
        }
    }

    private func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            ref = context.params["ref"]?.stringValue
            if let ref {
                let result = try await context.app.bus.execute(Invocation(command: CommandIDs.mathCopy,
                    params: ["ref": .string(ref), "as": "latex"], session: context.session))
                lines = try result.value.decode(MathCopy.Output.self).lines ?? []
            } else {
                refs = context.params["refs"]?.arrayValue?.compactMap(\.stringValue) ?? context.session?.selection.refs ?? []
                guard !refs.isEmpty else {
                    throw NibError(.invalidParams, String(localized: "Select handwriting on the page, then choose Convert › Maths."), path: "$.refs")
                }
                let result = try await context.app.bus.execute(Invocation(command: CommandIDs.mathRecognize,
                    params: ["refs": .array(refs.map(JSONValue.string))], session: context.session))
                let recognition = try result.value.decode(MathRecognition.self)
                lines = recognition.lines; warning = recognition.warning
            }
            refreshPreview()
        } catch is CancellationError { return }
        catch { self.error = NibError.wrap(error).message }
    }

    private func apply() {
        guard !busy, !lines.isEmpty else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let command = ref == nil ? CommandIDs.mathConvert : CommandIDs.mathSetLatex
                let params: JSONValue
                if let ref { params = ["ref": .string(ref), "lines": .array(lines.map(JSONValue.string))] }
                else { params = ["refs": .array(refs.map(JSONValue.string)), "latex": .array(lines.map(JSONValue.string))] }
                let result = try await context.app.bus.execute(Invocation(command: command, params: params, session: context.session))
                if ref == nil { ref = result.value["ref"]?.stringValue }
                undoGroup = result.group; applied = true
            } catch { self.error = NibError.wrap(error).message }
        }
    }
}
