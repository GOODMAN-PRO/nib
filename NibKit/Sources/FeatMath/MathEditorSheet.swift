import SwiftUI
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

/// An opaque native sheet keeps editing controls and preview away from live ink.
/// It uses the host window's session throughout, including undo and presentation.
private struct LatexLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

@MainActor
struct MathEditorSheet: View {
    let context: PanelContext
    @State private var lines: [LatexLine] = []
    @State private var revs: [Rev]?
    @State private var loaded = false
    @State private var targetInitialized = false
    @State private var applyFailed = false
    @State private var previewBusy = false
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
                isPrimaryEnabled: !busy && !previewBusy && !lines.isEmpty && preview != nil && previewError == nil,
                onCancel: context.dismiss, onPrimary: { apply() })
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    if busy { NibTraceRow(String(localized: "Recognising the selected handwriting…"), phase: .running) }
                    if let warning { NibBanner(warning, style: .info) }
                    if let error {
                        NibBanner(error, action: NibAction(String(localized: "Retry")) { if applyFailed { apply() } else { Task { await load() } } })
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
                                .accessibilityValue(lines.map(\.text).joined(separator: "; "))
                        }
                        if let previewError { NibBanner(previewError) }
                    }
                    Text(String(localized: "LaTeX lines"))
                        .font(NibFont.headline).accessibilityAddTraits(.isHeader)
                    ForEach($lines) { $line in
                        let lineID = line.id
                        let index = lines.firstIndex(where: { $0.id == lineID }) ?? 0
                        VStack(alignment: .leading, spacing: NibSpacing.s) {
                            Text(String(localized: "Line \(index + 1)")).font(NibFont.caption1)
                                .foregroundStyle(NibColor.labelSecondary)
                            NibField(text: $line.text,
                                     prompt: String(localized: "Enter LaTeX"), lines: 1...8)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityLabel(String(localized: "LaTeX line \(index + 1)"))
                            NibButton(String(localized: "Remove line"), kind: .plain) {
                                lines.removeAll { $0.id == lineID }; applied = false
                            }.accessibilityLabel(String(localized: "Remove line \(index + 1)"))
                        }.disabled(busy)
                    }
                    NibButton(String(localized: "Add line"), symbol: .plus, kind: .plain) {
                        lines.append(LatexLine(text: "")); applied = false
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
        .task(id: lines) { await refreshPreview() }
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
        Task { @MainActor in
            do {
                let result = try await context.app.bus.execute(Invocation(command: CommandIDs.mathCopy,
                    params: ["ref": .string(ref), "as": .string(format)], session: context.session))
                let content = try result.value.decode(MathCopy.Output.self)
                if action == "copy", let text = content.latex {
                    _ = try await context.app.bus.execute(Invocation(command: CommandIDs.clipboardCopyText,
                        params: ["text": .string(text)], session: context.session))
                    return
                }
                var shareItem: Any
                var clipboard: [String: Any]
                if let text = content.latex {
                    shareItem = text; clipboard = [UTType.utf8PlainText.identifier: text]
                } else if let name = content.asset,
                          let url = context.app.services.assets?.temporaryURL(AssetRef(String(name.dropFirst(4)))) {
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    shareItem = url; clipboard = [UTType.png.identifier: data]
                } else if let fragment = content.fragment, let assets = context.app.services.assets {
                    let bytes = try await Task.detached {
                        guard let data = fragment.encoded() else { throw NibError(.internalError, "The handwriting could not be encoded") }
                        return data
                    }.value
                    let asset = try assets.putTemporary(bytes, ext: "nibfragment")
                    guard let url = assets.temporaryURL(asset) else { throw NibError.unavailable("The handwriting file could not be prepared") }
                    shareItem = url; clipboard = [NibFragment.typeIdentifier: bytes]
                } else { throw NibError(.internalError, "No math content was returned") }
                if action == "copy" { UIPasteboard.general.setItems([clipboard]); return }
                guard let navigator = context.navigator, let presenter = context.session?.editor as? UIViewController else {
                    throw NibError.unavailable("Open this document before sharing maths")
                }
                let sheet = UIActivityViewController(activityItems: [shareItem], applicationActivities: nil)
                var top = presenter
                while let next = top.presentedViewController { top = next }
                sheet.popoverPresentationController?.sourceView = top.view
                sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
                navigator.presentModal(sheet)
            } catch { self.error = NibError.wrap(error).message; applyFailed = false }
        }
    }

    private func refreshPreview() async {
        applied = false
        previewBusy = true
        let texts = lines.map(\.text)
        do {
            try await Task.sleep(for: .milliseconds(150))
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let image = try MathTypesetter.shared.image(lines: texts, color: RGBA(NibUIColor.label))
                try Task.checkCancellation()
                return image
            }
            let image = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            preview = image; previewError = nil; previewBusy = false
        } catch is CancellationError { return }
        catch { preview = nil; previewError = NibError.wrap(error).message; previewBusy = false }
    }

    private func load() async {
        guard !busy, !loaded, lines.isEmpty else { return }
        busy = true; error = nil; applyFailed = false
        defer { busy = false }
        do {
            if !targetInitialized {
                ref = context.params["ref"]?.stringValue
                targetInitialized = true
            }
            if let ref {
                let result = try await context.app.bus.execute(Invocation(command: CommandIDs.mathCopy,
                    params: ["ref": .string(ref), "as": "latex"], session: context.session))
                lines = (try result.value.decode(MathCopy.Output.self).lines ?? []).map { LatexLine(text: $0) }
            } else {
                refs = context.params["refs"]?.arrayValue?.compactMap(\.stringValue) ?? context.session?.selection.refs ?? []
                guard !refs.isEmpty else {
                    throw NibError(.invalidParams, String(localized: "Select handwriting on the page, then choose Convert › Maths."), path: "$.refs")
                }
                let result = try await context.app.bus.execute(Invocation(command: CommandIDs.mathRecognize,
                    params: ["refs": .array(refs.map(JSONValue.string))], session: context.session))
                let recognition = try result.value.decode(MathRecognition.self)
                lines = recognition.lines.map { LatexLine(text: $0) }; warning = recognition.warning; revs = recognition.revs
            }
            loaded = true
        } catch is CancellationError { return }
        catch { self.error = NibError.wrap(error).message }
    }

    private func apply() {
        guard !busy, !lines.isEmpty else { return }
        busy = true; error = nil; applyFailed = true
        let texts = lines.map(\.text)
        Task { @MainActor in
            defer { busy = false }
            do {
                let command = ref == nil ? CommandIDs.mathConvert : CommandIDs.mathSetLatex
                var params: [String: JSONValue]
                if let ref { params = ["ref": .string(ref), "lines": .array(texts.map(JSONValue.string))] }
                else { params = ["refs": .array(refs.map(JSONValue.string)), "latex": .array(texts.map(JSONValue.string))] }
                if ref == nil, let revs { params["revs"] = try JSONValue.from(revs) }
                let result = try await context.app.bus.execute(Invocation(command: command, params: .object(params), session: context.session))
                if ref == nil { ref = result.value["ref"]?.stringValue }
                undoGroup = result.group; applied = true; applyFailed = false
            } catch { self.error = NibError.wrap(error).message }
        }
    }
}
