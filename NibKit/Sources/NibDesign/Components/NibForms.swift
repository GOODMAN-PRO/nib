import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import NibContracts

/// A password, API key or token field (DESIGN.md §14.8: secrets are entered only in Settings, in secure fields; the
/// lock prompt). 44 pt on `fill4` with the form-field radius (10), and an eye button that shows the text while held
/// open. The text is marked privacy-sensitive, so it is redacted in snapshots.
public struct NibSecureField: View {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void
    @State private var revealed = false

    public init(text: Binding<String>, prompt: String, onSubmit: @escaping () -> Void = {}) {
        self._text = text
        self.prompt = prompt
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 0) {
            Group {
                if revealed {
                    TextField(prompt, text: $text)
                } else {
                    SecureField(prompt, text: $text)
                }
            }
            .font(NibFont.body)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .privacySensitive()
            .submitLabel(.done)
            .onSubmit(onSubmit)
            .padding(.leading, NibSpacing.m)
            Button {
                revealed.toggle()
            } label: {
                Image(nib: revealed ? .eyeSlash : .eye)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NibPressStyle(shape: Circle()))
            .accessibilityLabel(revealed ? String(localized: "Hide text", bundle: .module)
                                         : String(localized: "Show text", bundle: .module))
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
    }
}

/// Text people copy exactly (DESIGN.md §4: SF Mono only for the developer console, raw tool calls and pasteable
/// configuration such as the bridge's `claude mcp add …` line): code type on `fill4` (radius 12), selectable, with an
/// optional Copy button. The caller copies (the pasteboard belongs to the feature).
public struct NibCodeBlock: View {
    let text: String
    let onCopy: (() -> Void)?

    public init(_ text: String, onCopy: (() -> Void)? = nil) {
        self.text = text
        self.onCopy = onCopy
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: text)
                .font(NibFont.code)
                .foregroundStyle(NibColor.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NibSpacing.m)
            if let onCopy {
                NibIconButton(.copy, label: String(localized: "Copy", bundle: .module), size: .panel, action: onCopy)
            }
        }
        .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous))
    }
}

/// A QR code for pairing and joining (the bridge's pairing URL, a live session's join code): black modules on a white
/// card with a quiet zone, scaled with no interpolation so it stays crisp. It stays white in dark mode because
/// scanners need it. `label` is what VoiceOver says ("QR code for joining this session").
public struct NibQRCode: View {
    let label: String
    let image: CGImage?

    public init(_ payload: String, label: String) {
        self.label = label
        self.image = NibQRCode.render(payload)
    }

    private static let context = CIContext()

    /// One pixel per module, medium error correction; nil for an empty payload.
    static func render(_ payload: String) -> CGImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    public var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(NibSpacing.m)
        .background(NibPaper.white.color, in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }
}

/// A plugin permission as a plain sentence with its glyph (DESIGN.md §14.10): "Read every document" with `doc`. In an
/// update's permission diff, added permissions are accent with "+" and removed ones are struck through; VoiceOver says
/// "Added" or "Removed" first. The accessory is usually the permission's own `NibToggle`.
public struct NibPermissionRow<Accessory: View>: View {
    public enum Change: Sendable {
        case unchanged, added, removed
    }

    let text: String
    let symbol: NibSymbol
    let change: Change
    let accessory: Accessory

    public init(_ text: String, symbol: NibSymbol, change: Change = .unchanged,
                @ViewBuilder accessory: () -> Accessory) {
        self.text = text
        self.symbol = symbol
        self.change = change
        self.accessory = accessory()
    }

    private var spoken: String {
        switch change {
        case .unchanged: return text
        case .added: return String(localized: "Added: \(text)", bundle: .module)
        case .removed: return String(localized: "Removed: \(text)", bundle: .module)
        }
    }

    public var body: some View {
        HStack(spacing: NibSpacing.m) {
            Image(nib: symbol)
                .font(NibFont.body)
                .foregroundStyle(change == .added ? NibColor.accent : NibColor.labelSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(verbatim: change == .added ? "+ " + text : text)
                .font(NibFont.body)
                .foregroundStyle(change == .added ? NibColor.accent : (change == .removed ? NibColor.labelSecondary : NibColor.label))
                .strikethrough(change == .removed)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(spoken)
            Spacer(minLength: NibSpacing.s)
            accessory
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .accessibilityElement(children: .contain)
    }
}

public extension NibPermissionRow where Accessory == EmptyView {
    init(_ text: String, symbol: NibSymbol, change: Change = .unchanged) {
        self.init(text, symbol: symbol, change: change) { EmptyView() }
    }
}
