import SwiftUI

/// Empty states are typography only: a 44 pt glyph in tertiary, a New York title, one sentence, at most one primary
/// and one secondary action. No illustrations, no mascots.
public struct NibEmptyState: View {
    let symbol: NibSymbol
    let title: String
    let message: String?
    let primary: NibAction?
    let secondary: NibAction?

    public init(symbol: NibSymbol, title: String, message: String? = nil, primary: NibAction? = nil,
                secondary: NibAction? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
    }

    public var body: some View {
        VStack(spacing: 0) {
            Image(nib: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(NibColor.labelTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(NibFont.emptyTitle)
                .foregroundStyle(NibColor.label)
                .multilineTextAlignment(.center)
                .padding(.top, NibSpacing.l)
            if let message {
                Text(message)
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, NibSpacing.s)
            }
            if primary != nil || secondary != nil {
                HStack(spacing: NibSpacing.m) {
                    if let primary {
                        NibButton(primary.title, kind: .primary, action: primary.handler)
                    }
                    if let secondary {
                        NibButton(secondary.title, kind: .secondary, action: secondary.handler)
                    }
                }
                .padding(.top, NibSpacing.xxl)
            }
        }
        .frame(maxWidth: 420)
        .padding(NibSpacing.xxl)
        .accessibilityElement(children: .contain)
    }
}
